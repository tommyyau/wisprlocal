import Foundation

/// Shared lexical identity for deterministic cleanup and alignment projection.
public enum Tokenizer {
    public static func semanticWords(_ text: String) -> [String] {
        let re = Self.wordRegex
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range).lowercased().replacingOccurrences(of: "’", with: "'")
                .filter { $0.isLetter || $0.isNumber || $0 == "'" }
        }
    }

    static let wordRegex = try! NSRegularExpression(pattern: #"[\p{L}\p{N}]+(?:['’][\p{L}]+|[.,:]\d+)*"#)
    static let negators: Set<String> = ["not", "no", "never", "nor", "none", "nothing", "nobody", "neither", "without", "cannot"]
    static func isNegator(_ word: String) -> Bool {
        negators.contains(word) || word.hasSuffix("n't")
    }
    static let tokenRegex = try! NSRegularExpression(pattern:
        #"[+\-−]?(?:\d[\d,]*(?:[.:]\d+)*|\.\d+)(?:[-–]\d+(?:[.:]\d+)*)?[A-Za-z%]*|[\p{L}\p{N}]+(?:['’ʼ‘][\p{L}]+)*|[\p{Sc}\p{Sm}°+=<>#%&@*/^~|\\]|[-–]"#)
}
