import Foundation

/// Positional evidence shared by deterministic and plan cleanup. Lexical matches alone
/// cannot distinguish an aside from a verb, direction, noun or degree modifier.
enum FillerContext {
    static let strong: Set<String> = ["um", "uh", "erm", "hmm"]
    static func removable(_ tokens: PlanTokens, range: Range<Int>) -> Bool {
        let w = tokens.keys, phrase = w[range].joined(separator: " ")
        let previous = range.lowerBound > 0 ? w[range.lowerBound - 1] : ""
        let next = range.upperBound < w.count ? w[range.upperBound] : ""
        let before = range.lowerBound == 0 ? tokens.prefix : tokens.gaps[range.lowerBound - 1]
        let after = tokens.gaps[range.upperBound - 1]
        let initial = range.lowerBound == 0 || before.contains(where: { ".!?;\n".contains($0) })
        if range.count == 1 && strong.contains(phrase) { return true }
        if phrase == "basically" { return initial || before.contains(",") }
        switch phrase {
        case "you know": if ["do", "does", "did", "let", "if", "to"].contains(previous) { return false }
        case "i mean": if ["it", "that", "what", "this"].contains(next) { return false }
        case "kind of", "sort of": if ["what", "which", "this", "that", "the", "a", "any", "some"].contains(previous) { return false }
        case "like":
            if ["i", "you", "he", "she", "we", "they", "it", "looks", "look", "seems"].contains(previous) { return false }
            if ["a", "an", "the", "this", "that", "these", "those", "my", "your", "his", "her", "our", "their", "some", "any"].contains(next) { return false }
            if !after.contains(",") || next.contains(where: \.isNumber) || Backtrack.numberWords.contains(next) { return false }
        case "well": if ["feeling", "do", "does", "did", "very", "as", "the", "a"].contains(previous) { return false }
        case "right": if [previous, next].contains(where: { ["on", "at", "to", "turn", "left", "now", "here", "there"].contains($0) }) { return false }
        case "okay": if ["is", "are", "was", "it's", "that's"].contains(previous) { return false }
        case "so":
            if ["that", "much", "many", "far", "long", "good", "bad", "happy", "sad", "nice", "tired", "ready", "important", "difficult", "easy", "late", "early", "glad"].contains(next) { return false }
            // With no comma, the next word could be an adjective: require an aside cluster.
            if !after.contains(",") && !(initial && ["okay", "um", "uh", "well"].contains(next)) { return false }
        default: if !PlanValidator.fillers.contains(where: { $0.elementsEqual(w[range]) }) { return false }
        }
        return (initial && (after.contains(",") || after.contains(where: { ".!?;\n".contains($0) }) || phrase == "so" && next == "okay")) ||
            (before.contains(where: { ",.!?;\n".contains($0) }) && after.contains(where: { ",.!?;\n".contains($0) }))
    }

    static func allRemovable(_ tokens: PlanTokens, range: Range<Int>) -> Bool {
        var i = range.lowerBound
        while i < range.upperBound {
            guard let phrase = PlanValidator.fillers.first(where: { i + $0.count <= range.upperBound && tokens.keys[i..<i + $0.count].elementsEqual($0) }),
                  removable(tokens, range: i..<i + phrase.count) else { return false }
            i += phrase.count
        }
        return true
    }

    /// RuleCleaner historically removes these two comma-bounded asides. Use the same
    /// decision function as plans, retaining its deliberately narrower deterministic scope.
    static func removeRuleAsides(_ text: String) -> String {
        let tokens = PlanTokens(text)
        var output = tokens.prefix, i = 0
        var preserveNextAside = false
        while i < tokens.keys.count {
            let size = tokens.keys[i] == "like" ? 1 : (i + 1 < tokens.keys.count && tokens.keys[i..<i + 2].elementsEqual(["you", "know"]) ? 2 : 0)
            if size > 0, !preserveNextAside, i > 0, tokens.gaps[i - 1].contains(","), removable(tokens, range: i..<i + size) {
                // Consume both bounding commas; the next aside still uses original gaps.
                while output.last?.isWhitespace == true { output.removeLast() }
                let nextAside = size == 1 && i + 2 < tokens.keys.count && tokens.keys[i + 1..<i + 3].elementsEqual(["you", "know"])
                if output.last == "," && !nextAside { output.removeLast() }
                preserveNextAside = nextAside
                output += " "
                i += size
            } else {
                output += tokens.surfaces[i] + tokens.gaps[i]; i += 1
                preserveNextAside = false
            }
        }
        return output
    }
}
