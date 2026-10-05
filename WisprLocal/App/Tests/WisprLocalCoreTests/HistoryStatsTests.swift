import Testing
import Foundation
@testable import WisprLocalCore

@Suite struct HistoryStatsTests {
    static var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.firstWeekday = 2  // Monday
        return c
    }
    // Thursday 2026-10-01 15:00 UTC
    static let now = ISO8601DateFormatter().date(from: "2026-10-01T15:00:00Z")!

    static func e(_ daysAgo: Int, _ text: String, speech: TimeInterval = 6, outcome: HistoryEntry.Outcome = .inserted) -> HistoryEntry {
        var x = HistoryEntry(timestamp: now.addingTimeInterval(-Double(daysAgo) * 86_400 - 60), raw: text, final: text,
                             audioDuration: speech + 1, speechDuration: speech, outcome: outcome)
        x.frontmostApp = "com.apple.TextEdit"
        return x
    }

    @Test func emptyHistoryIsAllZero() {
        let s = HistoryStats(entries: [], now: Self.now, calendar: Self.cal)
        #expect(s == HistoryStats())
    }

    @Test func countsOnlyInsertedDictations() {
        let entries = [
            Self.e(0, "one two three four five six seven eight nine ten", speech: 4),
            Self.e(0, "ignored words here", outcome: .noSpeech),
            Self.e(0, "blocked words", outcome: .blockedByConflict),
            Self.e(0, "   ", speech: 1),
        ]
        let s = HistoryStats(entries: entries, now: Self.now, calendar: Self.cal)
        #expect(s.totalWords == 10)
        #expect(s.totalDictations == 1)
        #expect(s.dictationsToday == 1)
        #expect(s.averageWPM == 150)  // 10 words / (4 s / 60)
        // Typing 10 words at 40 WPM = 15 s, minus 4 s speaking.
        #expect(abs(s.timeSaved - 11) < 0.001)
    }

    @Test func weekAndStreak() {
        let entries = [
            Self.e(0, "a b"), Self.e(1, "c d e"), Self.e(2, "f"),   // Thu, Wed, Tue → this week
            Self.e(4, "g h i j"),                                  // Sun → last week, breaks streak gap at day 3
        ]
        let s = HistoryStats(entries: entries, now: Self.now, calendar: Self.cal)
        #expect(s.wordsThisWeek == 6)
        #expect(s.totalWords == 10)
        #expect(s.streakDays == 3)
    }

    @Test func streakSurvivesUntilTodaysFirstDictation() {
        let s = HistoryStats(entries: [Self.e(1, "x"), Self.e(2, "y")], now: Self.now, calendar: Self.cal)
        #expect(s.streakDays == 2)
        #expect(s.dictationsToday == 0)
        let lapsed = HistoryStats(entries: [Self.e(2, "y")], now: Self.now, calendar: Self.cal)
        #expect(lapsed.streakDays == 0)
    }

    @Test func timeSavedNeverNegative() {
        let s = HistoryStats(entries: [Self.e(0, "slow", speech: 30)], now: Self.now, calendar: Self.cal)
        #expect(s.timeSaved == 0)
    }

    @Test func deleteAndClearRewriteTheFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hist-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = HistoryStore(directory: dir)
        let a = Self.e(2, "first"), b = Self.e(1, "second"), c = Self.e(0, "third")
        [a, b, c].forEach(store.append)
        store.flush()
        #expect(store.readAll().count == 3)
        try store.delete(b)
        #expect(store.readAll().map(\.final) == ["first", "third"])
        store.append(Self.e(0, "fourth"))
        #expect(store.readAll().map(\.final) == ["first", "third", "fourth"])
        try store.clearAll()
        #expect(store.readAll().isEmpty)
        try store.clearAll()  // idempotent
    }
}

@Suite struct HistoryRewriteRaceTests {

    @Test func appendDuringFilterSurvivesAtomicRewrite() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hist-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = HistoryStore(directory: dir)
        let old = HistoryStatsTests.e(10, "old"), kept = HistoryStatsTests.e(0, "kept"), added = HistoryStatsTests.e(0, "new")
        store.append(old); store.append(kept)
        let removed = try store.removeAll { entry in
            if entry.id == old.id { store.append(added); return true }
            return false
        }
        #expect(removed.map(\.id) == [old.id])
        #expect(store.readAll().map(\.id) == [kept.id, added.id])
    }

    @Test func concurrentAppendsSurviveRetentionCaller() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("retention-race-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = HistoryStore(directory: dir)
        let clips = DebugRecordingStore(directory: dir.appendingPathComponent("clips"), isEnabled: { false })
        let library = HistoryLibrary(history: store, recordings: clips)
        let old = HistoryStatsTests.e(10, "old")
        let added = (0..<200).map { HistoryStatsTests.e(0, "new \($0)") }
        store.append(old)
        // Exercise the index retention path used by the app.
        await library.index.load(now: HistoryStatsTests.now)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { for entry in added { await library.index.appendEntry(entry); await Task.yield() } }
            group.addTask {
                for _ in added {
                    _ = await library.index.prune(retention: .days7, now: HistoryStatsTests.now)
                    await Task.yield()
                }
            }
            try await group.waitForAll()
        }
        try await library.index.flush()
        #expect(await library.index.allEntries().map(\.id) == added.map(\.id))
        #expect(store.readAll().map(\.id) == added.map(\.id))
    }

}
