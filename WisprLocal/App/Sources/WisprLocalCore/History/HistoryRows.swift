import Foundation

/// A virtual flat collection lets LazyVStack see individual rows without copying a loaded
/// year's entries into another array. Locating a row costs a binary search over day sections.
public struct HistoryRows: RandomAccessCollection {
    public struct Item: Identifiable {
        public var id: String
        public var title: String?
        public var entry: HistoryEntry?
        public var first = false
        public var last = false
        public var lastGroup = false
    }
    let groups: [(title: String, entries: [HistoryEntry])]
    let starts: [Int]
    public init(groups: [(title: String, entries: [HistoryEntry])]) {
        self.groups = groups
        var starts = [0]
        for group in groups { starts.append(starts.last! + 1 + group.entries.count) }
        self.starts = starts
    }
    public var startIndex: Int { 0 }
    public var endIndex: Int { starts.last! }
    public func index(after i: Int) -> Int { i + 1 }
    public func index(before i: Int) -> Int { i - 1 }
    public subscript(i: Int) -> Item {
        var low = 0, high = groups.count
        while low + 1 < high {
            let mid = (low + high) / 2
            if starts[mid] <= i { low = mid } else { high = mid }
        }
        let group = groups[low], offset = i - starts[low] - 1
        if offset < 0 { return Item(id: "header-\(low)-\(group.title)", title: group.title) }
        let entry = group.entries[offset]
        return Item(id: "\(entry.id)", entry: entry, first: offset == 0,
                    last: offset == group.entries.count - 1, lastGroup: low == groups.count - 1)
    }
}
