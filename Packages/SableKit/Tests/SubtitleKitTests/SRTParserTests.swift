import XCTest
@testable import SubtitleKit

final class SRTParserTests: XCTestCase {
    private func parse(_ text: String) throws -> SubtitleDocument {
        try SubtitleParser.parse(string: text, format: .srt)
    }

    func testFixture() throws {
        let doc = try Fixtures.document("sample.en.srt")
        XCTAssertEqual(doc.format, .srt)
        XCTAssertEqual(doc.cues.count, 9)
        XCTAssertEqual(doc.cues.map(\.id), (1...9).map(String.init))
        XCTAssertEqual(doc.cues.map(\.index), Array(0..<9))
        let second = doc.cues[1]
        XCTAssertEqual(second.start, 7.5, accuracy: 0.0001)
        XCTAssertEqual(second.end, 10.4, accuracy: 0.0001)
        XCTAssertEqual(second.text, "I can't sleep.\nThe city is too loud tonight.")
        XCTAssertEqual(doc.cues[3].text, "<i>Is it safe?</i>")
        XCTAssertEqual(doc.cues[3].plainText, "Is it safe?")
        XCTAssertEqual(doc.cues[5].text, "Look — every light down there\nis someone's story.")
        XCTAssertEqual(doc.cues[0].rawText, "Mara, are you still awake?")
        XCTAssertNil(doc.cues[0].style)
    }

    func testBOMAndCRLFAndCR() throws {
        let crlf = "\u{FEFF}1\r\n00:00:01,000 --> 00:00:02,000\r\nLine one\r\nLine two\r\n\r\n2\r\n00:00:03,000 --> 00:00:04,000\r\nNext\r\n"
        let doc = try parse(crlf)
        XCTAssertEqual(doc.cues.map(\.text), ["Line one\nLine two", "Next"])
        let cr = crlf.replacingOccurrences(of: "\r\n", with: "\r")
        XCTAssertEqual(try parse(cr).cues.map(\.text), ["Line one\nLine two", "Next"])
        // Through the byte path (BOM-marked UTF-8 data).
        let viaData = try SubtitleParser.parse(data: Data([0xEF, 0xBB, 0xBF] + bytes(crlf)), fileExtension: "srt")
        XCTAssertEqual(viaData.cues.count, 2)
    }

    func testMissingAndOddCounters() throws {
        let text = """
        00:00:01,000 --> 00:00:02,000
        No counter

        7
        00:00:03,000 --> 00:00:04,000
        Seven

        7
        00:00:05,000 --> 00:00:06,000
        Duplicate seven

        0042
        00:00:07,000 --> 00:00:08,000
        Forty-two
        """
        let doc = try parse(text)
        XCTAssertEqual(doc.cues.map(\.text), ["No counter", "Seven", "Duplicate seven", "Forty-two"])
        XCTAssertEqual(doc.cues.map(\.id), ["c1", "c2", "c3", "42"])
    }

    func testBlankLineNoiseAndMissingSeparators() throws {
        let text = "\n\n\n1\n00:00:01,000 --> 00:00:02,000\n\n\nFirst\n\n\n\nstill first\n\n\n2\n00:00:03,000 --> 00:00:04,000\nSecond\n3\n00:00:05,000 --> 00:00:06,000\nThird\n\n\n\n"
        let doc = try parse(text)
        XCTAssertEqual(doc.cues.map(\.text), ["First\nstill first", "Second", "Third"])
        XCTAssertEqual(doc.cues.map(\.id), ["1", "2", "3"])
    }

    func testTimestampVariants() throws {
        let text = """
        1
        00:00:01.5 --> 00:00:02.25
        Dot and short millis

        2
        0:0:3,7 --> 0:00:04,123
        Single digits

        3
        123:45:06,789 --> 123:45:07,000
        Long hours

        4
        00:00:09,000 --> 00:00:10,000  X1:100 X2:200 Y1:10 Y2:50
        Coordinates

        5
        00:00:11,000-->00:00:12,000
        No spaces

        6
        00:00:13 --> 00:00:14
        No millis
        """
        let doc = try parse(text)
        XCTAssertEqual(doc.cues.count, 6)
        // Normalised order: the 123-hour cue sorts last.
        let expected: [(Double, Double)] = [(1.5, 2.25), (3.7, 4.123), (9, 10), (11, 12), (13, 14),
                                            (123 * 3600 + 45 * 60 + 6.789, 123 * 3600 + 45 * 60 + 7)]
        for (cue, e) in zip(doc.cues, expected) {
            XCTAssertEqual(cue.start, e.0, accuracy: 0.0005, cue.text)
            XCTAssertEqual(cue.end, e.1, accuracy: 0.0005, cue.text)
        }
        XCTAssertEqual(doc.cues[2].text, "Coordinates")
        XCTAssertEqual(doc.cues[5].id, "3")
    }

