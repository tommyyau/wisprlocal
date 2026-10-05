import Accelerate
import Foundation
import Synchronization

/// Latest per-band voice levels (0...1), written by the audio tap and read by the HUD once per
/// display frame (pull model, so nothing is pushed to the main actor per audio buffer).
public final class SpectrumBands: Sendable {
    public static let count = 9
    private let state = Mutex([Float](repeating: 0, count: SpectrumBands.count))
    public init() {}

    public func read() -> [Float] { state.withLock { $0 } }

    /// Copies in place (no allocation; safe on the realtime thread).
    func write(_ src: UnsafeBufferPointer<Float>) {
        state.withLock { s in
            for i in 0..<min(s.count, src.count) { s[i] = src[i] }
        }
    }

    public func clear() { state.withLock { s in for i in s.indices { s[i] = 0 } } }
}

/// 512-point Hann-windowed real FFT over the most recent 16 kHz mono samples, reduced to
/// log-spaced bands (100 Hz–4 kHz by default) mapped to 0...1 with a noise floor and a gentle
/// spectral tilt (speech energy falls off with frequency). Allocation-free after init; meant to
/// be driven from the audio tap (one caller at a time).
public final class SpectrumAnalyzer: @unchecked Sendable {
    public static let fftSize = 512
    public let bandCount: Int
    /// dB window mapped to 0...1 (after tilt). Below `floorDB` a band reads exactly 0.
    public var floorDB: Float = -50
    public var ceilingDB: Float = -10

    private let n = SpectrumAnalyzer.fftSize
    private let log2n = vDSP_Length(9)
    private let setup: FFTSetup
    private let ring: UnsafeMutablePointer<Float>
    private var writeIndex = 0
    private let window: UnsafeMutablePointer<Float>
    private let windowed: UnsafeMutablePointer<Float>
    private let real: UnsafeMutablePointer<Float>
    private let imag: UnsafeMutablePointer<Float>
    private let power: UnsafeMutablePointer<Float>
    private let out: UnsafeMutablePointer<Float>
    private let bins: [(lo: Int, hi: Int)]
    private let tiltDB: [Float]
    private let normDB: Float
    private let sampleRate: Float
    private let displayGainEnabled: Bool
    // Tilted FFT band peaks sit below time-domain RMS. -28 dB preserves the usual
    // -20 dBFS voice-processed speech while allowing up to 18 dB for quiet microphones.
    private let targetPeakDB: Float = -28
    private var trackedPeakDB: Float?
    private var speechSeconds: Float = 0
    private let maxGainDB: Float = 18
    private let speechQualificationSeconds: Double = 0.06
    private var noiseFloorDB: Float?
    private var validFloorSeconds: Double = 0
    private var floorEstablished = false
    private var hasEstablishedFloor = false
    private struct LoudnessFrame {
        var peak: Float = 0
        var end: Double = 0
        var duration: Double = 0
        var floorDuration: Double = 0
    }
    // Smallest supported hop: 64 samples (4 ms at 16 kHz): 375 entries for 1.5 s.
    // Smaller hops safely shorten the window proportionally. Fixed storage,
    // sized at init; neither floor nor persistence tracking allocates per buffer.
    private let history: UnsafeMutablePointer<LoudnessFrame>
    private let historyCapacity: Int
    private var historyIndex = 0
    private var historyCount = 0
    private var qualifyingFrames = 0
    private var elapsedSeconds: Double = 0
    // Classify continuous 1 ms regions, independent of callback boundaries. A lone
    // int16 LSB in an otherwise silent region is below -90 dBFS RMS.
    private var regionPower: Double = 0
    private var regionSamples = 0
    private var processedSamples = 0
    private var nonSilentStart: Double?
    private var lastSilentEnd: Double = 0
    private let resetRequested = Mutex(false)
    // Keep slowly swelling room noise below the speech gate.
    private let speechMarginDB: Float = 10

