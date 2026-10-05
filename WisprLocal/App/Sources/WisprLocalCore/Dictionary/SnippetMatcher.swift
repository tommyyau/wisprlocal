import Foundation

/// Whole-utterance snippet matching. A snippet fires ONLY when the entire (cleaned) utterance,
/// compared case- and punctuation-insensitively, equals its trigger or "insert <trigger>".
/// It never fires mid-sentence ("send my email to Sam" does not expand "my email").
public enum SnippetMatcher {
    /// Lowercase, fold typographic apostrophes, drop punctuation/symbols (apostrophes inside words
    /// are dropped too, so "what's" == "whats"), collapse whitespace.
    public static func normalise(_ s: String) -> String {
        var out = ""
        var pendingSpace = false
        for ch in s.lowercased() {
            if ch.isLetter || ch.isNumber {
                if pendingSpace && !out.isEmpty { out.append(" ") }
                pendingSpace = false
                out.append(ch)
            } else if ch == "'" || ch == "\u{2019}" {
                continue
            } else {
                pendingSpace = true
            }
        }
        return out
    }

    public static func match(_ utterance: String, snippets: [Snippet]) -> Snippet? {
        let u = normalise(utterance)
        guard !u.isEmpty else { return nil }
        let candidates = [u, u.hasPrefix("insert ") ? String(u.dropFirst("insert ".count)) : nil].compactMap { $0 }
        for s in snippets {
            let t = normalise(s.trigger)
            guard !t.isEmpty else { continue }
            if candidates.contains(t) { return s }
        }
        return nil
    }
}
