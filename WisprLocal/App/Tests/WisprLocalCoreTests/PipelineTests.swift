import Testing
import Foundation
@testable import WisprLocalCore

@MainActor final class PipelineEnv {
    let inserter = FakeInserter()
    let history = MemoryHistory()
    let audio = FakeAudio()
    let secure = FakeSecureInput()
    let clipboard = FakeClipboard()
    let caret = FakeCaretReader()
    let focus = FakeFocusProbe()
    let transcriber: FakeTranscriber
    var apps: [RunningAppInfo] = []
    var front: FrontmostApp? = FrontmostApp(pid: 42, bundleID: "com.apple.TextEdit")
    var notices: [String] = []
    var pipeline: DictationPipeline!
    var detector: ConflictDetector!

    init(text: String, speech: Bool, transcriber: FakeTranscriber?) {
        self.transcriber = transcriber ?? FakeTranscriber(text: text)
        audio.samples = [Float](repeating: 0.1, count: 16_000)
    }
}

/// Builds a pipeline whose conflict detector reads `env.apps` live.
@MainActor func makeEnv(text: String = "Please open whisperflow, um, now.", speech: Bool = true,
                        transcriber: FakeTranscriber? = nil, ready: Bool = true,
                        debugRecordings: DebugRecordingStore? = nil,
                        dictionary: DictionaryStore = tempDictionary(),
                        strategy: InsertionStrategy = .paste) async -> (PipelineEnv, DictationPipeline) {
    let env = PipelineEnv(text: text, speech: speech, transcriber: transcriber)
    let detector = ConflictDetector(runningApps: { [unowned env] in env.apps }, fnUsageReader: { 0 })
    let inserter = env.inserter
    let p = DictationPipeline(
        audio: env.audio, trimmer: FakeTrimmer(hasSpeech: speech), transcriber: env.transcriber,
        dictionary: dictionary, cleaner: RuleCleaner(), gate: detector,
        secureInput: env.secure, clipboard: env.clipboard,
        inserterFor: { _ in (inserter, strategy) }, history: env.history,
        frontmostApp: { [unowned env] in env.front }, caretReader: env.caret, debugRecordings: debugRecordings, autoFormatter: .none)
    p.onNotice = { [unowned env] in env.notices.append($0) }
    // The focused field holds everything typed so far (AX-readable, one window).
    env.focus.preceding = { [unowned env] in env.caret.context.preceding.map { $0 + env.inserter.inserted.joined() } }
    p.focusProbe = env.focus
    p.captureTail = .zero
    if ready { await p.prepareModels() }
    env.pipeline = p
    env.detector = detector
    return (env, p)
}

@MainActor @Suite struct PipelineTests {
    static let wispr = RunningAppInfo(bundleID: WisprFlowMatcher.bundleID, bundlePath: "/Applications/Wispr Flow.app")

    @Test func captureInterruptionCommitsOnceWithoutAutoSend() async {
        let (e, p) = await makeEnv(text: "Captured before disconnect.")
        var resets = 0, sendRequests = 0
        p.onGestureReset = { resets += 1 }
        p.autoSendRequested = { sendRequests += 1; return true }
        p.captureTail = .seconds(1)
        p.handle(.startRecording)
        e.audio.interrupt()
        #expect(!p.status.isRecording)
        e.audio.interrupt()  // a queued repeat cannot commit twice
        await p.drain()
        #expect(e.audio.stopped == 1 && e.audio.lastTail == .zero)
        #expect(e.inserter.inserted == ["Captured before disconnect."])
        #expect(e.history.entries.last?.outcome == .inserted)
        #expect(e.history.entries.last?.note == PipelineNotice.captureInterrupted)
        #expect(e.notices == [PipelineNotice.captureInterrupted])
        #expect(resets == 1 && sendRequests == 0)
        #expect(p.status == .ready)
    }