    public init(sampleRate: Double = AudioConstants.sampleRate, bands: Int = SpectrumBands.count,
                lowHz: Double = 100, highHz: Double = 4000, displayGainEnabled: Bool = true) {
        self.sampleRate = Float(sampleRate)
        self.displayGainEnabled = displayGainEnabled
        historyCapacity = Int(ceil(1.5 * sampleRate / 64))
        history = .allocate(capacity: historyCapacity)
        history.initialize(repeating: LoudnessFrame(), count: historyCapacity)
        bandCount = bands
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        func alloc(_ c: Int) -> UnsafeMutablePointer<Float> {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: c); p.initialize(repeating: 0, count: c); return p
        }
        ring = alloc(n); window = alloc(n); windowed = alloc(n)
        real = alloc(n / 2); imag = alloc(n / 2); power = alloc(n / 2); out = alloc(bands)
        vDSP_hann_window(window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        let binHz = sampleRate / Double(n)
        let ratio = pow(highHz / lowHz, 1 / Double(bands))
        var b: [(Int, Int)] = []
        var t: [Float] = []
        for k in 0..<bands {
            let f0 = lowHz * pow(ratio, Double(k)), f1 = f0 * ratio
            let lo = max(1, Int((f0 / binHz).rounded()))
            let hi = min(n / 2 - 1, max(lo, Int((f1 / binHz).rounded()) - 1))
            b.append((lo, hi))
            // +4 dB/octave around 400 Hz: lifts sibilants, calms low rumble/hum.
            t.append(Float(4 * log2((f0 * f1).squareRoot() / 400)))
        }
        bins = b; tiltDB = t
        // vDSP_fft_zrip returns 2×DFT; Hann coherent gain 0.5 → a sine of amplitude A peaks at
        // (A·n/2)². Normalising by n² makes a full-scale sine read ≈ -6 dB.
        normDB = 20 * log10(Float(n))
    }

    deinit {
        history.deinitialize(count: historyCapacity)
        history.deallocate()
        vDSP_destroy_fftsetup(setup)
        for p in [ring, window, windowed, real, imag, power, out] { p.deallocate() }
    }

    /// Appends samples and recomputes the bands. Returns a view of the internal band buffer
    /// (valid until the next call).
    @discardableResult
    public func process(_ samples: UnsafeBufferPointer<Float>) -> UnsafeBufferPointer<Float> {
        // Reset on the sole audio caller, including when the engine stays warm.
        let shouldReset = resetRequested.withLock { requested in
            let value = requested; requested = false; return value
        }
        if shouldReset {
            trackedPeakDB = nil; noiseFloorDB = nil; speechSeconds = 0
            floorEstablished = false; hasEstablishedFloor = false; validFloorSeconds = 0
            qualifyingFrames = 0; historyIndex = 0; historyCount = 0; elapsedSeconds = 0
            regionPower = 0; regionSamples = 0; processedSamples = 0
            nonSilentStart = nil; lastSilentEnd = 0
            writeIndex = 0
            ring.update(repeating: 0, count: n)
        }
        guard let base = samples.baseAddress, !samples.isEmpty else { return UnsafeBufferPointer(start: out, count: bandCount) }
        // Reject the whole buffer before copying: a NaN must neither poison the FFT
        // history nor change any tracker (including the qualification timer).
        var digitalSilence = true
        var inputPower: Double = 0
        for sample in samples {
            guard sample.isFinite else { return zeroOutput() }
            if sample != 0 { digitalSilence = false }
            inputPower += Double(sample) * Double(sample)
        }
        // Advance the tracker at most every 20 ms at 16 kHz, regardless of tap size.
        // Pointer views reuse the delivered storage; no sub-block arrays are allocated.
        let gain: Float
        if samples.count <= 320 {
            guard let nextGain = updateDisplayGain(samples, inputPower: inputPower, digitalSilence: digitalSilence) else { return zeroOutput() }
            gain = nextGain
        } else {
            var nextGain: Float = 0
            var start = 0
            while start < samples.count {
                let count = min(320, samples.count - start)
                let block = UnsafeBufferPointer(start: base + start, count: count)
                var blockPower: Double = 0
                var blockSilence = true
                for sample in block {
                    blockPower += Double(sample) * Double(sample)
                    if sample != 0 { blockSilence = false }
                }
                guard let updatedGain = updateDisplayGain(block, inputPower: blockPower, digitalSilence: blockSilence) else { return zeroOutput() }
                nextGain = updatedGain
                start += count
            }
            gain = nextGain
        }
        if digitalSilence { return zeroOutput() }
        // The final FFT covers the same most recent 512 samples as before,
        // with the gain reached after the final tracker sub-block.
        let span = ceilingDB - floorDB
        for k in 0..<bandCount {
            out[k] = min(1, max(0, (out[k] + gain - floorDB) / span))
        }
        return UnsafeBufferPointer(start: out, count: bandCount)
    }

