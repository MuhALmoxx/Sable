import XCTest
import SubtitleKit
import LibraryKit
@testable import Sable

/// Probing and subtitle extraction through the app's services (MediaProbeService +
/// SubtitleRepository + LibraryStore) with the bundled fixtures. Each test skips while the code
/// it exercises is still the skeleton stub, and becomes live after integration.
final class MediaSubtitleIntegrationTests: XCTestCase {
    // MARK: MP4 (AVFoundation engine, mov_text / tx3g)

    @MainActor
    func testMP4EmbeddedTextTrackIsDetectedAndExtracted() async throws {
        let services = try makeServices()
        let item = try addVideo("night-roof.mp4", to: services)
        let probe = await services.probe.probe(url: services.library.mediaURL(for: item))
        try skipIfStub(probe)
        XCTAssertEqual(probe.container, .mp4)
        XCTAssertEqual(probe.preferredEngine, .avFoundation, "H.264/AAC MP4 should play with AVFoundation (PiP)")
        XCTAssertEqual(probe.duration ?? 0, 40, accuracy: 0.5)
        XCTAssertNil(probe.issue)

        let tracks = await services.subtitles.tracks(for: item)
        let track = try XCTUnwrap(tracks.first { $0.id.hasPrefix("emb:mp4:") },
                                  "No embedded MP4 text track among \(tracks.map(\.id))")
        XCTAssertEqual(track.id, SubtitleTrackDescriptor.embeddedID(container: .mp4, streamID: 4))
        XCTAssertEqual(track.kind, .text)
        XCTAssertEqual(track.format, .tx3g)
        XCTAssertEqual(track.language?.primary, "en")
        if case let .embedded(container, streamID, _) = track.origin {
            XCTAssertEqual(container, .mp4)
            XCTAssertEqual(streamID, 4)
        } else {
            XCTFail("Unexpected origin \(track.origin)")
        }

        let document = try await loadDocument(track, item: item, services: services)
        assertNightRoofDialogue(document, firstCueStart: 3.0)
    }

    // MARK: MKV (VLC engine; text tracks extracted by SubtitleKit)

    @MainActor
    func testMKVEmbeddedTextTracksAreListedAndExtracted() async throws {
        let services = try makeServices()
        let item = try addVideo("night-roof.mkv", to: services)
        let probe = await services.probe.probe(url: services.library.mediaURL(for: item))
        try skipIfStub(probe)
        XCTAssertEqual(probe.container, .matroska)
        XCTAssertEqual(probe.preferredEngine, .vlc)
        XCTAssertEqual(probe.duration ?? 0, 40, accuracy: 0.5)

        let tracks = await services.subtitles.tracks(for: item)
        let byID = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let english = try XCTUnwrap(byID["emb:mkv:4"], "SRT en (TrackNumber 4) missing from \(tracks.map(\.id))")
        let styled = try XCTUnwrap(byID["emb:mkv:5"], "ASS en (TrackNumber 5) missing")
        let french = try XCTUnwrap(byID["emb:mkv:6"], "SRT fr (TrackNumber 6) missing")
        XCTAssertTrue(english.isDefault)
        XCTAssertEqual(english.language?.primary, "en")
        XCTAssertEqual(english.format, .srt)
        XCTAssertEqual(styled.format, .ass)
        XCTAssertEqual(french.language?.primary, "fr")
        XCTAssertTrue([english, styled, french].allSatisfy { $0.kind == .text && $0.isTranslatable })

        let englishDocument = try await loadDocument(english, item: item, services: services)
        assertNightRoofDialogue(englishDocument, firstCueStart: 3.0)

        let styledDocument = try await loadDocument(styled, item: item, services: services)
        XCTAssertEqual(styledDocument.cues.count, 10, "ASS track: the sign line plus nine dialogue lines")
        XCTAssertTrue(styledDocument.cues.contains { $0.plainText == "Mara, are you still awake?" })

        let frenchDocument = try await loadDocument(french, item: item, services: services)
        XCTAssertEqual(frenchDocument.cues.first?.plainText, "Mara, tu es encore réveillée ?")

        let cache = services.library.extractedDirectory.appendingPathComponent(item.id.uuidString, isDirectory: true)
        let cached = (try? FileManager.default.contentsOfDirectory(atPath: cache.path)) ?? []
        XCTAssertFalse(cached.isEmpty, "Extracted embedded tracks should be cached under Extracted/<itemID>/")

        // A second load comes from the cache and is identical.
        let again = try await loadDocument(english, item: item, services: services)
        XCTAssertEqual(again, englishDocument)
    }

    // MARK: External SRT

