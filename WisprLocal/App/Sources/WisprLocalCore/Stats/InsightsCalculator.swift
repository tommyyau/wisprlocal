import Foundation

/// One category's share of dictations (Insights › "Where you dictate").
public struct CategoryUsage: Sendable, Equatable, Identifiable {
    public var category: AppCategory
    public var dictations: Int
    public var words: Int
    /// Share of all dictations, 0…1.
    public var fraction: Double
    /// Most-used apps in this category (bundle ID, dictations), most first, at most 5.
    public var topApps: [AppUsage]
    public var id: AppCategory { category }
}

public struct AppUsage: Sendable, Equatable, Identifiable {
    public var bundleID: String
    public var dictations: Int
    public var words: Int
    public var id: String { bundleID }
    mutating func add(_ w: Int) { dictations += 1; words += w }
}

/// Words and dictations on one calendar day.
public struct DayActivity: Sendable, Equatable {
    public var words = 0
    public var dictations = 0
}

/// Everything the Insights page shows. Pure value; built by `InsightsCalculator`.
public struct Insights: Sendable, Equatable {
    /// The typing speed comparisons use (same as `HistoryStats.typingWPM`).
    public static let typingWPM: Double = HistoryStats.typingWPM

    public var totalWords = 0
    public var totalDictations = 0
    /// Total speaking time of the counted dictations, seconds.
    public var speakingSeconds: TimeInterval = 0
    /// Words ÷ speaking minutes (0 until there's at least a second of speech).
    public var averageWPM = 0
    /// `averageWPM / typingWPM` (0 when there's no speech yet).
    public var timesFasterThanTyping: Double { averageWPM > 0 ? Double(averageWPM) / Self.typingWPM : 0 }
    /// Typing the same words at `typingWPM`, minus the time spent speaking them. Never negative.
    public var timeSaved: TimeInterval { max(0, Double(totalWords) / Self.typingWPM * 60 - speakingSeconds) }

    /// Words dictated this calendar month, up to now.
    public var wordsThisMonth = 0
    /// Words dictated last month up to the same day of the month (a like-for-like comparison).
    public var wordsLastMonthToDate = 0
    /// Words dictated in the whole of last month.
    public var wordsLastMonth = 0
    /// This month vs the same point last month, as a fraction (+0.24 = 24 % more). nil when
    /// last month has no dictations to compare with.
    public var monthChange: Double? {
        guard wordsLastMonth > 0, wordsLastMonthToDate > 0 else { return nil }
        return Double(wordsThisMonth - wordsLastMonthToDate) / Double(wordsLastMonthToDate)
    }

    public var cleanup = CleanupCounts()
    /// Categories with at least one dictation, most used first (ties: `AppCategory` order).
    public var categories: [CategoryUsage] = []
    /// Distinct frontmost apps dictated into (unknown app excluded).
    public var appsUsed = 0

    /// Start of day → activity, for days with at least one dictation.
    public var days: [Date: DayActivity] = [:]
    /// Consecutive days with a dictation, ending today (or yesterday).
    public var currentStreak = 0
    /// First day of the current streak (nil when the streak is 0).
    public var currentStreakStart: Date?
    public var longestStreak = 0
    /// Word-count thresholds for heat levels 2, 3 and 4 (level 1 is any activity): the 25th,
    /// 50th and 75th percentiles of active days.
    public var heatThresholds: [Int] = [1, 1, 1]

    /// 0 (no dictation) … 4 (busiest quarter of your active days).
    public func heatLevel(words: Int) -> Int {
        guard words > 0 else { return 0 }
        var level = 1
        for t in heatThresholds where words > t { level += 1 }
        return min(4, level)
    }

    public init() {}
}

/// Fast, cached, incremental Insights over `history.jsonl` entries.
///
/// - `update(entries:)` with the same array plus new entries appended ingests only the new ones;
///   anything else (delete, clear, reorder) rebuilds from scratch, reusing the per-entry cleanup
///   cache (keyed by entry id) so a rebuild never re-diffs text.
/// - `insights(now:)` is O(active days + apps) and cached until the data or the day changes.
/// - Only entries `HistoryStats.counts` accepts are counted (inserted, non-empty), so refused /
///   outcome-only entries (SEC-2: no text) never contribute.
public final class InsightsCalculator: @unchecked Sendable {
    private let calendar: Calendar
    private let lock = NSLock()

