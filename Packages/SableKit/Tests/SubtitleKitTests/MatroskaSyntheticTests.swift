import XCTest
@testable import SubtitleKit

/// Matroska files built in-test with the EBML builder (Support/TestSupport.swift).
final class MatroskaSyntheticTests: XCTestCase {
    private func reader(_ bytes: [UInt8], ext: String = "mkv") throws -> MatroskaReader {
        try MatroskaReader(url: temporaryFile(bytes, ext: ext))
    }

    private func extract(_ bytes: [UInt8], track: Int = 2) throws -> SubtitleDocument {
        let r = try reader(bytes)
        return try XCTUnwrap(r.extractTextSubtitles(trackNumbers: [track])[track])
    }

    // MARK: Codecs

    func testImageTracksAreListedButNotExtracted() throws {
        let file = MKV.file([
            MKV.info(),
            MKV.tracks([
                MKV.videoTrack,
                MKVTrackSpec(number: 2, codecID: "S_HDMV/PGS", language: "ara", name: "Arabic PGS"),
                MKVTrackSpec(number: 3, codecID: "S_VOBSUB", language: "fre", codecPrivate: bytes("size: 720x480\n")),
                MKVTrackSpec(number: 4, codecID: "S_DVBSUB"),
                MKVTrackSpec(number: 5, codecID: "S_TEXT/UTF8", language: "eng"),
                MKVTrackSpec(number: 6, codecID: "S_HDMV/TEXTST"),
            ]),
            MKV.cluster(timestamp: 0, [
                MKV.simpleBlock(track: 2, timestamp: 0, [0x16, 0x00, 0x01]),
                MKV.blockGroup(track: 5, timestamp: 0, bytes("Text"), duration: 1000),
            ]),
        ])
        let r = try reader(file)
        let tracks = try r.readTracks()
        XCTAssertEqual(tracks.map(\.subtitleKind), [nil, .image, .image, .image, .text, .image])
        XCTAssertEqual(tracks[1].language, .arabic)
        XCTAssertEqual(tracks[2].language, LanguageCode("fr"))
        XCTAssertEqual(tracks.map { MatroskaCodec.displayName(forCodecID: $0.codecID) },
                       ["V_MPEG4/ISO/AVC", "PGS · image", "VobSub · image", "DVB · image", "SRT", "HDMV Text · unsupported"])
        let docs = try r.extractTextSubtitles(trackNumbers: [2, 3, 4, 5, 6])
        XCTAssertEqual(Array(docs.keys), [5])
        XCTAssertEqual(docs[5]?.cues.map(\.text), ["Text"])
    }

    func testCodecMapping() {
        XCTAssertEqual(MatroskaCodec.subtitleKind(forCodecID: "S_TEXT/WEBVTT"), .text)
        XCTAssertEqual(MatroskaCodec.subtitleKind(forCodecID: "D_WEBVTT/SUBTITLES"), .text)
        XCTAssertEqual(MatroskaCodec.subtitleKind(forCodecID: "S_TEXT/USF"), .text)
        XCTAssertEqual(MatroskaCodec.subtitleKind(forCodecID: "S_SSA"), .text)
        XCTAssertEqual(MatroskaCodec.subtitleKind(forCodecID: "S_IMAGE/BMP"), .image)
        XCTAssertEqual(MatroskaCodec.subtitleKind(forCodecID: "S_SOMETHING_NEW"), .image)
        XCTAssertNil(MatroskaCodec.subtitleKind(forCodecID: "A_AAC"))
        XCTAssertNil(MatroskaCodec.subtitleKind(forCodecID: "D_WEBVTT/METADATA"))
        XCTAssertEqual(MatroskaCodec.subtitleFormat(forCodecID: "S_TEXT/SSA"), .ssa)
        XCTAssertEqual(MatroskaCodec.subtitleFormat(forCodecID: "S_TEXT/WEBVTT"), .webvtt)
        XCTAssertEqual(MatroskaCodec.subtitleFormat(forCodecID: "S_HDMV/PGS"), .unknown)
        XCTAssertEqual(MatroskaCodec.displayName(forCodecID: "S_TEXT/WEBVTT"), "WebVTT")
    }

