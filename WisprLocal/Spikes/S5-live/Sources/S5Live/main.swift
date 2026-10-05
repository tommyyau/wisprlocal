// S5Live — live-preview measurement spike for WisprLocal.
// Offline only: models are loaded from local dirs via AsrModels.loadLocal (no ModelHub).
//
//   S5Live full     <v2|ultra> <cadenceMs> <wav...>        # 1a: re-transcribe whole growing buffer
//   S5Live tail     <v2|ultra> <cadenceMs> <capSec> <holdSec> <wav...>   # 1c: committed prefix + tail
//   S5Live sliding  <v2|ultra> <wav...>                    # 1b: FluidAudio SlidingWindowAsrManager
//   S5Live probe    <v2|ultra> <wav>                       # cost of one pass vs buffer length
//
// Output: one JSON line per run on stdout (prefixed "RESULT "), human log on stderr.

import AVFoundation
import CoreML
import Darwin
import FluidAudio
import Foundation

// MARK: - Resource accounting (no sudo: getrusage + proc_pid_rusage + task_info)

struct Usage {
    var wall: Double
    var cpu: Double          // user+sys seconds, whole process
    var energyNJ: UInt64     // rusage_info_v6.ri_energy_nj (kernel's per-task energy estimate)
    var taskEnergy: UInt64   // task_power_info_v2.task_energy (nJ)
    var gpuEnergy: UInt64    // task_power_info_v2.gpu_energy.task_gpu_utilisation (ns of GPU time)

    static func now() -> Usage {
        var ru = rusage()
        getrusage(RUSAGE_SELF, &ru)
        let cpu = Double(ru.ru_utime.tv_sec) + Double(ru.ru_utime.tv_usec) / 1e6
            + Double(ru.ru_stime.tv_sec) + Double(ru.ru_stime.tv_usec) / 1e6
        var info = rusage_info_v6()
        let rc = withUnsafeMutablePointer(to: &info) { p -> Int32 in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V6, $0)
            }
        }
        var tp = task_power_info_v2()
        var count = mach_msg_type_number_t(MemoryLayout<task_power_info_v2>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &tp) { p -> kern_return_t in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_POWER_INFO_V2), $0, &count)
            }
        }
        return Usage(
            wall: CFAbsoluteTimeGetCurrent(), cpu: cpu,
            energyNJ: rc == 0 ? info.ri_energy_nj : 0,
            taskEnergy: kr == KERN_SUCCESS ? tp.task_energy : 0,
            gpuEnergy: kr == KERN_SUCCESS ? tp.gpu_energy.task_gpu_utilisation : 0)
    }

    static func - (a: Usage, b: Usage) -> Usage {
        Usage(wall: a.wall - b.wall, cpu: a.cpu - b.cpu,
              energyNJ: a.energyNJ &- b.energyNJ, taskEnergy: a.taskEnergy &- b.taskEnergy,
              gpuEnergy: a.gpuEnergy &- b.gpuEnergy)
    }
}

