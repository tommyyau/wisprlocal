import Foundation
import Observation

/// HUD listening cue while recording. A COLD engine start mutes the first ~0.13–0.6 s, so the
/// pill shows a dim "starting" dot until real audio arrives, teaching users to wait a beat. A
/// warm start (engine already running, pre-roll prepended) is `.live` immediately.
public enum RecordingCue: Sendable, Equatable {
    case starting, live

    /// Tap level (`rms × 8`, one ~21 ms buffer) that ends "starting": the buffer is above
    /// −70 dBFS (`AudioGatingMetrics.activeDBFS`). Any level > 0 was not enough: cold-start
    /// clips carry stray ±1 LSB blips 200–250 ms before audio really flows (2 of 8 cold clips,
    /// 2026-10-03), which flipped the cue to live while the mic was still muted.
    public static let liveLevel = Float(8 * pow(10, AudioGatingMetrics.activeDBFS / 20))
}

public enum PipelineStatus: Sendable, Equatable {
    case preparingModel
    case ready
    case recording(handsFree: Bool)
    case processing
    case error(String)

    public var isRecording: Bool { if case .recording = self { return true } else { return false } }
}

/// User-facing HUD messages (kept here so tests can assert them).
public enum PipelineNotice {
    public static let captureInterrupted = "Microphone disconnected — dictation stopped"
    public static let focusChanged = "Focus changed — text copied to clipboard"
    public static let modelPreparing = "Speech model still preparing…"
    /// Shown while the "Noisy room / other languages" toggle swaps the loaded model.
    public static func switchingModel(to v: ASRModelVariant) -> String {
        v == .parakeetUltra ? "Switching to Noisy room model…" : "Switching to English model…"
    }
    public static let secureInput = "Secure input active (password field) — dictation disabled"
    /// SEC-4: the paired receiver Mac has a password field focused; text was not inserted (the receiver refused it).
    public static let remoteSecureInput = "Remote Mac has a password field focused — not inserted"
    public static let asrTimedOut = "Transcription timed out — please try again"
    /// `NoTextPolicy`: the user spoke but no words came out. The HUD adds a "See why" button
    /// (opens the entry in History) to every notice starting with `didntCatchPrefix`.
    public static let didntCatchPrefix = "Didn't catch that"
    public static let didntCatchThat = "Didn't catch that — try again"
    /// Same, built-in mic in a loud place (plane, train): the honest fix is a headset mic.
    public static let didntCatchThatUseHeadset = "Didn't catch that — a headset mic helps in loud places"
    /// Shown only when verification found that the paste did not change the field.
    /// Unverifiable pastes stay quiet; the re-paste shortcut remains available either way.
    public static let pasteNotConfirmed = "Paste may not have landed · \(PasteAgainShortcut.display) to paste again"
    public static func cancelledTyping(typed: Int, total: Int) -> String {
        typed == 0 ? cancelled : "Cancelled — typed \(typed) of \(total) characters"
    }
    public static func insertionFailed(_ reason: String) -> String {
        let sentence = reason.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return "\(sentence). — text copied to clipboard"
    }
    public static let nothingToPasteAgain = "Nothing to paste again yet"
    /// Zero-gating tip (`ZeroGatingPolicy`), once per session.
    public static let micCuttingOut = ZeroGatingPolicy.tip
    /// P1.1 follow-up: a re-press inside the previous dictation's 200 ms capture tail is dropped.
    public static func modelUnavailable(_ m: String) -> String { "Speech model unavailable: \(m)" }
    public static func transcriptionFailed(_ m: String) -> String { "Transcription failed twice: \(m)" }
    public static let quickRepressDropped = "Too quick — previous dictation still finishing. Press again."
    /// CC-7: countdown shown from `recordingLimitWarning` before the recording cap.
    public static let recordingLimitPrefix = "Recording stops in "
    public static func recordingStopsIn(_ seconds: Int) -> String { "\(recordingLimitPrefix)\(seconds) s" }
}

/// Which FM formatter the pipeline uses in AUTO mode (setting OFF + list cues).
public enum AutoFormatterChoice {
    /// No auto formatting (rules only while the setting is OFF).
    case none
    /// Apple Foundation Models (`FoundationModelsCleaner`, dictionary vocabulary for the guard).
    case system
    case custom(TextCleaner)
}

/// Orchestrates: hotkey action → record → stop (+tail) → `process`, whose post-processing order is
/// FIXED (DESIGN.md › "Dictation pipeline order"; `PipelineOrderTests` pins it):
///  1. VAD trim                       2. ASR (timeout, one retry)
///  3. language gate (non-English skips 5–9; replacements still apply)
///  4. dictionary replacements        5. phonetic spelling snap to dictionary terms, then the
///                                       opt-in context-name snap (one `SpellingSnapper` pass)
///  6. snippets (whole utterance; a hit skips 7–9)
///  7. cleanup: RuleCleaner + spoken numbers (default) OR AI formatting (user / auto list cues),
///     dictionary re-applied after the model
///  8. backtrack (opt-in, on the cleaned text)   9. per-app style (first capital, final stop)
/// 10. gates (Wispr Flow conflict, secure input, focus)   11. smart join   12. insert
/// 13. auto-send (Shift at release)  14. learning watcher (`onInserted`) and the Undo offer
/// Esc / triple-tap cancel (`cancelDictation`) is checked after 1, after 2, after 7 and right
/// before 11, so a cancelled job never reaches 11–14; during 12 it cancels the paste (nothing typed
/// if Cmd-V wasn't posted yet), and after the paste it stops 13–14: no Return ever follows a
/// cancel (checked immediately before pressing it) and the HUD says "Already typed". Undo (`undoLastCorrection`) stops the
/// watcher first (`onInsertionSuperseded`), so putting the words back is never "learned".
/// All collaborators are injected (fakes in tests). Hotkey actions arrive asynchronously on the
/// main actor (never inside the event-tap callback).
@MainActor
@Observable
public final class DictationPipeline {
    public private(set) var status: PipelineStatus = .ready
    public private(set) var lastEntry: HistoryEntry?
    /// Latest mic level 0...1 for the HUD waveform.
    public private(set) var level: Float = 0
    public private(set) var modelReady = false
    /// Meaningful while recording (see `RecordingCue`).
    public private(set) var recordingCue: RecordingCue = .live

    @ObservationIgnored public private(set) var transcriber: Transcriber
    @ObservationIgnored public var cleaner: TextCleaner
    @ObservationIgnored public var history: HistoryWriting
    /// MAXIMUM capture after Fn-up so the last word isn't clipped. 400 ms: history showed speech
    /// running to the very last sample with 200 ms ("at the moment" → "on the mount"). The tail is
    /// ADAPTIVE (`captureTailPolicy`): it ends after 120 ms of silence, but never before 150 ms.
    @ObservationIgnored public var captureTail: Duration = DictationPipeline.defaultCaptureTail
    public static let defaultCaptureTail: Duration = .milliseconds(400)
    public static let minimumCaptureTail: Duration = .milliseconds(150)
    public static let tailSilence: Duration = .milliseconds(120)
    /// false = always capture the full `captureTail`.
    @ObservationIgnored public var adaptiveTail = true
    public var captureTailPolicy: CaptureTailPolicy {
        adaptiveTail ? CaptureTailPolicy(minimum: min(Self.minimumCaptureTail, captureTail), maximum: captureTail,
                                         silence: Self.tailSilence)
                     : .fixed(captureTail)
    }
    /// AUTO formatting: the FM formatter used for list-cue utterances while the user's
    /// "AI formatting" setting is OFF (`cleaner` is the RuleCleaner). See `CleanupPolicy`.
    @ObservationIgnored public var autoFormatter: TextCleaner?
    @ObservationIgnored public var asrTimeout: Duration = .seconds(15)
    /// CC-7 (STRUCTURAL) recording caps, measured from the start of the recording. At the cap
    /// the recording is committed (as on a release); from `recordingLimitWarning` before it the
    /// HUD counts down once a second. The recorder's own 10-min buffer limit stays as a backstop.
    @ObservationIgnored public var holdRecordingLimit: Duration = DictationPipeline.defaultHoldRecordingLimit
    @ObservationIgnored public var handsFreeRecordingLimit: Duration = DictationPipeline.defaultHandsFreeRecordingLimit
    @ObservationIgnored public var recordingLimitWarning: Duration = .seconds(15)
    public static let defaultHoldRecordingLimit: Duration = .seconds(5 * 60)
    public static let defaultHandsFreeRecordingLimit: Duration = .seconds(10 * 60)
    @ObservationIgnored private var limitTask: Task<Void, Never>?
    @ObservationIgnored private var recordingStartedAt: Duration?
    /// Time source for the recording-cap countdown and the ASR timeout (tests inject a `ManualClock`).
    @ObservationIgnored public var pipelineClock: PipelineClock = SystemPipelineClock()

