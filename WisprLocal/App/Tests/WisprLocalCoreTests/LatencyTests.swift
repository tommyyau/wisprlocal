import AppKit
import Testing
import Foundation
import Synchronization
@testable import WisprLocalCore

// Release-to-text latency (STRUCTURAL): paste posted without waiting for the clipboard restore,
// FM only where it can help (CleanupPolicy) and capped at 1.5 s, adaptive capture tail,
// perceivedMs recorded, and a warm benchmark on the fixture.

@Suite struct CleanupPolicyTests {
    @Test func userEnabledAlwaysUsesModel() {
        #expect(CleanupPolicy.decide(text: "hello there how are you", userEnabled: true, autoAvailable: true) == .model)
        #expect(CleanupPolicy.decide(text: "hello there how are you", userEnabled: true, autoAvailable: false) == .model)
    }

    @Test func offWithoutListCuesUsesRules() {
        for t in ["I think we should move the meeting to three pm",
                  "one of the two options is fine",
                  "the first thing I noticed was the noise",       // "first" without "second"
                  "we need a new line of products",                // single "new line"
                  "ok", ""] {
            #expect(CleanupPolicy.decide(text: t, userEnabled: false, autoAvailable: true) == .rules, "\(t)")
        }
    }

    @Test func offWithListCuesUsesAutoModel() {
        let cases: [(String, String)] = [
            ("first we buy milk second we buy eggs", "first/second"),
            ("Firstly, the API. Secondly, the UI.", "first/second"),
            ("number one milk number two eggs", "number one/two"),
            ("point 1 latency point 2 cost", "point one/two"),
            ("bullet point milk bullet point eggs", "bullet point"),
            ("my list one, two, three, go", "one/two/three"),
            ("1. Milk 2. Eggs", "1./2."),
            ("dear John new line thanks new line Sam", "new line ×2"),
        ]
        for (t, cue) in cases {
            #expect(CleanupPolicy.decide(text: t, userEnabled: false, autoAvailable: true) == .autoModel(cue: cue), "\(t)")
        }
    }

    @Test func offWithCuesButNoAutoFormatterUsesRules() {
        #expect(CleanupPolicy.decide(text: "number one milk number two eggs", userEnabled: false, autoAvailable: false) == .rules)
    }

    @Test func modelTimeoutIsCappedAt1500ms() {
        #expect(CleanupPolicy.modelTimeout(.seconds(5)) == .milliseconds(1500))
        #expect(CleanupPolicy.modelTimeout(.milliseconds(800)) == .milliseconds(800))
        #expect(CleanupPolicy.modelTimeout(FoundationModelsCleaner.adaptiveTimeout(words: 1000)) == .milliseconds(1500))
    }

    @Test func fmCallNeverExceedsCapEvenWithLongFormula() async {
        let clock = ManualClock()
        let c = FoundationModelsCleaner(model: FakeCleanupModel(.hang), timeout: { _ in .seconds(5) }, clock: clock)
        let run = Task { await c.cleanDetailed("so I think we should move the meeting to three PM") }
        await clock.waitForSleepers(count: 1)
        #expect(clock.nextDeadline == CleanupPolicy.maxModelTimeout, "the formula's 5 s is capped")
        await clock.advance(by: CleanupPolicy.maxModelTimeout)
        let r = await run.value
        #expect(r.verdict == "timeout")
    }

    @MainActor @Test func aiFormattingDefaultsOffAndIgnoresLegacyKey() {
        let d = UserDefaults(suiteName: "wl-test-\(UUID().uuidString)")!
        d.set(true, forKey: "aiCleanupEnabled")   // pre-latency-fix default-ON key
        let s = AppSettings(defaults: d)
        #expect(s.aiCleanupEnabled == false)
        s.aiCleanupEnabled = true
        #expect(AppSettings(defaults: d).aiCleanupEnabled == true)
    }
}

@MainActor @Suite struct AutoFormattingPipelineTests {
    @Test func settingOffSkipsModelWithoutListCues() async {
        let (e, p) = await makeEnv(text: "so I think we should move the meeting to three pm")
        let m = FakeCleanupModel(.echo)
        p.autoFormatter = FoundationModelsCleaner(model: m)
        p.handle(.startRecording); p.handle(.commitRecording); await p.drain()
        #expect(m.prompts.withLock { $0.count } == 0)
        #expect(e.history.entries.last?.cleaner == "rules")
    }