    func testEmptyCuesDroppedAndUnsortedNormalized() throws {
        let text = """
        1
        00:00:10,000 --> 00:00:11,000
        Late

        2
        00:00:05,000 --> 00:00:06,000

        3
        00:00:01,000 --> 00:00:02,000
        Early

        4
        00:00:07,000 --> 00:00:08,000
        <i> </i>{\\an8}
        """
        let doc = try parse(text)
        XCTAssertEqual(doc.cues.map(\.text), ["Early", "Late"])
        XCTAssertEqual(doc.cues.map(\.id), ["3", "1"])
        XCTAssertEqual(doc.cues.map(\.index), [0, 1])
    }

    func testTagsFontsAlignmentEntities() throws {
        let text = """
        1
        00:00:01,000 --> 00:00:02,000
        <I>Shout</I> and <B><u>stress</u></B>

        2
        00:00:03,000 --> 00:00:04,000
        <font color="#ffff00" face="Arial">Yellow <i>words</i></font>

        3
        00:00:05,000 --> 00:00:06,000
        {\\an8}Top &amp; centre &lt;3

        4
        00:00:07,000 --> 00:00:08,000
        <i>Across
        two lines</i>

        5
        00:00:09,000 --> 00:00:10,000
        I <3 you & a < b > c&nbsp;d
        """
        let doc = try parse(text)
        XCTAssertEqual(doc.cues[0].text, "<i>Shout</i> and <b><u>stress</u></b>")
        XCTAssertEqual(doc.cues[1].text, "Yellow <i>words</i>")
        XCTAssertEqual(doc.cues[1].rawText, "<font color=\"#ffff00\" face=\"Arial\">Yellow <i>words</i></font>")
        XCTAssertEqual(doc.cues[2].text, "Top & centre <3")
        XCTAssertEqual(doc.cues[2].style?.alignment, 8)
        XCTAssertEqual(doc.cues[3].text, "<i>Across</i>\n<i>two lines</i>")
        XCTAssertEqual(doc.cues[4].text, "I <3 you & a < b > c\u{00A0}d")
        XCTAssertNil(doc.cues[0].style)
    }

    func testASSOverridesInsideSRT() throws {
        let doc = try parse("1\n00:00:01,000 --> 00:00:02,000\n{\\i1}Italic{\\i0} plain {\\pos(10,20)}{\\b1}bold\n")
        XCTAssertEqual(doc.cues[0].text, "<i>Italic</i> plain <b>bold</b>")
        XCTAssertEqual(doc.cues[0].rawText, "{\\i1}Italic{\\i0} plain {\\pos(10,20)}{\\b1}bold")
    }

    func testUnbalancedTagsAreBalanced() throws {
        let doc = try parse("1\n00:00:01,000 --> 00:00:02,000\n<i>Open only\nStray close</b> end\n")
        XCTAssertEqual(doc.cues[0].text, "<i>Open only</i>\n<i>Stray close end</i>")
    }

    func testEndBeforeStartIsClamped() throws {
        let doc = try parse("1\n00:00:05,000 --> 00:00:04,000\nBackwards\n")
        XCTAssertEqual(doc.cues[0].start, 5)
        XCTAssertEqual(doc.cues[0].end, 5)
    }

    func testTextThatLooksLikeANumber() throws {
        let doc = try parse("1\n00:00:01,000 --> 00:00:02,000\n42\n\n2\n00:00:03,000 --> 00:00:04,000\nNext\n")
        XCTAssertEqual(doc.cues.map(\.text), ["42", "Next"])
    }

    func testConcatenatedFilesWithStrayBOM() throws {
        let doc = try parse("\u{FEFF}1\n00:00:01,000 --> 00:00:02,000\nPart one\n\n\u{FEFF}1\n00:10:00,000 --> 00:10:02,000\nPart two\n")
        XCTAssertEqual(doc.cues.map(\.text), ["Part one", "Part two"])
        XCTAssertEqual(doc.cues.map(\.id), ["c1", "c2"]) // duplicate counters
    }

    func testArrowInsideTextIsNotATimingLine() throws {
        let doc = try parse("1\n00:00:01,000 --> 00:00:02,000\nGo --> there\n")
        XCTAssertEqual(doc.cues.map(\.text), ["Go --> there"])
    }
}
