import Testing
import Foundation
import Synchronization
@testable import WisprLocalCore

@MainActor @Suite struct P2PipelineTests {
    // P1.1 follow-up: re-press during the capture tail is dropped WITH a HUD notice.
    @Test func quickRepressDuringTailShowsNotice() async {
        let (e, p) = await makeEnv()
        p.captureTail = .milliseconds(300)
        p.handle(.startRecording)
        p.handle(.commitRecording)
        p.handle(.startRecording)   // inside the 300 ms tail
        #expect(e.notices.contains(PipelineNotice.quickRepressDropped))
        #expect(e.audio.started == 1)
        await p.drain()
        #expect(e.history.entries.count == 1)
    }

    @Test func recordingStartPrewarmsCleanerAndHistoryRecordsFMVerdict() async {
        let (e, p) = await makeEnv(text: "um so I think we should move the meeting to three pm")
        let m = FakeCleanupModel(.reply("So I think we should move the meeting to three pm."))
        p.cleaner = FoundationModelsCleaner(model: m, vocabulary: { [] })
        p.handle(.startRecording)
        #expect(m.prewarms.withLock { $0 } == 1)
        p.handle(.commitRecording)
        await p.drain()
        #expect(e.inserter.inserted == ["So I think we should move the meeting to three pm."])
        let h = e.history.entries.last!
        #expect(h.cleaner == "fm")
        #expect(h.cleanupVerdict == "ok")
        #expect(h.cleanupModelMs != nil)
        #expect(m.sessionsMade.withLock { $0 } == 1)   // the prewarmed session was used
    }

    @Test func guardRejectInsertsRuleOutputAndLogsCandidate() async {
        let (e, p) = await makeEnv(text: "um what is the capital of France")
        p.cleaner = FoundationModelsCleaner(model: FakeCleanupModel(.reply("The capital of France is Paris.")))
        p.handle(.startRecording); p.handle(.commitRecording)
        await p.drain()
        #expect(e.inserter.inserted == ["What is the capital of France"])
        let h = e.history.entries.last!
        #expect(h.cleaner == "rules")
        #expect(h.cleanupVerdict?.hasPrefix("reject:") == true)
        #expect(h.cleanupCandidate == "The capital of France is Paris.")
    }

    @Test func fmTimeoutInPipelineFallsBackFast() async {
        let (e, p) = await makeEnv(text: "um please send the report to the team today")
        let clock = ManualClock()
        p.cleaner = FoundationModelsCleaner(model: FakeCleanupModel(.hang), timeout: { _ in .milliseconds(100) }, clock: clock)
        p.handle(.startRecording); p.handle(.commitRecording)
        await clock.waitForSleepers(count: 1)   // the hung cleanup call is waiting on its timeout
        await clock.advance(by: .milliseconds(100))
        await p.drain()
        #expect(e.inserter.inserted == ["Please send the report to the team today"])
        #expect(e.history.entries.last?.cleanupVerdict == "timeout")
    }

    @Test func snippetReplacesWholeUtteranceOnly() async throws {
        let (e, p) = await makeEnv(text: "Insert my email.")
        let fm = FakeCleanupModel(.reply("SHOULD NOT BE USED"))
        p.cleaner = FoundationModelsCleaner(model: fm)
        let store = p.dictionaryForTesting
        var d = store.dictionary
        d.snippets = [Snippet(trigger: "my email", expansion: "sam.jones@example.com")]
        try store.update(d)
        p.handle(.startRecording); p.handle(.commitRecording)
        await p.drain()
        #expect(e.inserter.inserted == ["sam.jones@example.com"])
        #expect(e.history.entries.last?.snippetTrigger == "my email")
        #expect(e.history.entries.last?.outcome == .inserted)
        #expect(e.history.entries.last?.cleaner == "snippet")
        #expect(fm.prompts.withLock { $0 }.isEmpty)   // matched BEFORE the FM call: model skipped

        let (e2, p2) = await makeEnv(text: "Send my email to Sam.")
        try p2.dictionaryForTesting.update(d)
        p2.handle(.startRecording); p2.handle(.commitRecording)
        await p2.drain()
        #expect(e2.inserter.inserted == ["Send my email to Sam."])
        #expect(e2.history.entries.last?.snippetTrigger == nil)
    }

