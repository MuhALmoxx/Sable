import XCTest
import SubtitleKit
import LibraryKit
@testable import Sable

/// PlayerSession track switching with the real fixtures and services, without a playback engine:
/// the session clock stays at 0 s, so every track's timing group gets an offset that puts its
/// first line ("Mara, are you still awake?") on screen at 0 s. A switch must replace the drawn
/// cues at once (old text gone while the new track loads), Off must clear them, and turning a
/// track back on must show the current line again, for embedded, external and translated tracks.
final class SubtitleSwitchingTests: XCTestCase {
    private let mkvEnglish = "emb:mkv:4"
    private let mkvFrench = "emb:mkv:6"
    private let mp4English = "emb:mp4:4"
    private let firstEnglishLine = "Mara, are you still awake?"
    private let firstFrenchLine = "Mara, tu es encore réveillée ?"

    // MARK: Embedded tracks, Off and on again

    @MainActor
    func testSwitchingEmbeddedTracksReplacesTheShownTextAtOnce() async throws {
        let (services, item) = try makeLibrary(video: "night-roof.mkv")
        let session = PlayerSession(item: item, services: services)
        defer { session.tearDown() }
        await session.reloadSubtitleTracks()
        try requireTracks([mkvEnglish, mkvFrench], in: session)
        showFirstLineAtZero(services, item: item, groups: [mkvEnglish: 3.0, mkvFrench: 3.0])

        await session.selectSubtitleTrack(mkvEnglish)
        XCTAssertEqual(session.activeSubtitle?.descriptor.id, mkvEnglish)
        XCTAssertEqual(shownText(session), [firstEnglishLine])
        XCTAssertEqual(session.visibleCues.map(\.trackID), [mkvEnglish])

        // French is not in memory yet (it comes from the extraction cache), so the switch suspends.
        let french = mkvFrench
        let switching = Task { await session.selectSubtitleTrack(french) }
        await Task.yield() // runs the selection up to its first suspension point
        XCTAssertNotEqual(session.activeSubtitle?.descriptor.id, mkvEnglish,
                          "The English track is still active after choosing French")
        XCTAssertFalse(shownText(session).contains(firstEnglishLine),
                       "English text stayed on screen while French was loading: \(shownText(session))")
        if session.loadingSubtitleTrackID == mkvFrench {
            XCTAssertTrue(session.visibleCues.isEmpty, "Nothing may be drawn while the new track loads")
        }
        await switching.value
        XCTAssertEqual(session.activeSubtitle?.descriptor.id, mkvFrench)
        XCTAssertEqual(shownText(session), [firstFrenchLine])
        XCTAssertEqual(session.visibleCues.map(\.trackID), [mkvFrench])
        XCTAssertNil(session.loadingSubtitleTrackID)
        XCTAssertEqual(session.subtitleLoadState, .idle)

        await session.selectSubtitleTrack(nil)
        XCTAssertNil(session.activeSubtitle)
        XCTAssertTrue(session.visibleCues.isEmpty, "Off must clear the screen")

        await session.selectSubtitleTrack(mkvEnglish)
        XCTAssertEqual(shownText(session), [firstEnglishLine], "Turning subtitles on again shows the current line at once")
        XCTAssertEqual(session.timing.offset, -3.5, accuracy: 0.0001, "The track's own timing group applies")
    }

    // MARK: External tracks

