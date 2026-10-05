import Testing
import Foundation
@testable import WisprLocalCore

@Suite struct SpeechTrimPaddingTests {
    // 16 kHz: 300 ms = 4800 samples, 400 ms = 6400 samples.
    @Test func padsGenerouslyAroundSpeech() {
        let r = SileroSpeechTrimmer.keptRange(speechStart: 16_000, speechEnd: 48_000, count: 80_000,
                                              sampleRate: 16_000, preRoll: 0.3, postRoll: 0.4)
        #expect(r == 11_200..<54_400)
    }

    @Test func clampsToBufferAndNeverCutsSpeech() {
        let r = SileroSpeechTrimmer.keptRange(speechStart: 1_000, speechEnd: 79_000, count: 80_000,
                                              sampleRate: 16_000, preRoll: 0.3, postRoll: 0.4)
        #expect(r == 0..<80_000)
    }

    @Test func defaultsAreAtLeastSpec() async {
        let t = SileroSpeechTrimmer()
        #expect(t.preRoll >= 0.3)
        #expect(t.postRoll >= 0.4)
    }

    @MainActor @Test func captureTailDefaultIsGenerous() {
        #expect(DictationPipeline.defaultCaptureTail >= .milliseconds(300))
    }
}

@Suite struct ModelLocatorBundleTests {
    @Test func installedAppNeverSearchesAppSupportModels() throws {
        let fake = FileManager.default.temporaryDirectory.appendingPathComponent("wl-bundle-\(UUID().uuidString).app")
        let res = fake.appendingPathComponent("Contents/Resources/Models", isDirectory: true)
        try FileManager.default.createDirectory(at: res, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fake) }
        let info = fake.appendingPathComponent("Contents/Info.plist")
        try (["CFBundleIdentifier": "test.wl", "CFBundlePackageType": "APPL"] as NSDictionary).write(to: info)
        let bundle = try #require(Bundle(url: fake))
        let loc = ModelLocator.standard(bundle: bundle, environment: [:])
        #expect(!loc.searchRoots.contains(ModelLocator.appSupportModelsDir))
        #expect(loc.searchRoots.first?.lastPathComponent == "Models")
    }
}

@Suite struct DebugRecordingStoreTests {
    func tempStore(limit: Int = 3, enabled: Bool = true) -> DebugRecordingStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wl-debug-\(UUID().uuidString)")
        return DebugRecordingStore(directory: dir, limit: limit, isEnabled: { enabled })
    }

    @Test func wavRoundTrip() throws {
        let s: [Float] = [0, 0.5, -0.5, 1, -1, 0.25]
        let (out, rate) = try WAV.decode(WAV.encode(s, sampleRate: 16_000))
        #expect(rate == 16_000)
        #expect(out.count == s.count)
        for (a, b) in zip(s, out) { #expect(abs(a - b) < 0.0001) }
    }

    @Test func savesWavAndSidecarAndKeepsRollingLimit() throws {
        let store = tempStore(limit: 3)
        defer { store.deleteAll() }
        for i in 0..<5 {
            var e = HistoryEntry(timestamp: Date(timeIntervalSince1970: 1_000 + Double(i)), outcome: .inserted)
            e.raw = "raw \(i)"; e.final = "Final \(i)."
            #expect(store.save(samples: [Float](repeating: 0.1, count: 1600), entry: e) != nil)
        }
        let wavs = store.recordings()
        #expect(wavs.count == 3)
        let sidecar = wavs.last!.deletingPathExtension().appendingPathExtension("json")
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: sidecar)) as? [String: Any]
        #expect(obj?["raw"] as? String == "raw 4")
        #expect(obj?["final"] as? String == "Final 4.")
        let all = try FileManager.default.contentsOfDirectory(atPath: store.directory.path)
        #expect(all.count == 6)   // 3 wav + 3 json, oldest pruned
        store.deleteAll()
        #expect(store.recordings().isEmpty)
    }

    @Test func offByDefault() {
        let d = UserDefaults(suiteName: "wl-test-\(UUID().uuidString)")!
        #expect(d.bool(forKey: DebugRecordingStore.defaultsKey) == false)
    }

    @MainActor @Test func pipelineSavesOnlyWhenEnabled() async throws {
        for enabled in [false, true] {
            let store = tempStore(limit: 20, enabled: enabled)
            defer { store.deleteAll() }
            let env = PipelineEnv(text: "Hello there, this is a test.", speech: true, transcriber: nil)
            let p = DictationPipeline(
                audio: env.audio, trimmer: FakeTrimmer(hasSpeech: true), transcriber: env.transcriber,
                dictionary: tempDictionary(), cleaner: RuleCleaner(),
                gate: ConflictDetector(runningApps: { [] }, fnUsageReader: { 0 }),
                secureInput: env.secure, clipboard: env.clipboard,
                inserterFor: { [inserter = env.inserter] _ in (inserter, .paste) }, history: env.history,
                frontmostApp: { FrontmostApp(pid: 42, bundleID: "x") }, caretReader: env.caret, debugRecordings: store, autoFormatter: .none)
            p.captureTail = .zero
            await p.prepareModels()
            p.handle(.startRecording); p.handle(.commitRecording); await p.drain()
            await p.flushDebugRecordings()   // the save runs detached; wait for it to finish
            #expect(store.recordings().count == (enabled ? 1 : 0))
        }
    }
}

@Suite struct MalformedWAVTests {

    @Test(arguments: [0, 1, 2, 15]) func shortFormatChunkThrows(_ size: Int) {
        var data = Data("RIFF".utf8)
        data.append(contentsOf: [12, 0, 0, 0]); data.append(contentsOf: "WAVEfmt ".utf8)
        data.append(contentsOf: [UInt8(size), 0, 0, 0]); data.append(Data(repeating: 0, count: size))
        #expect(throws: WAV.DecodeError.self) { try WAV.decode(data) }
    }
    @Test func everyTruncatedPrefixThrows() {
        let valid = WAV.encode([0.5], sampleRate: 16_000)
        for length in 0..<valid.count {
            #expect(throws: WAV.DecodeError.self) { try WAV.decode(Data(valid.prefix(length))) }
        }
    }

}
