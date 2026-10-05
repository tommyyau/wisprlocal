// S1b spike: compare Phonon-2 / Parakeet Ultra / Parakeet TDT v2 via FluidAudio 0.17.5, fully offline.
//
// Usage (run from the spike dir; <m> = phonon2 | ultra | v2):
//   S1bModels download <m>            ONLINE one-time fetch into ./Models/<folder>
//   S1bModels load <m> [--gpu] [--hub] OFFLINE: load only, print LOAD_MS + RSS (use for first-ever / cold)
//   S1bModels bench <m> [--hub]       OFFLINE: latency (first + median of 5) on 4 lengths, then 1 pass over
//                                     every fixture -> results/raw/hyps_<m>.jsonl
//   S1bModels soak <m> [N] [maxSec]   OFFLINE: N sequential transcriptions (default 500, 900 s cap), 10 s watchdog
//   S1bModels vocab <m>               OFFLINE: CTC vocabulary rescoring on jargon fixtures -> results/raw/vocab_<m>.jsonl
// --hub uses AsrModels.load(from:version:) (ModelHub path, offlineMode=true); default is AsrModels.loadLocal.
import AVFoundation
import CoreML
import Darwin
import FluidAudio
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let modelsDir = root.appendingPathComponent("Models", isDirectory: true)
let fixtures = root.appendingPathComponent("Fixtures", isDirectory: true)
let rawDir = root.appendingPathComponent("results/raw", isDirectory: true)
try? FileManager.default.createDirectory(at: rawDir, withIntermediateDirectories: true)
let ctcDir = modelsDir.appendingPathComponent(Repo.parakeetCtc110m.folderName, isDirectory: true)

func modelInfo(_ name: String) -> (AsrModelVersion, URL) {
    switch name {
    case "phonon2": return (.phonon2, modelsDir.appendingPathComponent(Repo.phonon2.folderName))
    case "ultra": return (.ultra, modelsDir.appendingPathComponent(Repo.parakeetUltra.folderName))
    case "v2": return (.v2, modelsDir.appendingPathComponent(Repo.parakeetV2.folderName))
    default: fatalError("unknown model \(name)")
    }
}

func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e6 }  // ms
func median(_ xs: [Double]) -> Double {
    let s = xs.sorted(); return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
}
func f1(_ x: Double) -> String { String(format: "%.1f", x) }

// Memory: current resident, phys_footprint, and peak (ru_maxrss is bytes on macOS).
func memMB() -> (rss: Double, footprint: Double, peak: Double) {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    _ = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    var vm = task_vm_info_data_t()
    var vc = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    _ = withUnsafeMutablePointer(to: &vm) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(vc)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &vc)
        }
    }
    var ru = rusage(); getrusage(RUSAGE_SELF, &ru)
    let mb = 1024.0 * 1024.0
    return (Double(info.resident_size) / mb, Double(vm.phys_footprint) / mb, Double(ru.ru_maxrss) / mb)
}
func memLine() -> String { let m = memMB(); return "rss_mb=\(f1(m.rss)) footprint_mb=\(f1(m.footprint)) peak_rss_mb=\(f1(m.peak))" }

func readSamples(_ url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
    precondition(file.processingFormat.sampleRate == 16_000 && file.processingFormat.channelCount == 1)
    let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: buf)
    return Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength)))
}

struct Fixture: Codable { let id: String; let file: String; let ref: String; let jargon: [String]; let cond: String; let set: String; let dur: Double }
func loadManifest() throws -> [Fixture] {
    try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: fixtures.appendingPathComponent("manifest.json")))
}

