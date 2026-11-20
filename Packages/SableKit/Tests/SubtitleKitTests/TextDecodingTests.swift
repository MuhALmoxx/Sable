import XCTest
@testable import SubtitleKit

final class TextDecodingTests: XCTestCase {
    private let arabic = "مرحبا، كيف حالك؟"

    /// Encodes with our own Windows-1256 table (inverse lookup), so the test is independent of
    /// the platform's encodings.
    private func cp1256(_ s: String) -> [UInt8] {
        var inverse: [UInt32: UInt8] = [:]
        for (i, v) in TextDecoding.windows1256.enumerated() { inverse[v] = UInt8(0x80 + i) }
        return s.unicodeScalars.map { $0.value < 0x80 ? UInt8($0.value) : inverse[$0.value]! }
    }

    private func cp1252(_ s: String) -> [UInt8] {
        var inverse: [UInt32: UInt8] = [:]
        for (i, v) in TextDecoding.windows1252.enumerated() { inverse[v] = UInt8(0x80 + i) }
        return s.unicodeScalars.map { $0.value < 0x80 ? UInt8($0.value) : inverse[$0.value]! }
    }

    func testUTF8WithAndWithoutBOM() throws {
        XCTAssertEqual(try SubtitleParser.decodeText(Data(bytes("Hello — \(arabic)"))), "Hello — \(arabic)")
        XCTAssertEqual(try SubtitleParser.decodeText(Data([0xEF, 0xBB, 0xBF] + bytes("Hi"))), "Hi")
        XCTAssertEqual(try SubtitleParser.decodeText(Data()), "")
    }

    func testUTF16WithBOM() throws {
        let text = "1\n00:00:01,000 --> 00:00:02,000\n\(arabic) é"
        let units = Array(text.utf16)
        let le: [UInt8] = [0xFF, 0xFE] + units.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
        let be: [UInt8] = [0xFE, 0xFF] + units.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
        XCTAssertEqual(try SubtitleParser.decodeText(Data(le)), text)
        XCTAssertEqual(try SubtitleParser.decodeText(Data(be)), text)
    }

    func testUTF16WithoutBOMIsDetected() throws {
        let text = "1\n00:00:01,000 --> 00:00:02,000\nHello there\n"
        let le: [UInt8] = Array(text.utf16).flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
        XCTAssertEqual(try SubtitleParser.decodeText(Data(le)), text)
        let be: [UInt8] = Array(text.utf16).flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
        XCTAssertEqual(try SubtitleParser.decodeText(Data(be)), text)
    }

