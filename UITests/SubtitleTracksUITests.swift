import XCTest

/// Subtitle track switching WHILE THE VIDEO KEEPS PLAYING. After every switch the overlay
/// (`AX.Player.subtitleText`) is checked without pausing, rewinding or seeking: the previous
/// track's text must be gone at once, and the new track's text must appear at the current position
/// within a few seconds. In UI-test runs the overlay's accessibility value is the id of the track
/// its cues come from, which tells the embedded MP4 track and the external SRT apart (they carry
/// the same dialogue, 2.5 s apart).
///
/// Clip timing (Fixtures/src/sample.*.srt, 40 s clip): English lines start at 3.0, 7.5, 12.0, 16.5,
/// 17.6, 21.0, 25.5, 30.0 and 34.5 s and last 1.7–3.8 s; the French track has only 3.0–5.2 s and
/// 7.5–10.4 s; the external SRT is the English dialogue 2.5 s late (5.5 s … 39.5 s). Playback is
/// restarted near 0 s only BEFORE a track list is opened, and only when too little clip is left.
final class SubtitleTracksUITests: SableUITestCase {
    private let arabicPrefix = "tr:ar:"

    // MARK: Journeys

    /// MKV (VLC): embedded English (default) -> French -> Off -> English again.
    func testSwitchEmbeddedMKVTracksDuringPlayback() throws {
        launch(Launch.seeded)
        openLibraryItem(Fixture.mkvTitle)
        waitForPlayerReady()

        openTrackSheet()
        let embedded = elements(withIdentifierPrefix: AX.Tracks.subtitle("emb:mkv:"))
        XCTAssertTrue(waitUntil("the three embedded text tracks are listed", timeout: Timeout.playback) { embedded.count >= 3 },
                      "Expected SRT en, ASS en and SRT fr in the MKV, found \(embedded.count)")
        XCTAssertTrue(element(AX.Tracks.subtitle(Fixture.mkvFrenchSRT)).exists)
        XCTAssertTrue(element(AX.Tracks.subtitleOff).exists, "The sheet must offer 'Off'")
        let english = element(AX.Tracks.subtitle(Fixture.mkvEnglishSRT))
        XCTAssertTrue(waitUntil("the default English track is selected", timeout: Timeout.control) {
            english.exists && english.isSelected
        }, "The default English SRT should be the active track before switching")
        attachScreenshot("04-tracks")
        closeSheetIfPresent(AX.Tracks.sheet)

        // English -> French while playing. The French track only has lines until 10.4 s, so rewind
        // near 0 s first (before the list opens again) and switch right away.
        restartPlaybackFromBeginning()
        selectSubtitleTrack(id: Fixture.mkvFrenchSRT)
        expectSubtitles(from: Fixture.mkvFrenchSRT, replacing: Fixture.mkvEnglishSRT, timeout: 12,
                        description: "French dialogue replaces the English track",
                        matching: { text in Fixture.frenchFragments.contains { text.localizedCaseInsensitiveContains($0) } },
                        staleIf: { self.containsEnglishDialogue($0) })

        // French -> Off.
        keepClipAhead(latest: 26)
        selectSubtitlesOff()
        expectNoSubtitles(for: 4)

        // Off -> English again: the current line appears without any seek.
        keepClipAhead(latest: 28)
        selectSubtitleTrack(id: Fixture.mkvEnglishSRT)
        expectSubtitles(from: Fixture.mkvEnglishSRT, replacing: nil, timeout: 12,
                        description: "English dialogue is back after turning subtitles on again",
                        matching: { self.containsEnglishDialogue($0) })
    }

