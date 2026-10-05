import AVFoundation
import Foundation
@testable import WisprLocalCore

/// Deterministic, continuous "speech-like" test signal: two partials (440 / 1230 Hz) under a
/// 4 Hz syllabic envelope plus low-level noise from a fixed LCG. It is never digitally silent
/// for more than a zero crossing, so ANY run of ≥ 8 silent samples downstream was inserted.
struct TestSignal {
    private(set) var t: Double = 0
    private var rng: UInt64 = 0x9E37_79B9_7F4A_7C15

    mutating func next(rate: Double) -> Float {
        rng = rng &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        let noise = Double((rng >> 33) & 0xFFFF) / 65_536 - 0.5
        let env = 0.35 + 0.3 * sin(2 * .pi * 4 * t)
        let v = env * (0.6 * sin(2 * .pi * 440 * t) + 0.3 * sin(2 * .pi * 1230 * t)) + 0.02 * noise
        t += 1 / rate
        return Float(v)
    }
}

/// Drives the REAL capture path (`CapturePath`: the production tap block, `MonoResampler`,
/// `SampleSink` + pre-roll ring) without hardware, in the same call order as `AudioRecorder`:
/// `startEngine()` = `path.engineWillStart()` then "engine running"; a rebuild = a fresh
/// converter + tap for the new format into the SAME sink. Tap buffers are synthesised from
/// `TestSignal` at the device rate.
///
/// The reference for continuity is the converter's own output when fed the same input in ONE
/// call by a fresh converter (`oneShot`). AVAudioConverter is exactly chunk-invariant
/// (`ConverterTests.chunkedEqualsOneShot`), so a recording that is not an exact, contiguous slice
/// of that reference has had samples inserted, dropped, duplicated or carried over.
final class CaptureHarness {
    let path = CapturePath(sink: SampleSink(maxSamples: 16_000 * 600))
    var sink: SampleSink { path.sink }
    private(set) var format: AVAudioFormat
    private var tap: AVAudioNodeTapBlock
    private var signal = TestSignal()
    private var sampleTime: AVAudioFramePosition = 0
    private(set) var engineRunning = false
    /// Channel-0 input the CURRENT converter has consumed since it was created or reset.
    private(set) var converterInput: [Float] = []
    /// Everything the current converter emitted, in order (the oracle the sink is compared to).
    var reference: [Float] { Self.oneShot(converterInput, format: format) }

    init(rate: Double = 48_000, channels: AVAudioChannelCount = 1) {
        format = Self.format(rate: rate, channels: channels)
        tap = { _, _ in }
        rebuild(rate: rate, channels: channels)
    }

    static func format(rate: Double, channels: AVAudioChannelCount) -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: false)!
    }

    /// `AudioRecorder.prepareOnQueue`: engine stopped, new format → fresh converter + tap.
    func rebuild(rate: Double, channels: AVAudioChannelCount = 1) {
        engineRunning = false
        format = Self.format(rate: rate, channels: channels)
        tap = path.makeTap(for: format, report: { _, _ in })!
        converterInput = []
    }

    /// `AudioRecorder.startEngine`.
    func startEngine() {
        path.engineWillStart()
        converterInput = []
        engineRunning = true
    }

    func stopEngine() { engineRunning = false }

    /// The device delivers `seconds` of audio in tap buffers of `bufferFrames` (cycled).
    func feed(seconds: Double, bufferFrames: [Int] = [1024]) {
        precondition(engineRunning, "a stopped engine delivers no buffers")
        var left = Int((seconds * format.sampleRate).rounded())
        var i = 0
        while left > 0 {
            let n = min(left, bufferFrames[i % bufferFrames.count]); i += 1; left -= n
            let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
            b.frameLength = AVAudioFrameCount(n)
            var ch0: [Float] = []; ch0.reserveCapacity(n)
            for k in 0..<n {
                let v = signal.next(rate: format.sampleRate)
                b.floatChannelData![0][k] = v
                for c in 1..<Int(format.channelCount) { b.floatChannelData![c][k] = 0.25 * v }
                ch0.append(v)
            }
            // The tap converts only while listening (recording or warm); mirror that for the oracle.
            if sink.isListening { converterInput += ch0 }
            tap(b, AVAudioTime(sampleTime: sampleTime, atRate: format.sampleRate))
            sampleTime += AVAudioFramePosition(n)
        }
    }

    // MARK: AudioRecorder call order

    /// `enterWarm()`.
    func enterWarm() {
        sink.enableRing()
        if !engineRunning { startEngine() }
    }

    /// `start()`; returns whether it was warm.
    @discardableResult
    func startRecording() -> Bool {
        let warm = sink.beginRecording(engineRunning: engineRunning)
        if !engineRunning { startEngine() }
        return warm
    }

    /// `stopNow()` with `keepWarm`.
    func stopRecording(keepWarm: Bool) -> [Float] {
        let out = sink.end()
        if keepWarm && engineRunning { sink.enableRing() } else { stopEngine(); sink.disableRing() }
        return out
    }

    /// `leaveWarm()` while not recording.
    func leaveWarm() {
        sink.disableRing()
        stopEngine()
    }

    // MARK: oracle

    static func oneShot(_ x: [Float], format: AVAudioFormat) -> [Float] {
        guard !x.isEmpty else { return [] }
        let r = MonoResampler(inputFormat: format)!
        let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(x.count))!
        b.frameLength = AVAudioFrameCount(x.count)
        for k in 0..<x.count {
            b.floatChannelData![0][k] = x[k]
            for c in 1..<Int(format.channelCount) { b.floatChannelData![c][k] = 0.25 * x[k] }
        }
        // One input, then drain: a single convert call may stop short (stereo + channel map
        // returns ~600 frames early) and emit the rest on the next call.
        var out: [Float] = []
        var next: AVAudioPCMBuffer? = b
        while true {
            let o: AVAudioPCMBuffer
            if let n = next { o = r.convert(n)!; next = nil } else { o = r.convert(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1)!)! }
            if o.frameLength == 0 { break }
            out += UnsafeBufferPointer(start: o.floatChannelData![0], count: Int(o.frameLength))
        }
        return out
    }
}

/// Continuity verdict for one recording against its oracle.
struct Continuity {
    /// The converter holds back a constant few output frames (6 at 48 → 16 kHz) that a drained
    /// one-shot conversion includes; lengths and offsets may differ from the oracle by this much.
    static let latencyTolerance = 8

    /// Where the recording sits in the reference (nil = not an exact contiguous slice).
    var offset: Int?
    var gating: AudioGatingMetrics

    /// Finds `recording` in `reference` (by its first 64 samples) and requires the WHOLE
    /// recording to equal that slice exactly.
    static func check(_ recording: [Float], against reference: [Float]) -> Continuity {
        let g = AudioGatingMetrics.measureAllRuns(recording)
        let probe = Array(recording.prefix(64))
        guard !probe.isEmpty, reference.count >= recording.count else { return Continuity(offset: nil, gating: g) }
        for k in 0...(reference.count - recording.count) where reference[k] == probe[0] {
            guard Array(reference[k..<(k + probe.count)]) == probe else { continue }
            let exact = Array(reference[k..<(k + recording.count)]) == recording
            return Continuity(offset: exact ? k : nil, gating: g)
        }
        return Continuity(offset: nil, gating: g)
    }

    /// Byte view for "byte-identical" assertions.
    static func bytes(_ x: [Float]) -> Data { x.withUnsafeBufferPointer { Data(buffer: $0) } }
}
