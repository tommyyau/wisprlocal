#if DEBUG
import AppKit
import Darwin
import SwiftUI
import WisprLocalCore

/// DEBUG-only harness (`WisprLocal --ui-preview <dir>`): renders every screen with sample data,
/// in light and dark, to PNGs. Uses offscreen windows (never ordered on screen), a throwaway
/// UserDefaults suite and a temp dictionary — no real user data is read or written.
@MainActor
enum UIPreview {
    private static var benchmarking: Bool {
        ["1", "baseline"].contains(ProcessInfo.processInfo.environment["WISPRLOCAL_UI_BENCH"] ?? "")
    }
    private static var rowCounts: [String: Int] = [:]
    private static var heights: [String: (content: CGFloat, viewport: CGFloat)] = [:]

    static func run(outputDirectory dir: URL, only: String? = nil) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let suite = "wisprlocal-ui-preview"
        UserDefaults().removePersistentDomain(forName: suite)
        let defaults = UserDefaults(suiteName: suite)!
        let settings = AppSettings(defaults: defaults)
        settings.voiceProcessingEnabled = false
        let dictURL = FileManager.default.temporaryDirectory.appendingPathComponent("wisprlocal-ui-preview-dictionary.json")
        try? FileManager.default.removeItem(at: dictURL)
        let dictionary = DictionaryStore(url: dictURL)
        try? dictionary.update(sampleDictionary)
        let placement = HUDPlacementStore(defaults: defaults)

        func model(_ tweak: (inout AppModel.Sample) -> Void = { _ in }, entries: [HistoryEntry]? = nil) -> AppModel {
            var s = AppModel.Sample()
            s.now = now
            s.debugRecordingCount = 3
            tweak(&s)
            return AppModel(sample: s, settings: settings, dictionary: dictionary, placement: placement,
                            entries: previewHistory ?? entries ?? sampleEntries, defaults: defaults)
        }