    func testUTF32WithBOM() throws {
        let text = "Hi \(arabic)"
        let le: [UInt8] = [0xFF, 0xFE, 0, 0] + text.unicodeScalars.flatMap { s -> [UInt8] in
            let v = s.value
            return [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)]
        }
        XCTAssertEqual(try SubtitleParser.decodeText(Data(le)), text)
    }

    func testWindows1256Arabic() throws {
        let srt = "1\r\n00:00:01,000 --> 00:00:02,000\r\n\(arabic)\r\n\r\n2\r\n00:00:03,000 --> 00:00:04,000\r\n<i>نعم</i> 2024\r\n"
        let data = Data(cp1256(srt))
        XCTAssertNil(String(data: data, encoding: .utf8), "precondition: not valid UTF-8")
        XCTAssertEqual(try SubtitleParser.decodeText(data), srt)
        let doc = try SubtitleParser.parse(data: data, fileExtension: "srt")
        XCTAssertEqual(doc.cues.map(\.text), [arabic, "<i>نعم</i> 2024"])
    }

    func testWindows1256ShortWord() throws {
        XCTAssertEqual(try SubtitleParser.decodeText(Data(cp1256("نعم"))), "نعم")
    }

    func testWindows1252WesternTextIsNotMistakenForArabic() throws {
        for sample in ["Mädchen, Straße und Größe", "¿Dónde está el niño?", "Ça va très bien, à bientôt", "Ångström – “quoted” €5"] {
            XCTAssertEqual(try SubtitleParser.decodeText(Data(cp1252(sample))), sample, sample)
        }
    }

    func testISOLatin1FallbackForUndefined1252Bytes() throws {
        // 0x81 is undefined in Windows-1252: decode as ISO-8859-1 (C1 control), keep é.
        let decoded = try SubtitleParser.decodeText(Data([0x63, 0x61, 0x66, 0xE9, 0x81, 0x20, 0x6F, 0x6B]))
        XCTAssertEqual(decoded, "caf\u{E9}\u{81} ok")
    }

    func testValidUTF8WinsOverLegacy() throws {
        // "é" in UTF-8 is C3 A9, which would read as "Ã©" in 1252.
        XCTAssertEqual(try SubtitleParser.decodeText(Data(bytes("café"))), "café")
    }

    func testBinaryDataThrows() {
        var garbage: [UInt8] = []
        var x: UInt32 = 12345
        for _ in 0..<4000 {
            x = x &* 1103515245 &+ 12345
            garbage.append(UInt8(truncatingIfNeeded: x >> 16))
        }
        XCTAssertThrowsError(try SubtitleParser.decodeText(Data(garbage))) { error in
            XCTAssertEqual(error as? SubtitleError, .unreadableEncoding)
        }
    }

    func testTrailingNULPaddingIsIgnored() throws {
        XCTAssertEqual(try SubtitleParser.decodeText(Data(bytes("Hi") + [0, 0, 0])), "Hi")
    }

    func testTablesHave128Entries() {
        XCTAssertEqual(TextDecoding.windows1256.count, 128)
        XCTAssertEqual(TextDecoding.windows1252.count, 128)
        XCTAssertEqual(TextDecoding.windows1256[0xC7 - 0x80], 0x0627) // ا
        XCTAssertEqual(TextDecoding.windows1256[0xBF - 0x80], 0x061F) // ؟
        XCTAssertEqual(TextDecoding.windows1252[0x80 - 0x80], 0x20AC) // €
    }

    func testFormatDetectionFromContent() throws {
        let vtt = "WEBVTT\n\n00:01.000 --> 00:02.000\nHello\n"
        // A .srt that is really WebVTT.
        XCTAssertEqual(try SubtitleParser.parse(data: Data(bytes(vtt)), fileExtension: "srt").format, .webvtt)
        XCTAssertEqual(try SubtitleParser.parse(data: Data(bytes(vtt)), fileExtension: nil).format, .webvtt)
        let srt = "1\n00:00:01,000 --> 00:00:02,000\nHello\n"
        XCTAssertEqual(try SubtitleParser.parse(data: Data(bytes(srt)), fileExtension: "txt").format, .srt)
        XCTAssertEqual(try SubtitleParser.parse(data: Data(bytes(srt)), fileExtension: ".SRT").format, .srt)
        XCTAssertEqual(SubtitleParser.sniffFormat("[Script Info]\nScriptType: v4.00+\n"), .ass)
        XCTAssertEqual(SubtitleParser.sniffFormat("[Script Info]\nScriptType: v4.00\n[V4 Styles]\n"), .ssa)
        XCTAssertNil(SubtitleParser.sniffFormat("just some words"))
        XCTAssertThrowsError(try SubtitleParser.parse(data: Data(bytes("nothing here")), fileExtension: "txt")) { error in
            XCTAssertEqual(error as? SubtitleError, .unsupportedFormat("txt"))
        }
        XCTAssertThrowsError(try SubtitleParser.parse(data: Data(bytes("1\nno timing\n")), fileExtension: "srt")) { error in
            XCTAssertEqual(error as? SubtitleError, .empty)
        }
        XCTAssertThrowsError(try SubtitleParser.parse(string: "x", format: .tx3g))
    }
}
