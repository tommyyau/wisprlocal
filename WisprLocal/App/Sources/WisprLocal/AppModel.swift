import AppKit
import CoreAudio
import Observation
import SwiftUI
import WisprLocalCore

/// What every screen reads and does. Live it forwards to `AppController`; in the DEBUG
/// `--ui-preview` harness it serves fixed sample state, so screens render deterministically
/// without touching the real pipeline, permissions or user data.
@MainActor
@Observable
final class AppModel {
    enum ModelState: Equatable { case preparing(since: Date?), ready, failed(String) }

    /// Fixed state for previews.
    struct Sample {
        var granted: [Permission: Bool] = [.microphone: true, .accessibility: true, .inputMonitoring: true]
        var health: PermissionHealth = .ready
        var globe: GlobeKeyConflict = .doNothing
        var wisprFlowRunning = false
        var cleanup: CleanupModelAvailability = .available
        var model: ModelState = .ready
        var devices: [InputDevice] = [InputDevice(id: 1, name: "MacBook Pro Microphone", isBuiltIn: true),
                                      InputDevice(id: 2, name: "AirPods Pro", isBuiltIn: false)]
        var defaultDevice: AudioDeviceID? = 1
        var now = Date()
        var debugRecordingCount = 0
        var selfTest = SelfTest()
        var showGettingStarted: Bool?
        /// History entries that have a troubleshooting clip (preview only).
        var clipIDs: Set<UUID> = []
        /// Preview only: render this entry's clip as playing, 40 % through.
        var playingID: UUID?
        var retranscription: Retranscription.State = .idle
        /// Preview only: render this row as hovered (actions visible).
        var hoverID: UUID?
        /// Preview only: the account's first name (never read from the real account).
        var firstName = "Alex"
        /// Preview only: expand this category's top apps on Insights.
        var expandedCategory: AppCategory?
        /// Preview: "N learned from your corrections" (Settings › Writing).
        var learnedWords = 0
    }

    /// Home's live self-test: did we hear the mic, recognise words, insert text?
    struct SelfTest: Equatable {
        var startedAt = Date()
        var micHeard = false
        var attempt: HistoryEntry?
    }

    @ObservationIgnored let live: AppController?
    let settings: AppSettings
    let dictionary: DictionaryStore
    let placement: HUDPlacementStore
    var sample: Sample
    private(set) var entries: [HistoryEntry] = []
    /// Bumped by the 1–2 s poll on screens that show system state (permissions etc. aren't observable).
    var tick = 0
    var selfTest = SelfTest()
    /// History entry ids that have a clip on disk (refreshed whenever clips change).
    private(set) var clipIDs: Set<UUID> = []
    let playback: ClipPlayback
    let retranscription: Retranscription
    @ObservationIgnored private var timeZoneObserver: NSObjectProtocol?
    @ObservationIgnored private var clipObserver: NSObjectProtocol?
    @ObservationIgnored private let defaults: UserDefaults
    static let gettingStartedHiddenKey = "gettingStartedHidden"
    private var gettingStartedHidden: Bool
    var devices: [InputDevice] = []
    var defaultDevice: AudioDeviceID?
    /// The section the main window should show (menu items deep-link into it).
    var section: MainSection = .home
    /// Menu "Help & FAQ": the Help page switches to this tab (then clears it).
    var helpTabRequest: HelpView.Tab?
    /// HUD "See why": History opens this entry's details (then clears it).
    var historyDetailRequest: UUID?
    /// Deep link into Settings: the page scrolls to this section (then clears it).
    var settingsRequest: SettingsRequest?
    static let settingsTabKey = "settingsTab"
    var settingsTab: SettingsSection = .general {
        didSet { defaults.set(settingsTab.rawValue, forKey: Self.settingsTabKey) }
    }

