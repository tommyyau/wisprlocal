import AVFoundation
import Foundation
import Testing
@testable import WisprLocalCore

/// PROOF OF SOURCE for the zeroed audio (2026-10-03): a known continuous signal goes through
/// every stage WisprLocal owns — tap buffer → 48/44.1 kHz → 16 kHz converter → warm ring →
/// pre-roll prepend → recording sink → VAD trim → the samples handed to ASR — and every stage
/// must preserve continuity exactly: no inserted silent runs, no dropped, duplicated or stale
/// frames, lengths exact. These pass, so the zero runs in the plane clips are NOT made by our
/// capture path (see `ZeroGateDetectorTests` / the replay `--gating` report for the device side).
@Suite struct CaptureContinuityTests {
    static let preRoll = MicWarmPolicy.samples(MicWarmPolicy.preRoll)

    /// `rec` must be an exact contiguous slice of the converter output starting at `offset`,
    /// `expected` long, with no inserted silence. Offsets/lengths are measured against a DRAINED
    /// one-shot conversion, so they may differ by the converter's constant held-back latency.
    func expectContinuous(_ rec: [Float], _ ref: [Float], offset: Int, count expected: Int,
                          sourceLocation: SourceLocation = #_sourceLocation) {
        let c = Continuity.check(rec, against: ref)
        let tol = Continuity.latencyTolerance
        #expect(c.offset != nil, "recording is not an exact contiguous slice of the converter output", sourceLocation: sourceLocation)
        if let o = c.offset { #expect(abs(o - offset) <= tol, "offset \(o) vs expected \(offset)", sourceLocation: sourceLocation) }
        #expect(c.gating == .none, "inserted silence: \(c.gating)", sourceLocation: sourceLocation)
        #expect(abs(rec.count - expected) <= tol, "length \(rec.count) vs expected \(expected)", sourceLocation: sourceLocation)
    }

    @Test func coldStart() {
        let h = CaptureHarness()
        #expect(h.startRecording() == false)
        h.feed(seconds: 2.0)
        let rec = h.stopRecording(keepWarm: false)
        // Cold: everything the fresh converter emitted, from its first frame.
        expectContinuous(rec, h.reference, offset: 0, count: h.reference.count)
        #expect(abs(rec.count - 32_000) <= 8, "only the converter's constant latency may be missing (\(rec.count))")
        #expect(!h.engineRunning && !h.sink.ringEnabled)
    }

    @Test func warmStartPrependsExactly300msWithNoSeam() {
        let h = CaptureHarness()
        h.enterWarm()
        h.feed(seconds: 1.0)
        let before = h.reference.count
        #expect(h.startRecording() == true)
        h.feed(seconds: 1.5)
        let rec = h.stopRecording(keepWarm: true)
        let ref = h.reference
        expectContinuous(rec, ref, offset: before - Self.preRoll, count: Self.preRoll + (ref.count - before))
        #expect(h.engineRunning && h.sink.ringEnabled, "stays warm")
    }

    @Test func backToBackDictationsOnAWarmEngine() {
        let h = CaptureHarness()
        h.enterWarm()
        h.feed(seconds: 0.7)
        for gap in [0.2, 0.05, 1.3] {
            let before = h.reference.count
            #expect(h.startRecording())
            h.feed(seconds: 1.1, bufferFrames: [1024, 480, 4096])
            let rec = h.stopRecording(keepWarm: true)
            let ref = h.reference
            expectContinuous(rec, ref, offset: before - Self.preRoll, count: Self.preRoll + (ref.count - before))
            h.feed(seconds: gap)  // warm between dictations: the ring keeps rolling
        }
    }

    /// Warm window expires (engine stopped, ring zeroed), then a cold dictation: it must start
    /// with ITS OWN audio — not the converter's held-back frames from the previous run.
    @Test func warmWindowExpiryThenColdDictationCarriesNothingOver() {
        let h = CaptureHarness()
        h.enterWarm()
        h.feed(seconds: 0.8)
        _ = h.startRecording()
        h.feed(seconds: 1.0)
        _ = h.stopRecording(keepWarm: true)
        h.feed(seconds: 0.4)
        h.leaveWarm()                       // 60 s window expired
        #expect(h.startRecording() == false)
        h.feed(seconds: 1.2)
        let rec = h.stopRecording(keepWarm: false)
        expectContinuous(rec, h.reference, offset: 0, count: h.reference.count)
    }

    /// Two cold dictations in a row (warm mic off): the second must not begin with the tail of
    /// the first (regression: before `engineWillStart()` reset the converter, ~6 frames ≈ 0.4 ms
    /// of the PREVIOUS dictation led the next one).
    @Test func coldAfterColdHasNoStaleFrames() {
        let h = CaptureHarness()
        _ = h.startRecording(); h.feed(seconds: 1.0); _ = h.stopRecording(keepWarm: false)
        _ = h.startRecording(); h.feed(seconds: 1.0)
        let rec = h.stopRecording(keepWarm: false)
        expectContinuous(rec, h.reference, offset: 0, count: h.reference.count)
    }

    /// Device change mid-recording (AirPods ↔ built-in: 48 kHz stereo → 44.1 kHz mono): the
    /// engine is rebuilt into the SAME sink. The recording is segment 1 then segment 2, each
    /// exact; the restart gap is missing time, never inserted zeros.
    @Test(arguments: [false, true])
    func deviceChangeMidRecording(warm: Bool) throws {
        let h = CaptureHarness(rate: 48_000, channels: 2)
        if warm { h.enterWarm(); h.feed(seconds: 0.6) }
        let before = warm ? h.reference.count : 0
        _ = h.startRecording()
        h.feed(seconds: 1.0)
        let seg1 = h.reference
        h.rebuild(rate: 44_100, channels: 1)   // AVAudioEngineConfigurationChange → prepareOnQueue
        h.startEngine()                          // → startEngine
        h.feed(seconds: 1.0, bufferFrames: [941, 1024])
        let seg2 = h.reference
        let rec = h.stopRecording(keepWarm: false)
        // Segment 1 ends where the old converter stopped (its held-back frames are discarded with
        // it); segment 2 starts at the new converter's first frame. Nothing in between.
        let head = Array(seg2.prefix(64))
        let split = try #require((64..<(rec.count - 64)).first { k in rec[k] == head[0] && Array(rec[k..<(k + 64)]) == head },
                                 "segment 2 (new converter) not found in the recording")
        #expect(Continuity.check(Array(rec[split...]), against: seg2).offset == 0, "segment 2 not exact from its first frame")
        #expect(Continuity.check(Array(rec[..<split]), against: seg1).offset.map { abs($0 - (warm ? before - Self.preRoll : 0)) <= 8 } == true)
        #expect(seg1.count - (split + (warm ? before - Self.preRoll : 0)) <= Continuity.latencyTolerance, "only latency frames lost at the seam")
        #expect(AudioGatingMetrics.measureAllRuns(rec) == .none)
    }