    func testTrackMetadata() throws {
        let file = MKV.file([
            MKV.tracks([
                MKVTrackSpec(number: 1, codecID: "S_TEXT/UTF8"),                                         // no Language: "eng"
                MKVTrackSpec(number: 2, codecID: "S_TEXT/UTF8", language: "por", languageBCP47: "pt-BR"), // BCP47 wins
                MKVTrackSpec(number: 3, codecID: "S_TEXT/UTF8", language: "und", name: "  Signs  ", flagDefault: 0, flagForced: 1),
                MKVTrackSpec(number: 4, codecID: "S_TEXT/UTF8", uid: 0xDEAD_BEEF_CAFE, language: "ara", name: "", flagDefault: 1),
            ]),
        ])
        let tracks = try reader(file).readTracks()
        XCTAssertEqual(tracks.map(\.language), [.english, LanguageCode("pt-br"), nil, .arabic])
        XCTAssertEqual(tracks.map(\.name), [nil, nil, "Signs", nil])
        XCTAssertEqual(tracks.map(\.isDefault), [true, true, false, true])
        XCTAssertEqual(tracks.map(\.isForced), [false, false, true, false])
        XCTAssertEqual(tracks[3].uid, 0xDEAD_BEEF_CAFE)
        XCTAssertEqual(tracks.map(\.type), [.subtitle, .subtitle, .subtitle, .subtitle])
    }

    // MARK: Content encodings

    func testHeaderStripping() throws {
        let file = MKV.file([
            MKV.tracks([MKV.srtTrack(2, encodings: [MKV.headerStripping(bytes("<i>"))])]),
            MKV.cluster(timestamp: 1000, [
                MKV.blockGroup(track: 2, timestamp: 0, bytes("Hello</i>"), duration: 500),
                MKV.blockGroup(track: 2, timestamp: 1000, bytes("Second</i>"), duration: 500),
            ]),
        ])
        let doc = try extract(file)
        XCTAssertEqual(doc.cues.map(\.text), ["<i>Hello</i>", "<i>Second</i>"])
        XCTAssertEqual(doc.cues[0].start, 1, accuracy: 0.0001)
        XCTAssertEqual(doc.cues[0].end, 1.5, accuracy: 0.0001)
    }

    func testZlibCompressedPayloads() throws {
        let expectedB = String(decoding: Array(bytes(InflateTests.largeText).prefix(700)), as: UTF8.self)
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
        let file = MKV.file([
            MKV.tracks([MKV.srtTrack(2, encodings: [MKV.zlibEncoding()])]),
            MKV.cluster(timestamp: 0, [
                MKV.blockGroup(track: 2, timestamp: 100, base64(InflateVectors.mkvPayloadA), duration: 900),
                MKV.blockGroup(track: 2, timestamp: 2000, base64(InflateVectors.mkvPayloadB), duration: 900),
                MKV.blockGroup(track: 2, timestamp: 4000, zlibStored(bytes("Stored {\\an8}top")), duration: 900),
                MKV.blockGroup(track: 2, timestamp: 6000, [0x78, 0x9C, 0xFF, 0x00], duration: 900), // corrupt: skipped
            ]),
        ])
        let doc = try extract(file)
        XCTAssertEqual(doc.cues.count, 3)
        XCTAssertEqual(doc.cues[0].text, "Compressed <i>hello</i>")
        XCTAssertEqual(doc.cues[1].text, expectedB)
        XCTAssertEqual(doc.cues[2].text, "Stored top")
        XCTAssertEqual(doc.cues[2].style?.alignment, 8)
    }