func loadAsr(_ name: String, gpu: Bool, hub: Bool) async throws -> (AsrManager, Double) {
    let (version, dir) = modelInfo(name)
    let t0 = now()
    let units: MLComputeUnits? = gpu ? .cpuAndGPU : nil
    let models: AsrModels
    if hub {
        // ModelHub path: with every file + revision marker present and offlineMode=true it never networks.
        models = try await AsrModels.load(from: dir, version: version, encoderComputeUnits: units)
    } else {
        // Pure local path: MLModel(contentsOf:) per component, no ModelHub, no revision check.
        models = try AsrModels.loadLocal(from: dir, version: version, encoderComputeUnits: units)
    }
    let asr = AsrManager(config: .default)
    try await asr.loadModels(models)
    return (asr, now() - t0)
}

func transcribe(_ asr: AsrManager, _ samples: [Float]) async throws -> ASRResult {
    var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
    return try await asr.transcribe(samples, decoderState: &state)
}

func jsonLine(_ d: [String: Any]) -> String {
    String(data: try! JSONSerialization.data(withJSONObject: d, options: [.sortedKeys]), encoding: .utf8)!
}

// Per-call watchdog: if a call runs > limit, report HANG and exit(3) (a hung CoreML call cannot be cancelled).
final class Watchdog {
    private let lock = NSLock()
    private var started: Double? = nil
    private var label = ""
    private let timer: DispatchSourceTimer
    init(limitMs: Double, onHang: @escaping (String, Double) -> Void) {
        timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "watchdog"))
        timer.schedule(deadline: .now() + 0.5, repeating: 0.25)
        timer.setEventHandler { [unowned self] in
            self.lock.lock(); let s = self.started; let l = self.label; self.lock.unlock()
            if let s, now() - s > limitMs { onHang(l, now() - s) }
        }
        timer.resume()
    }
    func begin(_ l: String) { lock.lock(); started = now(); label = l; lock.unlock() }
    func end() { lock.lock(); started = nil; lock.unlock() }
}

let args = Array(CommandLine.arguments.dropFirst())
let mode = args.first ?? "bench"
let model = args.count > 1 ? args[1] : "v2"
let gpu = args.contains("--gpu")
let hub = args.contains("--hub")
setvbuf(stdout, nil, _IOLBF, 0)