let trace = ProcessInfo.processInfo.environment["S5_TRACE"] == "1"
func log(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

// MARK: - Model loading (local only)

func modelDir(_ v: String) -> URL {
    let cacheRoot = ProcessInfo.processInfo.environment["WISPRLOCAL_MODELS_DIR"]
        ?? ProcessInfo.processInfo.environment["WISPRLITE_MODELS_DIR"]
        ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../App/.models-cache").standardizedFileURL.path
    let roots = [
        NSHomeDirectory() + "/Applications/WisprLocal.app/Contents/Resources/Models",
        cacheRoot,
    ]
    let folder = v == "ultra" ? "parakeet-ultra" : "parakeet-tdt-0.6b-v2"
    for r in roots where FileManager.default.fileExists(atPath: r + "/" + folder) {
        return URL(fileURLWithPath: r + "/" + folder)
    }
    fatalError("model \(folder) not found")
}

func loadAsr(_ v: String) async throws -> AsrManager {
    let cfg = MLModelConfiguration()
    cfg.computeUnits = .cpuAndNeuralEngine
    let t0 = CFAbsoluteTimeGetCurrent()
    let models = try AsrModels.loadLocal(from: modelDir(v), version: v == "ultra" ? .ultra : .v2,
                                         configuration: cfg, encoderComputeUnits: .cpuAndNeuralEngine)
    let asr = AsrManager(config: .default)
    try await asr.loadModels(models)
    var st = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
    _ = try await asr.transcribe([Float](repeating: 0, count: 16_000), decoderState: &st)
    _ = try await asr.transcribe([Float](repeating: 0, count: 16_000), decoderState: &st)
    log("loaded \(v) in \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - t0)) s")
    return asr
}

struct Word { var text: String; var start: Double; var end: Double }

struct Hyp { var text: String; var words: [Word] }

func transcribe(_ asr: AsrManager, _ s: ArraySlice<Float>) async throws -> Hyp {
    var st = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
    let r = try await asr.transcribe(Array(s), decoderState: &st)
    var words: [Word] = []
    for t in r.tokenTimings ?? [] {
        let isBoundary = t.token.hasPrefix("▁") || t.token.hasPrefix(" ")
        let piece = t.token.replacingOccurrences(of: "▁", with: "").trimmingCharacters(in: .whitespaces)
        if isBoundary || words.isEmpty {
            if piece.isEmpty && !isBoundary { continue }
            words.append(Word(text: piece, start: t.startTime, end: t.endTime))
        } else {
            words[words.count - 1].text += piece
            words[words.count - 1].end = t.endTime
        }
    }
    words.removeAll { $0.text.isEmpty }
    let text = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
    // Fall back to text words (no timings) if the token reconstruction disagrees.
    let tw = text.split(separator: " ").map(String.init)
    if tw != words.map(\.text) {
        if words.count == tw.count { for i in words.indices { words[i].text = tw[i] } }
        else { words = tw.map { Word(text: $0, start: -1, end: -1) } }
    }
    return Hyp(text: text, words: words)
}

// MARK: - Flicker + WER

func norm(_ w: String) -> String { w.lowercased().filter { $0.isLetter || $0.isNumber } }

func lcp(_ a: [String], _ b: [String]) -> Int {
    var i = 0
    while i < a.count && i < b.count && a[i] == b[i] { i += 1 }
    return i
}

func wer(_ ref: [String], _ hyp: [String]) -> Double {
    let r = ref.map(norm).filter { !$0.isEmpty }, h = hyp.map(norm).filter { !$0.isEmpty }
    if r.isEmpty { return h.isEmpty ? 0 : 1 }
    var d = Array(0...h.count)
    for i in 1...r.count {
        var prev = d[0]; d[0] = i
        for j in stride(from: 1, through: h.count, by: 1) {
            let tmp = d[j]
            d[j] = min(d[j] + 1, d[j - 1] + 1, prev + (r[i - 1] == h[j - 1] ? 0 : 1))
            prev = tmp
        }
    }
    return Double(d[h.count]) / Double(r.count)
}

struct FlickerStats {
    var updates = 0
    var updatesWithRewrite = 0       // any already-shown word (excl. the last one) changed — raw text
    var updatesWithRewriteNorm = 0   // same, ignoring case/punctuation
    var wordsRewritten = 0           // raw
    var wordsRewrittenNorm = 0
    var maxDepthWords = 0            // deepest rewrite, in words back from the end of the previous display
    var rewriteAges: [Double] = []   // audio age (s) of each first-changed word at the time it changed

    mutating func add(prev: [String], prevAges: [Double], new: [String]) {
        updates += 1
        guard !prev.isEmpty else { return }
        let l = lcp(prev, new)
        let raw = max(0, prev.count - 1 - l)
        if raw > 0 { updatesWithRewrite += 1; wordsRewritten += raw }
        let ln = lcp(prev.map(norm), new.map(norm))
        let n = max(0, prev.count - 1 - ln)
        if n > 0 { updatesWithRewriteNorm += 1; wordsRewrittenNorm += n }
        if l < prev.count {
            maxDepthWords = max(maxDepthWords, prev.count - l)
            if raw > 0, l < prevAges.count, prevAges[l] >= 0 { rewriteAges.append(prevAges[l]) }
        }
    }
}

func pct(_ xs: [Double], _ p: Double) -> Double {
    guard !xs.isEmpty else { return 0 }
    let s = xs.sorted()
    return s[min(s.count - 1, Int((Double(s.count - 1) * p).rounded()))]
}

func loadWav(_ path: String) throws -> [Float] {
    try AudioConverter().resampleAudioFile(path: path)
}

func refWords(_ wav: String) -> [String] {
    let txt = (try? String(contentsOfFile: wav.replacingOccurrences(of: ".wav", with: ".txt"), encoding: .utf8)) ?? ""
    return txt.split(whereSeparator: { $0.isWhitespace }).map(String.init)
}

func emit(_ d: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: d, options: [.sortedKeys])
    print("RESULT " + String(data: data, encoding: .utf8)!)
    fflush(stdout)
}