    /// MP4 (AVFoundation): embedded mov_text (default) -> external SRT -> Off -> external again.
    func testSwitchMP4EmbeddedExternalAndOffDuringPlayback() throws {
        launch(Launch.seeded)
        openLibraryItem(Fixture.mp4Title)
        waitForPlayerReady()
        restartPlaybackFromBeginning()
        expectSubtitles(from: Fixture.mp4EnglishText, replacing: nil, timeout: 15,
                        description: "the embedded MP4 text track (default) is shown",
                        matching: { self.containsEnglishDialogue($0) })

        openTrackSheet()
        XCTAssertTrue(element(AX.Tracks.subtitle(Fixture.mp4EnglishText)).waitForExistence(timeout: Timeout.control),
                      "The MP4's embedded mov_text track should be listed as \(Fixture.mp4EnglishText)")
        let external = elements(withIdentifierPrefix: AX.Tracks.subtitle(Fixture.externalPrefix)).firstMatch
        XCTAssertTrue(external.waitForExistence(timeout: Timeout.control), "The seeded external SRT is not listed")
        XCTAssertTrue(element(AX.Tracks.importSubtitle).exists, "The sheet must offer importing a subtitle file")

        // Embedded -> external while playing.
        selectSubtitleTrack(prefix: Fixture.externalPrefix)
        expectSubtitles(from: Fixture.externalPrefix, replacing: Fixture.mp4EnglishText, timeout: 12,
                        description: "the external SRT's lines replace the embedded track",
                        matching: { self.containsEnglishDialogue($0) })
        attachScreenshot("04b-external-srt")

        // External -> Off: the external lines are dense (gaps ≤ 2.3 s), so 4 s without text is meaningful.
        keepClipAhead(latest: 26)
        selectSubtitlesOff()
        expectNoSubtitles(for: 4)

        // Off -> external again.
        keepClipAhead(latest: 30)
        selectSubtitleTrack(prefix: Fixture.externalPrefix)
        expectSubtitles(from: Fixture.externalPrefix, replacing: nil, timeout: 12,
                        description: "the external SRT's lines are back after turning subtitles on again",
                        matching: { self.containsEnglishDialogue($0) })
    }

    /// MKV: English original <-> Arabic translation (made first with the fast offline mock).
    func testSwitchBetweenOriginalAndTranslatedDuringPlayback() throws {
        launch(Launch.seededWithMockTranslation + ["-mockTranslationDelay", "0.1"])
        openLibraryItem(Fixture.mkvTitle)
        waitForPlayerReady()
        createArabicTranslationOfDefaultTrack()

        restartPlaybackFromBeginning()
        expectSubtitles(from: Fixture.mkvEnglishSRT, replacing: nil, timeout: 12,
                        description: "the English original is shown",
                        matching: { self.containsEnglishDialogue($0) })

        // Original -> translated.
        selectSubtitleTrack(prefix: arabicPrefix)
        expectSubtitles(from: arabicPrefix, replacing: Fixture.mkvEnglishSRT, timeout: 12,
                        description: "the Arabic translation replaces the English line",
                        matching: { self.containsArabic($0) },
                        staleIf: { self.containsEnglishDialogue($0) && !self.containsArabic($0) })

        // Translated -> original.
        keepClipAhead(latest: 27)
        selectSubtitleTrack(id: Fixture.mkvEnglishSRT)
        expectSubtitles(from: Fixture.mkvEnglishSRT, replacing: arabicPrefix, timeout: 12,
                        description: "the English original replaces the Arabic line",
                        matching: { self.containsEnglishDialogue($0) },
                        staleIf: { self.containsArabic($0) })
    }

    // MARK: Helpers

    private struct OverlayReading: CustomStringConvertible {
        let text: String
        let track: String?

        var description: String {
            "'\(text.replacingOccurrences(of: "\n", with: " "))' from \(track ?? "an unnamed track")"
        }
    }

    /// The overlay's text and source track, or nil when no line is shown. Reads one snapshot, so
    /// a line ending between two queries can't fail the test.
    private func overlayReading() -> OverlayReading? {
        guard let snapshot = try? element(AX.Player.subtitleText).snapshot(), !snapshot.label.isEmpty else { return nil }
        let value = (snapshot.value as? String).flatMap { $0.isEmpty ? nil : $0 }
        return OverlayReading(text: snapshot.label, track: value)
    }