        AppVersion.previewOverride = "Version 1.0 (202610031200)"
        var written: [String] = []
        for dark in [false, true] {
            let mode = dark ? "dark" : "light"
            let shots: [(String, CGSize, AnyView)] = [
                ("home", CGSize(width: 1000, height: 1000),
                 main(model({ $0.clipIDs = clipIDs; $0.hoverID = hoverEntry.id }, entries: timelineEntries), .home)),
                ("insights", CGSize(width: 1000, height: 1720),
                 main(model({ $0.expandedCategory = .ai }, entries: insightsEntries), .insights)),
                ("insights-empty", CGSize(width: 1000, height: 1300), main(model(entries: []), .insights)),
                ("snippets-empty", CGSize(width: 1000, height: 760), main(emptySnippetsModel(model()), .snippets)),
                ("home-empty", CGSize(width: 1000, height: 700), main(model(entries: []), .home)),
                ("home-needs-permission", CGSize(width: 1000, height: 420),
                 main(model({ $0.granted[.inputMonitoring] = false; $0.health = .missing([.inputMonitoring]) }), .home)),
                ("history", CGSize(width: 1000, height: 1000),
                 main(model({ $0.clipIDs = clipIDs; $0.hoverID = hoverEntry.id }, entries: timelineEntries), .history)),
                ("history-recordings-off", CGSize(width: 1000, height: 520),
                 main(recordingsOffModel(model({ $0.hoverID = sampleEntries.last!.id }, entries: timelineEntries)), .history)),
                ("dictionary", CGSize(width: 1000, height: 760), main(model(), .dictionary)),
                ("snippets", CGSize(width: 1000, height: 760), main(model(), .snippets)),
                ("settings", CGSize(width: 1000, height: 700), settingsShot(model(), .general, name: "settings")),
                ("settings-microphone", CGSize(width: 1000, height: 700), settingsShot(model(), .microphone, name: "settings-microphone")),
                ("settings-writing", CGSize(width: 1000, height: 700), settingsShot(model(), .writing, name: "settings-writing")),
                ("settings-writing-expanded", CGSize(width: 1000, height: 700), settingsShot(model(), .writing, name: "settings-writing-expanded", expanded: true)),
                ("settings-writing-details", CGSize(width: 1000, height: 1300), settingsShot(model(), .writing, name: "settings-writing-details", expanded: true, override: true)),
                ("settings-preparing", CGSize(width: 1000, height: 700), settingsShot(model({ $0.model = .preparing(since: nil) }), .general, name: "settings-preparing")),
                ("settings-remote-expanded", CGSize(width: 1000, height: 1050), settingsShot(model(), .remote, name: "settings-remote-expanded", expanded: true)),
                ("settings-privacy", CGSize(width: 1000, height: 700), settingsShot(model(), .privacy, name: "settings-privacy")),
                ("settings-ready-popover", CGSize(width: 1000, height: 700), settingsShot(model(), .general, name: "settings-ready-popover", popover: true)),
                ("settings-needs-permission", CGSize(width: 1000, height: 700),
                 settingsShot(model({ $0.granted[.accessibility] = false; $0.granted[.inputMonitoring] = false
                              $0.health = .missing([.accessibility, .inputMonitoring]); $0.globe = .emojiAndSymbols }), .general, name: "settings-needs-permission")),
                ("help", CGSize(width: 1000, height: 3000), main(model(), .help)),
                ("settings-remote", CGSize(width: 1000, height: 700), settingsShot(model(), .remote, name: "settings-remote")),
                ("help-faq", CGSize(width: 1000, height: 1900), main(model(), .help, help: .why)),
                ("home-new-user", CGSize(width: 1000, height: 1650),
                 main(model({ $0.showGettingStarted = true
                              $0.selfTest = AppModel.SelfTest(startedAt: now, micHeard: true, attempt: firstTry) }, entries: [firstTry]), .home)),
                ("home-new-user-waiting", CGSize(width: 1000, height: 1650),
                 main(model({ $0.showGettingStarted = true; $0.selfTest = AppModel.SelfTest(startedAt: now, micHeard: true) }, entries: []), .home)),
                ("onboarding-1-welcome", CGSize(width: 680, height: 580), onboarding(model(), .welcome)),
                ("onboarding-2-permissions", CGSize(width: 680, height: 580),
                 onboarding(model({ $0.granted[.inputMonitoring] = false; $0.health = .missing([.inputMonitoring]); $0.model = .preparing(since: nil) }), .permissions)),
                ("onboarding-3-globe", CGSize(width: 680, height: 580), onboarding(model({ $0.globe = .emojiAndSymbols }), .globe)),
                ("onboarding-4-try", CGSize(width: 680, height: 580), onboarding(model(), .tryIt, practice: sampleEntries.last!.final)),
                ("onboarding-5-hands-free", CGSize(width: 680, height: 580), onboarding(model(), .handsFree, practice: sampleEntries.last!.final)),
                ("onboarding-5-hands-free-waiting", CGSize(width: 680, height: 580), onboarding(model(entries: []), .handsFree)),
                ("onboarding-6-controls", CGSize(width: 680, height: 580), onboarding(model(), .controls)),
                ("onboarding-7-done", CGSize(width: 680, height: 580), onboarding(model(), .done)),
                ("about", CGSize(width: 320, height: 380), AnyView(AboutView())),
                ("credits", CGSize(width: 560, height: 520), AnyView(CreditsView {})),
                ("hud-positioning", CGSize(width: 640, height: 200), AnyView(hudPositioning())),
                ("info-popover-speech-model", CGSize(width: 820, height: 560), AnyView(infoPopover(model(), .speechModel))),
                ("info-popover-noise", CGSize(width: 820, height: 560), AnyView(infoPopover(model(), .noiseReduction))),
                ("settings-noisy-room", CGSize(width: 1000, height: 700),
                 settingsShot(model(), .microphone, name: "settings-noisy-room", noisyRoom: true)),
                ("history-playback", CGSize(width: 1000, height: 900),
                 main(model({ $0.clipIDs = clipIDs; $0.playingID = playingEntry.id }), .history)),
                ("history-detail", CGSize(width: 760, height: 520),
                 detailShot(HistoryDetailView(model: model({ $0.clipIDs = clipIDs
                     $0.retranscription = .done(.parakeetUltra, "The cooper netties cluster is healthy again. Root cause was an expired certificate on the ingress.") }),
                                           entry: detailEntry))),
                ("history-detail-preparing", CGSize(width: 760, height: 470),
                 detailShot(HistoryDetailView(model: model({ $0.clipIDs = clipIDs; $0.retranscription = .preparing(.parakeetUltra) }),
                                           entry: detailEntry))),
                ("history-detail-no-clip", CGSize(width: 760, height: 470),
                 detailShot(HistoryDetailView(model: model(), entry: detailEntry))),
                ("history-detail-outcome-only", CGSize(width: 760, height: 300),
                 detailShot(HistoryDetailView(model: model(), entry: refusedEntry))),
                ("menu-normal", CGSize(width: 420, height: 330), menuMock("normal (ready)", MenuSnapshot())),
                ("menu-mic-ready", CGSize(width: 420, height: 370),
                 menuMock("attention: Mic Ready", MenuSnapshot(micReady: .window(secondsLeft: 42)))),
                ("menu-holding-off", CGSize(width: 560, height: 370),
                 menuMock("attention: holding off for Wispr Flow", MenuSnapshot(holdingOffForWisprFlow: true))),
                ("menu-indicator-hidden", CGSize(width: 480, height: 370),
                 menuMock("attention: Indicator Hidden — Show", MenuSnapshot(indicatorHidden: true))),
                ("settings-microphone-check-ok", CGSize(width: 1000, height: 700),
                 settingsShot(model(entries: gatingEntries(bad: 0, of: 3)), .microphone, name: "settings-microphone-check-ok", noiseReduction: true)),
                ("settings-microphone-check-cutting-out", CGSize(width: 1000, height: 700),
                 settingsShot(model(entries: gatingEntries(bad: 2, of: 3)), .microphone, name: "settings-microphone-check-cutting-out", noiseReduction: true)),
                ("settings-writing-app-override", CGSize(width: 1000, height: 700), settingsShot(model(), .writing, name: "settings-writing-app-override", expanded: true, override: true)),
                ("dictionary-words-learned", CGSize(width: 1000, height: 760), main(model({ $0.learnedWords = 4 }), .dictionary)),
                ("fix-word-sheet", CGSize(width: 440, height: 440), AnyView(fixWordSheet(model()))),
                ("history-detail-long", CGSize(width: 760, height: 600),
                 detailShot(HistoryDetailView(model: model({ $0.clipIDs = [longEntry.id] }), entry: longEntry))),
                ("history-detail-long-comparison", CGSize(width: 760, height: 600),
                 detailShot(HistoryDetailView(model: model({ $0.clipIDs = [longEntry.id]
                     $0.retranscription = .done(.parakeetUltra, longEntry.final) }), entry: longEntry))),
                ("history-detail-long-no-clip", CGSize(width: 760, height: 420),
                 detailShot(HistoryDetailView(model: model(), entry: longEntry))),
                ("fix-word-long", CGSize(width: 440, height: 440),
                 wordShot(FixWordSheet(model: model(), entry: longEntry) {})),
                ("fix-word-long-identifier", CGSize(width: 440, height: 440),
                 wordShot(FixWordSheet(model: model(), entry: longIdentifierEntry) {})),
                ("compact-home", CGSize(width: 820, height: 1100), main(model(), .home)),
                ("compact-home-new-user", CGSize(width: 820, height: 2200), main(model({ $0.showGettingStarted = true }), .home)),
                ("compact-home-needs-permission", CGSize(width: 820, height: 900),
                 main(model({ $0.granted[.inputMonitoring] = false; $0.health = .missing([.inputMonitoring]) }), .home)),
                ("compact-insights", CGSize(width: 820, height: 1800), main(model(), .insights)),
                ("compact-settings", CGSize(width: 820, height: 560), settingsShot(model(), .general, name: "compact-settings")),
                ("compact-settings-microphone", CGSize(width: 820, height: 560), settingsShot(model(), .microphone, name: "compact-settings-microphone", noisyRoom: true)),
                ("compact-settings-writing", CGSize(width: 820, height: 560), settingsShot(model(), .writing, name: "compact-settings-writing", expanded: true, override: true)),
                ("compact-settings-privacy", CGSize(width: 820, height: 560), settingsShot(model(), .privacy, name: "compact-settings-privacy")),
                ("compact-settings-remote", CGSize(width: 820, height: 560), settingsShot(model(), .remote, name: "compact-settings-remote")),
                ("compact-settings-setup", CGSize(width: 820, height: 560), settingsShot(model({ $0.granted = [:]; $0.health = .stalePermission; $0.model = .preparing(since: nil) }), .general, name: "compact-settings-setup")),
                ("compact-history", CGSize(width: 820, height: 1100), main(model(), .history)),
                ("compact-dictionary", CGSize(width: 820, height: 900), main(model(), .dictionary)),
                ("compact-snippets", CGSize(width: 820, height: 1000), main(model(), .snippets)),
                ("compact-help", CGSize(width: 820, height: 4000), main(model(), .help)),
            ]
            for (name, size, view) in shots {
                if let only, !name.hasPrefix(only) { continue }
                let file = dir.appendingPathComponent("\(name)-\(mode).png")
                if snapshot(view, size: size, dark: dark, to: file) { written.append(file.lastPathComponent) }
                if benchmarking { return }
                let limits = ["settings": 5, "settings-microphone": 4, "settings-writing": 5, "settings-privacy": 4, "settings-remote": 1]
                let defaults = Set(limits.keys)
                if name.contains("settings"), let h = heights[name] {
                    print("\(name)-\(mode): content \(Int(ceil(h.content))) pt / viewport \(Int(floor(h.viewport))) pt; \(rowCounts[name] ?? 0) preference rows")
                    if let limit = limits[name], (rowCounts[name] ?? 0) != limit {
                        print("UI preview failed: \(name)-\(mode) must have exactly \(limit) default preference rows.")
                        exit(1)
                    }
                    if defaults.contains(name), h.viewport <= 0 || h.content > h.viewport + 1 {
                        print("UI preview failed: \(name)-\(mode) default content exceeds its viewport.")
                        exit(1)
                    }
                } else if defaults.contains(name) {
                    print("UI preview failed: no height measurement for \(name)-\(mode).")
                    exit(1)
                }
            }
        }
        UserDefaults().removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: dictURL)
        print("UI preview: \(written.count) PNGs written to \(dir.path)")
    }

    private static func settingsShot(_ base: AppModel, _ tab: SettingsSection, name: String,
                                     expanded: Bool = false, override: Bool = false,
                                     noisyRoom: Bool = false, noiseReduction: Bool = false, popover: Bool = false) -> AnyView {
        let suite = "wisprlocal-ui-preview-" + name
        UserDefaults().removePersistentDomain(forName: suite)
        let defaults = UserDefaults(suiteName: suite)!
        let settings = AppSettings(defaults: defaults)
        settings.noisyRoomMode = noisyRoom
        settings.voiceProcessingEnabled = noiseReduction
        if name == "settings-microphone-check-ok" {
            precondition(MicAudioDiagnostics.warning(base.entries) == nil,
                         "Healthy microphone preview must retain the default caption, without warning tint.")
        }
        let m = AppModel(sample: base.sample, settings: settings, dictionary: base.dictionary, placement: base.placement,
                         entries: base.entries, defaults: defaults)
        m.section = .settings
        m.settingsTab = tab
        let styles = StyleSettingsStore(defaults: defaults)
        if override { styles.setOverride(.veryCasual, forBundleID: "com.tinyspeck.slackmacgap") }
        return AnyView(HStack(spacing: 0) {
            Sidebar(model: m, simulated: true).frame(width: 214).background(Theme.sidebarSimulated)
            Rectangle().fill(Theme.cardBorder).frame(width: 0.5)
            SettingsView(model: m, stylesExpanded: expanded, styleStore: styles, rows: { rowCounts[name] = $0.count }, measure: { content, viewport in
                heights[name] = (content, viewport)
            })
            .overlay(alignment: .topTrailing) {
                if popover { ReadyPopoverContent(model: m).background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
                    .fixedSize().padding(.top, Theme.Space.xxl + Theme.Space.xl + Theme.Space.m).padding(.trailing, Theme.Space.xl) }
            }
        }.tint(Theme.accent))
    }

    /// Same state with recordings explicitly turned OFF (own throwaway settings).
    private static func recordingsOffModel(_ base: AppModel) -> AppModel {
        let suite = "wisprlocal-ui-preview-recordings-off"
        UserDefaults().removePersistentDomain(forName: suite)
        let d = UserDefaults(suiteName: suite)!
        let settings = AppSettings(defaults: d)
        settings.keepDebugRecordings = false
        return AppModel(sample: base.sample, settings: settings, dictionary: base.dictionary, placement: base.placement,
                        entries: timelineEntries, defaults: d)
    }

    /// Same state, but a dictionary with no snippets (the Snippets hero).
    private static func emptySnippetsModel(_ base: AppModel) -> AppModel {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wisprlocal-ui-preview-dictionary-empty.json")
        try? FileManager.default.removeItem(at: url)
        let d = DictionaryStore(url: url)
        var dict = sampleDictionary
        dict.snippets = []
        try? d.update(dict)
        return AppModel(sample: base.sample, settings: base.settings, dictionary: d, placement: base.placement,
                        entries: sampleEntries, defaults: UserDefaults(suiteName: "wisprlocal-ui-preview")!)
    }

    private static func main(_ m: AppModel, _ s: MainSection, help: HelpView.Tab = .howTo) -> AnyView {
        m.section = s
        return AnyView(MainWindowView(model: m, animate: false, simulatedSidebar: true, helpTab: help))
    }

    /// Menu mock from the same `MenuModel.entries` the real menu renders (Ultra off).
    private static func menuMock(_ caption: String, _ snap: MenuSnapshot) -> AnyView {
        AnyView(MenuMock(caption: caption,
                         entries: MenuModel.entries(snap, noisyRoom: false),
                         icon: .resolve(snap)))
    }

    private static func detailShot(_ v: HistoryDetailView) -> AnyView {
        AnyView(v.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).background(Theme.windowBackground))
    }

    private static func wordShot(_ v: FixWordSheet) -> AnyView {
        AnyView(v.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).background(Theme.windowBackground))
    }

    private static func onboarding(_ m: AppModel, _ step: OnboardingView.Step, practice: String = "") -> AnyView {
        AnyView(OnboardingView(model: m, initialStep: step, animate: false, practiceText: practice) {})
    }


    /// An NSPopover lives in its own window, which an offscreen snapshot can't capture, so the
    /// popover is drawn by hand: the real `InfoPopoverContent` in a popover-like bubble under the
    /// Microphone group's ⓘ.
    private static func infoPopover(_ m: AppModel, _ topic: InfoTopic) -> some View {
        ZStack(alignment: .topLeading) {
            microphoneOnly(m, noisyRoom: false)
            InfoPopoverContent(topic: topic)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous).fill(.regularMaterial))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous).strokeBorder(Theme.cardBorder))
                .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
                .padding(.leading, topic == .speechModel ? 310 : 370).padding(.top, topic == .speechModel ? 196 : 142)
        }
    }

    /// Recent dictations with cut-out measurements: `bad` of the last `of` cutting out.
    private static func gatingEntries(bad: Int, of n: Int) -> [HistoryEntry] {
        sampleEntries.suffix(n).enumerated().map { i, e in
            var x = e
            x.zeroFraction = i < bad ? 0.11 : 0.002
            x.maxZeroRunMs = i < bad ? 420 : 30
            return x
        }
    }


    /// History › Fix a Word… with the misheard phrase already picked and the spelling typed.
    private static func fixWordSheet(_ m: AppModel) -> some View {
        let entry = HistoryEntry(timestamp: now.addingTimeInterval(-300), raw: "the cooper netties cluster is healthy again",
                                 final: "The cooper netties cluster is healthy again.", engine: "fluidaudio:v2", cleaner: "rules",
                                 audioDuration: 3.2, speechDuration: 2.6, frontmostApp: "com.tinyspeck.slackmacgap", outcome: .inserted)
        return FixWordSheet(model: m, entry: entry, initialSelection: 1...2, initialCorrect: "Kubernetes") {}
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Theme.windowBackground)
    }

    /// Own throwaway settings, so the toggle state doesn't leak into the other shots.
    private static func microphoneOnly(_ base: AppModel, noisyRoom: Bool, entries: [HistoryEntry] = []) -> some View {
        let suite = "wisprlocal-ui-preview-mic-\(noisyRoom)"
        UserDefaults().removePersistentDomain(forName: suite)
        let d = UserDefaults(suiteName: suite)!
        let settings = AppSettings(defaults: d)
        settings.noisyRoomMode = noisyRoom
        settings.voiceProcessingEnabled = true
        let m = AppModel(sample: base.sample, settings: settings, dictionary: base.dictionary, placement: base.placement,
                         entries: entries, defaults: d)
        return VStack(alignment: .leading, spacing: Theme.Space.l) {
            MicrophoneSettings(model: m)
            Spacer(minLength: 0)
        }
        .padding(Theme.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.windowBackground)
    }

    private static func hudPositioning() -> some View {
        let anim = HUDAnimator()
        var f = anim.step(t: 0, target: .recording(handsFree: false), bands: HUDController.idleBands(0), reduceMotion: false)
        for i in 1...120 { f = anim.step(t: Double(i) / 120, target: .recording(handsFree: false), bands: HUDController.idleBands(Double(i) / 120), reduceMotion: false) }
        return ZStack {
            LinearGradient(colors: Theme.previewBackdropHUD, startPoint: .topLeading, endPoint: .bottomTrailing)
            HUDFrameView(frame: f, positioning: .above, dragEnabled: true).environment(\.hudSimulatedMaterial, true)
        }
    }

    /// Hosts the view in an offscreen window (real AppKit controls render, unlike ImageRenderer).
    static func snapshot(_ view: AnyView, size: CGSize, dark: Bool, to url: URL) -> Bool {
        // Borderless so it may sit far off-screen (titled windows get pulled back on screen);
        // ordered in so SwiftUI actually renders, but never visible to the user.
        let cpuStart = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let wallStart = Date()
        let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -30_000, y: -30_000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
            .environment(\.colorScheme, dark ? .dark : .light))
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        window.setContentSize(size)
        window.orderFrontRegardless()
        window.setFrameOrigin(CGPoint(x: -30_000, y: -30_000))
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.45))
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        host.display()
        let cpuMs = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpuStart) / 1_000_000
        print("UI open \(url.deletingPathExtension().lastPathComponent): \(String(format: "%.2f", cpuMs)) ms main-thread CPU; \(String(format: "%.2f", Date().timeIntervalSince(wallStart) * 1_000)) ms wall (includes 450 ms settle)")
        if ProcessInfo.processInfo.environment["WISPRLOCAL_UI_BENCH"] == "1",
           url.lastPathComponent.hasPrefix("history-"), url.lastPathComponent == "history-light.png" {
            precondition(cpuMs < 150 * (Double(ProcessInfo.processInfo.environment["WISPRLOCAL_TIMING_SCALE"] ?? "1") ?? 1),
                         "History exceeded its main-thread CPU budget")
        }
        // Open-time benchmarking ends before bitmap export, which traverses even clipped
        // AppKit layers in an eager baseline and isn't part of opening the History screen.
        if benchmarking { return false }
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return false }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        do { try data.write(to: url); return true } catch { return false }
    }

    /// Seeded identities and timestamps make large-history measurements reproducible.
    nonisolated static let previewHistory: [HistoryEntry]? = {
        guard let raw = ProcessInfo.processInfo.environment["WISPRLOCAL_PREVIEW_HISTORY_COUNT"],
              let count = Int(raw), count >= 0 else { return nil }
        return (0..<count).map { i in
            let text = "Synthetic dictation \(i): the project review is ready."
            return HistoryEntry(id: HistoryEntry.legacyID(for: Data("preview-\(i)".utf8)),
                timestamp: now.addingTimeInterval(-Double(count - 1 - i) * 576), raw: text, final: text,
                engine: "fluidaudio:v2", cleaner: "rules", audioDuration: 4, speechDuration: 3, outcome: .inserted)
        }
    }()

    // MARK: sample data

    /// Friday 2 Oct 2026, 15:20 local.
    nonisolated static let now: Date = {
        var c = DateComponents(); c.year = 2026; c.month = 10; c.day = 2; c.hour = 15; c.minute = 20
        return Calendar.current.date(from: c)!
    }()

    /// Entries with a troubleshooting clip in the History shots (two recent rows have none).
    nonisolated static var clipIDs: Set<UUID> {
        Set(sampleEntries.filter { $0.timestamp < now.addingTimeInterval(-30 * 60) }.map(\.id))
    }
    /// The row shown mid-playback.
    nonisolated static var playingEntry: HistoryEntry { sampleEntries[sampleEntries.count - 4] }
    /// The cleaned-up dictation (filler removed, dictionary fix, punctuation) for the details shots.
    nonisolated static var detailEntry: HistoryEntry { sampleEntries[4] }

    /// Synthetic stress cases: no user dictation is copied into screenshots or source.
    nonisolated static let longEntry: HistoryEntry = {
        let sentence = "Review the animation and sound effects so every jump, slide and collision is easy to understand. "
        let text = String(repeating: sentence, count: 28) + "This is the end of the long dictation."
        return HistoryEntry(timestamp: now, raw: "um " + text, final: text, engine: "fluidaudio:ultra",
                            audioDuration: 126, speechDuration: 126, frontmostApp: "com.apple.TextEdit",
                            outcome: .inserted)
    }()

    nonisolated static let longIdentifierEntry: HistoryEntry = {
        let text = "Review " + String(repeating: "VeryLongIdentifier", count: 12) + " before saving."
        return HistoryEntry(timestamp: now, raw: text, final: text, outcome: .inserted)
    }()

    /// An outcome-only entry (SEC-2: no text, no clip).
    nonisolated static let refusedEntry: HistoryEntry = {
        var e = HistoryEntry(timestamp: now.addingTimeInterval(-600), engine: "fluidaudio:v2", cleaner: "rules",
                             audioDuration: 2.4, speechDuration: 1.8, frontmostApp: "com.apple.Safari", outcome: .blockedBySecureInput)
        e.rawWordCount = 4; e.voiceProcessingActive = true
        return e
    }()

    /// Sample entries plus a refused attempt (an outcome-only row), oldest first.
    nonisolated static var timelineEntries: [HistoryEntry] {
        (sampleEntries + [refusedEntry]).sorted { $0.timestamp < $1.timestamp }
    }
    /// The Home / History row drawn as hovered (it has a clip, so ▷ shows).
    nonisolated static var hoverEntry: HistoryEntry { sampleEntries[sampleEntries.count - 3] }

    /// ~26 weeks of realistic, deterministic history for Insights: activity that grows over
    /// time, a 12-day current streak, and a busier October than September.
    nonisolated static let insightsEntries: [HistoryEntry] = {
        var seed: UInt64 = 0x5EED_CAFE
        func rnd() -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(seed >> 11) / Double(1 << 53)
        }
        let apps: [(String, Double)] = [
            ("com.anthropic.claudefordesktop", 0.20), ("com.openai.chat", 0.12), ("com.todesktop.230313mzl4w4u92", 0.04),
            ("com.apple.dt.Xcode", 0.10), ("com.microsoft.VSCode", 0.06), ("com.apple.Terminal", 0.04),
            ("com.tinyspeck.slackmacgap", 0.13), ("com.apple.MobileSMS", 0.05),
            ("com.apple.mail", 0.08), ("com.microsoft.Outlook", 0.02),
            ("com.apple.Notes", 0.06), ("notion.id", 0.03), ("com.apple.TextEdit", 0.01),
            ("com.apple.Safari", 0.04), ("com.google.Chrome", 0.01), ("com.example.Unknown", 0.01),
        ]
        func pickApp() -> String {
            var r = rnd()
            for (a, w) in apps { r -= w; if r <= 0 { return a } }
            return apps[0].0
        }
        let pairs: [(String, String)] = [
            ("um can you refactor this function so it takes a config struct instead of five arguments",
             "Can you refactor this function so it takes a config struct instead of five arguments?"),
            ("the cooper netties deploy is green now so we can ship after lunch",
             "The Kubernetes deploy is green now, so we can ship after lunch."),
            ("thanks for the notes I'll send the revised plan by thursday",
             "Thanks for the notes. I'll send the revised plan by Thursday."),
            ("so we need, like, twenty five more test devices for the beta",
             "We need 25 more test devices for the beta."),
            ("Sounds good, see you at the standup.", "Sounds good, see you at the standup."),
            ("uh write a short summary of this thread with the open questions at the end",
             "Write a short summary of this thread with the open questions at the end."),
            ("Remember to book the train for Monday.", "Remember to book the train for Monday."),
            ("swift you eye previews are broken on the main branch you know since the last merge",
             "SwiftUI previews are broken on the main branch since the last merge."),
        ]
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        var out: [HistoryEntry] = []
        for back in stride(from: 182, through: 0, by: -1) {
            guard let day = cal.date(byAdding: .day, value: -back, to: today) else { continue }
            let growth = 1 - Double(back) / 200                  // more active lately
            let weekend = [1, 7].contains(cal.component(.weekday, from: day))
            var p = (weekend ? 0.25 : 0.62) * growth + 0.12
            if back <= 11 { p = 1 }                              // current streak
            if back == 12 { p = 0 }
            if (30...47).contains(back) { p = 1 }                 // longest streak so far: 18 days
            if back == 29 || back == 48 { p = 0 }
            guard rnd() < p else { continue }
            var n = Int(2 + rnd() * 9 * growth)
            for k in 0..<n {
                let (raw, final) = pairs[Int(rnd() * Double(pairs.count)) % pairs.count]
                let words = Double(HistoryStats.wordCount(final))
                let speech = words / (128 + rnd() * 40) * 60
                let t = day.addingTimeInterval(8.5 * 3600 + Double(k) * 1800 + rnd() * 1500)
                guard t < now.addingTimeInterval(-3600) else { continue }
                out.append(HistoryEntry(timestamp: t, raw: raw, final: final, engine: "fluidaudio:v2", cleaner: "rules",
                                        audioDuration: speech + 0.6, speechDuration: speech, frontmostApp: pickApp(), outcome: .inserted))
            }
        }
        return (out + sampleEntries).sorted { $0.timestamp < $1.timestamp }
    }()

    /// A self-test attempt where the words were heard but the focus moved.
    nonisolated static let firstTry: HistoryEntry = {
        HistoryEntry(timestamp: now.addingTimeInterval(-20), raw: "Hello WisprLocal", final: "Hello WisprLocal.", engine: "parakeet-ultra",
                     cleaner: "rules", audioDuration: 1.9, speechDuration: 1.3, frontmostApp: "com.apple.TextEdit", outcome: .focusChanged)
    }()

    nonisolated static let sampleDictionary = UserDictionary(
        vocabulary: ["Kubernetes", "Parakeet", "WisprLocal", "Acme Robotics", "SwiftUI", "Alex Rivera", "TestFlight", "OKRs"],
        replacements: [ReplacementRule(from: "cooper netties", to: "Kubernetes"),
                       ReplacementRule(from: "swift you eye", to: "SwiftUI"),
                       ReplacementRule(from: "wisp her local", to: "WisprLocal")],
        snippets: [Snippet(trigger: "my calendar link", expansion: "Here's a link to grab time with me: cal.example.com/sam"),
                   Snippet(trigger: "sign off", expansion: "Thanks,\nAlex")])

    nonisolated static let sampleEntries: [HistoryEntry] = {
        func e(_ minutesAgo: Double, _ app: String, _ text: String, raw: String? = nil, speech: Double, snippet: String? = nil) -> HistoryEntry {
            var x = HistoryEntry(timestamp: now.addingTimeInterval(-minutesAgo * 60), raw: raw ?? text, final: text,
                                 engine: "fluidaudio:v2", cleaner: snippet == nil ? "rules" : "snippet",
                                 audioDuration: speech + 0.6, speechDuration: speech,
                                 frontmostApp: app, outcome: .inserted)
            x.snippetTrigger = snippet
            x.voiceProcessingActive = true
            if minutesAgo < 60 { x.join = "ax:" + text }
            return x
        }
        let day = 24.0 * 60
        return [
            e(4 * day + 30, "com.apple.mail", "Hi Sam, thanks for the notes. I'll have the revised plan over by Thursday.", speech: 5.1),
            e(3 * day + 120, "com.apple.Notes", "Ideas for the offsite: a short demo of WisprLocal, then open questions on the roadmap.", speech: 6.4),
            e(2 * day + 15, "com.apple.Safari", "best noise cancelling microphone for podcasts", speech: 2.6),
            e(day + 300, "com.apple.mail", "Thanks,\nAlex", raw: "sign off", speech: 0.9, snippet: "sign off"),
            e(day + 45, "com.apple.TextEdit", "The Kubernetes cluster is healthy again. Root cause was an expired certificate on the ingress.",
              raw: "um the cooper netties cluster is healthy again root cause was an expired certificate on the ingress", speech: 6.8),
            e(day + 20, "com.apple.Notes", "Remember to book the train for Monday and pick up the parcel.", speech: 3.9),
            e(180, "com.apple.mail", "Hey team, quick update: the beta build is in TestFlight. Please try dictating in your usual apps and tell me what breaks.", speech: 8.2),
            e(95, "com.apple.dt.Xcode", "// Debounce the permission poll so it never runs more than once every two seconds.", speech: 4.6),
            e(41, "com.apple.Notes", "Groceries: oat milk, lemons, coffee beans and something for dinner on Saturday.", speech: 4.1),
            e(12, "com.apple.Safari", "Here's a link to grab time with me: cal.example.com/sam", raw: "my calendar link", speech: 1.2, snippet: "my calendar link"),
            e(3, "com.apple.TextEdit", "This is my first dictation, and it feels a lot faster than typing.", speech: 3.4),
        ]
    }()
}
#endif
