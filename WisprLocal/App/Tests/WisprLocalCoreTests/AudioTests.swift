import Testing
import AVFoundation
import Accelerate
@testable import WisprLocalCore

@Suite struct AudioTests {
    @Test func resamples48kStereoTo16kMono() throws {
        let inFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
        let r = try #require(MonoResampler(inputFormat: inFmt))
        var total = 0
        for _ in 0..<50 {  // 50 x 4800 frames = 5 s
            let b = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: 4800)!
            b.frameLength = 4800
            for c in 0..<2 { for i in 0..<4800 { b.floatChannelData![c][i] = sin(Float(i) * 0.05) * 0.5 } }
            let out = try #require(r.convert(b))
            #expect(out.format.channelCount == 1 && out.format.sampleRate == 16_000)
            total += Int(out.frameLength)
        }
        // Only the converter's constant priming latency (~220 frames ≈ 14 ms) may be missing —
        // no per-buffer loss (which would scale with the buffer count).
        #expect(total <= 80_000 && 80_000 - total < 400, "total=\(total)")
    }

    @Test func sinkCapsAtMaxAndSignalsOnce() {
        let s = SampleSink(maxSamples: 10)
        s.begin()
        let data = [Float](repeating: 1, count: 6)
        let hits = (0..<3).map { _ in data.withUnsafeBufferPointer { s.append($0) } }
        #expect(hits == [false, true, false])
        #expect(s.end().count == 10)
        #expect(data.withUnsafeBufferPointer { s.append($0) } == false)  // inactive after end
    }
}

class SpectrumAnalyzerFixtures {

    func sine(_ hz: Double, amp: Float, count: Int = 1024) -> [Float] {
        (0..<count).map { amp * Float(sin(2 * Double.pi * hz * Double($0) / 16_000)) }
    }

    static let calibratedSpeech = Result { () throws -> (samples: [Float], p95: Float) in
        let url = try #require(Bundle.module.url(forResource: "clip05", withExtension: "wav", subdirectory: "Fixtures"))
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        #expect(file.processingFormat.sampleRate == 16_000)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let all = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        let windows = stride(from: 0, through: all.count - 320, by: 320).map { start in
            (all[start..<start + 320].reduce(0) { $0 + $1 * $1 } / 320).squareRoot()
        }.sorted()
        return (Array(all.prefix(80_000)), windows[Int(Double(windows.count - 1) * 0.95)])
    }

    func speech(levelDB: Float) throws -> (samples: [Float], threshold: Float) {
        let fixture = try Self.calibratedSpeech.get()
        let target = pow(Float(10), levelDB / 20)
        return (scaled(fixture.samples, by: target / fixture.p95), target / 10)
    }

    func rms(_ samples: ArraySlice<Float>) -> Float {
        (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
    }

    func outputs(_ samples: [Float], analyzer: SpectrumAnalyzer, hop: Int = 320) -> [[Float]] {
        samples.withUnsafeBufferPointer { pointer in
            stride(from: 0, through: samples.count - hop, by: hop).map { start in
                Array(analyzer.process(UnsafeBufferPointer(rebasing: pointer[start..<start + hop])))
            }
        }
    }

    func mean(_ frames: [[Float]]) -> Float {
        frames.reduce(0) { $0 + $1.reduce(0, +) } / Float(frames.count * SpectrumBands.count)
    }

    func speechFrames(_ frames: [[Float]], samples: [Float], threshold: Float) -> [[Float]] {
        frames.enumerated().compactMap { index, frame in
            let start = index * 320
            return start >= 16_000 && rms(samples[start..<start + 320]) >= threshold ? frame : nil
        }
    }

    func scaled(_ samples: [Float], by scale: Float) -> [Float] {
        var result = [Float](repeating: 0, count: samples.count)
        var scale = scale
        vDSP_vsmul(samples, 1, &scale, &result, 1, vDSP_Length(samples.count))
        return result
    }

    static let uniformNoise: [Float] = {
        var seed: UInt64 = 0x12345678
        return (0..<192_000).map { _ in
            seed = seed &* 6364136223846793005 &+ 1
            return (Float(seed >> 40) / Float(1 << 24) * 2 - 1) * Float(3).squareRoot()
        }
    }()

    func noise(levelDB: Float, seconds: Int) -> [Float] {
        scaled(Array(Self.uniformNoise.prefix(seconds * 16_000)), by: pow(10, levelDB / 20))
    }

    // Probe generators: a single Gaussian stream (and continuous pink filter
    // history) for the entire run, never reseeded at a frame boundary.
    func generateProbeNoise(levelDB: Float, count: Int, pink: Bool = false, seed: UInt64 = 21) -> [Float] {
        var state = seed &* 0x9E3779B97F4A7C15 | 1
        func uniform() -> Double {
            state ^= state >> 12; state ^= state << 25; state ^= state >> 27
            return Double((state &* 2685821657736338717) >> 11) / Double(UInt64(1) << 53)
        }
        var b = [Float](repeating: 0, count: 7)
        var values = (0..<count).map { _ -> Float in
            let w = Float(sqrt(-2 * log(max(uniform(), 1e-12))) * cos(2 * .pi * uniform()))
            guard pink else { return w }
            b[0] = 0.99886 * b[0] + w * 0.0555179
            b[1] = 0.99332 * b[1] + w * 0.0750759
            b[2] = 0.969 * b[2] + w * 0.153852
            b[3] = 0.8665 * b[3] + w * 0.3104856
            b[4] = 0.55 * b[4] + w * 0.5329522
            b[5] = -0.7616 * b[5] - w * 0.016898
            let value = b.reduce(0, +) + w * 0.5362
            b[6] = w * 0.115926
            return value
        }
        let scale = pow(Float(10), levelDB / 20) / rms(values[...])
        for i in values.indices { values[i] *= scale }
        return values
    }

    static let whiteProbe = SpectrumAnalyzerFixtures().generateProbeNoise(levelDB: 0, count: 192_000)
    static let pinkProbe = SpectrumAnalyzerFixtures().generateProbeNoise(levelDB: 0, count: 192_000, pink: true)

    func probeNoise(levelDB: Float, count: Int, pink: Bool = false, seed: UInt64 = 21) -> [Float] {
        let source = pink ? Self.pinkProbe : Self.whiteProbe
        // Different offsets preserve a continuous stream without regenerating it per test.
        let offset = min(Int(seed % 1000), source.count - count)
        let values = Array(source[offset..<offset + count])
        var measured: Float = 0
        vDSP_rmsqv(values, 1, &measured, vDSP_Length(count))
        return scaled(values, by: pow(10, levelDB / 20) / measured)
    }

    struct Trace {
        var frames: [[Float]] = []
        var ends: [Int] = []
        var gains: [Float] = []
    }

    func trace(_ samples: [Float], analyzer: SpectrumAnalyzer, hop: Int) -> Trace {
        var run = Trace()
        samples.withUnsafeBufferPointer { p in
            for start in stride(from: 0, through: samples.count - hop, by: hop) {
                run.frames.append(Array(analyzer.process(UnsafeBufferPointer(rebasing: p[start..<start + hop]))))
                run.ends.append(start + hop)
                run.gains.append(analyzer.trackedGainDB)
            }
        }
        return run
    }

    func windowMean(_ run: Trace, from: Int, to: Int) -> Float {
        mean(run.ends.indices.filter { run.ends[$0] > from && run.ends[$0] <= to }.map { run.frames[$0] })
    }

    static let swellingBeds: [[Float]] = {
        let test = SpectrumAnalyzerFixtures()
        return [false, true].flatMap { pink in
            let base = test.probeNoise(levelDB: -55, count: 192_000, pink: pink)
            return (0..<4).map { profile in
                var values = base
                var state: UInt64 = 73
                var drift: [Float] = []
                for _ in 0...12 {
                    state = state &* 6364136223846793005 &+ 1
                    drift.append(Float(state >> 40) / Float(1 << 24) * 6 - 3)
                }
                for i in values.indices {
                    let seconds = Double(i) / 16_000
                    let db: Float
                    switch profile {
                    case 0: db = 0
                    case 1: db = 3 * Float(sin(.pi * seconds))
                    case 2: db = 1.5 * Float(sin(.pi * seconds))
                    default:
                        let position = seconds
                        let index = Int(position)
                        let fraction = (1 - cos(Float.pi * Float(position - Double(index)))) / 2
                        db = drift[index] + (drift[index + 1] - drift[index]) * fraction
                    }
                    values[i] *= pow(10, db / 20)
                }
                return values
            }
        }
    }()

    func litFraction(_ frames: [[Float]]) -> Float {
        Float(frames.filter { ($0.max() ?? 0) > 0.05 }.count) / Float(frames.count)
    }

    // Two seconds establish the floor, then ten seconds cover five full swells.
    // Profiles: steady, +/-3 dB and +/-1.5 dB at 0.5 Hz, random +/-3 dB drift.
    func checkSwellingRoomNoise(hop: Int, configuration: Int, profile: Int) {
        let bed = configuration / 3 * 4 + profile
        let level = [Float(-45), -50, -55][configuration % 3]
        let samples = scaled(Self.swellingBeds[bed], by: pow(10, (level + 55) / 20))
        let analyzer = SpectrumAnalyzer()
        _ = outputs(Array(samples.prefix(32_000)), analyzer: analyzer, hop: hop)
        #expect(analyzer.displayGainState.floor != nil)
        let frames = outputs(Array(samples.suffix(160_000)), analyzer: analyzer, hop: hop)
        let lit = litFraction(frames), maximum = frames.flatMap { $0 }.max() ?? 0
        print("Spectrum swell hop=\(hop) pink=\(bed >= 4) profile=\(bed % 4) dB=\(level): lit=\(lit) max=\(maximum)")
        #expect(lit <= 0.02 && maximum <= 0.10)
    }
}

