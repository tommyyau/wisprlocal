import Testing
import Foundation
import AVFoundation
@preconcurrency import FluidAudio
@testable import WisprLocalCore

/// Pure model-selection tests (no models needed).
@Suite struct ModelSelectionTests {
    @Test func defaultIsV2WithNoFallbackChain() {
        #expect(ASRModelVariant.default == .parakeetV2)
        #expect(FluidAudioTranscriber(variant: .parakeetUltra, locator: ModelLocator(searchRoots: [])).engineName == "fluidaudio:ultra")
    }

    /// A missing model fails loudly (no silent fallback to another model).
    @Test func missingModelThrowsNotInstalled() async {
        let t = FluidAudioTranscriber(variant: .parakeetUltra, locator: ModelLocator(searchRoots: [URL(fileURLWithPath: "/nonexistent")]))
        OfflinePolicy.enableOfflineMode()
        await #expect(throws: TranscriberError.self) { try await t.prepare() }
    }

    /// Keep in sync with scripts/models_common.sh (BUNDLE_MODELS tokens -> folder names).
    @Test func folderNamesMatchScripts() {
        #expect(ASRModelVariant(rawValue: "ultra")?.folderName == "parakeet-ultra")
        #expect(ASRModelVariant(rawValue: "phonon2") == nil)
        #expect(ASRModelVariant(rawValue: "v2")?.folderName == "parakeet-tdt-0.6b-v2")
        #expect(ModelLocator.vadFolderName == "silero-vad")
    }

    @Test func locatorPrefersEarlierRoots() throws {
        let fm = FileManager.default
        let a = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let b = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        for root in [a, b] {
            for f in ["Decoder.mlmodelc", "Encoder.mlmodelc"] {
                try fm.createDirectory(at: root.appendingPathComponent("parakeet-ultra/\(f)"), withIntermediateDirectories: true)
            }
        }
        let loc = ModelLocator(searchRoots: [a, b])
        #expect(loc.asrDirectory(for: .parakeetUltra)?.path == a.appendingPathComponent("parakeet-ultra").path)
        #expect(loc.asrDirectory(for: .parakeetV2) == nil)
        let std = ModelLocator.standard(bundle: .main, environment: ["WISPRLOCAL_MODELS_DIR": a.path])
        #expect(std.searchRoots.first?.path == a.path)
    }
}

