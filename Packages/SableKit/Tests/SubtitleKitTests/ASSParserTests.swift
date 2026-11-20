import XCTest
@testable import SubtitleKit

final class ASSParserTests: XCTestCase {
    private func parse(_ text: String, format: SubtitleFormat = .ass) throws -> SubtitleDocument {
        try SubtitleParser.parse(string: text, format: format)
    }

    private func script(styles: String = "Style: Default,Arial,20,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,0,2,10,10,10,1",
                        format: String = "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text",
                        events: [String]) -> String {
        """
        [Script Info]
        Title: Test
        ScriptType: v4.00+

        [V4+ Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
        \(styles)

        [Events]
        \(format)
        \(events.joined(separator: "\n"))
        """
    }

    func testFixture() throws {
        let doc = try Fixtures.document("sample.en.ass")
        XCTAssertEqual(doc.format, .ass)
        XCTAssertEqual(doc.title, "Sable sample (styled)")
        XCTAssertEqual(doc.cues.count, 10)
        XCTAssertEqual(doc.cues.map(\.id), (1...10).map { "a\($0)" })
        let sign = doc.cues[0]
        XCTAssertEqual(sign.start, 0.5, accuracy: 0.0001)
        XCTAssertEqual(sign.end, 2.5, accuracy: 0.0001)
        XCTAssertEqual(sign.text, "<b>NIGHT CITY — 2:14 AM</b>") // Sign style is bold
        XCTAssertEqual(sign.style, CueStyleHint(alignment: 8, styleName: "Sign", italic: false, bold: true))
        XCTAssertEqual(sign.rawText, "{\\an8}NIGHT CITY — 2:14 AM")
        XCTAssertEqual(doc.cues[2].text, "I can't sleep.\nThe city is too loud tonight.")
        XCTAssertEqual(doc.cues[2].style?.alignment, 2)
        XCTAssertEqual(doc.cues[2].style?.styleName, "Default")
        XCTAssertEqual(doc.cues[4].text, "<i>Is it safe?</i>")
        XCTAssertEqual(doc.cues[7].text, "You sound like your father, Idris.")
        let header = try XCTUnwrap(doc.header)
        XCTAssertTrue(header.hasPrefix("[Script Info]\nTitle: Sable sample (styled)"))
        XCTAssertTrue(header.contains("Style: Sign,Arial,52"))
        XCTAssertFalse(header.contains("[Events]"))
    }

    func testFixtureDialogueMatchesSRT() throws {
        let ass = try Fixtures.document("sample.en.ass")
        let srt = try Fixtures.document("sample.en.srt")
        assertSameCues(Array(ass.cues.dropFirst()), srt.cues)
    }

    func testOverrides() throws {
        let doc = try parse(script(events: [
            "Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,{\\i1}Ital{\\i0}ic {\\b1}bold{\\b0} {\\u1}under{\\u}",
            "Dialogue: 0,0:00:03.00,0:00:04.00,Default,,0,0,0,,{\\pos(100,200)\\fs40\\c&H00FF00&\\t(0,500,\\i1\\fs20)}Styled, with, commas",
            "Dialogue: 0,0:00:05.00,0:00:06.00,Default,,0,0,0,,Line one\\NLine two\\nLine three\\hend",
            "Dialogue: 0,0:00:07.00,0:00:08.00,Default,,0,0,0,,{\\a6}Legacy top{\\an1}",
            "Dialogue: 0,0:00:09.00,0:00:10.00,Default,,0,0,0,,{\\p1}m 0 0 l 100 0 100 100 0 100{\\p0}",
            "Dialogue: 0,0:00:11.00,0:00:12.00,Default,,0,0,0,,{Translator note}Visible{\\p2}m 0 0 l 1 1{\\p0} after",
            "Comment: 0,0:00:13.00,0:00:14.00,Default,,0,0,0,,Commented out",
            "Dialogue: 0,0:00:15.00,0:00:16.00,Default,,0,0,0,,{\\b700}Heavy{\\b400} normal {\\i1}a{\\r}b",
            "Dialogue: 0,0:00:17.00,0:00:18.00,Default,,0,0,0,,  ",
        ]))
        XCTAssertEqual(doc.cues.map(\.text), [
            "<i>Ital</i>ic <b>bold</b> <u>under</u>",
            "Styled, with, commas",
            "Line one\nLine two\nLine three end",
            "Legacy top",
            "Visible after",
            "<b>Heavy</b> normal <i>a</i>b",
        ])
        XCTAssertEqual(doc.cues.map(\.id), ["a1", "a2", "a3", "a4", "a6", "a7"])
        XCTAssertEqual(doc.cues[3].style?.alignment, 8) // \a6 = top centre; later \an1 ignored
        XCTAssertEqual(doc.cues[0].style?.alignment, 2)
    }