    @Test func settingOffRunsModelOnListCues() async {
        let (e, p) = await makeEnv(text: "number one milk number two eggs")
        let m = FakeCleanupModel(.reply("1. Milk\n2. Eggs"))
        p.autoFormatter = FoundationModelsCleaner(model: m)
        p.handle(.startRecording)
        #expect(m.prewarms.withLock { $0 } == 1)   // prewarmed while speaking
        p.handle(.commitRecording); await p.drain()
        #expect(m.prompts.withLock { $0.count } == 1)
        let h = e.history.entries.last!
        #expect(h.cleanupVerdict?.hasPrefix("auto(number one/two):") == true)
    }

    @Test func settingOnDoesNotUseAutoFormatter() async {
        let (e, p) = await makeEnv(text: "number one milk number two eggs")
        let auto = FakeCleanupModel(.echo), user = FakeCleanupModel(.echo)
        p.autoFormatter = FoundationModelsCleaner(model: auto)
        p.cleaner = FoundationModelsCleaner(model: user)
        p.handle(.startRecording); p.handle(.commitRecording); await p.drain()
        #expect(auto.prompts.withLock { $0.count } == 0)
        #expect(auto.prewarms.withLock { $0 } == 0)
        #expect(user.prompts.withLock { $0.count } == 1)
        #expect(e.history.entries.count == 1)
    }

    @Test func historyRecordsPerceivedAndStageBreakdown() async {
        let (e, p) = await makeEnv()
        p.captureTail = .milliseconds(200)
        p.handle(.startRecording); p.handle(.commitRecording); await p.drain()
        let l = e.history.entries.last!.latencies
        #expect(l.tailMs != nil)   // FakeAudio returns at once; the real recorder waits 150–400 ms
        #expect(l.perceivedMs != nil)
        #expect(l.perceivedMs! <= l.totalMs)
        #expect(l.perceivedMs! >= l.tailMs!)
        #expect(l.handoffMs != nil && l.joinMs != nil && l.gatesMs != nil)
    }

    @Test func pipelineUsesAdaptiveTailByDefault() async {
        let (e, p) = await makeEnv()
        defer { withExtendedLifetime(e) {} }
        p.captureTail = DictationPipeline.defaultCaptureTail
        #expect(p.captureTailPolicy == .default)
        p.adaptiveTail = false
        #expect(p.captureTailPolicy == .fixed(.milliseconds(400)))
    }

    @Test func caretReadStartsBeforeInsertion() async {
        // The caret context is read concurrently with ASR (not after it).
        let tr = FakeTranscriber(text: "Hello there, this is a test.", hangCalls: 1)
        let (e, p) = await makeEnv(transcriber: tr)
        p.handle(.startRecording); p.handle(.commitRecording)
        await eventually { e.caret.reads == [42] }       // read while ASR is still blocked
        #expect(e.inserter.inserted.isEmpty && tr.callCount == 1)
        tr.release()
        await p.drain()
        #expect(e.inserter.inserted.count == 1)
        #expect(e.caret.reads == [42])
    }

    @Test func oldHistoryLinesWithoutNewFieldsStillDecode() throws {
        let line = #"{"asrMs":1,"cleanupMs":0,"dictionaryMs":0,"insertMs":0,"totalMs":1,"vadMs":0}"#
        let t = try JSONDecoder().decode(StageTimings.self, from: Data(line.utf8))
        #expect(t.perceivedMs == nil && t.tailMs == nil)
    }
}

@MainActor @Suite struct PasteInserterLatencyTests {
    func board() -> NSPasteboard { NSPasteboard(name: NSPasteboard.Name("wl-test-\(UUID().uuidString)")) }