// Each group runs serially so parameter sweeps have bounded individual timings.
// Independent groups can run together without flooding the test executor.
@Suite(.serialized) final class SpectrumAnalyzerSteadyAndSwellTests: SpectrumAnalyzerFixtures {

    @Test(arguments: [160, 341, 1600], [false, true])
    func steadyRoom45Noise(hop: Int, pink: Bool) {
        checkSwellingRoomNoise(hop: hop, configuration: (pink ? 3 : 0) + 0, profile: 0)
    }

    @Test(arguments: [160, 341, 1600], [false, true])
    func steadyRoom50Noise(hop: Int, pink: Bool) {
        checkSwellingRoomNoise(hop: hop, configuration: (pink ? 3 : 0) + 1, profile: 0)
    }

    @Test(arguments: [160, 341, 1600], [false, true])
    func steadyRoom55Noise(hop: Int, pink: Bool) {
        checkSwellingRoomNoise(hop: hop, configuration: (pink ? 3 : 0) + 2, profile: 0)
    }

    @Test(arguments: [160, 341, 1600], [false, true])
    func threeDBRoom45Noise(hop: Int, pink: Bool) {
        checkSwellingRoomNoise(hop: hop, configuration: (pink ? 3 : 0) + 0, profile: 1)
    }

    @Test(arguments: [160, 341, 1600], [false, true])
    func threeDBRoom50Noise(hop: Int, pink: Bool) {
        checkSwellingRoomNoise(hop: hop, configuration: (pink ? 3 : 0) + 1, profile: 1)
    }

    @Test(arguments: [160, 341, 1600], [false, true])
    func threeDBRoom55Noise(hop: Int, pink: Bool) {
        checkSwellingRoomNoise(hop: hop, configuration: (pink ? 3 : 0) + 2, profile: 1)
    }
}

@Suite(.serialized) final class SpectrumAnalyzerDriftAndPauseTests: SpectrumAnalyzerFixtures {

    @Test(arguments: [160, 341, 1600], [false, true])
    func onePointFiveDBRoom45Noise(hop: Int, pink: Bool) {
        checkSwellingRoomNoise(hop: hop, configuration: (pink ? 3 : 0) + 0, profile: 2)
    }

    @Test(arguments: [160, 341, 1600], [false, true])
    func onePointFiveDBRoom50Noise(hop: Int, pink: Bool) {
        checkSwellingRoomNoise(hop: hop, configuration: (pink ? 3 : 0) + 1, profile: 2)
    }

