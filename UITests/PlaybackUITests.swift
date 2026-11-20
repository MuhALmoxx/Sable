import XCTest

/// Import/play journey: open the seeded MP4, playback time advances, rotation, audio tracks.
final class PlaybackUITests: SableUITestCase {
    func testOpenMP4PlaybackTimeAdvances() throws {
        launch(Launch.seeded)
        openLibraryItem(Fixture.mp4Title)

        let timeLabel = playerControl(AX.Player.currentTime, timeout: Timeout.playback)
        XCTAssertTrue(timeLabel.waitForExistence(timeout: Timeout.playback), "The current-time readout is missing")
        resumePlayback()
        var first: TimeInterval?
        var latest: TimeInterval?
        let advanced = waitUntil("playback time advances by at least 2 s", timeout: Timeout.playback) {
            guard let now = self.currentPlaybackTime() else { return false }
            if first == nil { first = now }
            latest = now
            return now >= (first ?? now) + 2
        }
        XCTAssertTrue(advanced, "Playback time did not advance (first \(String(describing: first)), latest \(String(describing: latest)))")
        let duration = playerControl(AX.Player.duration)
        if duration.exists, let seconds = Self.seconds(fromClock: duration.label) {
            XCTAssertEqual(seconds, Fixture.durationSeconds, accuracy: 1.5, "Duration readout should match the 40 s fixture")
        }
        _ = playerControl(AX.Player.playPause)
        attachScreenshot("02-player-portrait")

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(waitUntil("the player lays out in landscape", timeout: Timeout.control) {
            let frame = self.app.windows.firstMatch.frame
            return frame.width > frame.height
        }, "The player did not rotate to landscape")
        XCTAssertTrue(element(AX.Player.screen).exists)
        _ = playerControl(AX.Player.playPause)
        attachScreenshot("03-player-landscape")
        XCUIDevice.shared.orientation = .portrait
    }

    func testPlayPauseStopsTheClock() throws {
        launch(Launch.seeded)
        openLibraryItem(Fixture.mp4Title)
        resumePlayback()
        XCTAssertTrue(waitUntil("playback reaches 2 s", timeout: Timeout.playback) { (self.currentPlaybackTime() ?? 0) >= 2 })
        pausePlayback()
        guard let paused = currentPlaybackTime() else { return XCTFail("No time readout after pausing") }
        // While paused the readout must not move: sample it for a few seconds (predicate polling).
        let moved = waitUntil("time changes while paused", timeout: 4) {
            guard let now = self.currentPlaybackTime() else { return false }
            return abs(now - paused) >= 1
        }
        XCTAssertFalse(moved, "The playback clock kept running while paused")
    }

    func testMKVListsBothAudioTracks() throws {
        launch(Launch.seeded)
        openLibraryItem(Fixture.mkvTitle)
        tapPlayerAction(AX.Player.audioButton)
        let rows = elements(withIdentifierPrefix: "tracks.audio.")
        XCTAssertTrue(waitUntil("two audio tracks are listed", timeout: Timeout.playback) { rows.count >= 2 },
                      "Expected the Dialogue and Commentary tracks, found \(rows.count)")
        let commentary = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'tracks.audio.' AND label CONTAINS[c] 'Commentary'")).firstMatch
        if commentary.exists {
            commentary.tap()
        } else {
            rows.element(boundBy: 1).tap()
        }
        closeSheetIfPresent(AX.Tracks.sheet)
        XCTAssertTrue(element(AX.Player.screen).exists)
        XCTAssertFalse(element(AX.Player.errorMessage).exists, "Switching audio tracks produced an error")
    }
}