    @Test func returnsAsSoonAsPasteIsPostedAndRestoresLater() async throws {
        let pb = board()
        pb.clearContents(); pb.setString("user clipboard", forType: .string)
        var posted = 0
        let clock = ManualClock()
        let ins = PasteInserter(pasteboard: pb, restoreDelay: .milliseconds(300), postPaste: { posted += 1 }, clock: clock)
        try await ins.insert("dictated")                     // returns with no time having passed: never waits the restore delay
        #expect(clock.now == .zero)
        #expect(posted == 1)
        #expect(pb.string(forType: .string) == "dictated")    // target app reads this
        #expect(ins.restorePending)
        await clock.waitForSleepers(count: 1)
        #expect(clock.nextDeadline == .milliseconds(300))
        await clock.advance(by: .milliseconds(300))
        await ins.waitForRestore()
        #expect(pb.string(forType: .string) == "user clipboard")
        #expect(!ins.restorePending)
    }

    @Test func backToBackPastesKeepTheOriginalClipboard() async throws {
        let pb = board()
        pb.clearContents(); pb.setString("original", forType: .string)
        let clock = ManualClock()
        let ins = PasteInserter(pasteboard: pb, restoreDelay: .milliseconds(200), postPaste: {}, clock: clock)
        try await ins.insert("first")
        try await ins.insert("second")                       // before the first restore ran
        #expect(pb.string(forType: .string) == "second")
        await clock.waitForSleepers(count: 1)         // only the second restore is pending
        await clock.advance(by: .milliseconds(200))
        await ins.waitForRestore()
        #expect(pb.string(forType: .string) == "original")
    }

    @Test func foreignClipboardChangeIsNotOverwritten() async throws {
        let pb = board()
        pb.clearContents(); pb.setString("original", forType: .string)
        let ins = PasteInserter(pasteboard: pb, restoreDelay: .milliseconds(100), postPaste: {})
        try await ins.insert("dictated")
        pb.clearContents(); pb.setString("user copied meanwhile", forType: .string)
        await ins.waitForRestore()
        #expect(pb.string(forType: .string) == "user copied meanwhile")
    }

    @Test func failedPostRestoresImmediately() async {
        let pb = board()
        pb.clearContents(); pb.setString("original", forType: .string)
        let ins = PasteInserter(pasteboard: pb, postPaste: { throw InsertionError.notTrusted })
        await #expect(throws: InsertionError.self) { try await ins.insert("dictated") }
        #expect(pb.string(forType: .string) == "original")
        #expect(!ins.restorePending)
    }
}

@Suite struct CaptureTailPolicyTests {
    let p = CaptureTailPolicy.default
    static func tone(_ n: Int, amp: Float) -> [Float] { (0..<n).map { amp * sin(Float($0) * 0.2) } }

    @Test func defaultsAre150to400With120msSilence() {
        #expect(p.minimum == .milliseconds(150) && p.maximum == .milliseconds(400) && p.silence == .milliseconds(120))
    }

    @Test func stopDecision() {
        #expect(!p.shouldStop(elapsed: .milliseconds(100), endsInSilence: true))    // below minimum
        #expect(p.shouldStop(elapsed: .milliseconds(150), endsInSilence: true))
        #expect(!p.shouldStop(elapsed: .milliseconds(300), endsInSilence: false))   // still speaking
        #expect(p.shouldStop(elapsed: .milliseconds(400), endsInSilence: false))    // hard cap
    }

    @Test func silenceDetectionIsRelativeToTheRecording() {
        let speech = Self.tone(16_000, amp: 0.3), noise = Self.tone(8_000, amp: 0.001)
        let rec = noise + speech + noise
        let th = p.threshold(for: rec[...])
        #expect(th >= p.minThreshold && th <= p.maxThreshold)
        #expect(p.endsInSilence((speech + Self.tone(2_400, amp: 0.001))[...], threshold: th))   // 150 ms quiet
        #expect(!p.endsInSilence((speech + Self.tone(1_000, amp: 0.001))[...], threshold: th))  // only 62 ms quiet
        #expect(!p.endsInSilence(speech[...], threshold: th))
        // A soft fricative ending (−36 dBFS) is NOT silence.
        #expect(!p.endsInSilence((speech + Self.tone(2_400, amp: 0.016))[...], threshold: th))
    }

    @Test func fixedPolicyNeverStopsEarly() {
        let f = CaptureTailPolicy.fixed(.milliseconds(400))
        #expect(!f.shouldStop(elapsed: .milliseconds(399), endsInSilence: true))
        #expect(f.shouldStop(elapsed: .milliseconds(400), endsInSilence: true))
    }
}