    /// Partial pre-roll: a recording that starts before the ring holds 300 ms prepends only what
    /// was really captured (never unwritten, zero-filled ring slots).
    @Test func warmStartWithPartlyFilledRing() {
        let h = CaptureHarness()
        h.enterWarm()
        h.feed(seconds: 0.1)                     // ~1,600 samples in the ring
        let before = h.reference.count
        #expect(h.startRecording())
        h.feed(seconds: 0.5)
        let rec = h.stopRecording(keepWarm: true)
        let ref = h.reference
        #expect(before < Self.preRoll)
        expectContinuous(rec, ref, offset: 0, count: ref.count)
    }

    /// The last stage we own: VAD trim keeps one contiguous range, and that exact slice is
    /// what the transcriber receives.
    @MainActor @Test func vadTrimAndHandOffToASRAreExactSlices() async {
        let h = CaptureHarness()
        h.enterWarm(); h.feed(seconds: 0.8)
        _ = h.startRecording(); h.feed(seconds: 2.0)
        let rec = h.stopRecording(keepWarm: true)
        let trimmer = RangeTrimmer(speechStart: 9_000, speechEnd: 30_000)
        let asr = RecordingTranscriber()
        let p2 = DictationPipeline(audio: FakeAudio(), trimmer: trimmer, transcriber: asr, dictionary: tempDictionary(),
                                   cleaner: RuleCleaner(), gate: ConflictDetector(runningApps: { [] }, fnUsageReader: { 0 }),
                                   inserterFor: { _ in (FakeInserter(), .paste) },
                                   history: MemoryHistory(), frontmostApp: { nil }, caretReader: FakeCaretReader(),
                                   debugRecordings: nil, autoFormatter: .none)
        await p2.prepareModels()
        _ = await p2.process(samples: rec, target: nil)
        let r = SileroSpeechTrimmer.keptRange(speechStart: 9_000, speechEnd: 30_000, count: rec.count, sampleRate: 16_000,
                                              preRoll: 0.3, postRoll: 0.4)!
        #expect(asr.received.count == 1)
        #expect(Continuity.bytes(asr.received.first ?? []) == Continuity.bytes(Array(rec[r])))
    }