    /// After a switch (playback running): waits until the overlay draws a line of the track whose
    /// id starts with `newTrack` and whose text satisfies `matches`. Fails as soon as a line of the
    /// previous track (`oldTrack` id prefix, or text `isOldText` accepts) is still on screen.
    @discardableResult
    private func expectSubtitles(from newTrack: String, replacing oldTrack: String?, timeout: TimeInterval,
                                 description: String, matching matches: @escaping (String) -> Bool,
                                 staleIf isOldText: ((String) -> Bool)? = nil,
                                 file: StaticString = #filePath, line: UInt = #line) -> String {
        var last = "nothing"
        var stale: String?
        let shown = waitUntil(description, timeout: timeout) {
            guard let reading = self.overlayReading() else { return false }
            last = reading.description
            let fromNewTrack = reading.track?.hasPrefix(newTrack) == true
            if let oldTrack, reading.track?.hasPrefix(oldTrack) == true {
                stale = last
                return true
            }
            if !fromNewTrack, let isOldText, isOldText(reading.text) {
                stale = last
                return true
            }
            return fromNewTrack && matches(reading.text)
        }
        if let stale {
            XCTFail("The previous track is still on screen after switching to \(newTrack): \(stale)", file: file, line: line)
        } else {
            XCTAssertTrue(shown, "\(description) (last overlay: \(last))", file: file, line: line)
        }
        return last
    }

    /// After turning subtitles off: the overlay is gone right away and stays empty while the clip
    /// plays on through cue windows.
    private func expectNoSubtitles(for seconds: TimeInterval, file: StaticString = #filePath, line: UInt = #line) {
        var lingering = "nothing"
        let cleared = waitUntil("subtitles disappear when turned off", timeout: 2) {
            guard let reading = self.overlayReading() else { return true }
            lingering = reading.description
            return false
        }
        XCTAssertTrue(cleared, "Subtitle text is still visible after selecting Off: \(lingering)", file: file, line: line)
        var reappeared: String?
        _ = waitUntil("no subtitle text while subtitles are off", timeout: seconds) {
            guard let reading = self.overlayReading() else { return false }
            reappeared = reading.description
            return true
        }
        XCTAssertNil(reappeared, "Subtitle text came back while subtitles are off: \(reappeared ?? "")", file: file, line: line)
    }

    /// The transport controls exist once the video is open (the chrome never auto-hides in UI tests).
    private func waitForPlayerReady(file: StaticString = #filePath, line: UInt = #line) {
        waitFor(AX.Player.playPause, timeout: Timeout.playback, file: file, line: line)
    }

    private func selectSubtitlesOff(file: StaticString = #filePath, line: UInt = #line) {
        if !element(AX.Tracks.sheet).exists { openTrackSheet(file: file, line: line) }
        // "Off" is the first row of the list, visible as soon as the sheet opens.
        let off = waitFor(AX.Tracks.subtitleOff, timeout: Timeout.control, file: file, line: line)
        off.tap()
        closeSheetIfPresent(AX.Tracks.sheet)
    }

    /// Leaves enough of the 40 s clip for the next switch: when the playhead is past `latest`,
    /// rewinds near 0 s and resumes. Runs BEFORE the track list opens, so the switch and every
    /// check after it happen during uninterrupted playback.
    private func keepClipAhead(latest: TimeInterval) {
        if let now = currentPlaybackTime(), now <= latest { return }
        restartPlaybackFromBeginning()
    }

    /// Runs the offline mock translation of the active (default English) track to completion and
    /// closes the sheet WITHOUT showing the result, so the switch is made from the track list.
    private func createArabicTranslationOfDefaultTrack(file: StaticString = #filePath, line: UInt = #line) {
        tapPlayerAction(AX.Player.translateButton, file: file, line: line)
        waitFor(AX.Translation.sheet, timeout: Timeout.screen, file: file, line: line)
        let start = waitFor(AX.Translation.start, timeout: Timeout.screen, file: file, line: line)
        let mockOption = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'mock'")).firstMatch
        if mockOption.exists && mockOption.isHittable && !mockOption.isSelected {
            mockOption.tap()
        }
        start.tap()
        XCTAssertTrue(element(AX.Translation.showArabic).waitForExistence(timeout: Timeout.translation),
                      "The mock translation did not finish", file: file, line: line)
        closeSheetIfPresent(AX.Translation.sheet)
    }
}