    init(controller: AppController) {
        live = controller
        settings = controller.settings
        dictionary = controller.dictionary
        placement = controller.hudPlacement
        sample = Sample()
        defaults = .standard
        settingsTab = SettingsSection(rawValue: defaults.string(forKey: Self.settingsTabKey) ?? "") ?? .general
        gettingStartedHidden = UserDefaults.standard.bool(forKey: Self.gettingStartedHiddenKey)
        playback = controller.playback
        retranscription = controller.retranscription
        observeHistory()
        timeZoneObserver = NotificationCenter.default.addObserver(forName: .NSSystemTimeZoneDidChange,
                                                                  object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshHistoryCalendar() }
        }
        refreshDevices()
        // Settings › Privacy › Delete All, pruning, new clips: play buttons follow the disk.
        clipObserver = NotificationCenter.default.addObserver(forName: DebugRecordingStore.didChangeNotification,
                                                              object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshClips() }
        }
    }

    init(sample: Sample, settings: AppSettings, dictionary: DictionaryStore, placement: HUDPlacementStore, entries: [HistoryEntry],
         defaults: UserDefaults) {
        live = nil
        self.placement = placement
        self.defaults = defaults
        settingsTab = SettingsSection(rawValue: defaults.string(forKey: Self.settingsTabKey) ?? "") ?? .general
        gettingStartedHidden = sample.showGettingStarted.map { !$0 } ?? defaults.bool(forKey: Self.gettingStartedHiddenKey)
        selfTest = sample.selfTest
        self.sample = sample
        self.settings = settings
        self.dictionary = dictionary
        self.entries = entries
        devices = sample.devices
        defaultDevice = sample.defaultDevice
        clipIDs = sample.clipIDs
        let previewDir = FileManager.default.temporaryDirectory.appendingPathComponent("wisprlocal-ui-preview-clips", isDirectory: true)
        playback = ClipPlayback(directory: previewDir, isDictating: { false }, makePlayer: { _ in PreviewClipPlayer() })
        retranscription = Retranscription(makeTranscriber: { _ in PreviewTranscriber() }, isDictating: { false })
        if let id = sample.playingID { playback.play(id: id, url: previewDir.appendingPathComponent(id.uuidString + ".wav")) }
        cachePreview()
    }

    // MARK: state

    var now: Date { live == nil ? sample.now : Date() }
    private let historyPresentation = HistoryPresentation()
    var historyRevision: UInt64 { historyPresentation.revision }
    var historySearchPage: HistoryIndex.Page { historyPresentation.searchPage }
    func canOpenHistory(_ id: UUID) -> Bool { historyPresentation.canOpen(id) }
    var stats: HistoryStats { historyPresentation.stats }
    var timeline: [HistoryEntry] { historyPresentation.recent }
    var dictations: [HistoryEntry] { timeline.filter(HistoryStats.counts) }
    var historyGroups: [HistoryPresentation.DayGroup] { historyPresentation.groups }
    var diagnostics: [HistoryEntry] { historyPresentation.diagnostics }
    var insights: Insights { historyPresentation.insights }
    var historyHasMore: Bool { historyPresentation.hasMore }
    @ObservationIgnored private var historyTask: Task<Void, Never>?
    @ObservationIgnored private var lastHistoryDay: Date?

    var historyRemovalFailures = Set<UUID>()

    func retryHistoryRemoval() {
        if let live { Task { await live.library.index.retryRemovals() } }
    }

    func observeHistory() {
        guard let live else { return }
        historyTask?.cancel()
        let index = live.library.index
        historyTask = Task { [weak self] in
            let changes = await index.changes()
            Task { await index.load() }
            for await change in changes {
                guard !Task.isCancelled, let self else { break }
                switch change {
                case .loadedRecent(let snapshot), .loadedAll(let snapshot), .appended(_, let snapshot),
                     .removed(_, let snapshot), .cleared(let snapshot):
                    self.historyRemovalFailures = snapshot.failedRemovalIDs
                }
                self.historyPresentation.apply(change, now: self.now)
                self.entries = self.timeline.reversed()
                self.refreshClips()
            }
        }
    }

    func historyPage(more: Bool = false) async {
        guard let live else { return }
        let revision = historyRevision
        let page = await live.library.index.page(moreDays: more ? 7 : 0)
        guard revision == historyRevision else { return }
        historyPresentation.setPage(page, now: now)
        entries = timeline.reversed()
    }

    func searchHistory(query: String, more: Bool = false) async -> HistoryIndex.Page {
        let request = historyPresentation.beginSearch(query: query)
        if let live {
            let revision = historyRevision
            let page = await live.library.index.page(moreDays: more ? 7 : 0, query: query)
            guard !Task.isCancelled else { return .init() }
            historyPresentation.setSearchPage(page, revision: revision, request: request)
            return historyPresentation.searchPage
        }
        let q = query.trimmingCharacters(in: .whitespaces)
        let page = HistoryIndex.Page(entries: historyGroups.flatMap(\.entries).filter {
            HistoryStats.counts($0) && ($0.final.localizedCaseInsensitiveContains(q) || $0.raw.localizedCaseInsensitiveContains(q))
        })
        historyPresentation.setSearchPage(page, revision: historyRevision, request: request)
        return historyPresentation.searchPage
    }

    private func cachePreview() {
        let stats = HistoryStats(entries: entries, now: now)
        let calculator = InsightsCalculator(); calculator.update(entries: entries)
        let diagnostics = Array(entries.filter { $0.zeroFraction != nil }.suffix(MicAudioDiagnostics.window))
        let page = HistoryIndex.Page(entries: entries.reversed().filter(HistoryIndex.visible))
        historyPresentation.apply(.loadedAll(.init(page: page, stats: stats, insights: calculator.insights(now: now),
                                                   diagnostics: diagnostics, prunableCounts: [:])), now: now)
    }

    /// "Welcome back, Alex": the first word of the Mac account's full name, when the user
    /// hasn't turned it off (Settings › Privacy).
    var greetingName: String? {
        guard settings.greetByName else { return nil }
        let full = live == nil ? sample.firstName : NSFullUserName()
        guard let first = full.split(whereSeparator: { $0.isWhitespace }).first, !first.isEmpty else { return nil }
        return String(first)
    }

    /// Preview only: the row drawn as hovered.
    var previewHoverID: UUID? { live == nil ? sample.hoverID : nil }

    func isGranted(_ p: Permission) -> Bool {
        _ = tick
        return live != nil ? p.isGranted : (sample.granted[p] ?? false)
    }
    var allGranted: Bool { Permission.allCases.allSatisfy(isGranted) }
    var health: PermissionHealth { live?.permissions.health ?? sample.health }
    var globeConflict: GlobeKeyConflict { _ = tick; return live?.conflicts.globeConflict ?? sample.globe }
    /// Holding off for Wispr Flow (running and not overridden).
    var wisprFlowRunning: Bool { live?.conflicts.holdingOff ?? sample.wisprFlowRunning }
    var cleanupAvailability: CleanupModelAvailability { live?.cleanupAvailability ?? sample.cleanup }
    var hotkeyActive: Bool { live?.hotkeyActive ?? (sample.health == .ready) }
    var modelState: ModelState {
        guard let live else { return sample.model }
        switch live.pipeline.status {
        case .preparingModel: return .preparing(since: live.prewarmStartedAt)
        case .error(let m): return .failed(m)
        default: return live.modelError.map { .failed($0) } ?? .ready
        }
    }
    var lastDictation: HistoryEntry? { live?.lastDictation ?? dictations.first }

    /// One human sentence for the overall state (Home hero, menu).
    var readiness: (ok: Bool, text: String) {
        let issues = setupIssues
        return issues.first.map { (false, $0.text) } ?? (true, "Ready. Hold 🌐 anywhere you can type.")
    }

    var setupIssues: [SetupIssue] {
        let state: SetupIssue.Model
        switch modelState {
        case .ready: state = .ready
        case .preparing: state = .preparing
        case .failed: state = .failed
        }
        return SetupIssue.resolve(permissions: Dictionary(uniqueKeysWithValues: Permission.allCases.map { ($0, isGranted($0)) }),
                                  health: health, globeAction: globeConflict, consumeGlobe: settings.consumeGlobeKey,
                                  wisprFlow: wisprFlowRunning, model: state, globeActive: hotkeyActive)
    }

    var micReadiness: MicReadiness { MicReadiness(keep: settings.keepMicReady, always: settings.alwaysMicReady) }
    func setMicReadiness(_ value: MicReadiness) {
        if let live { live.setMicReadiness(value) } else { value.apply(to: settings) }
    }

    // MARK: actions

    func refreshClips() {
        guard let live else { return }
        clipIDs = live.recordings.clipIDs()
        playback.clipsChanged(available: clipIDs)
    }

    /// Deletes the entry AND its clip (stopping it first if it is playing).
    func delete(_ e: HistoryEntry) {
        playback.stop(ifPlaying: e.id)
        if retranscription.entryID == e.id { retranscription.cancel() }
        if let live { Task { await live.library.index.delete(ids: [e.id]) } }
        else { entries.removeAll { $0.id == e.id }; cachePreview() }
    }

    /// Clear All: every entry and every clip.
    func clearHistory() {
        playback.stop()
        retranscription.cancel()
        if let live { Task { await live.library.index.clear() } }
        else { entries = []; clipIDs = []; cachePreview() }
    }

    // MARK: playback

    /// What the row's play slot shows for `e`.
    func playbackState(_ e: HistoryEntry) -> HistoryPlayback { HistoryPlayback.of(e, clipIDs: clipIDs) }

    func clipURL(_ e: HistoryEntry) -> URL? {
        guard playbackState(e) == .playable else { return nil }
        if let live { return live.library.clipURL(for: e) }
        return FileManager.default.temporaryDirectory.appendingPathComponent("wisprlocal-ui-preview-clips/\(e.id.uuidString).wav")
    }

    func togglePlayback(_ e: HistoryEntry) {
        guard let url = clipURL(e) else { return }
        playback.toggle(id: e.id, url: url)
    }

    func stopPlayback() { playback.stop() }

    /// Recording or processing a dictation right now.
    var isDictating: Bool {
        guard let live else { return false }
        switch live.pipeline.status {
        case .recording, .processing: return true
        default: return false
        }
    }

    /// The model "Re-transcribe" would use for `e` (the one it was NOT transcribed with).
    func otherVariant(for e: HistoryEntry) -> ASRModelVariant {
        Retranscription.otherVariant(for: e, active: live?.activeVariant ?? settings.activeASRVariant)
    }

    func retranscribe(_ e: HistoryEntry) {
        guard let url = clipURL(e) else { return }
        retranscription.start(entryID: e.id, clip: url, variant: otherVariant(for: e))
    }

    /// The retranscription state shown for `e` (preview: fixed sample state).
    func retranscriptionState(for e: HistoryEntry) -> Retranscription.State {
        if live == nil { return sample.retranscription }
        return retranscription.entryID == e.id ? retranscription.state : .idle
    }

    func refreshDevices() {
        guard live != nil else { return }
        devices = InputDevices.all()
        defaultDevice = InputDevices.defaultInputID()
    }

    func selectDevice(_ id: AudioDeviceID) {
        guard live != nil else { defaultDevice = id; return }
        if InputDevices.setDefaultInput(id) { defaultDevice = id }
    }

    func refreshSystemState() {
        tick &+= 1
        live?.refreshStatus()
        live?.conflicts.refresh()
        let day = Calendar.autoupdatingCurrent.startOfDay(for: now)
        if lastHistoryDay != day { refreshHistoryCalendar() }
    }

    private func refreshHistoryCalendar() {
        lastHistoryDay = Calendar.autoupdatingCurrent.startOfDay(for: now)
        historyPresentation.calendarDidChange(now: now)
        if let live { Task { await live.library.index.calendarDidChange(now: now) } }
    }

    func setVoiceProcessing(_ on: Bool) { if let live { live.setVoiceProcessing(on) } else { settings.voiceProcessingEnabled = on } }
    func setAIFormatting(_ on: Bool) { if let live { live.setAICleanup(enabled: on) } else { settings.aiCleanupEnabled = on } }
    /// "Noisy room / other languages (Parakeet Ultra)" (OFF = "English (Parakeet v2)").
    var noisyRoom: Bool { settings.noisyRoomMode }
    func setNoisyRoom(_ on: Bool) { if let live { live.setNoisyRoom(on) } else { settings.noisyRoomMode = on } }
    /// "Speech: English (Parakeet v2)" — the model actually in use.
    func setWisprFlowUsesDifferentShortcut(_ on: Bool) {
        if let live { live.setWisprFlowUsesDifferentShortcut(on) } else { settings.wisprFlowUsesDifferentShortcut = on }
    }
    func setConsumeGlobe(_ on: Bool) { if let live { live.setConsumeGlobe(on) } else { settings.consumeGlobeKey = on } }
    func relaunch() { live?.relaunch() }
    func retryModel() { live?.retryModelPreparation() }
    func quitWisprFlow() { live?.conflicts.quitWisprFlow() }
    func useWisprLocalAnyway() { live?.useWisprLocalAnyway() }
    func request(_ p: Permission) { if live != nil { p.request() } }
    func openSettings(_ p: Permission) { if live != nil { p.openSettings() } }
    func openKeyboardSettings() { if live != nil { NSWorkspace.shared.open(GlobeKeyConflict.keyboardSettingsURL) } }
    func showOnboarding() { if let live { WindowManager.shared.showOnboarding(controller: live) } }
    func completeOnboarding() { settings.onboardingCompleted = true }

    // MARK: getting started

    /// Number of dictations after which the Getting Started cards retire on their own.
    static let gettingStartedGoal = 3
    /// Visible until 3 dictations or until hidden; Help › "Show Getting Started" pins it back.
    var gettingStartedVisible: Bool {
        if live == nil, let forced = sample.showGettingStarted { return forced }
        return !gettingStartedHidden && (stats.totalDictations < Self.gettingStartedGoal || defaults.bool(forKey: Self.gettingStartedPinnedKey))
    }
    static let gettingStartedPinnedKey = "gettingStartedPinned"

    func hideGettingStarted() {
        gettingStartedHidden = true
        if live == nil { sample.showGettingStarted = false }
        defaults.set(true, forKey: Self.gettingStartedHiddenKey)
        defaults.set(false, forKey: Self.gettingStartedPinnedKey)
    }

    func reopenGettingStarted() {
        gettingStartedHidden = false
        if live == nil { sample.showGettingStarted = true }
        defaults.set(false, forKey: Self.gettingStartedHiddenKey)
        defaults.set(true, forKey: Self.gettingStartedPinnedKey)
        restartSelfTest()
        section = .home
    }

    func restartSelfTest() { selfTest = SelfTest(startedAt: Date()) }

    /// Called ~7×/s while the self-test card is on screen.
    func sampleSelfTest() {
        guard let live else { return }
        if !selfTest.micHeard, live.pipeline.status.isRecording,
           (live.recorder.spectrum.read().max() ?? 0) > 0.12 {
            selfTest.micHeard = true
        }
        if let a = live.lastAttempt, a.timestamp >= selfTest.startedAt.addingTimeInterval(-1), a != selfTest.attempt {
            selfTest.attempt = a
            if a.recognisedWords { selfTest.micHeard = true }
        }
    }

    var hudPreset: HUDPreset { placement.preset }
    var hudHasCustom: Bool { placement.hasCustom }
    func setHUDPreset(_ p: HUDPreset) {
        placement.setPreset(p)
        live?.hud.placementChanged()
    }
    /// Shows the real pill on screen, draggable, with Done.
    func adjustHUDPosition() { live?.hud.beginPositioning() }
}

