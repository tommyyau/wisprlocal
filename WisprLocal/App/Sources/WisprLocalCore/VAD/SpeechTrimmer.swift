@preconcurrency import CoreML
@preconcurrency import FluidAudio
import Foundation

public protocol SpeechTrimmer: Sendable {
    func prepare() async throws
    /// Returns the samples from the first speech onset to the last speech offset, or nil if
    /// there is no speech (the pipeline then skips ASR and inserts nothing).
    func trim(_ samples: [Float]) async throws -> [Float]?
}

/// Silero VAD (FluidAudio), loaded with `MLModel(contentsOf:)` straight from disk — no ModelHub.
public actor SileroSpeechTrimmer: SpeechTrimmer {
    private let locator: ModelLocator
    private var vad: VadManager?
    /// Total speech shorter than this is treated as no speech (clicks, breaths).
    public let minSpeech: TimeInterval
    /// Audio kept before the first / after the last detected speech (on top of FluidAudio's own
    /// 0.1 s pad). Generous on purpose: soft onsets/endings ("…at the moment") fall below the
    /// Silero threshold, and padding costs nothing (Parakeet ignores silence).
    nonisolated public let preRoll: TimeInterval
    nonisolated public let postRoll: TimeInterval
    /// Offline assertion source (TS-6: injected in tests; never mutate the global).
    private let isOffline: @Sendable () -> Bool

    public init(locator: ModelLocator = .standard(), minSpeech: TimeInterval = 0.15,
                preRoll: TimeInterval = 0.3, postRoll: TimeInterval = 0.4,
                isOffline: @escaping @Sendable () -> Bool = { ModelHub.offlineMode }) {
        self.isOffline = isOffline
        self.locator = locator
        self.minSpeech = minSpeech
        self.preRoll = preRoll
        self.postRoll = postRoll
    }

    /// Pure: the kept range [speechStart - preRoll, speechEnd + postRoll] clamped to the buffer.
    /// Only the outer edges are trimmed — never anything between first onset and last offset.
    public static func keptRange(speechStart: Int, speechEnd: Int, count: Int, sampleRate: Int,
                                 preRoll: TimeInterval, postRoll: TimeInterval) -> Range<Int>? {
        let a = max(0, min(count, speechStart - Int(preRoll * Double(sampleRate))))
        let b = max(a, min(count, speechEnd + Int(postRoll * Double(sampleRate))))
        return b > a ? a..<b : nil
    }

    public func prepare() async throws { _ = try loaded() }

    private func loaded() throws -> VadManager {
        if let vad { return vad }
        try OfflinePolicy.requireOffline(isOffline: isOffline)  // set once at app launch; loaders only assert
        guard let url = locator.vadModelURL() else { throw VADError.modelMissing(locator.searchRoots) }
        let cfg = VadConfig.default
        let mlc = MLModelConfiguration()
        mlc.computeUnits = cfg.computeUnits
        let model = try MLModel(contentsOf: url, configuration: mlc)
        let m = VadManager(config: cfg, vadModel: model)
        vad = m
        return m
    }

    public func trim(_ samples: [Float]) async throws -> [Float]? {
        guard !samples.isEmpty else { return nil }
        let vad = try loaded()
        let segments = try await vad.segmentSpeech(samples)
        let sr = Int(AudioConstants.sampleRate)
        let speech = segments.reduce(0) { $0 + $1.duration }
        guard let first = segments.first, let last = segments.last, speech >= minSpeech else { return nil }
        guard let r = Self.keptRange(speechStart: first.startSample(sampleRate: sr), speechEnd: last.endSample(sampleRate: sr),
                                     count: samples.count, sampleRate: sr, preRoll: preRoll, postRoll: postRoll)
        else { return nil }
        return Array(samples[r])
    }
}

public enum VADError: Error, LocalizedError {
    case modelMissing([URL])
    public var errorDescription: String? {
        if case .modelMissing(let roots) = self {
            return "Silero VAD model not found (looked in \(roots.map(\.path).joined(separator: ", ")))."
        }
        return nil
    }
}