/// Warm benchmark on the 5 s fixture: REAL VAD + Parakeet Ultra + the production default cleaner
/// (AI formatting OFF → rules, auto formatter armed). Fake: audio capture (tail excluded) and the
/// key-event post (headless). Asserts warm perceivedMs < 600 ms and logs the stage breakdown.
@MainActor @Suite(.serialized) struct LatencyBenchmarkTests {
    /// Opt-in (wall-clock, machine-dependent): `WISPRLOCAL_LATENCY_BENCH=1 swift test --filter LatencyBenchmarkTests`.
    nonisolated static let benchEnabled = AppEnvironment.flag("LATENCY_BENCH")

    @Test(.enabled(if: benchEnabled, "set WISPRLOCAL_LATENCY_BENCH=1"),
          .enabled(if: FluidAudioIntegrationTests.pipelineReady, FluidAudioIntegrationTests.skipReason))
    func warmPerceivedUnder600msOnFixture() async throws {
        OfflinePolicy.enableOfflineMode()
        let locator = FluidAudioIntegrationTests.locator
        try #require(FluidAudioIntegrationTests.hasVAD && FluidAudioIntegrationTests.hasUltra,
                     "models missing but WISPRLOCAL_REQUIRE_MODELS=1")
        let speech = try FluidAudioIntegrationTests.fixture()
        #expect(abs(Double(speech.count) / AudioConstants.sampleRate - 5) < 1.5, "fixture should be ~5 s")
        let audio = FakeAudio()
        audio.samples = [Float](repeating: 0, count: 4_000) + speech + [Float](repeating: 0, count: 4_000)
        let history = MemoryHistory(), inserter = FakeInserter()
        let dictionary = tempDictionary()
        let p = DictationPipeline(
            audio: audio, trimmer: SileroSpeechTrimmer(locator: locator),
            transcriber: FluidAudioTranscriber(variant: .parakeetUltra, locator: locator),
            dictionary: dictionary, cleaner: RuleCleaner(),   // AppSettings default: AI formatting OFF
            gate: ConflictDetector(runningApps: { [] }, fnUsageReader: { 0 }),
            secureInput: FakeSecureInput(), clipboard: FakeClipboard(),
            inserterFor: { _ in (inserter, .paste) }, history: history,
            frontmostApp: { FrontmostApp(pid: 1, bundleID: "x") }, caretReader: FakeCaretReader(),
            debugRecordings: nil, autoFormatter: .system)
        p.captureTail = .zero   // tail excluded (reported separately in real use: 150–400 ms)
        await p.prepareModels()
        try #require(p.modelReady, "models not prepared: \(p.status)")
        for _ in 0..<8 {
            p.handle(.startRecording)
            try? await Task.sleep(for: .milliseconds(100))
            p.handle(.commitRecording)
            await p.drain()
        }
        let warm = Array(history.entries.dropFirst(2))
        try #require(warm.allSatisfy { $0.outcome == .inserted }, "\(warm.map(\.outcome))")
        func p50(_ f: (StageTimings) -> Double) -> Double { let s = warm.map { f($0.latencies) }.sorted(); return s[s.count / 2] }
        let perceived = p50 { $0.perceivedMs ?? .infinity }
        print(String(format: "LATENCY n=%d | handoff %.1f | vad %.1f | asr %.1f | dict %.2f | cleanup %.2f (%@) | gates %.2f | join %.2f | insert %.2f | perceived p50 %.1f | total %.1f ms",
                     warm.count, p50 { $0.handoffMs ?? 0 }, p50(\.vadMs), p50(\.asrMs), p50(\.dictionaryMs), p50(\.cleanupMs),
                     warm.last?.cleaner ?? "?", p50 { $0.gatesMs ?? 0 }, p50 { $0.joinMs ?? 0 }, p50(\.insertMs), perceived, p50(\.totalMs)))
        print("LATENCY text:", warm.last?.final ?? "")
        #expect(perceived < 600, "warm perceivedMs p50 \(perceived) ms ≥ 600 ms")
    }
}