enum AppVersion {
    static var short: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "dev"
    }
    static var build: String? { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String }
    /// "Version 0.1.0 (202610031200)"; unbundled dev runs say so instead of "dev".
    static var display: String {
        guard let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
            return previewOverride ?? "Development build"
        }
        if let b = build, b != v { return "Version \(v) (\(b))" }
        return "Version \(v)"
    }
    /// `--ui-preview` only: render a realistic version line.
    nonisolated(unsafe) static var previewOverride: String?
}

/// The app icon: the bundle's, else the icon source PNG (dev runs / previews), else a drawn orb.
struct AppIconImage: View {
    var size: CGFloat = 64
    static let image: NSImage? = {
        if Bundle.main.bundleURL.pathExtension == "app" { return NSApp?.applicationIconImage }
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/IconSource/icon-B-1024.png")
        return NSImage(contentsOf: src)
    }()
    var body: some View {
        if let img = Self.image {
            Image(nsImage: img).resizable().interpolation(.high).frame(width: size, height: size)
        } else {
            Orb(size: size * 0.8).frame(width: size, height: size)
        }
    }
}

/// Main-window sidebar sections.
enum MainSection: String, CaseIterable, Identifiable, Hashable {
    case home, insights, history, dictionary, snippets, settings, help
    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: "Home"
        case .insights: "Insights"
        case .history: "History"
        case .dictionary: "Dictionary"
        case .snippets: "Snippets"
        case .settings: "Settings"
        case .help: "Help"
        }
    }
    var symbol: String {
        switch self {
        case .home: "house"
        case .insights: "chart.bar.xaxis"
        case .history: "clock.arrow.circlepath"
        case .dictionary: "character.book.closed"
        case .snippets: "text.badge.plus"
        case .settings: "gearshape"
        case .help: "questionmark.circle"
        }
    }
}

