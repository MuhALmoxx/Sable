import XCTest

/// Relaunch journey: position (resume), subtitle selection and timing survive a terminate +
/// launch WITHOUT -uiTesting.
final class PersistenceUITests: SableUITestCase {
    func testRelaunchRestoresPositionSubtitleSelectionAndTiming() throws {
        launch(Launch.seeded)
        openLibraryItem(Fixture.mp4Title)
        openTrackSheet()
        let externalRow = elements(withIdentifierPrefix: AX.Tracks.subtitle(Fixture.externalPrefix)).firstMatch
        XCTAssertTrue(externalRow.waitForExistence(timeout: Timeout.playback), "The seeded external SRT is not listed")
        let externalRowID = externalRow.identifier
        externalRow.tap()
        closeSheetIfPresent(AX.Tracks.sheet)

        let readout = openTimingPanel()
        waitFor(AX.Timing.plusTenth).tap()
        waitForOffset("+0.100", in: readout)
        closeTimingPanel()

        // Setup above takes a while on CI and the clip keeps playing: rewind first. (Positions in
        // the last 10 s count as "finished" and intentionally restart from 0 on reopen.)
        restartPlaybackFromBeginning()
        let target: TimeInterval = 5   // low, so even a slow CI poll pauses well before the "finished" zone (last 10 s)
        XCTAssertTrue(waitUntil("playback passes \(Int(target)) s", timeout: 30) {
            (self.currentPlaybackTime() ?? 0) >= target
        }, "Playback never reached \(target) s")
        pausePlayback()
        let saved = try XCTUnwrap(currentPlaybackTime(), "No time readout before closing")
        waitFor(AX.Player.close).tap()
        waitFor(AX.Library.screen, timeout: Timeout.screen)

        relaunchKeepingState()
        openLibraryItem(Fixture.mp4Title)

        // Relaunched with -startPaused: the player opens at the restored position without playing,
        // so the readout must match the saved time (a fresh start would show 0:00).
        let resumed = waitUntil("playback resumes at \(saved) s", timeout: Timeout.playback) {
            guard let now = self.currentPlaybackTime() else { return false }
            return abs(now - saved) <= 1.5
        }
        XCTAssertTrue(resumed, "The remembered position (\(saved) s) was not restored; now \(String(describing: currentPlaybackTime()))")
        pausePlayback()
        attachScreenshot("10-relaunch-resumed")

        // Subtitle selection persisted: the external track is the selected row.
        openTrackSheet()
        let row = element(externalRowID)
        XCTAssertTrue(row.waitForExistence(timeout: Timeout.control), "The external SRT disappeared after relaunch")
        let selectedByValue = (row.value as? String).map { value in
            ["selected", "checked", "active"].contains { value.localizedCaseInsensitiveContains($0) }
        } ?? false
        XCTAssertTrue(row.isSelected || selectedByValue,
                      "The external SRT should still be the selected subtitle (expose it with the .isSelected trait)")
        closeSheetIfPresent(AX.Tracks.sheet)

        // Timing persisted per video + track.
        let restoredReadout = openTimingPanel()
        waitForOffset("+0.100", in: restoredReadout)
    }
}
