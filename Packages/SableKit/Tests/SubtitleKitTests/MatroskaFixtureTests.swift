import XCTest
@testable import SubtitleKit

/// Real files muxed by ffmpeg (see Fixtures/make_fixtures.sh).
final class MatroskaFixtureTests: XCTestCase {
    func testNightRoofTracks() throws {
        let reader = try MatroskaReader(url: Fixtures.url("night-roof.mkv"))
        XCTAssertEqual(reader.docType, "matroska")
        let tracks = try reader.readTracks()
        XCTAssertEqual(tracks.map(\.type), [.video, .audio, .audio, .subtitle, .subtitle, .subtitle])
        XCTAssertEqual(tracks.map(\.number), [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(reader.title, "Night Roof (Sable sample)")
        XCTAssertEqual(try XCTUnwrap(reader.duration), 40, accuracy: 0.1)
        XCTAssertEqual(reader.timestampScale, 1_000_000)

        let audio = tracks.filter { $0.type == .audio }
        XCTAssertEqual(audio.map(\.name), ["Dialogue", "Commentary"])
        XCTAssertEqual(audio.map(\.language), [.english, .english])

        let subs = tracks.filter { $0.type == .subtitle }
        XCTAssertEqual(subs.map(\.codecID), ["S_TEXT/UTF8", "S_TEXT/ASS", "S_TEXT/UTF8"])
        XCTAssertEqual(subs.map(\.language), [.english, .english, LanguageCode("fr")])
        XCTAssertEqual(subs.map(\.name), ["English", "English (styled)", "Français"])
        XCTAssertEqual(subs.map(\.isDefault), [true, false, false])
        XCTAssertEqual(subs.map(\.isForced), [false, false, false])
        XCTAssertEqual(subs.map(\.subtitleKind), [.text, .text, .text])
        XCTAssertEqual(subs.map(\.subtitleFormat), [.srt, .ass, .srt])
        XCTAssertEqual(subs.map { MatroskaCodec.displayName(forCodecID: $0.codecID) }, ["SRT", "ASS", "SRT"])
        let assPrivate = try XCTUnwrap(subs[1].codecPrivate)
        XCTAssertTrue(String(decoding: assPrivate, as: UTF8.self).hasPrefix("[Script Info]"))
        XCTAssertNil(tracks[0].subtitleKind)
        XCTAssertNotEqual(tracks[0].uid, 0)

        // Reading tracks stops at the first Cluster: only a few KB of the 720 KB file are read.
        XCTAssertLessThan(reader.io.bytesRead, 64 * 1024)
        // Cached.
        XCTAssertEqual(try reader.readTracks(), tracks)
    }

    func testNightRoofExtractionMatchesSourceFiles() throws {
        let reader = try MatroskaReader(url: Fixtures.url("night-roof.mkv"))
        var reported: [Double] = []
        let docs = try reader.extractTextSubtitles(trackNumbers: [4, 5, 6], progress: { reported.append($0) })
        XCTAssertEqual(Set(docs.keys), [4, 5, 6])

        let srt = try XCTUnwrap(docs[4])
        XCTAssertEqual(srt.format, .srt)
        XCTAssertEqual(srt.language, .english)
        XCTAssertEqual(srt.title, "English")
        assertSameCues(srt.cues, try Fixtures.document("sample.en.srt").cues)
        XCTAssertEqual(srt.cues.map(\.id), (1...9).map { "c\($0)" })

        let ass = try XCTUnwrap(docs[5])
        let assSource = try Fixtures.document("sample.en.ass")
        XCTAssertEqual(ass.format, .ass)
        assertSameCues(ass.cues, assSource.cues, compareIDs: true) // ids from ReadOrder = file event order
        XCTAssertEqual(ass.cues.map(\.style), assSource.cues.map(\.style))
        XCTAssertEqual(ass.header, assSource.header)
        XCTAssertEqual(ass.cues[0].style?.alignment, 8)

        let fr = try XCTUnwrap(docs[6])
        XCTAssertEqual(fr.language, LanguageCode("fr"))
        assertSameCues(fr.cues, try Fixtures.document("sample.fr.srt").cues)
        XCTAssertEqual(fr.cues.first?.text, "Mara, tu es encore réveillée ?")

        XCTAssertEqual(reported.last, 1)
        XCTAssertEqual(reported, reported.sorted())
    }

    func testExtractSingleTrackAndIgnoreNonText() throws {
        let reader = try MatroskaReader(url: Fixtures.url("night-roof.mkv"))
        let docs = try reader.extractTextSubtitles(trackNumbers: [1, 2, 6, 99])
        XCTAssertEqual(Array(docs.keys), [6])
        XCTAssertTrue(try reader.extractTextSubtitles(trackNumbers: [1, 2]).isEmpty)
        XCTAssertTrue(try reader.extractTextSubtitles(trackNumbers: []).isEmpty)
    }

    func testWebVTTInMatroskaAndWebM() throws {
        let source = try Fixtures.document("sample.en.vtt")
        for (name, docType) in [("sample.webvtt.mkv", "matroska"), ("sample.webvtt.webm", "webm")] {
            let reader = try MatroskaReader(url: Fixtures.url(name))
            XCTAssertEqual(reader.docType, docType)
            let tracks = try reader.readTracks()
            XCTAssertEqual(tracks.count, 1)
            let track = try XCTUnwrap(tracks.first)
            XCTAssertEqual(track.subtitleKind, .text, name)
            XCTAssertEqual(track.subtitleFormat, .webvtt, name)
            XCTAssertEqual(track.language, .english)
            XCTAssertEqual(track.name, "English (WebVTT)")
            let doc = try XCTUnwrap(reader.extractTextSubtitles(trackNumbers: [track.number])[track.number])
            XCTAssertEqual(doc.format, .webvtt)
            // Same ids (cue identifiers), timing, text and alignment as parsing the .vtt directly.
            assertSameCues(doc.cues, source.cues, compareIDs: true)
            XCTAssertEqual(doc.cues.map { $0.style?.alignment }, source.cues.map { $0.style?.alignment }, name)
        }
    }

    func testNotMatroska() throws {
        XCTAssertThrowsError(try MatroskaReader(url: Fixtures.url("sample.en.srt"))) { error in
            guard case .unsupportedFormat = error as? SubtitleError else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try MatroskaReader(url: URL(fileURLWithPath: "/nonexistent/sable/file.mkv"))) { error in
            guard case .io = error as? SubtitleError else { return XCTFail("\(error)") }
        }
    }
}
