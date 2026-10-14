import Foundation

/// Spoken commands are whole tokens. Ambiguous noun uses remain words.
public enum SpokenPunctuation {
    static let commands: [String: String] = [
        "comma": ",", "period": ".", "full stop": ".", "question mark": "?",
        "exclamation mark": "!", "exclamation point": "!", "colon": ":", "semicolon": ";",
        "open quote": "“", "close quote": "”", "end quote": "”",
        "open paren": "(", "close paren": ")", "dash": "—", "hyphen": "-",
    ]
    static let pattern = try! NSRegularExpression(pattern:
        #"\b(literal\s+)?(exclamation point|exclamation mark|question mark|full stop|open quote|close quote|end quote|open paren|close paren|semicolon|comma|period|colon|dash|hyphen)\b"#, options: .caseInsensitive)
    static let nounLeads: Set<String> = ["a", "an", "the", "this", "that", "these", "those", "some", "any", "every", "each", "one", "two", "many", "few", "several", "another", "my", "your", "his", "her", "our", "their", "of", "in", "on", "at", "for", "with", "without", "by", "from", "to", "about", "during", "over", "under"]
    static let nounTails: Set<String> = ["of", "cancer", "key", "button", "symbol", "character", "mark", "separated", "delimited", "separator", "notation"]

    static let compoundModifiers: [String: Set<String>] = [
        "period": ["trial", "short", "long", "same", "rest", "notice", "grace", "time", "victorian"],
        "comma": ["oxford", "serial"], "dash": ["quick", "short", "em", "en"],
        "question mark": ["big", "huge"],
    ]
    static func isCompound(_ previous: String, _ command: String) -> Bool {
        compoundModifiers[command]?.contains(previous) == true ||
            (command == "period" && (previous.hasSuffix("ing") || previous.hasSuffix("al") || previous == "probationary"))
    }

    public static func apply(_ text: String, vocabulary: [String] = []) -> String {
        let ns = text as NSString
        var t = text
        let protected = Set(vocabulary.flatMap { Tokenizer.semanticWords($0) })
        for m in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let command = ns.substring(with: m.range(at: 2)).lowercased()
            if m.range(at: 1).location != NSNotFound {
                t = (t as NSString).replacingCharacters(in: m.range, with: ns.substring(with: m.range(at: 2)))
                continue
            }
            guard !Tokenizer.semanticWords(command).contains(where: protected.contains) else { continue }
            let before = ns.substring(to: m.range.location)
            let after = ns.substring(from: NSMaxRange(m.range))
            let previous = Tokenizer.semanticWords(before).last ?? ""
            let next = Tokenizer.semanticWords(after).first ?? ""
            guard !nounLeads.contains(previous), !nounTails.contains(next) else { continue }
            let following = after.trimmingCharacters(in: .whitespacesAndNewlines)
            let sentenceBoundary = following.isEmpty || following.first.map { ".!?".contains($0) || $0.isUppercase } == true
            if isCompound(previous, command), !(command == "period" && sentenceBoundary &&
                (previous.hasSuffix("ing") || previous.hasSuffix("al")) && Tokenizer.semanticWords(before).count > 1) { continue }
            let nextIsCommand = commands.keys.contains { following.lowercased().hasPrefix($0) }
            if command == "period", before.trimmingCharacters(in: .whitespacesAndNewlines).last.map({ ".!?".contains($0) }) == true { continue }
            // Quoted words are literal, except explicit quote commands themselves.
            let quoteCount = before.filter { "\"“”".contains($0) }.count
            guard quoteCount % 2 == 0 || command.contains("quote") else { continue }
            // A sentence must precede bare single-token punctuation; at the start it is a noun.
            guard !before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || command.hasPrefix("open ") else { continue }
            let symbol = commands[command]!
            let live = t as NSString
            var range = m.range
            // Absorb matching ASR punctuation only next to a converted command.
            if [",", ".", "?", "!", ":", ";"].contains(symbol) {
                while range.location > 0 {
                    let ch = live.substring(with: NSRange(location: range.location - 1, length: 1))
                    guard ch == symbol || ch == " " || ch == "\t" else { break }
                    range.location -= 1; range.length += 1
                }
                while NSMaxRange(range) < live.length {
                    let ch = live.substring(with: NSRange(location: NSMaxRange(range), length: 1))
                    guard ch == symbol else { break }
                    range.length += 1
                }
            }
            // Only touch whitespace/casing next to this edit. Existing math and abbreviations
            // elsewhere in the utterance remain byte-for-byte unchanged.
            if symbol != "(" && symbol != "“" && symbol != "—" {
                while range.location > 0 && [" ", "\t"].contains(live.substring(with: NSRange(location: range.location - 1, length: 1))) {
                    range.location -= 1; range.length += 1
                }
            }
            var replacement = symbol
            var end = NSMaxRange(range)
            if symbol == "-" || symbol == "(" || symbol == "“" {
                while end < live.length && [" ", "\t"].contains(live.substring(with: NSRange(location: end, length: 1))) { range.length += 1; end += 1 }
            }
            if [".", "?", "!"].contains(symbol) && !nextIsCommand {
                while end < live.length && [" ", "\t"].contains(live.substring(with: NSRange(location: end, length: 1))) { range.length += 1; end += 1 }
                if end < live.length {
                    let letter = live.substring(with: NSRange(location: end, length: 1))
                    if letter.first?.isLetter == true { replacement += " " + letter.uppercased(); range.length += 1 }
                }
            }
            t = (t as NSString).replacingCharacters(in: range, with: replacement)
            if command == "period", sentenceBoundary, previous.hasSuffix("ing") || previous.hasSuffix("al"),
               let first = t.first, first.isLowercase {
                t = first.uppercased() + t.dropFirst()
            }
        }
        return t
    }
}
