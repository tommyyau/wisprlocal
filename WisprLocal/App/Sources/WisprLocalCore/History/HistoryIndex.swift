import Foundation

/// The live history's I/O and decoded data stay on this actor. Screens receive bounded pages
/// and already-calculated numbers, never a full-file read on the main actor.
public actor HistoryIndex: HistoryWriting {
    public struct Page: Sendable, Equatable {
        public var entries: [HistoryEntry]
        public var hasMore: Bool
        public init(entries: [HistoryEntry] = [], hasMore: Bool = false) {
            self.entries = entries; self.hasMore = hasMore
        }
    }

    public struct Snapshot: Sendable {
        public var failedRemovalIDs: Set<UUID> = []
        public var page: Page
        public var stats: HistoryStats
        public var insights: Insights
        /// Last measured dictations, oldest first (unmeasured attempts don't displace them).
        public var diagnostics: [HistoryEntry]
        public var prunableCounts: [HistoryRetention: Int]
        public init(page: Page, stats: HistoryStats, insights: Insights, diagnostics: [HistoryEntry],
                    prunableCounts: [HistoryRetention: Int]) {
            self.page = page; self.stats = stats; self.insights = insights; self.diagnostics = diagnostics
            self.prunableCounts = prunableCounts
        }
    }

    public enum Change: Sendable {
        case loadedRecent(Snapshot)
        case loadedAll(Snapshot)
        case appended([HistoryEntry], Snapshot)
        case removed([UUID], Snapshot)
        case cleared(Snapshot)
    }

    private let store: HistoryStore
    private let recordings: DebugRecordingStore?
    private var calendar: Calendar
    private var entries: [HistoryEntry] = []
    private var folded: [(final: String, raw: String)] = []
    private var buckets: [Date: Bucket] = [:]
    private var insightsEngine: InsightsCalculator
    private var subscribers: [UUID: AsyncStream<Change>.Continuation] = [:]
    private var loading: Task<Void, Never>?
    private var lastSweepCount = 0
    private var recentLoaded = false
    private var allLoaded = false
    private var appendedDuringLoad: [HistoryEntry] = []
    private var removedDuringLoad = Set<UUID>()
    private var clearedDuringLoad = false
    private var loadedDays = 0
    private var searchDays = 0
    private var searchQuery = ""
    private var measuredRecent: [HistoryEntry] = []
    private var lastPageHasMore = false
    private var failedRemovalIDs = Set<UUID>()
    private var rewrites: [Task<Void, Error>] = []
    // HistoryWriting is synchronous. A serial bridge preserves submission order without ever
    // blocking the caller; flush also drains this bridge before awaiting the disk queue.
    private nonisolated let submissions = DispatchQueue(label: "wisprlocal.history.index.submissions")

    private struct Bucket {
        var entries: [HistoryEntry] = []
        var count = 0
        var words = 0
        var dictations = 0
        var speaking: Double = 0
        var countedTimes: [Date] = []
        var wordPrefix = [0]
        var timestamps: [Date] = []

        static func bound(_ dates: [Date], _ date: Date, inclusive: Bool = false) -> Int {
            var low = 0, high = dates.count
            while low < high {
                let mid = (low + high) / 2
                if dates[mid] < date || (inclusive && dates[mid] == date) { low = mid + 1 }
                else { high = mid }
            }
            return low
        }

        mutating func add(_ entry: HistoryEntry) {
            entries.append(entry); count += 1
            let position = Self.bound(timestamps, entry.timestamp, inclusive: true)
            timestamps.insert(entry.timestamp, at: position)
            guard HistoryStats.counts(entry) else { return }
            let words = HistoryStats.wordCount(entry.final)
            self.words += words; dictations += 1
            speaking += entry.speechDuration > 0 ? entry.speechDuration : entry.audioDuration
            let countedPosition = Self.bound(countedTimes, entry.timestamp, inclusive: true)
            countedTimes.insert(entry.timestamp, at: countedPosition)
            wordPrefix.insert(wordPrefix[countedPosition], at: countedPosition + 1)
            for i in (countedPosition + 1)..<wordPrefix.count { wordPrefix[i] += words }
        }

        func words(from lower: Date, through upper: Date) -> Int {
            let first = Self.bound(countedTimes, lower), last = Self.bound(countedTimes, upper, inclusive: true)
            return last >= first ? wordPrefix[last] - wordPrefix[first] : 0
        }
    }

    public init(store: HistoryStore, recordings: DebugRecordingStore? = nil, calendar: Calendar = .autoupdatingCurrent) {
        self.store = store; self.recordings = recordings; self.calendar = calendar
        insightsEngine = InsightsCalculator(calendar: calendar)
    }

    /// Rebucket in-memory history after a system time-zone change or day rollover.
    public func calendarDidChange(calendar: Calendar = .autoupdatingCurrent, now: Date = Date()) {
        self.calendar = calendar
        insightsEngine = InsightsCalculator(calendar: calendar)
        rebuild()
        emit(.loadedAll(snapshot(now: now)))
    }

    @discardableResult
    public func sweepOrphans(cutoff: Date = Date()) async -> Int {
        if !allLoaded { await load(now: cutoff); return lastSweepCount }
        return recordings?.sweep(keeping: Set(entries.map(\.id)), cutoff: cutoff) ?? 0
    }

    public func changes(now: Date = Date()) -> AsyncStream<Change> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Change>.makeStream()
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.unsubscribe(id) } }
        if recentLoaded { continuation.yield(allLoaded ? .loadedAll(snapshot(now: now)) : .loadedRecent(snapshot(now: now))) }
        return stream
    }

    private func unsubscribe(_ id: UUID) { subscribers[id] = nil }
    private func emit(_ change: Change) { for c in subscribers.values { c.yield(change) } }

    public func load(now: Date = Date()) async {
        if let loading { await loading.value; return }
        let task = Task { await self.performLoad(now: now) }
        loading = task
        await task.value
    }

    private func performLoad(now: Date) async {
        // A seek reads only the newest chunks, even in a multi-year file.
        store.flush()
        let tail = Self.readTail(store.fileURL, now: now, calendar: calendar)
        entries = tail
        rebuild()
        recentLoaded = true
        emit(.loadedRecent(snapshot(now: now)))
        // Let subscribers paint the tail while the remaining decode runs independently.
        let store = self.store
        let full = await Task.detached(priority: .utility) { store.readAll() }.value
        entries = clearedDuringLoad ? [] : full.filter { !removedDuringLoad.contains($0.id) }
        // The full read may already contain a pending append. Account for occurrences, not just
        // ids: identical duplicate lines remain identical duplicate rows.
        var occurrences: [UUID: Int] = [:]
        for e in entries { occurrences[e.id, default: 0] += 1 }
        for e in appendedDuringLoad where !removedDuringLoad.contains(e.id) {
            if occurrences[e.id, default: 0] > 0 { occurrences[e.id, default: 0] -= 1 }
            else { entries.append(e) }
        }
        appendedDuringLoad = []; removedDuringLoad = []
        rebuild()
        allLoaded = true
        emit(.loadedAll(snapshot(now: now)))
        if let recordings {
            let ids = Set(entries.map(\.id))
            lastSweepCount = await Task.detached(priority: .utility) { recordings.sweep(keeping: ids, cutoff: now) }.value
        }
    }

    public nonisolated func append(_ entry: HistoryEntry) {
        submissions.async {
            let done = DispatchSemaphore(value: 0)
            Task { await self.appendEntry(entry); done.signal() }
            done.wait()
        }
    }

    public func appendEntry(_ entry: HistoryEntry, now: Date = Date()) {
        store.append(entry)
        if !allLoaded { appendedDuringLoad.append(entry) }
        entries.append(entry); folded.append(Self.fold(entry)); addToBucket(entry)
        if entry.zeroFraction != nil { measuredRecent = Array((measuredRecent + [entry]).suffix(MicAudioDiagnostics.window)) }
        insightsEngine.append(entries: [entry])
        emit(.appended([entry], snapshot(now: now, includePage: false)))
    }

    public func delete(ids: Set<UUID>, now: Date = Date()) async {
        await load(now: now)
        guard !ids.isEmpty else { return }
        if !allLoaded { removedDuringLoad.formUnion(ids) }
        var kept: [HistoryEntry] = [], keptFolded: [(final: String, raw: String)] = [], removed: [HistoryEntry] = []
        for (i, entry) in entries.enumerated() {
            if ids.contains(entry.id) { removed.append(entry) }
            else { kept.append(entry); keptFolded.append(folded[i]) }
        }
        entries = kept; folded = keptFolded
        let affected = Set(removed.map { calendar.startOfDay(for: $0.timestamp) })
        for day in affected {
            let remaining = buckets[day]?.entries.filter { !ids.contains($0.id) } ?? []
            buckets[day] = nil
            for entry in remaining { addToBucket(entry) }
        }
        measuredRecent = Array(entries.lazy.filter { $0.zeroFraction != nil }.suffix(MicAudioDiagnostics.window))
        insightsEngine.remove(entries: removed, lastRemainingID: entries.last?.id)
        // Publish before starting the rewrite. Store's append queue orders the atomic rename
        // before later appends, so no append can be overwritten by the replacement file.
        emit(.removed(Array(ids), snapshot(now: now)))
        scheduleRewrite(ids: ids)
        recordings?.delete(ids: Array(ids))
    }

    public func clear(now: Date = Date()) async {
        await load(now: now)
        let ids = Set(entries.map(\.id))
        if !allLoaded { clearedDuringLoad = true; appendedDuringLoad = [] }
        entries = []; folded = []; buckets = [:]; measuredRecent = []
        insightsEngine.clear(); loadedDays = 0; searchDays = 0
        emit(.cleared(snapshot(now: now)))
        scheduleRewrite(ids: ids, clearAll: true)
        recordings?.deleteAll()
    }

    @discardableResult
    public func prune(retention: HistoryRetention, now: Date = Date()) async -> Int {
        await load(now: now)
        guard let cutoff = retention.cutoff(now: now) else { return 0 }
        let ids = Set(entries.lazy.filter { $0.timestamp < cutoff }.map(\.id))
        let count = entries.filter { ids.contains($0.id) }.count
        await delete(ids: ids, now: now)
        return count
    }

    private func scheduleRewrite(ids: Set<UUID>, clearAll: Bool = false) {
        let store = self.store
        // Enqueue immediately, before another actor operation can submit an append.
        let work = store.rawRewrite(removing: clearAll ? nil : ids)
        rewrites.append(Task {
            do {
                try await work.value
                self.failedRemovalIDs.subtract(ids)
                self.emit(.loadedAll(self.snapshot(now: Date())))
            } catch {
                self.failedRemovalIDs.formUnion(ids)
                self.entries = store.readAll()
                self.rebuild()
                self.emit(.loadedAll(self.snapshot(now: Date())))
                throw error
            }
        })
    }

    public func retryRemovals() async {
        let ids = failedRemovalIDs
        await delete(ids: ids)
    }

    public func flush() async throws {
        await withCheckedContinuation { continuation in submissions.async { continuation.resume() } }
        let pending = rewrites
        rewrites = []
        var failure: Error?
        for task in pending {
            do { try await task.value } catch { if failure == nil { failure = error } }
        }
        store.flush()
        if let failure { throw failure }
    }

    public func page(moreDays: Int = 0, query: String = "", now: Date = Date()) -> Page {
        if query.trimmingCharacters(in: .whitespaces).isEmpty { loadedDays += moreDays }
        else {
            if searchQuery != query { searchQuery = query; searchDays = 0 }
            searchDays += moreDays
        }
        let page = makePage(query: query, now: now)
        if query.trimmingCharacters(in: .whitespaces).isEmpty { lastPageHasMore = page.hasMore }
        return page
    }

    public func snapshot(now: Date = Date()) -> Snapshot { snapshot(now: now, includePage: true) }

    private func snapshot(now: Date, includePage: Bool) -> Snapshot {
        var counts: [HistoryRetention: Int] = [:]
        for r in HistoryRetention.allCases { counts[r] = prunableCount(retention: r, now: now) }
        let page = includePage ? makePage(query: "", now: now) : Page(hasMore: lastPageHasMore || !allLoaded)
        if includePage { lastPageHasMore = page.hasMore }
        var result = Snapshot(page: page, stats: stats(now: now),
                        insights: insightsEngine.insights(now: now), diagnostics: diagnostics(), prunableCounts: counts)
        result.failedRemovalIDs = failedRemovalIDs
        return result
    }

    public func stats(now: Date = Date()) -> HistoryStats {
        var result = HistoryStats()
        let today = calendar.startOfDay(for: now)
        let week = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? now.addingTimeInterval(-7 * 86_400)
        let upper = now.addingTimeInterval(60)
        var speaking = 0.0
        var active = Set<Date>()
        for (day, b) in buckets {
            result.totalWords += b.words; result.totalDictations += b.dictations; speaking += b.speaking
            if day == today { result.dictationsToday += b.dictations }
            if b.dictations > 0 { active.insert(day) }
            if day <= upper { result.wordsThisWeek += b.words(from: week, through: upper) }
        }
        if speaking >= 1 { result.averageWPM = Int((Double(result.totalWords) / (speaking / 60)).rounded()) }
        result.timeSaved = max(0, Double(result.totalWords) / HistoryStats.typingWPM * 60 - speaking)
        var day = active.contains(today) ? today : calendar.date(byAdding: .day, value: -1, to: today) ?? today
        while active.contains(day) {
            result.streakDays += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return result
    }

    public func prunableCount(retention: HistoryRetention, now: Date = Date()) -> Int {
        guard let cutoff = retention.cutoff(now: now) else { return 0 }
        let boundary = calendar.startOfDay(for: cutoff)
        return buckets.reduce(0) { total, pair in
            if pair.key < boundary { return total + pair.value.count }
            if pair.key == boundary { return total + Bucket.bound(pair.value.timestamps, cutoff) }
            return total
        }
    }

    public func allEntries() -> [HistoryEntry] { entries }

    private func diagnostics() -> [HistoryEntry] { measuredRecent }

    private func makePage(query: String, now: Date) -> Page {
        let q = query.trimmingCharacters(in: .whitespaces)
        let key = Self.foldText(q)
        let needsFullCheck = q.unicodeScalars.contains { CharacterSet.nonBaseCharacters.contains($0) }
            || q.unicodeScalars.contains { Self.foldText(String($0)).count != String($0).count }
        let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)) ?? now
        var result: [HistoryEntry] = []
        var days = Set<Date>()
        var baseDays: Int?
        var hasMore = false
        for i in entries.indices.reversed() {
            let e = entries[i]
            guard Self.visible(e) else { continue }
            if !q.isEmpty {
                guard HistoryStats.counts(e),
                      (needsFullCheck || folded[i].final.contains(key) || folded[i].raw.contains(key)),
                      (e.final.localizedCaseInsensitiveContains(q) || e.raw.localizedCaseInsensitiveContains(q)) else { continue }
            }
            let day = calendar.startOfDay(for: e.timestamp)
            if baseDays == nil, result.count >= 200, day < yesterday, !days.contains(day) { baseDays = days.count }
            if let baseDays, days.count >= baseDays + (q.isEmpty ? loadedDays : searchDays), !days.contains(day) { hasMore = true; break }
            days.insert(day); result.append(e)
        }
        return Page(entries: result, hasMore: hasMore || !allLoaded)
    }

    private func rebuild() {
        folded = entries.map(Self.fold); buckets = [:]
        measuredRecent = Array(entries.lazy.filter { $0.zeroFraction != nil }.suffix(MicAudioDiagnostics.window))
        for e in entries { addToBucket(e) }
        insightsEngine.update(entries: entries)
    }

    private func addToBucket(_ entry: HistoryEntry) {
        buckets[calendar.startOfDay(for: entry.timestamp), default: Bucket()].add(entry)
    }

    public static func visible(_ e: HistoryEntry) -> Bool {
        HistoryStats.counts(e) || (e.outcome != .inserted && e.outcome != .noSpeech && e.outcome != .emptyAfterCleanup)
    }
    private static func foldText(_ s: String) -> String { s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) }
    private static func fold(_ e: HistoryEntry) -> (final: String, raw: String) { (foldText(e.final), foldText(e.raw)) }

    private static func readTail(_ url: URL, now: Date, calendar: Calendar) -> [HistoryEntry] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard var position = try? handle.seekToEnd() else { return [] }
        let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)) ?? now
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var carry = Data(), newest: [HistoryEntry] = []
        var seenDays = Set<Date>()
        while position > 0 {
            let count = min(position, 65_536); position -= count
            try? handle.seek(toOffset: position)
            guard let chunk = try? handle.read(upToCount: Int(count)) else { break }
            var data = chunk; data.append(carry)
            let lines = data.split(separator: 10, omittingEmptySubsequences: false)
            carry = position > 0 ? Data(lines.first ?? Data.SubSequence()) : Data()
            let complete = position > 0 ? lines.dropFirst() : lines[...]
            for line in complete.reversed() where !line.isEmpty {
                let bytes = Data(line)
                decoder.userInfo[HistoryEntry.legacyIDSeedKey] = bytes
                guard let e = try? decoder.decode(HistoryEntry.self, from: bytes) else { continue }
                newest.append(e); seenDays.insert(calendar.startOfDay(for: e.timestamp))
            }
            if newest.lazy.filter(Self.visible).count >= 200, seenDays.count >= 2, newest.contains(where: { $0.timestamp < yesterday }) { break }
        }
        return newest.reversed()
    }
}

