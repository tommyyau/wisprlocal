import Foundation

public protocol TextCleaner: Sendable {
    var name: String { get }
    func clean(_ text: String) async -> String
    /// Called at recording START (hotkey down) so an LLM session can be created + prewarmed
    /// while the user is still speaking. Default: no-op.
    func prepareForDictation()
    /// Clean and report which cleaner produced the text and why (history). Default: `clean`.
    func cleanDetailed(_ text: String) async -> CleanupOutcome
}

/// Result of a cleanup pass, recorded in history.
public struct CleanupOutcome: Sendable, Equatable {
    public var text: String
    /// Cleaner that produced `text`: "rules" or "fm".
    public var producedBy: String
    /// FM path only: "ok", "reject:<reason>", "timeout", "error:<…>", "guardrail",
    /// "unavailable:<reason>", "skipped:short". nil for plain rule cleaning.
    public var verdict: String?
    /// The FM candidate when it was NOT used (guard reject) — kept for tuning.
    public var candidate: String?
    /// FM latency (ms) when the model was called.
    public var modelMs: Double?

    public init(text: String, producedBy: String, verdict: String? = nil, candidate: String? = nil, modelMs: Double? = nil) {
        self.text = text; self.producedBy = producedBy; self.verdict = verdict
        self.candidate = candidate; self.modelMs = modelMs
    }
}

extension TextCleaner {
    public func prepareForDictation() {}
    public func cleanDetailed(_ text: String) async -> CleanupOutcome {
        CleanupOutcome(text: await clean(text), producedBy: name)
    }
}

/// Deterministic, deliberately conservative cleanup for Parakeet output (already punctuated and
/// cased). Only text we deliberately edit is touched; casing changes only where an edit left a
/// lowercase letter at a sentence start (tracked with an internal marker).
///
/// Rules:
/// - Voice commands fire ONLY as standalone sentences — at the start of the text/line or right
///   after `.`/`!`/`?`, and followed by `.`/`!`/`?`/`,` or end of line:
///   "scratch that" deletes everything before it in the current dictation; "new line" / "new paragraph" → "\n" / "\n\n".
///   ("Let's scratch that plan." and "a new line of products" are untouched.)
/// - Hesitation fillers that are never real words (um, uh, uhm, erm, hmm) are removed as whole
///   tokens in lowercase or Capitalised form ANYWHERE, no comma needed ("Um okay the" → "Okay the").
///   Ambiguous ones (er, ah) only as lowercase tokens, or Capitalised at a sentence start when a
///   comma follows ("Er the second one" survives). Never ALL-CAPS ("the ER", "UM" survive) and
///   never hyphenated ("uh-huh", "uh-uh").
/// - "like" is removed ONLY in ", like," ("I'd like us to", "something like, 5 minutes" survive).
/// - ", you know," and sentence-initial "Well," / "So," (with the comma) are removed.
/// - Unambiguous spoken numbers become digits (`SpokenNumbers.convert`): multi-word cardinals,
///   decimals ("six point one" → 6.1), percentages ("fifty percent" → 50%) and version numbers
///   after a name ("GPT five" → GPT 5, "v two" → v2). Single number words in prose stay words.
/// - Inline corrections ("no wait", "I mean", "or rather", "sorry I meant", "actually") are LEFT
///   VERBATIM — never applied (P2.1-final: nothing may delete content except "scratch that" as a
///   standalone sentence). The opt-in `Backtrack` pass (OFF by default) runs AFTER cleanup and
///   handles only unambiguous same-type slot restatements; see `FinalPasses`.
/// This is the deterministic pre-pass the LLM receives; the LLM may only punctuate/case/lay out.
/// - Spoken punctuation ("comma", "period") is NOT converted (Parakeet punctuates; "trial period").
/// All regexes are compiled once (static).
public struct RuleCleaner: TextCleaner {
    public var name: String { "rules" }
    public init() {}

    public func clean(_ text: String) async -> String { cleanSync(text) }

    static let hesitations: Set<String> = ["um", "umm", "uh", "uhh", "uhm", "er", "erm", "ah", "ahh", "hmm", "hmmm"]
    static let mark: Character = "\u{1}"
    static let markS = "\u{1}"

    private static func re(_ p: String, _ o: NSRegularExpression.Options = []) -> NSRegularExpression {
        try! NSRegularExpression(pattern: p, options: o)
    }

