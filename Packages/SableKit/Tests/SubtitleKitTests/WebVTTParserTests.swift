import XCTest
@testable import SubtitleKit

final class WebVTTParserTests: XCTestCase {
    private func parse(_ text: String) throws -> SubtitleDocument {
        try SubtitleParser.parse(string: text, format: .webvtt)
    }

    func testHeaderBlocksAndIDs() throws {
        let text = """
        \u{FEFF}WEBVTT - Night Roof
        Kind: captions
        Language: en

        STYLE
        ::cue(.loud) { color: yellow; }

        REGION
        id:bill width:40%

        NOTE This is a comment
        spanning two lines

        intro
        00:01.000 --> 00:02.500
        Hello

        00:00:03.000 --> 00:00:04.000
        No identifier

        NOTE another note

        1:02:03.004 --> 1:02:04.000
        Hours
        """
        let doc = try parse(text)
        XCTAssertEqual(doc.format, .webvtt)
        XCTAssertEqual(doc.language, .english)
        XCTAssertEqual(doc.cues.map(\.text), ["Hello", "No identifier", "Hours"])
        XCTAssertEqual(doc.cues.map(\.id), ["intro", "c2", "c3"])
        XCTAssertEqual(doc.cues[0].start, 1, accuracy: 0.0001)
        XCTAssertEqual(doc.cues[0].end, 2.5, accuracy: 0.0001)
        XCTAssertEqual(doc.cues[2].start, 3723.004, accuracy: 0.0001)
    }

    func testSpansAndEntities() throws {
        let text = """
        WEBVTT

        00:01.000 --> 00:02.000
        <v Mara>Hello</v> <v.loud Idris>there</v>

        00:03.000 --> 00:04.000
        <c.yellow.bg_blue>Coloured</c> <lang fr>bonjour</lang> <i.foo>italic</i>

        00:05.000 --> 00:06.000
        <ruby>漢<rt>かん</rt>字<rt>じ</rt></ruby> and <ruby>base<rt>annotation</ruby>

        00:07.000 --> 00:08.000
        Karaoke <00:07.500>words <00:00:07.900>here

        00:09.000 --> 00:10.000
        Tom &amp; Jerry &lt;3 &gt; a&nbsp;b &lrm;x&rlm; &#1575;&#x644;
        """
        let doc = try parse(text)
        XCTAssertEqual(doc.cues.map(\.text), [
            "Hello there",
            "Coloured bonjour <i>italic</i>",
            "漢字 and base",
            "Karaoke words here",
            "Tom & Jerry <3 > a\u{00A0}b \u{200E}x\u{200F} ال",
        ])
        XCTAssertEqual(doc.cues[0].rawText, "<v Mara>Hello</v> <v.loud Idris>there</v>")
    }

    func testCueSettingsToAlignment() {
        XCTAssertNil(WebVTTParser.alignment(fromSettings: ""))
        XCTAssertNil(WebVTTParser.alignment(fromSettings: "align:center line:-1"))
        XCTAssertEqual(WebVTTParser.alignment(fromSettings: "line:0"), 8)
        XCTAssertEqual(WebVTTParser.alignment(fromSettings: "line:10%"), 8)
        XCTAssertEqual(WebVTTParser.alignment(fromSettings: "line:50%,center"), 5)
        XCTAssertNil(WebVTTParser.alignment(fromSettings: "line:90%")) // bottom centre = default
        XCTAssertEqual(WebVTTParser.alignment(fromSettings: "align:start"), 1)
        XCTAssertEqual(WebVTTParser.alignment(fromSettings: "align:end line:0"), 9)
        XCTAssertEqual(WebVTTParser.alignment(fromSettings: "position:10% align:center"), 1)
        XCTAssertEqual(WebVTTParser.alignment(fromSettings: "position:90%,line-right line:0"), 9)
        XCTAssertEqual(WebVTTParser.alignment(fromSettings: "vertical:rl size:50%"), nil)
    }

    func testSettingsAreApplied() throws {
        let doc = try parse("WEBVTT\n\n00:01.000 --> 00:02.000 line:0 align:start\nTop left\n")
        XCTAssertEqual(doc.cues[0].style?.alignment, 7)
    }

    func testToleratesMissingHeaderAndCommaMillis() throws {
        let doc = try parse("00:01,000 --> 00:02,000\nNo header\n")
        XCTAssertEqual(doc.cues.map(\.text), ["No header"])
    }

    func testDuplicateIdentifiersFallBack() throws {
        let doc = try parse("WEBVTT\n\nx\n00:01.000 --> 00:02.000\nA\n\nx\n00:03.000 --> 00:04.000\nB\n\nc1\n00:05.000 --> 00:06.000\nC\n")
        XCTAssertEqual(doc.cues.map(\.id), ["c1_2", "c2", "c1"])
        XCTAssertEqual(Set(doc.cues.map(\.id)).count, 3)
    }

    func testHeaderWithCueDirectlyAfterIsNotLost() throws {
        let doc = try parse("WEBVTT\n00:01.000 --> 00:02.000\nRight after header\n")
        XCTAssertEqual(doc.cues.map(\.text), ["Right after header"])
    }

    func testEmptyPayloadDropped() throws {
        let doc = try parse("WEBVTT\n\n00:01.000 --> 00:02.000\n<v Someone></v>\n\n00:03.000 --> 00:04.000\nKept\n")
        XCTAssertEqual(doc.cues.map(\.text), ["Kept"])
    }

    func testFixtureMatchesSRT() throws {
        let vtt = try Fixtures.document("sample.en.vtt")
        let srt = try Fixtures.document("sample.en.srt")
        XCTAssertEqual(vtt.cues.first?.id, "title")
        XCTAssertEqual(vtt.cues.first?.style?.alignment, 8)
        assertSameCues(Array(vtt.cues.dropFirst()), srt.cues, compareIDs: true)
    }
}
