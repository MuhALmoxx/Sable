import XCTest

/// Library: clean state, seeded fixtures, settings.
final class LibraryUITests: SableUITestCase {
    func testCleanLaunchShowsEmptyLibrary() throws {
        launch(Launch.clean)
        XCTAssertTrue(element(AX.Library.emptyState).waitForExistence(timeout: Timeout.screen),
                      "A wiped library should show the empty state")
        XCTAssertTrue(element(AX.Library.importVideo).exists, "The import action must be reachable from the empty library")
        XCTAssertEqual(elements(withIdentifierPrefix: AX.Library.itemPrefix).count, 0, "-uiTesting must start without items")
    }

    func testSeededLibraryListsBothFixtures() throws {
        launch(Launch.seeded)
        waitFor(AX.Library.item(Fixture.mp4Title))
        waitFor(AX.Library.item(Fixture.mkvTitle))
        XCTAssertFalse(element(AX.Library.emptyState).exists)
        // Durations/thumbnails are generated in the background; give them a moment to land so the
        // screenshot shows the finished grid (the wait ends as soon as a duration is visible).
        _ = waitUntil("a duration label is shown", timeout: 10) {
            self.app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", #".*\d+:\d{2}.*"#)).count > 0
        }
        attachScreenshot("01-library")
    }

    func testSettingsScreenShowsTranslationAndLicenses() throws {
        launch(Launch.clean)
        waitFor(AX.Library.settings).tap()
        waitFor(AX.Settings.screen)
        attachScreenshot("09-settings")
        let licenses = element(AX.Settings.licenses)
        if !licenses.waitForExistence(timeout: 3) {
            app.swipeUp()
        }
        XCTAssertTrue(licenses.waitForExistence(timeout: Timeout.control), "Settings must offer the licenses (LGPL notice)")
        licenses.tap()
        let vlcNotice = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] 'VLC'")).firstMatch
        XCTAssertTrue(vlcNotice.waitForExistence(timeout: Timeout.control), "The licenses page must mention MobileVLCKit")
    }
}
