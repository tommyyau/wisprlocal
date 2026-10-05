import Testing
import Foundation
@testable import WisprLocalCore

/// Opt-in: `WISPRLOCAL_PROFILE=1 WISPRLOCAL_MODELS_DIR=<…/WisprLocal.app/Contents/Resources/Models> swift test --filter ProfileTests`.
/// Warm release-to-insert path on the fixture with REAL VAD + Ultra + production cleaner; stage
/// timings are read back from history. (Insertion uses a fake inserter: posting key events is
/// not allowed headless. The 200 ms capture tail is excluded and reported separately.)
@MainActor @Suite(.serialized) struct ProfileTests {
    nonisolated static let enabled = AppEnvironment.flag("PROFILE")

    @Test(.enabled(if: enabled, "set WISPRLOCAL_PROFILE=1"))
    func warmReleaseToInsert() async throws {
        OfflinePolicy.enableOfflineMode()
        let locator = FluidAudioIntegrationTests.locator
        let speech = try FluidAudioIntegrationTests.fixture()
        let audio = FakeAudio()
        audio.samples = [Float](repeating: 0, count: 8_000) + speech + [Float](repeating: 0, count: 8_000)
        let history = MemoryHistory(), inserter = FakeInserter()
        let cleaner: TextCleaner = SystemCleanupModel.currentAvailability.isAvailable
            ? FoundationModelsCleaner(vocabulary: { ["Wispr Flow", "Tailscale"] }) : RuleCleaner()
        let p = DictationPipeline(
            audio: audio, trimmer: SileroSpeechTrimmer(locator: locator),
            transcriber: FluidAudioTranscriber(variant: .parakeetUltra, locator: locator),
            dictionary: tempDictionary(), cleaner: cleaner,
            gate: ConflictDetector(runningApps: { [] }, fnUsageReader: { 0 }),
            secureInput: FakeSecureInput(), clipboard: FakeClipboard(),
            inserterFor: { _ in (inserter, .paste) }, history: history,
            frontmostApp: { FrontmostApp(pid: 1, bundleID: "x") }, caretReader: FakeCaretReader(), debugRecordings: nil)
        p.captureTail = .zero
        await p.prepareModels()
        try #require(p.modelReady, "models not prepared: \(p.status)")
        let runs = 12
        for i in 0..<(runs + 2) {
            p.handle(.startRecording)
            try? await Task.sleep(for: .milliseconds(400))  // "speaking" while the FM session prewarms
            p.handle(.commitRecording)
            await p.drain()
            _ = i
        }
        let warm = Array(history.entries.dropFirst(2))
        func p50(_ k: KeyPath<StageTimings, Double>) -> Double { let s = warm.map { $0.latencies[keyPath: k] }.sorted(); return s[s.count / 2] }
        func p95(_ k: KeyPath<StageTimings, Double>) -> Double { let s = warm.map { $0.latencies[keyPath: k] }.sorted(); return s[min(s.count - 1, Int(Double(s.count) * 0.95))] }
        print(String(format: "PROFILE n=%d cleaner=%@ | vad p50 %.1f | asr p50 %.1f | dict p50 %.2f | cleanup p50 %.1f (p95 %.1f) | insert p50 %.2f | total p50 %.1f p95 %.1f ms",
                     warm.count, warm.last?.cleaner ?? "?", p50(\.vadMs), p50(\.asrMs), p50(\.dictionaryMs), p50(\.cleanupMs), p95(\.cleanupMs),
                     p50(\.insertMs), p50(\.totalMs), p95(\.totalMs)))
        print("PROFILE per-run cleanup/model ms:", warm.map { "\(Int($0.latencies.cleanupMs))/\(Int($0.cleanupModelMs ?? -1))" }.joined(separator: " "))
        print("PROFILE text:", warm.last?.final ?? "", "| verdict:", warm.last?.cleanupVerdict ?? "-", "| fm ms:", warm.last?.cleanupModelMs ?? -1)
        // Non-model CPU work on the path (guard + rules + dictionary), measured directly.
        let raw = warm.last?.raw ?? "", out = warm.last?.final ?? ""
        let clock = ContinuousClock(), t0 = clock.now
        for _ in 0..<200 { _ = OutputGuard.check(raw: raw, output: out, vocabulary: ["Wispr Flow", "Tailscale"]) }
        let g = durationMs(clock.now - t0) / 200
        let t1 = clock.now
        for _ in 0..<200 { _ = RuleCleaner().cleanSync(raw) }
        let r = durationMs(clock.now - t1) / 200
        let long = FMIntegrationTests.realistic.joined(separator: " ")
        let t2 = clock.now
        for _ in 0..<20 { _ = OutputGuard.check(raw: long, output: long) }
        let gl = durationMs(clock.now - t2) / 20
        print(String(format: "PROFILE guard %.3f ms (fixture) / %.2f ms (%d-word input) | rules %.3f ms", g, gl, OutputGuard.words(long).count, r))
    }
}