    // Accumulators
    private var processed = 0
    private var lastID: UUID?
    private var totalWords = 0
    private var totalDictations = 0
    private var speaking: TimeInterval = 0
    private var cleanup = CleanupCounts()
    private var days: [Date: DayActivity] = [:]
    private var apps: [String: AppUsage] = [:]
    private var cleanupCache: [UUID: (counts: CleanupCounts, words: Int)] = [:]
    private var revision = 0
    /// Cached day interval for chronological ingestion (avoids a Calendar call per entry).
    private var dayCache: DateInterval?

    private var snapshot: (revision: Int, day: Date, value: Insights)?

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    /// Number of full rebuilds (tests).
    public private(set) var rebuilds = 0

    /// Brings the accumulators up to date with `entries` (oldest first, as `HistoryStore.readAll`).
    public func update(entries: [HistoryEntry]) {
        lock.lock(); defer { lock.unlock() }
        if entries.count == processed, entries.last?.id == lastID { return }
        let appendOnly = entries.count > processed && (processed == 0 || entries[processed - 1].id == lastID)
        if !appendOnly { reset() }
        for i in processed..<entries.count { ingest(entries[i]) }
        flushRun()
        processed = entries.count
        lastID = entries.last?.id
        revision &+= 1
    }

    /// HistoryIndex supplies deltas, so deletion never re-ingests the surviving file.
    public func append(entries: [HistoryEntry]) {
        lock.withLock {
            for entry in entries { ingest(entry) }
            flushRun(); processed += entries.count
            if let last = entries.last { lastID = last.id }
            revision &+= 1
        }
    }

    public func remove(entries: [HistoryEntry], lastRemainingID: UUID?) {
        lock.withLock {
            for entry in entries where entry.outcome == .inserted {
                var words: Int
                if entry.snippetTrigger == nil, entry.raw != entry.final, let hit = cleanupCache[entry.id] {
                    cleanup = cleanup - hit.counts; words = hit.words
                } else { words = CleanupDiff.wordCount(entry.final) }
                guard words > 0 else { continue }
                totalWords -= words; totalDictations -= 1
                speaking -= entry.speechDuration > 0 ? entry.speechDuration : entry.audioDuration
                let day = dayStart(entry.timestamp)
                days[day]?.words -= words; days[day]?.dictations -= 1
                if days[day]?.dictations == 0 { days[day] = nil }
                if let app = entry.frontmostApp, !app.isEmpty {
                    apps[app]?.words -= words; apps[app]?.dictations -= 1
                    if apps[app]?.dictations == 0 { apps[app] = nil }
                }
            }
            if totalDictations == 0 { speaking = 0 }
            processed -= entries.count; lastID = lastRemainingID; revision &+= 1
        }
    }

    public func clear() {
        lock.withLock { reset(); cleanupCache = [:]; revision &+= 1 }
    }

    private func reset() {
        if processed > 0 { rebuilds += 1 }
        processed = 0; lastID = nil
        totalWords = 0; totalDictations = 0; speaking = 0
        cleanup = CleanupCounts(); days = [:]; apps = [:]
    }

    private func dayStart(_ d: Date) -> Date {
        if let c = dayCache, d >= c.start, d < c.end { return c.start }
        let interval = calendar.dateInterval(of: .day, for: d) ?? DateInterval(start: calendar.startOfDay(for: d), duration: 86_400)
        dayCache = interval
        return interval.start
    }

    /// Same-day run being accumulated (entries arrive oldest first), flushed into `days`.
    private var runDay: Date?
    private var run = DayActivity()

    private func flushRun() {
        if let d = runDay, run.dictations > 0 {
            days[d, default: DayActivity()].words += run.words
            days[d, default: DayActivity()].dictations += run.dictations
        }
        runDay = nil; run = DayActivity()
    }

    private func ingest(_ e: HistoryEntry) {
        guard e.outcome == .inserted else { return }
        // Snippets expand a trigger: that's not cleanup.
        var words = 0
        if e.snippetTrigger == nil, e.raw != e.final {
            if let hit = cleanupCache[e.id] {
                cleanup = cleanup + hit.counts; words = hit.words
            } else {
                let c = withUnsafeMutablePointer(to: &words) { CleanupDiff.counts(raw: e.raw, final: e.final, finalWords: $0) }
                cleanupCache[e.id] = (c, words)
                cleanup = cleanup + c
            }
        } else {
            words = CleanupDiff.wordCount(e.final)
        }
        // Same rule as `HistoryStats.counts`: inserted and not blank.
        guard words > 0 else { return }
        totalWords += words
        totalDictations += 1
        speaking += e.speechDuration > 0 ? e.speechDuration : e.audioDuration

        let day = dayStart(e.timestamp)
        if day != runDay { flushRun(); runDay = day }
        run.words += words
        run.dictations += 1

        if let id = e.frontmostApp, !id.isEmpty {
            apps[id, default: AppUsage(bundleID: id, dictations: 0, words: 0)].add(words)
        }
    }

