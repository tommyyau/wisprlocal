import Foundation
import Testing
@testable import WisprLocalCore

@Suite struct HistoryIndexTests {
    private static let now = Date(timeIntervalSince1970: 1_796_000_000)
    private static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Europe/London")!
        return value
    }

    private static func synthetic(_ count: Int) -> [HistoryEntry] {
        (0..<count).map { i in
            let text = ["Café résumé", "HELLO world", "naïve façade", "plain text"][i % 4]
            var e = HistoryEntry(id: HistoryEntry.legacyID(for: Data("index-\(i)".utf8)),
                timestamp: now.addingTimeInterval(-Double(count - i) * 600), raw: text, final: text,
                audioDuration: 2, speechDuration: Double(i % 7 + 1) / 4, outcome: i % 17 == 0 ? .noSpeech : .inserted)
            if i % 13 == 0 { e.raw = "um " + text; e.frontmostApp = "com.apple.Notes" }
            if i % 31 == 0 { e.snippetTrigger = "plain trigger" }
            if !e.outcome.retainsContent { e.raw = ""; e.final = "" }
            if i % 23 == 0 { e.zeroFraction = 0.1 }
            return e
        }
    }

    private static func fixture(_ entries: [HistoryEntry]) throws -> (HistoryStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("history-index-\(UUID())")
        let store = HistoryStore(directory: root)
        try AppPaths.ensurePrivateDirectory(root)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        var data = Data()
        for entry in entries { data.append(try encoder.encode(entry)); data.append(10) }
        try AppPaths.writePrivate(data, to: store.fileURL)
        return (store, root)
    }

    @Test(arguments: [0, 1, 400, 10_000])
    func pagesPreserveFileOrderIncludingDuplicatesAndOutOfOrderTimestamps(count: Int) async throws {
        var source = Self.synthetic(count)
        if source.count > 10 {
            source.swapAt(2, source.count - 2)
            source.append(source[3])
            // UK autumn DST boundary, with equal wall-clock times on either side.
            source[5].timestamp = ISO8601DateFormatter().date(from: "2026-10-25T01:30:00Z")!
        }
        let (store, root) = try Self.fixture(source)
        defer { try? FileManager.default.removeItem(at: root) }
        if count > 0 {
            var lines = try Self.lines(of: store.fileURL)
            var legacy = try #require(try JSONSerialization.jsonObject(with: lines[0]) as? [String: Any])
            legacy["id"] = nil
            lines[0] = try JSONSerialization.data(withJSONObject: legacy, options: [.sortedKeys])
            var bytes = Data()
            for line in lines { bytes.append(line); bytes.append(10) }
            try AppPaths.writePrivate(bytes, to: store.fileURL)
        }
        let reference = store.readAll()
        let index = HistoryIndex(store: store, calendar: Self.calendar)
        await index.load(now: Self.now)
        var page = await index.page(now: Self.now)
        var previous: [HistoryEntry] = []
        var concatenated: [HistoryEntry] = []
        while page.hasMore {
            #expect(Array(page.entries.prefix(previous.count)) == previous)
            concatenated += page.entries.dropFirst(previous.count)
            previous = page.entries
            page = await index.page(moreDays: 7, now: Self.now)
        }
        concatenated += page.entries.dropFirst(previous.count)
        #expect(concatenated == reference.reversed().filter(HistoryIndex.visible))
        let completePage = page
        await MainActor.run {
            let presentation = HistoryPresentation(calendar: Self.calendar)
            presentation.setPage(completePage, now: Self.now)
            var oldGroups: [HistoryPresentation.DayGroup] = []
            for entry in completePage.entries {
                let title: String
                if Self.calendar.isDate(entry.timestamp, inSameDayAs: Self.now) { title = "Today" }
                else if Self.calendar.isDate(entry.timestamp, inSameDayAs: Self.calendar.date(byAdding: .day, value: -1, to: Self.now)!) { title = "Yesterday" }
                else {
                    // Format in the test calendar's zone, as the app does (HistoryPresentation), not the machine's.
                    var style = Date.FormatStyle.dateTime.weekday(.wide).month(.wide).day()
                    style.calendar = Self.calendar; style.timeZone = Self.calendar.timeZone
                    title = entry.timestamp.formatted(style)
                }
                if oldGroups.last?.title == title { oldGroups[oldGroups.count - 1].entries.append(entry) }
                else { oldGroups.append(.init(title: title, entries: [entry])) }
            }
            // Report only the first difference: printing 10,000 entries made a 26 MB CI log.
            let groups = presentation.groups
            let firstDiff = groups.indices.first { $0 < oldGroups.count && groups[$0] != oldGroups[$0] }
            #expect(groups.count == oldGroups.count && firstDiff == nil,
                    "day groups differ: counts \(groups.count) vs \(oldGroups.count); first differing group \(firstDiff.map { "\($0): \(groups[$0].title) (\(groups[$0].entries.count)) vs \(oldGroups[$0].title) (\(oldGroups[$0].entries.count))" } ?? "none")")
        }
        let all = await index.allEntries()
        #expect(all.count == reference.count && all == reference, "allEntries differ from the file (\(all.count) vs \(reference.count))")
    }

    /// The file's newline-separated lines as `Data`. Splits a byte array: `Data.split` is ambiguous under Swift 6.3.
    static func lines(of url: URL) throws -> [Data] {
        try [UInt8](Data(contentsOf: url)).split(separator: UInt8(ascii: "\n")).map { Data($0) }
    }

    @Test func recentArrivesBeforeCompletionAndStaysBounded() async throws {
        let (store, root) = try Self.fixture(Self.synthetic(50_000))
        defer { try? FileManager.default.removeItem(at: root) }
        let index = HistoryIndex(store: store, calendar: Self.calendar)
        let stream = await index.changes(now: Self.now)
        let start = ContinuousClock.now
        let load = Task { await index.load(now: Self.now) }
        var iterator = stream.makeAsyncIterator()
        guard case .loadedRecent(let recent)? = await iterator.next() else { Issue.record("Missing recent event"); return }
        let elapsed = start.duration(to: .now)
        // End to end this includes scheduling the load task. On a developer Mac (scale 1) the recent window must
        // arrive within 50 ms. Shared CI runners run the suite in parallel on few cores, so allow 5 s there: still
        // far below a regression to decoding the whole 50k-line file before publishing anything.
        #expect(elapsed < (TimingBudget.scale > 1 ? .seconds(5) : .milliseconds(50)))
        #expect(recent.page.entries.count >= 200)
        #expect(recent.page.entries.count < 500)
        guard case .loadedAll? = await iterator.next() else { Issue.record("Missing completion event"); return }
        await load.value
        // Best of five: a single reading includes an actor hop that a loaded test thread pool can delay.
        var bestStats = Duration.seconds(1)
        for _ in 0..<5 {
            let statsStart = ContinuousClock.now
            _ = await index.stats(now: Self.now)
            bestStats = min(bestStats, statsStart.duration(to: .now))
        }
        #expect(bestStats < .milliseconds(TimingBudget.scale))
        print("History index 50k recent: \(elapsed); cached bucket stats (best of 5): \(bestStats)")
    }

    @Test func searchMatchesLocalisedContains() async throws {
        var source = Self.synthetic(400)
        for text in ["Straße", "İstanbul", "œuvre", "Æther", "Kelvin", "Ångström", "γειά", "Ｃａｆｅ", "cafe\u{301}", "Strasse", "file", "staff", "st", "e\u{301}e", "a\u{308}a", "c\u{327}c"] {
            source.append(HistoryEntry(timestamp: Self.now, raw: text, final: text, outcome: .inserted))
        }
        let (store, root) = try Self.fixture(source)
        defer { try? FileManager.default.removeItem(at: root) }
        let index = HistoryIndex(store: store, calendar: Self.calendar)
        await index.load(now: Self.now)
        let entries = store.readAll()
        for query in ["", "cafe", "CAFÉ", "resume", "NAIVE", "façade", "Hello", "world", "é", "missing", "  plain  ",
                      "strasse", "istanbul", "oeuvre", "aether", "kelvin", "angstrom", "ΓΕΙΆ", "Ｃａｆｅ", "ß", "ẞ", "ﬁ", "ﬆ", "ﬅ", "\u{301}e", "\u{308}a", "\u{327}c"] {
            var page = await index.page(query: query, now: Self.now)
            while page.hasMore { page = await index.page(moreDays: 7, query: query, now: Self.now) }
            let q = query.trimmingCharacters(in: .whitespaces)
            let reference = entries.reversed().filter {
                q.isEmpty ? HistoryIndex.visible($0) : HistoryStats.counts($0) &&
                ($0.final.localizedCaseInsensitiveContains(q) || $0.raw.localizedCaseInsensitiveContains(q))
            }
            #expect(page.entries == reference, "Query: \(query)")
        }
    }

    @Test func statsAndInsightsMatchAfterSeededMutationsAndRollover() async throws {
        let (store, root) = try Self.fixture([])
        defer { try? FileManager.default.removeItem(at: root) }
        let index = HistoryIndex(store: store, calendar: Self.calendar)
        await index.load(now: Self.now)
        var entries: [HistoryEntry] = []
        var seed: UInt64 = 42
        for step in 0..<100 {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1
            let now = Self.now.addingTimeInterval(Double(step / 25) * 86_400)
            switch seed % 10 {
            case 0:
                await index.clear(now: now); entries = []
            case 1, 2:
                if let e = entries.first {
                    await index.delete(ids: [e.id], now: now); entries.removeAll { $0.id == e.id }
                }
            case 3:
                _ = await index.prune(retention: .hours24, now: now)
                entries = HistoryRetention.hours24.partition(entries, now: now).kept
            default:
                var e = Self.synthetic(100)[step]
                e.id = HistoryEntry.legacyID(for: Data("mutation-\(step)".utf8))
                await index.appendEntry(e, now: now); entries.append(e)
            }
            let stats = await index.stats(now: now)
            #expect(stats == HistoryStats(entries: entries, now: now, calendar: Self.calendar))
            let calculator = InsightsCalculator(calendar: Self.calendar); calculator.update(entries: entries)
            let snapshot = await index.snapshot(now: now)
            #expect(snapshot.insights == calculator.insights(now: now))
            #expect(snapshot.prunableCounts[.hours24] == HistoryRetention.hours24.partition(entries, now: now).pruned.count)
        }
        try await index.flush()
        #expect(store.readAll() == entries)
    }

    @Test func rawRewritePreservesLegacyAndUntouchedBytesAndConcurrentAppends() async throws {
        let source = Self.synthetic(400)
        let (store, root) = try Self.fixture(source)
        defer { try? FileManager.default.removeItem(at: root) }
        var lines = try Self.lines(of: store.fileURL)
        var legacy = try #require(try JSONSerialization.jsonObject(with: lines[0]) as? [String: Any])
        legacy["id"] = nil
        lines[0] = try JSONSerialization.data(withJSONObject: legacy, options: [.prettyPrinted, .sortedKeys])
            .filter { $0 != 10 } // Noncanonical spacing stays exactly as written.
        var bytes = Data()
        for line in lines { bytes.append(line); bytes.append(10) }
        try AppPaths.writePrivate(bytes, to: store.fileURL)
        let legacyID = HistoryEntry.legacyID(for: lines[0])
        let index = HistoryIndex(store: store)
        await index.load(now: Self.now)
        await index.delete(ids: [source[1].id, legacyID], now: Self.now)
        var appended = source[2]; appended.id = UUID()
        index.append(appended)
        try await index.flush()
        let after = try Self.lines(of: store.fileURL)
        #expect(Array(after.dropLast()) == Array(lines.dropFirst(2)))
        #expect(store.readAll().last == appended)
        #expect(!store.readAll().contains { $0.id == source[1].id || $0.id == legacyID })
    }

    @MainActor @Test func applyingAppendAndReadingHomeStatsStayWithinMainActorBudgets() async throws {
        let source = Self.synthetic(50_000)
        let (store, root) = try Self.fixture(source)
        defer { try? FileManager.default.removeItem(at: root) }
        let index = HistoryIndex(store: store, calendar: Self.calendar)
        await index.load(now: Self.now)
        let initial = await index.snapshot(now: Self.now)
        let presentation = HistoryPresentation(calendar: Self.calendar)
        // Exercise even a History screen which has already paged through the whole year.
        presentation.setPage(.init(entries: source.reversed().filter(HistoryIndex.visible)), now: Self.now)
        var entry = source.last!
        entry.id = UUID(); entry.timestamp = Self.now
        await index.appendEntry(entry, now: Self.now)
        let updated = await index.snapshot(now: Self.now)
        let start = ContinuousClock.now
        presentation.apply(.appended([entry], updated), now: Self.now)
        let elapsed = start.duration(to: .now)
        #expect(elapsed < .milliseconds(2 * TimingBudget.scale))
        #expect(presentation.recent.first == entry)
        #expect(presentation.groups.flatMap(\.entries).count == source.filter(HistoryIndex.visible).count + 1)
        let statsStart = ContinuousClock.now
        #expect(presentation.stats.totalDictations == initial.stats.totalDictations + 1)
        #expect(statsStart.duration(to: .now) < .milliseconds(TimingBudget.scale))
        print("History presentation 50k append: \(elapsed); Home stats: \(statsStart.duration(to: .now))")
        try await index.flush()
    }

    @Test func deleteAndAppendWhileLoadingNeverResurrectDeletedContent() async throws {
        let source = Self.synthetic(10_000)
        let (store, root) = try Self.fixture(source)
        defer { try? FileManager.default.removeItem(at: root) }
        let index = HistoryIndex(store: store)
        let stream = await index.changes(now: Self.now)
        let loading = Task { await index.load(now: Self.now) }
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
        await index.delete(ids: [source[0].id, source.last!.id], now: Self.now)
        var appended = source[1]; appended.id = UUID()
        await index.appendEntry(appended, now: Self.now)
        await loading.value
        try await index.flush()
        let memory = await index.allEntries()
        #expect(!memory.contains { $0.id == source[0].id || $0.id == source.last!.id })
        #expect(memory.filter { $0.id == appended.id }.count == 1)
        #expect(memory == store.readAll())
    }

    @Test func futureTimestampsAndPartialDayCutoffsUseExactBucketPrefixes() async throws {
        let now = Self.calendar.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 12))!
        var entries = Self.synthetic(400)
        for i in entries.indices { entries[i].timestamp = now.addingTimeInterval(Double((i * 137) % 400 - 200) * 60) }
        let (store, root) = try Self.fixture(entries)
        defer { try? FileManager.default.removeItem(at: root) }
        let index = HistoryIndex(store: store, calendar: Self.calendar)
        await index.load(now: now)
        for shift in [-86_400.0, -3_600, 0, 3_600, 86_400] {
            let time = now.addingTimeInterval(shift)
            #expect(await index.stats(now: time) == HistoryStats(entries: entries, now: time, calendar: Self.calendar))
            #expect(await index.prunableCount(retention: .hours24, now: time) == HistoryRetention.hours24.partition(entries, now: time).pruned.count)
        }
        let removed = Set(entries.enumerated().filter { $0.offset % 3 == 0 }.map { $0.element.id })
        await index.delete(ids: removed, now: now)
        entries.removeAll { removed.contains($0.id) }
        #expect(await index.stats(now: now) == HistoryStats(entries: entries, now: now, calendar: Self.calendar))
        try await index.flush()
    }

    @Test func clearDuringLoadingKeepsOnlySubsequentAppends() async throws {
        let source = Self.synthetic(10_000)
        let (store, root) = try Self.fixture(source)
        defer { try? FileManager.default.removeItem(at: root) }
        let index = HistoryIndex(store: store)
        let stream = await index.changes(now: Self.now)
        let loading = Task { await index.load(now: Self.now) }
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
        await index.clear(now: Self.now)
        var appended = source[1]; appended.id = UUID()
        await index.appendEntry(appended, now: Self.now)
        await loading.value
        try await index.flush()
        #expect(await index.allEntries() == [appended])
        #expect(store.readAll() == [appended])
    }


    @MainActor @Test func searchInvalidatesOlderDeletedPrunedAndClearedRows() async throws {
        var source = Self.synthetic(2_000)
        source[1].final = "old needle"
        let (store, root) = try Self.fixture(source)
        defer { try? FileManager.default.removeItem(at: root) }
        let index = HistoryIndex(store: store, calendar: Self.calendar)
        await index.load(now: Self.now)
        let presentation = HistoryPresentation(calendar: Self.calendar)
        presentation.apply(.loadedAll(await index.snapshot(now: Self.now)), now: Self.now)
        let recent = presentation.recent
        let search = await index.page(query: "needle", now: Self.now)
        presentation.setSearchPage(search, revision: presentation.revision)
        #expect(presentation.searchPage.entries.map(\.id) == [source[1].id])
        let oldRevision = presentation.revision
        await index.delete(ids: [source[1].id], now: Self.now)
        presentation.apply(.removed([source[1].id], await index.snapshot(now: Self.now)), now: Self.now)
        #expect(presentation.recent == recent)
        #expect(presentation.revision > oldRevision)
        #expect(presentation.searchPage.entries.isEmpty)
        #expect(!presentation.canOpen(source[1].id))
        presentation.setSearchPage(search, revision: oldRevision)
        #expect(presentation.searchPage.entries.isEmpty, "late search cannot resurrect a deleted row")
        #expect(await index.page(query: "needle", now: Self.now).entries.isEmpty)

        let match = HistoryEntry(timestamp: Self.now, final: "new needle", outcome: .inserted)
        await index.appendEntry(match, now: Self.now)
        let beforeAppend = presentation.revision
        presentation.apply(.appended([match], await index.snapshot(now: Self.now)), now: Self.now)
        #expect(presentation.revision > beforeAppend)
        presentation.setSearchPage(await index.page(query: "needle", now: Self.now), revision: presentation.revision)
        #expect(presentation.searchPage.entries == [match])
        let later = Self.now.addingTimeInterval(86_401)
        #expect(await index.prune(retention: .hours24, now: later) > 0)
        presentation.apply(.removed([match.id], await index.snapshot(now: later)), now: later)
        #expect(presentation.searchPage.entries.isEmpty && !presentation.canOpen(match.id))
        let clearMatch = HistoryEntry(timestamp: later, final: "clear needle", outcome: .inserted)
        await index.appendEntry(clearMatch, now: later)
        presentation.apply(.appended([clearMatch], await index.snapshot(now: later)), now: later)
        presentation.setSearchPage(.init(entries: [clearMatch]), revision: presentation.revision)
        #expect(presentation.searchPage.entries == [clearMatch])
        await index.clear(now: later)
        presentation.apply(.cleared(await index.snapshot(now: later)), now: later)
        #expect(!presentation.canOpen(clearMatch.id))
        #expect(presentation.searchPage.entries.isEmpty)
        #expect(await index.page(query: "needle", now: later).entries.isEmpty)
        try await index.flush()
    }

    @MainActor @Test func pruningOlderSearchMatchesInvalidatesUnchangedRecentWindow() async throws {
        var source = Self.synthetic(2_000)
        for i in source.indices { source[i].timestamp = Self.now.addingTimeInterval(-Double(source.count - i) * 60) }
        source[1].final = "prune needle"
        let (store, root) = try Self.fixture(source)
        defer { try? FileManager.default.removeItem(at: root) }
        let index = HistoryIndex(store: store, calendar: Self.calendar)
        await index.load(now: Self.now)
        let presentation = HistoryPresentation(calendar: Self.calendar)
        presentation.apply(.loadedAll(await index.snapshot(now: Self.now)), now: Self.now)
        let recent = presentation.recent
        presentation.setSearchPage(await index.page(query: "needle", now: Self.now), revision: presentation.revision)
        let revision = presentation.revision
        let removed = source.filter { $0.timestamp < HistoryRetention.hours24.cutoff(now: Self.now)! }.map(\.id)
        #expect(await index.prune(retention: .hours24, now: Self.now) == removed.count)
        presentation.apply(.removed(removed, await index.snapshot(now: Self.now)), now: Self.now)
        #expect(presentation.recent == recent)
        #expect(presentation.revision > revision)
        #expect(presentation.searchPage.entries.isEmpty)
        #expect(!presentation.canOpen(source[1].id))
        #expect(await index.page(query: "needle", now: Self.now).entries.isEmpty)
        try await index.flush()
    }

    @MainActor @Test func timeZoneChangeRebuildsBucketsGroupsAndInsights() async throws {
        let now = ISO8601DateFormatter().date(from: "2026-10-05T23:30:00Z")!
        let entries = [30.0, 20, 10, 3, 1].map {
            HistoryEntry(timestamp: now.addingTimeInterval(-$0 * 3_600), final: "a b c", speechDuration: 2, outcome: .inserted)
        }
        let (store, root) = try Self.fixture(entries)
        defer { try? FileManager.default.removeItem(at: root) }
        let index = HistoryIndex(store: store, calendar: Self.calendar)
        let presentation = HistoryPresentation(calendar: Self.calendar)
        await index.load(now: now)
        presentation.apply(.loadedAll(await index.snapshot(now: now)), now: now)
        #expect(presentation.stats.dictationsToday == 0)
        var tokyo = Self.calendar; tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        // The notification handler calls these same injected-calendar entry points.
        await index.calendarDidChange(calendar: tokyo, now: now)
        presentation.calendarDidChange(calendar: tokyo, now: now)
        presentation.apply(.loadedAll(await index.snapshot(now: now)), now: now)
        #expect(presentation.stats == HistoryStats(entries: entries, now: now, calendar: tokyo))
        #expect(presentation.stats.dictationsToday == 2)
        #expect(presentation.groups.first?.title == "Today")
        let calculator = InsightsCalculator(calendar: tokyo); calculator.update(entries: entries)
        #expect(presentation.insights == calculator.insights(now: now))
        let tomorrow = tokyo.date(byAdding: .day, value: 1, to: now)!
        await index.calendarDidChange(calendar: tokyo, now: tomorrow)
        presentation.calendarDidChange(calendar: tokyo, now: tomorrow)
        presentation.apply(.loadedAll(await index.snapshot(now: tomorrow)), now: tomorrow)
        #expect(presentation.groups.first?.title == "Yesterday")
        #expect(presentation.stats.dictationsToday == 0)
    }

    @MainActor @Test(arguments: ["Africa/Cairo", "America/Havana"])
    func midnightDSTYesterdayTitleParity(zone: String) throws {
        var calendar = Self.calendar; calendar.timeZone = try #require(TimeZone(identifier: zone))
        var day = try #require(calendar.date(from: DateComponents(year: 2025, month: 1, day: 1, hour: 12)))
        let stop = try #require(calendar.date(from: DateComponents(year: 2027, month: 1, day: 1)))
        var checked = 0
        while day < stop {
            if calendar.component(.hour, from: calendar.startOfDay(for: day)) != 0 {
                for shift in [0, 1] {
                    let now = try #require(calendar.date(byAdding: .day, value: shift, to: day))
                    let yesterday = try #require(calendar.date(byAdding: .day, value: -1, to: now))
                    let entries = (0..<48).map { HistoryEntry(timestamp: now.addingTimeInterval(-Double($0) * 3_600), final: "x", outcome: .inserted) }
                    let presentation = HistoryPresentation(calendar: calendar)
                    presentation.setPage(.init(entries: entries), now: now)
                    let titles = presentation.groups.flatMap { group in group.entries.map { _ in group.title } }
                    for (entry, title) in zip(entries, titles) {
                        if calendar.isDate(entry.timestamp, inSameDayAs: now) { #expect(title == "Today") }
                        else if calendar.isDate(entry.timestamp, inSameDayAs: yesterday) { #expect(title == "Yesterday") }
                        else { #expect(title != "Today" && title != "Yesterday") }
                    }
                    checked += 1
                }
            }
            day = try #require(calendar.date(byAdding: .day, value: 1, to: day))
        }
        #expect(checked >= 4)
    }

    @Test(arguments: [false, true])
    func partialLastLineDoesNotSwallowNextAppend(rewrite: Bool) async throws {
        let entries = Self.synthetic(3)
        let (store, root) = try Self.fixture(entries)
        defer { try? FileManager.default.removeItem(at: root) }
        var data = try Data(contentsOf: store.fileURL)
        data.append(Data(#"{"timestamp":"truncated"#.utf8))
        try AppPaths.writePrivate(data, to: store.fileURL)
        let index = HistoryIndex(store: store)
        await index.load(now: Self.now)
        if rewrite {
            await index.delete(ids: [entries[0].id], now: Self.now)
            try await index.flush()
            #expect(try Data(contentsOf: store.fileURL).last == 10)
        }
        let appended = HistoryEntry(timestamp: Self.now, final: "survives truncated tail", outcome: .inserted)
        await index.appendEntry(appended, now: Self.now)
        try await index.flush()
        let relaunched = HistoryIndex(store: store)
        await relaunched.load(now: Self.now)
        #expect(await relaunched.allEntries().last == appended)
        #expect(try Data(contentsOf: store.fileURL).last == 10)
    }

    @Test func failedRewriteIsReportedOnceAndLaterFlushSucceeds() async throws {
        let (store, root) = try Self.fixture(Self.synthetic(3))
        defer { try? FileManager.default.removeItem(at: root) }
        let index = HistoryIndex(store: store)
        await index.load(now: Self.now)
        try FileManager.default.removeItem(at: store.fileURL)
        try FileManager.default.createDirectory(at: store.fileURL, withIntermediateDirectories: false)
        await index.delete(ids: [Self.synthetic(3)[0].id], now: Self.now)
        await index.delete(ids: [Self.synthetic(3)[1].id], now: Self.now)
        var failed = false
        do { try await index.flush() } catch { failed = true }
        #expect(failed)
        try FileManager.default.removeItem(at: store.fileURL)
        let appended = HistoryEntry(timestamp: Self.now, final: "after recovery", outcome: .inserted)
        await index.appendEntry(appended, now: Self.now)
        try await index.flush()
        try await index.flush()
        #expect(store.readAll() == [appended])
    }

    @Test func onlyIndexCallsFullHistoryOperations() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources")
        let enumerator = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        let pattern = #"\b(?:readAll|readAllOnQueue|readRecent|writeAllOnQueue|legacyEntries|legacyPrune|legacyDelete|legacyClear|rawRewrite|waitForHistoryRewrite)\s*\(|\.replaceAll\s*\(|func\s+replaceAll\s*\(\s*with\b|\b(?:history|store|live\.history)\.removeAll\s*\(|func\s+removeAll\s*\([^)]*HistoryEntry"#
        let regex = try NSRegularExpression(pattern: pattern)
        for bypass in ["func readRecent(limit: Int)", "HistoryIndex.legacyEntries(history)",
                       "archive.replaceAll(with: entries)", "func replaceAll(with entries: [HistoryEntry])",
                       "func renamedWrapper() { archive.readAll() }", "store.rawRewrite(removing: ids)",
                       "func removeAll(where predicate: (HistoryEntry) -> Bool)"] {
            #expect(regex.firstMatch(in: bypass, range: NSRange(bypass.startIndex..., in: bypass)) != nil)
        }
        let indexSource = try String(contentsOf: sources.appendingPathComponent("WisprLocalCore/History/HistoryIndex.swift"), encoding: .utf8)
        let publicFullRead = try NSRegularExpression(pattern: #"public\s+func\s+(?:readAll|readRecent|replaceAll|removeAll)\s*\("#)
        #expect(publicFullRead.firstMatch(in: indexSource, range: NSRange(indexSource.startIndex..., in: indexSource)) == nil)
        for case let file as URL in enumerator where file.pathExtension == "swift" && file.lastPathComponent != "HistoryIndex.swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            // Include declarations and wrappers so an unused legacy API cannot bypass the guard.
            #expect(regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)) == nil,
                    "Full history I/O outside the index: \(file.lastPathComponent)")
        }
    }
}

extension HistoryIndexTests {
    @Test(arguments: [false, true])
    func failedRemovalRestoresRowsAndRetryPersists(clear: Bool) async throws {
        final class Failure: @unchecked Sendable {
            let lock = NSLock()
            var enabled = true
            func check() throws {
                if lock.withLock({ enabled }) { throw CocoaError(.fileWriteUnknown) }
            }
            func recover() { lock.withLock { enabled = false } }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("history-retry-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let failure = Failure()
        let store = HistoryStore(directory: root, beforeRewrite: { try failure.check() })
        let entry = HistoryEntry(timestamp: Date(timeIntervalSince1970: 1_796_000_000), final: "example words", outcome: .inserted)
        store.append(entry); store.flush()
        let index = HistoryIndex(store: store)
        await index.load()
        let stream = await index.changes()
        var events = stream.makeAsyncIterator()
        _ = await events.next()
        if clear { await index.clear() } else { await index.delete(ids: [entry.id]) }
        _ = await events.next()
        do { try await index.flush(); Issue.record("Expected rewrite failure") } catch {}
        let event = await events.next()
        if case .loadedAll(let snapshot) = event {
            #expect(snapshot.failedRemovalIDs == [entry.id])
            #expect(snapshot.page.entries == [entry])
        } else { Issue.record("Missing failure snapshot") }
        #expect(await index.allEntries() == [entry])
        failure.recover()
        await index.retryRemovals()
        try await index.flush()
        #expect(store.readAll().isEmpty)
        #expect(await index.allEntries().isEmpty)
        #expect(await index.snapshot().failedRemovalIDs.isEmpty)
    }
}
