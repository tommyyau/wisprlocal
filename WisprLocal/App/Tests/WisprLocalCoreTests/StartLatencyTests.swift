import Foundation
import Testing
@testable import WisprLocalCore

@MainActor private final class StartSoundSpy: FeedbackSoundPlaying {
    let duration: Duration = .milliseconds(70)
    var played: [FeedbackSound] = []
    func play(_ sound: FeedbackSound) { played.append(sound) }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct StartLatencyTests {
    @Test func hudIsPublishedWhileRecorderStartIsGated() async {
        let (e, p) = await makeEnv()
        let gate = HangGate(); e.audio.startGate = gate
        defer { gate.release() }
        p.handle(.startRecording)
        await waitForTest("recorder suspended on closed gate") { gate.waiterCount == 1 }
        #expect(e.audio.startCompletion != nil, "recorder start is pending on the gate")
        #expect(!e.audio.startCompleted)
        #expect(p.status.isRecording && p.recordingCue == .starting)
        gate.release()
        await waitForTest("gated start completion") { e.audio.startCompleted }
        p.handle(.cancelRecording)
    }

    @Test func keyDownReturnsToCallerBeforeStartCompletes() async {
        let (e, p) = await makeEnv()
        let gate = HangGate(); e.audio.startGate = gate
        defer { gate.release() }
        var returned = false
        p.handle(.startRecording)
        returned = true
        #expect(returned && !e.audio.startCompleted && e.audio.startCompletion != nil)
        gate.release()
        await waitForTest("start after caller regained control") { e.audio.startCompleted }
        p.handle(.cancelRecording)
    }

    @Test func manualClockMeasuresThreeSecondCaptureDelay() async throws {
        let (e, p) = await makeEnv()
        let clock = ManualClock()
        p.pipelineClock = clock; e.audio.startClock = clock
        p.handle(.startRecording)
        // This call returns while the engine is still parked: the main actor remains usable.
        #expect(p.status.isRecording && p.recordingCue == .starting)
        await waitForTest("three-second start sleeper") { clock.sleeperCount > 0 }
        await clock.advance(by: .seconds(3))
        await waitForTest("start sleeper resumed") { clock.sleeperCount == 0 }
        // Completion is controlled separately to avoid depending on executor scheduling.
        await waitForTest("recorder start callback") { e.audio.startCompletion != nil }
        e.audio.finishStart()
        e.audio.onLevel?(0) // zero-filled startup buffers do not count as capture
        #expect(p.recordingCue == .starting)
        e.audio.onLevel?(0.5)
        #expect(p.recordingCue == .live)
        p.handle(.commitRecording)
        await p.drain()
        let timing = try #require(e.history.entries.last?.latencies)
        #expect(try #require(timing.keyDownToHUDMs) == 0)
        #expect(timing.keyDownToCaptureMs == 3000)
    }

    @Test(arguments: [HotkeyStateMachine.Action.cancelRecording, .cancelDictation, .commitRecording])
    func releaseAndCancelDuringStartCloseMic(action: HotkeyStateMachine.Action) async {
        let (e, p) = await makeEnv()
        let clock = ManualClock()
        p.pipelineClock = clock; e.audio.startClock = clock
        p.handle(.startRecording)
        p.handle(.enterHandsFree)
        #expect(p.status == .recording(handsFree: true))
        p.handle(action)
        #expect(!p.status.isRecording)
        p.handle(.startRecording) // cannot start again until the abandoned start is cleaned up
        #expect(e.audio.started == 1)
        await waitForTest("three-second start sleeper") { clock.sleeperCount > 0 }
        await clock.advance(by: .seconds(3))
        await waitForTest("recorder start callback") { e.audio.startCompletion != nil }
        e.audio.finishStart()
        await waitForTest("abandoned start stopped") { e.audio.stopped > 0 }
        e.audio.onLevel?(0.5) // late level must not resurrect HUD
        #expect(p.level == 0)
        #expect(e.inserter.inserted.isEmpty)
        #expect(e.audio.stopped == 1)
        e.audio.startClock = nil
        p.handle(.startRecording)
        #expect(e.audio.started == 2)
        p.handle(.cancelRecording)
        if action == .cancelDictation {
            #expect(e.history.entries.last?.latencies.keyDownToHUDMs == 0)
            #expect(e.history.entries.last?.latencies.keyDownToCaptureMs == nil)
        }
    }

    @Test func firstBufferClockSurvivesMainActorDelayAndDebugMetadata() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let debug = DebugRecordingStore(directory: dir, isEnabled: { true })
        let (e, p) = await makeEnv(debugRecordings: debug)
        let clock = ManualClock(); p.pipelineClock = clock
        e.audio.emitsCaptureOnImmediateStart = false
        p.handle(.startRecording)
        await clock.advance(by: .milliseconds(42))
        let callback = try #require(e.audio.onNonZeroCapture)
        await Task.detached { callback() }.value
        await clock.advance(by: .seconds(1))
        e.audio.onLevel?(0.5) // late UI callback must not replace the tap timestamp
        p.handle(.commitRecording)
        await p.drain(); await p.flushDebugRecordings()
        let entry = try #require(e.history.entries.last)
        #expect(entry.latencies.keyDownToHUDMs == 0)
        #expect(entry.latencies.keyDownToCaptureMs == 42)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let saved = try decoder.decode(HistoryEntry.self, from: Data(contentsOf: debug.jsonURL(entry.id)))
        #expect(saved.latencies == entry.latencies)
    }

