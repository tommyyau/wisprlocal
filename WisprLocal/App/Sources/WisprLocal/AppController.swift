import AppKit
import Observation
import WisprLocalCore

/// Composition root: owns every component and wires hotkey → pipeline → HUD.
@MainActor
@Observable
final class AppController {
    static let shared = AppController()

    let settings = AppSettings()
    /// Settings › Writing (per-app styles, backtrack); read live by the pipeline.
    let styles = StyleSettingsStore()
    let conflicts = ConflictDetector()
    /// Where the HUD pill sits (Settings › General).
    let hudPlacement = HUDPlacementStore()
    @ObservationIgnored let dictionary: DictionaryStore
    /// Smart dictionary: correction learning, context names (Settings › Writing).
    let smart: SmartDictionaryController
    @ObservationIgnored let recorder: AudioRecorder
    /// Reads `conflicts.flag` (lock-free) inside the tap: Wispr Flow priority.
    @ObservationIgnored let hotkey: GlobeKeyMonitor
    @ObservationIgnored private var coexistence: WisprFlowCoexistence!
    @ObservationIgnored let inserter = RoutingInserter()
    let pipeline: DictationPipeline
    /// Warm mic (first-word clipping fix): menu line, Settings › Microphone, privacy drops.
    let warmMic: WarmMicController
    @ObservationIgnored private var warmTimer: Timer?
    @ObservationIgnored private var warmObservers: [(NotificationCenter, NSObjectProtocol)] = []
    @ObservationIgnored private(set) var history: HistoryStore
    /// Opt-in troubleshooting clips (`<history id>.wav` + `.json`); shared by the pipeline,
    /// History playback and Settings › Privacy.
    @ObservationIgnored let recordings = DebugRecordingStore()
    /// History + clips, deleted together (History › Delete / Clear All, startup sweep).
    @ObservationIgnored private(set) var library: HistoryLibrary
    /// History playback (one clip at a time; stopped first whenever 🌐 is pressed).
    let playback: ClipPlayback
    /// History › details › "Re-transcribe with the other model" (writes nothing to History).
    let retranscription: Retranscription
    @ObservationIgnored private(set) var hud: HUDController!
    /// the small conveniences (Esc cancel, mouse trigger, sounds, auto-send — Settings › General; retention — Settings › Privacy; hide pill — right-click the pill).
    let convenienceSettings = ConvenienceSettings()
    @ObservationIgnored private(set) var conveniences: Conveniences!

    /// Apple Intelligence model state (Settings + onboarding); refreshed by `refreshStatus()`.
    private(set) var cleanupAvailability: CleanupModelAvailability = .other("checking")
    /// Live max FM timeout (Settings), read per cleanup call.
    @ObservationIgnored let cleanupMaxTimeout: LiveValue<Double>

    /// Model pre-warm start (non-nil while preparing) — onboarding/HUD show elapsed time.
    private(set) var prewarmStartedAt: Date?
    /// Accessibility / Input Monitoring health; polls every 2 s (and retries the event tap) while unhealthy.
    let permissions: PermissionMonitor
    var hotkeyActive: Bool { permissions.tapRunning }
    /// Settings › Microphone › Check your microphone is recording: 🌐 presses are ignored meanwhile.
    private(set) var micTestRunning = false
    /// Most recent inserted dictation (Home, History and onboarding "Try it").
    private(set) var lastDictation: HistoryEntry?
    /// Most recent attempt of any outcome (Home's self-test explains failures).
    private(set) var lastAttempt: HistoryEntry?
    /// Bumped on every history append so open screens reload.
    private(set) var historyRevision = 0
    @ObservationIgnored private var started = false
    @ObservationIgnored private var prewarmTask: Task<Void, Never>?
    /// One engine per bundled model; only the ACTIVE one is ever prepared (the other is unloaded).
    @ObservationIgnored private var transcribers: [ASRModelVariant: FluidAudioTranscriber] = [:]
    /// The model the pipeline is using now (menu footer, Settings › Microphone).
    private(set) var activeVariant: ASRModelVariant

