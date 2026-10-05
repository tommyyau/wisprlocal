import Foundation

/// Dashboard numbers derived from `history.jsonl` (pure; unit-tested). Only dictations that
/// were actually inserted count — no-speech / blocked / failed attempts are ignored.
public struct HistoryStats: Sendable, Equatable {
    /// Typing speed the "time saved" estimate compares against.
    public static let typingWPM: Double = 40

    public var wordsThisWeek = 0
    public var totalWords = 0
    /// Words ÷ speaking minutes across all inserted dictations (0 when there's no speech yet).
    public var averageWPM = 0
    /// Typing the same words at `typingWPM`, minus the time spent speaking them. Never negative.
    public var timeSaved: TimeInterval = 0
    /// Consecutive days with ≥1 dictation, ending today (or yesterday, so the streak doesn't
    /// read 0 first thing in the morning).
    public var streakDays = 0
    public var dictationsToday = 0
    public var totalDictations = 0

    public init() {}

    public static func wordCount(_ s: String) -> Int {
        s.split { $0.isWhitespace || $0.isNewline }.count
    }

    public static func counts(_ e: HistoryEntry) -> Bool {
        e.outcome == .inserted && !e.final.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public init(entries: [HistoryEntry], now: Date = Date(), calendar: Calendar = .current) {
        let used = entries.filter(Self.counts)
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? now.addingTimeInterval(-7 * 86_400)
        let today = calendar.startOfDay(for: now)
        var speaking: TimeInterval = 0
        var days = Set<Date>()
        for e in used {
            let w = Self.wordCount(e.final)
            totalWords += w
            if e.timestamp >= weekStart, e.timestamp <= now.addingTimeInterval(60) { wordsThisWeek += w }
            if calendar.startOfDay(for: e.timestamp) == today { dictationsToday += 1 }
            // Prefer trimmed speech; older lines may only carry the raw capture length.
            speaking += e.speechDuration > 0 ? e.speechDuration : e.audioDuration
            days.insert(calendar.startOfDay(for: e.timestamp))
        }
        totalDictations = used.count
        if speaking >= 1 { averageWPM = Int((Double(totalWords) / (speaking / 60)).rounded()) }
        timeSaved = max(0, Double(totalWords) / Self.typingWPM * 60 - speaking)

        var day = days.contains(today) ? today : (calendar.date(byAdding: .day, value: -1, to: today) ?? today)
        while days.contains(day) {
            streakDays += 1
            guard let prev = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = prev
        }
    }
}