    func testCombinedEncodingsAreUndoneInOrder() throws {
        // Muxing applied header stripping (order 0) then zlib (order 1): decode zlib first.
        let file = MKV.file([
            MKV.tracks([MKV.srtTrack(2, encodings: [MKV.headerStripping(bytes("Prefix: ")), MKV.zlibEncoding(order: 1)])]),
            MKV.cluster(timestamp: 0, [MKV.blockGroup(track: 2, timestamp: 0, zlibStored(bytes("payload")), duration: 1000)]),
        ])
        XCTAssertEqual(try extract(file).cues.map(\.text), ["Prefix: payload"])
    }

    func testCompressedCodecPrivate() throws {
        let header = "[Script Info]\nScriptType: v4.00+\n\n[V4+ Styles]\nFormat: Name, Bold, Italic, Alignment\nStyle: Default,0,1,9\n\n[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n"
        let file = MKV.file([
            MKV.tracks([MKVTrackSpec(number: 2, codecID: "S_TEXT/ASS", codecPrivate: zlibStored(bytes(header)),
                                     encodings: [MKV.zlibEncoding(scope: 3)])]),
            MKV.cluster(timestamp: 0, [MKV.blockGroup(track: 2, timestamp: 0, zlibStored(bytes("0,0,Default,,0,0,0,,Leaning")), duration: 1000)]),
        ])
        let r = try reader(file)
        XCTAssertEqual(try r.readTracks().first?.codecPrivate.map { String(decoding: $0, as: UTF8.self) }, header)
        let doc = try XCTUnwrap(r.extractTextSubtitles(trackNumbers: [2])[2])
        XCTAssertEqual(doc.cues.map(\.text), ["<i>Leaning</i>"])
        XCTAssertEqual(doc.cues[0].style, CueStyleHint(alignment: 9, styleName: "Default", italic: true, bold: false))
        XCTAssertEqual(doc.header, "[Script Info]\nScriptType: v4.00+\n\n[V4+ Styles]\nFormat: Name, Bold, Italic, Alignment\nStyle: Default,0,1,9\n")
    }

    func testEncryptedTrackYieldsNoCues() throws {
        let file = MKV.file([
            MKV.tracks([MKV.srtTrack(2, encodings: [MKV.encryption()])]),
            MKV.cluster(timestamp: 0, [MKV.blockGroup(track: 2, timestamp: 0, bytes("ciphertext"), duration: 1000)]),
        ])
        let doc = try extract(file)
        XCTAssertTrue(doc.cues.isEmpty)
    }

    // MARK: Structure

    func testUnknownSizeSegmentAndClusters() throws {
        let file = MKV.file(unknownSegmentSize: true, [
            MKV.info(timestampScale: 1_000_000, duration: 9000, title: "Live"),
            MKV.tracks([MKV.videoTrack, MKV.srtTrack(2)]),
            MKV.cluster(timestamp: 0, [
                MKV.simpleBlock(track: 1, timestamp: 0, [UInt8](repeating: 0xAB, count: 5000)),
                MKV.blockGroup(track: 2, timestamp: 500, bytes("One"), duration: 1000),
            ], unknownSize: true),
            MKV.cluster(timestamp: 3000, [
                MKV.blockGroup(track: 2, timestamp: 0, bytes("Two"), duration: 1000),
                MKV.simpleBlock(track: 1, timestamp: 10, [UInt8](repeating: 0xCD, count: 3000)),
            ], unknownSize: true),
            MKV.cluster(timestamp: 6000, [MKV.blockGroup(track: 2, timestamp: 0, bytes("Three"), duration: 1000)]),
            EBML.master(MKVID.cues, [EBML.master(0xBB, [EBML.uint(0xB3, 0)])]),
        ])
        let r = try reader(file)
        XCTAssertEqual(try r.readTracks().count, 2)
        XCTAssertEqual(r.title, "Live")
        XCTAssertEqual(try XCTUnwrap(r.duration), 9, accuracy: 0.0001)
        let doc = try XCTUnwrap(r.extractTextSubtitles(trackNumbers: [2])[2])
        XCTAssertEqual(doc.cues.map(\.text), ["One", "Two", "Three"])
        XCTAssertEqual(doc.cues.map(\.start), [0.5, 3, 6])
    }

