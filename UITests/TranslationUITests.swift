import XCTest

/// Whole-track English -> Arabic translation with the offline mock provider (-mockTranslation):
/// full run to 100 %, cancel + resume from the checkpoint, SRT export.
final class TranslationUITests: SableUITestCase {
    func testTranslateWholeEnglishTrackToArabicWithMockProvider() throws {
        // 3 chunks x 2 s: long enough for the test to observe progress before 100 %.
        launch(Launch.seededWithMockTranslation + ["-mockTranslationDelay", "2.0"])
        openLibraryItem(Fixture.mkvTitle)
        selectSubtitleTrack(id: Fixture.mkvEnglishSRT)
        openTranslationSheet()
        startMockTranslation()

        XCTAssertTrue(waitUntil("translation progress is shown", timeout: Timeout.screen) { self.translationFraction() != nil },
                      "No progress readout (AX.Translation.progressLabel / AX.Translation.progress)")
        attachScreenshot("05-translation-progress")
        waitForTranslationToFinish()
        if let fraction = translationFraction() {
            XCTAssertEqual(fraction, 1, accuracy: 0.001, "Progress must reach 100 %")
        }

        showArabicTrack()
        let arabic = waitForSubtitleText(timeout: 30, description: "Arabic subtitle text is shown") { self.containsArabic($0) }
        XCTAssertFalse(containsEnglishDialogue(arabic), "The overlay should show the translation, not the English line: \(arabic)")
        _ = playerControl(AX.Player.playPause)
        attachScreenshot("06-arabic-subtitles")
    }

    func testCancelMidwayThenResumeContinuesFromCheckpoint() throws {
        // Slow the mock down so there is time to cancel between chunks.
        launch(Launch.seededWithMockTranslation + ["-mockTranslationDelay", "4.0"])
        openLibraryItem(Fixture.mkvTitle)
        selectSubtitleTrack(id: Fixture.mkvEnglishSRT)
        openTranslationSheet()
        startMockTranslation()

        var partial: Double = 0
        let midway = waitUntil("translation is part-way", timeout: 45) {
            guard let fraction = self.translationFraction() else { return false }
            partial = fraction
            return fraction > 0 && fraction < 1
        }
        XCTAssertTrue(midway, "Never observed partial progress (last \(partial)); the mock must pace its chunks (-mockTranslationDelay)")
        waitFor(AX.Translation.cancel, timeout: Timeout.control).tap()

        var resume = element(AX.Translation.resume)
        if !resume.waitForExistence(timeout: Timeout.control) {
            // Layouts that close the sheet on cancel offer Resume when it is reopened.
            if !element(AX.Translation.sheet).exists { openTranslationSheet() }
            resume = waitFor(AX.Translation.resume, timeout: Timeout.control)
        }
        let stopped = translationFraction() ?? partial
        XCTAssertGreaterThan(stopped, 0, "The checkpoint must keep the chunks completed before cancelling")
        XCTAssertLessThan(stopped, 1, "Cancel must stop the job before it completes")
        attachScreenshot("05b-translation-cancelled")

        resume.tap()
        var samples: [Double] = []
        let finished = waitUntil("the resumed translation completes", timeout: Timeout.translation) {
            if let fraction = self.translationFraction() { samples.append(fraction) }
            return (samples.last ?? 0) >= 0.999 || self.element(AX.Translation.showArabic).exists
        }
        XCTAssertTrue(finished, "The resumed job did not finish (samples \(samples))")
        if let first = samples.first {
            XCTAssertGreaterThanOrEqual(first + 0.0001, stopped,
                                        "Resume started from \(first), below the checkpoint \(stopped): it restarted from 0")
        }
        XCTAssertFalse(samples.contains { $0 + 0.0001 < stopped }, "Progress dropped below the checkpoint: \(samples)")

        showArabicTrack()
        restartPlaybackFromBeginning()   // the long cancel/resume run usually reaches the end of the 40 s clip
        waitForSubtitleText(timeout: 30, description: "Arabic subtitle text is shown after resume") { self.containsArabic($0) }
    }

    func testExportTranslatedTrackAsSRT() throws {
        launch(Launch.seededWithMockTranslation + ["-mockTranslationDelay", "0.1"])
        openLibraryItem(Fixture.mkvTitle)
        selectSubtitleTrack(id: Fixture.mkvEnglishSRT)
        openTranslationSheet()
        startMockTranslation()
        waitForTranslationToFinish()

        let export = waitFor(AX.Translation.export, timeout: Timeout.control)
        export.tap()
        let path = waitFor(AX.Translation.exportedPath, timeout: Timeout.screen)
        let shown = waitForLabel(of: path, timeout: Timeout.screen, description: "the exported .srt path is shown") {
            $0.range(of: ".srt", options: .caseInsensitive) != nil
        }
        XCTAssertFalse(shown.isEmpty)
        attachScreenshot("05c-translation-exported")
    }

    // MARK: Helpers

    private func openTranslationSheet() {
        tapPlayerAction(AX.Player.translateButton)
        waitFor(AX.Translation.sheet, timeout: Timeout.screen)
    }

    /// Picks the mock provider if the sheet offers a choice, then starts the job. The mock is free,
    /// so the paid-provider confirmation must not appear.
    private func startMockTranslation(file: StaticString = #filePath, line: UInt = #line) {
        let start = waitFor(AX.Translation.start, timeout: Timeout.screen, file: file, line: line)
        let mockOption = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'mock'")).firstMatch
        if mockOption.exists && mockOption.isHittable && !mockOption.isSelected {
            mockOption.tap()
        }
        start.tap()
        let confirm = element(AX.Translation.confirmPaid)
        if confirm.waitForExistence(timeout: 2) {
            XCTFail("The paid-provider confirmation appeared: -mockTranslation should select the free mock provider",
                    file: file, line: line)
        }
    }

    /// Fraction 0...1 from the progress label, or the progress bar's accessibility value.
    /// Reads through `snapshot()` (which throws instead of failing the test) because the progress
    /// views disappear the moment the job completes, between an `exists` check and a label read.
    private func translationFraction() -> Double? {
        if let snap = try? element(AX.Translation.progressLabel).snapshot(),
           let fraction = Self.progressFraction(from: snap.label) { return fraction }
        if let snap = try? element(AX.Translation.progress).snapshot() {
            if let value = snap.value as? String, let fraction = Self.progressFraction(from: value) { return fraction }
            if let fraction = Self.progressFraction(from: snap.label) { return fraction }
        }
        return nil
    }

    private func waitForTranslationToFinish(file: StaticString = #filePath, line: UInt = #line) {
        var last: Double?
        let done = waitUntil("translation reaches 100 %", timeout: Timeout.translation) {
            last = self.translationFraction() ?? last
            if let last, last >= 0.999 { return true }
            return self.element(AX.Translation.showArabic).exists || self.element(AX.Translation.export).exists
        }
        XCTAssertTrue(done, "Translation did not complete (last progress \(String(describing: last)))", file: file, line: line)
    }

    /// Activates the Arabic track: the sheet's "show Arabic" action, else the tr:ar: row.
    private func showArabicTrack(file: StaticString = #filePath, line: UInt = #line) {
        let showArabic = element(AX.Translation.showArabic)
        if showArabic.waitForExistence(timeout: Timeout.control) {
            showArabic.tap()
        } else {
            let done = element(AX.Translation.done)
            if done.exists { done.tap() }
            closeSheetIfPresent(AX.Translation.sheet)
            selectSubtitleTrack(prefix: "tr:ar:", file: file, line: line)
        }
        closeSheetIfPresent(AX.Translation.sheet)
    }
}