    private func updateDisplayGain(_ samples: UnsafeBufferPointer<Float>, inputPower: Double,
                                   digitalSilence: Bool) -> Float? {
        let base = samples.baseAddress!
        let seconds = Double(samples.count) / Double(sampleRate)
        let nearSilent = inputPower / Double(samples.count) < 1e-9
        if nearSilent { nonSilentStart = nil; qualifyingFrames = 0 }
        let regionSize = max(1, Int((Double(sampleRate) * 0.001).rounded()))
        var regionPower = self.regionPower
        var regionSamples = self.regionSamples
        var processedSamples = self.processedSamples
        var nonSilentStart = self.nonSilentStart
        var lastSilentEnd = self.lastSilentEnd
        for sample in samples {
            regionPower += Double(sample) * Double(sample)
            regionSamples += 1; processedSamples += 1
            if regionSamples == regionSize {
                let end = Double(processedSamples) / Double(sampleRate)
                if regionPower / Double(regionSamples) < 1e-9 {
                    lastSilentEnd = end; nonSilentStart = nil
                } else if !nearSilent && nonSilentStart == nil {
                    nonSilentStart = end - Double(regionSize) / Double(sampleRate)
                }
                regionPower = 0; regionSamples = 0
            }
        }
        self.regionPower = regionPower
        self.regionSamples = regionSamples
        self.processedSamples = processedSamples
        self.nonSilentStart = nonSilentStart
        self.lastSilentEnd = lastSilentEnd
        elapsedSeconds += seconds
        let count = samples.count
        var i = 0
        while i < count {
            let chunk = min(count - i, n - writeIndex)
            (ring + writeIndex).update(from: base + i, count: chunk)
            writeIndex = (writeIndex + chunk) % n; i += chunk
        }
        if digitalSilence {
            updateNoiseFloor()
            qualifyingFrames = 0
            // A mixed delivered buffer still publishes its final FFT window.
            guard computeBandDB().isFinite else { return nil }
            return 0 // Exact zeros never lower the noise estimate.
        }
        let framePeakDB = computeBandDB()
        guard framePeakDB.isFinite else { return nil }
        // Tracker time advances by this sub-block, solely on the single audio tap.
        // NO FLOOR -> NO GAIN. Startup/fade-in never seeds the minimum: wait
        // 150 ms of real audio and require the whole FFT window to follow silence.
        let eligibleAt = max((nonSilentStart ?? elapsedSeconds) + 0.15,
                             lastSilentEnd + Double(n) / Double(sampleRate))
        let eligible = nonSilentStart != nil && elapsedSeconds + 1e-9 >= eligibleAt
        history[historyIndex] = LoudnessFrame(peak: framePeakDB, end: elapsedSeconds,
            duration: seconds,
            floorDuration: eligible ? min(seconds, max(0, elapsedSeconds - eligibleAt)) : 0)
        historyIndex = (historyIndex + 1) % historyCapacity
        historyCount = min(historyCount + 1, historyCapacity)
        updateNoiseFloor()
        let isSpeech = hasEstablishedFloor && (noiseFloorDB.map { framePeakDB >= $0 + speechMarginDB } ?? false)
        qualifyingFrames = isSpeech ? min(qualifyingFrames + 1, historyCapacity) : 0
        var duration: Double = 0
        var persistentPeak = framePeakDB
        var frames = 0
        for offset in 0..<min(qualifyingFrames, historyCount) {
            let frame = history[(historyIndex - 1 - offset + historyCapacity) % historyCapacity]
            persistentPeak = min(persistentPeak, frame.peak)
            duration += frame.duration
            frames += 1
            if frames >= 3 && duration + 1e-9 >= speechQualificationSeconds { break }
        }
        let sustainedSpeech = frames >= 3 && duration + 1e-9 >= speechQualificationSeconds
        if sustainedSpeech {
            // Both initial adoption and upward attack use the minimum over a
            // qualifying window, so an isolated loud frame cannot move the peak.
            trackedPeakDB = max(persistentPeak, (trackedPeakDB ?? persistentPeak) - 3 * Float(seconds))
            speechSeconds += Float(seconds)
        }
        // Loud frames never inherit quiet-speech gain while the qualified peak catches up.
        let gain = framePeakDB < targetPeakDB && displayGainEnabled && floorEstablished
            && sustainedSpeech && speechSeconds > 0.25 ? trackedGainDB : 0
        return gain
    }

