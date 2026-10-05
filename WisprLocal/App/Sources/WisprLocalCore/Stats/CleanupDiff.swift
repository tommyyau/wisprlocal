import Foundation
import WisprLocalStatsC

/// Edits WisprLocal made between what was heard (`raw`) and what was typed (`final`).
public struct CleanupCounts: Sendable, Equatable {
    /// Hesitations and verbal fillers taken out ("um", "uh", ", like,", ", you know,").
    public var fillers = 0
    /// Heard words swapped for different words (Dictionary replacements such as
    /// "cooper netties" → "Kubernetes").
    public var dictionary = 0
    /// Punctuation, capitalisation, spoken numbers → digits, line breaks and lists, voice commands.
    public var formatting = 0

    public var total: Int { fillers + dictionary + formatting }

    public init(fillers: Int = 0, dictionary: Int = 0, formatting: Int = 0) {
        self.fillers = fillers; self.dictionary = dictionary; self.formatting = formatting
    }

    public static func + (a: CleanupCounts, b: CleanupCounts) -> CleanupCounts {
        CleanupCounts(fillers: a.fillers + b.fillers, dictionary: a.dictionary + b.dictionary, formatting: a.formatting + b.formatting)
    }
    public static func - (a: CleanupCounts, b: CleanupCounts) -> CleanupCounts {
        CleanupCounts(fillers: a.fillers - b.fillers, dictionary: a.dictionary - b.dictionary, formatting: a.formatting - b.formatting)
    }
}

/// Deterministic word-level diff of raw vs final, classified into `CleanupCounts`.
///
/// Rules (pure, no dictionary needed, so it also works for old history lines):
/// - Words are whitespace-separated tokens; a token's *core* is its letters and digits, lowercased.
/// - Cores are aligned with an LCS (common prefix/suffix trimmed first, so typical entries cost
///   almost nothing).
/// - An aligned word whose surface differs ("the" → "The", "again" → "again.") = 1 formatting edit.
/// - A removed filler word = 1 filler edit ("you know" counts once).
/// - A run of other removed words replaced by new words = 1 dictionary edit, unless the new words
///   carry digits (spoken numbers → "25"), which is formatting.
/// - Other runs that only remove words (voice commands such as "new line") or only add them
///   (list numbers, bullets) = 1 formatting edit each.
/// - Each added line break = 1 formatting edit; punctuation-only tokens added ("-", "•") = 1 each.
public enum CleanupDiff {
    /// Whitespace-separated word count (ASCII whitespace; same tokens the diff uses).
    public static func wordCount(_ s: String) -> Int {
        var s = s
        return s.withUTF8 { Int(wl_word_count($0.baseAddress, $0.count)) }
    }

    /// Edits for one dictation. Equal strings cost one comparison.
    public static func counts(raw: String, final: String) -> CleanupCounts {
        counts(raw: raw, final: final, finalWords: nil)
    }

    /// Same, also reporting the final text's word count (saves a second pass).
    static func counts(raw: String, final: String, finalWords: UnsafeMutablePointer<Int>?) -> CleanupCounts {
        if raw == final || raw.isEmpty {
            finalWords?.pointee = wordCount(final)
            return CleanupCounts()
        }
        var raw = raw, final = final
        let c = raw.withUTF8 { r in final.withUTF8 { f in wl_cleanup_diff(r.baseAddress, r.count, f.baseAddress, f.count) } }
        finalWords?.pointee = Int(c.final_words)
        return CleanupCounts(fillers: Int(c.fillers), dictionary: Int(c.dictionary), formatting: Int(c.formatting))
    }
}