// MARK: - 1a: full re-transcription of the growing buffer

func runFull(_ asr: AsrManager, model: String, cadenceMs: Int, wav: String) async throws {
    let samples = try loadWav(wav)
    let dur = Double(samples.count) / 16000
    let step = cadenceMs * 16
    var lat: [Double] = []
    var fl = FlickerStats()
    var prev: [String] = [], prevAges: [Double] = []
    let u0 = Usage.now()
    var end = step
    var lastHyp = Hyp(text: "", words: [])
    while true {
        let e = min(end, samples.count)
        let t0 = CFAbsoluteTimeGetCurrent()
        let h = try await transcribe(asr, samples[0..<e])
        lat.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        let words = h.words.map(\.text)
        let audioEnd = Double(e) / 16000
        if trace { log(String(format: "[%5.1fs %3.0fms] ", audioEnd, lat.last!) + h.text) }
        fl.add(prev: prev, prevAges: prevAges, new: words)
        prev = words; prevAges = h.words.map { $0.start >= 0 ? audioEnd - $0.start : -1 }
        lastHyp = h
        if e == samples.count { break }
        end += step
    }
    let u = Usage.now() - u0
    let finalWer = wer(refWords(wav), lastHyp.words.map(\.text))
    emit(["mode": "full", "model": model, "cadenceMs": cadenceMs, "clip": (wav as NSString).lastPathComponent,
          "audioSec": dur, "updates": lat.count,
          "latP50": pct(lat, 0.5), "latP95": pct(lat, 0.95), "latMax": lat.max() ?? 0, "latLast": lat.last ?? 0,
          "overCadence": lat.filter { $0 > Double(cadenceMs) }.count,
          "busySec": lat.reduce(0, +) / 1000, "dutyCycle": lat.reduce(0, +) / 1000 / dur,
          "cpuSec": u.cpu, "cpuPerAudioSec": u.cpu / dur, "energyJ": Double(u.energyNJ) / 1e9,
          "taskEnergyJ": Double(u.taskEnergy) / 1e9,
          "rewriteUpdates": fl.updatesWithRewrite, "rewriteUpdatesNorm": fl.updatesWithRewriteNorm,
          "wordsRewritten": fl.wordsRewritten, "wordsRewrittenNorm": fl.wordsRewrittenNorm,
          "maxDepthWords": fl.maxDepthWords, "rewriteAgeP95": pct(fl.rewriteAges, 0.95),
          "rewriteAgeMax": fl.rewriteAges.max() ?? 0, "finalWER": finalWer, "finalText": lastHyp.text])
}

// MARK: - 1c: committed prefix + capped tail

