import Foundation

/// Why the guard rejected an LLM cleanup candidate (recorded in history).
public enum GuardReason: Sendable, Equatable, Codable {
    case emptyOutput
    /// Raw is empty / punctuation-only but the model produced text.
    case emptyRaw
    /// Output starts with an assistant preamble ("Sure!", "Here it is:") not in raw.
    case preamble(String)
    /// Output ends with an assistant trailer ("Hope this helps", "(as is)").
    case trailer(String)
    /// The word sequence differs: a word was added, removed, changed or moved.
    case wordsChanged(String)
    /// A word's case changed where that isn't allowed (US→us, Polish→polish, May→may).
    case caseChanged(String)
    /// A 4-gram repeated 3+ times more often than in raw (looping generation).
    case repetition(String)
    /// A format/control character (zero-width etc.) or a symbol class absent from the input.
    case foreignCharacter(String)
    /// Terminal punctuation (. ? !) moved, added, removed or changed type.
    case sentenceStructure
    /// A newline in the middle of a sentence.
    case midSentenceNewline
    /// Less formatted than raw (lowercase echo / lost terminal punctuation) → keep raw.
    case downgrade

    public var summary: String {
        switch self {
        case .emptyOutput: return "empty-output"
        case .emptyRaw: return "empty-raw"
        case .preamble(let p): return "preamble(\(p))"
        case .trailer(let p): return "trailer(\(p))"
        case .wordsChanged(let w): return "words-changed(\(w))"
        case .caseChanged(let w): return "case-changed(\(w))"
        case .repetition(let g): return "repetition(\(g))"
        case .downgrade: return "downgrade"
        case .foreignCharacter(let c): return "foreign-char(\(c))"
        case .sentenceStructure: return "sentence-structure"
        case .midSentenceNewline: return "mid-sentence-newline"
        }
    }

    /// The reason's case name WITHOUT its payload. The payload (`summary`) carries dictated
    /// words; only `kind` may reach the unified log (SEC-1).
    public var kind: String {
        switch self {
        case .emptyOutput: return "empty-output"
        case .emptyRaw: return "empty-raw"
        case .preamble: return "preamble"
        case .trailer: return "trailer"
        case .wordsChanged: return "words-changed"
        case .caseChanged: return "case-changed"
        case .repetition: return "repetition"
        case .downgrade: return "downgrade"
        case .foreignCharacter: return "foreign-char"
        case .sentenceStructure: return "sentence-structure"
        case .midSentenceNewline: return "mid-sentence-newline"
        }
    }
}

public enum GuardVerdict: Sendable, Equatable {
    case ok
    case reject(GuardReason)
    public var isOK: Bool { self == .ok }
    public var summary: String {
        switch self { case .ok: return "ok"; case .reject(let r): return "reject:" + r.summary }
    }
    /// Payload-free verdict for logging (SEC-1): "ok" / "reject:words-changed".
    public var kind: String {
        switch self { case .ok: return "ok"; case .reject(let r): return "reject:" + r.kind }
    }
}

/// Structural guard: the model may not add, delete, change or reorder words.
/// RuleCleaner performs deterministic content edits before the model sees the input.
/// The model may change punctuation, sentence-start casing and list/line layout.
/// Currency, operators, math symbols, degrees and numeric/sign hyphens are content.
/// Letter-to-letter hyphens are equivalent to spaces; spaced hyphens between letter
/// tokens are optional punctuation; a hyphen before currency or after an operator is a sign.
/// Numbered markers present in the input are kept;
/// added list markers are layout. Normalised content token sequences must match exactly,
/// with additional casing, sentence structure, preamble/trailer and downgrade checks.
public struct OutputGuard: Sendable {
    public var vocabulary: [String]
    public var replacements: CompiledDictionary?

    public init(vocabulary: [String] = [], replacements: CompiledDictionary? = nil) {
        self.vocabulary = vocabulary; self.replacements = replacements
    }