    @Test(arguments: [160, 341, 1600], [false, true])
    func onePointFiveDBRoom55Noise(hop: Int, pink: Bool) {
        checkSwellingRoomNoise(hop: hop, configuration: (pink ? 3 : 0) + 2, profile: 2)
    }

    @Test(arguments: [160, 341, 1600], [false, true])
    func randomDriftRoom45Noise(hop: Int, pink: Bool) {
        checkSwellingRoomNoise(hop: hop, configuration: (pink ? 3 : 0) + 0, profile: 3)
    }

    @Test(arguments: [160, 341, 1600], [false, true])
    func randomDriftRoom50Noise(hop: Int, pink: Bool) {
        checkSwellingRoomNoise(hop: hop, configuration: (pink ? 3 : 0) + 1, profile: 3)
    }

    @Test(arguments: [160, 341, 1600], [false, true])
    func randomDriftRoom55Noise(hop: Int, pink: Bool) {
        checkSwellingRoomNoise(hop: hop, configuration: (pink ? 3 : 0) + 2, profile: 3)
    }

    @Test(arguments: [160, 341, 1600], [false, true])
    func swellingMidSentencePause(hop: Int, pink: Bool) throws {
        let clip = try speech(levelDB: -35).samples
        var mixed = scaled(Self.swellingBeds[pink ? 5 : 1], by: pow(10, 5 / 20))
        for i in 0..<32_000 {
            mixed[32_000 + i] += clip[16_000 + i]
            mixed[112_000 + i] += clip[16_000 + i]
        }
        let run = trace(Array(mixed.prefix(144_000)), analyzer: SpectrumAnalyzer(), hop: hop)
        // Exclude only the 512-sample FFT overlap with the preceding sentence.
        let pause = run.ends.indices.filter { run.ends[$0] > 64_000 + 512 && run.ends[$0] <= 112_000 }.map { run.frames[$0] }
        let lit = litFraction(pause)
        print("Spectrum 3s swelling pause hop=\(hop) pink=\(pink): lit=\(lit)")
        #expect(lit <= 0.05)
    }
}

@Suite(.serialized) final class SpectrumAnalyzerStartupTests: SpectrumAnalyzerFixtures {