    private func computeBandDB() -> Float {
        // Unroll ring (oldest first) and window.
        let tail = n - writeIndex
        vDSP_vmul(ring + writeIndex, 1, window, 1, windowed, 1, vDSP_Length(tail))
        if writeIndex > 0 { vDSP_vmul(ring, 1, window + tail, 1, windowed + tail, 1, vDSP_Length(writeIndex)) }
        var split = DSPSplitComplex(realp: real, imagp: imag)
        windowed.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
        }
        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
        imag[0] = 0  // packed Nyquist; bin 0 (DC) is never used
        vDSP_zvmags(&split, 1, power, 1, vDSP_Length(n / 2))
        var framePeakDB: Float = -.infinity
        for k in 0..<bandCount {
            let (lo, hi) = bins[k]
            var sum: Float = 0
            for j in lo...hi { sum += power[j] }
            let mean = sum / Float(hi - lo + 1)
            let db = 10 * log10(mean + 1e-12) - normDB + tiltDB[k]
            guard db.isFinite else { return -.infinity }
            out[k] = db
            framePeakDB = max(framePeakDB, db)
        }
        return framePeakDB
    }

    private func updateNoiseFloor() {
        var minimum: Float = .infinity
        var floorSeconds: Double = 0
        let cutoff = elapsedSeconds - 1.5
        var index = historyIndex
        for _ in 0..<historyCount {
            index = index == 0 ? historyCapacity - 1 : index - 1
            let frame = history[index]
            if frame.end <= cutoff { break }
            if frame.floorDuration > 0 {
                minimum = min(minimum, frame.peak)
                floorSeconds += min(frame.floorDuration, frame.end - cutoff)
            }
        }
        validFloorSeconds = floorSeconds
        // A floor is established only with 200 ms of eligible history. Until then,
        // the display uses exactly the original, zero-gain mapping.
        floorEstablished = validFloorSeconds + 1e-9 >= 0.2
        // Retain peak adaptation after initial establishment even if sparse valid
        // history later dips below 200 ms; output gain still requires a ready floor.
        hasEstablishedFloor = hasEstablishedFloor || floorEstablished
        noiseFloorDB = validFloorSeconds > 0 ? max(-78, minimum) : nil
    }

    /// Begin a fresh per-dictation display adaptation on the next audio buffer.
    /// Only display state is reset; recorded samples and voice processing are untouched.
    public func resetDisplayGain() { resetRequested.withLock { $0 = true } }

    /// Internal diagnostics include the actual optional tracker values, so tests
    /// detect NaN poisoning even if min/max happen to hide it in the output gain.
    var displayGainState: (peak: Float?, floor: Float?, gain: Float, floorSeconds: Double) {
        (trackedPeakDB, floorEstablished ? noiseFloorDB : nil, floorEstablished ? trackedGainDB : 0, validFloorSeconds)
    }

    // Internal diagnostics allow tests to distinguish a frozen tracker from merely
    // gated output. This is the retained peak adaptation, not the applied gain.
    var trackedGainDB: Float { min(maxGainDB, max(0, targetPeakDB - (trackedPeakDB ?? targetPeakDB))) }

    private func zeroOutput() -> UnsafeBufferPointer<Float> {
        for k in 0..<bandCount { out[k] = 0 }
        return UnsafeBufferPointer(start: out, count: bandCount)
    }

    public var levels: [Float] { Array(UnsafeBufferPointer(start: out, count: bandCount)) }

    /// Centre frequency of each band (Hz), for tests/diagnostics.
    public func centreFrequency(band k: Int, sampleRate: Double = AudioConstants.sampleRate) -> Double {
        let binHz = sampleRate / Double(n)
        return Double(bins[k].lo + bins[k].hi) / 2 * binHz
    }
}