    /// STRUCTURAL: the engine starts in exactly one place, which resets the converter first.
    @Test func engineStartsOnlyThroughStartEngine() throws {
        let src = try String(contentsOf: PreRollPrivacyTests.sources.appendingPathComponent("WisprLocalCore/Audio/AudioRecorder.swift"),
                             encoding: .utf8)
        #expect(src.components(separatedBy: "engine.start()").count == 2, "engine.start() must appear once (in startEngine)")
        #expect(src.contains("path.engineWillStart()\n        try engine.start()"))
    }
}

/// Golden: the fixture clip through the full capture path + pipeline (ASR mocked) arrives at the
/// transcriber byte-identical to the expected 48 → 16 kHz resampling of what the device sent.
@MainActor @Suite struct GoldenCaptureTests {
    static var fixture: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/clip05.wav")
    }

    @Test func fixtureClipArrivesAtTheTranscriberByteIdentical() async throws {
        let clip = try WAV.decode(Data(contentsOf: Self.fixture))
        #expect(clip.sampleRate == 16_000)
        // What a 48 kHz device would deliver for this speech.
        let up = try #require(Upsampler.to48k(clip.samples))
        let fmt = CaptureHarness.format(rate: 48_000, channels: 1)
        let path = CapturePath(sink: SampleSink(maxSamples: 16_000 * 60))
        let tap = path.makeTap(for: fmt, report: { _, _ in })!
        path.sink.beginRecording(engineRunning: false)
        path.engineWillStart()
        var i = 0, t: AVAudioFramePosition = 0
        while i < up.count {
            let n = min(1024, up.count - i)
            let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n))!
            b.frameLength = AVAudioFrameCount(n)
            for k in 0..<n { b.floatChannelData![0][k] = up[i + k] }
            tap(b, AVAudioTime(sampleTime: t, atRate: 48_000))
            i += n; t += AVAudioFramePosition(n)
        }
        let captured = path.sink.end()
        let expected = CaptureHarness.oneShot(up, format: fmt)
        #expect(Continuity.bytes(captured) == Continuity.bytes(Array(expected.prefix(captured.count))))
        #expect(expected.count - captured.count <= Continuity.latencyTolerance)

        let asr = RecordingTranscriber()
        let p = DictationPipeline(audio: FakeAudio(), trimmer: FakeTrimmer(), transcriber: asr, dictionary: tempDictionary(),
                                  cleaner: RuleCleaner(), gate: ConflictDetector(runningApps: { [] }, fnUsageReader: { 0 }),
                                  inserterFor: { _ in (FakeInserter(), .paste) }, history: MemoryHistory(), frontmostApp: { nil },
                                  caretReader: FakeCaretReader(), debugRecordings: nil, autoFormatter: .none)
        await p.prepareModels()
        _ = await p.process(samples: captured, target: nil)
        #expect(asr.received.count == 1)
        #expect(Continuity.bytes(asr.received.first ?? []) == Continuity.bytes(captured), "the transcriber got different bytes")
        #expect(AudioGatingMetrics.measureAllRuns(expected).maxZeroRunMs < 250, "fixture sanity")
    }
}

enum Upsampler {
    static func to48k(_ x: [Float]) -> [Float]? {
        let inF = CaptureHarness.format(rate: 16_000, channels: 1), outF = CaptureHarness.format(rate: 48_000, channels: 1)
        guard let c = AVAudioConverter(from: inF, to: outF),
              let b = AVAudioPCMBuffer(pcmFormat: inF, frameCapacity: AVAudioFrameCount(x.count)),
              let o = AVAudioPCMBuffer(pcmFormat: outF, frameCapacity: AVAudioFrameCount(x.count * 3 + 64)) else { return nil }
        b.frameLength = AVAudioFrameCount(x.count)
        for k in 0..<x.count { b.floatChannelData![0][k] = x[k] }
        nonisolated(unsafe) var fed = false
        nonisolated(unsafe) let input = b   // the converter calls this block synchronously, on this thread
        _ = c.convert(to: o, error: nil) { _, s in
            if fed { s.pointee = .endOfStream; return nil }
            fed = true; s.pointee = .haveData; return input
        }
        return Array(UnsafeBufferPointer(start: o.floatChannelData![0], count: Int(o.frameLength)))
    }
}

