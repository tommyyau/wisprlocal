import Foundation

/// Only immediate repeats of grammatical scaffolding; quoted text and vocabulary are opaque.
public enum StutterRemover {
    static let functionWords: Set<String> = ["i", "i'm", "the", "a", "an", "to", "and", "but", "we", "it", "was", "this", "of", "for", "you", "my", "he", "she", "they", "are", "were", "have", "has", "will", "would", "can", "could", "do", "did", "be", "it's"]
    static let pattern = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}])([\p{L}]+(?:['’][\p{L}]+)?-?)[ \t]+(?=([\p{L}]+(?:['’][\p{L}]+)?)\b)"#)
    static let openings = try! NSRegularExpression(pattern: #"\b(I think|I am|I want|I need|we should|we are)[ \t]+\1\b"#, options: .caseInsensitive)

    public static func apply(_ text: String, vocabulary: [String] = []) -> String {
        // Edit only outside paired quotes, including smart quotes. A dangling opening quote
        // protects the rest, since guessing where a quotation ends would lose words.
        var out = "", segment = "", quoted = false
        var quoteEnd: Character?
        let chars = Array(text)
        for (i, c) in chars.enumerated() {
            let singleBoundary = (c == "'" || c == "’") &&
                (i == 0 || !chars[i - 1].isLetter || i + 1 == chars.count || !chars[i + 1].isLetter)
            let opening = !quoted && (c == "\"" || c == "“" || c == "‘" || singleBoundary)
            let closing = quoted && c == quoteEnd && (c != "'" && c != "’" || singleBoundary)
            if opening || closing {
                out += quoted ? segment : collapse(segment, vocabulary: vocabulary)
                segment = ""; out.append(c); quoted.toggle()
                quoteEnd = opening ? (c == "“" ? "”" : c == "‘" ? "’" : c) : nil
            } else { segment.append(c) }
        }
        return out + (quoted ? segment : collapse(segment, vocabulary: vocabulary))
    }

    private static func collapse(_ text: String, vocabulary: [String]) -> String {
        let protected = Set(vocabulary.flatMap { Tokenizer.semanticWords($0) })
        var t = text
        let placement = PlanTokens(t)
        var offsets: [Int] = [], offset = placement.prefix.utf16.count
        for index in placement.keys.indices {
            offsets.append(offset)
            offset += placement.surfaces[index].utf16.count + placement.gaps[index].utf16.count
        }
        for index in placement.keys.indices.reversed() where index + 8 < placement.keys.count {
            let range = index..<index + 4
            guard PlanValidator.incompletePlacement(placement, range: range),
                  placement.gaps[index + 3].contains(","),
                  PlanValidator.falseStartReason(placement, range: range, isClauseStart: true,
                                                restartEnd: index + 9, terms: protected) == nil else { continue }
            // Keep the opening's original case while deleting its unfinished slot.
            let end = offsets[index + 4] + placement.surfaces[index + 4].utf16.count
            let edit = NSRange(location: offsets[index], length: end - offsets[index])
            t = (t as NSString).replacingCharacters(in: edit, with: placement.surfaces[index])
        }
        for _ in 0..<50 {
            let ns = t as NSString
            let matches = pattern.matches(in: t, range: NSRange(location: 0, length: ns.length))
            guard let m = matches.first(where: { m in
                let a = ns.substring(with: m.range(at: 1)).lowercased().replacingOccurrences(of: "’", with: "'")
                let b = ns.substring(with: m.range(at: 2)).lowercased().replacingOccurrences(of: "’", with: "'")
                guard !protected.contains(b) else { return false }
                if a.hasSuffix("-") { return a.count > 2 && b.hasPrefix(a.dropLast()) }
                let before = ns.substring(to: m.range.location).trimmingCharacters(in: .whitespacesAndNewlines)
                let sentenceStart = before.isEmpty || before.last.map { ".!?".contains($0) } == true
                let sameCase = ns.substring(with: m.range(at: 1)) == ns.substring(with: m.range(at: 2))
                return a == b && functionWords.contains(a) && (sameCase || sentenceStart && a != "will")
            }) else { break }
            // Keep the first repeat's case, but a fragment must use its completion.
            let a = ns.substring(with: m.range(at: 1)), b = ns.substring(with: m.range(at: 2))
            let whole = NSRange(location: m.range.location, length: NSMaxRange(m.range(at: 2)) - m.range.location)
            t = ns.replacingCharacters(in: whole, with: a.hasSuffix("-") ? b : a)
        }
        // Restrict two-word repeats to a small set of sentence openings.
        let ns = t as NSString
        for m in openings.matches(in: t, range: NSRange(location: 0, length: ns.length)).reversed() {
            let phrase = ns.substring(with: m.range(at: 1))
            let before = ns.substring(to: m.range.location).trimmingCharacters(in: .whitespacesAndNewlines)
            if (before.isEmpty || before.last.map { ".!?".contains($0) } == true),
               !Tokenizer.semanticWords(phrase).contains(where: protected.contains) {
                t = (t as NSString).replacingCharacters(in: m.range, with: phrase)
            }
        }
        return t
    }
}