    func testBlockGroupWithoutDurationAndSimpleBlocks() throws {
        let file = MKV.file([
            MKV.tracks([MKV.srtTrack(2)]),
            MKV.cluster(timestamp: 0, [
                MKV.blockGroup(track: 2, timestamp: 1000, bytes("Until next"), duration: nil),
                MKV.simpleBlock(track: 2, timestamp: 2000, bytes("Capped at five")),
                MKV.blockGroup(track: 2, timestamp: 20000, bytes("Explicit"), duration: 1500, durationFirst: true),
                MKV.blockGroup(track: 2, timestamp: 30000, bytes("Zero duration"), duration: 0),
            ]),
        ])
        let doc = try extract(file)
        XCTAssertEqual(doc.cues.map(\.text), ["Until next", "Capped at five", "Explicit", "Zero duration"])
        XCTAssertEqual(doc.cues.map(\.end), [2, 7, 21.5, 32])
    }

    func testTimestampScaleAndNegativeRelativeTimestamps() throws {
        let file = MKV.file([
            MKV.info(timestampScale: 100_000), // 0.1 ms per tick
            MKV.tracks([MKV.srtTrack(2)]),
            MKV.cluster(timestamp: 50_000, [   // 5 s
                MKV.blockGroup(track: 2, timestamp: -10_000, bytes("Four"), duration: 12_345), // 4 s, 1.2345 s
                MKV.blockGroup(track: 2, timestamp: -32_768, bytes("Clamped"), duration: 10_000),
            ]),
            MKV.cluster(timestamp: 0, [MKV.blockGroup(track: 2, timestamp: -500, bytes("Negative"), duration: 10_000)]),
        ])
        let doc = try extract(file)
        XCTAssertEqual(doc.cues.map(\.text), ["Negative", "Clamped", "Four"])
        XCTAssertEqual(doc.cues[0].start, 0)
        XCTAssertEqual(doc.cues[1].start, 1.7232, accuracy: 0.00001)
        XCTAssertEqual(doc.cues[2].start, 4, accuracy: 0.00001)
        XCTAssertEqual(doc.cues[2].end, 5.2345, accuracy: 0.00001)
    }

    func testLacing() throws {
        // Xiph: 3 frames, sizes 3, 4, rest.
        let xiph: [UInt8] = [2, 3, 4] + bytes("OneTwo!Three")
        // EBML: 3 frames, first size 4 (vint 0x84), second = 4 + (-1) (signed vint 0xBE = 62 - 63 = -1), rest.
        let ebml: [UInt8] = [2, 0x84, 0xBE] + bytes("AaaaBbbCccc")
        // Fixed: 2 frames of 5 bytes.
        let fixed: [UInt8] = [1] + bytes("FirstLater")
        let file = MKV.file([
            MKV.tracks([MKV.srtTrack(2)]),
            MKV.cluster(timestamp: 0, [
                MKV.simpleBlock(track: 2, timestamp: 1000, xiph, flags: 0x80 | 0x02),
                MKV.simpleBlock(track: 2, timestamp: 2000, ebml, flags: 0x80 | 0x06),
                MKV.simpleBlock(track: 2, timestamp: 3000, fixed, flags: 0x80 | 0x04),
                MKV.simpleBlock(track: 2, timestamp: 4000, [5, 9, 9], flags: 0x80 | 0x02), // broken lacing: skipped
            ]),
        ])
        let doc = try extract(file)
        XCTAssertEqual(doc.cues.map(\.text), ["One", "Two!", "Three", "Aaaa", "Bbb", "Cccc", "First", "Later"])
        XCTAssertEqual(MatroskaReader.splitLaces([0, 1, 2], lacing: 2), [[1, 2]])
        XCTAssertNil(MatroskaReader.splitLaces([1, 1, 2, 3], lacing: 2)) // 3 bytes don't split into 2 equal frames
    }