    @MainActor
    func testSwitchingToAnExternalFileOffAndOnAgain() async throws {
        let (services, item) = try makeLibrary(video: "night-roof.mp4")
        let external = try services.library.attachSubtitle(from: try fixtureURL("night-roof.late.en.srt"), to: item.id, copy: true)
        let session = PlayerSession(item: services.library.item(id: item.id) ?? item, services: services)
        defer { session.tearDown() }
        await session.reloadSubtitleTracks()
        try requireTracks([mp4English, external.id], in: session)
        // The external SRT is the same dialogue 2.5 s late (first line 5.5–7.7 s).
        showFirstLineAtZero(services, item: item, groups: [mp4English: 3.0, external.id: 5.5])

        await session.selectSubtitleTrack(mp4English)
        XCTAssertEqual(session.visibleCues.map(\.trackID), [mp4English])
        XCTAssertEqual(shownText(session), [firstEnglishLine])

        await session.selectSubtitleTrack(external.id)
        XCTAssertEqual(session.visibleCues.map(\.trackID), [external.id], "Same words, but drawn from the external file")
        XCTAssertEqual(shownText(session), [firstEnglishLine])
        XCTAssertEqual(session.timing.offset, -6.0, accuracy: 0.0001)

        await session.selectSubtitleTrack(nil)
        XCTAssertTrue(session.visibleCues.isEmpty)

        await session.selectSubtitleTrack(external.id)
        XCTAssertEqual(session.visibleCues.map(\.trackID), [external.id])
        XCTAssertEqual(shownText(session), [firstEnglishLine])
    }

    @MainActor
    func testAFailedSwitchBringsThePreviousTrackBack() async throws {
        let (services, item) = try makeLibrary(video: "night-roof.mp4")
        let external = try services.library.attachSubtitle(from: try fixtureURL("night-roof.late.en.srt"), to: item.id, copy: true)
        let session = PlayerSession(item: services.library.item(id: item.id) ?? item, services: services)
        defer { session.tearDown() }
        await session.reloadSubtitleTracks()
        try requireTracks([mp4English, external.id], in: session)
        showFirstLineAtZero(services, item: item, groups: [mp4English: 3.0])

        await session.selectSubtitleTrack(mp4English)
        XCTAssertEqual(shownText(session), [firstEnglishLine])

        // The external file vanished from disk before it was ever loaded.
        try FileManager.default.removeItem(at: services.library.subtitlesDirectory.appendingPathComponent(external.fileName))
        await session.selectSubtitleTrack(external.id)
        XCTAssertEqual(session.activeSubtitle?.descriptor.id, mp4English, "The previous track should be shown again")
        XCTAssertEqual(session.visibleCues.map(\.trackID), [mp4English])
        XCTAssertNil(session.loadingSubtitleTrackID, "The failed track must not stay 'loading'")
        guard case .failed = session.subtitleLoadState else {
            return XCTFail("The failure should be reported, got \(session.subtitleLoadState)")
        }
    }

    // MARK: Original <-> translation

    @MainActor
    func testSwitchingBetweenOriginalAndTranslation() async throws {
        let (services, item) = try makeLibrary(video: "night-roof.mkv")
        let session = PlayerSession(item: item, services: services)
        defer { session.tearDown() }
        await session.reloadSubtitleTracks()
        try requireTracks([mkvEnglish], in: session)
        showFirstLineAtZero(services, item: item, groups: [mkvEnglish: 3.0])

        await session.selectSubtitleTrack(mkvEnglish)
        let source = try XCTUnwrap(session.activeSubtitle?.document)
        let firstArabic = "مارا، هل ما زلتِ مستيقظة؟"
        let ref = try saveArabicTranslation(of: source, firstLine: firstArabic, services: services, item: item)
        await session.reloadSubtitleTracks()
        try requireTracks([ref.id], in: session)
        XCTAssertEqual(shownText(session), [firstEnglishLine], "Listing a new translation must not change the shown track")

        await session.selectSubtitleTrack(ref.id)
        XCTAssertEqual(session.activeSubtitle?.descriptor.id, ref.id)
        XCTAssertEqual(shownText(session), [firstArabic])
        XCTAssertEqual(session.visibleCues.first?.isRightToLeft, true)
        XCTAssertEqual(session.timing.offset, -3.5, accuracy: 0.0001, "A translation shares its source's timing group")
        XCTAssertEqual(session.originalTextByCueID()[source.cues[0].id], firstEnglishLine)

        await session.selectSubtitleTrack(mkvEnglish)
        XCTAssertEqual(shownText(session), [firstEnglishLine])
        XCTAssertTrue(session.originalTextByCueID().isEmpty)

        await session.selectSubtitleTrack(ref.id)
        XCTAssertEqual(shownText(session), [firstArabic])
    }

