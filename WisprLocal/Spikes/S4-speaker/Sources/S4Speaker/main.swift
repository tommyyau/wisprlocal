// S4 spike: speaker gating feasibility with FluidAudio's WeSpeaker embedding model.
//   S4Speaker download   # ONLINE, one-time: fetch diarizer models into ./Models
//   S4Speaker run        # OFFLINE: enroll voice A, score segments of A / B / A+B mixtures
import AVFoundation
import CoreML
import FluidAudio
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let modelsDir = root.appendingPathComponent("Models", isDirectory: true)
let fx = root.appendingPathComponent("Fixtures", isDirectory: true)
let diarDir = modelsDir.appendingPathComponent(Repo.diarizer.folderName, isDirectory: true)

func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e6 }
func median(_ xs: [Double]) -> Double { let s = xs.sorted(); return s[s.count / 2] }
func f3(_ x: Float) -> String { String(format: "%.3f", x) }

func readSamples(_ name: String) throws -> [Float] {
    let file = try AVAudioFile(forReading: fx.appendingPathComponent(name), commonFormat: .pcmFormatFloat32, interleaved: false)
    let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: buf)
    return Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength)))
}
func rms(_ x: [Float]) -> Float { sqrt(x.reduce(0) { $0 + $1 * $1 } / Float(max(1, x.count))) }
func normalize(_ v: [Float]) -> [Float] { let n = sqrt(v.reduce(0) { $0 + $1 * $1 }); return n > 0 ? v.map { $0 / n } : v }
func cosine(_ a: [Float], _ b: [Float]) -> Float { zip(normalize(a), normalize(b)).reduce(0) { $0 + $1.0 * $1.1 } }

/// A + B where B's RMS is set to `db` relative to A's RMS; result rescaled to A's RMS.
func mix(_ a: [Float], _ b: [Float], db: Float) -> [Float] {
    let n = min(a.count, b.count)
    let g = rms(a) / max(rms(b), 1e-9) * pow(10, db / 20)
    var m = (0..<n).map { a[$0] + g * b[$0] }
    let k = rms(Array(a[0..<n])) / max(rms(m), 1e-9)
    m = m.map { $0 * k }
    return m
}

func windows(_ x: [Float], seconds: Double) -> [[Float]] {
    let w = Int(seconds * 16_000)
    return stride(from: 0, to: x.count - w + 1, by: w).map { Array(x[$0..<($0 + w)]) }
        .filter { rms($0) > 0.005 }  // drop near-silent windows (say pauses)
}

let mode = CommandLine.arguments.dropFirst().first ?? "run"
do {
    switch mode {
    case "download":
        _ = try await ModelHub.loadModels(.diarizer, modelNames: Array(ModelNames.Diarizer.requiredModels), directory: modelsDir)
        print("downloaded to \(diarDir.path)")

    case "run":
        ModelHub.offlineMode = true
        let t0 = now()
        let cfg = MLModelConfiguration()
        // Default mirrors DiarizerModels.defaultConfiguration() (.all). Override: S4_UNITS=cpu|ane|gpu
        switch ProcessInfo.processInfo.environment["S4_UNITS"] {
        case "cpu": cfg.computeUnits = .cpuOnly
        case "ane": cfg.computeUnits = .cpuAndNeuralEngine
        case "gpu": cfg.computeUnits = .cpuAndGPU
        default: cfg.computeUnits = .all
        }
        print("UNITS \(cfg.computeUnits.rawValue)")
        // Pure local load: no ModelHub involved at all.
        let embModel = try MLModel(contentsOf: diarDir.appendingPathComponent(ModelNames.Diarizer.embeddingFile), configuration: cfg)
        let extractor = EmbeddingExtractor(embeddingModel: embModel)
        let maskFrames = embModel.modelDescription.inputDescriptionsByName["mask"]!.multiArrayConstraint!.shape.last!.intValue
        print("EMB_LOAD_MS \(String(format: "%.1f", now() - t0)) mask_frames=\(maskFrames) inputs=\(embModel.modelDescription.inputDescriptionsByName.mapValues { $0.multiArrayConstraint?.shape ?? [] })")
        let ones = [[Float](repeating: 1, count: maskFrames)]
        var lat: [Double] = []
        func embed(_ seg: [Float]) throws -> [Float] {
            let t = now(); let e = try autoreleasepool { try extractor.getEmbeddings(audio: seg, masks: ones)[0] }; lat.append(now() - t); return e
        }

        let enrollAudio = try readSamples("A_enroll.wav")
        let aTest = try readSamples("A_test.wav")
        let aNews = try readSamples("A_newstext.wav")
        var streams: [(String, [Float])] = [("A_alone(test text)", aTest), ("A_alone(news text)", aNews)]
        for v in ["Samantha", "Karen", "Moira", "Fred"] { streams.append(("B_alone \(v)", try readSamples("B_\(v).wav"))) }
        for v in ["Samantha", "Fred"] {
            let b = try readSamples("B_\(v).wav")
            for db: Float in [-12, -6, 0] { streams.append(("MIX A+\(v) @\(Int(db))dB", mix(aTest, b, db: db))) }
        }

        for L in [1.5, 3.0, 5.0] {
            let enrollEmb = normalize(try windows(enrollAudio, seconds: L).map { normalize(try embed($0)) }
                .reduce([Float](repeating: 0, count: 256)) { acc, e in zip(acc, e).map { $0 + $1 } })
            print("\n=== window \(L)s (enrollment = mean of \(windows(enrollAudio, seconds: L).count) x \(L)s windows of Daniel, 31 s) ===")
            print("stream | n | mean | min | max")
            var aMin: Float = 1, bMax: Float = -1
            for (name, x) in streams {
                let sims = try windows(x, seconds: L).map { cosine(try embed($0), enrollEmb) }
                let mean = sims.reduce(0, +) / Float(sims.count)
                print("\(name) | \(sims.count) | \(f3(mean)) | \(f3(sims.min()!)) | \(f3(sims.max()!))")
                if name.hasPrefix("A_alone") { aMin = min(aMin, sims.min()!) }
                if name.hasPrefix("B_alone") { bMax = max(bMax, sims.max()!) }
            }
            print("GAP L=\(L): min(A_alone)=\(f3(aMin)) max(B_alone)=\(f3(bMax)) margin=\(f3(aMin - bMax)) -> threshold \(aMin > bMax ? "CLEAN at \(f3((aMin + bMax) / 2))" : "OVERLAP")")
        }
        let warm = Array(lat.dropFirst(3))
        print("\nEMB_LATENCY calls=\(lat.count) first_ms=\(String(format: "%.1f", lat[0])) median_ms=\(String(format: "%.2f", median(warm))) p95_ms=\(String(format: "%.2f", warm.sorted()[Int(Double(warm.count) * 0.95)]))")

    default: print("unknown mode")
    }
} catch {
    print("ERROR: \(error)"); exit(1)
}