    public static func check(raw: String, output: String, vocabulary: [String] = [],
                             replacements: CompiledDictionary? = nil) -> GuardVerdict {
        OutputGuard(vocabulary: vocabulary, replacements: replacements).check(raw: raw, output: output)
    }

    public func check(raw rawIn: String, output: String, vocabulary extra: [String] = []) -> GuardVerdict {
        // Raw as the model saw it: dictionary replacements + the deterministic RuleCleaner pre-pass.
        let raw = RuleCleaner().cleanSync(replacements?.apply(to: rawIn) ?? rawIn, vocabulary: vocabulary + extra)
        let out = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard out.contains(where: { $0.isLetter || $0.isNumber }) else { return .reject(.emptyOutput) }
        guard raw.contains(where: { $0.isLetter || $0.isNumber }) else { return .reject(.emptyRaw) }

        let rawWords = Self.words(raw), outWords = Self.words(out)
        if let p = Self.phrase(Self.preambles, atStartOf: outWords), !Self.contains(rawWords, p) {
            return .reject(.preamble(p.joined(separator: " ")))
        }
        if let p = Self.phrase(Self.trailers, atEndOf: outWords), !Self.contains(rawWords, p) {
            return .reject(.trailer(p.joined(separator: " ")))
        }

        // Unicode: no format/control characters; no symbol the input doesn't contain.
        if let c = Self.foreignCharacter(output: out, raw: raw) { return .reject(.foreignCharacter(c)) }

        let R = Self.tokens(raw, keepNumberedMarkers: true)
        let O = Self.tokens(out, keepNumberedMarkers: Self.hasNumberedMarker(raw))
        // THE rule: identical word sequence (no insertions, deletions, substitutions, moves).
        // Surface tokens, NOT contraction-expanded: "cannot" ≠ "can not", "its" ≠ "it's".
        if R.map(\.key) != O.map(\.key) {
            let i = (0..<min(R.count, O.count)).first(where: { R[$0].key != O[$0].key }) ?? min(R.count, O.count)
            let what = i < O.count ? O[i].surface : (i < R.count ? "missing \(R[i].surface)" : "?")
            return .reject(.wordsChanged(what))
        }
        // Case: lower→upper only at sentence starts, "i…", weekdays/months, or to a dictionary
        // spelling. Upper→lower NEVER (WHO / IT / US / Polish / May stay as spoken).
        let vocabSpellings = Set((vocabulary + extra).flatMap { Self.tokens($0).map(\.surface) })
        for (r, o) in zip(R, O) where r.surface != o.surface {
            if r.isNumber { return .reject(.wordsChanged(o.surface)) }            // byte-for-byte
            let lowered = zip(r.surface, o.surface).contains { $0.isUppercase && $1.isLowercase }
            if lowered { return .reject(.caseChanged(o.surface)) }
            let allowed = o.sentenceInitial || r.key == "i" || r.key.hasPrefix("i'") || Self.calendarWords.contains(r.key)
                || vocabSpellings.contains(o.surface)
            if !allowed { return .reject(.caseChanged(o.surface)) }
        }
        // Existing terminals keep their word positions and type. A final full stop may
        // complete an otherwise unterminated final sentence (including a final list item).
        if R.contains(where: { $0.terminalAfter != nil }) {
            for k in R.indices where R[k].terminalAfter != O[k].terminalAfter {
                if k == R.count - 1, R[k].terminalAfter == nil, O[k].terminalAfter == "." { continue }
                return .reject(.sentenceStructure)
            }
        }
        // Newlines only at sentence or list-item boundaries (or where raw had one).
        for (k, o) in O.enumerated() where k > 0 && o.newlineBefore {
            let prev = O[k - 1]
            let ok = prev.terminalAfter != nil || prev.colonAfter || o.listItem || O[k - 1].lineIsListItem || R[k].newlineBefore
            if !ok { return .reject(.midSentenceNewline) }
        }
        if let g = Self.repeatedGram(O.map(\.key), comparedTo: R.map(\.key)) { return .reject(.repetition(g)) }
        if Self.isDowngrade(raw: raw, output: out) { return .reject(.downgrade) }
        return .ok
    }

