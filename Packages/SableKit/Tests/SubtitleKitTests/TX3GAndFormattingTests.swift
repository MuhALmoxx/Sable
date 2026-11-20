import XCTest
@testable import SubtitleKit

final class TX3GTests: XCTestCase {
    private func sample(_ text: [UInt8], declared: Int? = nil, trailing: [UInt8] = []) -> Data {
        let n = declared ?? text.count
        return Data([UInt8(n >> 8), UInt8(n & 0xFF)] + text + trailing)
    }

    func testUTF8() {
        XCTAssertEqual(TX3GDecoder.decodeSample(sample(bytes("Hello\nworld"))), "Hello\nworld")
        XCTAssertEqual(TX3GDecoder.decodeSample(sample(bytes("مرحبا"))), "مرحبا")
    }

    func testStyleBoxesAreIgnored() {
        // 'styl' box after the text.
        let styl: [UInt8] = [0, 0, 0, 22, 0x73, 0x74, 0x79, 0x6C, 0, 1, 0, 0, 0, 5, 0, 1, 1, 18, 0xFF, 0xFF, 0xFF, 0xFF]
        XCTAssertEqual(TX3GDecoder.decodeSample(sample(bytes("Styled"), trailing: styl)), "Styled")
    }

    func testUTF16WithBOM() {
        let units = Array("Hé مرحبا".utf16)
        let be: [UInt8] = [0xFE, 0xFF] + units.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
        XCTAssertEqual(TX3GDecoder.decodeSample(sample(be)), "Hé مرحبا")
        let le: [UInt8] = [0xFF, 0xFE] + units.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
        XCTAssertEqual(TX3GDecoder.decodeSample(sample(le)), "Hé مرحبا")
    }

    func testEmptyAndMalformed() {
        XCTAssertNil(TX3GDecoder.decodeSample(Data()))
        XCTAssertNil(TX3GDecoder.decodeSample(Data([0])))
        XCTAssertNil(TX3GDecoder.decodeSample(Data([0, 0])))
        XCTAssertNil(TX3GDecoder.decodeSample(Data([0, 0, 0x41]))) // length 0 = gap
        XCTAssertNil(TX3GDecoder.decodeSample(sample(bytes("  \n"))))
        XCTAssertEqual(TX3GDecoder.decodeSample(sample(bytes("Cut"), declared: 50)), "Cut") // declared > available
        XCTAssertEqual(TX3GDecoder.decodeSample(sample(bytes("A\r\nB\r"))), "A\nB")
    }

    func testSliceOfLargerData() {
        let whole = Data([9, 9, 9] + [0, 2] + bytes("Hi"))
        XCTAssertEqual(TX3GDecoder.decodeSample(whole.subdata(in: 3..<whole.count)), "Hi")
        XCTAssertEqual(TX3GDecoder.decodeSample(whole[3...]), "Hi")
    }
}

final class FormattingTests: XCTestCase {
    func testPlayerTime() {
        XCTAssertEqual(TimecodeFormatter.playerTime(0), "0:00")
        XCTAssertEqual(TimecodeFormatter.playerTime(5.9), "0:05")
        XCTAssertEqual(TimecodeFormatter.playerTime(123), "2:03")
        XCTAssertEqual(TimecodeFormatter.playerTime(3723), "1:02:03")
        XCTAssertEqual(TimecodeFormatter.playerTime(36_000 * 3), "30:00:00")
        XCTAssertEqual(TimecodeFormatter.playerTime(-65), "\u{2212}1:05")
        XCTAssertEqual(TimecodeFormatter.playerTime(-0.4), "0:00")
        XCTAssertEqual(TimecodeFormatter.playerTime(.nan), "0:00")
        XCTAssertEqual(TimecodeFormatter.playerTime(.infinity), "0:00")
    }

    func testPrecise() {
        XCTAssertEqual(TimecodeFormatter.precise(3723.456), "01:02:03.456")
        XCTAssertEqual(TimecodeFormatter.precise(0), "00:00:00.000")
        XCTAssertEqual(TimecodeFormatter.precise(59.9999), "00:01:00.000")
        XCTAssertEqual(TimecodeFormatter.precise(-1.5), "\u{2212}00:00:01.500")
        XCTAssertEqual(TimecodeFormatter.precise(360_000), "100:00:00.000")
    }

    func testSignedOffset() {
        XCTAssertEqual(TimecodeFormatter.signedOffset(1.3), "+1.300 s")
        XCTAssertEqual(TimecodeFormatter.signedOffset(-0.1), "\u{2212}0.100 s")
        XCTAssertEqual(TimecodeFormatter.signedOffset(0), "0.000 s")
        XCTAssertEqual(TimecodeFormatter.signedOffset(0.0004), "0.000 s")
        XCTAssertEqual(TimecodeFormatter.signedOffset(-0.0004), "0.000 s")
        XCTAssertEqual(TimecodeFormatter.signedOffset(125.25), "+125.250 s")
        XCTAssertEqual(TimecodeFormatter.signedOffset(-3600), "\u{2212}3600.000 s")
    }

    func testOffsetInputAccepts() throws {
        let cases: [(String, Double)] = [
            ("1.5", 1.5), ("+1.5", 1.5), ("-1.5", -1.5), ("\u{2212}1.5", -1.5), ("-90", -90), ("1:02.5", 62.5),
            ("-1:02:03.25", -3723.25), ("250ms", 0.25), ("-2s", -2), (",5", 0.5), ("0,5", 0.5), ("  2.25 s ", 2.25),
            ("-250 ms", -0.25), ("3 sec", 3), ("+0", 0), ("12:00", 720), ("100000", 100_000), ("5.", 5),
            ("\u{2013}0.3", -0.3), ("1:2:3", 3723),
        ]
        for (input, expected) in cases {
            let value = try XCTUnwrap(OffsetInput.parse(input), input)
            XCTAssertEqual(value, expected, accuracy: 1e-9, input)
        }
    }

    func testOffsetInputRejectsGarbage() {
        for input in ["", "   ", "abc", "1.2.3", "--1", "+-1", "1e5", "1:02ms", "1::2", ":30", "1:2:3:4", "s", "ms", "1,5,0",
                      "1 5", "0x10", "nan", "inf", "1:-2", "- 1:x"] {
            XCTAssertNil(OffsetInput.parse(input), input)
        }
    }
}
