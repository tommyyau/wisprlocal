import Foundation
import Testing
@testable import WisprLocalCore

/// Insights: cleanup diff categories, app categories, months, streaks, incremental cache, speed.
struct InsightsTests {
    static let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/London")!
        return c
    }()

    static func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    static func entry(_ at: Date, raw: String? = nil, _ final: String, app: String? = "com.apple.Notes",
                      speech: TimeInterval = 3, outcome: HistoryEntry.Outcome = .inserted, snippet: String? = nil) -> HistoryEntry {
        var e = HistoryEntry(timestamp: at, raw: raw ?? final, final: final, engine: "t", cleaner: "rules",
                             audioDuration: speech + 0.5, speechDuration: speech, frontmostApp: app, outcome: outcome)
        e.snippetTrigger = snippet
        return e
    }

    // MARK: cleanup diff

    @Test func identicalTextHasNoEdits() {
        #expect(CleanupDiff.counts(raw: "Hello there.", final: "Hello there.") == CleanupCounts())
        #expect(CleanupDiff.counts(raw: "", final: "Anything") == CleanupCounts())
    }

    @Test func fillerDictionaryAndFormattingAreSeparated() {
        let c = CleanupDiff.counts(
            raw: "um the cooper netties cluster is healthy again root cause was an expired certificate on the ingress",
            final: "The Kubernetes cluster is healthy again. Root cause was an expired certificate on the ingress.")
        #expect(c.fillers == 1)            // um
        #expect(c.dictionary == 1)         // cooper netties → Kubernetes
        #expect(c.formatting == 4)         // The, again., Root, ingress.
        #expect(c.total == 6)
    }

    @Test func youKnowCountsOnceAndLikeIsAFiller() {
        let c = CleanupDiff.counts(raw: "It was, you know, fine and, like, quick.", final: "It was fine and quick.")
        #expect(c.fillers == 2)
        #expect(c.dictionary == 0)
        #expect(c.formatting == 2)          // "was," → "was", "and," → "and"
    }

    @Test func spokenNumbersAndListsAreFormatting() {
        #expect(CleanupDiff.counts(raw: "it took twenty five minutes", final: "it took 25 minutes")
                == CleanupCounts(formatting: 1))
        let list = CleanupDiff.counts(raw: "buy milk eggs bread", final: "Buy:\n- milk\n- eggs\n- bread")
        #expect(list.dictionary == 0 && list.fillers == 0)
        #expect(list.formatting == 2 /* Buy, Buy: */ - 1 + 3 /* newlines */ + 3 /* bullets */)
    }

    @Test func caseOnlyChangeIsFormatting() {
        #expect(CleanupDiff.counts(raw: "swiftui is great", final: "SwiftUI is great") == CleanupCounts(formatting: 1))
    }

    @Test func wordCountMatchesHistoryStatsForPlainText() {
        for s in ["", "one", "  two  words ", "line\nbreak\tand tab", "Hi Sam, thanks.\n\nBest"] {
            #expect(CleanupDiff.wordCount(s) == HistoryStats.wordCount(s), "\(s)")
        }
    }

    // MARK: categories

    @Test func bundleIDsMapToCategories() {
        #expect(AppCategoryMap.category(for: "com.anthropic.claudefordesktop") == .ai)
        #expect(AppCategoryMap.category(for: "com.apple.dt.Xcode") == .code)
        #expect(AppCategoryMap.category(for: "com.jetbrains.intellij") == .code)
        #expect(AppCategoryMap.category(for: "com.tinyspeck.slackmacgap") == .messages)
        #expect(AppCategoryMap.category(for: "com.microsoft.Outlook") == .email)
        #expect(AppCategoryMap.category(for: "notion.id") == .docs)
        #expect(AppCategoryMap.category(for: "com.google.Chrome.canary") == .browser)
        #expect(AppCategoryMap.category(for: "com.example.unknown") == .other)
        #expect(AppCategoryMap.category(for: nil) == .other)
        #expect(AppCategoryMap.category(for: "com.example.unknown", overrides: ["com.example.unknown": .docs]) == .docs)
    }

    @Test func categoriesShareCountsAndApps() {
        let d = Self.date(2026, 10, 2)
        let entries = [
            Self.entry(d, "one two", app: "com.openai.chat"),
            Self.entry(d, "three", app: "com.openai.chat"),
            Self.entry(d, "four five six", app: "com.anthropic.claudefordesktop"),
            Self.entry(d, "seven", app: "com.apple.mail"),
            Self.entry(d, "refused", app: "com.apple.mail", outcome: .blockedBySecureInput),
        ]
        let r = InsightsCalculator.insights(entries: entries, now: d, calendar: Self.cal)
        #expect(r.totalDictations == 4)
        #expect(r.appsUsed == 3)
        #expect(r.categories.map(\.category) == [.ai, .email])
        #expect(r.categories[0].dictations == 3 && r.categories[0].words == 6)
        #expect(abs(r.categories[0].fraction - 0.75) < 1e-9)
        #expect(r.categories[0].topApps.map(\.bundleID) == ["com.openai.chat", "com.anthropic.claudefordesktop"])
    }

    // MARK: totals, months, streaks

    @Test func wpmAndTypingComparison() {
        let d = Self.date(2026, 10, 2)
        // 120 words over 60 s of speech = 120 wpm = 3× typing.
        let words = Array(repeating: "word", count: 60).joined(separator: " ")
        let r = InsightsCalculator.insights(entries: [Self.entry(d, words, speech: 30), Self.entry(d, words, speech: 30)],
                                            now: d, calendar: Self.cal)
        #expect(r.averageWPM == 120)
        #expect(r.timesFasterThanTyping == 3)
        #expect(r.totalWords == 120)
    }

    @Test func monthChangeComparesLikeForLike() {
        let now = Self.date(2026, 10, 10)
        let entries = [
            Self.entry(Self.date(2026, 9, 3), "a b c d"),          // last month, before the 10th
            Self.entry(Self.date(2026, 9, 25), "e f g h i j"),     // last month, after the 10th
            Self.entry(Self.date(2026, 10, 2), "k l m"),
            Self.entry(Self.date(2026, 10, 9), "n o p q r"),
        ]
        let r = InsightsCalculator.insights(entries: entries, now: now, calendar: Self.cal)
        #expect(r.wordsThisMonth == 8)
        #expect(r.wordsLastMonthToDate == 4)
        #expect(r.wordsLastMonth == 10)
        #expect(r.monthChange == 1.0)
    }

    @Test func monthChangeHiddenWithoutLastMonth() {
        let now = Self.date(2026, 10, 10)
        let r = InsightsCalculator.insights(entries: [Self.entry(Self.date(2026, 10, 2), "hello")], now: now, calendar: Self.cal)
        #expect(r.monthChange == nil)
    }

    @Test func streaksCurrentAndLongest() {
        let now = Self.date(2026, 10, 10, 9)
        var entries: [HistoryEntry] = []
        for d in [1, 2, 3, 4, 5] { entries.append(Self.entry(Self.date(2026, 9, d), "x")) }   // 5-day run
        for d in [7, 8, 9] { entries.append(Self.entry(Self.date(2026, 10, d), "x")) }       // ends yesterday
        let r = InsightsCalculator.insights(entries: entries, now: now, calendar: Self.cal)
        #expect(r.longestStreak == 5)
        #expect(r.currentStreak == 3)
        #expect(r.currentStreakStart == Self.cal.startOfDay(for: Self.date(2026, 10, 7)))
        // A gap of two days breaks the current streak.
        let later = InsightsCalculator.insights(entries: entries, now: Self.date(2026, 10, 12), calendar: Self.cal)
        #expect(later.currentStreak == 0 && later.currentStreakStart == nil)
    }

    @Test func streakSurvivesDSTChange() {
        // UK clocks go back on 25 Oct 2026.
        let entries = (23...27).map { Self.entry(Self.date(2026, 10, $0, 1), "x") }
        let r = InsightsCalculator.insights(entries: entries, now: Self.date(2026, 10, 27, 20), calendar: Self.cal)
        #expect(r.currentStreak == 5 && r.longestStreak == 5)
    }

    @Test func heatLevels() {
        var i = Insights()
        i.heatThresholds = [10, 20, 40]
        #expect(i.heatLevel(words: 0) == 0)
        #expect(i.heatLevel(words: 5) == 1)
        #expect(i.heatLevel(words: 15) == 2)
        #expect(i.heatLevel(words: 30) == 3)
        #expect(i.heatLevel(words: 500) == 4)
    }

    @Test func snippetsAndRefusalsAreNotCleanup() {
        let d = Self.date(2026, 10, 2)
        let entries = [
            Self.entry(d, raw: "sign off", "Thanks,\nAlex", snippet: "sign off"),
            Self.entry(d, raw: "", "", outcome: .blockedBySecureInput),
            Self.entry(d, raw: "um hello", "Hello"),
        ]
        let r = InsightsCalculator.insights(entries: entries, now: d, calendar: Self.cal)
        #expect(r.cleanup == CleanupCounts(fillers: 1, formatting: 1))
    }

    // MARK: incremental + speed

    static func synthetic(_ n: Int, from start: Date) -> [HistoryEntry] {
        let apps = ["com.apple.mail", "com.tinyspeck.slackmacgap", "com.openai.chat", "com.apple.dt.Xcode",
                    "com.apple.Safari", "com.apple.Notes", "com.example.other", "com.anthropic.claudefordesktop"]
        let raws = ["um so the cooper netties cluster is healthy again root cause was an expired certificate",
                    "hey team quick update the beta build is in testflight please try it and tell me what breaks",
                    "remember to book the train for monday and pick up the parcel",
                    "it took like twenty five minutes you know to get there"]
        let finals = ["The Kubernetes cluster is healthy again. Root cause was an expired certificate.",
                      "Hey team, quick update: the beta build is in TestFlight. Please try it and tell me what breaks.",
                      "remember to book the train for monday and pick up the parcel",
                      "It took 25 minutes to get there."]
        return (0..<n).map { i in
            let k = i % raws.count
            return entry(start.addingTimeInterval(Double(i) * 1_700), raw: raws[k], finals[k], app: apps[i % apps.count],
                         speech: 4 + Double(i % 5), outcome: i % 37 == 0 ? .focusChanged : .inserted)
        }
    }

    @Test func incrementalEqualsFullRebuild() {
        let all = Self.synthetic(600, from: Self.date(2026, 3, 1))
        let now = all.last!.timestamp
        let inc = InsightsCalculator(calendar: Self.cal)
        inc.update(entries: Array(all.prefix(250)))
        _ = inc.insights(now: now)
        inc.update(entries: Array(all.prefix(400)))
        inc.update(entries: all)
        #expect(inc.rebuilds == 0)
        let full = InsightsCalculator.insights(entries: all, now: now, calendar: Self.cal)
        #expect(inc.insights(now: now) == full)

        // A deletion rebuilds (and matches a fresh calculation).
        var fewer = all
        fewer.remove(at: 100)
        inc.update(entries: fewer)
        #expect(inc.rebuilds == 1)
        #expect(inc.insights(now: now) == InsightsCalculator.insights(entries: fewer, now: now, calendar: Self.cal))
    }

    @Test func tenThousandEntriesUnderFiftyMilliseconds() {
        let all = Self.synthetic(10_000, from: Self.date(2026, 3, 1))
        let now = all.last!.timestamp
        // Thread CPU time (not wall clock), best of five cold runs: other suites running in
        // parallel can't make this flaky, and it still measures the full cold computation.
        func cpuNow() -> UInt64 { clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) }
        var best = Double.infinity
        var result = Insights()
        for _ in 0..<5 {
            let t0 = cpuNow()
            result = InsightsCalculator.insights(entries: all, now: now, calendar: Self.cal)
            best = min(best, Double(cpuNow() - t0) / 1e6)
        }
        #expect(result.totalDictations > 9_000)
        #expect(best < 50, "cold insights over 10k entries took \(best) ms")

        // Appending one entry to a warm calculator is far cheaper still.
        let warm = InsightsCalculator(calendar: Self.cal)
        warm.update(entries: all)
        _ = warm.insights(now: now)
        var more = all
        more.append(Self.entry(now.addingTimeInterval(60), raw: "um one more", "One more."))
        let t0 = cpuNow()
        warm.update(entries: more)
        _ = warm.insights(now: now.addingTimeInterval(60))
        let incMs = Double(cpuNow() - t0) / 1e6
        #expect(incMs < 10, "incremental update took \(incMs) ms")
    }
}
