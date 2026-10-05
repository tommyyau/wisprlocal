import Testing
import Foundation
@testable import WisprLocalCore

/// SEC-1 (STRUCTURAL): no dictated content in the unified log, ever. Every `Log.` / `logger.` /
/// `os_log` / `NSLog` call in Sources is scanned; an interpolation that mentions a
/// content-bearing identifier fails the build's test run.
@Suite struct LogHygieneTests {
    /// Identifiers that hold (or derive from) dictated words, snippets or dictionary entries.
    static let contentIdentifiers: Set<String> = [
        "text", "raw", "final", "transcript", "candidate", "summary", "snippet", "snippets",
        "expansion", "trigger", "replaced", "toInsert", "speech", "words", "dictionary",
        "vocabulary", "hints", "prompt", "modelInput", "rules", "entry", "join", "preceding",
        "cleanupCandidate", "cleanupVerdict", "payload", "string",
    ]

    static let callPattern = try! NSRegularExpression(
        pattern: #"\b(Log\.(info|error|debug|notice|fault|warning)|logger\.\w+|os_log|NSLog)\s*\("#)
    static let interpolation = try! NSRegularExpression(pattern: #"\\\(([^)]*(\([^)]*\))?[^)]*)\)"#)
    static let identifier = try! NSRegularExpression(pattern: #"[A-Za-z_][A-Za-z0-9_]*"#)

    /// Violations in one source text (file label for messages).
    static func violations(in source: String, file: String) -> [String] {
        var out: [String] = []
        for (i, line) in source.components(separatedBy: "\n").enumerated() {
            let ns = line as NSString
            guard callPattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) != nil else { continue }
            for m in interpolation.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                let expr = ns.substring(with: m.range(at: 1))
                let ens = expr as NSString
                for id in identifier.matches(in: expr, range: NSRange(location: 0, length: ens.length)) {
                    let name = ens.substring(with: id.range)
                    if contentIdentifiers.contains(name) { out.append("\(file):\(i + 1): \\(\(expr))") }
                }
            }
        }
        return out
    }

    @Test func noLogCallInterpolatesDictatedContent() throws {
        var v: [String] = []
        var calls = 0
        for f in OfflineGuardTests.allSwiftFiles() {
            let s = try String(contentsOf: f, encoding: .utf8)
            calls += s.components(separatedBy: "\n").filter {
                Self.callPattern.firstMatch(in: $0, range: NSRange(location: 0, length: ($0 as NSString).length)) != nil
            }.count
            v += Self.violations(in: s, file: OfflineGuardTests.relativePath(f))
        }
        #expect(calls >= 10, "scanner found only \(calls) log calls — is it still matching?")
        #expect(v.isEmpty, "dictated content interpolated into the unified log:\n\(v.joined(separator: "\n"))")
    }

    /// Positive control: the scanner must catch the exact SEC-1 bug and its variants.
    @Test(arguments: [
        #"Log.info("FM cleanup rejected by guard: \(verdict.summary)")"#,
        #"Log.error("bad \(entry.final)")"#,
        #"logger.info("x \(raw, privacy: .public)")"#,
        #"Log.info("join \(String(text.prefix(5)))")"#,
        #"NSLog("t \(transcript)")"#,
    ])
    func scannerCatchesPlantedLeak(_ line: String) {
        #expect(!Self.violations(in: line, file: "planted").isEmpty)
    }

    @Test func scannerAllowsKindsAndCounts() {
        let ok = #"Log.info("FM cleanup rejected by guard: \(verdict.kind) n=\(count)")"#
        #expect(Self.violations(in: ok, file: "ok").isEmpty)
    }

    /// The logged form of every guard verdict carries no payload.
    @Test func guardVerdictKindHasNoPayload() {
        let secret = "Paris"
        let reasons: [GuardReason] = [.emptyOutput, .emptyRaw, .preamble(secret), .trailer(secret),
                                      .wordsChanged(secret), .caseChanged(secret), .repetition(secret),
                                      .foreignCharacter(secret), .sentenceStructure, .midSentenceNewline, .downgrade]
        for r in reasons {
            let k = GuardVerdict.reject(r).kind
            #expect(!k.contains(secret) && !k.contains("("), "\(k)")
            #expect(k.hasPrefix("reject:"))
        }
        #expect(GuardVerdict.ok.kind == "ok")
    }
}
