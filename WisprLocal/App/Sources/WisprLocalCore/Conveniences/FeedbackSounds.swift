import AppKit
import Foundation

public enum FeedbackSound: Sendable, Equatable { case start, stop }

/// Optional start/stop sound (Settings › General, default OFF).
@MainActor
public protocol FeedbackSoundPlaying: AnyObject {
    /// How long one sound lasts (used to cut it out of the capture).
    var duration: Duration { get }
    func play(_ sound: FeedbackSound)
}

/// A soft two-note tone generated in code (no bundled or downloaded assets), played quietly
/// through NSSound: rising for start, falling for stop, 70 ms, 15 % volume.
@MainActor
public final class ToneFeedbackSounds: FeedbackSoundPlaying {
    public let duration: Duration = .milliseconds(70)
    public static let volume: Float = 0.15
    private lazy var sounds: [FeedbackSound: NSSound] = [
        .start: Self.make(from: 660, to: 880),
        .stop: Self.make(from: 880, to: 620),
    ].compactMapValues { $0 }

    public init() {}

    public func play(_ sound: FeedbackSound) {
        guard let s = sounds[sound] else { return }
        s.stop()
        s.volume = Self.volume
        s.play()
    }

    /// 44.1 kHz mono WAV: a sine gliding `f0` → `f1` with a smooth raised-cosine envelope.
    static func samples(from f0: Double, to f1: Double, seconds: Double = 0.07, rate: Double = 44_100) -> [Float] {
        let n = Int(seconds * rate)
        var phase = 0.0
        return (0..<n).map { i in
            let x = Double(i) / Double(max(1, n - 1))
            phase += 2 * .pi * (f0 + (f1 - f0) * x) / rate
            let env = 0.5 - 0.5 * cos(2 * .pi * x)  // 0 → 1 → 0: no clicks
            return Float(sin(phase) * env * 0.6)
        }
    }

    private static func make(from f0: Double, to f1: Double) -> NSSound? {
        NSSound(data: WAV.encode(samples(from: f0, to: f1), sampleRate: 44_100))
    }
}

/// Keeps the feedback sounds out of what is transcribed (STRUCTURAL): the pipeline notes when
/// each sound played on its clock, and the samples captured during [start, start + duration +
/// `margin`] are CUT from the capture before VAD/ASR. Covers the start sound (played right after
/// the mic starts) and a previous stop sound that the warm-mic pre-roll could still hold.
public struct SoundExclusion: Sendable, Equatable {
    /// Output latency + room echo allowance after each sound.
    public static let margin: Duration = .milliseconds(80)

    /// Clock time of the press (when live capture began).
    public var pressAt: Duration
    /// Index in the capture where live audio begins (= the pre-roll length; 0 when cold).
    public var liveStartIndex: Int
    /// Sound intervals on the same clock, each already including `margin`.
    public var windows: [ClosedRange<Duration>]
    public var sampleRate: Double

    public init(pressAt: Duration, liveStartIndex: Int, windows: [ClosedRange<Duration>],
                sampleRate: Double = AudioConstants.sampleRate) {
        self.pressAt = pressAt; self.liveStartIndex = liveStartIndex; self.windows = windows; self.sampleRate = sampleRate
    }

    static func seconds(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    /// The sample index for clock time `t`.
    func index(_ t: Duration) -> Int { liveStartIndex + Int((Self.seconds(t - pressAt) * sampleRate).rounded()) }

    /// Index ranges to cut from a capture of `count` samples (clamped, merged, ascending).
    public func ranges(count: Int) -> [Range<Int>] {
        let rs = windows.compactMap { w -> Range<Int>? in
            let lo = max(0, index(w.lowerBound)), hi = min(count, index(w.upperBound))
            return lo < hi ? lo..<hi : nil
        }.sorted { $0.lowerBound < $1.lowerBound }
        var merged: [Range<Int>] = []
        for r in rs {
            if let last = merged.last, r.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, r.upperBound)
            } else { merged.append(r) }
        }
        return merged
    }

    /// `samples` with every sound window removed.
    public func apply(_ samples: [Float]) -> [Float] {
        let rs = ranges(count: samples.count)
        guard !rs.isEmpty else { return samples }
        var out: [Float] = []
        out.reserveCapacity(samples.count)
        var at = 0
        for r in rs {
            out.append(contentsOf: samples[at..<r.lowerBound])
            at = r.upperBound
        }
        out.append(contentsOf: samples[at...])
        return out
    }
}

/// Presses Return (auto-send). Injected so tests never post real input.
@MainActor
public protocol ReturnKeyPosting: AnyObject {
    func pressReturn() throws
}

/// A Return key-down/up from a PRIVATE event source with EMPTY flags (the user may still be
/// holding Shift, which would turn it into Shift-Return, a newline in chat apps), marked as ours.
@MainActor
public final class SystemReturnKey: ReturnKeyPosting {
    public static let keyCode: CGKeyCode = 36  // kVK_Return
    public init() {}

    public static func events() -> [CGEvent] {
        let src = CGEventSource(stateID: .privateState)
        return [true, false].compactMap { down in
            guard let e = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: down) else { return nil }
            e.flags = []
            e.setIntegerValueField(.eventSourceUserData, value: SyntheticEventMarker.value)
            return e
        }
    }

    public func pressReturn() throws {
        guard AXIsProcessTrusted() else { throw InsertionError.notTrusted }
        let evs = Self.events()
        guard evs.count == 2 else { throw InsertionError.eventCreationFailed }
        for e in evs { e.post(tap: .cghidEventTap) }
    }
}
