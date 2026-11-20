import XCTest

final class SmokeUITests: SableUITestCase {
    func testLaunchShowsLibrary() throws {
        launch(Launch.clean)
        XCTAssertTrue(element(AX.Library.screen).exists)
        attachScreenshot("00-launch")
    }
}
