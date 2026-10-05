// S5Translate — Apple Translation framework probe (macOS 26), headless CLI.
//
//   S5Translate availability                 # LanguageAvailability for en -> fr/de/es/... (no downloads)
//   S5Translate quality <fr|de|es> [low|high] # 15 sentences, latency per sentence
//   S5Translate incremental <fr|de|es>        # word-by-word growing prefix, latency per update
//
// Uses TranslationSession(installedSource:target:) (macOS 26+), which needs no SwiftUI
// `.translationTask` host. It only works when the pack is already installed; it never downloads.

import Foundation
import Translation

func log(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }
func emit(_ d: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: d, options: [.sortedKeys, .withoutEscapingSlashes])
    print("RESULT " + String(data: data, encoding: .utf8)!)
    fflush(stdout)
}
func ms(_ t0: CFAbsoluteTime) -> Double { (CFAbsoluteTimeGetCurrent() - t0) * 1000 }

let en = Locale.Language(identifier: "en-US")
let targets = ["fr", "de", "es", "it", "pt-BR", "ja", "zh-Hans", "ko", "nl"]

let sentences = [
    "Hey can you push the fix to staging before lunch?",
    "The Kubernetes cluster is back up and the pods are healthy again.",
    "I set up Tailscale on the build server so we can SSH in from anywhere.",
    "We're seeing about 42 requests per second, which is roughly 3 times last week.",
    "Let's move the launch from March 10th to March 24th.",
    "Honestly I think we're overthinking this, let's just ship it and see what happens.",
    "The payment integration still fails on about 3% of transactions.",
    "Can you send me the Q3 numbers by end of day Friday?",
    "My flight lands at 6:45 pm so I'll probably be late to dinner.",
    "Gonna grab a coffee, back in 10.",
    "The API returns a 503 when the Redis cache is cold.",
    "Please review the pull request and leave comments on the GitHub thread.",
    "We upgraded the nodes and cut the monthly AWS bill by around 18 percent.",
    "No worries at all, take your time and ping me when you're ready.",
    "Version 2.1.3 fixes the memory leak in the audio pipeline.",
]

@available(macOS 26.4, *)
func strategy(_ s: String) -> TranslationSession.Strategy { s == "high" ? .highFidelity : .lowLatency }

func makeSession(_ tgt: String, _ strat: String) -> TranslationSession {
    let t = Locale.Language(identifier: tgt)
    if #available(macOS 26.4, *), strat != "default" {
        return TranslationSession(installedSource: en, target: t, preferredStrategy: strategy(strat))
    }
    return TranslationSession(installedSource: en, target: t)
}

let args = CommandLine.arguments
let mode = args.count > 1 ? args[1] : "availability"

switch mode {
case "availability":
    let la = LanguageAvailability()
    var out: [String: String] = [:]
    for t in targets {
        let st = await la.status(from: en, to: Locale.Language(identifier: t))
        out[t] = "\(st)"
    }
    let supported = await la.supportedLanguages.map { $0.maximalIdentifier }.sorted()
    emit(["mode": "availability", "status": out, "supportedCount": supported.count, "supported": supported])

case "quality":
    let tgt = args.count > 2 ? args[2] : "fr"
    let strat = args.count > 3 ? args[3] : "default"
    let st = await LanguageAvailability().status(from: en, to: Locale.Language(identifier: tgt))
    guard st == .installed else { emit(["mode": "quality", "target": tgt, "skipped": "status=\(st) (not installed; no download triggered)"]); exit(0) }
    let t0 = CFAbsoluteTimeGetCurrent()
    let session = makeSession(tgt, strat)
    let createMs = ms(t0)
    let t1 = CFAbsoluteTimeGetCurrent()
    do { try await session.prepareTranslation() } catch { log("prepare: \(error)") }
    let prepMs = ms(t1)
    var rows: [[String: Any]] = []
    for s in sentences {
        let t = CFAbsoluteTimeGetCurrent()
        do {
            let r = try await session.translate(s)
            rows.append(["src": s, "out": r.targetText, "ms": ms(t)])
        } catch {
            rows.append(["src": s, "error": "\(error)", "ms": ms(t)])
        }
    }
    // Second pass (warm) for latency only.
    var warm: [Double] = []
    for s in sentences { let t = CFAbsoluteTimeGetCurrent(); _ = try? await session.translate(s); warm.append(ms(t)) }
    // Batch API
    let tb = CFAbsoluteTimeGetCurrent()
    let batch = (try? await session.translations(from: sentences.map { .init(sourceText: $0) }))?.count ?? -1
    let batchMs = ms(tb)
    emit(["mode": "quality", "target": tgt, "strategy": strat, "createMs": createMs, "prepareMs": prepMs,
          "rows": rows, "warmMs": warm, "batchCount": batch, "batchMs": batchMs])

case "incremental":
    let tgt = args.count > 2 ? args[2] : "fr"
    let strat = args.count > 3 ? args[3] : "default"
    let st = await LanguageAvailability().status(from: en, to: Locale.Language(identifier: tgt))
    guard st == .installed else { emit(["mode": "incremental", "target": tgt, "skipped": "status=\(st)"]); exit(0) }
    let session = makeSession(tgt, strat)
    try? await session.prepareTranslation()
    let text = "Hi team, the big decision is that we are moving the launch from March tenth to March twenty fourth, mainly because the payment integration still fails on about three percent of transactions, and Priya thinks the fix will take about a week and a half."
    let words = text.split(separator: " ").map(String.init)
    var rows: [[String: Any]] = []
    var prevOut = ""
    for n in 1...words.count {
        let partial = words[0..<n].joined(separator: " ")
        let t = CFAbsoluteTimeGetCurrent()
        let out = (try? await session.translate(partial).targetText) ?? "<error>"
        let l = ms(t)
        // How much of the previously shown translation survived as a prefix (in words)?
        let pw = prevOut.split(separator: " "), nw = out.split(separator: " ")
        var k = 0; while k < pw.count && k < nw.count && pw[k] == nw[k] { k += 1 }
        rows.append(["n": n, "ms": l, "keptPrefixWords": k, "prevWords": pw.count, "out": out])
        prevOut = out
    }
    emit(["mode": "incremental", "target": tgt, "strategy": strat, "rows": rows])

case "headless":
    // Proves the API is usable from a plain CLI (no SwiftUI/AppKit host) and that an
    // installedSource session refuses rather than downloads when the pack is missing.
    let tgt = args.count > 2 ? args[2] : "fr"
    let t0 = CFAbsoluteTimeGetCurrent()
    let session = TranslationSession(installedSource: en, target: Locale.Language(identifier: tgt))
    let createMs = ms(t0)
    let canDL = session.canRequestDownloads
    let ready = await session.isReady
    var result = "not attempted"
    var tMs = 0.0
    if !canDL {
        let t = CFAbsoluteTimeGetCurrent()
        do { result = "OK: " + (try await session.translate("Hello world").targetText) }
        catch { result = "threw: \(error) | \(error.localizedDescription)" }
        tMs = ms(t)
    }
    emit(["mode": "headless", "target": tgt, "createMs": createMs, "canRequestDownloads": canDL,
          "isReady": ready, "translateResult": result, "translateMs": tMs])

default:
    log("unknown mode")
}
