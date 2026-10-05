// S1 spike: Parakeet TDT 0.6B v2 offline via FluidAudio 0.17.5.
//
// Usage (run from the spike dir):
//   S1Parakeet download          # ONLINE, one-time: fetch models into ./Models
//   S1Parakeet loadonly          # OFFLINE: cold-load models only (for RSS baseline)
//   S1Parakeet bench             # OFFLINE: load + transcribe fixtures (first + median of 5)
//   S1Parakeet vocab             # OFFLINE: CTC custom-vocabulary rescoring on fixtures
//   S1Parakeet vad               # OFFLINE: Silero VAD on padded clip
import AVFoundation
import CoreML
import FluidAudio
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let modelsDir = root.appendingPathComponent("Models", isDirectory: true)
let fixtures = root.appendingPathComponent("Fixtures", isDirectory: true)
let asrDir = modelsDir.appendingPathComponent(Repo.parakeetV2.folderName, isDirectory: true)
let vadDir = modelsDir.appendingPathComponent(Repo.vad.folderName, isDirectory: true)
let ctcDir = modelsDir.appendingPathComponent(Repo.parakeetCtc110m.folderName, isDirectory: true)

func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e6 }  // ms
func median(_ xs: [Double]) -> Double {
    let s = xs.sorted(); return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
}
func f1(_ x: Double) -> String { String(format: "%.1f", x) }

func readSamples(_ url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
    precondition(file.processingFormat.sampleRate == 16_000 && file.processingFormat.channelCount == 1)
    let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: buf)
    return Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength)))
}

func loadAsr() async throws -> (AsrManager, Double) {
    let t0 = now()
    // AsrModels.load(from:) -> ModelHub.loadModels(...) per bundle. With every file present it
    // never touches the network; with offlineMode=true a missing/corrupt file throws instead of
    // deleting the cache and re-downloading.
    let models = try await AsrModels.load(from: asrDir, version: .v2)
    let asr = AsrManager(config: .default)
    try await asr.loadModels(models)
    return (asr, now() - t0)
}

func transcribe(_ asr: AsrManager, _ samples: [Float]) async throws -> ASRResult {
    var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
    return try await asr.transcribe(samples, decoderState: &state)
}

let clips = ["clip05", "clip30", "clip60"]