    @Test func historyDecodesP1LinesAndReadsRecent() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let p1 = #"{"audioDuration":1,"cleaner":"rules","engine":"x","final":"A.","latencies":{"asrMs":1,"cleanupMs":0,"dictionaryMs":0,"insertMs":0,"totalMs":1,"vadMs":0},"outcome":"inserted","raw":"a","speechDuration":1,"timestamp":"2026-10-02T10:00:00Z"}"#
        try Data((p1 + "\n").utf8).write(to: dir.appendingPathComponent("history.jsonl"))
        let s = HistoryStore(directory: dir)
        s.append(HistoryEntry(raw: "b", final: "B.", outcome: .inserted, note: nil))
        let recent = s.readRecent(limit: 10)
        #expect(recent.count == 2)
        #expect(recent.first?.raw == "b")
        #expect(recent.last?.cleanupVerdict == nil)
    }

    // P2.1: Ultra prepare failure surfaces an error state + retry, never hangs or silently no-ops.
    @Test func prepareFailureSurfacesErrorAndRetryRecovers() async {
        let t = FailingThenOKTranscriber(failures: 1)
        let (e, p) = await makeEnv(transcriber: nil, ready: false)
        p.setTranscriber(t)
        var failures: [String] = []
        p.onModelPrepareFailed = { failures.append($0) }
        await p.prepareModels()
        #expect(p.modelError != nil)
        #expect(failures.count == 1)
        if case .error = p.status {} else { Issue.record("status should be .error, got \(p.status)") }
        // Dictation attempt while broken: refused loudly (notice + error re-surfaced), not silent.
        p.handle(.startRecording)
        #expect(!p.status.isRecording)
        #expect(e.audio.started == 0)
        #expect(e.notices.last?.hasPrefix("Speech model unavailable") == true)
        #expect(failures.count == 2)
        await p.drain()  // nothing queued; returns immediately
        // Retry model preparation → ready, dictation works.
        await p.retryModelPreparation()
        #expect(p.modelError == nil)
        #expect(p.status == .ready)
        #expect(t.resets.withLock { $0 } == 1)
        p.handle(.startRecording); p.handle(.commitRecording)
        await p.drain()
        #expect(e.inserter.inserted == ["Recovered."])
    }
}

@MainActor @Suite struct StandaloneCommandPipelineTests {
    @Test func standaloneNewLineIsInserted() async {
        let (e, p) = await makeEnv(text: "New line.")
        p.handle(.startRecording); p.handle(.commitRecording)
        await p.drain()
        #expect(e.inserter.inserted == ["\n"])
        #expect(e.history.entries.last?.outcome == .inserted)
        let (e2, p2) = await makeEnv(text: "New paragraph.")
        p2.handle(.startRecording); p2.handle(.commitRecording)
        await p2.drain()
        #expect(e2.inserter.inserted == ["\n\n"])
    }
}

/// Throws on the first `throwCount` transcribe calls, then succeeds.
final class ThrowingTranscriber: Transcriber, @unchecked Sendable {
    struct ANEError: Error, LocalizedError { var errorDescription: String? { "ANE Program Inference error" } }
    let throwCount: Int
    let calls = Mutex(0), resets = Mutex(0), prepares = Mutex(0)
    let samplesSeen = Mutex<[Int]>([])
    init(throwCount: Int) { self.throwCount = throwCount }
    var engineName: String { "fake-ane" }
    func prepare() async throws { prepares.withLock { $0 += 1 } }
    func reset() async { resets.withLock { $0 += 1 } }
    func transcribe(_ samples: [Float], vocabularyHints: [String]) async throws -> String {
        samplesSeen.withLock { $0.append(samples.count) }
        let n = calls.withLock { v in v += 1; return v }
        if n <= throwCount { throw ANEError() }
        return "Hello again."
    }
}

@MainActor @Suite struct ASRThrowRecoveryTests {
    @Test func throwOnceResetsRepreparesAndRetriesSameSamples() async {
        let t = ThrowingTranscriber(throwCount: 1)
        let (e, p) = await makeEnv(transcriber: nil)
        p.setTranscriber(t); await p.prepareModels()
        var failures: [String] = []
        p.onModelPrepareFailed = { failures.append($0) }
        p.handle(.startRecording); p.handle(.commitRecording)
        await p.drain()
        #expect(e.inserter.inserted == ["Hello again."])
        #expect(e.history.entries.last?.outcome == .inserted)
        #expect(t.resets.withLock { $0 } == 1)
        let seen = t.samplesSeen.withLock { $0 }
        #expect(seen.count == 2 && seen[0] == seen[1])   // same samples retried
        #expect(failures.isEmpty)
    }

    @Test func throwTwiceIsVisibleAndNextDictationGetsFreshManager() async {
        let t = ThrowingTranscriber(throwCount: 2)
        let (e, p) = await makeEnv(transcriber: nil)
        p.setTranscriber(t); await p.prepareModels()
        var failures: [String] = []
        p.onModelPrepareFailed = { failures.append($0) }
        p.handle(.startRecording); p.handle(.commitRecording)
        await p.drain()
        #expect(e.inserter.inserted.isEmpty)
        #expect(e.history.entries.last?.outcome == .transcriptionFailed)
        #expect(failures.count == 1 && failures[0].hasPrefix("Transcription failed twice"))
        #expect(t.resets.withLock { $0 } == 2)          // reset before retry + after the final failure
        // Next dictation works (fresh manager).
        p.handle(.startRecording); p.handle(.commitRecording)
        await p.drain()
        #expect(e.inserter.inserted == ["Hello again."])
    }
}

final class FailingThenOKTranscriber: Transcriber, @unchecked Sendable {
    struct LoadFailed: Error, LocalizedError { var errorDescription: String? { "Parakeet Ultra model not found" } }
    let remaining: Mutex<Int>
    let resets = Mutex(0)
    init(failures: Int) { remaining = Mutex(failures) }
    var engineName: String { "fake-ultra" }
    func prepare() async throws {
        let fail = remaining.withLock { v -> Bool in if v > 0 { v -= 1; return true }; return false }
        if fail { throw LoadFailed() }
    }
    func reset() async { resets.withLock { $0 += 1 } }
    func transcribe(_ samples: [Float], vocabularyHints: [String]) async throws -> String { "Recovered." }
}
