import XCTest

/// Manual subtitle timing: ±0.1 s nudges, typed offsets, reset and undo.
final class TimingUITests: SableUITestCase {
    func testNudgePlusThenMinusOneTenth() throws {
        launch(Launch.seeded)
        openLibraryItem(Fixture.mp4Title)
        selectSubtitleTrack(prefix: Fixture.externalPrefix)
        let readout = openTimingPanel()
        waitForOffset("0.000", in: readout)

        waitFor(AX.Timing.plusTenth).tap()
        waitForOffset("+0.100", in: readout)
        let meaning = element(AX.Timing.offsetMeaning)
        if meaning.exists {
            XCTAssertTrue(meaning.label.range(of: "later", options: .caseInsensitive) != nil,
                          "A positive offset must be explained as subtitles appearing LATER: '\(meaning.label)'")
        }
        attachScreenshot("07-timing")

        waitFor(AX.Timing.minusTenth).tap()
        waitForOffset("0.000", in: readout)
    }

    func testTypedOffsetResetAndUndo() throws {
        launch(Launch.seeded)
        openLibraryItem(Fixture.mp4Title)
        selectSubtitleTrack(prefix: Fixture.externalPrefix)
        let readout = openTimingPanel()

        let entry = waitFor(AX.Timing.entry)
        entry.tap()
        // Return dismisses the keyboard (and may already apply); otherwise tap Apply.
        entry.typeText("-2.5\n")
        let applied = waitUntil("typed offset applied on submit", timeout: 2) {
            readout.exists && Self.offsetToken(in: readout.label) == "\u{2212}2.500"
        }
        if !applied {
            waitFor(AX.Timing.apply).tap()
        }
        waitForOffset("\u{2212}2.500", in: readout)
        let meaning = element(AX.Timing.offsetMeaning)
        if meaning.exists {
            XCTAssertTrue(meaning.label.range(of: "earlier", options: .caseInsensitive) != nil,
                          "A negative offset must be explained as subtitles appearing EARLIER: '\(meaning.label)'")
        }

        waitFor(AX.Timing.plusOne).tap()
        waitForOffset("\u{2212}1.500", in: readout)

        waitFor(AX.Timing.reset).tap()
        waitForOffset("0.000", in: readout)

        waitFor(AX.Timing.undo).tap()
        waitForOffset("\u{2212}1.500", in: readout)
        waitFor(AX.Timing.undo).tap()
        waitForOffset("\u{2212}2.500", in: readout)
    }
}