    // Sentence start = start of line, or after .!? (or our marker), plus optional spaces.
    static let command = re("(?:^|(?<=[.!?\u{1}]))[ \\t]*(new line|new paragraph)[ \\t]*(?:[.!?,]|$)",
                            [.caseInsensitive, .anchorsMatchLines])
    /// Never-a-word hesitations (um, uh, uhm, erm, hmm), lowercase or Capitalised, anywhere — no
    /// comma needed. Case-sensitive on purpose: ALL-CAPS "UM"/"UH" may be acronyms. Never part of
    /// a hyphenated word ("uh-huh", "uh-uh" are answers).
    static let strongFiller = re("(,[ \\t]*)?(?<![\\p{L}\\p{N}'-])(?:[uU]m+|[uU]h+|[uU]hm|[eE]rm|[hH]mm+)(?![\\p{L}\\p{N}'-])(?:[ \\t]*,)?")
    /// Ambiguous lowercase hesitations (er, ah): whole lowercase tokens only.
    static let lowerFiller = re("(,[ \\t]*)?(?<![\\p{L}\\p{N}'-])(?:er|ah+)(?![\\p{L}\\p{N}'-])(?:[ \\t]*,)?")
    /// Capitalised ambiguous hesitation at a sentence start — ONLY when followed by a comma ("Er,").
    static let capFiller = re("(?:^|(?<=[.!?\u{1}]))([ \\t]*)(?:Er|Ah+)(?![\\p{L}\\p{N}'-])[ \\t]*,",
                              [.anchorsMatchLines])
    /// ", like," — but not before a number ("it took, like, 5 minutes" = "about").
    static let likeFiller = re(",[ \\t]*like[ \\t]*,(?![ \\t]*(?:[0-9]|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|fifteen|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety|a hundred|a few|a couple|half)\\b)", [.caseInsensitive])
    /// ", like," directly before another comma-delimited aside keeps ONE comma:
    /// "So, like, you know, it's fine." → "So, you know, it's fine."
    static let likeBeforeAside = re(",[ \\t]*like[ \\t]*,(?=[ \\t]*(?:you know|i mean)[ \\t]*,)", [.caseInsensitive])
    /// ", you know," — but not when it follows "like," (handled by `likeBeforeAside`).
    static let youKnow = re("(?<!like),[ \\t]*\\byou know\\b[ \\t]*,", [.caseInsensitive])
    /// A whole utterance that is only "new line" / "new paragraph" (any case/punctuation).
    static let standaloneCommand = re("^[\\s.,!?]*(new line|new paragraph)[\\s.,!?]*$", [.caseInsensitive])
    /// Standalone "scratch that": at the start or after . ! ? / newline; ends with . ! , or end of
    /// text (a following "?" makes it a question, not a command).
    static let scratchCommand = re("(?:^|(?<=[.!?\\n]))[ \\t]*scratch that[ \\t]*(?:[.!,]|$)(?![ \\t]*\\?)", [.caseInsensitive])
    static let markSpaces = re("\u{1}[ \\t]+")
    static let multiSpace = re("[ \\t]{2,}")
    static let spaceBeforePunct = re("[ \\t]+([,.!?;:])")
    static let commaBeforeTerminal = re(",(\u{1}*)([.!?])")
    static let spacesAroundNewline = re("[ \\t]*\\n[ \\t]*")