/// Integration: real FluidAudio models, test-only fixture WAV made with eSpeak NG. Skips if models are absent
/// unless WISPRLOCAL_REQUIRE_MODELS=1 (set by scripts/test_offline.sh, which also runs the suite
/// under sandbox-exec with network denied). Serialized: touches the global ModelHub flag.
@Suite(.serialized) struct FluidAudioIntegrationTests {
    static let env = ProcessInfo.processInfo.environment
    static let requireModels = AppEnvironment.flag("REQUIRE_MODELS", in: env)

    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()  // .../WisprLocal
    }

    /// Dev search roots: env override, repo .models-cache, legacy App Support, then the spike model dirs.
    static var locator: ModelLocator {
        var roots: [URL] = []
        // Test-only: simulate a machine with no models (fresh-clone / CI check).
        if env["WISPRLOCAL_NO_MODELS"] == "1" { return ModelLocator(searchRoots: []) }
        if let d = AppEnvironment.value("MODELS_DIR", in: env) { roots.append(URL(fileURLWithPath: d)) }
        roots.append(repoRoot.appendingPathComponent("App/.models-cache"))   // scripts/fetch_models.sh
        roots.append(ModelLocator.appSupportModelsDir)                      // legacy dev cache
        roots.append(repoRoot.appendingPathComponent("Spikes/S1b-models/Models"))
        roots.append(repoRoot.appendingPathComponent("Spikes/S1-parakeet/Models"))
        return ModelLocator(searchRoots: roots)
    }

    static var fixtureURL: URL? { Bundle.module.url(forResource: "clip05", withExtension: "wav", subdirectory: "Fixtures") }

    // TS-7: model-dependent tests are SKIPPED (reported as skipped, not passed) via
    // `.enabled(if:)` when weights/fixture are absent. With WISPRLOCAL_REQUIRE_MODELS=1 they run
    // and fail loudly on the missing piece (`#require`).
    static let hasFixture = fixtureURL != nil
    static let hasVAD = locator.vadModelURL() != nil
    static let hasUltra = locator.asrDirectory(for: .parakeetUltra) != nil
    static let hasV2 = locator.asrDirectory(for: .parakeetV2) != nil
    static let v2Ready = requireModels || (hasV2 && hasFixture)
    static let vadReady = requireModels || (hasVAD && hasFixture)
    static let asrReady = requireModels || (hasUltra && hasFixture)
    static let pipelineReady = requireModels || (hasVAD && hasUltra && hasFixture)
    static let skipReason: Comment = "model weights or Fixtures/clip05.wav not found (scripts/fetch_models.sh; WISPRLOCAL_REQUIRE_MODELS=1 to fail instead)"

    /// The 5 s fixture (throws a recorded failure if absent).
    static func fixture() throws -> [Float] {
        let url = try #require(fixtureURL, "Fixtures/clip05.wav missing (regenerate with scripts/make_fixtures.sh)")
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buf)
        return Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength)))
    }

    /// TS-6: never mutates the process-global `ModelHub.offlineMode` (other suites' loaders
    /// read it concurrently); the policy is exercised through its injectable source.
    @Test func offlineFlagAssertion() throws {
        #expect(throws: OfflinePolicy.Violation.self) { try OfflinePolicy.requireOffline(isOffline: { false }) }
        try OfflinePolicy.requireOffline(isOffline: { true })
        OfflinePolicy.enableOfflineMode()
        try OfflinePolicy.requireOffline()
        #expect(ModelHub.offlineMode)
    }

    /// TS-6 (structural): no test may flip the global back off (it races parallel suites).
    @Test func noTestMutatesTheGlobalOfflineFlag() throws {
        let testsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let needle = "offlineMode" + " = " + "false"
        let files = try FileManager.default.contentsOfDirectory(at: testsDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "OfflineGuardTests.swift" }  // its ban list
        #expect(files.count > 20)
        for f in files {
            #expect(!(try String(contentsOf: f, encoding: .utf8)).contains(needle), "\(f.lastPathComponent)")
        }
    }

    /// Loaders only ASSERT offline mode (it's set once at launch); with it off they refuse.
    @Test func loadersRefuseWhenOfflineModeOff() async {
        let t = FluidAudioTranscriber(variant: .parakeetUltra, locator: Self.locator, isOffline: { false })
        await #expect(throws: OfflinePolicy.Violation.self) { try await t.prepare() }
        let v = SileroSpeechTrimmer(locator: Self.locator, isOffline: { false })
        await #expect(throws: OfflinePolicy.Violation.self) { try await v.prepare() }
    }

    @Test(.enabled(if: vadReady, skipReason)) func vadTrimsSpeechAndRejectsSilence() async throws {
        OfflinePolicy.enableOfflineMode()
        try #require(Self.hasVAD, "Silero VAD missing but WISPRLOCAL_REQUIRE_MODELS=1")
        let vad = SileroSpeechTrimmer(locator: Self.locator)
        let s = try Self.fixture()
        let padded = [Float](repeating: 0, count: 48_000) + s + [Float](repeating: 0, count: 48_000)
        let trimmed = try await vad.trim(padded)
        #expect(trimmed != nil)
        #expect((trimmed?.count ?? 0) < padded.count - 48_000)
        #expect(try await vad.trim([Float](repeating: 0, count: 64_000)) == nil)
    }

    @Test(.enabled(if: asrReady, skipReason)) func ultraTranscribesFixtureOffline() async throws {
        OfflinePolicy.enableOfflineMode()
        try #require(Self.hasUltra, "Parakeet Ultra missing but WISPRLOCAL_REQUIRE_MODELS=1")
        let t = FluidAudioTranscriber(variant: .parakeetUltra, locator: Self.locator)
        let clock = ContinuousClock()
        let t0 = clock.now
        try await t.prepare()
        let load = clock.now - t0
        let s = try Self.fixture()
        let t1 = clock.now
        let text = try await t.transcribe(s)
        print("ULTRA load=\(load) asr=\(clock.now - t1) text=\(text)")
        #expect(t.engineName == "fluidaudio:ultra")
        Self.checkTranscript(text)
    }

    /// The DEFAULT model ("English (Parakeet v2)"), and a real unload → reload cycle.
    @Test(.enabled(if: v2Ready, skipReason)) func v2TranscribesFixtureOfflineAndReloadsAfterUnload() async throws {
        OfflinePolicy.enableOfflineMode()
        try #require(Self.hasV2, "Parakeet v2 missing but WISPRLOCAL_REQUIRE_MODELS=1")
        let t = FluidAudioTranscriber(variant: .parakeetV2, locator: Self.locator)
        try await t.prepare()
        #expect(await t.isReady)
        let s = try Self.fixture()
        let text = try await t.transcribe(s)
        print("V2 text=\(text)")
        #expect(t.engineName == "fluidaudio:v2")
        Self.checkTranscript(text)
        await t.unload()
        #expect(await !t.isReady)
        let again = try await t.transcribe(s)  // reloads lazily (ANE cache warm)
        #expect(again == text)
    }

    static func checkTranscript(_ text: String) {
        let final = UserDictionary.seed.apply(to: text)
        let lower = final.lowercased()
        #expect(lower.contains("laptop"), "got: \(text)")
        #expect(lower.contains("tailscale"), "got: \(text)")
        #expect(final.contains("Wispr Flow"), "got: \(text) -> \(final)")
    }
}

@Suite struct BundledModelLocatorTests {

    @Test func bundledAppIgnoresBothEnvironmentOverrides() {
        let locator = ModelLocator.standard(environment: ["WISPRLOCAL_MODELS_DIR": "/env-models",
                                                          AppEnvironment.legacyPrefix + "MODELS_DIR": "/legacy-models"], runningFromBundle: true)
        #expect(!locator.searchRoots.contains(URL(fileURLWithPath: "/env-models")))
        #expect(!locator.searchRoots.contains(URL(fileURLWithPath: "/legacy-models")))
        #expect(!locator.searchRoots.contains(ModelLocator.appSupportModelsDir))
    }

}