func runTail(_ asr: AsrManager, model: String, cadenceMs: Int, capSec: Double, holdSec: Double, wav: String) async throws {
    // Strategy 1c: committed prefix (frozen text) + re-decoded tail.
    // Each tick decodes audio [commitTime - ctxSec, now]; words that start before commitTime are
    // dropped (they belong to the committed prefix) — left context without re-emitting text.
    // Commit rule (all must hold): word is in the prefix shared with the previous tick's tail
    // (stable for 2 consecutive decodes), ends >= holdSec before the live edge, and the cut is
    // at a "boundary": word ends in punctuation OR is followed by a >= 0.2 s gap. Forced commit
    // (stability waived, boundary still preferred) when the window would exceed capSec.
    let ctxSec = Double(ProcessInfo.processInfo.environment["S5_CTX"] ?? "2.0") ?? 2.0
    let samples = try loadWav(wav)
    let dur = Double(samples.count) / 16000
    let step = cadenceMs * 16
    var committed: [String] = []
    var commitTime = 0.0
    var prevTail: [String] = []
    var lat: [Double] = [], windows: [Double] = []
    var fl = FlickerStats()
    var prevDisp: [String] = [], prevAges: [Double] = []
    var commits = 0, forced = 0
    let u0 = Usage.now()
    var end = step
    func isBoundary(_ ws: [Word], _ i: Int) -> Bool {
        if let c = ws[i].text.last, ".,?!:;".contains(c) { return true }
        return i + 1 < ws.count && ws[i + 1].start - ws[i].end >= 0.2
    }
    while true {
        let e = min(end, samples.count)
        let isLast = e == samples.count
        let winStartSec = max(0, commitTime - ctxSec)
        let ws = Int(winStartSec * 16000)
        let t0 = CFAbsoluteTimeGetCurrent()
        let h = try await transcribe(asr, samples[ws..<e])
        lat.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        let winDur = Double(e - ws) / 16000
        windows.append(winDur)
        let audioEnd = Double(e) / 16000
        // Absolute-time words, minus those in the already-committed region.
        var tw = h.words.map { Word(text: $0.text, start: winStartSec + $0.start, end: winStartSec + $0.end) }
        if commitTime > 0 { tw.removeAll { $0.start >= 0 && $0.start < commitTime - 0.04 } }
        // Casing fix: a tail that starts mid-sentence shouldn't be capitalised by the fresh decode.
        if let last = committed.last, let lc = last.last, !".?!".contains(lc), var f = tw.first?.text,
           f != "I", !f.hasPrefix("I'"), f.count > 1, f.dropFirst().allSatisfy({ !$0.isUppercase }) {
            f = f.prefix(1).lowercased() + f.dropFirst(); tw[0].text = f
        }
        let tail = tw.map(\.text)

        let disp = committed + tail
        if trace { log(String(format: "[%5.1fs %3.0fms win %4.1fs] ", audioEnd, lat.last!, winDur) + committed.suffix(8).joined(separator: " ") + " | " + tail.joined(separator: " ")) }
        let ages = Array(repeating: -1.0, count: committed.count) + tw.map { $0.start >= 0 ? audioEnd - $0.start : -1 }
        fl.add(prev: prevDisp, prevAges: prevAges, new: disp)
        prevDisp = disp; prevAges = ages

        if !isLast, tw.allSatisfy({ $0.start >= 0 }), tw.count >= 2 {
            let stable = lcp(prevTail, tail)
            let mustForce = (audioEnd + Double(cadenceMs) / 1000) - max(0, commitTime - ctxSec) > capSec
            let edge = audioEnd - holdSec
            var k = 0, kAny = 0
            for i in 0..<(tw.count - 1) where tw[i].end <= edge {
                if i < stable && isBoundary(tw, i) { k = i + 1 }
                if mustForce { kAny = isBoundary(tw, i) ? i + 1 : max(kAny, i + 1) }
            }
            if k == 0 && mustForce { k = kAny; if k > 0 { forced += 1 } }
            if k > 0 {
                committed += tail[0..<k]
                commitTime = (tw[k - 1].end + tw[k].start) / 2
                commits += 1
                prevTail = Array(tail[k...])
            } else { prevTail = tail }
        } else { prevTail = tail }

        if isLast { break }
        end += step
    }
    let u = Usage.now() - u0
    // Reference for the preview: the offline full-buffer pass (what we'd actually insert).
    let full = try await transcribe(asr, samples[0..<samples.count])
    emit(["mode": "tail", "model": model, "cadenceMs": cadenceMs, "capSec": capSec, "holdSec": holdSec, "ctxSec": ctxSec,
          "clip": (wav as NSString).lastPathComponent, "audioSec": dur, "updates": lat.count,
          "latP50": pct(lat, 0.5), "latP95": pct(lat, 0.95), "latMax": lat.max() ?? 0,
          "overCadence": lat.filter { $0 > Double(cadenceMs) }.count,
          "windowMax": windows.max() ?? 0, "commits": commits, "forcedCommits": forced,
          "busySec": lat.reduce(0, +) / 1000, "dutyCycle": lat.reduce(0, +) / 1000 / dur,
          "cpuSec": u.cpu, "cpuPerAudioSec": u.cpu / dur, "energyJ": Double(u.energyNJ) / 1e9,
          "taskEnergyJ": Double(u.taskEnergy) / 1e9,
          "rewriteUpdates": fl.updatesWithRewrite, "rewriteUpdatesNorm": fl.updatesWithRewriteNorm,
          "wordsRewritten": fl.wordsRewritten, "wordsRewrittenNorm": fl.wordsRewrittenNorm,
          "maxDepthWords": fl.maxDepthWords,
          "previewWERvsFull": wer(full.words.map(\.text), prevDisp), "previewWERvsRef": wer(refWords(wav), prevDisp),
          "fullWERvsRef": wer(refWords(wav), full.words.map(\.text)),
          "previewText": prevDisp.joined(separator: " "), "fullText": full.text])
}