    @Test func handsFreeDoneInsertsOnceAndResetsTheGesture() async {
        let (e, p) = await makeEnv(text: "Finish this dictation.")
        let clock = ManualClock(); p.pipelineClock = clock
        var resets = 0, askedToSend = 0
        p.onGestureReset = { resets += 1 }
        p.autoSendRequested = { askedToSend += 1; return true }
        p.handle(.startRecording)
        p.handle(.enterHandsFree)
        await clock.advance(by: .seconds(72))
        #expect(p.status == .recording(handsFree: true))
        #expect(p.activeDictationSeconds == 72)
        #expect(p.finishHandsFree())
        #expect(!p.finishHandsFree(), "a second click cannot insert twice")
        await p.drain()
        #expect(e.audio.started == 1 && e.audio.stopped == 1)
        #expect(e.inserter.inserted == ["Finish this dictation."])
        #expect(e.history.entries.count == 1 && e.history.entries.first?.outcome == .inserted)
        #expect(resets == 1 && askedToSend == 0)
        #expect(p.status == .ready)
        p.handle(.startRecording)  // the next dictation works after clicking Done
        #expect(e.audio.started == 2 && p.status == .recording(handsFree: false))
        p.handle(.cancelRecording)
    }

    @Test func handsFreeDoneDoesNotFinishAnIdleOrHeldRecording() async {
        let (e, p) = await makeEnv()
        #expect(!p.finishHandsFree())
        p.handle(.startRecording)
        #expect(!p.finishHandsFree())
        #expect(p.status == .recording(handsFree: false) && e.audio.stopped == 0)
        p.handle(.cancelRecording)
    }

    @Test func endToEndInsertsCleanedText() async {
        let (e, p) = await makeEnv()
        p.handle(.startRecording)
        #expect(p.status == .recording(handsFree: false))
        p.handle(.commitRecording)
        await p.drain()
        #expect(e.inserter.inserted == ["Please open Wispr Flow now."])
        let h = e.history.entries.last!
        #expect(h.outcome == .inserted)
        #expect(h.raw == "Please open whisperflow, um, now.")
        #expect(h.frontmostApp == "com.apple.TextEdit")
        #expect(h.audioDuration == 1.0)
        #expect(p.status == .ready)
    }

    @Test func commitKeepsCapturingForTail() async {
        let (e, p) = await makeEnv()
        p.captureTail = .milliseconds(200)
        p.handle(.startRecording)
        p.handle(.commitRecording)
        await p.drain()
        #expect(e.audio.lastTail == .milliseconds(200))
        #expect(e.audio.stopped == 1)
    }

    // STRUCTURAL (item 2): focus guard
    @Test func focusChangeCopiesToClipboardInsteadOfPasting() async {
        let (e, p) = await makeEnv()
        p.handle(.startRecording)                      // target = TextEdit (pid 42)
        e.front = FrontmostApp(pid: 77, bundleID: "com.tinyspeck.slackmacgap")
        p.handle(.commitRecording)
        await p.drain()
        #expect(e.inserter.inserted.isEmpty)
        #expect(e.clipboard.strings == ["Please open Wispr Flow now."])
        #expect(e.history.entries.last?.outcome == .focusChanged)
        #expect(e.history.entries.last?.frontmostApp == "com.apple.TextEdit")
        #expect(e.notices.contains(PipelineNotice.focusChanged))
    }

    @Test func dictationWhileModelPreparingIsRefused() async {
        let (e, p) = await makeEnv(ready: false)
        p.handle(.startRecording)
        #expect(!p.status.isRecording)
        #expect(e.audio.started == 0)
        #expect(e.notices == [PipelineNotice.modelPreparing])
    }

    // STRUCTURAL (item 5): conflict gate is live, no notification needed
    @Test func conflictGateQueriesRunningAppsLive() async {
        let (e, p) = await makeEnv()
        e.apps = [Self.wispr]  // appears WITHOUT any launch notification / refresh()
        let entry = await p.process(samples: e.audio.samples, target: e.front)
        #expect(entry.outcome == .blockedByConflict)
        #expect(e.inserter.inserted.isEmpty)
        e.apps = []           // quits, again without notification
        let entry2 = await p.process(samples: e.audio.samples, target: e.front)
        #expect(entry2.outcome == .inserted)
    }

    @Test func ignoreLetsInsertionThroughWhileWisprRuns() async {
        let (e, p) = await makeEnv()
        e.apps = [Self.wispr]
        let d = ConflictDetector(runningApps: { [unowned e] in e.apps }, fnUsageReader: { 0 })
        #expect(d.insertionBlockReason() != nil)
        d.useAnyway = true
        #expect(d.insertionBlockReason() == nil)
        _ = p
    }

