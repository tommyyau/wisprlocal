import Foundation

/// Adaptive capture tail after key-up: keep recording until `silence` (120 ms) of low energy has
/// been seen at the end of the buffer, but at least `minimum` (150 ms) and at most `maximum`
/// (400 ms). The fixed 400 ms tail made every dictation wait 400 ms; a word that is still being
/// spoken at release keeps the full 400 ms, so endings stay safe ("at the moment" was clipped
/// with a fixed 200 ms) while the common case (user already silent) stops at ~150 ms.
public struct CaptureTailPolicy: Sendable, Equatable {
    public var minimum: Duration
    public var maximum: Duration
    public var silence: Duration
    /// Frame size for the energy analysis.
    public var frame: Duration = .milliseconds(10)
    /// Absolute floor/ceiling for the silence RMS threshold (Float32 full scale = 1).
    public var minThreshold: Float = 0.003
    public var maxThreshold: Float = 0.02

    public static let `default` = CaptureTailPolicy(minimum: .milliseconds(150), maximum: .milliseconds(400),
                                                    silence: .milliseconds(120))

    public init(minimum: Duration, maximum: Duration, silence: Duration) {
        self.minimum = min(minimum, maximum); self.maximum = maximum; self.silence = silence
    }

    /// A fixed tail (no early stop): minimum == maximum.
    public static func fixed(_ d: Duration) -> CaptureTailPolicy { CaptureTailPolicy(minimum: d, maximum: d, silence: .zero) }

    static func samples(_ d: Duration, rate: Double) -> Int {
        Int((Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18) * rate)
    }

    /// Silence threshold for this recording: 3 × its noise floor (15th-percentile frame RMS),
    /// never above 15 % of its speech level (90th percentile), clamped to [minThreshold,
    /// maxThreshold]. Relative so quiet fricative endings ("-s", "-t") still count as sound in a
    /// quiet room while a noisy room doesn't keep the tail open forever.
    public func threshold(for recording: ArraySlice<Float>, sampleRate: Double = AudioConstants.sampleRate) -> Float {
        let n = max(1, Self.samples(frame, rate: sampleRate))
        var rms: [Float] = []
        rms.reserveCapacity(recording.count / n + 1)
        var i = recording.startIndex
        while i + n <= recording.endIndex {
            rms.append(Self.rms(recording[i..<(i + n)]))
            i += n
        }
        guard !rms.isEmpty else { return minThreshold }
        rms.sort()
        let floor = rms[Int(Double(rms.count - 1) * 0.15)]
        let speech = rms[Int(Double(rms.count - 1) * 0.90)]
        var t = floor * 3
        if speech > 0 { t = min(t, speech * 0.15) }
        return min(maxThreshold, max(minThreshold, t))
    }

    /// True when every `frame` of the last `silence` of `samples` is below `threshold`.
    public func endsInSilence(_ samples: ArraySlice<Float>, threshold: Float,
                              sampleRate: Double = AudioConstants.sampleRate) -> Bool {
        let need = Self.samples(silence, rate: sampleRate)
        guard need > 0, samples.count >= need else { return false }
        let n = max(1, Self.samples(frame, rate: sampleRate))
        var i = samples.endIndex - need
        while i < samples.endIndex {
            let e = min(samples.endIndex, i + n)
            if Self.rms(samples[i..<e]) >= threshold { return false }
            i = e
        }
        return true
    }

    /// Pure decision used by the recorder's poll loop.
    public func shouldStop(elapsed: Duration, endsInSilence: Bool) -> Bool {
        if elapsed >= maximum { return true }
        return elapsed >= minimum && endsInSilence
    }

    static func rms(_ s: ArraySlice<Float>) -> Float {
        guard !s.isEmpty else { return 0 }
        var sum: Float = 0
        for x in s { sum += x * x }
        return (sum / Float(s.count)).squareRoot()
    }
}
