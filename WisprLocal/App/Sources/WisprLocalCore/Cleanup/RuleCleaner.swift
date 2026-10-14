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
    /// Model path: "llm-projected", "llm-rejected(<reason>)", "timeout",
    /// "unavailable:<reason>" or "skipped:<reason>". nil for plain rule cleaning.
    public var verdict: String?
    /// Per-span accepted/restored reason counts, retained only in local History.
    public var spanVerdicts: [String: Int] = [:]
    /// Generated prose, retained only in local History; never logged.
    public var candidate: String?
    /// FM latency (ms) when the model was called.
    public var modelMs: Double?

    public init(text: String, producedBy: String, verdict: String? = nil, candidate: String? = nil, modelMs: Double? = nil, spanVerdicts: [String: Int] = [:]) {
        self.text = text; self.producedBy = producedBy; self.verdict = verdict
        self.candidate = candidate; self.modelMs = modelMs; self.spanVerdicts = spanVerdicts
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
/// Explicit levels keep one deterministic floor: Verbatim removes hesitations and handles
/// spoken numbers/new lines; Light/Medium then remove safe stutters, convert optional spoken
/// punctuation, discard explicit cancellation commands and resolve same-type backtracks.
/// Verbatim retains the original default rules; Light and Medium add semantic commands.
/// Dictionary spellings arrive first. Every content-editing stage precedes the model.
/// Regexes are compiled once; ambiguous content stays as spoken.
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
    /// "Sol 6", see `SpokenNumbers.convert`). The pipeline shares this vocabulary
    /// with projection and the correction Undo source.
    public func cleanSync(_ input: String, vocabulary: [String] = [], level: CleanupLevel = .verbatim,
                          spokenPunctuation: Bool = true, backtrack: Bool = true) -> String {
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
        t = FillerContext.removeRuleAsides(t)
        t = Self.normalize(t)
        if level != .verbatim {
            t = StutterRemover.apply(t, vocabulary: vocabulary)
            if spokenPunctuation { t = SpokenPunctuation.apply(t, vocabulary: vocabulary) }
            t = DiscardCommand.apply(t)
            if backtrack { t = Backtrack.apply(t).text }
        }
        return t
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