    @ObservationIgnored private let audio: AudioCapturing
    @ObservationIgnored private let trimmer: SpeechTrimmer
    @ObservationIgnored private let dictionary: DictionaryStore
    @ObservationIgnored private let gate: InsertionGate
    @ObservationIgnored private let secureInput: SecureInputChecking
    @ObservationIgnored private let clipboard: ClipboardWriting
    @ObservationIgnored private let inserterFor: @MainActor (String?) -> (TextInserter, InsertionStrategy)
    @ObservationIgnored private let frontmostApp: @MainActor () -> FrontmostApp?
    @ObservationIgnored private var chain: Task<Void, Never>?
    /// Detached debug-recording writes, chained so tests can await them (`flushDebugRecordings`).
    @ObservationIgnored private var debugSaveChain: Task<Void, Never>?
    @ObservationIgnored private var pendingJobs = 0
    @ObservationIgnored private var finishingCapture = false
    @ObservationIgnored private var recordingTarget: FrontmostApp?
    @ObservationIgnored private var prepareGeneration = 0
    /// The engine a recording STARTED on: its utterance is transcribed by that engine even if the
    /// mode is switched mid-recording (never mix models within one dictation).
    @ObservationIgnored private var recordingTranscriber: Transcriber?
    @ObservationIgnored private var recordingCapture = CaptureInfo()
    /// Mode switches run one after another; a superseded switch skips its prepare.
    @ObservationIgnored private var switchChain: Task<Void, Never>?
    @ObservationIgnored private var switchGeneration = 0
    /// English-only cleanup gate (`CleanupLanguagePolicy`).
    @ObservationIgnored public var languageDetector: LanguageDetecting
    /// Smart join: reads the text before the caret (AX); fakes in tests.
    @ObservationIgnored private let caretReader: CaretContextReading
    /// Our previous successful insertion (fallback join context when AX can't read the field).
    @ObservationIgnored public private(set) var lastInsertion: LastInsertion?
    @ObservationIgnored private var lastDictationText: String?
    /// The current input is the Mac's built-in mic (nil = unknown): picks the headset advice in
    /// the "Didn't catch that" notice. Set by the app.
    @ObservationIgnored public var inputIsBuiltInMic: @MainActor () -> Bool? = { nil }
    /// macOS Mic Mode at recording start (history `micMode`). Set by the app.
    @ObservationIgnored public var micModeProvider: @MainActor () -> String? = { nil }
    /// The zero-gating tip has been shown this session (`ZeroGatingPolicy`: once per session).
    @ObservationIgnored public private(set) var gatingTipShown = false
    /// This session's recent gating measurements, oldest → newest (`ZeroGatingPolicy.shouldWarn`).
    @ObservationIgnored public private(set) var recentGating: [AudioGatingMetrics] = []
    /// The entry the latest "Didn't catch that" notice is about ("See why" opens it).
    @ObservationIgnored public private(set) var lastNoTextEntryID: UUID?
    /// Opt-in troubleshooting recordings (no-op unless the Settings toggle is on).
    @ObservationIgnored private let debugRecordings: DebugRecordingStore?
    @ObservationIgnored public var currentDate: @MainActor () -> Date = { Date() }
    /// Per-app writing style for the target's bundle ID (`FinalPasses`); nil = no style. The app
    /// wires Settings › Writing here; the default (no style) keeps the pipeline verbatim.
    @ObservationIgnored public var styleFor: @MainActor (String?) -> WritingStyle? = { _ in nil }
    /// Backtrack ("2, actually 3" → "3"). OFF unless the app wires the user's opt-in.
    @ObservationIgnored public var backtrackEnabled: @MainActor () -> Bool = { false }
    @ObservationIgnored public var nameRecognizer: NameRecognizing = NLNameRecognizer()
    /// The latest inserted backtrack, undoable from the HUD (`undoLastCorrection`).
    @ObservationIgnored public private(set) var pendingCorrection: PendingCorrection?
    /// Posts the target app's Undo (⌘Z). Injectable for tests.
    @ObservationIgnored public var postUndo: @MainActor () throws -> Void = { try UndoKeystroke.post() }
    /// Pause between ⌘Z and the paste of the original, so the app has applied the undo.
    @ObservationIgnored public var undoSettle: Duration = .milliseconds(80)

    // MARK: conveniences (Esc / triple-tap cancel, feedback sounds, Shift-Return auto-send)
    /// Start/stop sounds; nil = off (Settings › General). Never captured: `SoundExclusion`.
    @ObservationIgnored public var feedbackSounds: FeedbackSoundPlaying?
    /// Read at commit: Shift was held on the event that ended the dictation AND auto-send is on.
    @ObservationIgnored public var autoSendRequested: @MainActor () -> Bool = { false }
    @ObservationIgnored public var returnKey: ReturnKeyPosting = SystemReturnKey()
    /// Pause between the posted paste and Return, so the app has taken the paste first.
    @ObservationIgnored public var autoSendDelay: Duration = .milliseconds(120)
    /// Longest a triple-tap hold may delay an insertion (backstop for a lost release).
    @ObservationIgnored public var insertionHoldLimit: Duration = .seconds(1)
    @ObservationIgnored private var soundExclusion: SoundExclusion?
    @ObservationIgnored private var lastStopSound: ClosedRange<Duration>?
    @ObservationIgnored private var jobSeq = 0
    @ObservationIgnored private var cancelledThrough = 0
    @ObservationIgnored private var lastCommittedSeconds: Double = 0
    @ObservationIgnored public private(set) var insertionHeld = false
    @ObservationIgnored private var holdWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var holdBackstop: Task<Void, Never>?
    /// Focused element + window of the target (AX, off the main actor). Read at recording start
    /// and again right before an auto-send Return (R3), and after a backtrack paste for Undo (R5).
    @ObservationIgnored public var focusProbe: FocusProbing = AXFocusProbe()
    @ObservationIgnored private var recordingFocus: Task<FocusSnapshot?, Never>?
    /// The paste in flight (cancelled by Esc / triple-tap) and whose job it is.
    @ObservationIgnored private var insertTask: Task<Void, Error>?
    @ObservationIgnored private var insertingJob: (job: Int, autoSend: Bool)?
    /// Smart dictionary: opt-in context names (nil = off). Read at recording START for the
    /// target app and held IN MEMORY for that one dictation (`ContextProvider`).
    @ObservationIgnored public var contextProvider: ContextProviding?
    /// Smart dictionary: what the user deleted (`LearningStore` tombstones, lowercased). The
    /// spelling snapper never offers those terms nor rewrites those heard forms.
    @ObservationIgnored public var snapperTombstones: @MainActor () -> Set<String> = { [] }
    @ObservationIgnored private var recordingContext: Task<ContextSnapshot?, Never>?
    /// Smart dictionary: a paste succeeded (the correction watcher may start). In memory only.
    @ObservationIgnored public var onInserted: ((InsertedDictation) -> Void)?
    /// The text `onInserted` reported is about to be replaced BY US (backtrack Undo). The learning
    /// watcher must stop first: our ⌘Z + re-paste is not a user correction.
    @ObservationIgnored public var onInsertionSuperseded: (() -> Void)?