    func testTracksAfterClustersViaSeekHeadOrLinearWalk() throws {
        let tracks = MKV.tracks([MKV.srtTrack(2, name: "Late tracks")])
        let cluster = MKV.cluster(timestamp: 0, [MKV.blockGroup(track: 2, timestamp: 0, bytes("Found"), duration: 1000)])
        // SeekHead position is relative to the Segment payload start.
        func seekHead(tracksPosition: UInt64) -> [UInt8] {
            EBML.master(MKVID.seekHead, [EBML.master(MKVID.seek, [
                EBML.element(MKVID.seekID, EBML.id(MKVID.tracks)),
                EBML.element(MKVID.seekPosition, [0, 0, 0, 0, 0, 0, UInt8(tracksPosition >> 8), UInt8(tracksPosition & 0xFF)]),
            ])])
        }
        let headLength = UInt64(seekHead(tracksPosition: 0).count)
        let info = MKV.info()
        let withSeek = MKV.file([seekHead(tracksPosition: headLength + UInt64(info.count + cluster.count)), info, cluster, tracks])
        let withoutSeek = MKV.file([info, cluster, tracks])
        for file in [withSeek, withoutSeek] {
            let r = try reader(file)
            XCTAssertEqual(try r.readTracks().map(\.name), ["Late tracks"])
            XCTAssertEqual(try r.extractTextSubtitles(trackNumbers: [2])[2]?.cues.map(\.text), ["Found"])
        }
    }

    func testRejectsNonMatroska() throws {
        XCTAssertThrowsError(try reader(bytes("definitely not EBML"))) { error in
            XCTAssertEqual(error as? SubtitleError, .unsupportedFormat("not a Matroska or WebM file"))
        }
        XCTAssertThrowsError(try reader(MKV.ebmlHeader(docType: "notmkv") + EBML.master(MKVID.segment, []))) { error in
            XCTAssertEqual(error as? SubtitleError, .unsupportedFormat("EBML document type \"notmkv\""))
        }
        XCTAssertThrowsError(try reader(MKV.ebmlHeader())) { error in
            XCTAssertEqual(error as? SubtitleError, .malformed("no Matroska Segment found"))
        }
        XCTAssertThrowsError(try reader([]))
        XCTAssertEqual(try reader(MKV.file(docType: "webm", [MKV.tracks([MKV.srtTrack(1)])]), ext: "webm").docType, "webm")
    }

    func testTruncatedFileKeepsWhatWasRead() throws {
        let file = MKV.file([
            MKV.tracks([MKV.srtTrack(2)]),
            MKV.cluster(timestamp: 0, [
                MKV.blockGroup(track: 2, timestamp: 0, bytes("Complete"), duration: 1000),
                MKV.blockGroup(track: 2, timestamp: 2000, bytes("This block is cut off in the middle"), duration: 1000),
            ]),
        ])
        let doc = try extract(Array(file.dropLast(20)))
        XCTAssertEqual(doc.cues.map(\.text), ["Complete"])
    }

    func testResynchronisesAfterGarbage() throws {
        let first = MKV.cluster(timestamp: 0, [MKV.blockGroup(track: 2, timestamp: 0, bytes("Before"), duration: 1000)])
        let second = MKV.cluster(timestamp: 5000, [MKV.blockGroup(track: 2, timestamp: 0, bytes("After"), duration: 1000)])
        let garbage: [UInt8] = [0x00, 0x00, 0x00, 0x12, 0x00, 0x7F, 0x00, 0x00]
        let file = MKV.file(unknownSegmentSize: true, [MKV.tracks([MKV.srtTrack(2)]), first, garbage, second])
        XCTAssertEqual(try extract(file).cues.map(\.text), ["Before", "After"])
    }

    // MARK: Text codecs

