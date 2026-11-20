import XCTest
@testable import LibraryKit

final class LibraryContractTests: XCTestCase {
    func testProgressFraction() {
        var item = MediaItem(title: "a", fileName: "a.mp4", fileSize: 1, duration: 100)
        item.playback.position = 25
        XCTAssertEqual(item.progressFraction, 0.25, accuracy: 0.0001)
    }
}
