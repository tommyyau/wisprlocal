import Foundation
import NaturalLanguage

/// Per-app writing style: the LAST deterministic pass, after cleanup, the dictionary and an
/// optional backtrack, before the smart join. English only.
///
/// MEANING-SAFE (STRUCTURAL, `StyleWordsPreservedTests`): a style may change only
/// - the case of the FIRST letter of the text, and
/// - a single trailing full stop (removed, or added after a final letter/digit — outside closing
///   brackets/quotes, never after code, a URL or an emoji; `addFullStop`).
/// It never adds, removes or changes a word, never touches `?`, `!`, `…`, interior text or
/// whitespace. `WritingStyle.apply` is the only entry point.
public enum WritingStyle: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Full punctuation and a sentence capital.
    case formal
    /// No trailing full stop on a single-sentence message; capitals kept.
    case casual
    /// No trailing full stop and a lowercase first letter (unless "I", a name, an acronym or a
    /// dictionary term). Opt-in only.
    case veryCasual
    /// No auto-capital on the first word, no trailing full stop; identifiers are never touched.
    case code

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .formal: "Formal"
        case .casual: "Casual"
        case .veryCasual: "Very casual"
        case .code: "Code"
        }
    }

    /// One-line "why" for the style picker.
    public var summary: String {
        switch self {
        case .formal: "Full punctuation and capitals."
        case .casual: "No full stop on a one-line message."
        case .veryCasual: "No full stop, lowercase start."
        case .code: "No auto-capitals or full stop."
        }
    }

    /// Built-in default per category. Very casual is never a default (opt-in only).
    public static func defaultStyle(for category: AppCategory) -> WritingStyle {
        switch category {
        case .email, .docs, .browser, .other: .formal
        case .messages, .ai: .casual
        case .code: .code
        }
    }

    /// The live example shown on the style cards.
    public static let exampleInput = "See you at 3."

    // MARK: apply

    /// - Parameters:
    ///   - text: the final cleaned text.
    ///   - vocabulary: dictionary terms; a first word that is one is never lowercased.
    ///   - names: decides whether the first word is a name (kept capitalised).
    public func apply(_ text: String, vocabulary: [String] = [], names: NameRecognizing = NLNameRecognizer()) -> String {
        guard text.contains(where: { $0.isLetter || $0.isNumber }) else { return text }
        var t = text
        switch self {
        case .formal:
            t = Self.capitaliseFirst(t)
            t = Self.addFullStop(t)
        case .casual:
            if Self.isSingleSentence(t) { t = Self.removeFullStop(t) }
        case .veryCasual, .code:
            t = Self.removeFullStop(t)
            if Self.mayLowercaseFirstWord(t, vocabulary: vocabulary, names: names) { t = Self.lowercaseFirst(t) }
        }
        return t
    }

    // MARK: first letter

    /// Index of the first letter, when it starts the first word (leading quotes/brackets allowed).
    static func firstLetterIndex(_ t: String) -> String.Index? {
        var i = t.startIndex
        while i < t.endIndex {
            let c = t[i]
            if c.isLetter { return i }
            if c.isWhitespace || "\"'“‘(".contains(c) { i = t.index(after: i); continue }
            return nil  // starts with a digit, symbol, list marker…
        }
        return nil
    }

    /// The first whitespace-separated token (letters, digits and identifier characters).
    static func firstWord(_ t: String) -> Substring? {
        guard let i = firstLetterIndex(t) else { return nil }
        let rest = t[i...]
        return rest.prefix(while: { !$0.isWhitespace })
    }

    static func capitaliseFirst(_ t: String) -> String {
        guard let i = firstLetterIndex(t), t[i].isLowercase, let w = firstWord(t), !isIdentifierLike(w) else { return t }
        return replacing(t, at: i, with: t[i].uppercased())
    }

    static func lowercaseFirst(_ t: String) -> String {
        guard let i = firstLetterIndex(t), t[i].isUppercase else { return t }
        return replacing(t, at: i, with: t[i].lowercased())
    }

    /// Replaces ONE character; refuses a case mapping that changes length (e.g. "ß" → "SS").
    static func replacing(_ t: String, at i: String.Index, with s: String) -> String {
        guard s.count == 1 else { return t }
        var out = t
        out.replaceSubrange(i...i, with: s)
        return out
    }

    /// "iPhone", "macOS", "foo_bar", "x.y", "GPT", "Q3": never re-cased.
    static func isIdentifierLike(_ w: Substring) -> Bool {
        let core = w.trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:\"'”’)"))
        if core.contains(where: { "_./\\()[]{}<>=#@$`".contains($0) || $0.isNumber }) { return true }
        let letters = core.filter(\.isLetter)
        if letters.dropFirst().contains(where: \.isUppercase) { return true }  // camelCase, ACRONYM
        return false
    }

    static let iWords: Set<String> = ["I", "I'm", "I'll", "I'd", "I've", "I’m", "I’ll", "I’d", "I’ve"]

    /// Proper nouns that are always capitalised in English.
    static let properWords: Set<String> = [
        "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday",
        "January", "February", "March", "April", "June", "July", "August", "September", "October",
        "November", "December", "English",
    ]

    static func mayLowercaseFirstWord(_ t: String, vocabulary: [String], names: NameRecognizing) -> Bool {
        guard let w = firstWord(t), let first = w.first, first.isUppercase else { return false }
        let core = String(w).trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:\"'”’)"))
        if iWords.contains(core) || isIdentifierLike(w) || properWords.contains(core) { return false }
        guard let i = firstLetterIndex(t) else { return false }
        let start = t[i...]
        for term in vocabulary where !term.isEmpty {
            if term.first?.isUppercase == true, start.hasPrefix(term) {
                let after = start.dropFirst(term.count).first
                if after == nil || !(after!.isLetter || after!.isNumber) { return false }
            }
        }
        if names.isName(core, in: t) { return false }
        return true
    }

    // MARK: trailing full stop

    /// The text up to trailing whitespace and closing quotes/brackets.
    private static func trailingSplit(_ t: String) -> (body: Substring, tail: Substring) {
        var end = t.endIndex
        while end > t.startIndex {
            let p = t.index(before: end)
            if t[p].isWhitespace || "\"”’)".contains(t[p]) { end = p } else { break }
        }
        return (t[..<end], t[end...])
    }

    static func removeFullStop(_ t: String) -> String {
        let (body, tail) = trailingSplit(t)
        guard body.hasSuffix("."), !body.hasSuffix(".."), !body.hasSuffix("…") else { return t }
        let before = body.dropLast()
        // Keep the dot of an abbreviation or initialism ("a.m.", "e.g.", "U.S.").
        if let w = before.split(whereSeparator: { $0.isWhitespace }).last, isAbbreviation(w + ".") { return t }
        return String(before) + tail
    }

    /// "a.m.", "e.g.", "U.S.", "i.e.": letter groups of one or two, each followed by a dot.
    static func isAbbreviation<S: StringProtocol>(_ w: S) -> Bool {
        String(w).range(of: "^(?:\\p{L}{1,2}\\.){2,}$", options: .regularExpression) != nil
    }

    /// Closing brackets and quotes the full stop goes AFTER ("(attached)." — English convention).
    static let stopClosers: Set<Character> = ["\"", "'", "”", "’", ")", "]", "}"]
    static let stopOpeners: Set<Character> = ["\"", "'", "“", "‘", "(", "[", "{"]

    /// Formal's trailing full stop (R4): after the last letter/digit, OUTSIDE any closing brackets
    /// and quotes, before trailing whitespace. Skipped when the text already ends with a terminal
    /// mark (`.`, `!`, `?`, `…`, `:`…), an emoji, or a code-like token / URL / path (`foo(bar)`,
    /// `README.md`, a web address): a dot there would change the code.
    static func addFullStop(_ t: String) -> String {
        guard !t.contains("\n") else { return t }  // lists and layouts keep their shape
        var end = t.endIndex
        while end > t.startIndex, t[t.index(before: end)].isWhitespace { end = t.index(before: end) }
        let content = t[..<end], space = t[end...]
        var inner = content.endIndex
        while inner > content.startIndex, stopClosers.contains(content[content.index(before: inner)]) {
            inner = content.index(before: inner)
        }
        guard let last = content[..<inner].last, last.isLetter || last.isNumber else { return t }
        if let token = content.split(whereSeparator: \.isWhitespace).last, isCodeLike(token) { return t }
        return String(content) + "." + space
    }

    /// A token a full stop must not follow: code calls, paths, URLs, file names, handles.
    /// Enclosing brackets/quotes are ignored ("(attached)" is prose; "foo(bar)" is a call).
    static func isCodeLike(_ token: Substring) -> Bool {
        var core = token
        while let c = core.last, stopClosers.contains(c) { core = core.dropLast() }
        while let c = core.first, stopOpeners.contains(c) { core = core.dropFirst() }
        if core.contains(where: { "_/\\=<>{}[]#@`|~^*(".contains($0) }) { return true }
        // An interior dot next to a letter: "README.md", "example.com", "self.reload" (not "6.1").
        let chars = Array(core)
        for i in chars.indices.dropFirst().dropLast() where chars[i] == "." {
            let a = chars[i - 1], b = chars[i + 1]
            if (a.isLetter || a.isNumber) && (b.isLetter || b.isNumber) && (a.isLetter || b.isLetter) { return true }
        }
        return false
    }

    /// No sentence break inside the text: no newline and no `.`/`!`/`?` followed by a space
    /// before the final character (decimals such as "6.1" and "e.g. " abbreviations aside).
    static func isSingleSentence(_ t: String) -> Bool {
        let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("\n") { return false }
        let chars = Array(trimmed)
        guard chars.count > 1 else { return true }
        for i in 0..<(chars.count - 1) where ".!?".contains(chars[i]) && chars[i + 1].isWhitespace {
            if chars[i] == "." {
                // "e.g. this" / "a.m. tomorrow": the token holds another dot → abbreviation.
                var j = i - 1
                var token = ""
                while j >= 0, !chars[j].isWhitespace { token.append(chars[j]); j -= 1 }
                if isAbbreviation(String(token.reversed()) + ".") { continue }
            }
            return false
        }
        return true
    }
}