    /// Recorder auto-stopped (max duration) or refused: the hotkey gesture must be reset.
    @ObservationIgnored public var onGestureReset: (() -> Void)?
    /// Each finished utterance.
    @ObservationIgnored public var onEntry: ((HistoryEntry) -> Void)?
    /// A dictation was refused at key-down because WisprLocal is holding off for Wispr Flow.
    @ObservationIgnored public var onBlockedByConflict: (() -> Void)?
    /// Short HUD message.
    @ObservationIgnored public var onNotice: ((String) -> Void)?
    /// Model preparation failed (message): the app shows a persistent error with a
    /// "Retry model preparation" action. Also re-sent when a dictation is attempted meanwhile.
    @ObservationIgnored public var onModelPrepareFailed: ((String) -> Void)?

    /// Non-nil while the speech model is unusable (prepare failed).
    public var modelError: String? { if case .error(let m) = status, !modelReady { return m } else { return nil } }

    /// The speech model is loading right now (start-up, mode switch, retry). DERIVED from the
    /// model state, never a sticky flag: it ends the moment the current engine is ready OR has
    /// failed, and a superseded switch can't leave it set (`modelReady` follows the latest engine).
    public var isModelLoading: Bool { !modelReady && modelError == nil }

    public init(audio: AudioCapturing, trimmer: SpeechTrimmer, transcriber: Transcriber,
                dictionary: DictionaryStore, cleaner: TextCleaner, gate: InsertionGate,
                secureInput: SecureInputChecking = SystemSecureInput(),
                clipboard: ClipboardWriting = SystemClipboard(),
                inserterFor: @escaping @MainActor (String?) -> (TextInserter, InsertionStrategy),
                history: HistoryWriting, frontmostApp: @escaping @MainActor () -> FrontmostApp?,
                caretReader: CaretContextReading = AXCaretContextReader(),
                debugRecordings: DebugRecordingStore? = DebugRecordingStore(),
                autoFormatter: AutoFormatterChoice = .system,
                languageDetector: LanguageDetecting = NLLanguageDetector()) {
        self.caretReader = caretReader
        self.languageDetector = languageDetector
        switch autoFormatter {
        case .none: self.autoFormatter = nil
        case .custom(let c): self.autoFormatter = c
        case .system:
            self.autoFormatter = FoundationModelsCleaner(vocabulary: { [dictionary] in dictionary.dictionary.vocabulary })
        }
        self.debugRecordings = debugRecordings
        self.audio = audio; self.trimmer = trimmer; self.transcriber = transcriber
        self.dictionary = dictionary; self.cleaner = cleaner; self.gate = gate
        self.secureInput = secureInput; self.clipboard = clipboard
        self.inserterFor = inserterFor; self.history = history; self.frontmostApp = frontmostApp
        audio.onLevel = { [weak self] l in
            guard let self else { return }
            self.level = l
            if l >= RecordingCue.liveLevel, self.recordingCue == .starting { self.recordingCue = .live }
        }
        audio.onCaptureInterrupted = { [weak self] _ in
            guard let self, self.status.isRecording else { return }
            self.commit(autoSendAllowed: false, captureInterrupted: true)
            self.onGestureReset?()
            self.onNotice?(PipelineNotice.captureInterrupted)
        }
        audio.onMaxDurationReached = { [weak self] in
            guard let self, self.status.isRecording else { return }
            self.commit(autoSendAllowed: false)
            self.onGestureReset?()
        }
    }

    /// Swap the ASR engine. Any in-flight `prepareModels()` for the old engine is ignored when
    /// it finishes (generation counter), so `modelReady` always describes the current engine.
    public func setTranscriber(_ t: Transcriber) {
        transcriber = t
        prepareGeneration += 1
        modelReady = false
        if !status.isRecording && pendingJobs == 0 { status = .preparingModel }
    }