extension HistoryStore {
    func readAll() -> [HistoryEntry] { queue.sync { readAllOnQueue() } }

    private func readAllOnQueue() -> [HistoryEntry] {
        guard let data = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return data.split(separator: "\n").compactMap { line in
            let bytes = Data(line.utf8)
            dec.userInfo[HistoryEntry.legacyIDSeedKey] = bytes  // id migration for pre-id lines
            return try? dec.decode(HistoryEntry.self, from: bytes)
        }
    }
    /// Read, filter and atomically rewrite on the append queue. Appends submitted during the
    /// filter run afterwards, so the rename cannot overwrite a newly appended entry.
    @discardableResult
    func removeAll(where shouldRemove: (HistoryEntry) -> Bool) throws -> [HistoryEntry] {
        try queue.sync {
            let entries = readAllOnQueue()
            var kept: [HistoryEntry] = [], removed: [HistoryEntry] = []
            for entry in entries {
                if shouldRemove(entry) { removed.append(entry) } else { kept.append(entry) }
            }
            if !removed.isEmpty { try writeAllOnQueue(kept) }
            return removed
        }
    }

    func replaceAll(with entries: [HistoryEntry]) throws {
        try queue.sync { try writeAllOnQueue(entries) }
    }

    private func writeAllOnQueue(_ entries: [HistoryEntry]) throws {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = Data()
        for e in entries { data.append(try enc.encode(e)); data.append(0x0A) }
        try AppPaths.ensurePrivateDirectory(fileURL.deletingLastPathComponent())
        try AppPaths.writePrivate(data, to: fileURL)
    }