/// Decides whether a capitalised first word is a personal or place name (kept capitalised by
/// Very casual and Code). Injectable so tests are deterministic.
public protocol NameRecognizing: Sendable {
    func isName(_ word: String, in text: String) -> Bool
}

/// Apple's on-device `NLTagger` name tagging (no network, no download).
public struct NLNameRecognizer: NameRecognizing {
    public init() {}
    public func isName(_ word: String, in text: String) -> Bool {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        var found = false
        let opts: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .joinNames]
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType, options: opts) { tag, range in
            if let tag, [.personalName, .placeName, .organizationName].contains(tag),
               text[range].split(separator: " ").first.map(String.init) == word { found = true }
            return false  // only the first token matters
        }
        return found
    }
}

/// A fixed set of names (tests, previews).
public struct FixedNames: NameRecognizing {
    public let names: Set<String>
    public init(_ names: Set<String> = []) { self.names = names }
    public func isName(_ word: String, in text: String) -> Bool { names.contains(word) }
}

/// Which style applies where: per-app override → category style. Pure.
public struct StyleConfiguration: Codable, Sendable, Equatable {
    /// Master switch ("Per-app styles", default ON).
    public var enabled: Bool
    /// Style per category; a missing key means the built-in default.
    public var categories: [AppCategory: WritingStyle]
    /// bundle ID → style, wins over the category.
    public var appOverrides: [String: WritingStyle]

    public init(enabled: Bool = true, categories: [AppCategory: WritingStyle] = [:], appOverrides: [String: WritingStyle] = [:]) {
        self.enabled = enabled; self.categories = categories; self.appOverrides = appOverrides
    }

    public func style(for category: AppCategory) -> WritingStyle {
        categories[category] ?? WritingStyle.defaultStyle(for: category)
    }

    /// Apps whose built-in style differs from their Insights category: Cursor counts as an AI
    /// tool in Insights, but you write code in it. A user override still wins.
    public static let builtInAppStyles: [String: WritingStyle] = [
        "com.todesktop.230313mzl4w4u92": .code,  // Cursor
    ]

    /// nil when styles are off. User override → built-in app default → category style.
    public func style(forBundleID id: String?) -> WritingStyle? {
        guard enabled else { return nil }
        if let id, let o = appOverrides[id] ?? Self.builtInAppStyles[id] { return o }
        return style(for: AppCategoryMap.category(for: id))
    }
}
