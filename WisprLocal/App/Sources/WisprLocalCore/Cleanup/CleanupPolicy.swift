import Foundation

/// Decides whether the (slow, 0.5–4 s) Foundation Models formatter runs for an utterance.
///
/// History showed FM cleanup cost 0.3–4.5 s whenever it ran and the strict `OutputGuard` often
/// rejected the result anyway (the RuleCleaner text was used) — latency paid for nothing.
/// Parakeet already punctuates, and the guard only lets FM change punctuation, casing and list
/// layout, so the model is only worth calling when:
/// - the user turned on "AI formatting (lists & punctuation)" (OFF by default), or
/// - AUTO mode: deterministic LIST cues are present ("first … second …", "number one",
///   "bullet point", "one, two, three", repeated "new line"), where layout can actually help.
/// Pure + unit-tested (STRUCTURAL: the pipeline routes through `decide`).
public enum CleanupPolicy {
    public enum Decision: Equatable, Sendable {
        /// Deterministic RuleCleaner only.
        case rules
        /// The user's FM cleaner (setting ON).
        case model
        /// Setting OFF but list cues found: the auto formatter.
        case autoModel(cue: String)
    }

    /// Hard ceiling for any FM call on the dictation path. The per-call timeout is
    /// min(adaptive formula, this).
    public static let maxModelTimeout: Duration = .milliseconds(1500)

    public static func modelTimeout(_ formula: Duration) -> Duration { min(formula, maxModelTimeout) }

    /// - Parameters:
    ///   - text: the transcript after dictionary replacement (before cleanup).
    ///   - userEnabled: the "AI formatting" setting (the configured cleaner is the FM one).
    ///   - autoAvailable: an auto formatter exists.
    public static func decide(text: String, userEnabled: Bool, autoAvailable: Bool) -> Decision {
        if userEnabled { return .model }
        guard autoAvailable, let cue = listCue(in: text) else { return .rules }
        return .autoModel(cue: cue)
    }

    /// The first deterministic list cue found (a short label for history), nil when none.
    public static func listCue(in text: String) -> String? {
        let words = tokens(text)
        guard words.count >= 3 else { return nil }
        let joined = " " + words.joined(separator: " ") + " "

        // "bullet point(s)" / "next bullet" / "numbered list" / "new bullet"
        for phrase in ["bullet point", "next bullet", "new bullet", "numbered list", "bulleted list", "bullet list"]
            where joined.contains(" \(phrase)") { return phrase }
        // "number one … number two" or "point one … point two" / "item one … item two"
        for lead in ["number", "point", "item", "step"] {
            let seq = ordinalSequence(words, after: lead)
            if seq >= 2 { return "\(lead) one/two" }
        }
        // "first(ly) … second(ly)" (+ optionally third…)
        let firsts: Set<String> = ["first", "firstly"], seconds: Set<String> = ["second", "secondly"]
        if let i = words.firstIndex(where: firsts.contains),
           words[(i + 1)...].contains(where: seconds.contains) { return "first/second" }
        // "one, two, three" enumerations: three ADJACENT counting words (punctuation ignored).
        // Counting words spread through prose ("one of the two…") deliberately don't count.
        if countingRun(words) >= 3 { return "one/two/three" }
        if numeralMarkers(text) >= 2 { return "1./2." }
        // "new line" said two or more times (a dictated multi-line layout)
        if occurrences(of: " new line ", in: joined) + occurrences(of: " next line ", in: joined) >= 2 { return "new line ×2" }
        return nil
    }

    // MARK: helpers

    static let counting = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]

    static func tokens(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "'") }).map(String.init)
    }

    static func value(_ w: String) -> Int? {
        if let i = counting.firstIndex(of: w) { return i + 1 }
        if let n = Int(w), (1...20).contains(n) { return n }
        return nil
    }

    /// Longest run "lead 1 … lead 2 … lead 3" with increasing values starting at 1.
    static func ordinalSequence(_ words: [String], after lead: String) -> Int {
        var expected = 1
        for (i, w) in words.enumerated() where w == lead && i + 1 < words.count {
            if value(words[i + 1]) == expected { expected += 1 }
        }
        return expected - 1
    }

    /// Longest run of ADJACENT counting words 1,2,3… ("one two three").
    static func countingRun(_ words: [String]) -> Int {
        var best = 0, run = 0, expected = 1
        for w in words {
            if let v = value(w), v == expected { run += 1; expected += 1 }
            else if value(w) == 1 { run = 1; expected = 2 }
            else { run = 0; expected = 1 }
            best = max(best, run)
        }
        return best
    }

    /// "1." / "1)" markers in increasing order (1., 2., …) — numerals at a list position.
    static func numeralMarkers(_ text: String) -> Int {
        var expected = 1
        let scalars = Array(text)
        var i = 0
        while i < scalars.count {
            if scalars[i].isNumber, i == 0 || !scalars[i - 1].isNumber {
                var j = i; var num = ""
                while j < scalars.count, scalars[j].isNumber { num.append(scalars[j]); j += 1 }
                if j < scalars.count, scalars[j] == "." || scalars[j] == ")",
                   j + 1 >= scalars.count || scalars[j + 1] == " ",
                   Int(num) == expected { expected += 1 }
                i = j
            } else { i += 1 }
        }
        return expected - 1
    }

    static func occurrences(of needle: String, in hay: String) -> Int {
        var n = 0, r = hay.startIndex..<hay.endIndex
        while let f = hay.range(of: needle, range: r) { n += 1; r = hay.index(before: f.upperBound)..<hay.endIndex }
        return n
    }
}