let mode = CommandLine.arguments.dropFirst().first ?? "bench"
do {
    switch mode {
    case "download":
        ModelHub.offlineMode = false
        try await AsrModels.download(to: asrDir, version: .v2)
        _ = try await ModelHub.loadModels(.vad, modelNames: [ModelNames.VAD.sileroVadFile], directory: modelsDir)
        try await CtcModels.download(to: ctcDir, variant: .ctc110m)
        print("downloaded to \(modelsDir.path)")

    case "loadonly":
        ModelHub.offlineMode = true
        let (_, ms) = try await loadAsr()
        print("LOAD_MS \(f1(ms))")

    case "bench":
        ModelHub.offlineMode = true
        let (asr, loadMs) = try await loadAsr()
        print("LOAD_MS \(f1(loadMs))")
        for c in clips {
            let s = try readSamples(fixtures.appendingPathComponent("\(c).wav"))
            let dur = Double(s.count) / 16_000
            let t0 = now(); let first = try await transcribe(asr, s); let firstMs = now() - t0
            var times: [Double] = []
            var text = first.text
            for _ in 0..<5 {
                let t = now(); let r = try await transcribe(asr, s); times.append(now() - t); text = r.text
            }
            let med = median(times)
            print("CLIP \(c) dur_s=\(String(format: "%.2f", dur)) first_ms=\(f1(firstMs)) median5_ms=\(f1(med)) min_ms=\(f1(times.min()!)) max_ms=\(f1(times.max()!)) rtfx=\(f1(dur * 1000 / med))")
            print("TEXT \(c): \(text)")
        }

    case "vocab":
        ModelHub.offlineMode = true
        let (asr, _) = try await loadAsr()
        let t0 = now()
        // CtcModels.load(from:) -> ModelHub.loadModels; tokenizer read from the SAME local dir.
        let ctc = try await CtcModels.load(from: ctcDir, variant: .ctc110m)
        let tok = try await CtcTokenizer.load(from: ctcDir)
        let words: [(String, [String]?)] = [
            ("Wispr Flow", ["Whisper Flow", "Wisper Flow"]), ("Tailscale", ["Tail scale"]),
            ("Kubernetes", nil), ("Argo CD", nil), ("Helm", nil), ("Grafana", nil), ("Postgres", nil),
            ("Priya", nil), ("Diego Alvarez", nil), ("Sarah Chen", nil), ("Parakeet", nil),
        ]
        let terms = words.map { CustomVocabularyTerm(text: $0.0, aliases: $0.1, ctcTokenIds: tok.encode($0.0)) }
        let vocab = CustomVocabularyContext(terms: terms)
        let spotter = CtcKeywordSpotter(models: ctc, blankId: ctc.vocabulary.count)
        // Pass ctcModelDirectory explicitly: VocabularyBoostingSession.init hard-codes
        // CtcModels.defaultCacheDirectory (~/Library/Application Support/...) for the tokenizer.
        let rescorer = try await VocabularyRescorer.create(
            spotter: spotter, vocabulary: vocab, config: .default, ctcModelDirectory: ctcDir)
        let sizeCfg = ContextBiasingConstants.rescorerConfig(forVocabSize: terms.count)
        print("CTC_LOAD_MS \(f1(now() - t0))")
        for c in clips {
            let s = try readSamples(fixtures.appendingPathComponent("\(c).wav"))
            let base = try await transcribe(asr, s)
            var times: [Double] = []
            var out: VocabularyRescorer.RescoreOutput? = nil
            var detected: [String] = []
            for _ in 0..<5 {
                let t = now()
                let spot = try await spotter.spotKeywordsWithLogProbs(audioSamples: s, customVocabulary: vocab)
                let o = rescorer.ctcTokenRescore(
                    transcript: base.text, tokenTimings: base.tokenTimings ?? [], logProbs: spot.logProbs,
                    frameDuration: spot.frameDuration, cbw: sizeCfg.cbw, marginSeconds: 0.5,
                    minSimilarity: max(sizeCfg.minSimilarity, vocab.minSimilarity))
                times.append(now() - t); out = o
                detected = spot.detections.map { $0.term.text }
            }
            print("VOCAB \(c) extra_median5_ms=\(f1(median(times))) modified=\(out!.wasModified) detected=\(Array(Set(detected)).sorted())")
            print("BASE  \(c): \(base.text)")
            print("BOOST \(c): \(out!.text)")
        }

    case "vad":
        ModelHub.offlineMode = true
        let t0 = now()
        let cfg = VadConfig.default
        let mlc = MLModelConfiguration(); mlc.computeUnits = cfg.computeUnits
        let vadModel = try MLModel(contentsOf: vadDir.appendingPathComponent(ModelNames.VAD.sileroVadFile), configuration: mlc)
        let vad = VadManager(config: cfg, vadModel: vadModel)  // pure local, no ModelHub
        print("VAD_LOAD_MS \(f1(now() - t0))")
        let s = try readSamples(fixtures.appendingPathComponent("clip05_padded.wav"))
        var times: [Double] = []
        var segs: [VadSegment] = []
        _ = try await vad.segmentSpeech(s)  // warm-up
        for _ in 0..<5 {
            let t = now(); segs = try await vad.segmentSpeech(s); times.append(now() - t)
        }
        print("VAD dur_s=\(String(format: "%.2f", Double(s.count) / 16000)) median5_ms=\(f1(median(times))) segments=\(segs.count)")
        for g in segs { print("  seg \(String(format: "%.3f", g.startTime))s -> \(String(format: "%.3f", g.endTime))s") }
        // Ground truth: speech in clip05 starts at 3.000 s and the clip is 4.352 s long.
        let (asr, _) = try await loadAsr()
        let full = try await transcribe(asr, s)
        print("ASR_PADDED: \(full.text)")
        if let a = segs.first, let b = segs.last {
            let trimmed = Array(s[a.startSample(sampleRate: 16000)..<min(s.count, b.endSample(sampleRate: 16000))])
            let t = now(); let r = try await transcribe(asr, trimmed); let ms = now() - t
            print("ASR_TRIMMED (\(f1(ms)) ms): \(r.text)")
        }

    default:
        print("unknown mode \(mode)")
    }
} catch {
    print("ERROR: \(error)")
    exit(1)
}