    @MainActor
    func testExternalLateSRTAttachesAndLoads() async throws {
        let services = try makeServices()
        let item = try addVideo("night-roof.mp4", to: services)
        let ref: ExternalSubtitleRef
        do {
            ref = try services.library.attachSubtitle(from: try fixtureURL("night-roof.late.en.srt"), to: item.id, copy: true)
        } catch SubtitleError.notImplemented(let what) {
            throw XCTSkip("Not implemented yet: \(what)")
        }
        XCTAssertTrue(ref.id.hasPrefix("ext:"))
        XCTAssertEqual(ref.format, .srt)
        let fresh = try XCTUnwrap(services.library.item(id: item.id))
        XCTAssertTrue(fresh.externalSubtitles.contains { $0.id == ref.id })

        let tracks = await services.subtitles.tracks(for: fresh)
        if tracks.isEmpty {
            throw XCTSkip("SubtitleRepository.tracks(for:) is still the skeleton stub")
        }
        let track = try XCTUnwrap(tracks.first { $0.id == ref.id }, "External track missing from \(tracks.map(\.id))")
        XCTAssertEqual(track.kind, .text)
        XCTAssertEqual(track.timingGroupID, ref.id)
        let document = try await loadDocument(track, item: fresh, services: services)
        assertNightRoofDialogue(document, firstCueStart: 5.5)
    }

    // MARK: Helpers

    private func fixtureURL(_ name: String) throws -> URL {
        let directory = try XCTUnwrap(Bundle.main.url(forResource: "UITestFixtures", withExtension: nil),
                                      "UITestFixtures is missing from the Debug app bundle")
        let url = directory.appendingPathComponent(name)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "Fixture \(name) missing")
        return url
    }

    @MainActor
    private func makeServices() throws -> AppServices {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SableAppTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return try AppServices(root: root)
    }

    /// Imports through LibraryStore; while that is still a stub, places the file in Media/ by hand
    /// so the probe/repository code can still be exercised.
    @MainActor
    private func addVideo(_ name: String, to services: AppServices) throws -> MediaItem {
        let source = try fixtureURL(name)
        do {
            return try services.library.importVideo(from: source, copy: true)
        } catch SubtitleError.notImplemented(_) {
            let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            let item = MediaItem(title: name, fileName: name, fileSize: size)
            try FileManager.default.createDirectory(at: services.library.mediaDirectory, withIntermediateDirectories: true)
            let destination = services.library.mediaURL(for: item)
            if !FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.copyItem(at: source, to: destination)
            }
            return item
        }
    }

    private func skipIfStub(_ probe: MediaProbeResult) throws {
        if probe.duration == nil && probe.container == .other && probe.subtitleTracks.isEmpty && probe.issue == nil {
            throw XCTSkip("MediaProbeService.probe(url:) is still the skeleton stub")
        }
    }

    @MainActor
    private func loadDocument(_ track: SubtitleTrackDescriptor, item: MediaItem,
                              services: AppServices) async throws -> SubtitleDocument {
        do {
            return try await services.subtitles.document(for: track, item: item)
        } catch SubtitleError.notImplemented(let what) {
            throw XCTSkip("Not implemented yet: \(what)")
        }
    }

    /// The fixture dialogue (Fixtures/src/sample.en.srt), shifted so cue 1 starts at `firstCueStart`.
    private func assertNightRoofDialogue(_ document: SubtitleDocument, firstCueStart: TimeInterval,
                                         file: StaticString = #filePath, line: UInt = #line) {
        let cues = document.cues
        XCTAssertEqual(cues.count, 9, "Expected the nine fixture lines, got \(cues.count)", file: file, line: line)
        guard cues.count == 9 else { return }
        XCTAssertEqual(cues[0].plainText, "Mara, are you still awake?", file: file, line: line)
        XCTAssertEqual(cues[0].start, firstCueStart, accuracy: 0.05, file: file, line: line)
        XCTAssertEqual(cues[0].end, firstCueStart + 2.2, accuracy: 0.05, file: file, line: line)
        XCTAssertEqual(cues[1].plainText, "I can't sleep.\nThe city is too loud tonight.", file: file, line: line)
        XCTAssertEqual(cues[1].start, firstCueStart + 4.5, accuracy: 0.05, file: file, line: line)
        XCTAssertEqual(cues[3].plainText, "Is it safe?", file: file, line: line)
        XCTAssertEqual(cues[8].plainText, "Then let's watch it together, Mara.", file: file, line: line)
        XCTAssertEqual(cues[8].start, firstCueStart + 31.5, accuracy: 0.05, file: file, line: line)
        XCTAssertEqual(Set(cues.map(\.id)).count, cues.count, "Cue ids must be unique", file: file, line: line)
        XCTAssertEqual(cues.map(\.index), Array(0..<cues.count), "Cues must be indexed 0..<n", file: file, line: line)
        XCTAssertEqual(cues.map(\.start), cues.map(\.start).sorted(), "Cues must be sorted by start", file: file, line: line)
    }
}