    /// The Insights snapshot as of `now`.
    public func insights(now: Date) -> Insights {
        lock.lock(); defer { lock.unlock() }
        let today = calendar.startOfDay(for: now)
        if let s = snapshot, s.revision == revision, s.day == today { return s.value }
        let v = build(now: now, today: today)
        snapshot = (revision, today, v)
        return v
    }

    private func build(now: Date, today: Date) -> Insights {
        var r = Insights()
        r.totalWords = totalWords
        r.totalDictations = totalDictations
        r.speakingSeconds = speaking
        if speaking >= 1 { r.averageWPM = Int((Double(totalWords) / (speaking / 60)).rounded()) }
        r.cleanup = cleanup
        r.days = days

        // Months: this month to date vs last month to the same day.
        if let thisMonth = calendar.dateInterval(of: .month, for: now),
           let lastStart = calendar.date(byAdding: .month, value: -1, to: thisMonth.start),
           let lastMonth = calendar.dateInterval(of: .month, for: lastStart) {
            let dayOfMonth = calendar.component(.day, from: now)
            let lastToDateEnd = min(lastMonth.end, calendar.date(byAdding: .day, value: dayOfMonth, to: lastMonth.start) ?? lastMonth.end)
            for (d, a) in days {
                if d >= thisMonth.start && d < thisMonth.end && d <= now { r.wordsThisMonth += a.words }
                if d >= lastMonth.start && d < lastMonth.end {
                    r.wordsLastMonth += a.words
                    if d < lastToDateEnd { r.wordsLastMonthToDate += a.words }
                }
            }
        }

        // Categories.
        var byCat: [AppCategory: (dictations: Int, words: Int, apps: [AppUsage])] = [:]
        var unknown = (dictations: 0, words: 0)
        for (_, a) in apps {
            let c = AppCategoryMap.category(for: a.bundleID)
            byCat[c, default: (0, 0, [])].dictations += a.dictations
            byCat[c, default: (0, 0, [])].words += a.words
            byCat[c, default: (0, 0, [])].apps.append(a)
        }
        let known = apps.values.reduce(0) { $0 + $1.dictations }
        if totalDictations > known {
            unknown.dictations = totalDictations - known
            byCat[.other, default: (0, 0, [])].dictations += unknown.dictations
        }
        let order = Dictionary(uniqueKeysWithValues: AppCategory.allCases.enumerated().map { ($1, $0) })
        r.categories = byCat.map { c, v in
            CategoryUsage(category: c, dictations: v.dictations, words: v.words,
                          fraction: totalDictations > 0 ? Double(v.dictations) / Double(totalDictations) : 0,
                          topApps: Array(v.apps.sorted { ($0.dictations, $1.bundleID) > ($1.dictations, $0.bundleID) }.prefix(5)))
        }
        .sorted { $0.dictations != $1.dictations ? $0.dictations > $1.dictations : order[$0.category]! < order[$1.category]! }
        r.appsUsed = apps.count

        // Streaks.
        let sorted = days.keys.sorted()
        var longest = 0, run = 0
        var prev: Date?
        for d in sorted {
            if let p = prev, let next = calendar.date(byAdding: .day, value: 1, to: p), calendar.isDate(next, inSameDayAs: d) {
                run += 1
            } else {
                run = 1
            }
            longest = max(longest, run)
            prev = d
        }
        r.longestStreak = longest
        var day = days[today] != nil ? today : (calendar.date(byAdding: .day, value: -1, to: today) ?? today)
        var start: Date?
        while days[day] != nil {
            r.currentStreak += 1
            start = day
            guard let p = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = calendar.startOfDay(for: p)
        }
        r.currentStreakStart = start

        // Heat thresholds: quartiles of active days' word counts.
        let counts = days.values.map(\.words).sorted()
        if !counts.isEmpty {
            func q(_ p: Double) -> Int { counts[min(counts.count - 1, Int(Double(counts.count - 1) * p))] }
            r.heatThresholds = [q(0.25), q(0.5), q(0.75)]
        }
        return r
    }

    /// One-shot convenience (no caching across calls).
    public static func insights(entries: [HistoryEntry], now: Date, calendar: Calendar = .current) -> Insights {
        let c = InsightsCalculator(calendar: calendar)
        c.update(entries: entries)
        return c.insights(now: now)
    }
}