    func clearAll() throws {
        try queue.sync {
            if FileManager.default.fileExists(atPath: fileURL.path) { try FileManager.default.removeItem(at: fileURL) }
        }
    }

    func readRecent(limit: Int) -> [HistoryEntry] { Array(readAll().suffix(limit).reversed()) }
    func delete(_ entry: HistoryEntry) throws {
        try rawRewrite(removing: [entry.id]).waitForHistoryRewrite()
    }

    /// A queue-backed operation can be awaited by the actor or synchronously by old tools.
    final class RawRewrite: @unchecked Sendable {
        let group = DispatchGroup()
        private let lock = NSLock()
        private var error: Error?
        init() { group.enter() }
        func finish(_ error: Error?) { lock.withLock { self.error = error }; group.leave() }
        func waitForHistoryRewrite() throws { group.wait(); if let error = lock.withLock({ error }) { throw error } }
        var value: Void {
            get async throws {
                try await withCheckedThrowingContinuation { continuation in
                    group.notify(queue: .global(qos: .utility)) {
                        do { try self.waitForHistoryRewrite(); continuation.resume() }
                        catch { continuation.resume(throwing: error) }
                    }
                }
            }
        }
    }

    func rawRewrite(removing ids: Set<UUID>?) -> RawRewrite {
        let operation = RawRewrite()
        queue.async {
            do {
                try self.beforeRewrite()
                guard let ids else {
                    if FileManager.default.fileExists(atPath: self.fileURL.path) { try FileManager.default.removeItem(at: self.fileURL) }
                    operation.finish(nil); return
                }
                guard !ids.isEmpty, FileManager.default.fileExists(atPath: self.fileURL.path) else { operation.finish(nil); return }
                let data = try Data(contentsOf: self.fileURL)
                var kept = Data()
                // Preserve original bytes, repairing a missing final line separator.
                var start = data.startIndex
                while start < data.endIndex {
                    let newline = data[start...].firstIndex(of: 10)
                    let end = newline ?? data.endIndex
                    let line = Data(data[start..<end])
                    let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
                    let id = (object?["id"] as? String).flatMap(UUID.init(uuidString:)) ?? HistoryEntry.legacyID(for: line)
                    let next = newline.map { data.index(after: $0) } ?? data.endIndex
                    if !ids.contains(id) { kept.append(data[start..<next]) }
                    start = next
                }
                if !kept.isEmpty, kept.last != 10 { kept.append(10) }
                try AppPaths.writePrivate(kept, to: self.fileURL)
                operation.finish(nil)
            } catch { operation.finish(error) }
        }
        return operation
    }
}