    func testASSBlocksSortedByReadOrder() throws {
        let header = "[Script Info]\nScriptType: v4.00+\n\n[V4+ Styles]\nFormat: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding\nStyle: Default,Arial,20,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,0,2,10,10,10,1\nStyle: Top,Arial,20,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,1,0,0,0,100,100,0,0,1,2,0,8,10,10,10,1\n\n[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n"
        let file = MKV.file([
            MKV.tracks([MKVTrackSpec(number: 2, codecID: "S_TEXT/ASS", codecPrivate: bytes(header))]),
            MKV.cluster(timestamp: 0, [
                MKV.blockGroup(track: 2, timestamp: 1000, bytes("2,0,Default,,0,0,0,,Third read, same start"), duration: 1000),
                MKV.blockGroup(track: 2, timestamp: 1000, bytes("1,0,Top,Sign,0,0,0,,{\\i1}Second{\\i0}, read"), duration: 1000),
                MKV.blockGroup(track: 2, timestamp: 500, bytes("0,0,Default,,0,0,0,,First\\Nline"), duration: 500),
                MKV.blockGroup(track: 2, timestamp: 3000, bytes("3,0,Default,,0,0,0,,{\\p1}m 0 0 l 10 10"), duration: 500),
                MKV.blockGroup(track: 2, timestamp: 4000, bytes("Dialogue: 0,0:00:00.00,0:00:01.00,Top,,0,0,0,,Legacy full line"), duration: 500),
            ]),
        ])
        let doc = try extract(file)
        XCTAssertEqual(doc.format, .ass)
        XCTAssertEqual(doc.cues.map(\.text), ["First\nline", "<b><i>Second</i>, read</b>", "Third read, same start", "<b>Legacy full line</b>"])
        // ReadOrder n -> "a<n+1>"; the legacy line has no ReadOrder and gets its position.
        XCTAssertEqual(doc.cues.map(\.id), ["a1", "a2", "a3", "a4"])
        XCTAssertEqual(doc.cues[1].style, CueStyleHint(alignment: 8, styleName: "Top", italic: false, bold: true))
        XCTAssertEqual(doc.cues[3].start, 4, accuracy: 0.0001) // block timing wins over the line's own times
        XCTAssertEqual(doc.cues[0].rawText, "First\\Nline")
    }

    func testSSABlocks() throws {
        let header = "[Script Info]\nScriptType: v4.00\n\n[V4 Styles]\nFormat: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, TertiaryColour, BackColour, Bold, Italic, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, AlphaLevel, Encoding\nStyle: Default,Arial,20,16777215,65535,65535,0,0,0,1,2,0,2,10,10,10,0,0\n\n[Events]\nFormat: Marked, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n"
        let file = MKV.file([
            MKV.tracks([MKVTrackSpec(number: 2, codecID: "S_TEXT/SSA", codecPrivate: bytes(header))]),
            MKV.cluster(timestamp: 0, [MKV.blockGroup(track: 2, timestamp: 0, bytes("0,Marked=0,Default,,0000,0000,0000,,{\\a6}Top"), duration: 1000)]),
        ])
        let doc = try extract(file)
        XCTAssertEqual(doc.format, .ssa)
        XCTAssertEqual(doc.cues.map(\.text), ["Top"])
        XCTAssertEqual(doc.cues[0].style?.alignment, 8)
    }

    func testWebVTTBlocks() throws {
        let file = MKV.file(docType: "webm", [
            MKV.tracks([
                MKVTrackSpec(number: 2, codecID: "D_WEBVTT/SUBTITLES", language: "eng"),
                MKVTrackSpec(number: 3, codecID: "S_TEXT/WEBVTT", language: "eng", codecPrivate: bytes("WEBVTT\n\nSTYLE\n::cue { color: red }\n")),
            ]),
            MKV.cluster(timestamp: 0, [
                MKV.blockGroup(track: 2, timestamp: 1000, bytes("intro\nline:0 align:start\n<v Mara>Hi &amp; bye</v>"), duration: 1000),
                MKV.blockGroup(track: 2, timestamp: 3000, bytes("\n\nNo id\r\nTwo lines"), duration: 1000),
                MKV.blockGroup(track: 3, timestamp: 1000, bytes("<c.loud>Matroska</c> style"), duration: 1000,
                               addition: bytes("align:end line:0\nNOTE kept out")),
                MKV.blockGroup(track: 3, timestamp: 2000, bytes("Plain <00:00:02.500>karaoke"), duration: 1000),
            ]),
        ])
        let r = try reader(file, ext: "webm")
        let docs = try r.extractTextSubtitles(trackNumbers: [2, 3])
        let webm = try XCTUnwrap(docs[2])
        XCTAssertEqual(webm.cues.map(\.text), ["Hi & bye", "No id\nTwo lines"])
        XCTAssertEqual(webm.cues.map(\.id), ["intro", "c2"])
        XCTAssertEqual(webm.cues[0].style?.alignment, 7)
        XCTAssertNil(webm.cues[1].style)
        let mkv = try XCTUnwrap(docs[3])
        XCTAssertEqual(mkv.cues.map(\.text), ["Matroska style", "Plain karaoke"])
        XCTAssertEqual(mkv.cues[0].style?.alignment, 9)
    }

