import XCTest
@testable import TranslationKit

final class TranslationContractTests: XCTestCase {
    func testArabicProfileExists() {
        XCTAssertEqual(TargetLanguages.arabic.code, .arabic)
        XCTAssertTrue(TargetLanguages.arabic.isRightToLeft)
    }
}