    // STRUCTURAL (item 6): secure input
    @Test func secureInputRefusesRecording() async {
        let (e, p) = await makeEnv()
        e.secure.active = true
        p.handle(.startRecording)
        #expect(e.audio.started == 0)
        #expect(!p.status.isRecording)
        #expect(e.notices == [PipelineNotice.secureInput])
    }

    @Test func secureInputRefusesInsertion() async {
        let (e, p) = await makeEnv()
        p.handle(.startRecording)
        e.secure.active = true  // password field focused while we were transcribing
        p.handle(.commitRecording)
        await p.drain()
        #expect(e.inserter.inserted.isEmpty)
        #expect(e.clipboard.strings.isEmpty)
        #expect(e.history.entries.last?.outcome == .blockedBySecureInput)
    }

    // Item 8: ASR timeout recovers the chain
    @Test(.timeLimit(.minutes(1))) func hungTranscriberTimesOutAndNextDictationWorks() async {
        let tr = FakeTranscriber(text: "Hello there.", hangCalls: 1)   // the first call hangs for good
        let (e, p) = await makeEnv(transcriber: tr)
        defer { tr.release() }
        let clock = ManualClock(); p.pipelineClock = clock
        p.asrTimeout = .milliseconds(200)
        p.handle(.startRecording); p.handle(.commitRecording)
        await eventually { !p.isFinishingCapture }              // capture tail finished
        p.handle(.startRecording); p.handle(.commitRecording)  // queued behind the hung one
        await clock.waitForSleepers(count: 1)            // first job is inside its ASR timeout
        await clock.advance(by: .milliseconds(200))
        await p.drain()
        let outcomes = e.history.entries.map(\.outcome)
        #expect(outcomes == [.transcriptionTimedOut, .inserted])
        #expect(e.inserter.inserted == ["Hello there."])
        #expect(e.notices.contains(PipelineNotice.asrTimedOut))
        #expect(p.status == .ready)
    }

    // Nit: Fn+other key after a speculative start -> discarded, never transcribed
    @Test func cancelDiscardsSpeculativeAudio() async {
        let (e, p) = await makeEnv()
        p.handle(.startRecording)
        p.handle(.cancelRecording)
        await p.drain()
        #expect(e.audio.cancelled == 1)
        #expect(e.transcriber.callCount == 0)
        #expect(e.inserter.inserted.isEmpty)
        #expect(e.history.entries.isEmpty)
    }

    @Test func setTranscriberSupersedesInFlightPrepare() async {
        let (_, p) = await makeEnv()
        #expect(p.modelReady)
        p.setTranscriber(FakeTranscriber(text: "x"))
        #expect(!p.modelReady)
        await p.prepareModels()
        #expect(p.modelReady)
    }

    @Test func noSpeechSkipsInsertion() async {
        let (e, p) = await makeEnv(speech: false)
        let entry = await p.process(samples: e.audio.samples, target: e.front)
        #expect(entry.outcome == .noSpeech)
        #expect(e.inserter.inserted.isEmpty)
    }

    @Test func tooShortAudioIsNoSpeech() async {
        let (e, p) = await makeEnv()
        let entry = await p.process(samples: [Float](repeating: 0, count: 100), target: e.front)
        #expect(entry.outcome == .noSpeech)
    }

    @Test func fillerOnlyIsEmptyAfterCleanup() async {
        let (e, p) = await makeEnv(text: "Um.")
        let entry = await p.process(samples: e.audio.samples, target: e.front)
        #expect(entry.outcome == .emptyAfterCleanup)
        #expect(e.inserter.inserted.isEmpty)
    }

    @Test func historyStoreWritesJSONLines() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let s = HistoryStore(directory: dir)
        s.append(HistoryEntry(raw: "a", final: "A.", engine: "x", outcome: .inserted))
        s.append(HistoryEntry(raw: "b", outcome: .focusChanged))
        let all = s.readAll()
        #expect(all.count == 2)
        #expect(all[1].outcome == .focusChanged)
    }

    @Test func raceTimeoutReturnsFastResult() async throws {
        let v = try await raceTimeout(.seconds(5)) { 7 }
        #expect(v == 7)
    }
}
