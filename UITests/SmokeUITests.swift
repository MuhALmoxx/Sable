import XCTest

final class SmokeUITests: XCTestCase {
    func testLaunchShowsLibrary() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting"]
        app.launch()
        XCTAssertTrue(app.otherElements[AX.Library.screen].waitForExistence(timeout: 20) || app.staticTexts["Sable"].waitForExistence(timeout: 5))
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "00-launch"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
