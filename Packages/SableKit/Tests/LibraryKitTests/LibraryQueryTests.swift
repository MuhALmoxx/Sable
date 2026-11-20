import XCTest
@testable import LibraryKit

final class LibraryQueryTests: XCTestCase {
    private let base = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func item(_ title: String, added: TimeInterval = 0, played: TimeInterval? = nil,
                      duration: TimeInterval? = nil, size: Int64 = 0) -> MediaItem {
        MediaItem(title: title, fileName: "\(title).mkv", fileSize: size, duration: duration,
                  addedAt: base.addingTimeInterval(added), lastPlayedAt: played.map { base.addingTimeInterval($0) })
    }

    func testEmptySearchKeepsEverything() {
        let items = [item("B"), item("A")]
        XCTAssertEqual(LibraryQuery.apply(items, search: "", sort: .size).map(\.title), ["B", "A"])
        XCTAssertEqual(LibraryQuery.apply(items, search: "   ", sort: .size).map(\.title), ["B", "A"])
    }

    func testSearchIsCaseAndDiacriticInsensitive() {
        let items = [item("Café Nights"), item("Night Roof"), item("Amélie"), item("Roofless")]
        XCTAssertEqual(LibraryQuery.filter(items, search: "cafe").map(\.title), ["Café Nights"])
        XCTAssertEqual(LibraryQuery.filter(items, search: "AMELIE").map(\.title), ["Amélie"])
        XCTAssertEqual(LibraryQuery.filter(items, search: "café").map(\.title), ["Café Nights"])
        XCTAssertEqual(LibraryQuery.filter(items, search: "roof").map(\.title), ["Night Roof", "Roofless"])
        XCTAssertEqual(LibraryQuery.filter(items, search: "roof night").map(\.title), ["Night Roof"])
        XCTAssertEqual(LibraryQuery.filter(items, search: "  NIGHT  ").map(\.title), ["Café Nights", "Night Roof"])
        XCTAssertTrue(LibraryQuery.filter(items, search: "zzz").isEmpty)
    }

    func testSortRecentlyAddedDescending() {
        let items = [item("old", added: 0), item("new", added: 100), item("mid", added: 50)]
        XCTAssertEqual(LibraryQuery.apply(items, search: "", sort: .recentlyAdded).map(\.title), ["new", "mid", "old"])
    }

    func testSortRecentlyPlayedNeverPlayedLast() {
        let items = [item("never1"), item("long ago", played: 10), item("never2"), item("just now", played: 500)]
        XCTAssertEqual(LibraryQuery.apply(items, search: "", sort: .recentlyPlayed).map(\.title),
                       ["just now", "long ago", "never1", "never2"])
    }

    func testSortTitleUsesLocalizedStandardCompare() {
        let items = [item("episode 10"), item("Episode 2"), item("alpha"), item("Épisode 1")]
        let sorted = LibraryQuery.apply(items, search: "", sort: .title).map(\.title)
        XCTAssertEqual(sorted.first, "alpha")
        // Numeric-aware: 2 before 10.
        let two = sorted.firstIndex(of: "Episode 2")!
        let ten = sorted.firstIndex(of: "episode 10")!
        XCTAssertLessThan(two, ten)
    }

    func testSortDurationDescendingUnknownLast() {
        let items = [item("unknown"), item("short", duration: 60), item("zero", duration: 0), item("long", duration: 7200)]
        XCTAssertEqual(LibraryQuery.apply(items, search: "", sort: .duration).map(\.title),
                       ["long", "short", "unknown", "zero"])
    }

    func testSortSizeDescending() {
        let items = [item("small", size: 10), item("big", size: 9_000_000_000), item("medium", size: 5000)]
        XCTAssertEqual(LibraryQuery.apply(items, search: "", sort: .size).map(\.title), ["big", "medium", "small"])
    }

    func testSortIsStableForEqualKeys() {
        let items = (0..<20).map { item("same \($0)", added: 0, size: 7) }
        XCTAssertEqual(LibraryQuery.apply(items, search: "", sort: .size).map(\.title), items.map(\.title))
        XCTAssertEqual(LibraryQuery.apply(items, search: "", sort: .recentlyAdded).map(\.title), items.map(\.title))
        XCTAssertEqual(LibraryQuery.apply(items, search: "", sort: .recentlyPlayed).map(\.title), items.map(\.title))
    }

    func testSearchThenSort() {
        let items = [item("Roof A", size: 1), item("Garden", size: 100), item("Roof B", size: 50)]
        XCTAssertEqual(LibraryQuery.apply(items, search: "roof", sort: .size).map(\.title), ["Roof B", "Roof A"])
    }
}