    @MainActor
    func testLibraryChangesKeepTheTranslationShownAndARegeneratedOneIsSwappedInPlace() async throws {
        let (services, item) = try makeLibrary(video: "night-roof.mkv")
        let session = PlayerSession(item: item, services: services)
        defer { session.tearDown() }
        await session.reloadSubtitleTracks()
        try requireTracks([mkvEnglish], in: session)
        showFirstLineAtZero(services, item: item, groups: [mkvEnglish: 3.0])
        await session.selectSubtitleTrack(mkvEnglish)
        let source = try XCTUnwrap(session.activeSubtitle?.document)
        let ref = try saveArabicTranslation(of: source, firstLine: "النسخة الأولى", services: services, item: item)
        await session.reloadSubtitleTracks()
        await session.selectSubtitleTrack(ref.id)
        XCTAssertEqual(shownText(session), ["النسخة الأولى"])

        // Every persistNow (pause, rate, style, leaving the app) bumps the library revision and
        // reloads the list: the translation stays installed, nothing reloads or blinks.
        let installed = try XCTUnwrap(session.activeSubtitle?.document)
        await session.reloadSubtitleTracks()
        XCTAssertEqual(session.activeSubtitle?.document, installed)
        XCTAssertNil(session.loadingSubtitleTrackID)
        XCTAssertEqual(session.subtitleLoadState, .idle)
        XCTAssertEqual(shownText(session), ["النسخة الأولى"])

        // "Translate again" saves a new version under the same track id: shown without a reselect.
        _ = try saveArabicTranslation(of: source, firstLine: "النسخة الثانية", services: services, item: item)
        await session.reloadSubtitleTracks()
        XCTAssertEqual(session.activeSubtitle?.descriptor.id, ref.id)
        XCTAssertEqual(shownText(session), ["النسخة الثانية"])
    }

    // MARK: Helpers

    @MainActor
    private func makeLibrary(video name: String) throws -> (AppServices, MediaItem) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SableSwitchingTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        let services = try AppServices(root: root)
        let item = try services.library.importVideo(from: try fixtureURL(name), copy: true)
        return (services, item)
    }

    private func fixtureURL(_ name: String) throws -> URL {
        let directory = try XCTUnwrap(Bundle.main.url(forResource: "UITestFixtures", withExtension: nil),
                                      "UITestFixtures is missing from the Debug app bundle")
        return directory.appendingPathComponent(name)
    }

    @MainActor
    private func requireTracks(_ ids: [String], in session: PlayerSession,
                               file: StaticString = #filePath, line: UInt = #line) throws {
        for id in ids {
            _ = try XCTUnwrap(session.subtitleTracks.first { $0.id == id },
                              "\(id) missing from \(session.subtitleTracks.map(\.id))", file: file, line: line)
        }
    }

    /// Offsets each timing group so the line starting at `firstLineStart` is visible at 0 s
    /// (0.5 s into it): effective = original + offset.
    @MainActor
    private func showFirstLineAtZero(_ services: AppServices, item: MediaItem, groups: [String: TimeInterval]) {
        for (group, start) in groups {
            services.timing.setTiming(SubtitleTiming(offset: -(start + 0.5)),
                                      forKey: TimingStore.key(videoID: item.id, timingGroupID: group), undoable: false)
        }
    }

    @MainActor
    private func shownText(_ session: PlayerSession) -> [String] {
        session.visibleCues.map(\.text)
    }

    /// Saves an Arabic translation of `source` (same cue ids and times) the way TranslationService does.
    @MainActor
    @discardableResult
    private func saveArabicTranslation(of source: SubtitleDocument, firstLine: String,
                                       services: AppServices, item: MediaItem) throws -> TranslatedSubtitleRef {
        let cues = source.cues.map { cue -> SubtitleCue in
            var translated = cue
            translated.text = cue.index == 0 ? firstLine : "سطر مترجم"
            translated.rawText = nil
            return translated
        }
        let document = SubtitleDocument(format: source.format, cues: cues, language: .arabic, title: "Arabic")
        return try services.library.saveTranslation(document, sourceTrackID: mkvEnglish, providerID: "tests",
                                                    modelID: nil, to: item.id)
    }
}
