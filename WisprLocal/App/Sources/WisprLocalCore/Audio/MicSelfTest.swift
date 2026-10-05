@preconcurrency import AVFoundation
import Foundation

/// On-device microphone self-test (Settings › Microphone › "Check your microphone", and
/// `WisprLocalReplay --mic-check`): records a few seconds with the CURRENT settings, reports the
/// level and the zero-gating metrics in plain words, then — when Noise reduction
/// (voice processing) is on — repeats with it OFF so the two can be compared side by side.
///
/// Recordings live only in the returned results (memory). Nothing is written to disk, history
/// or logs; the caller drops them when its sheet closes.
public struct MicCheckResult: Sendable, Equatable, Identifiable {
    public var id: Bool { voiceProcessing }
    /// What was requested for this pass.
    public var voiceProcessing: Bool
    /// What the recorder reported (nil = unknown).
    public var voiceProcessingActive: Bool?
    /// macOS Mic Mode in effect ("Standard", "Voice Isolation", "Wide Spectrum"), when known.
    public var micMode: String?
    public var duration: TimeInterval
    public var peakDBFS: Double
    public var rmsDBFS: Double
    public var gating: AudioGatingMetrics
    /// In memory only (play back in the sheet); never persisted.
    public var samples: [Float]

    /// A voice at arm's length peaks well above −45 dBFS; below it the mic barely heard anything.
    public static let minPeakDBFS = -45.0
    public var levelOK: Bool { peakDBFS > Self.minPeakDBFS }
    public var passed: Bool { duration >= 1 && levelOK && !gating.isCuttingOut }

    public var title: String { voiceProcessing ? "Noise reduction ON" : "Noise reduction OFF" }

    /// One plain-words line.
    public var verdict: String {
        if duration < 1 { return "Fail — the mic delivered almost no audio." }
        if gating.isCuttingOut {
            return "Fail — audio cut out: \(MicAudioDiagnostics.percent(gating.zeroFraction)) went digitally silent, longest gap \(Int(gating.maxZeroRunMs.rounded())) ms."
        }
        if !levelOK { return "Fail — very quiet (peak \(Int(peakDBFS.rounded())) dBFS). Speak during the test, or pick another mic." }
        return "Pass — level good (peak \(Int(peakDBFS.rounded())) dBFS), no cut-outs."
    }

    /// Numbers line.
    public var details: String {
        var s = String(format: "Level: peak %.0f dBFS, average %.0f dBFS · Silenced: %@ · Longest gap: %d ms",
                       peakDBFS, rmsDBFS, MicAudioDiagnostics.percent(gating.zeroFraction), Int(gating.maxZeroRunMs.rounded()))
        if let micMode { s += " · Mic Mode: \(micMode)" }
        return s
    }

    public static func measure(_ samples: [Float], voiceProcessing: Bool, voiceProcessingActive: Bool?, micMode: String?,
                               sampleRate: Double = AudioConstants.sampleRate) -> MicCheckResult {
        var peak: Float = 0, sum: Double = 0
        for x in samples { peak = max(peak, abs(x)); sum += Double(x) * Double(x) }
        let rms = samples.isEmpty ? 0 : (sum / Double(samples.count)).squareRoot()
        func db(_ v: Double) -> Double { 20 * log10(max(v, 1e-6)) }
        return MicCheckResult(voiceProcessing: voiceProcessing, voiceProcessingActive: voiceProcessingActive, micMode: micMode,
                              duration: Double(samples.count) / sampleRate, peakDBFS: db(Double(peak)), rmsDBFS: db(rms),
                              gating: AudioGatingMetrics.measure(MicSelfTest.droppingStartupMute(samples), sampleRate: sampleRate),
                              samples: samples)
    }
}

@MainActor
public final class MicSelfTest {
    public enum Phase: Equatable, Sendable { case recording(voiceProcessing: Bool), done }
    public typealias MakeRecorder = @MainActor (_ voiceProcessing: Bool) -> AudioCapturing

    private let makeRecorder: MakeRecorder
    private let sleep: @Sendable (Duration) async throws -> Void
    private let micMode: @MainActor () -> String?

    public init(makeRecorder: @escaping MakeRecorder,
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                micMode: @escaping @MainActor () -> String? = { MicMode.current }) {
        self.makeRecorder = makeRecorder; self.sleep = sleep; self.micMode = micMode
    }

    /// The real recorder (a separate engine; the caller stops the warm mic first).
    public static func live() -> MicSelfTest {
        MicSelfTest(makeRecorder: { vp in AudioRecorder(voiceProcessingEnabled: vp) })
    }

    /// Current settings first; if voice processing is on, again with it off.
    public func run(currentVoiceProcessing vp: Bool, duration: Duration = .seconds(3),
                    progress: @MainActor (Phase) -> Void = { _ in }) async throws -> [MicCheckResult] {
        var out: [MicCheckResult] = []
        for pass in vp ? [true, false] : [false] {
            progress(.recording(voiceProcessing: pass))
            out.append(try await record(voiceProcessing: pass, duration: duration))
        }
        progress(.done)
        return out
    }

    private func record(voiceProcessing: Bool, duration: Duration) async throws -> MicCheckResult {
        let rec = makeRecorder(voiceProcessing)
        try rec.start()
        do { try await sleep(duration) } catch { rec.cancel(); throw error }
        let samples = await rec.stop(tail: .zero)
        return MicCheckResult.measure(samples, voiceProcessing: voiceProcessing,
                                      voiceProcessingActive: rec.captureVoiceProcessingActive, micMode: micMode())
    }

    /// Side-by-side conclusion, nil with a single pass.
    public static func comparison(_ r: [MicCheckResult]) -> String? {
        guard let on = r.first(where: { $0.voiceProcessing }), let off = r.first(where: { !$0.voiceProcessing }) else { return nil }
        switch (on.gating.isCuttingOut, off.gating.isCuttingOut) {
        case (true, false):
            return "Noise reduction is what's cutting your audio out (\(MicAudioDiagnostics.percent(on.gating.zeroFraction)) silenced with it on, \(MicAudioDiagnostics.percent(off.gating.zeroFraction)) off). Turn it off in Settings › Microphone."
        case (true, true):
            return "Audio cuts out either way, so it's coming from the mic or macOS (check Mic Mode in Control Centre, or try another mic)."
        case (false, true):
            return "Audio only cut out with noise reduction off — keep it on."
        case (false, false):
            return "No cut-outs either way. Keep whichever sounds better to you."
        }
    }

    /// A COLD engine start delivers ~0.13–0.25 s of exact zeros before the device's first real
    /// buffer (AVAudioEngine/VPIO start-up, see `RecordingCue`). That run is a known start-up
    /// artefact, not gating, so the self-test measures from the first non-silent sample.
    nonisolated public static func droppingStartupMute(_ s: [Float]) -> ArraySlice<Float> {
        let first = s.firstIndex { abs($0) >= AudioGatingMetrics.silenceThreshold } ?? s.endIndex
        return s[first...]
    }
}

/// The macOS Mic Mode (Control Centre › Mic Mode) for apps using voice processing.
public enum MicMode {
    public static var current: String? {
        switch AVCaptureDevice.activeMicrophoneMode {
        case .standard: return "Standard"
        case .wideSpectrum: return "Wide Spectrum"
        case .voiceIsolation: return "Voice Isolation"
        @unknown default: return nil
        }
    }
}