    private init() {
        cleanupMaxTimeout = LiveValue(settings.aiCleanupMaxTimeout)
        dictionary = DictionaryStore(url: settings.dictionaryURL)
        smart = SmartDictionaryController(dictionary: dictionary)
        recorder = AudioRecorder(voiceProcessingEnabled: settings.voiceProcessingEnabled)
        history = HistoryStore(directory: settings.historyDirectory)
        library = HistoryLibrary(history: history, recordings: recordings)
        let flag = conflicts.flag
        let hotkey = GlobeKeyMonitor(holdingOff: { flag.isHoldingOff })
        self.hotkey = hotkey
        permissions = PermissionMonitor(probe: SystemPermissionProbe(startTap: { hotkey.start() }))
        let inserter = self.inserter
        let variant = Self.variant(noisyRoom: settings.noisyRoomMode)
        activeVariant = variant
        let engine = FluidAudioTranscriber(variant: variant)
        transcribers[variant] = engine
        let pipeline = DictationPipeline(
            audio: recorder,
            trimmer: SileroSpeechTrimmer(),
            transcriber: engine,
            dictionary: dictionary,
            cleaner: Self.makeCleaner(enabled: settings.aiCleanupEnabled, maxTimeout: cleanupMaxTimeout, dictionary: dictionary),
            gate: conflicts,
            inserterFor: { bundleID in
                (inserter.inserter(forBundleID: bundleID), inserter.router.strategy(forBundleID: bundleID))
            },
            history: library.index,
            frontmostApp: { FrontmostApp.current() },
            caretReader: AXCaretContextReader(policy: smart.contextProvider.readPolicy),
            debugRecordings: recordings)
        self.pipeline = pipeline
        smart.install(on: pipeline)
        pipeline.inputIsBuiltInMic = { InputDevices.defaultInputIsBuiltIn() }
        pipeline.micModeProvider = { MicMode.current }
        let styles = self.styles
        pipeline.styleFor = { styles.configuration.style(forBundleID: $0) }
        pipeline.backtrackEnabled = { styles.backtrackEnabled }
        let dictating: @MainActor () -> Bool = {
            switch pipeline.status {
            case .recording, .processing: return true
            default: return false
            }
        }
        playback = ClipPlayback(directory: recordings.directory, isDictating: dictating)
        // A separate engine instance per run, so releasing it never touches the pipeline's model.
        retranscription = Retranscription(makeTranscriber: { FluidAudioTranscriber(variant: $0) }, isDictating: dictating)
        let settings = self.settings, conflicts = self.conflicts
        warmMic = WarmMicController(audio: recorder,
                                    keepReady: { settings.keepMicReady }, alwaysReady: { settings.alwaysMicReady },
                                    isSecureInputActive: { SystemSecureInput().isSecureInputActive },
                                    isConflictActive: { conflicts.holdingOff })
    }