    /// Would the model add anything the guard accepts? Only punctuation, sentence casing or
    /// list layout — so skip it for text that is already punctuated, sentence-cased and has no
    /// spoken list ordinals (saves ~400 ms).
    public static func modelMayHelp(_ raw: String, vocabulary: [String] = []) -> Bool {
        let t = tokens(raw)
        guard raw.contains(where: { ".!?".contains($0) }) else { return true }
        if let last = raw.trimmingCharacters(in: .whitespacesAndNewlines).last, !".!?\"')".contains(last) { return true }
        if t.contains(where: { $0.sentenceInitial && $0.surface.first?.isLowercase == true }) { return true }
        if t.contains(where: { $0.key == "i" && $0.surface == "i" }) { return true }
        return t.contains { ["first", "second", "third", "firstly", "secondly", "thirdly", "lastly"].contains($0.key) }
    }

    // MARK: tokens

    static let calendarWords: Set<String> = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
                                             "january", "february", "march", "april", "may", "june", "july", "august",
                                             "september", "october", "november", "december"]

    struct Tok: Sendable {
        /// Surface spelling (apostrophes normalised, NFKC).
        var surface: String
        /// Comparison key: lowercase (numbers: exact).
        var key: String { isNumber ? surface : surface.lowercased() }
        var isNumber: Bool
        var sentenceInitial: Bool
        /// "." / "?" / "!" directly after this token (before the next one), if any.
        var terminalAfter: Character?
        var colonAfter: Bool
        var newlineBefore: Bool
        /// This token starts a line that had a list marker; `lineIsListItem` = its line is one.
        var listItem: Bool
        var lineIsListItem: Bool
    }

    /// Numbers keep signs, decimals, thousands, ranges, times and suffixes attached.
    /// Words keep internal apostrophes. Currency, math and ASCII operators, degrees,
    /// and numeric/sign hyphens are comparison tokens; letter-to-letter hyphens are punctuation.
    /// List markers are handled separately, preserving input numbering.
    static let tokenRegex = try! NSRegularExpression(pattern:
        #"[+\-−]?(?:\d[\d,]*(?:[.:]\d+)*|\.\d+)(?:[-–]\d+(?:[.:]\d+)*)?[A-Za-z%]*|[\p{L}\p{N}]+(?:'[\p{L}]+)*|[\p{Sc}\p{Sm}°+=<>#%&@*/^~|\\]|[-–]"#)
    static let listMarker = try! NSRegularExpression(pattern: #"^[ \t]*(?:\d{1,2}[.)]|[a-z][.)]|[-•–·*])[ \t]+"#)

    /// NFKC + apostrophe normalisation (’ ʼ ‘ → '), and minus/en-dash between digits → hyphen.
    static func normalise(_ s: String) -> String {
        s.precomposedStringWithCompatibilityMapping
            .replacingOccurrences(of: #"(?<=\d)([ \t]*)[−–](?=[ \t]*\d)"#, with: "$1-", options: .regularExpression)
            .replacingOccurrences(of: "\u{2019}", with: "'").replacingOccurrences(of: "\u{02BC}", with: "'")
            .replacingOccurrences(of: "\u{2018}", with: "'")
    }

    static func hasNumberedMarker(_ text: String) -> Bool {
        normalise(text).components(separatedBy: "\n").contains { line in
            guard let m = listMarker.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return false }
            return (line as NSString).substring(with: m.range).trimmingCharacters(in: .whitespaces).first?.isNumber == true
        }
    }

    static func tokens(_ text: String, keepNumberedMarkers: Bool = false) -> [Tok] {
        var out: [Tok] = []
        var pendingNewline = false, sentenceStart = true
        for line in normalise(text).components(separatedBy: "\n") {
            let lns = line as NSString
            var body = line, isItem = false
            if let m = listMarker.firstMatch(in: line, range: NSRange(location: 0, length: lns.length)) {
                let marker = lns.substring(with: m.range).trimmingCharacters(in: .whitespaces)
                if keepNumberedMarkers, marker.first?.isNumber == true {
                    out.append(Tok(surface: String(marker.dropLast()), isNumber: true, sentenceInitial: true,
                                   terminalAfter: nil, colonAfter: false, newlineBefore: pendingNewline && !out.isEmpty,
                                   listItem: true, lineIsListItem: true))
                    pendingNewline = false
                }
                body = lns.substring(from: m.range.location + m.range.length); isItem = true
                sentenceStart = true
            }
            let ns = body as NSString
            var lastEnd = 0, first = true
            for m in tokenRegex.matches(in: body, range: NSRange(location: 0, length: ns.length)) {
                let gap = ns.substring(with: NSRange(location: lastEnd, length: m.range.location - lastEnd))
                if !out.isEmpty, !first || !gap.isEmpty { Self.annotate(&out[out.count - 1], gap: gap) }
                if gap.contains(where: { ".!?".contains($0) }) { sentenceStart = true }
                lastEnd = m.range.location + m.range.length
                let matched = ns.substring(with: m.range)
                let w = matched.count > 1 && matched.first == "−"
                    ? matched.replacingOccurrences(of: "−", with: "-") : matched
                if w == "-" {
                    let before = ns.substring(to: m.range.location)
                    let after = ns.substring(from: lastEnd)
                    let left = before.trimmingCharacters(in: .whitespaces).last
                    let right = after.trimmingCharacters(in: .whitespaces).first
                    if left?.isLetter == true && right?.isLetter == true { continue }
                    let adjacentDigit = before.last?.isNumber == true || after.first?.isNumber == true
                    let besideDigit = left?.isNumber == true || right?.isNumber == true
                    let currencySign = after.first?.unicodeScalars.first?.properties.generalCategory == .currencySymbol
                    let operatorSign = left.map { "+-−=<>*/^%|&~".contains($0) || $0.unicodeScalars.first?.properties.generalCategory == .mathSymbol } ?? false
                    if !adjacentDigit && !besideDigit && !currencySign && !operatorSign { continue }
                }
                let isNum = w.first?.isNumber == true || ("+-.".contains(w.first!) && w.count > 1)
                out.append(Tok(surface: w, isNumber: isNum, sentenceInitial: sentenceStart || pendingNewline && isItem,
                               terminalAfter: nil, colonAfter: false, newlineBefore: pendingNewline && !out.isEmpty,
                               listItem: first && isItem, lineIsListItem: isItem))
                sentenceStart = false; pendingNewline = false; first = false
            }
            if !out.isEmpty { Self.annotate(&out[out.count - 1], gap: ns.substring(from: lastEnd)) }
            if out.last?.terminalAfter != nil { sentenceStart = true }
            pendingNewline = true
            if isItem { sentenceStart = true }
        }
        return out
    }

    static func annotate(_ t: inout Tok, gap: String) {
        if t.terminalAfter == nil, let c = gap.first(where: { ".!?".contains($0) }) { t.terminalAfter = c }
        if gap.contains(":") { t.colonAfter = true }
    }

    /// Skips list markers; rejects format/control characters and non-ASCII or currency
    /// symbols absent from the normalised input.
    static func foreignCharacter(output: String, raw: String) -> String? {
        let rawScalars = Set(normalise(raw).unicodeScalars)
        let content = normalise(output).components(separatedBy: "\n").map { line in
            let ns = line as NSString
            guard let marker = listMarker.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return line }
            return ns.substring(from: marker.range.length)
        }.joined(separator: "\n")
        for u in content.unicodeScalars {
            if u == "\n" || u == "\t" { continue }
            let cat = u.properties.generalCategory
            if cat == .format || cat == .control || cat == .lineSeparator || cat == .paragraphSeparator {
                return String(format: "U+%04X", u.value)
            }
            if rawScalars.contains(u) || u.properties.isAlphabetic || CharacterSet.decimalDigits.contains(u) { continue }
            if cat == .currencySymbol || !u.isASCII { return String(u) }
        }
        return nil
    }

    // MARK: words (preamble/trailer, word counts)

    public static func words(_ s: String) -> [String] { tokens(s).filter { $0.surface.contains(where: { $0.isLetter || $0.isNumber }) }.map(\.key) }

    static let preambles: [[String]] = [
        "sure", "certainly", "of course", "absolutely", "here is", "here's", "here are", "here it is", "here you go",
        "i'm sorry", "i am sorry", "sorry", "i apologize", "i apologise", "i can't", "i cannot", "i'm unable",
        "i am unable", "i won't", "i will not", "unfortunately", "as an ai", "the cleaned", "cleaned text",
        "corrected text", "the corrected", "the transcript", "transcript", "note", "output", "result", "answer",
        "the answer", "okay", "ok",
    ].map { words($0) }

    static let trailers: [[String]] = [
        "that is all", "that's all", "hope this helps", "i hope this helps", "let me know", "as is", "unchanged",
        "no changes", "cleaned", "end of transcript", "anything else", "thank you for watching", "thanks for watching",
        "please subscribe",
    ].map { words($0) }

    static func phrase(_ list: [[String]], atStartOf ws: [String]) -> [String]? {
        list.filter { ws.count >= $0.count && Array(ws.prefix($0.count)) == $0 }.max(by: { $0.count < $1.count })
    }

    static func phrase(_ list: [[String]], atEndOf ws: [String]) -> [String]? {
        list.filter { ws.count >= $0.count && Array(ws.suffix($0.count)) == $0 }.max(by: { $0.count < $1.count })
    }

    static func contains(_ ws: [String], _ p: [String]) -> Bool {
        guard ws.count >= p.count, !p.isEmpty else { return false }
        return (0...(ws.count - p.count)).contains { Array(ws[$0..<($0 + p.count)]) == p }
    }

    static func repeatedGram(_ out: [String], comparedTo raw: [String]) -> String? {
        func counts(_ a: [String]) -> [String: Int] {
            var c: [String: Int] = [:]
            if a.count >= 4 { for i in 0...(a.count - 4) { c[a[i..<(i + 4)].joined(separator: " "), default: 0] += 1 } }
            return c
        }
        let o = counts(out), r = counts(raw)
        return o.first(where: { $0.value >= 3 && $0.value > (r[$0.key] ?? 0) })?.key
    }

    // MARK: downgrade

    static func sentenceStarts(_ s: String) -> (caps: Int, total: Int) {
        var caps = 0, total = 0, atStart = true
        for ch in s {
            if ch.isLetter { if atStart { total += 1; if ch.isUppercase { caps += 1 } }; atStart = false }
            else if ch.isNumber { if atStart { total += 1; caps += 1 }; atStart = false }
            else if ".!?\n".contains(ch) { atStart = true }
        }
        return (caps, total)
    }

    static func terminals(_ s: String) -> Int {
        var n = 0, lineHasText = false, lineTerminated = false
        for ch in s {
            if ".!?".contains(ch) { n += 1; lineTerminated = true; continue }
            if ch == "\n" {
                if lineHasText && !lineTerminated { n += 1 }
                lineHasText = false; lineTerminated = false; continue
            }
            if ch.isLetter || ch.isNumber { lineHasText = true; lineTerminated = false }
        }
        return n
    }

    /// Lower share of capitalised sentence starts than raw, or raw had terminal punctuation and
    /// the output has none.
    static func isDowngrade(raw: String, output: String) -> Bool {
        let r = sentenceStarts(raw), o = sentenceStarts(output)
        if r.total > 0, o.total > 0, Double(o.caps) / Double(o.total) < Double(r.caps) / Double(r.total) { return true }
        return terminals(raw) > 0 && terminals(output) == 0
    }
}
