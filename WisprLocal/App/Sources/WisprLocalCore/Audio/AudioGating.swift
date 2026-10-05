import Foundation

/// Zero-gating detector (STRUCTURAL): how much of a dictation's audio was DIGITALLY silenced.
///
/// Background (2026-10-03, plane cabin, built-in mic): saved clips held runs of exact int16 zeros
/// (typically 10–15 % of the clip, runs up to ~0.5 s). Every run edge sits at ±1 LSB, i.e. the
/// signal fades to below −96 dBFS rather than being cut, and the run lengths do not align with
/// any buffer size — the signature of Apple voice processing's noise suppressor, not of our
/// capture path (proven stage by stage by `CaptureContinuityTests`). A real room never measures
/// below −96 dBFS at a laptop mic, so "digitally silent" audio means something upstream gated it.
public struct AudioGatingMetrics: Codable, Sendable, Equatable {
    /// Fraction (0…1) of the active audio (cold-start / trailing silence excluded) inside
    /// digital-silence holes INSIDE speech (`measure`).
    public var zeroFraction: Double
    /// Longest such hole, milliseconds.
    public var maxZeroRunMs: Double

    public init(zeroFraction: Double, maxZeroRunMs: Double) {
        self.zeroFraction = zeroFraction; self.maxZeroRunMs = maxZeroRunMs
    }

    /// |x| below half an int16 LSB: the sample is 0 once written as 16-bit PCM (the debug WAVs),
    /// and an exact 0.0 from the device counts too.
    public static let silenceThreshold: Float = 0.5 / 32_767
    /// Runs shorter than this (0.5 ms at 16 kHz) are ordinary zero crossings, not gating.
    public static let minRunSamples = 8

    /// Analysis window for the level gates below.
    public static let windowMs = 20.0
    /// Audio "starts" at the first 20 ms window above this (and ends after the last one). Before
    /// it is cold-start engine mute: leading zeros (130–600 ms measured), stray ±1 LSB blips
    /// inside them, and the fade-in, none of which is the mic cutting out.
    public static let activeDBFS = -70.0
    /// Speech-level: a hole counts only with a window this loud within `bracketMs` on BOTH sides.
    public static let speechDBFS = -50.0
    /// Real-data basis (2026-10-03, 20 debug clips, VP + Voice Isolation, quiet room): pauses
    /// between phrases decay over ~200–400 ms to digital zero (VP gating a silent pause, nothing
    /// lost). The old whole-clip metric flagged 17/20; with a 150 ms bracket one clip still had a
    /// severe 785 ms "hole" (a decaying phrase end); at 100 ms the worst is 351 ms, non-severe.
    public static let bracketMs = 100.0

    public static let none = AudioGatingMetrics(zeroFraction: 0, maxZeroRunMs: 0)

    /// The detector (STRUCTURAL): digital-silence holes INSIDE speech, over the active audio only.
    /// 1. Trim everything before the first sustained signal (a 20 ms window above −70 dBFS) and
    ///    after the last one: cold-start mute, blips, fade-in/out and trailing gating are excluded
    ///    from both the numerator and the denominator.
    /// 2. Count a zero run (≥ `minRunSamples`) only if speech-level audio (≥ −50 dBFS) sits
    ///    within `bracketMs` before it AND after it: a hole in speech, not a gated pause.
    public static func measure(_ samples: some Collection<Float>, sampleRate: Double = AudioConstants.sampleRate) -> AudioGatingMetrics {
        let s = Array(samples)
        guard !s.isEmpty, sampleRate > 0 else { return .none }
        let hop = max(1, Int(sampleRate * windowMs / 2_000))          // 10 ms; windows = 2 hops
        let hops = s.count / hop
        guard hops >= 2 else { return .none }
        var power = [Double](repeating: 0, count: hops)
        for h in 0..<hops {
            var sum = 0.0
            for k in (h * hop)..<((h + 1) * hop) { sum += Double(s[k]) * Double(s[k]) }
            power[h] = sum / Double(hop)
        }
        func level(_ w: Int) -> Double {                               // window w = hops w, w+1
            let p = (power[w] + power[w + 1]) / 2
            return p > 0 ? 10 * log10(p) : -240
        }
        let windows = hops - 1
        var active = [Bool](repeating: false, count: windows), speech = active
        for w in 0..<windows { let l = level(w); active[w] = l > activeDBFS; speech[w] = l >= speechDBFS }
        guard let firstW = active.firstIndex(of: true), let lastW = active.lastIndex(of: true) else { return .none }
        let start = firstW * hop, end = min(s.count, (lastW + 2) * hop)
        let reach = max(1, Int((bracketMs / 1_000 * sampleRate / Double(hop)).rounded()))
        func speechNear(_ lo: Int, _ hi: Int) -> Bool {                 // any speech window in [lo, hi)
            let a = max(0, lo), b = min(windows, hi)
            return a < b && speech[a..<b].contains(true)
        }
        var gated = 0, longest = 0
        var i = start
        while i < end {
            guard abs(s[i]) < silenceThreshold else { i += 1; continue }
            var k = i
            while k < end, abs(s[k]) < silenceThreshold { k += 1 }
            if k - i >= minRunSamples {
                let before = speechNear(i / hop - reach - 1, i / hop)               // windows ending at/before the run
                let after = speechNear((k + hop - 1) / hop, (k + hop - 1) / hop + reach)  // windows starting at/after it
                if before && after { gated += k - i; longest = max(longest, k - i) }
            }
            i = k
        }
        guard end > start else { return .none }
        return AudioGatingMetrics(zeroFraction: Double(gated) / Double(end - start),
                                  maxZeroRunMs: Double(longest) / sampleRate * 1000)
    }