    @Test(arguments: [160, 320, 341, 1600], [false, true])
    func probeContinuousBeds(hop: Int, pink: Bool) throws {
        let clip = try speech(levelDB: -35).samples
        let lead = 16_000
        let total = lead + clip.count + 48_000
        var mixed = probeNoise(levelDB: -50, count: total, pink: pink)
        for i in clip.indices { mixed[lead + i] += clip[i] }
        let run = trace(mixed, analyzer: SpectrumAnalyzer(), hop: hop)
        let baseline = trace(mixed, analyzer: SpectrumAnalyzer(displayGainEnabled: false), hop: hop)
        let speechIndexes = run.ends.indices.filter {
            let end = run.ends[$0] - lead
            return end > 16_000 && end <= clip.count && rms(clip[max(0, end - 512)..<end]) >= pow(10, -55 / 20)
        }
        let gained = mean(speechIndexes.map { run.frames[$0] })
        let ungained = mean(speechIndexes.map { baseline.frames[$0] })
        let pause = windowMean(run, from: lead + clip.count + 25_600, to: total)
        print("Spectrum probe bed hop=\(hop) pink=\(pink): speech=\(gained), disabled=\(ungained), settled pause=\(pause)")
        #expect(gained >= ungained)
        #expect(gained > ungained)
        #expect(pause <= 0.05)
        #expect(zip(run.frames, baseline.frames).allSatisfy { actual, original in
            zip(actual, original).allSatisfy { $0.isFinite && $0 >= $1 && $0 <= 1 }
        })
        #expect(run.gains.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 18 })
    }

    @Test(arguments: [64, 160, 341, 1600], [false, true])
    func startupRoomNoise(hop: Int, abrupt: Bool) throws {
        let clip = Array(try speech(levelDB: -35).samples.prefix(48_000))
        let pink = (!abrupt && hop != 160) || hop == 341
        let level: Float = abrupt ? -45 : -50
        var pre: [[Float]] = [], gaps: [[Float]] = []
        var voiced: [[Float]] = [], disabled: [[Float]] = []
        let phase = hop / 3
        let zeros = 3200 + phase
        let room = 8000
        let count = room + clip.count
        var bed = probeNoise(levelDB: level, count: count, pink: pink, seed: UInt64(phase + 1))
        if !abrupt {
            for i in 0..<1600 { bed[i] *= pow(10, (-100 + Float(i) / 16) / 20) }
            for i in 0..<1600 where abs(bed[i]) < AudioGatingMetrics.silenceThreshold { bed[i] = 0 }
        }
        for i in clip.indices { bed[room + i] += clip[i] }
        var stream = [Float](repeating: 0, count: zeros)
        if !abrupt { stream[zeros / 3] = 1 / 32_767; stream[zeros / 2] = -1 / 32_767 }
        stream += bed
        let analyzer = SpectrumAnalyzer()
        // Exercise the same startup rule on a warm dictation reset too.
        if abrupt {
            _ = outputs(Array(clip.prefix(8000)), analyzer: analyzer, hop: hop)
            analyzer.resetDisplayGain()
        }
        let run = trace(stream, analyzer: analyzer, hop: hop)
        let baseline = trace(stream, analyzer: SpectrumAnalyzer(displayGainEnabled: false), hop: hop)
        for i in run.ends.indices {
            let end = run.ends[i] - zeros
            if end > 0 && end <= room { pre.append(run.frames[i]) }
            if end > room + 512 && end <= room + clip.count {
                let clean = rms(clip[end - room - 512..<end - room])
                if clean < pow(10, -70 / 20) { gaps.append(run.frames[i]) }
                if clean >= pow(10, -55 / 20) {
                    voiced.append(run.frames[i]); disabled.append(baseline.frames[i])
                }
            }
        }
        func lit(_ frames: [[Float]]) -> Float {
            Float(frames.filter { ($0.max() ?? 0) > 0.05 }.count) / Float(frames.count)
        }
        let speechMean = mean(voiced), baselineMean = mean(disabled)
        print("Spectrum startup hop=\(hop) abrupt=\(abrupt) pink=\(pink) room=\(level): pre lit=\(lit(pre)) mean=\(mean(pre)), gaps lit=\(lit(gaps)), speech=\(speechMean) disabled=\(baselineMean) ratio=\(speechMean / baselineMean)")
        #expect(!pre.isEmpty && !gaps.isEmpty && !voiced.isEmpty)
        #expect(lit(pre) <= 0.05 && mean(pre) <= 0.02)
        #expect(lit(gaps) <= 0.05)
        #expect(speechMean >= (level == -45 ? 1 : 1.5) * baselineMean)
    }

    @Test(arguments: [32, 64, 160, 341, 1600])
    func noFloorMeansExactlyNoGain(hop: Int) {
        let analyzer = SpectrumAnalyzer()
        let baseline = SpectrumAnalyzer(displayGainEnabled: false)
        var stream = [Float](repeating: 0, count: 3200)
        stream[1000] = 1 / 32_767
        stream += probeNoise(levelDB: -50, count: 12_800)
        var firstFloor: Int?
        var noGainWithoutFloor = true, noPrematureFloor = true
        stream.withUnsafeBufferPointer { p in
            for start in stride(from: 0, through: stream.count - hop, by: hop) {
                let frame = UnsafeBufferPointer(rebasing: p[start..<start + hop])
                let actual = Array(analyzer.process(frame))
                let original = Array(baseline.process(frame))
                if analyzer.displayGainState.floor == nil {
                    noGainWithoutFloor = noGainWithoutFloor && analyzer.displayGainState.gain == 0 && actual == original
                } else if firstFloor == nil { firstFloor = start + hop }
                if start + hop < 3200 + 5600 { noPrematureFloor = noPrematureFloor && analyzer.displayGainState.floor == nil }
            }
        }
        #expect(noGainWithoutFloor && noPrematureFloor)
        #expect(firstFloor != nil && firstFloor! >= 8800 && firstFloor! <= 8800 + hop + 32)
        print("Spectrum startup floor hop=\(hop): first established at sample \(firstFloor ?? -1)")
    }

    @Test(arguments: [32, 64])
    func smallestHopRetainsItsTimeWindow(hop: Int) {
        let analyzer = SpectrumAnalyzer()
        _ = outputs(probeNoise(levelDB: -50, count: 48_000), analyzer: analyzer, hop: hop)
        let expectedSeconds = hop == 64 ? 1.5 : 0.75
        #expect(abs(analyzer.displayGainState.floorSeconds - expectedSeconds) < 1e-6)
        print("Spectrum floor window hop=\(hop): \(analyzer.displayGainState.floorSeconds)s")
    }

    @Test(arguments: [2000.0, 16_000, 48_000])
    func startupEligibilityUsesRealTimeAndWholeWindow(sampleRate: Double) {
        let hop = 64
        let analyzer = SpectrumAnalyzer(sampleRate: sampleRate, highHz: min(4000, sampleRate * 0.45))
        let stream = probeNoise(levelDB: -50, count: Int(sampleRate * 0.8))
        var established: Int?
        stream.withUnsafeBufferPointer { p in
            for start in stride(from: 0, through: stream.count - hop, by: hop) {
                _ = analyzer.process(UnsafeBufferPointer(rebasing: p[start..<start + hop]))
                if analyzer.displayGainState.floor != nil && established == nil { established = start + hop }
                if established == nil { #expect(analyzer.displayGainState.gain == 0) }
            }
        }
        let earliest = max(0.15, Double(SpectrumAnalyzer.fftSize) / sampleRate) + 0.2
        #expect(established != nil)
        if let established {
            let seconds = Double(established) / sampleRate
            #expect(seconds + 1e-9 >= earliest && seconds <= earliest + Double(hop) / sampleRate + 0.001)
            print("Spectrum startup real time rate=\(sampleRate): floor at \(seconds)s, earliest=\(earliest)s")
        }
    }

    @Test(arguments: [64, 160, 341, 1600], [false, true])
    func silenceRunRestartsFloorEligibility(hop: Int, blips: Bool) throws {
        let analyzer = SpectrumAnalyzer()
        _ = outputs(try speech(levelDB: -35).samples, analyzer: analyzer, hop: hop)
        var mute = [Float](repeating: 0, count: hop * Int(ceil(2 * 16_000 / Double(hop))))
        if blips {
            for i in stride(from: 17, to: mute.count, by: 701) { mute[i] = i.isMultiple(of: 2) ? 1 / 32_767 : -1 / 32_767 }
        }
        _ = outputs(mute, analyzer: analyzer, hop: hop)
        #expect(analyzer.displayGainState.floor == nil && analyzer.displayGainState.gain == 0)
        let bed = probeNoise(levelDB: -45, count: hop * Int(ceil(0.5 * 16_000 / Double(hop))))
        let baseline = SpectrumAnalyzer(displayGainEnabled: false)
        bed.withUnsafeBufferPointer { p in
            for start in stride(from: 0, through: bed.count - hop, by: hop) {
                let frame = UnsafeBufferPointer(rebasing: p[start..<start + hop])
                let actual = Array(analyzer.process(frame)), original = Array(baseline.process(frame))
                if start + hop < 5600 {
                    #expect(analyzer.displayGainState.floor == nil && analyzer.displayGainState.gain == 0)
                    // Both retain different FFT histories only in the first 512 samples.
                    if start + hop >= 512 { #expect(actual == original) }
                }
            }
        }
        #expect(analyzer.displayGainState.floor != nil)
    }
}

@Suite(.serialized) final class SpectrumAnalyzerSpeechTests: SpectrumAnalyzerFixtures {

    @Test func silenceReadsFlatZero() {
        let a = SpectrumAnalyzer()
        let z = [Float](repeating: 0, count: 1024)
        z.withUnsafeBufferPointer { _ = a.process($0) }
        #expect(a.levels.count == SpectrumBands.count)
        #expect(a.levels.allSatisfy { $0 == 0 })
    }

    @Test func toneLightsItsOwnBand() {
        let a = SpectrumAnalyzer()
        let s = sine(1000, amp: 0.1)
        s.withUnsafeBufferPointer { _ = a.process($0) }
        let lv = a.levels
        let peak = lv.indices.max { lv[$0] < lv[$1] }!
        let centres = (0..<lv.count).map { a.centreFrequency(band: $0) }
        let expected = centres.indices.min { abs(centres[$0] - 1000) < abs(centres[$1] - 1000) }!
        #expect(peak == expected)
        #expect(lv[peak] > 0.5)
        #expect(lv[0] < 0.2 && lv[lv.count - 1] < 0.2)
    }

    // 20 ms RMS windows also define speech frames (within 20 dB of the clip's p95).
    @Test(arguments: [160, 320, 341, 1600], ["zeros", "tiny", "coldZeros", "nan"])
    func probeSilenceThenNoise(hop: Int, variant: String) throws {
        let analyzer = SpectrumAnalyzer()
        if variant != "coldZeros" { _ = outputs(try speech(levelDB: -35).samples, analyzer: analyzer, hop: hop) }
        if variant == "tiny" {
            _ = outputs(probeNoise(levelDB: -140, count: 3200, seed: 7), analyzer: analyzer, hop: hop)
        } else if variant != "nan" {
            let zeros = outputs([Float](repeating: 0, count: 3200), analyzer: analyzer, hop: hop)
            #expect(zeros.allSatisfy { $0.allSatisfy { $0 == 0 } })
        }
        // One stream spans both noise levels, including the NaN frame.
        var stream = probeNoise(levelDB: -50, count: 96_000, seed: 11)
        for i in 48_000..<stream.count { stream[i] *= pow(10, 5 / 20) }
        if variant == "nan" { stream[17] = .nan }
        let run = trace(stream, analyzer: analyzer, hop: hop)
        let quiet = windowMean(run, from: 25_600, to: 48_000)
        let louder = windowMean(run, from: 48_000 + 25_600, to: stream.count)
        print("Spectrum probe silence hop=\(hop) \(variant): settled -50=\(quiet), -45=\(louder)")
        #expect(quiet <= 0.05 && louder <= 0.05)
        #expect(run.frames.allSatisfy { $0.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 } })
    }

    // Measured engine startup: zeros containing stray +/-1 int16 LSBs, followed
    // by a 100 ms fade at 1 dB/ms, quantized below half an LSB. One seeded noise
    // stream (including pink filter state) continues through room, clip and tail.
    @Test func displayGainMakesQuietSpeechLevelIndependent() throws {
        let quiet = try speech(levelDB: -35)
        let normal = try speech(levelDB: -20)
        let quietMean = mean(speechFrames(outputs(quiet.samples, analyzer: SpectrumAnalyzer()), samples: quiet.samples, threshold: quiet.threshold))
        let normalMean = mean(speechFrames(outputs(normal.samples, analyzer: SpectrumAnalyzer()), samples: normal.samples, threshold: normal.threshold))
        let normalBaseline = mean(speechFrames(outputs(normal.samples, analyzer: SpectrumAnalyzer(displayGainEnabled: false)), samples: normal.samples, threshold: normal.threshold))
        let baseline = mean(speechFrames(outputs(quiet.samples, analyzer: SpectrumAnalyzer(displayGainEnabled: false)), samples: quiet.samples, threshold: quiet.threshold))
        print("Spectrum means: quiet=\(quietMean), normal=\(normalMean), quiet disabled=\(baseline), normal disabled=\(normalBaseline)")
        #expect(abs(normalMean - normalBaseline) <= 0.02, "normal=\(normalMean), disabled=\(normalBaseline)")
        #expect(abs(quietMean - normalMean) <= 0.15, "quiet=\(quietMean), normal=\(normalMean)")
        #expect(quietMean >= 3 * baseline, "quiet=\(quietMean), disabled=\(baseline)")
    }

    @Test func speechOverContinuousNoise() throws {
        let quiet = try speech(levelDB: -35)
        let bed = noise(levelDB: -50, seconds: (quiet.samples.count + 15_999) / 16_000 + 3)
        var mixed = bed
        for i in quiet.samples.indices { mixed[i] += quiet.samples[i] }
        let frames = outputs(mixed, analyzer: SpectrumAnalyzer())
        let disabled = outputs(mixed, analyzer: SpectrumAnalyzer(displayGainEnabled: false))
        let speechMean = mean(speechFrames(Array(frames.prefix(quiet.samples.count / 320)), samples: quiet.samples, threshold: quiet.threshold))
        let baseline = mean(speechFrames(Array(disabled.prefix(quiet.samples.count / 320)), samples: quiet.samples, threshold: quiet.threshold))
        let pauseMean = mean(Array(frames.suffix(150)))
        let gapFrames = frames.enumerated().compactMap { index, frame -> [Float]? in
            let start = index * 320
            guard start >= 16_000, start + 320 <= quiet.samples.count,
                  rms(quiet.samples[start..<start + 320]) < quiet.threshold else { return nil }
            return frame
        }
        let gapMean = mean(gapFrames)
        print("Spectrum continuous -50 bed: speech=\(speechMean), disabled=\(baseline), ratio=\(speechMean / baseline), post-speech pause=\(pauseMean), clip gaps=\(gapMean)")
        #expect(pauseMean <= 0.05)
        #expect(gapMean <= 0.05)
        #expect(speechMean >= 1.5 * baseline)
    }

    @Test func zeroFramesThenNoise() throws {
        let analyzer = SpectrumAnalyzer()
        _ = outputs(try speech(levelDB: -35).samples, analyzer: analyzer)
        let zeros = outputs([Float](repeating: 0, count: 3200), analyzer: analyzer)
        #expect(zeros.allSatisfy { $0.allSatisfy { $0 == 0 } })
        let pauseMean = mean(outputs(noise(levelDB: -50, seconds: 3), analyzer: analyzer))
        print("Spectrum 200 ms zeros then -50 noise: pause=\(pauseMean)")
        #expect(pauseMean <= 0.05)
    }

    @Test(arguments: [160, 320, 341, 1600]) func nonFiniteFrameMidSpeech(hop: Int) throws {
        let analyzer = SpectrumAnalyzer()
        let samples = noise(levelDB: -65, seconds: 1) + (try speech(levelDB: -35).samples)
        let boundary = (48_000 / hop) * hop
        _ = outputs(Array(samples.prefix(boundary)), analyzer: analyzer, hop: hop)
        let control = SpectrumAnalyzer()
        _ = outputs(Array(samples.prefix(boundary)), analyzer: control, hop: hop)
        let before = analyzer.displayGainState
        #expect(before.peak != nil && before.floor != nil && before.gain > 0)
        var invalid = Array(samples[boundary..<boundary + hop])
        invalid[hop - 17] = .nan
        let bad = invalid.withUnsafeBufferPointer { Array(analyzer.process($0)) }
        let after = analyzer.displayGainState
        #expect(bad.allSatisfy { $0 == 0 })
        #expect(after.peak?.isFinite == true && after.floor?.isFinite == true && after.gain.isFinite)
        #expect(after.peak == before.peak && after.floor == before.floor && after.gain == before.gain)
        // Retry the rejected frame and continue through 60 ms of actual speech.
        let recovery = trace(Array(samples[boundary..<boundary + max(960, hop)]), analyzer: analyzer, hop: hop)
        let reference = trace(Array(samples[boundary..<boundary + max(960, hop)]), analyzer: control, hop: hop)
        #expect(recovery.frames == reference.frames)
        #expect(recovery.gains == reference.gains)
        #expect(recovery.frames.allSatisfy { $0.allSatisfy { $0.isFinite } })
        #expect(recovery.gains.allSatisfy { abs($0 - before.gain) <= 0.5 })
        print("Spectrum NaN mid-speech hop=\(hop): gain before=\(before.gain), after=\(after.gain), recovery=\(recovery.gains)")
    }

    @Test(arguments: [160, 320, 341, 1600], [false, true]) func roomGetsLouder(hop: Int, warm: Bool) throws {
        let analyzer = SpectrumAnalyzer()
        if warm { _ = outputs(try speech(levelDB: -35).samples, analyzer: analyzer, hop: hop) }
        // One continuous random stream, scaled at the room-change boundary.
        var stream = noise(levelDB: -70, seconds: 6)
        for i in 32_000..<stream.count { stream[i] *= pow(10, 25 / 20) }
        let run = trace(stream, analyzer: analyzer, hop: hop)
        let settledMean = windowMean(run, from: 32_000 + 25_600, to: 32_000 + 57_600)
        print("Spectrum room -70 to -45 hop=\(hop) warm=\(warm): +1.6...3.6s=\(settledMean)")
        #expect(settledMean <= 0.05)
    }

    @Test(arguments: [(160, 0), (320, 950), (341, 1000), (1600, 1234), (160, 2900)])
    func clicksDoNotChangeSpeechGain(configuration: (Int, Int)) throws {
        let (hop, phase) = configuration
        let analyzer = SpectrumAnalyzer()
        let disabled = SpectrumAnalyzer(displayGainEnabled: false)
        let warmup = noise(levelDB: -65, seconds: 1) + (try speech(levelDB: -35).samples)
        _ = outputs(warmup, analyzer: analyzer, hop: hop)
        _ = outputs(warmup, analyzer: disabled, hop: hop)
        let gainBefore = analyzer.trackedGainDB
        #expect(gainBefore > 0)
        var pause = noise(levelDB: -60, seconds: 3)
        // Ten ms at -25 dBFS RMS every 300 ms, offset from the 20 ms hop.
        let click = sine(1000, amp: pow(10, -25 / 20) * Float(2).squareRoot(), count: 160)
        let burst = noise(levelDB: -25, seconds: 3)
        for (index, start) in stride(from: phase, to: pause.count - 160, by: 4800).enumerated() {
            for i in click.indices { pause[start + i] += index.isMultiple(of: 2) ? click[i] : burst[start + i] }
        }
        let pauseMean = mean(outputs(pause, analyzer: analyzer, hop: hop))
        let baseline = mean(outputs(pause, analyzer: disabled, hop: hop))
        let gainAfter = analyzer.trackedGainDB
        print("Spectrum clicks (\(hop) sample hop, phase \(phase)): pause=\(pauseMean), disabled=\(baseline), gain before=\(gainBefore), after=\(gainAfter)")
        #expect(pauseMean <= baseline + 0.05)
        #expect(abs(gainAfter - gainBefore) <= 1)
    }

    @Test(arguments: [160, 320, 341, 1600], [Float(-25), -10])
    func clickDuringSpeech(hop: Int, clickDB: Float) throws {
        let clean = try speech(levelDB: -35).samples
        var clicked = clean
        let at = 32_000 + 1250 // Inside the retained FFT window even for a 1600-sample hop.
        let burst = noise(levelDB: clickDB, seconds: 1)
        for i in 0..<160 { clicked[at + i] += burst[i] }
        let run = trace(clicked, analyzer: SpectrumAnalyzer(), hop: hop)
        let control = trace(clean, analyzer: SpectrumAnalyzer(), hop: hop)
        let beforeIndex = try #require(run.ends.lastIndex { $0 <= at })
        let afterIndex = try #require(run.ends.firstIndex { $0 >= at + 512 })
        let gainBefore = run.gains[beforeIndex]
        let gainAfter = run.gains[afterIndex]
        let indexes = run.ends.indices.filter {
            let end = run.ends[$0]
            return end > at + 512 && end <= at + 512 + 16_000 && rms(clean[max(0, end - 512)..<end]) >= pow(10, -55 / 20)
        }
        let postMean = mean(indexes.map { run.frames[$0] })
        let controlMean = mean(indexes.map { control.frames[$0] })
        print("Spectrum mid-speech click hop=\(hop) dB=\(clickDB): gain before=\(gainBefore), after=\(gainAfter), next 1s=\(postMean), control=\(controlMean)")
        #expect(abs(gainAfter - gainBefore) <= 1)
        #expect(abs(postMean - controlMean) <= 0.02)
        #expect(run.gains.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 18 })
    }

    @Test(arguments: [160, 320, 341, 1600]) func qualificationNeedsDurationAndFrames(hop: Int) {
        let analyzer = SpectrumAnalyzer()
        _ = outputs(noise(levelDB: -70, seconds: 1), analyzer: analyzer, hop: hop)
        let required = max(hop <= 320 ? 3 : 1, Int(ceil(0.06 * 16_000 / Double(hop))))
        let loud = sine(700, amp: 0.1, count: required * hop)
        loud.withUnsafeBufferPointer { p in
            for frame in 0..<required {
                _ = analyzer.process(UnsafeBufferPointer(rebasing: p[frame * hop..<(frame + 1) * hop]))
                if frame + 1 < required { #expect(analyzer.displayGainState.peak == nil) }
            }
        }
        #expect(analyzer.displayGainState.peak?.isFinite == true)
        print("Spectrum qualification hop=\(hop): adopts after \(required) frames")
    }

    @Test(arguments: [160, 320, 341, 1600], [false, true]) func sustainedLoudAttack(hop: Int, afterPause: Bool) throws {
        let analyzer = SpectrumAnalyzer()
        _ = outputs(noise(levelDB: -65, seconds: 1) + (try speech(levelDB: -35).samples), analyzer: analyzer, hop: hop)
        if afterPause { _ = outputs(noise(levelDB: -60, seconds: 1), analyzer: analyzer, hop: hop) }
        let before = analyzer.trackedGainDB
        let loud = sine(700, amp: pow(10, -12 / 20) * Float(2).squareRoot(), count: 8000)
        let run = trace(loud, analyzer: analyzer, hop: hop)
        let deadline = max(1600, 3 * hop)
        let index = try #require(run.ends.lastIndex { $0 <= deadline })
        print("Spectrum sustained loud hop=\(hop) afterPause=\(afterPause): before=\(before), gain by \(Float(deadline) / 16_000)s=\(run.gains[index])")
        #expect(before > 0)
        #expect(run.gains[index] <= 0.5)
    }

    @Test(arguments: [(160, Float(-15), Float(-35)), (320, -35, -20), (341, -20, -35), (1600, -35, -35)])
    func perDictationReset(configuration: (Int, Float, Float)) throws {
        let (hop, previousDB, nextDB) = configuration
        do {
            let analyzer = SpectrumAnalyzer()
            _ = outputs(try speech(levelDB: previousDB).samples, analyzer: analyzer, hop: hop)
            if previousDB != -15 {
                let silence = outputs([Float](repeating: 0, count: 2 * 16_000), analyzer: analyzer, hop: hop)
                #expect(silence.allSatisfy { $0.allSatisfy { $0 == 0 } })
            }
            analyzer.resetDisplayGain()
            let next = try speech(levelDB: nextDB).samples
            let reset = outputs(next, analyzer: analyzer, hop: hop)
            let cold = outputs(next, analyzer: SpectrumAnalyzer(), hop: hop)
            print("Spectrum reset hop=\(hop) \(previousDB) -> \(nextDB): mean=\(mean(reset)), cold=\(mean(cold))")
            #expect(abs(mean(reset) - mean(cold)) <= 0.02)
            #expect(reset == cold)
        }
    }

    @Test func displayGainLeavesStandaloneLoudSpeechUnchanged() throws {
        let loud = try speech(levelDB: -15).samples
        let actual = outputs(loud, analyzer: SpectrumAnalyzer())
        let original = outputs(loud, analyzer: SpectrumAnalyzer(displayGainEnabled: false))
        #expect(actual == original)
    }

    @Test(arguments: [160, 341, 1600])
    func displayGainLeavesLoudSpeechUnchanged(hop: Int) throws {
        // A voiced harmonic signal with slowly varying syllable energy, at
        // -15 dBFS RMS. Prime quiet-speech gain to exercise the immediate guard
        // before the persistence-qualified tracker can catch up.
        var loud = (0..<32_000).map { i -> Float in
            let t = Double(i) / 16_000
            let voice = sin(2 * .pi * 200 * t) + 0.5 * sin(2 * .pi * 700 * t) + 0.25 * sin(2 * .pi * 1300 * t)
            return Float(voice * (1 + 0.2 * sin(2 * .pi * 3 * t)))
        }
        loud = scaled(loud, by: pow(10, -15 / 20) / rms(loud[...]))
        let analyzer = SpectrumAnalyzer(), original = SpectrumAnalyzer(displayGainEnabled: false)
        let quiet = noise(levelDB: -65, seconds: 1) + (try speech(levelDB: -35).samples)
        _ = outputs(quiet, analyzer: analyzer, hop: hop)
        _ = outputs(quiet, analyzer: original, hop: hop)
        let floorBed = probeNoise(levelDB: -65, count: 8000)
        _ = outputs(floorBed, analyzer: analyzer, hop: hop)
        _ = outputs(floorBed, analyzer: original, hop: hop)
        var quietTail = scaled(Array(loud.prefix(8000)), by: 0.1)
        let tailBed = probeNoise(levelDB: -65, count: quietTail.count)
        for i in quietTail.indices { quietTail[i] += tailBed[i] }
        _ = outputs(quietTail, analyzer: analyzer, hop: hop)
        _ = outputs(quietTail, analyzer: original, hop: hop)
        #expect(analyzer.trackedGainDB > 0)
        var mixed = probeNoise(levelDB: -50, count: loud.count)
        for i in loud.indices { mixed[i] += loud[i] }
        let frames = outputs(mixed, analyzer: analyzer, hop: hop)
        let baseline = outputs(mixed, analyzer: original, hop: hop)
        // Compare once the retained FFT window contains the loud passage alone.
        // At hop 1600 this includes the very first loud callback, before peak attack.
        let maximumDifference = frames.indices.filter { ($0 + 1) * hop >= SpectrumAnalyzer.fftSize }.flatMap { index in
            zip(frames[index], baseline[index]).map { abs($0 - $1) }
        }.max() ?? 0
        print("Spectrum loud -15 over -50 hop=\(hop): maximum difference=\(maximumDifference)")
        #expect(maximumDifference <= 0.02)
    }

    @Test(arguments: [160, 341, 1600], [Float(-55), -50, -45])
    func speechLiftByRoomLevel(hop: Int, level: Float) throws {
        let clip = try speech(levelDB: -35).samples
        var mixed = probeNoise(levelDB: level, count: 32_000 + clip.count, pink: true)
        for i in clip.indices { mixed[32_000 + i] += clip[i] }
        let run = trace(mixed, analyzer: SpectrumAnalyzer(), hop: hop)
        let baseline = trace(mixed, analyzer: SpectrumAnalyzer(displayGainEnabled: false), hop: hop)
        let indexes = run.ends.indices.filter {
            let end = run.ends[$0] - 32_000
            return end > 16_000 && end <= clip.count && rms(clip[end - 512..<end]) >= pow(10, -55 / 20)
        }
        let gained = mean(indexes.map { run.frames[$0] }), ungained = mean(indexes.map { baseline.frames[$0] })
        let required: Float = level == -55 ? 3 : level == -50 ? 1.5 : 1
        print("Spectrum lift hop=\(hop) bed=\(level): gained=\(gained) ungained=\(ungained) ratio=\(gained / ungained) required=\(required)")
        #expect(gained >= required * ungained)
    }

    @Test func displayGainStartsWithOriginalMapping() {
        let samples = sine(1000, amp: 0.01, count: 320)
        let analyzer = SpectrumAnalyzer()
        let baseline = SpectrumAnalyzer(displayGainEnabled: false)
        samples.withUnsafeBufferPointer { pointer in
            #expect(Array(analyzer.process(pointer)) == Array(baseline.process(pointer)))
        }
    }

    @Test func bandsPublishAndClear() {
        let b = SpectrumBands()
        let v: [Float] = (0..<SpectrumBands.count).map { Float($0) / 10 }
        v.withUnsafeBufferPointer { b.write($0) }
        #expect(b.read() == v)
        b.clear()
        #expect(b.read().allSatisfy { $0 == 0 })
    }
}

@Suite(.serialized) final class SpectrumAnalyzerHopParityTests: SpectrumAnalyzerFixtures {
    /// `ungainedTolerance`: −15 dBFS speech must match today's mapping (0.02). −20 dBFS is the normal level
    /// with voice processing on; its quieter syllables may get a small lift (≤ 0.08, ~2 pt on a bar), by design.
    func checkParity(_ samples: [Float], label: String, loud: Bool = false, ungainedTolerance: Float = 0.02) {
        let large = trace(samples, analyzer: SpectrumAnalyzer(), hop: 1600)
        let small = trace(samples, analyzer: SpectrumAnalyzer(), hop: 320)
        let delta = large.gains.indices.map { abs(large.gains[$0] - small.gains[$0 * 5 + 4]) }.max() ?? 0
        #expect(!large.gains.isEmpty)
        #expect(delta <= 1, "\(label): gain delta=\(delta) dB")
        print("Spectrum hop parity \(label): max gain delta=\(delta) dB")
        if loud {
            let baseline = trace(samples, analyzer: SpectrumAnalyzer(displayGainEnabled: false), hop: 1600)
            let difference = zip(large.frames, baseline.frames).flatMap { actual, original in
                zip(actual, original).map { abs($0 - $1) }
            }.max() ?? 0
            let smallDifference = large.frames.indices.flatMap { i in
                zip(small.frames[i * 5 + 4], baseline.frames[i]).map { abs($0 - $1) }
            }.max() ?? 0
            print("Spectrum hop parity \(label): hop 320 ungained difference=\(smallDifference)")
            print("Spectrum hop parity \(label): max ungained difference=\(difference)")
            #expect(difference <= ungainedTolerance, "\(label): ungained difference=\(difference)")
        }
    }

    @Test(arguments: [false, true], [1, 2, 3])
    func swellAndDrift(pink: Bool, profile: Int) {
        checkParity(Self.swellingBeds[(pink ? 4 : 0) + profile], label: "noise pink=\(pink) profile=\(profile)")
    }

    @Test(arguments: [Float(-35), -20, -15])
    func speechOverPink(level: Float) throws {
        let clip = try speech(levelDB: level).samples
        var mixed = probeNoise(levelDB: -50, count: 32_000 + clip.count, pink: true)
        for i in clip.indices { mixed[32_000 + i] += clip[i] }
        checkParity(mixed, label: "clip05 \(level) over -50 pink", loud: level >= -20,
                    ungainedTolerance: level >= -15 ? 0.02 : 0.08)
    }

    @Test(arguments: [128, 320])
    func typing(clickSamples: Int) {
        var mixed = probeNoise(levelDB: -60, count: 64_000, pink: true)
        let clicks = probeNoise(levelDB: -30, count: mixed.count)
        for start in stride(from: 16_000 + 123, to: mixed.count - clickSamples, by: 2000) {
            for i in 0..<clickSamples { mixed[start + i] += clicks[start + i] }
        }
        checkParity(mixed, label: "typing \(clickSamples / 16) ms -30 at 8/s over -60")
    }

    @Test(arguments: [false, true])
    func coldStart(fade: Bool) throws {
        let clip = try speech(levelDB: -35).samples
        var bed = probeNoise(levelDB: -50, count: 8000 + clip.count, pink: true)
        if fade {
            for i in 0..<1600 { bed[i] *= pow(10, (-100 + Float(i) / 16) / 20) }
        }
        for i in clip.indices { bed[8000 + i] += clip[i] }
        var stream = [Float](repeating: 0, count: 3200)
        stream[1000] = 1 / 32_767
        stream += bed
        checkParity(stream, label: "cold start fade=\(fade)")
    }

    @Test func recordingStartResetsDisplayGainForColdAndWarmPaths() throws {
        let source = try String(contentsOf: PreRollPrivacyTests.sources.appendingPathComponent("WisprLocalCore/Audio/AudioRecorder.swift"), encoding: .utf8)
        let start = try #require(source.range(of: "    public func start() throws {"))
        let end = try #require(source.range(of: "    private func startEngine()", range: start.upperBound..<source.endIndex))
        let body = String(source[start.upperBound..<end.lowerBound])
        let reset = try #require(body.range(of: "path.analyzer.resetDisplayGain()"))
        let begin = try #require(body.range(of: "sink.beginRecording(engineRunning: running)"))
        let coldBranch = try #require(body.range(of: "if !running {"))
        #expect(reset.lowerBound < begin.lowerBound && reset.lowerBound < coldBranch.lowerBound)
        #expect(body.components(separatedBy: "resetDisplayGain()").count == 2)
    }
}
