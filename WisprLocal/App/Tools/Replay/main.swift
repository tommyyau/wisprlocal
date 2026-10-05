// WisprLocalReplay — dev-only, OFFLINE re-transcription of saved debug recordings.
//   swift run WisprLocalReplay <clip.wav> [--variant v2|ultra|all] [--models DIR]
//       Default variant: v2. "all" runs every variant whose model is installed.
//   swift run WisprLocalReplay --compare-all [--dir DIR] [--models DIR]
//       Real-voice A/B: every clip in ~/Library/Application Support/WisprLocal/DebugRecordings
//       (or --dir) through BOTH English (Parakeet v2) and Noisy room (Parakeet Ultra), side by
//       side with differing words highlighted, then a summary split by voice processing on/off.
//   swift run WisprLocalReplay --gating [--dir DIR]
//       Zero-gating detector over every saved clip (content-free numbers: zeroFraction,
//       maxZeroRunMs, voice processing, Mic Mode), plus the totals the VP-default decision uses.
//   swift run WisprLocalReplay --mic-check
//       On-device mic self-test (same as Settings › Microphone › Check your microphone): records 3 s
//       with voice processing on, then off, and reports level + zero-gating in plain words.
//       Nothing is saved. Quit WisprLocal first (or stop its warm mic) so the mic is free.
//   swift run -c release WisprLocalReplay --bench-switch [--models DIR]
//       Mode-switch cost: load / unload each model in turn, printing load time and memory.
// Model search: --models, $WISPRLOCAL_MODELS_DIR (or legacy $WISPRLITE_MODELS_DIR), repo .models-cache, the installed app bundle,
// then the legacy App Support cache. Offline mode is enforced (no downloads, ever).
import Darwin
import Foundation
import WisprLocalCore

func fail(_ m: String) -> Never { FileHandle.standardError.write(Data((m + "\n").utf8)); exit(2) }
let usage = """
usage: WisprLocalReplay <clip.wav> [--variant v2|ultra|all] [--models DIR]
       WisprLocalReplay --compare-all [--dir DIR] [--models DIR]
       WisprLocalReplay --bench-switch [--models DIR]
       WisprLocalReplay --gating [--dir DIR]
       WisprLocalReplay --mic-check [--vp on|off]
"""

var args = Array(CommandLine.arguments.dropFirst())
var variantArg = "v2", modelsArg: String?, dirArg: String?
var wavPath: String?
var compareAll = false, benchSwitch = false, gatingReport = false, micCheck = false, micCheckVP = true
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--variant":
        if args.isEmpty { fail("--variant needs a value") }
        variantArg = args.removeFirst()
    case "--models":
        if args.isEmpty { fail("--models needs a value") }
        modelsArg = args.removeFirst()
    case "--dir":
        if args.isEmpty { fail("--dir needs a value") }
        dirArg = args.removeFirst()
    case "--compare-all": compareAll = true
    case "--bench-switch": benchSwitch = true
    case "--gating": gatingReport = true
    case "--mic-check": micCheck = true
    case "--vp":
        if args.isEmpty { fail("--vp needs on|off") }
        micCheckVP = args.removeFirst() != "off"
    case "-h", "--help": fail(usage)
    default: wavPath = a
    }
}

OfflinePolicy.enableOfflineMode()

let appDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
var roots: [URL] = []
if let m = modelsArg { roots.append(URL(fileURLWithPath: m)) }
if let e = AppEnvironment.value("MODELS_DIR"), !e.isEmpty { roots.append(URL(fileURLWithPath: e)) }
roots.append(appDir.appendingPathComponent(".models-cache"))
roots.append(URL(fileURLWithPath: "/Applications/WisprLocal.app/Contents/Resources/Models"))
roots.append(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/WisprLocal.app/Contents/Resources/Models"))
roots.append(ModelLocator.appSupportModelsDir)
let locator = ModelLocator(searchRoots: roots)

func decode(_ url: URL) -> [Float]? {
    guard let d = try? Data(contentsOf: url), let w = try? WAV.decode(d), w.sampleRate == Int(AudioConstants.sampleRate) else { return nil }
    return w.samples
}

func sidecar(_ wav: URL) -> [String: Any]? {
    let url = wav.deletingPathExtension().appendingPathExtension("json")
    guard let d = try? Data(contentsOf: url) else { return nil }
    return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
}

/// Resident and physical-footprint memory of this process, MB.
func memoryMB() -> (rss: Double, footprint: Double) {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    guard kr == KERN_SUCCESS else { return (0, 0) }
    return (Double(info.resident_size) / 1_048_576, Double(info.phys_footprint) / 1_048_576)
}

let tty = isatty(STDOUT_FILENO) != 0
func mark(_ w: String) -> String { tty ? "\u{1B}[1;33m\(w)\u{1B}[0m" : "[\(w)]" }
func pad(_ s: String, _ n: Int) -> String { s.padding(toLength: n, withPad: " ", startingAt: 0) }

// MARK: --mic-check

if micCheck {
    print("Mic check: talk normally for 3 s each time it says Recording. Nothing is saved.")
    do {
        let results = try await MicSelfTest.live().run(currentVoiceProcessing: micCheckVP) { phase in
            if case .recording(let vp) = phase { print("Recording… (voice processing \(vp ? "on" : "off"))") }
        }
        for r in results {
            print("\n\(r.title)\n  \(r.verdict)\n  \(r.details)")
        }
        if let c = MicSelfTest.comparison(results) { print("\n\(c)") }
        exit(results.allSatisfy(\.passed) ? 0 : 1)
    } catch { fail("mic check failed: \(error.localizedDescription)") }
}

// MARK: --gating

if gatingReport {
    let dir = dirArg.map { URL(fileURLWithPath: $0) } ?? AppPaths.debugRecordingsDirectory
    let wavs = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
        .filter { $0.pathExtension == "wav" }
        .sorted { (sidecar($0)?["timestamp"] as? String ?? "") < (sidecar($1)?["timestamp"] as? String ?? "") }
    var rows: [(vp: Bool?, m: AudioGatingMetrics)] = []
    print("\(pad("recorded", 21)) \(pad("dur", 6)) \(pad("VP", 4)) \(pad("mode", 16)) \(pad("zero%", 7)) \(pad("maxRun", 8)) verdict")
    for w in wavs {
        guard let s = decode(w) else { continue }
        let meta = sidecar(w) ?? [:]
        let m = AudioGatingMetrics.measure(s)
        let vp = meta["voiceProcessingActive"] as? Bool
        rows.append((vp, m))
        print("\(pad(meta["timestamp"] as? String ?? w.lastPathComponent, 21)) \(pad(String(format: "%.1f", Double(s.count) / 16_000), 6)) \(pad(vp.map { $0 ? "on" : "off" } ?? "?", 4)) \(pad(meta["micMode"] as? String ?? "?", 16)) \(pad(String(format: "%.1f", m.zeroFraction * 100), 7)) \(pad(String(format: "%.0f ms", m.maxZeroRunMs), 8)) \(m.isCuttingOut ? "CUTTING OUT" : "ok")")
    }
    for (title, sub) in [("VP on", rows.filter { $0.vp == true }), ("VP off", rows.filter { $0.vp == false }), ("VP unknown", rows.filter { $0.vp == nil })] where !sub.isEmpty {
        let f = sub.map(\.m.zeroFraction).sorted()
        print("\(title): \(sub.count) clip(s), cutting out \(sub.filter(\.m.isCuttingOut).count), median zero \(String(format: "%.1f", f[f.count / 2] * 100)) %, worst run \(String(format: "%.0f", sub.map(\.m.maxZeroRunMs).max() ?? 0)) ms")
    }
    exit(0)
}

// MARK: --bench-switch

if benchSwitch {
    let fmt = { (d: Duration) in String(format: "%.2f s", durationMs(d) / 1000) }
    let probe = [Float](repeating: 0, count: 32_000)
    print("start            rss \(String(format: "%.0f", memoryMB().rss)) MB  footprint \(String(format: "%.0f", memoryMB().footprint)) MB")
    let sequence: [ASRModelVariant] = [.parakeetV2, .parakeetUltra, .parakeetV2, .parakeetUltra]
    for (i, v) in sequence.enumerated() {
        guard locator.asrDirectory(for: v) != nil else { fail("\(v.rawValue) model not installed (scripts/fetch_models.sh)") }
        let t = FluidAudioTranscriber(variant: v, locator: locator)
        let start = ContinuousClock.now
        do { try await t.prepare() } catch { fail("\(v.rawValue) prepare failed: \(error.localizedDescription)") }
        let load = ContinuousClock.now - start
        _ = try? await t.transcribe(probe, vocabularyHints: [])
        let m = memoryMB()
        print("\(i + 1). \(pad(v.rawValue, 6)) load \(fmt(load))  rss \(String(format: "%.0f", m.rss)) MB  footprint \(String(format: "%.0f", m.footprint)) MB")
        await t.unload()
        try? await Task.sleep(for: .milliseconds(300))
        let u = memoryMB()
        print("   unloaded       rss \(String(format: "%.0f", u.rss)) MB  footprint \(String(format: "%.0f", u.footprint)) MB")
    }
    exit(0)
}

// MARK: --compare-all

if compareAll {
    let dir = dirArg.map { URL(fileURLWithPath: $0) } ?? AppPaths.debugRecordingsDirectory
    let wavs = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
        .filter { $0.pathExtension == "wav" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    guard !wavs.isEmpty else {
        fail("No recordings in \(dir.path).\nTurn on Settings › Privacy › Keep last 20 recordings (on this Mac), use WisprLocal for a day, then run this again.")
    }
    for v in [ASRModelVariant.parakeetV2, .parakeetUltra] where locator.asrDirectory(for: v) == nil {
        fail("\(v.displayName) is not installed (run scripts/fetch_models.sh, or install WisprLocal.app)")
    }
    var clips: [(name: String, samples: [Float], voiceProcessing: Bool?)] = []
    for w in wavs {
        guard let s = decode(w) else { print("skip \(w.lastPathComponent) (not a 16 kHz WAV)"); continue }
        clips.append((w.lastPathComponent, s, sidecar(w)?["voiceProcessingActive"] as? Bool))
    }
    print("Comparing \(clips.count) clip(s) from \(dir.path)")
    print("  v2    = \(ASRModelVariant.parakeetV2.modeName)")
    print("  ultra = \(ASRModelVariant.parakeetUltra.modeName)")
    print("  Words only one model produced are \(tty ? "highlighted" : "[bracketed]"). Each model is loaded once, then unloaded.\n")
    let results = await ModelComparison.run(clips: clips, a: FluidAudioTranscriber(variant: .parakeetV2, locator: locator),
                                            b: FluidAudioTranscriber(variant: .parakeetUltra, locator: locator))
    let detector = NLLanguageDetector()
    for c in results {
        let secs = Double(clips.first { $0.name == c.name }?.samples.count ?? 0) / AudioConstants.sampleRate
        let vp = c.voiceProcessing.map { $0 ? "VP on" : "VP off" } ?? "VP ?"
        let same = WordDiff.equivalent(c.a.text, c.b.text)
        print("── \(c.name)  \(String(format: "%.1f", secs)) s  \(vp)  \(same ? "identical" : "DIFFERENT")")
        let (l, r) = WordDiff.highlighted(c.a.text, c.b.text, mark: mark)
        func lang(_ t: String) -> String {
            let (verdict, d) = CleanupLanguagePolicy.decide(t, detector: detector)
            return verdict.allowsCleanup ? "" : "  ⚠︎ non-English (\(d?.logDescription ?? "?"))"
        }
        print("   v2    \(String(format: "%5.0f", c.a.ms)) ms  \(c.a.error.map { "ERROR \($0)" } ?? (c.a.isEmpty ? "(empty)" : l))\(lang(c.a.text))")
        print("   ultra \(String(format: "%5.0f", c.b.ms)) ms  \(c.b.error.map { "ERROR \($0)" } ?? (c.b.isEmpty ? "(empty)" : r))\(lang(c.b.text))")
    }
    func report(_ title: String, _ subset: [ModelComparison.Clip]) {
        guard !subset.isEmpty else { return }
        let s = ModelComparison.summarize(subset, detector: detector)
        print("\n\(title): \(s.clips) clip(s) — identical \(s.identical), different \(s.different)")
        print("   \(pad("", 22))  \(pad("v2", 10))  ultra")
        print("   \(pad("non-English detected", 22))  \(pad(String(s.nonEnglishA), 10))  \(s.nonEnglishB)")
        print("   \(pad("empty output", 22))  \(pad(String(s.emptyA), 10))  \(s.emptyB)")
        print("   \(pad("average latency", 22))  \(pad(String(format: "%.0f ms", s.avgMsA), 10))  \(String(format: "%.0f ms", s.avgMsB))")
    }
    print("\n════ Summary")
    report("All clips", results)
    report("Voice processing ON", results.filter { $0.voiceProcessing == true })
    report("Voice processing OFF", results.filter { $0.voiceProcessing == false })
    report("Voice processing unknown (older recordings)", results.filter { $0.voiceProcessing == nil })
    exit(0)
}

// MARK: single clip

guard let wavPath else { fail(usage) }
let url = URL(fileURLWithPath: wavPath)
let decoded: (samples: [Float], sampleRate: Int)
do { decoded = try WAV.decode(try Data(contentsOf: url)) } catch { fail("cannot read \(wavPath): \(error.localizedDescription)") }
guard decoded.sampleRate == Int(AudioConstants.sampleRate) else {
    fail("clip is \(decoded.sampleRate) Hz; expected \(Int(AudioConstants.sampleRate)) Hz (debug recordings are 16 kHz)")
}
print("clip      \(url.lastPathComponent)  \(String(format: "%.2f", Double(decoded.samples.count) / AudioConstants.sampleRate)) s")

// Sidecar (if present): what the app heard at the time.
if let obj = sidecar(url) {
    print("recorded  engine: \(obj["engine"] as? String ?? "")  voice processing: \((obj["voiceProcessingActive"] as? Bool).map { $0 ? "on" : "off" } ?? "unknown")")
    print("recorded  raw:   \(obj["raw"] as? String ?? "")")
    print("recorded  final: \(obj["final"] as? String ?? "")")
}

let variants: [ASRModelVariant]
if variantArg == "all" { variants = ASRModelVariant.allCases }
else if let v = ASRModelVariant(rawValue: variantArg) { variants = [v] }
else { fail("unknown variant \(variantArg)") }
for v in variants {
    guard locator.asrDirectory(for: v) != nil else {
        print("\(pad(v.rawValue, 9)) (model not installed — skipped)")
        continue
    }
    let t = FluidAudioTranscriber(variant: v, locator: locator)
    do {
        let start = Date()
        let text = try await t.transcribe(decoded.samples, vocabularyHints: [])
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        print("\(pad(v.rawValue, 9)) raw:   \(text)   [\(ms) ms incl. load]")
        print("\(String(repeating: " ", count: 9)) rules: \(RuleCleaner().cleanSync(text))")
        await t.unload()
    } catch {
        print("\(v.rawValue): error \(error.localizedDescription)")
    }
}