    /// `vocabulary`: dictionary terms; a number spoken after one becomes digits ("Sol six" →
    /// "Sol 6", see `SpokenNumbers.convert`). The guard re-runs this pre-pass with the SAME
    /// vocabulary, so both sides agree.
    public func cleanSync(_ input: String, vocabulary: [String] = []) -> String {
        // Standalone command: insert the break itself (never trimmed away as "empty").
        let ns = input as NSString
        if let m = Self.standaloneCommand.firstMatch(in: input, range: NSRange(location: 0, length: ns.length)) {
            return ns.substring(with: m.range(at: 1)).lowercased() == "new paragraph" ? "\n\n" : "\n"
        }
        // An utterance that is ONLY hesitations ("Um.", "uh, um") inserts nothing.
        let words = input.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "-" })
        if !words.isEmpty, words.allSatisfy({ Self.hesitations.contains(String($0)) }) { return "" }
        // Deterministic number conversion (unambiguous spoken runs only) — before the LLM.
        var t = SpokenNumbers.convert(input, vocabulary: vocabulary).replacingOccurrences(of: "\r\n", with: "\n")
        t = Self.applyScratchThat(t)
        t = Self.applyCommands(t)
        t = Self.replace(t, Self.strongFiller) { m, _ in m.range(at: 1).location != NSNotFound ? "" : Self.markS }
        t = Self.replace(t, Self.lowerFiller) { m, _ in m.range(at: 1).location != NSNotFound ? "" : Self.markS }
        t = Self.replace(t, Self.capFiller) { m, ns in ns.substring(with: m.range(at: 1)) + Self.markS }
        t = Self.replace(t, Self.youKnow) { _, _ in "" }
        t = Self.replace(t, Self.likeBeforeAside) { _, _ in "," }
        t = Self.replace(t, Self.likeFiller) { _, _ in "" }
        return Self.normalize(t)
    }

    // MARK: commands

    /// "scratch that" (standalone command: start of text or after . ! ? or a newline, followed by
    /// ".", "!", ",", or the end — NOT "?") deletes EVERYTHING before it in this dictation, so a
    /// cancelled instruction can never leave a fragment ("Do not ship to St."). Text after the
    /// command is kept (capitalised). Applied repeatedly for several commands.
    static func applyScratchThat(_ text: String) -> String {
        var t = text
        while let m = scratchCommand.firstMatch(in: t, range: NSRange(location: 0, length: (t as NSString).length)) {
            let after = (t as NSString).substring(from: m.range.location + m.range.length)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            t = after.prefix(1).uppercased() + after.dropFirst()
        }
        return t
    }

    static func applyCommands(_ input: String) -> String {
        var t = input
        while let m = command.firstMatch(in: t, range: NSRange(location: 0, length: (t as NSString).length)) {
            let ns = t as NSString
            let word = ns.substring(with: m.range(at: 1)).lowercased()
            var before = ns.substring(to: m.range.location)
            let after = String(ns.substring(from: m.range.location + m.range.length)
                .drop(while: { $0 == " " || $0 == "\t" }))
            while let c = before.last, c == " " || c == "\t" { before.removeLast() }
            switch word {
            case "new paragraph":
                t = before + "\n\n" + markS + after
            default:
                t = before + "\n" + markS + after
            }
        }
        return t
    }

    // MARK: normalisation

    static func normalize(_ input: String) -> String {
        var t = input
        t = replace(t, markSpaces) { _, _ in markS }
        t = replace(t, multiSpace) { _, _ in " " }
        t = replace(t, spaceBeforePunct) { m, ns in ns.substring(with: m.range(at: 1)) }
        t = replace(t, commaBeforeTerminal) { m, ns in ns.substring(with: m.range(at: 1)) + ns.substring(with: m.range(at: 2)) }
        t = replace(t, spacesAroundNewline) { _, _ in "\n" }
        // Capitalise a lowercase letter that an edit left at a sentence start.
        var out = ""
        var pendingCap = false
        var atSentenceStart = true
        for ch in t {
            if ch == mark {
                if atSentenceStart { pendingCap = true }
                continue
            }
            if pendingCap, ch.isLetter {
                out += ch.uppercased(); pendingCap = false; atSentenceStart = false; continue
            }
            if ch.isLetter || ch.isNumber { pendingCap = false }
            out.append(ch)
            if ".!?\n".contains(ch) { atSentenceStart = true }
            else if ch == " " || ch == "\t" || ch == "\"" || ch == "(" { /* keep state */ }
            else { atSentenceStart = false }
        }
        // Punctuation orphaned at the very start by a removal (", so" / ". Then").
        while let c = out.first, ",;:.".contains(c) { out.removeFirst(); out = String(out.drop(while: { $0 == " " })) }
        out = out.trimmingCharacters(in: .whitespacesAndNewlines)
        if !out.contains(where: { $0.isLetter || $0.isNumber }) { return "" }
        return out
    }

    static func replace(_ s: String, _ re: NSRegularExpression,
                        with: (NSTextCheckingResult, NSString) -> String) -> String {
        let ns = s as NSString
        var out = ""
        var last = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            out += with(m, ns)
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }
}
