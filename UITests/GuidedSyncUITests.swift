import XCTest

/// Guided sync on the seeded MP4 with the external SRT that runs 2.5 s LATE:
/// mark the moment a line is spoken, pick the matching cue, check the computed offset
/// (offset = marked speech start − original cue start), apply it, then undo it.
final class GuidedSyncUITests: SableUITestCase {
    func testGuidedSyncComputesAppliesAndUndoesOffset() throws {
        launch(Launch.seeded)
        openLibraryItem(Fixture.mp4Title)
        selectSubtitleTrack(prefix: Fixture.externalPrefix)

        // Park playback just after the speech burst of "I can't sleep." starts (7.5 s in the audio,
        // 10.0 s in the late file), so the mark lands on a known moment.
        restartPlaybackFromBeginning()
        XCTAssertTrue(waitUntil("playback reaches the spoken line", timeout: Timeout.playback) {
            (self.currentPlaybackTime() ?? 0) >= Fixture.lateCueSpeechStart - 0.5
        }, "Playback did not reach \(Fixture.lateCueSpeechStart) s")
        pausePlayback()

        tapPlayerAction(AX.Player.syncButton)
        waitFor(AX.Sync.flow, timeout: Timeout.screen)

        // Step 1: mark "now" as the start of a spoken line.
        let mark = waitFor(AX.Sync.mark, timeout: Timeout.control)
        if !mark.isHittable {
            let next = element(AX.Sync.next)
            if next.exists { next.tap() }
        }
        XCTAssertTrue(waitUntil("Mark becomes tappable", timeout: Timeout.control) { mark.exists && mark.isHittable })
        mark.tap()
        let markedLabel = waitFor(AX.Sync.markedTime, timeout: Timeout.control)
        var marked = waitForLabel(of: markedLabel, timeout: Timeout.control, description: "the marked time is shown") {
            Self.seconds(fromClock: $0) != nil
        }

        // Nudging the mark moves it (the step size is the sync feature's choice).
        let nudge = element(AX.Sync.nudgeForward)
        if nudge.exists && nudge.isHittable {
            let before = marked
            nudge.tap()
            marked = waitForLabel(of: markedLabel, timeout: Timeout.control, description: "nudging moves the mark") {
                $0 != before && Self.seconds(fromClock: $0) != nil
            }
        }
        let markedSeconds = try XCTUnwrap(Self.seconds(fromClock: marked), "Unparseable marked time '\(marked)'")
        var displayedDecimals = 0
        if let dot = marked.lastIndex(of: ".") {
            displayedDecimals = marked[marked.index(after: dot)...].prefix(while: \.isNumber).count
        }
        let markTolerance = displayedDecimals > 0 ? 0.5 * pow(10, -Double(displayedDecimals)) + 0.0015 : 0.5015

        // Step 2: choose the line that was spoken (cue "2", 10.000 s in the late file).
        let next = element(AX.Sync.next)
        if next.exists {
            // The sheet scrolls Next into view after a mark; scroll ourselves if it is still hidden.
            var scrolls = 0
            while !next.isHittable && scrolls < 4 {
                element(AX.Sync.flow).swipeUp()
                scrolls += 1
            }
            if next.isHittable { next.tap() }
        }
        let candidates = elements(withIdentifierPrefix: "sync.candidate.")
        XCTAssertTrue(waitUntil("candidate lines are offered", timeout: Timeout.screen) { candidates.count > 0 },
                      "No candidate cues around the marked time \(marked)")
        attachScreenshot("08-sync-candidates")
        let target = element(AX.Sync.candidate(Fixture.lateCueID))
        var widenings = 0
        while !target.exists && widenings < 3 && element(AX.Sync.widen).exists {
            element(AX.Sync.widen).tap()
            widenings += 1
            _ = target.waitForExistence(timeout: 3)
        }
        XCTAssertTrue(target.waitForExistence(timeout: Timeout.control), "Cue \(Fixture.lateCueID) is not offered as a candidate")
        if !target.isHittable { app.swipeUp() }
        target.tap()

        // Step 3: the computed offset is marked − original cue start.
        let expected = markedSeconds - Fixture.lateCueOriginalStart
        let computed = waitFor(AX.Sync.computedOffset, timeout: Timeout.control)
        let computedLabel = waitForLabel(of: computed, timeout: Timeout.control, description: "the computed offset is shown") {
            Self.offsetSeconds(in: $0) != nil
        }
        let computedSeconds = try XCTUnwrap(Self.offsetSeconds(in: computedLabel))
        XCTAssertEqual(computedSeconds, expected, accuracy: markTolerance,
                       "offset must equal marked (\(marked)) − cue start (10.000 s)")
        // The fixture file is 2.5 s LATE, so a mark at the real speech onset (7.5 s) gives a negative
        // correction. On a slow CI runner the pause can land after the cue's original start (10 s);
        // the formula check above is the real assertion, the sign is only checked when it applies.
        if markedSeconds < Fixture.lateCueOriginalStart - 0.05 {
            XCTAssertLessThan(computedSeconds, 0, "The file is LATE, so the correction must move subtitles EARLIER (negative)")
        }
        let computedToken = try XCTUnwrap(Self.offsetToken(in: computedLabel))

        // Step 4: apply (and confirm, when the flow asks), then leave the flow.
        let apply = element(AX.Sync.apply)
        if apply.waitForExistence(timeout: Timeout.control) { apply.tap() }
        let confirm = element(AX.Sync.confirm)
        if confirm.waitForExistence(timeout: 3) { confirm.tap() }
        closeSheetIfPresent(AX.Sync.flow)
        XCTAssertTrue(waitForDisappearance(of: element(AX.Sync.flow), timeout: Timeout.control), "The sync flow did not close")

        // The timing panel shows the applied offset; Undo restores 0.000 s.
        let readout = openTimingPanel()
        waitForOffset(computedToken, in: readout)
        waitFor(AX.Timing.undo).tap()
        waitForOffset("0.000", in: readout)
    }
}