    /// Mode switch ("Noisy room / other languages"): from now on dictations are refused with
    /// `modelPreparing` until `new` is ready. Work that started on the old engine (a recording in
    /// progress, queued jobs) finishes on it; THEN the old engine is unloaded and only then is the
    /// new one prepared, so at most one model is resident (apart from those in-flight jobs).
    /// Rapid toggles are serialised; only the last switch prepares. Returns the switch task.
    @discardableResult
    public func switchTranscriber(to new: Transcriber) -> Task<Void, Never> {
        let old = transcriber
        setTranscriber(new)
        switchGeneration += 1
        let gen = switchGeneration
        let previous = switchChain
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            while self.status.isRecording || self.pendingJobs > 0 || self.finishingCapture {
                try? await Task.sleep(for: .milliseconds(50))
            }
            await old.unload()
            guard gen == self.switchGeneration else { return }  // a newer switch prepares its own engine
            await self.prepareModels()
        }
        switchChain = task
        return task
    }

    /// Load VAD + ASR (first-ever ASR load compiles for the ANE, 30–60 s).
    public func prepareModels() async {
        prepareGeneration += 1
        let gen = prepareGeneration
        let t = transcriber
        modelReady = false
        if !status.isRecording && pendingJobs == 0 { status = .preparingModel }
        do {
            try await trimmer.prepare()
            try await t.prepare()
            guard gen == prepareGeneration else { return }  // superseded
            modelReady = true
            if !status.isRecording { settleStatus() }
        } catch {
            guard gen == prepareGeneration else { return }
            let msg = error.localizedDescription
            Log.error("Model preparation failed: \(msg)")
            status = .error(msg)
            onModelPrepareFailed?(msg)
        }
    }

    /// User action: "Retry model preparation".
    public func retryModelPreparation() async {
        await transcriber.reset()
        await prepareModels()
    }

    public func handle(_ action: HotkeyStateMachine.Action) {
        switch action {
        case .startRecording:
            guard !status.isRecording else { return }
            // Wispr Flow priority (STRUCTURAL): a live check at key-down. While holding off, the
            // mic never opens and nothing is transcribed (the insert-time gate is the backstop).
            if gate.insertionBlockReason() != nil {
                onBlockedByConflict?()
                onGestureReset?()
                return
            }
            guard !finishingCapture else {
                onNotice?(PipelineNotice.quickRepressDropped)
                onGestureReset?()
                return
            }
            guard modelReady else {
                if case .error(let m) = status {
                    onNotice?(PipelineNotice.modelUnavailable(m))
                    onModelPrepareFailed?(m)
                } else { onNotice?(PipelineNotice.modelPreparing) }
                onGestureReset?()
                return
            }
            guard !secureInput.isSecureInputActive else {
                onNotice?(PipelineNotice.secureInput)
                onGestureReset?()
                return
            }
            pendingCorrection = nil  // a new dictation ends the previous Undo offer (its chip goes too)
            recordingTarget = frontmostApp()  // focus guard: target fixed at START
            recordingTranscriber = transcriber  // engine fixed at START too (mode switches)
            if let t = recordingTarget {
                let probe = focusProbe
                recordingFocus = Task { @MainActor in await probe.snapshot(pid: t.pid, precedingChars: 0) }
            } else { recordingFocus = nil }
            do {
                try audio.start()
                recordingCue = audio.lastStartWasWarm ? .live : .starting
                recordingCapture = CaptureInfo(warmStart: audio.lastStartWasWarm, micMode: micModeProvider())
                if let provider = contextProvider, let t = recordingTarget {
                    recordingContext = Task { @MainActor in await provider.snapshot(for: t) }  // after the mic is on
                } else { recordingContext = nil }
                status = .recording(handsFree: false)
                recordingStartedAt = pipelineClock.now
                armSoundExclusion()
                armRecordingLimit(handsFree: false)
                cleaner.prepareForDictation()  // fresh LLM session, prewarmed while the user speaks
                if !userFormattingEnabled { autoFormatter?.prepareForDictation() }  // used only on list cues
            } catch {
                status = .error(error.localizedDescription)
                onGestureReset?()
            }
        case .enterHandsFree:
            if status.isRecording {
                status = .recording(handsFree: true)
                armRecordingLimit(handsFree: true)
            }
        case .cancelRecording:
            guard status.isRecording else { return }
            disarmRecordingLimit()
            audio.cancel()  // speculative audio discarded; nothing is transcribed
            recordingContext = nil
            recordingFocus = nil
            recordingTarget = nil
            recordingTranscriber = nil
            soundExclusion = nil
            settleStatus()
        case .cancelDictation:
            cancelDictation()
        case .holdInsertion:
            holdInsertion()
        case .releaseInsertion:
            releaseInsertion()
        case .commitRecording:
            commit(autoSendAllowed: true)
        }
        if !status.isRecording { level = 0 }
    }

    /// The HUD's Done button finishes hands-free without stealing focus or sending a chat.
    /// A stale click after stopping, or during hold-to-talk, cannot commit another recording.
    @discardableResult
    public func finishHandsFree() -> Bool {
        guard status == .recording(handsFree: true) else { return false }
        onGestureReset?()
        commit(autoSendAllowed: false)
        return true
    }

    /// Stop and process. `autoSendAllowed` = a user release (not the recording cap).
    private func commit(autoSendAllowed: Bool, captureInterrupted: Bool = false) {
        guard status.isRecording else { return }
        let autoSend = autoSendAllowed && autoSendRequested()
        lastCommittedSeconds = activeRecordingSeconds ?? 0
        let exclusion = soundExclusion
        soundExclusion = nil
        disarmRecordingLimit()
        let target = recordingTarget
        recordingTarget = nil
        let engine = recordingTranscriber ?? transcriber
        recordingTranscriber = nil
        var capture = recordingCapture
        capture.interrupted = captureInterrupted
        capture.voiceProcessing = audio.captureVoiceProcessingActive
        capture.nameContext = recordingContext
        recordingContext = nil
        capture.focus = recordingFocus
        recordingFocus = nil
        let releasedAt = ContinuousClock.now
        finishingCapture = true
        let audio = self.audio, tail = captureInterrupted ? CaptureTailPolicy.fixed(.zero) : captureTailPolicy
        // Stop independently of the job chain so the mic turns off even if a job is queued.
        let stopTask = Task { @MainActor [weak self] in
            let samples = await audio.stop(adaptiveTail: tail)
            let ended = ContinuousClock.now
            self?.playStopSound()  // only once the capture has ended: never recorded
            return (exclusion?.apply(samples) ?? samples, ended)
        }
        enqueue(target: target, transcriber: engine, capture: capture, releasedAt: releasedAt, autoSend: autoSend) { [weak self] in
            let s = await stopTask.value
            self?.finishingCapture = false
            return s
        }
        if !status.isRecording { level = 0 }
    }

    // MARK: cancel (Esc, triple-tap)

    private func seconds(_ d: Duration) -> Double { Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18 }

    private var activeRecordingSeconds: Double? {
        guard status.isRecording, let started = recordingStartedAt else { return nil }
        return max(0, seconds(pipelineClock.now - started))
    }

    /// A WisprLocal dictation is in flight (recording, finishing its tail, or processing).
    public var isDictationActive: Bool { status.isRecording || pendingJobs > 0 || finishingCapture }

    /// Length of the active dictation (recording so far, or the recording being processed);
    /// nil when no dictation is active. Esc asks before discarding more than 30 s.
    public var activeDictationSeconds: Double? {
        if let s = activeRecordingSeconds { return s }
        return pendingJobs > 0 || finishingCapture ? lastCommittedSeconds : nil
    }

    /// Esc / triple-tap: discard the active dictation. Recording: the mic stops, the audio is
    /// dropped and History records `cancelled`. Processing: the job finishes as `cancelled`
    /// without inserting (checked before every step that could type). Returns whether there
    /// was anything to cancel. The HUD says "Cancelled".
    @discardableResult
    public func cancelDictation() -> Bool {
        if status.isRecording {
            let duration = activeRecordingSeconds ?? 0
            let target = recordingTarget
            disarmRecordingLimit()
            audio.cancel()
            recordingContext?.cancel()
            recordingContext = nil  // context names are dropped with the cancelled dictation
            recordingFocus = nil
            recordingTarget = nil
            recordingTranscriber = nil
            soundExclusion = nil
            level = 0
            let entry = HistoryEntry(engine: transcriber.engineName, cleaner: cleaner.name, audioDuration: duration,
                                     frontmostApp: target?.bundleID, outcome: .cancelled)
            history.append(entry)
            lastEntry = entry
            settleStatus()
            playStopSound()
            onEntry?(entry)
            onNotice?(PipelineNotice.cancelled)
            Log.info("dictation cancelled while recording")
            return true
        }
        guard pendingJobs > 0 || finishingCapture else { return false }
        cancelledThrough = jobSeq
        releaseInsertion()
        if insertingJob != nil {
            // R1: the paste is in flight. Stop it if it hasn't been posted; either way nothing
            // follows it (no Return, no Undo, no learning). The job says which happened
            // ("Cancelled" or "Already typed"), so the HUD and History agree.
            insertTask?.cancel()
            Log.info("dictation cancelled during insertion")
            return true
        }
        onNotice?(PipelineNotice.cancelled)
        Log.info("dictation cancelled while processing")
        return true
    }

    private func isCancelled(_ job: Int?) -> Bool { job.map { $0 <= cancelledThrough } ?? false }

    /// Triple-tap, second tap: queued dictations wait before typing until released (third tap
    /// cancels; the window ending releases; `insertionHoldLimit` is the backstop).
    public func holdInsertion() {
        insertionHeld = true
        holdBackstop?.cancel()
        let clock = pipelineClock, limit = insertionHoldLimit
        holdBackstop = Task { @MainActor [weak self] in
            try? await clock.sleep(until: clock.now + limit)
            guard !Task.isCancelled else { return }
            self?.releaseInsertion()
        }
    }

    public func releaseInsertion() {
        insertionHeld = false
        holdBackstop?.cancel(); holdBackstop = nil
        let waiters = holdWaiters
        holdWaiters = []
        for w in waiters { w.resume() }
    }

    private func waitWhileHeld() async {
        while insertionHeld { await withCheckedContinuation { holdWaiters.append($0) } }
    }

    // MARK: feedback sounds

    /// Plays the start sound (mic already running) and records what to cut from this capture:
    /// the start sound, plus a recent stop sound the warm pre-roll may still hold.
    private func armSoundExclusion() {
        let now = pipelineClock.now
        var windows: [ClosedRange<Duration>] = []
        if let last = lastStopSound { windows.append(last) }
        if let fs = feedbackSounds {
            fs.play(.start)
            windows.append(now...(now + fs.duration + SoundExclusion.margin))
        }
        let pre = audio.lastStartWasWarm ? MicWarmPolicy.samples(MicWarmPolicy.preRoll) : 0
        soundExclusion = windows.isEmpty ? nil : SoundExclusion(pressAt: now, liveStartIndex: pre, windows: windows)
    }

    private func playStopSound() {
        guard let fs = feedbackSounds else { return }
        let now = pipelineClock.now
        fs.play(.stop)
        lastStopSound = now...(now + fs.duration + SoundExclusion.margin)
    }

    private func disarmRecordingLimit() {
        limitTask?.cancel(); limitTask = nil
        recordingStartedAt = nil
    }

    /// (Re)arms the cap for the current mode; hands-free extends a hold that turned into it.
    private func armRecordingLimit(handsFree: Bool) {
        limitTask?.cancel()
        guard let started = recordingStartedAt else { return }
        let deadline = started + (handsFree ? handsFreeRecordingLimit : holdRecordingLimit)
        let warnAt = deadline - recordingLimitWarning
        let clock = pipelineClock
        limitTask = Task { @MainActor [weak self] in
            try? await clock.sleep(until: warnAt)
            while !Task.isCancelled {
                guard let self, self.status.isRecording else { return }
                let left = deadline - clock.now
                guard left > .zero else { break }
                let secs = Int((Double(left.components.seconds) + Double(left.components.attoseconds) / 1e18).rounded(.up))
                self.onNotice?(PipelineNotice.recordingStopsIn(max(1, secs)))
                let next = deadline - .seconds(max(0, secs - 1))
                try? await clock.sleep(until: next)
            }
            guard !Task.isCancelled, let self, self.status.isRecording else { return }
            Log.info("recording cap reached (\(handsFree ? "hands-free" : "hold")); committing")
            self.commit(autoSendAllowed: false)
            self.onGestureReset?()
        }
    }

    private func settleStatus() {
        if pendingJobs > 0 { status = .processing }
        else if case .error = status, !modelReady { /* keep */ }
        else { status = modelReady ? .ready : .preparingModel }
    }

    private func enqueue(target: FrontmostApp?, transcriber: Transcriber, capture: CaptureInfo, releasedAt: ContinuousClock.Instant,
                         autoSend: Bool = false,
                         samples: @escaping @MainActor () async -> ([Float], ContinuousClock.Instant)) {
        pendingJobs += 1
        jobSeq += 1
        let job = jobSeq
        status = .processing
        let previous = chain
        chain = Task { [weak self] in
            let (s, capturedAt) = await samples()
            await previous?.value
            guard let self else { return }
            let nameContext = await capture.nameContext?.value
            let entry = await self.process(samples: s, target: target, releasedAt: releasedAt, captureEndedAt: capturedAt,
                                           transcriber: transcriber, voiceProcessing: capture.voiceProcessing,
                                           warmStart: capture.warmStart, micMode: capture.micMode,
                                           autoSend: autoSend, job: job, nameContext: nameContext,
                                           startFocus: capture.focus, captureInterrupted: capture.interrupted)
            self.pendingJobs -= 1
            self.lastEntry = entry
            self.onEntry?(entry)
            if !self.status.isRecording { self.settleStatus() }
        }
    }

    /// The configured cleaner is the user's FM formatter ("AI formatting" ON).
    var userFormattingEnabled: Bool { !(cleaner is RuleCleaner) }

    var dictionaryForTesting: DictionaryStore { dictionary }
    static let rules = RuleCleaner()

    /// Wait for queued work (tests).
    public func drain() async { await chain?.value }

    /// Wait for the background debug-recording writes started so far (tests).
    public func flushDebugRecordings() async { await debugSaveChain?.value }

    /// True from key-up until the capture tail has finished (a new press is refused meanwhile).
    public var isFinishingCapture: Bool { finishingCapture }

    /// The full post-recording pipeline. Always returns (and logs) a history entry.
    /// `target` = frontmost app captured when recording started. `releasedAt` = key-up,
    /// `captureEndedAt` = when the capture tail ended (nil: samples given directly).
    public func process(samples: [Float], target: FrontmostApp?,
                        releasedAt: ContinuousClock.Instant = .now,
                        captureEndedAt: ContinuousClock.Instant? = nil,
                        transcriber engine: Transcriber? = nil,
                        voiceProcessing: Bool? = nil, warmStart: Bool? = nil,
                        micMode: String? = nil, autoSend: Bool = false, job: Int? = nil,
                        nameContext: ContextSnapshot? = nil,
                        startFocus: Task<FocusSnapshot?, Never>? = nil,
                        captureInterrupted: Bool = false) async -> HistoryEntry {
        let sr = AudioConstants.sampleRate
        let transcriber = engine ?? self.transcriber
        var entry = HistoryEntry(engine: transcriber.engineName, cleaner: cleaner.name,
                                 audioDuration: Double(samples.count) / sr, frontmostApp: target?.bundleID,
                                 outcome: .noSpeech)
        entry.voiceProcessingActive = voiceProcessing
        entry.warmStart = warmStart
        entry.micMode = micMode
        if captureInterrupted { entry.note = PipelineNotice.captureInterrupted }
        var timings = StageTimings()
        var keptSpeech: [Float]?
        // Content-free capture diagnostics (input level, zero-gating detector).
        let level = CaptureLevel.measure(samples, sampleRate: sr)
        entry.inputLevelDBFS = level.loudDBFS
        entry.noiseFloorDBFS = level.floorDBFS
        var gating = AudioGatingMetrics.none
        var gatingMeasured = false
        func measureGating(_ s: [Float]) {
            // Holes inside speech only: cold-start mute, its blips and fade-in, and trailing
            // silence are trimmed by the detector itself (warm or cold start alike).
            gating = AudioGatingMetrics.measure(s, sampleRate: sr)
            gatingMeasured = true
            entry.zeroFraction = gating.zeroFraction
            entry.maxZeroRunMs = gating.maxZeroRunMs
        }
        var noticeSent = false
        func notice(_ m: String) { noticeSent = true; onNotice?(m) }
        /// Esc / triple-tap cancelled this job: outcome-only `cancelled`, audio dropped.
        func cancelledNow() -> Bool {
            guard isCancelled(job) else { return false }
            entry.outcome = .cancelled
            entry.note = nil
            keptSpeech = nil
            noticeSent = true  // "Cancelled" was shown
            return true
        }
        pendingCorrection = nil  // a new dictation ends the previous Undo offer
        var uncorrected: String?
        // SEC-2 (STRUCTURAL): dictated text lives in `content`, NOT in `entry`, until the outcome
        // is known. `attach` copies it only for a delivered outcome (`Outcome.retainsContent`);
        // every refusal/failure is recorded outcome-only, and refusals keep no audio.
        var content = HistoryContent()
        defer {
            entry.latencies = timings
            // Zero-gating tip (STRUCTURAL): only when `ZeroGatingPolicy.shouldWarn` (2 of the last
            // 3 dictations, or one severe), once per session, never over a notice this dictation
            // already showed (it then comes with the next gated dictation), never on a refusal.
            if gatingMeasured {
                recentGating = Array((recentGating + [gating]).suffix(ZeroGatingPolicy.recentWindow))
            }
            if gating.isCuttingOut {
                Log.info("audio gating: zeroFraction=\(String(format: "%.3f", gating.zeroFraction)) maxZeroRunMs=\(Int(gating.maxZeroRunMs)) vp=\(voiceProcessing.map(String.init) ?? "?") warm=\(warmStart.map(String.init) ?? "?")")
                if ZeroGatingPolicy.shouldWarn(recent: recentGating), !gatingTipShown, !noticeSent, !entry.outcome.isSafetyRefusal {
                    gatingTipShown = true
                    onNotice?(PipelineNotice.micCuttingOut)
                }
            }
            content.attach(to: &entry)
            history.append(entry)
            if let store = debugRecordings, let keptSpeech, entry.outcome.mayKeepDebugAudio, store.isEnabled() {
                let e = entry
                let generation = store.saveGeneration
                let previous = debugSaveChain
                debugSaveChain = Task.detached(priority: .utility) {
                    await previous?.value
                    store.save(samples: keptSpeech, entry: e, generation: generation)
                }
            }
        }
        func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }
        let clock = ContinuousClock()
        let processStart = clock.now
        if let captureEndedAt {
            timings.tailMs = ms(captureEndedAt - releasedAt)
            timings.handoffMs = ms(processStart - captureEndedAt)
        }
        func finish() { timings.totalMs = ms(clock.now - releasedAt) }
        if captureInterrupted, samples.count < Int(sr * 0.2) {
            // Too short to transcribe: discard, using the existing outcome-only cancellation.
            entry.outcome = .cancelled
            entry.note = HistoryEntry.microphoneInterruptedNote
            finish(); return entry
        }
        // Smart-join caret context: read NOW, concurrently with VAD/ASR (the AX read runs on
        // `AXQueue`, off the main actor), so it is normally done before insertion.
        let caretReader = self.caretReader
        let caretTask: Task<CaretContext, Never>? = target.map { t in
            Task { @MainActor in await caretReader.read(pid: t.pid, bundleID: t.bundleID) }
        }

        // 1. VAD trim
        var t0 = clock.now
        let speech: [Float]?
        do { speech = samples.count < Int(sr * 0.2) ? nil : try await trimmer.trim(samples) }
        catch { speech = samples }  // VAD failure must not lose the utterance
        timings.vadMs = ms(clock.now - t0)
        if cancelledNow() { finish(); return entry }
        guard let speech, !speech.isEmpty else {
            // No speech: keep the whole capture (the retention table keeps audio for every
            // non-refusal), and say so if the user clearly talked (`NoTextPolicy.loudNoSpeech`).
            keptSpeech = samples
            measureGating(samples)
            if let why = NoTextPolicy.reason(speechDuration: nil, transcriptEmpty: true,
                                             captureDuration: entry.audioDuration, level: level) {
                reportNoText(why, entry: &entry, level: level, gating: gating, notice: notice)
            }
            finish(); return entry
        }
        entry.speechDuration = Double(speech.count) / sr
        keptSpeech = speech
        measureGating(speech)

        // 2. ASR, raced against a timeout so a hung decode can't wedge the job chain.
        t0 = clock.now
        let raw: String
        let hints = dictionary.dictionary.vocabulary
        let timeout = asrTimeout
        do {
            do {
                raw = try await raceTimeout(timeout, clock: pipelineClock) { try await transcriber.transcribe(speech, vocabularyHints: hints) }
            } catch let e where !(e is TimeoutError) {
                // Transient engine failure (e.g. ANE "Program Inference error"): drop the manager,
                // re-prepare, and retry ONCE on the same samples (kept in memory until done).
                Log.error("ASR threw (\(e.localizedDescription)); resetting, re-preparing and retrying once")
                await transcriber.reset()
                raw = try await raceTimeout(timeout, clock: pipelineClock) {
                    try await transcriber.prepare()
                    return try await transcriber.transcribe(speech, vocabularyHints: hints)
                }
                entry.note = "recovered after one retry: \(e.localizedDescription)"
            }
        } catch let e as TimeoutError {
            timings.asrMs = ms(clock.now - t0)
            entry.outcome = .transcriptionTimedOut
            entry.note = e.localizedDescription
            Log.error("ASR timed out after \(asrTimeout); resetting transcriber")
            notice(PipelineNotice.asrTimedOut)
            Task { await transcriber.reset() }
            finish(); return entry
        } catch {
            // Failed twice: visible error with "Retry model preparation"; the next dictation gets
            // a fresh manager (reset again so nothing half-broken is reused).
            timings.asrMs = ms(clock.now - t0)
            entry.outcome = .transcriptionFailed
            entry.note = error.localizedDescription
            Log.error("ASR failed after retry: \(error.localizedDescription)")
            noticeSent = true  // the persistent model error is shown
            await transcriber.reset()
            onModelPrepareFailed?(PipelineNotice.transcriptionFailed(error.localizedDescription))
            finish(); return entry
        }
        timings.asrMs = ms(clock.now - t0)
        if cancelledNow() { finish(); return entry }
        content.raw = raw
        entry.rawWordCount = raw.split(whereSeparator: \.isWhitespace).count
        // 2b. Never silent (`NoTextPolicy`): speech was heard but the model returned no words.
        if let why = NoTextPolicy.reason(speechDuration: entry.speechDuration,
                                         transcriptEmpty: raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                         captureDuration: entry.audioDuration, level: level) {
            reportNoText(why, entry: &entry, level: level, gating: gating, notice: notice)
            finish(); return entry
        }

        // 4. Dictionary replacements (every language: they are the user's own spellings)
        t0 = clock.now
        var replaced = dictionary.apply(to: raw)
        timings.dictionaryMs = ms(clock.now - t0)

        // 3. Language gate — English-only cleanup (STRUCTURAL, `CleanupLanguagePolicy`): confidently non-English
        // text skips snippets, every cleanup rule and the formatter. Never rejected or re-decoded.
        // Logged content-free (language code + confidence only).
        let (langVerdict, detected) = CleanupLanguagePolicy.decide(raw, detector: languageDetector)
        entry.language = detected?.code
        if !langVerdict.allowsCleanup || transcriber.engineName.hasSuffix(":\(ASRModelVariant.parakeetUltra.rawValue)") {
            Log.info("language: \(detected?.logDescription ?? "short") engine=\(transcriber.engineName) cleanup=\(langVerdict.allowsCleanup ? "on" : "skipped")")
        }

        // 5. Smart dictionary spelling (English only): snap sound-alike words to a dictionary
        // term (always on) or, opt-in, to a name/identifier near the cursor. Conservative and
        // deterministic (`SpellingSnapper`); History gets a COUNT of context snaps, never text.
        if langVerdict.allowsCleanup {
            let snap = dictionary.snapper(context: nameContext, tombstones: snapperTombstones()).apply(replaced)
            replaced = snap.text
            if nameContext != nil { entry.contextSnaps = snap.contextSnaps }
        }

        // 6. Snippets on the replaced text BEFORE cleanup (whole utterance only; skips the LLM).
        var final: String
        let hasSnippets = !dictionary.dictionary.snippets.isEmpty
        if case .nonEnglish(let d) = langVerdict {
            final = replaced
            entry.cleaner = "none:\(d.code ?? "und")"
        } else if hasSnippets, let sn = dictionary.snippet(for: replaced) ?? dictionary.snippet(for: Self.rules.cleanSync(replaced)) {
            final = sn.expansion
            content.snippetTrigger = sn.trigger
            entry.cleaner = "snippet"
        } else {
            // 7. Cleanup: RuleCleaner + spoken numbers (default) OR AI formatting. CleanupPolicy (STRUCTURAL): the FM formatter only runs when the user
            // enabled it, or — auto mode — when the utterance has deterministic list cues.
            t0 = clock.now
            let decision = CleanupPolicy.decide(text: replaced, userEnabled: userFormattingEnabled,
                                                autoAvailable: autoFormatter != nil)
            let outcome: CleanupOutcome
            if case .autoModel(let cue) = decision, let auto = autoFormatter {
                var o = await auto.cleanDetailed(replaced)
                o.verdict = "auto(\(cue)):" + (o.verdict ?? "")
                outcome = o
            } else if let rules = cleaner as? RuleCleaner {
                // AI formatting OFF (the default): the deterministic pre-pass still gets the
                // user's dictionary terms, so "<term> six point one" → "<term> 6.1".
                outcome = CleanupOutcome(text: rules.cleanSync(replaced, vocabulary: dictionary.dictionary.vocabulary),
                                         producedBy: rules.name)
            } else {
                outcome = await cleaner.cleanDetailed(replaced)
            }
            timings.cleanupMs = ms(clock.now - t0)
            entry.cleaner = outcome.producedBy
            content.cleanupVerdict = outcome.verdict
            content.cleanupCandidate = outcome.candidate
            entry.cleanupModelMs = outcome.modelMs
            // The LLM may undo a replacement spelling; re-applying is idempotent.
            final = outcome.producedBy == "fm" ? dictionary.apply(to: outcome.text) : outcome.text
            if cancelledNow() { finish(); return entry }  // Esc during a (slow) AI-formatting pass
            // 8–9. Final deterministic passes (English only): backtrack (opt-in), then the
            // per-app style, which only changes the first letter's case and a trailing full stop.
            let passes = FinalPasses.apply(final, style: styleFor(target?.bundleID), backtrack: backtrackEnabled(),
                                           vocabulary: dictionary.dictionary.vocabulary, names: nameRecognizer)
            final = passes.text
            uncorrected = passes.uncorrected
            entry.style = passes.style?.rawValue
            if uncorrected != nil { entry.backtrackApplied = true }
        }
        content.final = final
        // Newline-only output ("new line" / "new paragraph" said on its own) is a real insertion.
        guard !final.trimmingCharacters(in: .whitespaces).isEmpty else {
            entry.outcome = .emptyAfterCleanup
            finish(); return entry
        }

        // 10a. Conflict gate (STRUCTURAL): never insert while holding off for Wispr Flow (it may
        // have launched mid-dictation).
        t0 = clock.now
        defer { if timings.gatesMs == nil { timings.gatesMs = ms(clock.now - t0) } }
        if let reason = gate.insertionBlockReason() {
            entry.outcome = .blockedByConflict
            entry.note = reason
            finish(); return entry
        }
        // 10b. Secure input gate (STRUCTURAL).
        if secureInput.isSecureInputActive {
            entry.outcome = .blockedBySecureInput
            notice(PipelineNotice.secureInput)
            finish(); return entry
        }
        // 10c. Focus guard (STRUCTURAL): only paste into the app that was frontmost at start.
        let now = frontmostApp()
        if now != target {
            lastDictationText = final
            clipboard.setString(final)
            entry.outcome = .focusChanged
            entry.note = "target \(target?.bundleID ?? "nil") now \(now?.bundleID ?? "nil")"
            notice(PipelineNotice.focusChanged)
            finish(); return entry
        }

        timings.gatesMs = ms(clock.now - t0)

        // 11. Smart join with the text before the caret (space + casing at dictation joins).
        t0 = clock.now
        let (inserter, strategy) = inserterFor(target?.bundleID)
        entry.insertionStrategy = "\(strategy.rawValue):\(inserter.name)"
        let context = await caretTask?.value ?? .unavailable
        await waitWhileHeld()  // triple-tap: wait for the third tap or the window to end
        if cancelledNow() { finish(); return entry }
        let insertAt = currentDate()
        let toInsert = JoinPolicy.adjust(final, context: context, pid: target?.pid, last: lastInsertion,
                                         now: insertAt, vocabulary: dictionary.dictionary.vocabulary)
        if toInsert != final { content.join = (context.preceding == nil ? "fallback:" : "ax:") + toInsert }
        timings.joinMs = ms(clock.now - t0)
        // 12. Insert. `insert` returns once the paste is POSTED (clipboard restore is async), so
        // insertMs / perceivedMs measure what the user sees.
        // Esc / triple-tap from here on (R1): the paste task is cancelled — before Cmd-V nothing is
        // typed (`.cancelled`, "Cancelled"); after it, the text stays (`.inserted`, "Already
        // typed") and NOTHING follows: no Return, no Undo offer, no learning watcher.
        t0 = clock.now
        var watchable: InsertedDictation?
        var returnPressed = false
        let previousInsertion = lastInsertion  // R15: Undo's original joins like the inserted text
        insertingJob = job.map { ($0, autoSend) }
        defer { insertingJob = nil; insertTask = nil }
        var typedNoticeShown = false
        /// R1: true (and everything after the paste is dropped) once this job was cancelled.
        func cancelledAfterTyping() -> Bool {
            guard isCancelled(job) else { return false }
            if !typedNoticeShown {
                typedNoticeShown = true
                entry.note = autoSend ? "cancelled after the paste: Return not pressed" : "cancelled after the paste"
                notice(autoSend ? PipelineNotice.alreadyTypedNotSent : PipelineNotice.alreadyTyped)
                Log.info("cancelled after the paste: nothing further")
            }
            pendingCorrection = nil
            watchable = nil
            return true
        }
        do {
            let task = Task { @MainActor in try await insert(toInsert, using: inserter, target: target) }
            insertTask = task
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            let report = inserter.lastReport
            timings.perceivedMs = ms(clock.now - releasedAt) - (report.map { ms($0.afterPost) } ?? 0)
            if let target {
                lastInsertion = LastInsertion(pid: target.pid, elementID: context.elementID, text: toInsert, at: insertAt)
            }
            lastDictationText = toInsert
            entry.outcome = .inserted
            if let report {
                entry.pasteVerified = report.verified
                entry.pasteRetried = report.retried
                entry.pasteRestoreDelayMs = ms(report.restoreDelay)
            }
            if !cancelledAfterTyping() {
                // Warn when the field stayed unchanged, without a reminder after every
                // unverifiable paste (for example, in Electron apps).
                // (Not counted as this dictation's notice: the once-per-session gating tip may
                // replace it; the re-paste shortcut works either way.)
                if report?.verified == false {
                    onNotice?(PipelineNotice.pasteNotConfirmed)
                }
                if let uncorrected, let target, strategy == .paste {
                    let original = JoinPolicy.adjust(uncorrected, context: context, pid: target.pid, last: previousInsertion,
                                                     now: insertAt, vocabulary: dictionary.dictionary.vocabulary)
                    // R5/R6/R14: ⌘Z only where it is provably our paste; else "Copy original".
                    var focus: FocusSnapshot?
                    if UndoPolicy.mayOfferUndo(bundleID: target.bundleID, pasteVerified: report?.verified,
                                               pasteRetried: report?.retried ?? false, hasReport: report != nil,
                                               axVerified: true) {
                        let snap = await focusProbe.snapshot(pid: target.pid, precedingChars: toInsert.utf16.count + 1)
                        if UndoPolicy.maySendUndo(inserted: toInsert, atInsert: snap, now: snap) { focus = snap }
                    }
                    pendingCorrection = PendingCorrection(pid: target.pid, inserted: toInsert, original: original,
                                                          at: insertAt, spoken: uncorrected, focus: focus)
                }
                if let target, strategy == .paste {
                    watchable = InsertedDictation(pid: target.pid, bundleID: target.bundleID, elementID: context.elementID,
                                                  text: toInsert, axReadable: context.preceding != nil && report?.verified != nil,
                                                  replaced: context.selectedText)
                }
            }
            // 13. Auto-send. Shift held at release: press Return now that the paste is posted (`AutoSendPolicy`).
            if !isCancelled(job),
               AutoSendPolicy.shouldPressReturn(enabled: autoSend, shiftHeldAtRelease: autoSend, outcome: entry.outcome,
                                                strategy: strategy, secureInputActive: secureInput.isSecureInputActive,
                                                pasteVerified: report?.verified) {
                try? await pipelineClock.sleep(until: pipelineClock.now + autoSendDelay)
                // R3: the SAME focused element and window as at recording start, else no Return.
                let atStart = await startFocus?.value
                var nowFocus: FocusSnapshot?
                if let target { nowFocus = await focusProbe.snapshot(pid: target.pid, precedingChars: 0) }
                // R1: no Return after a cancel — checked immediately before pressing it.
                if cancelledAfterTyping() {
                } else if !secureInput.isSecureInputActive, frontmostApp() == target,
                          AutoSendPolicy.focusUnchanged(atStart: atStart, now: nowFocus) {
                    do { try returnKey.pressReturn(); returnPressed = true; Log.info("auto-send: Return pressed") }
                    catch { Log.error("auto-send failed: \(error.localizedDescription)") }
                } else {
                    Log.info("auto-send: focus changed or not verifiable; Return not pressed")
                }
            }
            if returnPressed {
                // The message is SENT: the app's ⌘Z can no longer remove our paste, and the field
                // no longer holds it. No Undo offer, nothing to watch.
                pendingCorrection = nil
                watchable = nil
            }
            _ = cancelledAfterTyping()
        } catch let cancelled as TypingCancellation {
            entry.outcome = .cancelled
            entry.note = "typed \(cancelled.typed) of \(cancelled.total) characters before cancellation"
            notice(PipelineNotice.cancelledTyping(typed: cancelled.typed, total: cancelled.total))
        } catch let blocked as RemoteTypingBlocked {
            let progress = " — stopped after typing \(blocked.typed) of \(blocked.total) characters"
            switch blocked.reason {
            case .secureInput:
                entry.outcome = .blockedBySecureInput
                notice(PipelineNotice.secureInput + progress)
            case .conflict(let reason):
                entry.outcome = .blockedByConflict
                entry.note = reason
                notice(reason + progress)
            }
        } catch let gateError as PasteGateError {
            switch gateError {
            case .focusChanged:
                lastDictationText = final
                clipboard.setString(final)
                entry.outcome = .focusChanged
                notice(PipelineNotice.focusChanged)
            case .secureInput:
                entry.outcome = .blockedBySecureInput
                notice(PipelineNotice.secureInput)
            case .conflict(let reason):
                entry.outcome = .blockedByConflict
                entry.note = reason
            }
        } catch is CancellationError {
            entry.outcome = .cancelled
            _ = cancelledNow()  // cancelled before Cmd-V was posted: nothing was typed
            notice(PipelineNotice.cancelled)
        } catch RemoteInsertionError.remoteSecureInput {
            entry.outcome = .blockedByRemoteSecureInput
            notice(PipelineNotice.remoteSecureInput)
        } catch {
            entry.outcome = .insertFailed
            lastDictationText = final
            entry.note = PipelineNotice.insertionFailed(error.localizedDescription)
            clipboard.setString(final)
            noticeSent = true  // AppController flashes the content-free entry.note once.
        }
        timings.insertMs = ms(clock.now - t0)
        if let c = pendingCorrection {  // last, so it isn't replaced
            notice(c.undoable ? PipelineNotice.corrected : PipelineNotice.correctedCopyOnly)
        }
        // 14. Learning watcher (smart dictionary): only after the paste (and any auto-send) is done.
        if let watchable { onInserted?(watchable) }
        finish()
        return entry
    }

    private func insert(_ text: String, using inserter: TextInserter, target: FrontmostApp?) async throws {
        if let paste = inserter as? PasteInserter {
            try await paste.insert(text, prePostCheck: { [self] in try checkPasteGates(target: target) })
        } else if let remote = inserter as? RemoteInserter {
            do {
                try await remote.insert(text, prePostCheck: { [self] in
                    try checkPasteGates(target: target)
                })
            } catch is RemoteTypingError {
                throw PasteGateError.focusChanged
            }
        } else {
            try await inserter.insert(text)
        }
    }

    private func checkPasteGates(target: FrontmostApp?) throws {
        try Task.checkCancellation()
        if secureInput.isSecureInputActive { throw PasteGateError.secureInput }
        if frontmostApp() != target { throw PasteGateError.focusChanged }
        if let reason = gate.insertionBlockReason() { throw PasteGateError.conflict(reason) }
    }

    /// HUD "Corrected · Undo": puts the words back as spoken. Method (simplest reliable one):
    /// post the app's own ⌘Z, which removes our paste as one undo step, then paste the original
    /// through the normal inserter. Offered only for the paste strategy, only within
    /// `PendingCorrection.window`, only into the same app, only when `UndoPolicy` allows it (not
    /// in terminals, not after an unverified/retried paste, the same AX-verified element still
    /// ending with our text), and through the same gates as a dictation. Otherwise the original
    /// goes to the clipboard instead. Returns whether it replaced the text.
    @discardableResult
    public func undoLastCorrection() async -> Bool {
        guard let c = pendingCorrection else { return false }
        pendingCorrection = nil
        guard currentDate().timeIntervalSince(c.at) <= PendingCorrection.window,
              !status.isRecording, pendingJobs == 0 else { return false }
        guard gate.insertionBlockReason() == nil else { onBlockedByConflict?(); return false }
        guard !secureInput.isSecureInputActive else { onNotice?(PipelineNotice.secureInput); return false }
        let front = frontmostApp()
        guard front?.pid == c.pid else {
            clipboard.setString(c.spoken)
            onNotice?(PipelineNotice.focusChanged)
            return false
        }
        // R5: ⌘Z only when AX shows the SAME element (CFEqual, same window) still ending, at the
        // caret, with exactly what we inserted. Anything else (the user typed, switched field or
        // tab, AX unreadable) → the original goes to the clipboard instead.
        let now = c.undoable ? await focusProbe.snapshot(pid: c.pid, precedingChars: c.inserted.utf16.count + 1) : nil
        guard UndoPolicy.maySendUndo(inserted: c.inserted, atInsert: c.focus, now: now),
              !status.isRecording, pendingJobs == 0, frontmostApp()?.pid == c.pid else {
            clipboard.setString(c.spoken)
            onNotice?(PipelineNotice.undoNotSafe)
            Log.info("undo correction: field not verifiable; original copied instead")
            return false
        }
        let (inserter, _) = inserterFor(front?.bundleID)
        onInsertionSuperseded?()  // before ⌘Z: the watcher must never see our own rewrite
        do {
            try postUndo()
            try await Task.sleep(for: undoSettle)
            try await insert(c.original, using: inserter, target: front)
        } catch {
            Log.error("undo correction failed: \(error.localizedDescription)")
            return false
        }
        lastInsertion = LastInsertion(pid: c.pid, elementID: lastInsertion?.elementID, text: c.original, at: currentDate())
        lastDictationText = c.original
        Log.info("backtrack undone")
        return true
    }

    /// HUD "Corrected · can't undo here" → "Copy original": the words as spoken go to the
    /// clipboard (no keystrokes). Returns whether there was anything to copy.
    @discardableResult
    public func copyOriginalOfLastCorrection() -> Bool {
        guard let c = pendingCorrection, currentDate().timeIntervalSince(c.at) <= PendingCorrection.window else {
            pendingCorrection = nil
            return false
        }
        pendingCorrection = nil
        clipboard.setString(c.spoken)
        onNotice?(PipelineNotice.originalCopied)
        return true
    }

    /// Re-paste shortcut (`PasteAgainShortcut`): the most recent dictation, again, into whatever is
    /// frontmost now — through the same gates (Wispr Flow conflict, secure input) as a dictation.
    /// Refusals and cancellations preserve the previous recovery text.
    /// Recovery text only ever lives in memory, including after a failed insertion. Returns whether it pasted.
    @discardableResult
    public func pasteLastAgain() async -> Bool {
        guard !status.isRecording else { return false }
        guard let text = lastDictationText, !text.isEmpty else {
            onNotice?(PipelineNotice.nothingToPasteAgain); return false
        }
        guard gate.insertionBlockReason() == nil else { onBlockedByConflict?(); return false }
        guard !secureInput.isSecureInputActive else { onNotice?(PipelineNotice.secureInput); return false }
        let front = frontmostApp()
        let (inserter, _) = inserterFor(front?.bundleID)
        do { try await insert(text, using: inserter, target: front) } catch {
            Log.error("paste again failed: \(error.localizedDescription)")
            return false
        }
        Log.info("paste again: done")
        return true
    }

    /// Outcome `.noTextRecognised`, reason in `note`, a content-free log line, and the HUD notice.
    private func reportNoText(_ why: NoTextPolicy.Reason, entry: inout HistoryEntry, level: CaptureLevel,
                              gating: AudioGatingMetrics, notice: (String) -> Void) {
        entry.outcome = .noTextRecognised
        entry.note = why.rawValue
        lastNoTextEntryID = entry.id
        let heardSeconds = entry.speechDuration, capturedSeconds = entry.audioDuration  // numbers only
        Log.info("no text: \(why.rawValue) speech=\(String(format: "%.1f", heardSeconds))s capture=\(String(format: "%.1f", capturedSeconds))s level=\(Int(level.loudDBFS))dBFS floor=\(Int(level.floorDBFS))dBFS zeroFraction=\(String(format: "%.3f", gating.zeroFraction)) maxZeroRunMs=\(Int(gating.maxZeroRunMs))")
        notice(NoTextPolicy.notice(builtInMic: inputIsBuiltInMic(), level: level, gating: gating))
    }
}

/// What the pipeline records about a capture at recording start (content-free).
struct CaptureInfo {
    var interrupted = false
    var voiceProcessing: Bool?
    var warmStart: Bool?
    var micMode: String?
    /// Context names read at recording start (in memory; dropped with the job).
    var nameContext: Task<ContextSnapshot?, Never>?
    /// The focused element at recording start (auto-send's same-field check, R3).
    var focus: Task<FocusSnapshot?, Never>?
}
