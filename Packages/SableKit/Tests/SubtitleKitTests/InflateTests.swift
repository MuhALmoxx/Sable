import XCTest
@testable import SubtitleKit

final class InflateTests: XCTestCase {
    static let shortText = "Mara, are you still awake?\nI can't sleep. — مرحبا"

    /// Same generator as the Python script that produced InflateVectors.largeZlib.
    static var largeText: String {
        (0..<1500).map { i -> String in
            "\(SRTWriter.pad(Int64(i), 5)) The quick brown fox jumps over the lazy dog; cue number \(i * 7 % 1000) ends here."
        }.joined(separator: "\n")
    }

    func testStoredBlock() throws {
        XCTAssertEqual(try Inflate.zlibDecompress(base64(InflateVectors.storedZlib)), bytes(Self.shortText))
    }

    func testFixedHuffman() throws {
        XCTAssertEqual(try Inflate.zlibDecompress(base64(InflateVectors.fixedZlib)), bytes(Self.shortText))
    }

    func testDynamicHuffman() throws {
        let expected = Array(bytes(Self.largeText).prefix(3000))
        XCTAssertEqual(try Inflate.zlibDecompress(base64(InflateVectors.dynamicZlib)), expected)
        XCTAssertEqual(try Inflate.inflateRaw(base64(InflateVectors.rawDeflate)).output, expected)
        // decompress() picks zlib or raw automatically.
        XCTAssertEqual(try Inflate.decompress(base64(InflateVectors.rawDeflate)), expected)
        XCTAssertEqual(try Inflate.decompress(base64(InflateVectors.dynamicZlib)), expected)
    }

    func testLargeStream() throws {
        let out = try Inflate.zlibDecompress(base64(InflateVectors.largeZlib))
        XCTAssertEqual(out.count, 115_324)
        XCTAssertEqual(out, bytes(Self.largeText))
    }

    func testMultipleBlocks() throws {
        let medium = Array(bytes(Self.largeText).prefix(3000))
        let expected = bytes(Self.shortText) + medium + bytes(Self.shortText)
        XCTAssertEqual(try Inflate.zlibDecompress(base64(InflateVectors.multiBlockZlib)), expected)
    }

    func testStoredHelperRoundTrip() throws {
        let data = (0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 31) }
        XCTAssertEqual(try Inflate.zlibDecompress(zlibStored(data)), data) // several 64 KB stored blocks
        XCTAssertEqual(try Inflate.zlibDecompress(zlibStored([])), [])
    }

    func testAdler32() {
        XCTAssertEqual(Inflate.adler32(bytes("Wikipedia")), 0x11E6_0398)
        XCTAssertEqual(Inflate.adler32([]), 1)
    }

    func testErrors() {
        var corrupted = base64(InflateVectors.dynamicZlib)
        corrupted[corrupted.count - 1] ^= 0xFF // Adler-32 trailer
        XCTAssertThrowsError(try Inflate.zlibDecompress(corrupted)) { XCTAssertEqual($0 as? InflateError, .checksumMismatch) }

        let truncated = Array(base64(InflateVectors.largeZlib).prefix(100))
        XCTAssertThrowsError(try Inflate.zlibDecompress(truncated)) { XCTAssertEqual($0 as? InflateError, .truncated) }

        XCTAssertThrowsError(try Inflate.zlibDecompress([0x78, 0x9C, 0x07])) // block type 3 (invalid)
        XCTAssertThrowsError(try Inflate.zlibDecompress([0x12, 0x34, 0x00])) { XCTAssertEqual($0 as? InflateError, .invalidHeader) }
        XCTAssertThrowsError(try Inflate.zlibDecompress([0x78, 0xBB, 0, 0, 0, 0])) { XCTAssertEqual($0 as? InflateError, .presetDictionary) }

        // Output limit (zip-bomb guard).
        XCTAssertThrowsError(try Inflate.zlibDecompress(base64(InflateVectors.largeZlib), maxOutputSize: 1000)) {
            XCTAssertEqual($0 as? InflateError, .outputLimitExceeded)
        }

        // Stored block with a bad NLEN.
        XCTAssertThrowsError(try Inflate.inflateRaw([0x01, 0x05, 0x00, 0x00, 0x00, 1, 2, 3, 4, 5])) {
            XCTAssertEqual($0 as? InflateError, .invalidStoredLength)
        }
        // Fixed block whose first symbol is length code 257 with distance 1: refers before the output.
        // Bits (LSB first): BFINAL=1, BTYPE=01, code 0000001, distance code 00000.
        XCTAssertThrowsError(try Inflate.inflateRaw([0x03, 0x02, 0x00])) { XCTAssertEqual($0 as? InflateError, .distanceTooFar) }
    }
}
