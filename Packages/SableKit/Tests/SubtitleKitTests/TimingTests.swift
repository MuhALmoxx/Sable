import XCTest
@testable import SubtitleKit

final class TimingTests: XCTestCase {
    private func cue(_ i: Int, _ s: Double, _ e: Double, _ t: String = "x") -> SubtitleCue {
        SubtitleCue(id: "\(i + 1)", index: i, start: s, end: e, text: t)
    }

    func testOffsetFormulaMatchesSpec() {
        // offset = marked speech start − original selected cue start
        let timing = SyncMath.timing(markedSpeechStart: 12.4, originalCueStart: 10.0)
        XCTAssertEqual(timing.offset, 2.4, accuracy: 0.0001)
        XCTAssertEqual(timing.effective(10.0), 12.4, accuracy: 0.0001)
        let negative = SyncMath.timing(markedSpeechStart: 5.0, originalCueStart: 7.25)
        XCTAssertEqual(negative.offset, -2.25, accuracy: 0.0001)
    }

    func testShiftRoundsToMilliseconds() {
        var t = SubtitleTiming.identity
        for _ in 0..<10 { t = t.shifted(by: 0.1) }
        XCTAssertEqual(t.offset, 1.0)
        t = t.shifted(by: -0.1)
        XCTAssertEqual(t.offset, 0.9)
    }

    func testCandidateWindowUsesEffectiveTimes() {
        let cues = [cue(0, 1, 2), cue(1, 15, 17), cue(2, 30, 31), cue(3, 45, 50)]
        let none = SyncMath.candidateCues(cues, around: 20, window: 10, timing: .identity)
        XCTAssertEqual(none.map(\.id), ["2", "3"])
        let shifted = SyncMath.candidateCues(cues, around: 20, window: 10, timing: SubtitleTiming(offset: 20))
        XCTAssertEqual(shifted.map(\.id), ["1"])
        XCTAssertEqual(SyncMath.candidateCues(cues, around: 0, window: .infinity, timing: .identity).count, 4)
    }

    func testCueIndexOverlapsAndOffset() {
        let cues = [cue(0, 0, 10), cue(1, 2, 3), cue(2, 4, 6)]
        let index = CueIndex(cues: cues)
        XCTAssertEqual(index.activeCues(at: 2.5).map(\.id), ["1", "2"])
        XCTAssertEqual(index.activeCues(at: 3.0).map(\.id), ["1"])
        XCTAssertEqual(index.activeCues(at: 5, timing: SubtitleTiming(offset: 1)).map(\.id), ["1", "3"])
        XCTAssertEqual(index.activeCues(at: 10.5).map(\.id), [])
    }

    func testTwoPointTiming() throws {
        let t = try XCTUnwrap(SyncMath.twoPointTiming(markA: 11, cueStartA: 10, markB: 1001, cueStartB: 1000 * (1000.0 / 1001.0) + 0))
        XCTAssertEqual(t.effective(10), 11, accuracy: 0.01)
        XCTAssertNil(SyncMath.twoPointTiming(markA: 1, cueStartA: 1, markB: 1.2, cueStartB: 1.3))
    }
}
