import Foundation

/// Explicit standalone cancellation discards the current dictation. Inline cancellation only
/// discards the current clause (comma/semicolon boundary); ordinary phrases are left alone.
public enum DiscardCommand {
    static let pattern = try! NSRegularExpression(pattern:
        #"(?:^|(?<=[.!?\n,;]))[ \t]*(scratch that|never mind|forget that|strike that|cancel that)[ \t]*(?:[.!,;]|$)(?![ \t]*\?)"#, options: .caseInsensitive)
    public static func apply(_ text: String) -> String {
        var t = text
        for _ in 0..<50 {
            let original = t as NSString
            let matches = pattern.matches(in: t, range: NSRange(location: 0, length: original.length))
            var edited = false
            for m in matches {
                let before = original.substring(to: m.range.location)
                let after = original.substring(from: NSMaxRange(m.range)).trimmingCharacters(in: .whitespacesAndNewlines)
                let clauseCue = before.last == "," || before.last == ";"
                let prefix = clauseCue ? String(before.dropLast()) : before
                let boundary = clauseCue ? prefix.lastIndex(where: { ".!?\n;".contains($0) }) : nil
                let clause = boundary.map { String(prefix[prefix.index(after: $0)...]) } ?? prefix
                let words = Tokenizer.semanticWords(clause).filter { !["yes", "ok", "okay", "oh", "sure", "well", "hey"].contains($0) }
                guard words.count >= 3 || (!clauseCue && words.count >= 2) else { continue }
                let kept = boundary.map { String(prefix[...$0]) } ?? ""
                var replacement = after
                if kept.isEmpty || kept.last.map({ ".!?\n".contains($0) }) == true {
                    replacement = replacement.prefix(1).uppercased() + replacement.dropFirst()
                }
                t = kept + (kept.isEmpty || replacement.isEmpty ? "" : " ") + replacement
                edited = true
                break
            }
            if !edited { break }
        }
        return t
    }
}