    /// Privacy drops for the warm mic: lock, sleep, fast user switch (re-armed only for
    /// "Always ready" once cleared), plus a 0.5 s tick for expiry, secure input and the conflict gate.
    private func startWarmMic() {
        let ws = NSWorkspace.shared.notificationCenter
        let dn = DistributedNotificationCenter.default()
        func on(_ c: NotificationCenter, _ n: Notification.Name, _ f: @escaping @MainActor (WarmMicController) -> Void) {
            let o = c.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let w = self?.warmMic { f(w) } }
            }
            warmObservers.append((c, o))
        }
        on(dn, Notification.Name("com.apple.screenIsLocked")) { $0.block(.screenLocked) }
        on(dn, Notification.Name("com.apple.screenIsUnlocked")) { $0.clear(.screenLocked) }
        on(ws, NSWorkspace.willSleepNotification) { $0.block(.sleep) }
        on(ws, NSWorkspace.didWakeNotification) { $0.clear(.sleep) }
        on(ws, NSWorkspace.sessionDidResignActiveNotification) { $0.block(.userSwitched) }
        on(ws, NSWorkspace.sessionDidBecomeActiveNotification) { $0.clear(.userSwitched) }
        // Common modes: keeps ticking while the menu is open (event tracking), so the menu's
        // "Mic Ready · 0:42" countdown is live.
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.warmMic.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        warmTimer = timer
        warmMic.start()
    }

    func setMicReadiness(_ value: MicReadiness) {
        value.apply(to: settings)
        warmMic.settingsChanged()
    }

    // MARK: engine / cleaner factories

    /// The "Noisy room / other languages" toggle picks the model (v2 off, Ultra on). Developers
    /// can force a variant with `WISPRLOCAL_ASR_VARIANT=v2|ultra` (dev only; overrides the
    /// toggle). A value persisted by the old model picker (`asrVariant`) is deliberately ignored.
    static func variant(noisyRoom: Bool) -> ASRModelVariant {
        ProcessInfo.processInfo.environment["WISPRLOCAL_ASR_VARIANT"].flatMap(ASRModelVariant.init(rawValue:))
            ?? .forMode(noisyRoom: noisyRoom)
    }

    private func engine(for v: ASRModelVariant) -> FluidAudioTranscriber {
        if let t = transcribers[v] { return t }
        let t = FluidAudioTranscriber(variant: v)
        transcribers[v] = t
        return t
    }

    /// "Noisy room / other languages (Parakeet Ultra)" toggle (menu bar + Settings). Persists the
    /// choice, then swaps engines in the background: dictations are refused with "Speech model
    /// still preparing…" until the new model is ready; the old one is unloaded first.
    func setNoisyRoom(_ on: Bool) {
        settings.noisyRoomMode = on
        let v = Self.variant(noisyRoom: on)
        guard v != activeVariant else { return }
        activeVariant = v
        flash(PipelineNotice.switchingModel(to: v))
        prewarmTask?.cancel()
        prewarmStartedAt = Date()
        hud.update()
        let started = ContinuousClock.now
        let switchTask = pipeline.switchTranscriber(to: engine(for: v))
        prewarmTask = Task {
            await switchTask.value
            guard !Task.isCancelled else { return }
            Log.info("model switch to \(v.rawValue): \(ContinuousClock.now - started) (ready=\(pipeline.modelReady))")
            prewarmStartedAt = nil
            hud.update()
        }
    }

    static func makeCleaner(enabled: Bool, maxTimeout: LiveValue<Double>, dictionary: DictionaryStore) -> TextCleaner {
        guard enabled else { return RuleCleaner() }
        return FoundationModelsCleaner(
            timeout: { words in FoundationModelsCleaner.adaptiveTimeout(words: words, maxSeconds: maxTimeout.value) },
            vocabulary: { dictionary.dictionary.vocabulary })
    }

    /// Re-read Apple Intelligence availability (cheap).
    func refreshStatus() {
        cleanupAvailability = SystemCleanupModel.currentAvailability
    }

    /// Persistent model-preparation error (HUD banner + menu), nil when the model is fine.
    var modelError: String? { pipeline.modelError }

    /// "Retry model preparation" (HUD banner / menu / onboarding).
    func retryModelPreparation() {
        prewarmTask?.cancel()
        prewarmStartedAt = Date()
        hud.update()
        prewarmTask = Task {
            await pipeline.retryModelPreparation()
            guard !Task.isCancelled else { return }
            prewarmStartedAt = nil
            hud.update()
        }
    }

    /// Live state for the menu's attention row and the menu-bar icon (`MenuModel`). Every field
    /// is read from the component that owns it; there is no cached status to go stale.
    var menuSnapshot: MenuSnapshot {
        let micReady: MenuSnapshot.MicReady? = switch warmMic.mode {
        case .off: nil
        case .always: .always
        case .window: .window(secondsLeft: warmMic.secondsLeft)
        }
        return MenuSnapshot(permissionNeeded: !permissions.health.isReady,
                            holdingOffForWisprFlow: conflicts.holdingOff,
                            modelFailed: modelError != nil,
                            modelLoading: pipeline.isModelLoading,
                            recording: pipeline.status.isRecording,
                            micReady: micReady,
                            indicatorHidden: convenienceSettings.isIndicatorHidden(now: Date()))
    }

    var menuBarIconState: MenuBarIconState { .resolve(menuSnapshot) }

    var statusText: String {
        if conflicts.holdingOff { return WisprFlowCopy.holdingOff }
        switch pipeline.status {
        case .ready:
            switch permissions.health {
            case .missing(let ps): return "Waiting for " + ps.map(\.title).joined(separator: " / ")
            case .stalePermission: return "Globe key inactive — stale permission"
            case .needsRelaunch where !hotkeyActive: return "Relaunch WisprLocal to activate the Globe key"
            default: return hotkeyActive ? "Ready — hold Globe to dictate" : "Waiting for Accessibility / Input Monitoring"
            }
        case .preparingModel: return "Preparing speech model…"
        case .recording(let hf): return hf ? "Recording (hands-free — press Globe to stop)" : "Recording…"
        case .processing: return "Processing…"
        case .error(let m): return "Error: \(m)"
        }
    }

    func start() {
        guard !started else { return }
        started = true
        hud = HUDController(controller: self)
        smart.showNotice = { [weak self] s in self?.hud.flashNotice(s) }   // not logged (may hold a word)
        smart.dismissNotice = { [weak self] s in self?.hud.dismissNotice(s) }
        hud.onChipEnded = { [weak self] s in self?.smart.chipEnded(s) }
        // Wispr Flow priority: fully passive while it runs (unless overridden), resume on quit.
        conflicts.differentShortcut = settings.wisprFlowUsesDifferentShortcut
        coexistence = WisprFlowCoexistence(conflicts: conflicts, warmMic: warmMic, pipeline: pipeline,
                                           resetGesture: { [weak self] in self?.hotkey.resetGesture() },
                                           showNotice: { [weak self] in self?.hud.flashConflict() })
        coexistence.install(monitor: hotkey)
        conflicts.start()
        if conflicts.holdingOff { coexistence.holdingOffChanged() }

        hotkey.consumeGlobeEvents = settings.consumeGlobeKey
        hotkey.onAction = { [weak self] action in
            guard let self else { return }
            // Playback never interferes with recording: 🌐 stops it (and any re-transcription) first.
            self.playback.handleHotkey(action)
            self.retranscription.handleHotkey(action)
            if self.micTestRunning, action == .startRecording { self.hotkey.resetGesture(); return }
            if action == .startRecording {
                self.hud.clearChips()  // the pill shows the mic is on; old chips are moot
                self.smart.dictationStarting()
            }
            self.pipeline.handle(action)
        }
        observeHistoryIndex()
        pipeline.onGestureReset = { [weak self] in self?.hotkey.resetGesture() }
        // BUG C: never lose a dictation — ⌃⌥⌘V pastes the last one again.
        hotkey.onPasteAgain = { [weak self] in
            guard let self else { return }
            Task { await self.pipeline.pasteLastAgain() }
        }
        // The paste waits for 🌐 to be physically up: hardware flags ∪ the monitor's own state
        // (the Fn poll can be blind on some Macs).
        if let paste = inserter.paste as? PasteInserter {
            let hotkey = self.hotkey
            paste.modifiersHeld = { PasteKeystroke.physicalModifiersHeld() || hotkey.isFnDown }
        }
        conveniences = Conveniences(app: self, settings: convenienceSettings)
        conveniences.install()
        pipeline.onNotice = { [weak self] msg in self?.flash(msg) }
        pipeline.onModelPrepareFailed = { [weak self] msg in self?.hud.showModelError(msg) }
        pipeline.onEntry = { [weak self] entry in
            guard let self else { return }
            if HistoryStats.counts(entry) { self.lastDictation = entry }
            self.lastAttempt = entry
            self.historyRevision &+= 1
            if entry.outcome == .blockedByConflict { self.coexistence.notice() }
            if entry.outcome == .transcriptionFailed || entry.outcome == .insertFailed {
                Log.info("notice: dictation failed")
                self.hud.flashNotice(entry.note ?? "Dictation failed", priority: .alert)
            }
            self.warmMic.dictationFinished()  // (re)starts the 60 s ready window
        }
        var previousHealth = permissions.health
        permissions.onChange = { [weak self] health in
            guard let self else { return }
            Log.info("permissions: \(health)")
            if health.offersRelaunch {
                self.hud.showPermissionNotice(health)
            } else if let notice = health.lossNotice(previous: previousHealth) {
                self.hud.flashNotice(notice, priority: .alert)
            }
            previousHealth = health
        }
        permissions.start()
        recorder.prepareInBackground()
        startWarmMic()
        refreshStatus()
        prewarm()

        if !settings.onboardingCompleted {
            WindowManager.shared.showOnboarding(controller: self)
        } else if !Permission.allCases.allSatisfy(\.isGranted) || !permissions.health.isReady {
            // Set up before, but something's missing now: the Settings › General panel says what.
            WindowManager.shared.model(for: self).settingsRequest = .setup
            WindowManager.shared.showMain(controller: self, section: .settings)
        }
    }

    @ObservationIgnored private var historyTask: Task<Void, Never>?

    private func observeHistoryIndex() {
        historyTask?.cancel()
        let index = library.index
        historyTask = Task { [weak self] in
            let changes = await index.changes()
            Task { await index.load() }
            for await change in changes {
                guard !Task.isCancelled, let self else { break }
                switch change {
                case .loadedRecent(let snapshot), .loadedAll(let snapshot), .appended(_, let snapshot),
                     .removed(_, let snapshot), .cleared(let snapshot):
                    if self.lastDictation == nil {
                        self.lastDictation = snapshot.page.entries.first(where: HistoryStats.counts)
                    }
                }
            }
        }
    }

    func stop() {
        playback.stop()
        warmMic.block(.quit)  // mic off and pre-roll zeroed before exit
        warmTimer?.invalidate(); warmTimer = nil
        for (c, o) in warmObservers { c.removeObserver(o) }
        warmObservers = []
        conveniences?.stop()
        hotkey.stop()
        conflicts.stop()
    }

    /// Relaunch so a freshly granted (or re-added) permission takes effect.
    func relaunch() {
        AppRelauncher.relaunch { [weak self] msg in self?.flash("Relaunch failed: \(msg)") }
    }

    /// Serialised: a new prewarm cancels the previous one; the pipeline's generation counter
    /// ignores a superseded completion, so `modelReady` always matches the current engine.
    func prewarm() {
        prewarmTask?.cancel()
        prewarmStartedAt = Date()
        hud.update()
        prewarmTask = Task {
            await pipeline.prepareModels()
            guard !Task.isCancelled else { return }
            prewarmStartedAt = nil
            hud.update()
        }
    }

    /// The mic self-test runs its own engine: drop the warm mic first and hold off dictation.
    func beginMicTest() {
        micTestRunning = true
        warmMic.stopNow()
    }

    func endMicTest() { micTestRunning = false }

    /// Transient HUD notice (model switch, errors). Deliberately NOT stored for the menu: the
    /// menu derives its status from live state (`menuSnapshot`), so nothing can go stale.
    func flash(_ message: String) {
        Log.info("notice: \(message)")
        hud.flashNotice(message)
    }

    // MARK: settings actions

    func setVoiceProcessing(_ on: Bool) {
        settings.voiceProcessingEnabled = on
        recorder.setVoiceProcessingEnabled(on)
    }

    func setConsumeGlobe(_ on: Bool) {
        settings.consumeGlobeKey = on
        hotkey.consumeGlobeEvents = on
    }

    /// Persisted "Wispr Flow uses a different shortcut" (Settings, menu, HUD notice).
    func setWisprFlowUsesDifferentShortcut(_ on: Bool) {
        settings.wisprFlowUsesDifferentShortcut = on
        conflicts.differentShortcut = on
    }

    /// "Use WisprLocal anyway": in memory only (resets when Wispr Flow quits or relaunches),
    /// after a confirmation that both apps may type the same words.
    func useWisprLocalAnyway() {
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = WisprFlowCopy.useAnyway + "?"
        alert.informativeText = WisprFlowCopy.useAnywayConfirmation
        alert.addButton(withTitle: WisprFlowCopy.useAnyway)
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { conflicts.useAnyway = true }
        hud.update()
    }

    func setHistoryDirectory(_ url: URL) {
        settings.historyDirectory = url
        history = HistoryStore(directory: url)
        library = HistoryLibrary(history: history, recordings: recordings)
        pipeline.history = library.index
        observeHistoryIndex()
        historyRevision &+= 1
    }

    func setAICleanup(enabled: Bool? = nil, maxTimeout: Double? = nil) {
        if let maxTimeout {
            // Live: the next cleanup call reads it (no cleaner rebuild needed).
            settings.aiCleanupMaxTimeout = min(10, max(2, maxTimeout))
            cleanupMaxTimeout.set(settings.aiCleanupMaxTimeout)
        }
        if let enabled {
            settings.aiCleanupEnabled = enabled
            pipeline.cleaner = Self.makeCleaner(enabled: enabled, maxTimeout: cleanupMaxTimeout, dictionary: dictionary)
        }
    }

    var activeVariantLabel: String { activeVariant.modeLabel }

    /// History changed outside a dictation (retention pruning): open screens reload.
    func historyDidChange() { historyRevision &+= 1 }
}
