import XCTest

/// Subtitle track selection: embedded Matroska tracks and an external SRT.
final class SubtitleTracksUITests: SableUITestCase {
    func testSelectEmbeddedMKVSubtitleTracks() throws {
        launch(Launch.seeded)
        openLibraryItem(Fixture.mkvTitle)
        pausePlayback()   // keep the 40 s clip from running out while the sheet is inspected
        openTrackSheet()

        let embedded = elements(withIdentifierPrefix: AX.Tracks.subtitle("emb:mkv:"))
        XCTAssertTrue(waitUntil("the three embedded text tracks are listed", timeout: Timeout.playback) { embedded.count >= 3 },
                      "Expected SRT en, ASS en and SRT fr in the MKV, found \(embedded.count)")
        XCTAssertTrue(element(AX.Tracks.subtitle(Fixture.mkvEnglishSRT)).exists)
        XCTAssertTrue(element(AX.Tracks.subtitle(Fixture.mkvFrenchSRT)).exists)
        XCTAssertTrue(element(AX.Tracks.subtitleOff).exists, "The sheet must offer 'Off'")
        attachScreenshot("04-tracks")

        // French first (not the default), then back to English: proves the selection is applied.
        selectSubtitleTrack(id: Fixture.mkvFrenchSRT)
        closeSheetIfPresent(AX.Tracks.sheet)
        restartPlaybackFromBeginning()   // the French track only has cues at 3 s and 7.5 s
        waitForSubtitleText(description: "French dialogue is shown") { text in
            Fixture.frenchFragments.contains { text.localizedCaseInsensitiveContains($0) } && !self.containsEnglishDialogue(text)
        }

        selectSubtitleTrack(id: Fixture.mkvEnglishSRT)
        closeSheetIfPresent(AX.Tracks.sheet)
        restartPlaybackFromBeginning()
        waitForSubtitleText(description: "English dialogue is shown") { self.containsEnglishDialogue($0) }

        openTrackSheet()
        element(AX.Tracks.subtitleOff).tap()
        closeSheetIfPresent(AX.Tracks.sheet)
        let overlay = element(AX.Player.subtitleText)
        XCTAssertTrue(waitUntil("subtitles disappear when turned off", timeout: Timeout.control) {
            !overlay.exists || overlay.label.isEmpty
        }, "Subtitle text is still visible after selecting Off")
    }

    func testSelectExternalSRTOnMP4() throws {
        launch(Launch.seeded)
        openLibraryItem(Fixture.mp4Title)
        openTrackSheet()
        XCTAssertTrue(element(AX.Tracks.subtitle(Fixture.mp4EnglishText)).waitForExistence(timeout: Timeout.playback),
                      "The MP4's embedded mov_text track should be listed as \(Fixture.mp4EnglishText)")
        let external = elements(withIdentifierPrefix: AX.Tracks.subtitle(Fixture.externalPrefix)).firstMatch
        XCTAssertTrue(external.waitForExistence(timeout: Timeout.control), "The seeded external SRT is not listed")
        XCTAssertTrue(element(AX.Tracks.importSubtitle).exists, "The sheet must offer importing a subtitle file")
        selectSubtitleTrack(prefix: Fixture.externalPrefix)
        waitForSubtitleText(timeout: 30, description: "the external SRT's dialogue is shown") { self.containsEnglishDialogue($0) }
        attachScreenshot("04b-external-srt")
    }
}