    @Test func productionStartAndReadinessReadsNeverWaitOnAudioQueue() throws {
        let source = try String(contentsOf: PreRollPrivacyTests.sources.appendingPathComponent("WisprLocalCore/Audio/AudioRecorder.swift"), encoding: .utf8)
        let recorder = try #require(source.range(of: "nonisolated public final class AudioRecorder"))
        let start = try #require(source.range(of: "    public func start(completion:", range: recorder.upperBound..<source.endIndex))
        let end = try #require(source.range(of: "    public func start() throws", range: start.upperBound..<source.endIndex))
        let body = source[start.lowerBound..<end.lowerBound]
        #expect(body.contains("q.async") && !body.contains("q.sync"))
        let reads = try #require(source.range(of: "    public var voiceProcessingActive:"))
        let readsEnd = try #require(source.range(of: "    public func enterWarm()", range: reads.upperBound..<source.endIndex))
        #expect(!source[reads.lowerBound..<readsEnd.lowerBound].contains("q.sync"))
    }

    @Test func coldReleaseBeforeCaptureUsesQuickTapAndHintsOnce() async {
        let (e, p) = await makeEnv()
        var notices: [String] = []; p.onNotice = { notices.append($0) }
        let sound = StartSoundSpy(); p.feedbackSounds = sound
        for _ in 0..<2 {
            let gate = HangGate(); e.audio.startGate = gate
            p.handle(.startRecording)
            p.handle(.commitRecording)
            #expect(!p.status.isRecording && e.history.entries.isEmpty)
            #expect(notices == [PipelineNotice.holdUntilBars])
            let stopped = e.audio.stopped
            gate.release()
            await waitForTest("quick release closes pending start") { e.audio.stopped > stopped }
        }
        #expect(sound.played.isEmpty)
        let chip = HUDChipPolicy.chip(PipelineNotice.holdUntilBars)
        #expect(chip.priority == .info && chip.seconds == 3 && chip.actions.isEmpty)
    }

    @Test func releaseAfterEngineStartButBeforeFirstAudioIsAlsoSilent() async {
        let (e, p) = await makeEnv()
        e.audio.emitsCaptureOnImmediateStart = false
        let sound = StartSoundSpy(); p.feedbackSounds = sound
        var notices: [String] = []; p.onNotice = { notices.append($0) }
        p.handle(.startRecording)
        #expect(p.recordingCue == .starting)
        let soundsBeforeRelease = sound.played.count
        p.handle(.commitRecording)
        #expect(!p.status.isRecording && e.history.entries.isEmpty)
        #expect(sound.played.count == soundsBeforeRelease && e.audio.cancelled == 1)
        #expect(notices == [PipelineNotice.holdUntilBars])
    }

    @Test(arguments: [500, 3000], [false, true])
    func noAudioReleaseIsBounded(milliseconds: Int, pending: Bool) async throws {
        let (e, p) = await makeEnv()
        let clock = ManualClock(); p.pipelineClock = clock
        e.audio.samples = []; e.audio.emitsCaptureOnImmediateStart = false
        let gate = HangGate()
        if pending { e.audio.startGate = gate }
        defer { gate.release() }
        var notices: [String] = []; p.onNotice = { notices.append($0) }
        p.handle(.startRecording)
        await clock.advance(by: .milliseconds(milliseconds))
        p.handle(.commitRecording)
        await p.drain()
        if milliseconds == 500 {
            #expect(e.history.entries.isEmpty && notices == [PipelineNotice.holdUntilBars])
        } else {
            let entry = try #require(e.history.entries.last)
            #expect(entry.outcome == .noTextRecognised && entry.note == NoTextPolicy.Reason.micNoAudio.rawValue)
            #expect(entry.raw.isEmpty && entry.final.isEmpty)
            #expect(notices == [PipelineNotice.didntCatchThat])
        }
        if pending {
            gate.release()
            await waitForTest("late start closes after no-audio release") { e.audio.stopped > 0 }
        }
    }

    @Test func interruptedColdCaptureDoesNotSuggestHolding() async {
        let (e, p) = await makeEnv()
        e.audio.samples = []; e.audio.emitsCaptureOnImmediateStart = false
        var notices: [String] = []; p.onNotice = { notices.append($0) }
        p.handle(.startRecording)
        e.audio.interrupt()
        await p.drain()
        #expect(!notices.contains(PipelineNotice.holdUntilBars))
        #expect(notices.contains(PipelineNotice.captureInterrupted))
        #expect(e.history.entries.last?.outcome == .cancelled)
    }

    @Test func escapeDuringColdStartIsRealCancellation() async {
        let (e, p) = await makeEnv()
        let gate = HangGate(); e.audio.startGate = gate
        var notices: [String] = []; p.onNotice = { notices.append($0) }
        let sound = StartSoundSpy(); p.feedbackSounds = sound
        p.handle(.startRecording); p.handle(.cancelDictation)
        #expect(sound.played == [.stop])
        #expect(e.history.entries.last?.outcome == .cancelled)
        #expect(notices == [PipelineNotice.cancelled])
        gate.release()
        await waitForTest("escape closes pending start") { e.audio.stopped == 1 }
    }

    @Test func failedStartResetsGesture() async {
        let (e, p) = await makeEnv()
        let clock = ManualClock()
        p.pipelineClock = clock; e.audio.startClock = clock
        var resets = 0; p.onGestureReset = { resets += 1 }
        p.handle(.startRecording)
        await waitForTest("three-second start sleeper") { clock.sleeperCount > 0 }
        await clock.advance(by: .seconds(3))
        await waitForTest("recorder start callback") { e.audio.startCompletion != nil }
        e.audio.finishStart(.failure(AudioError.noInputDevice))
        #expect(!p.status.isRecording && resets == 1)
    }
}
