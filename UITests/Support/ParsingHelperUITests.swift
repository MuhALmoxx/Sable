import XCTest

/// Pure checks of the label parsers the journeys rely on (no app launch, runs in milliseconds).
final class ParsingHelperUITests: XCTestCase {
    func testClockParsing() {
        XCTAssertEqual(SableUITestCase.seconds(fromClock: "0:07"), 7)
        XCTAssertEqual(SableUITestCase.seconds(fromClock: "1:02:03"), 3723)
        XCTAssertEqual(SableUITestCase.seconds(fromClock: "00:00:07.512") ?? 0, 7.512, accuracy: 0.0001)
        XCTAssertEqual(SableUITestCase.seconds(fromClock: "Marked 0:07.5") ?? 0, 7.5, accuracy: 0.0001)
        XCTAssertEqual(SableUITestCase.seconds(fromClock: "\u{2212}0:05"), -5)
        XCTAssertNil(SableUITestCase.seconds(fromClock: "Play"))
    }

    func testOffsetTokens() {
        XCTAssertEqual(SableUITestCase.offsetToken(in: "+0.100 s"), "+0.100")
        XCTAssertEqual(SableUITestCase.offsetToken(in: "0.000 s"), "0.000")
        XCTAssertEqual(SableUITestCase.offsetToken(in: "Offset \u{2212}2.500 s (earlier)"), "\u{2212}2.500")
        XCTAssertEqual(SableUITestCase.offsetToken(in: "-1.250 s"), "\u{2212}1.250")
        XCTAssertNil(SableUITestCase.offsetToken(in: "No offset"))
        XCTAssertEqual(SableUITestCase.offsetSeconds(in: "\u{2212}2.500 s") ?? 0, -2.5, accuracy: 0.0001)
        XCTAssertEqual(SableUITestCase.formatOffset(-2.5), "\u{2212}2.500")
        XCTAssertEqual(SableUITestCase.formatOffset(0.1), "+0.100")
        XCTAssertEqual(SableUITestCase.formatOffset(0.0002), "0.000")
    }

    func testProgressFractions() {
        XCTAssertEqual(SableUITestCase.progressFraction(from: "44%") ?? 0, 0.44, accuracy: 0.0001)
        XCTAssertEqual(SableUITestCase.progressFraction(from: "100 percent") ?? 0, 1, accuracy: 0.0001)
        XCTAssertEqual(SableUITestCase.progressFraction(from: "3 / 9 lines") ?? 0, 1.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(SableUITestCase.progressFraction(from: "Translating 6 of 9") ?? 0, 6.0 / 9.0, accuracy: 0.0001)
        XCTAssertNil(SableUITestCase.progressFraction(from: "Starting…"))
    }
}