    /// Every digital-silence run anywhere (no trimming, no speech bracket): the capture-path
    /// continuity proofs, where ANY zero run is a bug.
    public static func measureAllRuns(_ samples: some Collection<Float>, sampleRate: Double = AudioConstants.sampleRate) -> AudioGatingMetrics {
        guard !samples.isEmpty, sampleRate > 0 else { return .none }
        var run = 0, longest = 0, gated = 0
        func close() {
            if run >= minRunSamples { gated += run; longest = max(longest, run) }
            run = 0
        }
        for x in samples {
            if abs(x) < silenceThreshold { run += 1 } else if run > 0 { close() }
        }
        close()
        return AudioGatingMetrics(zeroFraction: Double(gated) / Double(samples.count),
                                  maxZeroRunMs: Double(longest) / sampleRate * 1000)
    }

    /// The mic audio is cutting out (`ZeroGatingPolicy`).
    public var isCuttingOut: Bool { ZeroGatingPolicy.isCuttingOut(self) }
}

/// Thresholds + the user-facing copy for the zero-gating tip.
public enum ZeroGatingPolicy {
    /// > 5 % of the dictation digitally silenced…
    public static let maxZeroFraction = 0.05
    /// …or any single silent run longer than 250 ms (a whole syllable).
    public static let maxZeroRunMs = 250.0

    public static func isCuttingOut(_ m: AudioGatingMetrics) -> Bool {
        m.zeroFraction > maxZeroFraction || m.maxZeroRunMs > maxZeroRunMs
    }

    /// One dictation bad enough to warn on its own: > 25 % silenced, or a hole > 600 ms in speech.
    public static let severeZeroFraction = 0.25
    public static let severeZeroRunMs = 600.0

    public static func isSevere(_ m: AudioGatingMetrics) -> Bool {
        m.zeroFraction > severeZeroFraction || m.maxZeroRunMs > severeZeroRunMs
    }

    /// How many recent dictations the tip looks at, and how many of them must be cutting out.
    public static let recentWindow = 3
    public static let recentRequired = 2

    /// The tip decision (STRUCTURAL) for the newest dictation, `recent` oldest → newest (this
    /// session's measured dictations, the newest last). The newest must be cutting out, and
    /// either be severe or be one of ≥ 2 cutting-out dictations among the last 3, so a single
    /// cold-start artifact can never trigger it.
    public static func shouldWarn(recent: [AudioGatingMetrics]) -> Bool {
        guard let newest = recent.last, newest.isCuttingOut else { return false }
        if isSevere(newest) { return true }
        return recent.suffix(recentWindow).filter(\.isCuttingOut).count >= recentRequired
    }

    /// HUD tip, shown at most once per app session.
    public static let tip = "Mic cutting out — try turning off noise reduction"
}

/// Settings › Microphone › "Check your microphone": the passive cut-out verdict over
/// recent dictations, as one short status ("Last dictation: no cut-outs", "Cutting out on 2 of
/// the last 3"). Content-free (numbers only); nil until a dictation has been measured.
public enum MicAudioDiagnostics {
    public static let window = 20

    public static func status(_ entries: [HistoryEntry]) -> String? {
        let measured = entries.filter { $0.zeroFraction != nil }.suffix(window)
        guard !measured.isEmpty else { return nil }
        let bad = measured.map { AudioGatingMetrics(zeroFraction: $0.zeroFraction ?? 0, maxZeroRunMs: $0.maxZeroRunMs ?? 0) }
            .filter(\.isCuttingOut).count
        let n = measured.count
        if bad == 0 { return n == 1 ? "Last dictation: no cut-outs" : "Last \(n) dictations: no cut-outs" }
        return n == 1 ? "Cutting out on the last dictation" : "Cutting out on \(bad) of the last \(n)"
    }

    /// Healthy measurements retain the ordinary settings caption.
    public static func warning(_ entries: [HistoryEntry]) -> String? {
        let measured = entries.filter { $0.zeroFraction != nil }.suffix(window)
        guard measured.contains(where: {
            AudioGatingMetrics(zeroFraction: $0.zeroFraction ?? 0, maxZeroRunMs: $0.maxZeroRunMs ?? 0).isCuttingOut
        }) else { return nil }
        return status(entries)
    }

    static func percent(_ f: Double) -> String {
        f < 0.01 ? String(format: "%.1f %%", f * 100) : "\(Int((f * 100).rounded())) %"
    }
}