    func testStyleDefaultsAndFormatOrder() throws {
        let styles = """
        Style: Default,Arial,20,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,0,2,10,10,10,1
        Style: Narration,Arial,20,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,-1,-1,0,0,100,100,0,0,1,2,0,7,10,10,10,1
        """
        // Fields reordered: Text is still last, Style comes first.
        let doc = try parse(script(styles: styles, format: "Format: Style, Start, End, Layer, Name, MarginL, MarginR, MarginV, Effect, Text",
                                   events: ["Dialogue: Narration,0:00:01.00,0:00:02.00,0,,0,0,0,,Told {\\i0}plainly",
                                            "Dialogue: *Narration,0:00:03.00,0:00:04.00,0,,0,0,0,,Star",
                                            "Dialogue: missing,0:00:05.00,0:00:06.00,0,,0,0,0,,Unknown style"]))
        XCTAssertEqual(doc.cues[0].text, "<b><i>Told </i>plainly</b>")
        XCTAssertEqual(doc.cues[0].style, CueStyleHint(alignment: 7, styleName: "Narration", italic: true, bold: true))
        XCTAssertEqual(doc.cues[1].style?.alignment, 7)
        XCTAssertEqual(doc.cues[2].style?.alignment, 2) // falls back to Default
        XCTAssertEqual(doc.cues[2].style?.styleName, "missing")
    }

    func testSSAv4() throws {
        let text = """
        [Script Info]
        ScriptType: v4.00

        [V4 Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, TertiaryColour, BackColour, Bold, Italic, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, AlphaLevel, Encoding
        Style: Default,Arial,20,16777215,65535,65535,-2147483640,0,-1,1,3,0,6,30,30,30,0,0

        [Events]
        Format: Marked, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: Marked=0,0:00:01.00,0:00:02.50,Default,,0000,0000,0000,,Top centre, italic
        Dialogue: Marked=0,0:00:03.00,0:00:04.00,Default,,0000,0000,0000,,{\\a9}Middle left
        """
        let doc = try SubtitleParser.parse(data: Data(bytes(text)), fileExtension: "ssa")
        XCTAssertEqual(doc.format, .ssa)
        XCTAssertEqual(doc.cues[0].text, "<i>Top centre, italic</i>")
        XCTAssertEqual(doc.cues[0].style?.alignment, 8) // SSA 6 -> numpad 8
        XCTAssertEqual(doc.cues[1].style?.alignment, 4) // SSA 9 -> numpad 4
        XCTAssertEqual(doc.cues[0].end, 2.5, accuracy: 0.0001)
    }

    func testMissingFormatLinesUseDefaults() throws {
        let text = "[Script Info]\nScriptType: v4.00+\n\n[Events]\nDialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,Hello, world\n"
        let doc = try parse(text)
        XCTAssertEqual(doc.cues.map(\.text), ["Hello, world"])
        XCTAssertNil(doc.cues[0].style?.alignment)
    }

    func testSSALegacyAlignmentConversion() {
        XCTAssertEqual(ASSOverrides.numpad(fromSSA: 1), 1)
        XCTAssertEqual(ASSOverrides.numpad(fromSSA: 2), 2)
        XCTAssertEqual(ASSOverrides.numpad(fromSSA: 3), 3)
        XCTAssertEqual(ASSOverrides.numpad(fromSSA: 5), 7)
        XCTAssertEqual(ASSOverrides.numpad(fromSSA: 6), 8)
        XCTAssertEqual(ASSOverrides.numpad(fromSSA: 7), 9)
        XCTAssertEqual(ASSOverrides.numpad(fromSSA: 9), 4)
        XCTAssertEqual(ASSOverrides.numpad(fromSSA: 10), 5)
        XCTAssertEqual(ASSOverrides.numpad(fromSSA: 11), 6)
        XCTAssertNil(ASSOverrides.numpad(fromSSA: 0))
        XCTAssertNil(ASSOverrides.numpad(fromSSA: 4))
    }

    func testUnsortedEventsAreNormalizedButKeepIDs() throws {
        let doc = try parse(script(events: [
            "Dialogue: 0,0:00:05.00,0:00:06.00,Default,,0,0,0,,Second",
            "Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,First",
            "Dialogue: 1,0:00:01.00,0:00:02.00,Default,,0,0,0,,Same start, later in file",
        ]))
        XCTAssertEqual(doc.cues.map(\.text), ["First", "Same start, later in file", "Second"])
        XCTAssertEqual(doc.cues.map(\.id), ["a2", "a3", "a1"])
    }
}