// MARK: - App identity helpers (History rows)

@MainActor
enum AppIdentity {
    private static var cache: [String: (String, NSImage)] = [:]

    /// Display name + icon for a bundle ID ("Unknown app" when it's gone).
    static func lookup(_ bundleID: String?) -> (name: String, icon: NSImage) {
        guard let id = bundleID, !id.isEmpty else { return ("Unknown app", fallbackIcon) }
        if let hit = cache[id] { return hit }
        var result: (String, NSImage) = (id.split(separator: ".").last.map { String($0).capitalized } ?? id, fallbackIcon)
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            result = (name, NSWorkspace.shared.icon(forFile: url.path))
        }
        cache[id] = result
        return result
    }

    private static let fallbackIcon: NSImage = NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage()
}

// MARK: - Sample-mode stand-ins (the `--ui-preview` harness never touches audio or models)

/// A "playing" clip frozen 40 % through.
@MainActor
final class PreviewClipPlayer: ClipPlaying {
    var duration: TimeInterval { 5 }
    var currentTime: TimeInterval { 2 }
    var onFinish: (@MainActor () -> Void)?
    func play() -> Bool { true }
    func stop() {}
}

/// Never loads a model.
final class PreviewTranscriber: Transcriber {
    var engineName: String { "preview" }
    func prepare() async throws {}
    func transcribe(_ samples: [Float], vocabularyHints: [String]) async throws -> String { "" }
}
