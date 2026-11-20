import XCTest
@testable import SubtitleKit

final class SRTWriterTests: XCTestCase {
    private func cue(_ id: String, _ i: Int, _ s: Double, _ e: Double, _ t: String) -> SubtitleCue {
        SubtitleCue(id: id, index: i, start: s, end: e, text: t)
    }

    func testTimestamp() {
        XCTAssertEqual(SRTWriter.timestamp(0), "00:00:00,000")
        XCTAssertEqual(SRTWriter.timestamp(3723.456), "01:02:03,456")
        XCTAssertEqual(SRTWriter.timestamp(59.9996), "00:01:00,000")
        XCTAssertEqual(SRTWriter.timestamp(1.0005), "00:00:01,001")
        XCTAssertEqual(SRTWriter.timestamp(123 * 3600 + 1), "123:00:01,000")
        XCTAssertEqual(SRTWriter.timestamp(-5), "00:00:00,000")
        XCTAssertEqual(SRTWriter.timestamp(.nan), "00:00:00,000")
    }

    func testBasicWrite() {
        let doc = SubtitleDocument(format: .srt, cues: [cue("x", 0, 1, 2.5, "Hello\nworld"), cue("y", 1, 3, 4, "<i>Bye</i>")])
        XCTAssertEqual(SRTWriter.write(doc),
                       "1\r\n00:00:01,000 --> 00:00:02,500\r\nHello\r\nworld\r\n\r\n2\r\n00:00:03,000 --> 00:00:04,000\r\n<i>Bye</i>\r\n\r\n")
        let lf = SRTWriter.write(doc, options: SRTExportOptions(lineEnding: "\n", keepInlineTags: false))
        XCTAssertEqual(lf, "1\n00:00:01,000 --> 00:00:02,500\nHello\nworld\n\n2\n00:00:03,000 --> 00:00:04,000\nBye\n\n")
    }

    func testTimingAppliedAndClamped() {
        let doc = SubtitleDocument(format: .srt, cues: [
            cue("a", 0, 0.5, 1.0, "Entirely before zero after shift"),
            cue("b", 1, 1.5, 3.0, "Straddles zero"),
            cue("c", 2, 10, 12, "Normal"),
        ])
        let out = SRTWriter.write(doc, options: SRTExportOptions(timing: SubtitleTiming(offset: -2), lineEnding: "\n"))
        XCTAssertEqual(out, "1\n00:00:00,000 --> 00:00:01,000\nStraddles zero\n\n2\n00:00:08,000 --> 00:00:10,000\nNormal\n\n")
        // Original timestamps untouched when timing is nil, even if an offset exists elsewhere.
        XCTAssertTrue(SRTWriter.write(doc).contains("00:00:10,000 --> 00:00:12,000"))
        // Scale.
        let scaled = SRTWriter.write(doc, options: SRTExportOptions(timing: SubtitleTiming(offset: 1, scale: 1.001)))
        XCTAssertTrue(scaled.contains("00:00:11,010 --> 00:00:13,012"))
    }

    func testRTLMarks() {
        let doc = SubtitleDocument(format: .srt, cues: [cue("a", 0, 1, 2, "مرحبا!\nOK 123\n\u{202B}موجود\u{202C}")])
        let out = SRTWriter.write(doc, options: SRTExportOptions(addRTLMarks: true, lineEnding: "\n"))
        XCTAssertEqual(out, "1\n00:00:01,000 --> 00:00:02,000\n\u{202B}مرحبا!\u{202C}\nOK 123\n\u{202B}موجود\u{202C}\n\n")
        XCTAssertFalse(SRTWriter.write(doc).contains("\u{202B}مرحبا"))
    }

    func testBlankLinesAndEmptyCuesNeverBreakTheFile() {
        let doc = SubtitleDocument(format: .srt, cues: [cue("a", 0, 1, 2, "Top\n\n  \nBottom"), cue("b", 1, 3, 4, "  "), cue("c", 2, 5, 6, "Last")])
        let out = SRTWriter.write(doc, options: SRTExportOptions(lineEnding: "\n"))
        XCTAssertEqual(out, "1\n00:00:01,000 --> 00:00:02,000\nTop\nBottom\n\n2\n00:00:05,000 --> 00:00:06,000\nLast\n\n")
    }

    func testDialogueOrderEvenIfArrayIsUnsorted() {
        let doc = SubtitleDocument(format: .srt, cues: [cue("b", 1, 5, 6, "Second"), cue("a", 0, 1, 2, "First")])
        let reparsed = try? SubtitleParser.parse(string: SRTWriter.write(doc), format: .srt)
        XCTAssertEqual(reparsed?.cues.map(\.text), ["First", "Second"])
    }

    func testRoundTripSRTFixture() throws {
        let original = try Fixtures.document("sample.en.srt")
        let written = SRTWriter.write(original)
        let reparsed = try SubtitleParser.parse(data: Data(bytes(written)), fileExtension: "srt")
        assertSameCues(reparsed.cues, original.cues, compareIDs: true)
        // Idempotent: writing the reparsed document gives the same bytes.
        XCTAssertEqual(SRTWriter.write(reparsed), written)
    }

    func testRoundTripASSAndVTTThroughSRT() throws {
        for name in ["sample.en.ass", "sample.en.vtt", "sample.fr.srt"] {
            let original = try Fixtures.document(name)
            let reparsed = try SubtitleParser.parse(string: SRTWriter.write(original), format: .srt)
            assertSameCues(reparsed.cues, original.cues)
            XCTAssertEqual(reparsed.cues.map(\.id), (1...original.cues.count).map(String.init), name)
        }
    }

    func testRoundTripArabicWithMarksAndTags() throws {
        let doc = SubtitleDocument(format: .srt, cues: [
            cue("1", 0, 3, 5.2, "<i>مارا، هل ما زلتِ مستيقظة؟</i>"),
            cue("2", 1, 7.5, 10.4, "لا أستطيع النوم.\nالمدينة صاخبة جدًا الليلة."),
        ])
        let written = SRTWriter.write(doc, options: SRTExportOptions(timing: SubtitleTiming(offset: 2.5), addRTLMarks: true))
        let reparsed = try SubtitleParser.parse(string: written, format: .srt)
        XCTAssertEqual(reparsed.cues.count, 2)
        XCTAssertEqual(reparsed.cues[0].start, 5.5, accuracy: 0.0005)
        XCTAssertEqual(reparsed.cues[1].end, 12.9, accuracy: 0.0005)
        let stripMarks: (String) -> String = { $0.replacingOccurrences(of: "\u{202B}", with: "").replacingOccurrences(of: "\u{202C}", with: "") }
        XCTAssertEqual(reparsed.cues.map { stripMarks($0.text) }, doc.cues.map(\.text))
    }
}
