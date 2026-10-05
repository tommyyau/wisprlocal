import Foundation

/// Opt-in backtrack ("Coffee at 2, actually 3" → "Coffee at 3"). OFF by default.
///
/// Deterministic and deliberately narrow. A correction is applied ONLY when all hold:
/// - a cue — "actually", "no", "sorry", "I mean", "make that", "or rather" — sits DIRECTLY between
///   two short slot values, separated by nothing but spaces and commas;
/// - both values are the SAME type: a time ("2", "two thirty", "3:30", "3 pm" after at/by/…),
///   a number or amount ("5", "$5", "five", "50%"), a weekday, a month, or a single name;
/// - the two values differ;
/// - a name is not the first word of a sentence and the restated name ends the clause
///   (end of text or punctuation follows), so "Thanks Sam, sorry Alex couldn't come" is left alone.
/// Everything else stays verbatim: "I actually think so", "No, I don't", "Tuesday, no, 3".
/// Only the first value and the cue are removed; the restated value and all other words stay.
public enum Backtrack {
    public enum SlotType: Equatable, Sendable { case time, number, weekday, month, name }

    public struct Result: Equatable, Sendable {
        public var text: String
        public var applied: Bool
    }

    static let cues = ["actually", "no", "sorry", "i mean", "make that", "or rather"]

    static let numberWords: Set<String> = [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve",
        "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen", "twenty", "thirty",
        "forty", "fifty", "sixty", "seventy", "eighty", "ninety", "hundred",
    ]
    static let hourWords: Set<String> = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve"]
    static let weekdays: Set<String> = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
    static let months: Set<String> = ["January", "February", "March", "April", "May", "June", "July", "August",
                                      "September", "October", "November", "December"]
    /// Capitalised words that are never a name slot.
    static let notNames: Set<String> = [
        "I", "I'm", "I'll", "I'd", "I've", "The", "A", "An", "OK", "Okay", "Yes", "No", "Sorry", "Actually", "Make",
        "Or", "And", "But", "So", "Then", "Thanks", "Please", "It", "We", "You", "He", "She", "They", "This", "That",
    ]

    /// A number with thousands separators ("1,000", "$1,200.50", "2,000,000") is ONE token and is
    /// tried first (R7: "1,000, no, 2,000" → "2,000", never "1,2,000").
    private static let token = "(?:[$£€]?\\d{1,3}(?:,\\d{3})+(?:\\.\\d+)?%?(?![\\p{L}\\p{N}])|[$£€]?[\\p{L}\\p{N}][\\p{L}\\p{N}:'’%]*(?:\\.\\d+)?%?)"
    private static let suffix = "(?:[ ](?:o'clock|o’clock|fifteen|thirty|forty[- ]five|am|pm|a\\.m\\.|p\\.m\\.))?"
    private static let value = "(" + token + suffix + ")"
    private static let pattern: NSRegularExpression = {
        let cue = "(actually|no|sorry|i mean|make that|or rather)"
        let sep = "(?:[ ]*,[ ]*|[ ]+)"
        // Never start inside "1,000" (after "digit,") nor end before ",000" / ".5".
        return try! NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}'’$£€.:-])(?<!\\d,)" + value + sep + cue + sep + value
                                        + "(?![\\p{L}\\p{N}'’%-])(?![.,]\\d)",
                                        options: [.caseInsensitive])
    }()
    private static let timePreposition = try! NSRegularExpression(
        pattern: "(?:^|[^\\p{L}])(?:at|by|until|till|til|from|around|before|after|for)[ ]+$", options: [.caseInsensitive])

    /// Applies every unambiguous correction (repeatedly, so "2, no, 3, no, 4" → "4").
    public static func apply(_ input: String) -> Result {
        var t = input
        var applied = false
        var searchFrom = 0
        var guardCount = 0
        while guardCount < 50, let m = pattern.firstMatch(in: t, range: NSRange(location: searchFrom, length: (t as NSString).length - searchFrom)) {
            guardCount += 1
            let ns = t as NSString
            let v1 = ns.substring(with: m.range(at: 1)), v2 = ns.substring(with: m.range(at: 3))
            let before = ns.substring(to: m.range.location)
            let after = ns.substring(from: m.range.location + m.range.length)
            if accepts(v1: v1, v2: v2, before: before, after: after) {
                var replacement = v2
                if atSentenceStart(before), let f = replacement.first, f.isLowercase {
                    replacement = f.uppercased() + replacement.dropFirst()
                }
                t = before + replacement + after
                applied = true
                searchFrom = 0  // a chain may now match at the same place
            } else {
                searchFrom = m.range.location + 1
            }
        }
        return Result(text: t, applied: applied)
    }

    static func accepts(v1: String, v2: String, before: String, after: String) -> Bool {
        guard v1.lowercased() != v2.lowercased() else { return false }
        let timeContext = timePreposition.firstMatch(in: before, range: NSRange(location: 0, length: (before as NSString).length)) != nil
        guard let t1 = type(of: v1, timeContext: timeContext), let t2 = type(of: v2, timeContext: false) else { return false }
        let same: Bool
        switch (t1, t2) {
        case (.time, .number):
            same = isPlainNumber(v2)  // "at 2:30, actually 3": a bare number restates the time
        case (.number, .time):
            same = isPlainNumber(v1) && timeContext
        default:
            same = t1 == t2
        }
        guard same else { return false }
        if t1 == .name {
            if atSentenceStart(before) { return false }
            let next = after.first
            if let next, !".,!?;:".contains(next) { return false }
        }
        return true
    }

    static func atSentenceStart(_ before: String) -> Bool {
        let b = before.trimmingCharacters(in: .whitespaces)
        guard let last = b.last else { return true }
        return ".!?\n".contains(last)
    }

    static func isPlainNumber(_ v: String) -> Bool {
        let l = v.lowercased()
        if numberWords.contains(l) { return true }
        return l.allSatisfy(\.isNumber)
    }

    static func type(of v: String, timeContext: Bool) -> SlotType? {
        let lower = v.lowercased()
        let parts = lower.split(separator: " ").map(String.init)
        // Times: "3:30", "3 pm", "3pm", "two thirty", "five o'clock".
        if parts.count == 2 {
            let h = parts[0]  // the minute part is guaranteed by the pattern's suffix
            let hourOK = hourWords.contains(h) || (Int(h).map { (1...12).contains($0) } ?? false)
            return hourOK ? .time : nil
        }
        if parts.count != 1 { return nil }
        if lower.range(of: "^\\d{1,2}:\\d{2}$", options: .regularExpression) != nil { return .time }
        if lower.range(of: "^\\d{1,2}(am|pm)$", options: .regularExpression) != nil { return .time }
        if lower == "noon" || lower == "midnight" { return .time }
        // Numbers and amounts.
        if lower.range(of: "^[$£€]?\\d+(?:[.,]\\d+)*%?$", options: .regularExpression) != nil
            || numberWords.contains(lower) {
            return timeContext ? .time : .number
        }
        if weekdays.contains(lower) { return .weekday }
        if months.contains(v) { return .month }  // capitalised only: "may", "march" are verbs
        // A single name: Capitalised letters (apostrophes allowed), not a common word.
        if v.count > 1, let f = v.first, f.isUppercase,
           v.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "’" }),
           v.dropFirst().contains(where: \.isLowercase), !notNames.contains(v) {
            return .name
        }
        return nil
    }
}
