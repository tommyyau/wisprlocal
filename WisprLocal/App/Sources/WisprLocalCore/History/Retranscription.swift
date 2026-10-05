import Foundation
import Observation

/// History › details › "Re-transcribe with the other model": loads the OTHER model on demand
/// (its own engine instance, never the pipeline's), transcribes the saved clip, shows the text,
/// then releases the model. It has no history dependency at all: nothing is ever written to
/// History. It refuses to start while a dictation is in progress, and a dictation starting
/// mid-run discards the result (the model is still released).
@MainActor
@Observable
public final class Retranscription {
    public enum State: Equatable, Sendable {
        case idle
        /// Loading the model (the first ever load can take ~10 s).
        case preparing(ASRModelVariant)
        case transcribing(ASRModelVariant)
        case done(ASRModelVariant, String)
        case failed(String)
    }

    public private(set) var state: State = .idle
    /// The history entry the current state belongs to.
    public private(set) var entryID: UUID?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let makeTranscriber: @MainActor (ASRModelVariant) -> Transcriber
    @ObservationIgnored private let isDictating: @MainActor () -> Bool
    @ObservationIgnored private let loadSamples: @Sendable (URL) throws -> [Float]

    public init(makeTranscriber: @escaping @MainActor (ASRModelVariant) -> Transcriber,
                isDictating: @escaping @MainActor () -> Bool,
                loadSamples: @escaping @Sendable (URL) throws -> [Float] = Retranscription.decodeClip) {
        self.makeTranscriber = makeTranscriber; self.isDictating = isDictating; self.loadSamples = loadSamples
    }

    public var isBusy: Bool {
        switch state {
        case .preparing, .transcribing: return true
        default: return false
        }
    }

    /// Button enabled: not dictating, nothing already running.
    public var canStart: Bool { !isDictating() && !isBusy }

    /// The model `entry` was NOT transcribed with: v2 ↔ Ultra. Unknown engines use the other of
    /// `active`.
    public static func otherVariant(for entry: HistoryEntry, active: ASRModelVariant) -> ASRModelVariant {
        switch entry.variant ?? active {
        case .parakeetV2: return .parakeetUltra
        case .parakeetUltra: return .parakeetV2
        }
    }

    /// Starts a run; nil (and no state change) when refused.
    @discardableResult
    public func start(entryID: UUID, clip: URL, variant: ASRModelVariant) -> Task<Void, Never>? {
        guard canStart else { return nil }
        cancel()
        generation &+= 1
        let gen = generation
        self.entryID = entryID
        state = .preparing(variant)
        let engine = makeTranscriber(variant)
        let load = loadSamples
        let t = Task { @MainActor [weak self] in
            var result: State
            do {
                let samples = try await Task.detached(priority: .userInitiated) { try load(clip) }.value
                try await engine.prepare()
                if let self, self.generation == gen { self.state = .transcribing(variant) }
                let text = try await engine.transcribe(samples, vocabularyHints: [])
                result = .done(variant, text)
            } catch {
                result = .failed(error.localizedDescription)
            }
            await engine.unload()  // always release the extra model
            guard let self, self.generation == gen, !Task.isCancelled else { return }
            self.state = result
        }
        task = t
        return t
    }

    /// Discards a run in progress (its model is still released) and clears the result.
    public func cancel() {
        generation &+= 1
        task?.cancel(); task = nil
        state = .idle
        entryID = nil
    }

    /// A dictation is starting: drop any run so the extra model never competes with it.
    public func handleHotkey(_ action: HotkeyStateMachine.Action) {
        if action == .startRecording, isBusy { cancel() }
    }

    /// 16 kHz mono WAV from the recordings folder.
    public static let decodeClip: @Sendable (URL) throws -> [Float] = { url in
        let w = try WAV.decode(Data(contentsOf: url))
        guard w.sampleRate == Int(AudioConstants.sampleRate) else {
            throw WAV.DecodeError(reason: "\(w.sampleRate) Hz (expected \(Int(AudioConstants.sampleRate)) Hz)")
        }
        return w.samples
    }
}
