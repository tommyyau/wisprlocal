@preconcurrency import CoreML
@preconcurrency import FluidAudio
import Foundation
import Synchronization

public protocol Transcriber: Sendable {
    /// Short engine id recorded in history (e.g. "fluidaudio:ultra").
    var engineName: String { get }
    /// Load + warm the model (first-ever load compiles for the ANE, ~27 s).
    func prepare() async throws
    /// `vocabularyHints` is reserved for decode-time biasing (post-benchmark); implementations
    /// may ignore it. The dictionary is currently applied as replacement rules after ASR.
    func transcribe(_ samples: [Float], vocabularyHints: [String]) async throws -> String
    /// Drop the loaded engine after a hung decode; the next call reloads (cached: <1 s).
    func reset() async
    /// Free the model's memory (mode switch: only the active model stays loaded). Only called
    /// when nothing is decoding on this engine. The next call reloads (ANE cache: < 1 s).
    func unload() async
}

extension Transcriber {
    public func reset() async {}
    public func unload() async { await reset() }

    public func transcribe(_ samples: [Float]) async throws -> String {
        try await transcribe(samples, vocabularyHints: [])
    }
}

public enum TranscriberError: Error, LocalizedError {
    case notInstalled(String, searched: [URL])
    public var errorDescription: String? {
        switch self {
        case .notInstalled(let name, let roots):
            return "\(name) model not found (looked in \(roots.map(\.path).joined(separator: ", "))). Reinstall WisprLocal or run scripts/fetch_models.sh."
        }
    }
}

/// FluidAudio TDT transcriber (Parakeet v2 by default; Ultra in "Noisy room" mode), loaded strictly from a local
/// directory via `AsrModels.loadLocal(from:version:configuration:encoderPrecision:
/// encoderComputeUnits:)` (verified in FluidAudio 0.17.5 `AsrModels.swift:263`) — a synchronous
/// `MLModel(contentsOf:)` path with no ModelHub/HuggingFace code at all — with
/// `ModelHub.offlineMode` asserted on as a second line of defence.
///
/// Compute units are pinned to `.cpuAndNeuralEngine` for every component, encoder included:
/// the GPU encoder path reportedly costs ~150 s of compile per launch.
///
/// No automatic fallback between models: if the active variant fails to load, `prepare()` throws
/// and the app shows the error with a "Retry model preparation" action (per model: Retry acts on
/// whichever engine is active).
public actor FluidAudioTranscriber: Transcriber {
    public nonisolated let requestedVariant: ASRModelVariant
    private let locator: ModelLocator
    private var manager: AsrManager?
    private var loading: Task<AsrManager, Error>?
    /// Bumped by `unload()`; a load that started before it is not stored.
    private var epoch = 0
    /// Offline assertion source (TS-6: tests inject `{ false }` instead of flipping the
    /// process-global `ModelHub.offlineMode`, which raced other suites).
    private let isOffline: @Sendable () -> Bool

    public init(variant: ASRModelVariant = .default, locator: ModelLocator = .standard(),
                isOffline: @escaping @Sendable () -> Bool = { ModelHub.offlineMode }) {
        self.requestedVariant = variant
        self.locator = locator
        self.isOffline = isOffline
    }

    public nonisolated var engineName: String { "fluidaudio:\(requestedVariant.rawValue)" }

    public var isReady: Bool { manager != nil }

    public func prepare() async throws { _ = try await loadedManager() }

    private func loadedManager() async throws -> AsrManager {
        if let manager { return manager }
        if let loading { return try await loading.value }
        try OfflinePolicy.requireOffline(isOffline: isOffline)  // set once at app launch; loaders only assert
        let variant = requestedVariant
        guard let dir = locator.asrDirectory(for: variant) else {
            throw TranscriberError.notInstalled(variant.displayName, searched: locator.searchRoots)
        }
        let isOffline = self.isOffline
        let task = Task<AsrManager, Error> { try await Self.load(variant: variant, dir: dir, isOffline: isOffline) }
        loading = task
        let started = epoch
        do {
            let m = try await task.value
            if started == epoch { manager = m; loading = nil }
            return m
        } catch {
            if started == epoch { loading = nil }
            Log.error("ASR load failed: \(error.localizedDescription)")
            throw error
        }
    }

    private static func load(variant: ASRModelVariant, dir: URL, isOffline: @Sendable () -> Bool) async throws -> AsrManager {
        try OfflinePolicy.requireOffline(isOffline: isOffline)
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine
        let models = try AsrModels.loadLocal(from: dir, version: variant.fluidVersion,
                                             configuration: config,
                                             encoderComputeUnits: .cpuAndNeuralEngine)
        let asr = AsrManager(config: .default)
        try await asr.loadModels(models)
        // Warm-up pass so the first real utterance doesn't pay graph setup / ANE prepare.
        var st = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
        _ = try await asr.transcribe([Float](repeating: 0, count: 16_000), decoderState: &st)
        return asr
    }

    public func reset() async {
        manager = nil
        loading = nil
    }

    /// Mode switch: drop the engine AND free its CoreML models. A load still in flight finishes
    /// for its own caller but is not kept (`epoch`), so an unloaded engine never comes back.
    public func unload() async {
        epoch &+= 1
        let m = manager
        manager = nil
        loading = nil
        await m?.cleanup()
    }

    public func transcribe(_ samples: [Float], vocabularyHints: [String]) async throws -> String {
        let asr = try await loadedManager()
        var st = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
        let result = try await asr.transcribe(samples, decoderState: &st)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
