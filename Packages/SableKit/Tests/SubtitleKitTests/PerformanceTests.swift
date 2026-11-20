import XCTest
@testable import SubtitleKit

/// Sanity limits, generous enough for debug builds on CI runners.
final class PerformanceTests: XCTestCase {
    func testParseFiveThousandCueSRT() throws {
        var srt = ""
        srt.reserveCapacity(5000 * 80)
        for i in 0..<5000 {
            let start = Double(i) * 2.5
            srt += "\(i + 1)\r\n\(SRTWriter.timestamp(start)) --> \(SRTWriter.timestamp(start + 2))\r\n"
            srt += i % 3 == 0 ? "<i>Line \(i) of the film,</i>\r\nwith a second line.\r\n\r\n" : "Line \(i) — مرحبا {\\an8}\r\n\r\n"
        }
        let data = Data(bytes(srt))
        let started = Date()
        let doc = try SubtitleParser.parse(data: data, fileExtension: "srt")
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(doc.cues.count, 5000)
        XCTAssertEqual(doc.cues[4999].id, "5000")
        XCTAssertEqual(doc.cues[3].text, "<i>Line 3 of the film,</i>\nwith a second line.")
        XCTAssertEqual(doc.cues[4].style?.alignment, 8)
        XCTAssertLessThan(elapsed, 5, "parsing 5,000 cues took \(elapsed) s")

        let writeStart = Date()
        let written = SRTWriter.write(doc)
        XCTAssertLessThan(Date().timeIntervalSince(writeStart), 5)
        XCTAssertEqual(try SubtitleParser.parse(string: written, format: .srt).cues.count, 5000)
    }

    /// ~50 MB file of large "video" blocks with a few subtitle blocks. Extraction must seek over
    /// the video payloads: we assert that only a small fraction of the file is actually read.
    func testLargeMatroskaIsSkimmedNotRead() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sable-perf-\(UUID().uuidString).mkv")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        let out = try FileHandle(forWritingTo: url)

        let videoPayload = [UInt8](repeating: 0x5A, count: 200_000)
        let audioPayload = [UInt8](repeating: 0x33, count: 400)
        let clusterCount = 250
        // Segment of unknown size so we can stream clusters to disk.
        try out.write(contentsOf: Data(MKV.ebmlHeader() + EBML.id(MKVID.segment) + EBML.unknownSize))
        try out.write(contentsOf: Data(MKV.info(timestampScale: 1_000_000)))
        try out.write(contentsOf: Data(MKV.tracks([
            MKV.videoTrack,
            MKVTrackSpec(number: 2, type: 2, codecID: "A_AAC", language: "eng"),
            MKV.srtTrack(3),
        ])))
        for c in 0..<clusterCount {
            var blocks: [[UInt8]] = [MKV.simpleBlock(track: 1, timestamp: 0, videoPayload)]
            for k in 0..<5 {
                blocks.append(MKV.simpleBlock(track: 2, timestamp: Int16(k * 40 + 5), audioPayload))
            }
            if c % 10 == 0 {
                blocks.append(MKV.blockGroup(track: 3, timestamp: 100, bytes("Subtitle \(c / 10)"), duration: 1500))
            }
            try out.write(contentsOf: Data(MKV.cluster(timestamp: UInt64(c) * 2000, blocks)))
        }
        try out.close()

        let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber).intValue
        XCTAssertGreaterThan(size, 50_000_000)

        let started = Date()
        let reader = try MatroskaReader(url: url)
        XCTAssertEqual(try reader.readTracks().count, 3)
        let doc = try XCTUnwrap(reader.extractTextSubtitles(trackNumbers: [3])[3])
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(doc.cues.count, clusterCount / 10)
        XCTAssertEqual(doc.cues.last?.text, "Subtitle 24")
        XCTAssertEqual(try XCTUnwrap(doc.cues.last).start, 480.1, accuracy: 0.0001)
        XCTAssertLessThan(Double(reader.io.bytesRead), Double(size) * 0.05, "read \(reader.io.bytesRead) of \(size) bytes")
        XCTAssertLessThan(elapsed, 5, "extraction took \(elapsed) s")
    }
}
