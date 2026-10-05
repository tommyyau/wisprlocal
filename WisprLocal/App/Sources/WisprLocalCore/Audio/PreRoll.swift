import Foundation

/// In-memory ring of the most recent mic samples while the mic is kept warm ("Keep mic ready
/// after dictating" / "Always ready"). Starting AVAudioEngine mutes the first ~130–180 ms of the
/// device's audio (+~60 ms with voice processing), which clipped first words; with the engine
/// already running, the last `MicWarmPolicy.preRoll` of this ring is prepended to a new recording.
///
/// PRIVACY (STRUCTURAL, `PreRollPrivacyTests`): this type is not serialisable and has no file,
/// history, log or settings access; its samples leave it ONLY through `SampleSink.begin(preRoll:)`
/// when a dictation starts. `zeroAndFree()` overwrites every sample before releasing the storage.
struct PreRollRing: Sendable {
    let capacity: Int
    private var storage: [Float]
    private var head = 0     // next write index
    private var filled = 0

    init(capacity: Int) {
        self.capacity = max(1, capacity)
        storage = [Float](repeating: 0, count: self.capacity)
    }

    var isAllocated: Bool { !storage.isEmpty }
    var count: Int { filled }

    mutating func write(_ p: UnsafeBufferPointer<Float>) {
        guard isAllocated else { return }
        // Only the newest `capacity` samples matter.
        let src = p.count > capacity ? UnsafeBufferPointer(rebasing: p[(p.count - capacity)...]) : p
        for x in src {
            storage[head] = x
            head = (head + 1) % capacity
        }
        filled = min(capacity, filled + src.count)
    }

    mutating func write(_ a: [Float]) { a.withUnsafeBufferPointer { write($0) } }

    /// The newest `n` samples (n ≤ count), oldest first.
    func last(_ n: Int) -> [Float] {
        let k = min(max(0, n), filled)
        guard k > 0 else { return [] }
        var out = [Float](); out.reserveCapacity(k)
        var i = (head - k + capacity) % capacity
        for _ in 0..<k { out.append(storage[i]); i = (i + 1) % capacity }
        return out
    }

    /// Overwrite every sample with zero, then release the storage.
    mutating func zeroAndFree() {
        for i in storage.indices { storage[i] = 0 }
        storage = []
        head = 0; filled = 0
    }
}

/// Timing constants for the warm mic.
public enum MicWarmPolicy {
    /// How long the mic stays ready after a dictation ("Microphone readiness: Ready for 60 s after dictating").
    public static let window: TimeInterval = 60
    /// Ring length kept in memory.
    public static let ringDuration: Duration = .milliseconds(500)
    /// Prepended to a recording that starts while warm.
    public static let preRoll: Duration = .milliseconds(300)

    public static func samples(_ d: Duration, rate: Double = AudioConstants.sampleRate) -> Int {
        Int((Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18) * rate)
    }
}
