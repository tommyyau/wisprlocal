import Foundation
import Observation

/// Bounded recent rows for Home, loaded day cards for History and cached dashboard values.
/// An append touches the recent window and its day card, irrespective of the file's length.
@MainActor @Observable
public final class HistoryPresentation {
    public struct DayGroup: Equatable, Sendable {
        public var title: String
        public var entries: [HistoryEntry]
    }

    public private(set) var recent: [HistoryEntry] = []
    public private(set) var groups: [DayGroup] = []
    public private(set) var stats = HistoryStats()
    public private(set) var insights = Insights()
    public private(set) var diagnostics: [HistoryEntry] = []
    public private(set) var hasMore = false
    @ObservationIgnored private var titleCache: [Date: String] = [:]
    @ObservationIgnored private var titleDay: Date?
    @ObservationIgnored private var calendar: Calendar

    public init(calendar: Calendar = .autoupdatingCurrent) { self.calendar = calendar }

    private func title(_ timestamp: Date, now: Date) -> String {
        let today = calendar.startOfDay(for: now)
        if titleDay != today { titleCache = [:]; titleDay = today }
        let day = calendar.startOfDay(for: timestamp)
        if let title = titleCache[day] { return title }
        let title: String
        if day == today { title = "Today" }
        else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(timestamp, inSameDayAs: yesterday) { title = "Yesterday" }
        else {
            var style = Date.FormatStyle().weekday(.wide).month(.wide).day()
            style.calendar = calendar; style.timeZone = calendar.timeZone
            title = timestamp.formatted(style)
        }
        titleCache[day] = title
        return title
    }

    /// Every index event invalidates search, even when the newest 200 rows are unchanged.
    public private(set) var revision: UInt64 = 0
    public private(set) var searchPage = HistoryIndex.Page()
    public private(set) var unavailableIDs = Set<UUID>()
    public func canOpen(_ id: UUID) -> Bool { !unavailableIDs.contains(id) }

    @ObservationIgnored private var searchRequest: UInt64 = 0
    @ObservationIgnored private var searchQuery = ""
    public func beginSearch(query: String) -> UInt64 {
        searchRequest &+= 1
        if searchQuery != query { searchPage = .init(); searchQuery = query }
        return searchRequest
    }

    public func setSearchPage(_ page: HistoryIndex.Page, revision: UInt64, request: UInt64? = nil) {
        guard revision == self.revision, request == nil || request == searchRequest else { return }
        searchPage = .init(entries: page.entries.filter { canOpen($0.id) }, hasMore: page.hasMore)
    }

    public func calendarDidChange(calendar: Calendar = .autoupdatingCurrent, now: Date = Date()) {
        self.calendar = calendar; titleCache = [:]; titleDay = nil
        setPage(.init(entries: groups.flatMap(\.entries), hasMore: hasMore), now: now)
        revision &+= 1
    }

    public func setPage(_ page: HistoryIndex.Page, now: Date = Date()) {
        let entries = page.entries.filter { canOpen($0.id) }
        recent = Array(entries.prefix(200)); hasMore = page.hasMore
        var grouped: [DayGroup] = []
        for entry in entries {
            let title = title(entry.timestamp, now: now)
            if grouped.last?.title == title { grouped[grouped.count - 1].entries.append(entry) }
            else { grouped.append(DayGroup(title: title, entries: [entry])) }
        }
        groups = grouped
    }

    public func apply(_ change: HistoryIndex.Change, now: Date = Date()) {
        revision &+= 1
        switch change {
        case .removed(let ids, _):
            unavailableIDs.formUnion(ids)
            searchPage.entries.removeAll { unavailableIDs.contains($0.id) }
        case .loadedAll(let snapshot):
            unavailableIDs.subtract(snapshot.failedRemovalIDs)
        case .cleared:
            unavailableIDs.formUnion(searchPage.entries.map(\.id))
            unavailableIDs.formUnion(groups.flatMap(\.entries).map(\.id))
            searchPage = .init()
        default: break
        }
        let snapshot: HistoryIndex.Snapshot
        switch change {
        case .appended(let entries, let value):
            snapshot = value
            for entry in entries where HistoryIndex.visible(entry) && canOpen(entry.id) {
                recent = Array(([entry] + recent).prefix(200))
                let title = title(entry.timestamp, now: now)
                if groups.first?.title == title { groups[0].entries.insert(entry, at: 0) }
                else { groups.insert(DayGroup(title: title, entries: [entry]), at: 0) }
            }
        case .loadedRecent(let value), .loadedAll(let value), .removed(_, let value), .cleared(let value):
            snapshot = value; setPage(value.page, now: now)
        }
        stats = snapshot.stats; insights = snapshot.insights; diagnostics = snapshot.diagnostics; hasMore = snapshot.page.hasMore
    }
}