/// Records what the pipeline hands to ASR.
final class RecordingTranscriber: Transcriber, @unchecked Sendable {
    private let lock = NSLock()
    private var _received: [[Float]] = []
    var received: [[Float]] { lock.withLock { _received } }
    var engineName: String { "recording" }
    func prepare() async throws {}
    func reset() async {}
    func transcribe(_ samples: [Float], vocabularyHints: [String]) async throws -> String {
        lock.withLock { _received.append(samples) }
        return "hello there"
    }
}

/// A trimmer with known speech bounds, applying the production `keptRange`.
struct RangeTrimmer: SpeechTrimmer {
    let speechStart: Int, speechEnd: Int
    func prepare() async throws {}
    func trim(_ samples: [Float]) async throws -> [Float]? {
        SileroSpeechTrimmer.keptRange(speechStart: speechStart, speechEnd: speechEnd, count: samples.count,
                                      sampleRate: 16_000, preRoll: 0.3, postRoll: 0.4).map { Array(samples[$0]) }
    }
}

@Suite struct RingBufferTests {
    static func ramp(_ n: Int, from: Int = 0) -> [Float] { (from..<(from + n)).map { Float($0 + 1) } }

    @Test func wraparoundKeepsNewestInOrder() {
        var r = PreRollRing(capacity: 8_000)
        for chunk in stride(from: 0, to: 30_000, by: 1_337) { r.write(Self.ramp(min(1_337, 30_000 - chunk), from: chunk)) }
        #expect(r.count == 8_000)
        #expect(r.last(4_800) == Self.ramp(4_800, from: 25_200))
    }

    @Test func partialFillReturnsOnlyWrittenSamples() {
        var r = PreRollRing(capacity: 8_000)
        r.write(Self.ramp(1_000))
        #expect(r.count == 1_000)
        #expect(r.last(4_800) == Self.ramp(1_000), "never pads with unwritten (zero) slots")
        #expect(!r.last(4_800).contains(0))
    }

    @Test func sinkNeverPrependsUnwrittenSlots() {
        let sink = SampleSink(maxSamples: 100_000)
        sink.enableRing()
        Self.ramp(1_000).withUnsafeBufferPointer { _ = sink.append($0) }
        #expect(sink.begin(preRoll: 4_800) == 1_000)
        let got = sink.end()
        #expect(got == Self.ramp(1_000))
    }

    @Test func emptyRingPrependsNothing() {
        let sink = SampleSink(maxSamples: 100_000)
        sink.enableRing()
        #expect(sink.beginRecording(engineRunning: true) == true)
        #expect(sink.end().isEmpty)
    }

    @Test func reenabledRingStartsEmpty() {
        let sink = SampleSink(maxSamples: 100_000)
        sink.enableRing()
        Self.ramp(8_000).withUnsafeBufferPointer { _ = sink.append($0) }
        sink.disableRing(); sink.enableRing()
        #expect(sink.ringSnapshotForTesting().isEmpty)
        #expect(sink.begin(preRoll: 4_800) == 0)
    }
}