    func testLegacyEncodedTextTrack() throws {
        // Some muxers store Windows-1256 bytes in S_TEXT/UTF8: decode the track consistently.
        var inverse: [UInt32: UInt8] = [:]
        for (i, v) in TextDecoding.windows1256.enumerated() { inverse[v] = UInt8(0x80 + i) }
        func cp1256(_ s: String) -> [UInt8] { s.unicodeScalars.map { $0.value < 0x80 ? UInt8($0.value) : inverse[$0.value]! } }
        let file = MKV.file([
            MKV.tracks([MKV.srtTrack(2, language: "ara")]),
            MKV.cluster(timestamp: 0, [
                MKV.blockGroup(track: 2, timestamp: 0, cp1256("مرحبا"), duration: 1000),
                MKV.blockGroup(track: 2, timestamp: 2000, bytes("ASCII only"), duration: 1000),
                MKV.blockGroup(track: 2, timestamp: 4000, cp1256("نعم، شكرا") + [0, 0], duration: 1000),
            ]),
        ])
        XCTAssertEqual(try extract(file).cues.map(\.text), ["مرحبا", "ASCII only", "نعم، شكرا"])
    }

    func testUSFPayload() throws {
        let file = MKV.file([
            MKV.tracks([MKVTrackSpec(number: 2, codecID: "S_TEXT/USF")]),
            MKV.cluster(timestamp: 0, [MKV.blockGroup(track: 2, timestamp: 0, bytes("<subtitle><text>Hello <i>there</i><br/>friend</text></subtitle>"), duration: 1000)]),
        ])
        XCTAssertEqual(try extract(file).cues.map(\.text), ["Hello <i>there</i>\nfriend"])
    }

    // MARK: Progress and cancellation

    func testCancellation() throws {
        var clusters: [[UInt8]] = []
        for i in 0..<50 {
            clusters.append(MKV.cluster(timestamp: UInt64(i * 1000), [MKV.blockGroup(track: 2, timestamp: 0, bytes("Cue \(i)"), duration: 500)]))
        }
        let file = MKV.file([MKV.tracks([MKV.srtTrack(2)])] + clusters)
        let r = try reader(file)
        XCTAssertThrowsError(try r.extractTextSubtitles(trackNumbers: [2], isCancelled: { true })) { error in
            XCTAssertEqual(error as? SubtitleError, .cancelled)
        }
        var calls = 0
        XCTAssertThrowsError(try r.extractTextSubtitles(trackNumbers: [2], isCancelled: {
            calls += 1
            return calls > 10
        })) { error in
            XCTAssertEqual(error as? SubtitleError, .cancelled)
        }
        // Not cancelled: everything is there, progress is monotonic and ends at 1.
        var progress: [Double] = []
        let doc = try XCTUnwrap(r.extractTextSubtitles(trackNumbers: [2], progress: { progress.append($0) })[2])
        XCTAssertEqual(doc.cues.count, 50)
        XCTAssertEqual(progress.first, 0)
        XCTAssertEqual(progress.last, 1)
        XCTAssertEqual(progress, progress.sorted())
        XCTAssertGreaterThan(progress.count, 5)
    }
}
