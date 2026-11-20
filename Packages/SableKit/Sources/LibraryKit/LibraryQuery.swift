import Foundation

// OWNER: library agent.

public enum LibraryQuery {
    /// Case/diacritic-insensitive title search, then sort. Stable for equal keys.
    /// Every whitespace-separated search word must appear in the title ("roof night" finds
    /// "Night Roof").
    public static func apply(_ items: [MediaItem], search: String, sort: LibrarySort) -> [MediaItem] {
        sorted(filter(items, search: search), by: sort)
    }

    public static func filter(_ items: [MediaItem], search: String) -> [MediaItem] {
        let words = fold(search).split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else { return items }
        return items.filter { item in
            let title = fold(item.title)
            return words.allSatisfy { title.contains($0) }
        }
    }

    /// Stable sort: equal keys keep their input order.
    public static func sorted(_ items: [MediaItem], by sort: LibrarySort) -> [MediaItem] {
        let order: (MediaItem, MediaItem) -> ComparisonResult
        switch sort {
        case .recentlyAdded:
            order = { descending($0.addedAt, $1.addedAt) }
        case .recentlyPlayed:
            order = { descendingNilLast($0.lastPlayedAt, $1.lastPlayedAt) }
        case .title:
            order = { $0.title.localizedStandardCompare($1.title) }
        case .duration:
            order = { descendingNilLast(validDuration($0.duration), validDuration($1.duration)) }
        case .size:
            order = { descending($0.fileSize, $1.fileSize) }
        }
        return items.enumerated()
            .sorted { lhs, rhs in
                switch order(lhs.element, rhs.element) {
                case .orderedAscending: return true
                case .orderedDescending: return false
                case .orderedSame: return lhs.offset < rhs.offset
                }
            }
            .map(\.element)
    }

    /// Case-, diacritic- and width-insensitive form used for matching.
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    private static func validDuration(_ value: TimeInterval?) -> TimeInterval? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    private static func descending<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
        if a > b { return .orderedAscending }
        if a < b { return .orderedDescending }
        return .orderedSame
    }

    private static func descendingNilLast<T: Comparable>(_ a: T?, _ b: T?) -> ComparisonResult {
        switch (a, b) {
        case let (a?, b?): return descending(a, b)
        case (.some, .none): return .orderedAscending
        case (.none, .some): return .orderedDescending
        case (.none, .none): return .orderedSame
        }
    }
}