@Suite struct ConverterTests {
    static func buffer(_ x: ArraySlice<Float>, _ fmt: AVAudioFormat) -> AVAudioPCMBuffer {
        let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(max(1, x.count)))!
        b.frameLength = AVAudioFrameCount(x.count)
        for (k, v) in x.enumerated() {
            b.floatChannelData![0][k] = v
            for c in 1..<Int(fmt.channelCount) { b.floatChannelData![c][k] = 0.25 * v }
        }
        return b
    }

    static func signal(_ n: Int, rate: Double) -> [Float] {
        var s = TestSignal(); return (0..<n).map { _ in s.next(rate: rate) }
    }

    static func run(_ r: MonoResampler, _ x: [Float], sizes: [Int]) -> (out: [Float], counts: [Int]) {
        var out: [Float] = [], counts: [Int] = [], i = 0, j = 0
        while i < x.count {
            let n = min(sizes[j % sizes.count], x.count - i); j += 1
            let o = r.convert(buffer(x[i..<(i + n)], r.inputFormat))!
            counts.append(Int(o.frameLength))
            out += UnsafeBufferPointer(start: o.floatChannelData![0], count: Int(o.frameLength))
            i += n
        }
        return (out, counts)
    }

    /// Chunked conversion (any tap buffer size, incl. VPIO's 480/512 and odd sizes) is
    /// sample-for-sample the one-shot conversion: no zero padding or loss mid-stream.
    @Test(arguments: [[1024], [480], [512, 4096], [333, 1, 2048, 941]])
    func chunkedEqualsOneShot(_ sizes: [Int]) {
        let fmt = CaptureHarness.format(rate: 48_000, channels: 2)
        let x = Self.signal(96_000, rate: 48_000)
        let (out, _) = Self.run(MonoResampler(inputFormat: fmt)!, x, sizes: sizes)
        let one = CaptureHarness.oneShot(x, format: fmt)
        #expect(Array(one.prefix(out.count)) == out, "chunked output is not the one-shot output")
        #expect(one.count - out.count <= Continuity.latencyTolerance, "only the constant latency may be outstanding")
        #expect(AudioGatingMetrics.measureAllRuns(out) == .none)
    }

    /// A call may return FEWER frames than input/3 (the first one does: latency), never padding:
    /// short outputs are passed through as-is and the total catches up.
    @Test func shortOutputsAreNotPadded() {
        let fmt = CaptureHarness.format(rate: 48_000, channels: 1)
        let x = Self.signal(48_000, rate: 48_000)
        let (out, counts) = Self.run(MonoResampler(inputFormat: fmt)!, x, sizes: [1024])
        #expect(counts.first! < 1024 / 3, "first call is short (converter latency)")
        #expect(counts.dropFirst().dropLast().allSatisfy { (340...342).contains($0) })
        #expect(abs(out.count - 16_000) <= 8)
        #expect(!out.prefix(16).contains(0), "no leading zero padding")
    }

    @Test func resetDropsStaleFramesAcrossRuns() {
        let fmt = CaptureHarness.format(rate: 48_000, channels: 1)
        let r = MonoResampler(inputFormat: fmt)!
        _ = Self.run(r, Self.signal(20_000, rate: 48_000), sizes: [1024])
        let second = [Float](repeating: -0.3, count: 4_096)
        let fresh = CaptureHarness.oneShot(second, format: fmt)
        let stale = Self.run(r, second, sizes: [4_096]).out
        #expect(Array(fresh.prefix(stale.count)) != stale, "without a reset the previous run's held-back frames lead (the bug)")
        r.reset()
        let afterReset = Self.run(r, second, sizes: [4_096]).out
        #expect(Array(fresh.prefix(afterReset.count)) == afterReset, "after reset == a fresh converter")
        #expect(fresh.count - afterReset.count <= Continuity.latencyTolerance)
    }

    /// The processed mic is channel 0 (VPIO): channel 1 alone never reaches the recording.
    @Test func usesChannelZero() {
        let fmt = CaptureHarness.format(rate: 48_000, channels: 2)
        let r = MonoResampler(inputFormat: fmt)!
        let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 4_800)!
        b.frameLength = 4_800
        for k in 0..<4_800 { b.floatChannelData![0][k] = 0; b.floatChannelData![1][k] = 0.5 }
        let o = r.convert(b)!
        #expect(UnsafeBufferPointer(start: o.floatChannelData![0], count: Int(o.frameLength)).allSatisfy { $0 == 0 })
    }
}

extension PreRollTests {
    /// Exactly 300 ms, and the seam between pre-roll and live audio is sample-continuous through
    /// the real tap + converter (not just in the sink).
    @Test func preRollIsExactly300msAndSeamless() throws {
        let h = CaptureHarness()
        h.enterWarm()
        h.feed(seconds: 2.0)
        let before = h.reference.count
        h.startRecording()
        h.feed(seconds: 0.25, bufferFrames: [512])
        let rec = h.stopRecording(keepWarm: true)
        let ref = h.reference
        #expect(MicWarmPolicy.samples(MicWarmPolicy.preRoll) == 4_800)
        let c = Continuity.check(rec, against: ref)
        let o = try #require(c.offset, "not one contiguous slice: the seam has a gap, overlap or zeros")
        // The 4,800 pre-roll samples end exactly where key-down was (± the converter latency).
        #expect(abs((o + 4_800) - before) <= Continuity.latencyTolerance)
        #expect(abs(rec.count - (4_800 + ref.count - before)) <= Continuity.latencyTolerance)
        #expect(c.gating == .none)
    }
}