do {
    switch mode {
    case "download":
        ModelHub.offlineMode = false
        let (version, dir) = modelInfo(model)
        try await AsrModels.download(to: dir, version: version)
        print("downloaded \(model) to \(dir.path)")

    case "load":
        ModelHub.offlineMode = true
        let before = memMB()
        let (asr, ms) = try await loadAsr(model, gpu: gpu, hub: hub)
        let s = try readSamples(fixtures.appendingPathComponent("s1/clip05.wav"))
        let t = now(); let r = try await transcribe(asr, s); let firstMs = now() - t
        print("LOAD_MS \(model) gpu=\(gpu) hub=\(hub) load_ms=\(f1(ms)) first_transcribe_ms=\(f1(firstMs)) rss_before_mb=\(f1(before.rss)) \(memLine())")
        print("TEXT \(r.text)")

    case "bench":
        ModelHub.offlineMode = true
        let (asr, loadMs) = try await loadAsr(model, gpu: gpu, hub: hub)
        print("LOAD_MS \(f1(loadMs)) \(memLine())")
        let lat = ["clean/u01.wav", "clean/u19.wav", "s1/clip30.wav", "s1/clip60.wav"]
        for f in lat {
            let s = try readSamples(fixtures.appendingPathComponent(f))
            let dur = Double(s.count) / 16_000
            let t0 = now(); _ = try await transcribe(asr, s); let firstMs = now() - t0
            var times: [Double] = []
            for _ in 0..<5 { let t = now(); _ = try await transcribe(asr, s); times.append(now() - t) }
            let med = median(times)
            print("LAT \(model) \(f) dur_s=\(String(format: "%.2f", dur)) first_ms=\(f1(firstMs)) median5_ms=\(f1(med)) min_ms=\(f1(times.min()!)) max_ms=\(f1(times.max()!)) rtfx=\(f1(dur * 1000 / med))")
        }
        let out = rawDir.appendingPathComponent("hyps_\(model).jsonl")
        var lines: [String] = []
        for fx in try loadManifest() {
            let s = try readSamples(fixtures.appendingPathComponent(fx.file))
            let t = now(); let r = try await transcribe(asr, s); let ms = now() - t
            lines.append(jsonLine(["id": fx.id, "model": model, "hyp": r.text, "ms": ms, "dur": fx.dur]))
        }
        try (lines.joined(separator: "\n") + "\n").write(to: out, atomically: true, encoding: .utf8)
        print("HYPS \(out.path) n=\(lines.count)")
        print("MEM_END \(memLine())")

    case "soak":
        ModelHub.offlineMode = true
        let n = args.count > 2 ? Int(args[2]) ?? 500 : 500
        let maxSec = args.count > 3 ? Double(args[3]) ?? 900 : 900
        let (asr, loadMs) = try await loadAsr(model, gpu: false, hub: false)
        let man = try loadManifest().filter { $0.set != "long" }
        let clips = try man.map { ($0.id, try readSamples(fixtures.appendingPathComponent($0.file))) }
        print("SOAK_START \(model) load_ms=\(f1(loadMs)) clips=\(clips.count) \(memLine())")
        let logURL = rawDir.appendingPathComponent("soak_\(model).jsonl")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let fh = try FileHandle(forWritingTo: logURL)
        let wd = Watchdog(limitMs: 10_000) { label, ms in
            print("HANG \(model) call=\(label) elapsed_ms=\(f1(ms)) \(memLine())")
            fh.write(Data((jsonLine(["event": "hang", "call": label, "elapsed_ms": ms]) + "\n").utf8))
            exit(3)
        }
        let tStart = now()
        var lat: [Double] = []
        var rng = SystemRandomNumberGenerator()
        var refText: [String: String] = [:]
        var mismatches = 0
        var i = 0
        while i < n && (now() - tStart) / 1000 < maxSec {
            let (id, s) = clips[Int.random(in: 0..<clips.count, using: &rng)]
            wd.begin("\(i):\(id)")
            let t = now(); let r = try await transcribe(asr, s); let ms = now() - t
            wd.end()
            lat.append(ms)
            if let prev = refText[id], prev != r.text { mismatches += 1 } else { refText[id] = r.text }
            var rec: [String: Any] = ["i": i, "id": id, "ms": ms, "dur": Double(s.count) / 16000]
            if i % 50 == 0 || i == n - 1 {
                let m = memMB(); rec["rss_mb"] = m.rss; rec["footprint_mb"] = m.footprint; rec["peak_mb"] = m.peak
                print("SOAK \(model) i=\(i) t_s=\(f1((now() - tStart) / 1000)) last_ms=\(f1(ms)) \(memLine())")
            }
            fh.write(Data((jsonLine(rec) + "\n").utf8))
            i += 1
        }
        try fh.close()
        print("SOAK_END \(model) calls=\(i) wall_s=\(f1((now() - tStart) / 1000)) hangs=0 nondeterministic_outputs=\(mismatches) \(memLine())")

    case "vocab":
        ModelHub.offlineMode = true
        let (asr, _) = try await loadAsr(model, gpu: false, hub: false)
        let t0 = now()
        let ctc = try await CtcModels.load(from: ctcDir, variant: .ctc110m)
        let tok = try await CtcTokenizer.load(from: ctcDir)
        let target = ["Wispr Flow", "Tailscale", "Kubernetes", "Grafana"]
        let aliases: [String: [String]] = ["Wispr Flow": ["Whisper Flow", "Whisperflow"], "Tailscale": ["Tail scale"]]
        func vocab(minSim: Float?) -> CustomVocabularyContext {
            CustomVocabularyContext(terms: target.map {
                CustomVocabularyTerm(text: $0, aliases: aliases[$0], ctcTokenIds: tok.encode($0), minSimilarity: minSim)
            })
        }
        let spotter = CtcKeywordSpotter(models: ctc, blankId: ctc.vocabulary.count)
        // Configurations: library default; spotter-rescue off; spotter-rescue off + strict per-term threshold.
        let configs: [(String, VocabularyRescorer.Config, Float?)] = [
            ("default", .default, nil),
            ("norescue", VocabularyRescorer.Config(spotterRescueEnabled: false), nil),
            ("norescue_sim070", VocabularyRescorer.Config(spotterRescueEnabled: false), 0.70),
        ]
        var rescorers: [(String, VocabularyRescorer, CustomVocabularyContext)] = []
        for (name, cfg, sim) in configs {
            let v = vocab(minSim: sim)
            rescorers.append((name, try await VocabularyRescorer.create(spotter: spotter, vocabulary: v, config: cfg, ctcModelDirectory: ctcDir), v))
        }
        let sizeCfg = ContextBiasingConstants.rescorerConfig(forVocabSize: target.count)
        print("CTC_LOAD_MS \(f1(now() - t0)) cbw=\(sizeCfg.cbw) minSim=\(sizeCfg.minSimilarity)")
        let man = try loadManifest().filter { fx in fx.set != "long" }  // incl. no-target clips (false-fire check)
        var lines: [String] = []
        for fx in man {
            let s = try readSamples(fixtures.appendingPathComponent(fx.file))
            let base = try await transcribe(asr, s)
            var rec: [String: Any] = ["id": fx.id, "model": model, "base": base.text]
            for (name, rescorer, v) in rescorers {
                var times: [Double] = []
                var out: VocabularyRescorer.RescoreOutput? = nil
                for _ in 0..<3 {
                    let t = now()
                    let spot = try await spotter.spotKeywordsWithLogProbs(audioSamples: s, customVocabulary: v)
                    out = rescorer.ctcTokenRescore(
                        transcript: base.text, tokenTimings: base.tokenTimings ?? [], logProbs: spot.logProbs,
                        frameDuration: spot.frameDuration, cbw: sizeCfg.cbw, marginSeconds: 0.5,
                        minSimilarity: max(sizeCfg.minSimilarity, v.minSimilarity))
                    times.append(now() - t)
                }
                rec[name] = out!.text
                rec[name + "_ms"] = median(times)
            }
            lines.append(jsonLine(rec))
        }
        let out = rawDir.appendingPathComponent("vocab_\(model).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: out, atomically: true, encoding: .utf8)
        print("VOCAB \(out.path) n=\(lines.count)")

    case "myvoice":
        // S1bModels myvoice <m> <dir>: transcribe every audio file in <dir> (any rate/channels; resampled to 16 kHz mono)
        ModelHub.offlineMode = true
        guard args.count > 2 else { print("usage: myvoice <m> <dir>"); exit(2) }
        let dir = URL(fileURLWithPath: args[2], isDirectory: true)
        let (asr, loadMs) = try await loadAsr(model, gpu: false, hub: false)
        print("LOAD_MS \(f1(loadMs))")
        let conv = AudioConverter()
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { ["wav", "m4a", "aiff", "aif", "caf", "mp3"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var lines: [String] = []
        for f in files {
            let s = try conv.resampleAudioFile(f)
            _ = try await transcribe(asr, s)  // warm
            let t = now(); let r = try await transcribe(asr, s); let ms = now() - t
            let id = f.deletingPathExtension().lastPathComponent
            print("MYVOICE \(model) \(id) dur_s=\(String(format: "%.2f", Double(s.count) / 16000)) ms=\(f1(ms))")
            lines.append(jsonLine(["id": id, "model": model, "hyp": r.text, "ms": ms, "dur": Double(s.count) / 16000]))
        }
        let out = rawDir.appendingPathComponent("myvoice_\(model).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: out, atomically: true, encoding: .utf8)
        print("HYPS \(out.path) n=\(lines.count) \(memLine())")

    default:
        print("unknown mode \(mode)")
    }
} catch {
    print("ERROR: \(error)")
    exit(1)
}