// MARK: - probe: one-pass cost vs buffer length

func runProbe(_ asr: AsrManager, model: String, wav: String) async throws {
    let samples = try loadWav(wav)
    for sec in [1.0, 2, 4, 8, 12, 15, 16, 20, 30, 45, 60] where Int(sec * 16000) <= samples.count {
        var ls: [Double] = []
        let u0 = Usage.now()
        for _ in 0..<5 {
            let t0 = CFAbsoluteTimeGetCurrent()
            _ = try await transcribe(asr, samples[0..<Int(sec * 16000)])
            ls.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        }
        let u = Usage.now() - u0
        emit(["mode": "probe", "model": model, "bufferSec": sec, "latP50": pct(ls, 0.5), "latMin": ls.min()!,
              "cpuMsPerPass": u.cpu * 1000 / 5, "energyJPerPass": Double(u.energyNJ) / 1e9 / 5,
              "taskEnergyJPerPass": Double(u.taskEnergy) / 1e9 / 5])
    }
}

// MARK: - 1b: FluidAudio SlidingWindowAsrManager, fed in 100 ms buffers paced at real time

func runSliding(model: String, wav: String, paceRealtime: Bool) async throws {
    let samples = try loadWav(wav)
    let cfg = MLModelConfiguration(); cfg.computeUnits = .cpuAndNeuralEngine
    let models = try AsrModels.loadLocal(from: modelDir(model), version: model == "ultra" ? .ultra : .v2,
                                         configuration: cfg, encoderComputeUnits: .cpuAndNeuralEngine)
    var swc = SlidingWindowAsrConfig.streaming
    if model == "v2" { swc = swc.applying(tdtConfig: TdtConfig(blankId: 1024)) }
    let mgr = SlidingWindowAsrManager(config: swc)
    try await mgr.loadModels(models)
    let updates = await mgr.transcriptionUpdates
    try await mgr.startStreaming(source: .system)
    let start = CFAbsoluteTimeGetCurrent()
    let collector = Task { () -> [(Double, Bool, String)] in
        var out: [(Double, Bool, String)] = []
        for await u in updates {
            out.append((CFAbsoluteTimeGetCurrent() - start, u.isConfirmed, u.text))
        }
        return out
    }
    let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    var i = 0
    while i < samples.count {
        let n = min(1600, samples.count - i)
        let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n))!
        b.frameLength = AVAudioFrameCount(n)
        samples.withUnsafeBufferPointer { src in b.floatChannelData![0].update(from: src.baseAddress! + i, count: n) }
        await mgr.streamAudio(b)
        i += n
        if paceRealtime { try await Task.sleep(nanoseconds: 100_000_000) }
    }
    let final = try await mgr.finish()
    let total = CFAbsoluteTimeGetCurrent() - start
    collector.cancel()
    let ups = await collector.value
    for u in ups { log(String(format: "  t=%.2fs confirmed=%@ %@", u.0, u.1 ? "Y" : "n", String(u.2.prefix(80)))) }
    emit(["mode": "sliding", "model": model, "clip": (wav as NSString).lastPathComponent,
          "audioSec": Double(samples.count) / 16000, "updates": ups.count,
          "firstUpdateSec": ups.first?.0 ?? -1, "updateTimes": ups.map { $0.0 }, "wallSec": total,
          "finalWER": wer(refWords(wav), final.split(separator: " ").map(String.init)), "finalText": final])
}

// MARK: - main

let args = CommandLine.arguments
guard args.count >= 3 else { log("usage: see header"); exit(2) }
let mode = args[1], model = args[2]
do {
    switch mode {
    case "full":
        let asr = try await loadAsr(model)
        for w in args[4...] { try await runFull(asr, model: model, cadenceMs: Int(args[3])!, wav: w) }
    case "tail":
        let asr = try await loadAsr(model)
        for w in args[6...] {
            try await runTail(asr, model: model, cadenceMs: Int(args[3])!, capSec: Double(args[4])!,
                              holdSec: Double(args[5])!, wav: w)
        }
    case "probe":
        let asr = try await loadAsr(model)
        try await runProbe(asr, model: model, wav: args[3])
    case "sliding":
        for w in args[3...] { try await runSliding(model: model, wav: w, paceRealtime: ProcessInfo.processInfo.environment["S5_PACE"] == "1") }
    default:
        log("unknown mode"); exit(2)
    }
} catch {
    log("ERROR: \(error)"); exit(1)
}
