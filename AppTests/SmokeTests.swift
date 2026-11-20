import XCTest
@testable import Sable

final class SmokeTests: XCTestCase {
    func testPaletteAccentIsDefined() {
        XCTAssertNotNil(Palette.accent)
    }
}
