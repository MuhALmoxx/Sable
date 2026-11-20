import XCTest
import Foundation
@testable import LibraryKit
import SubtitleKit

final class LibraryStoreTests: XCTestCase {
    private var root: URL!
    private var inbox: URL!
    private var clock = Date(timeIntervalSinceReferenceDate: 800_000_000)

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("LibraryStoreTests-\(UUID().uuidString)")
        root = base.appendingPathComponent("Sable", isDirectory: true)
        inbox = base.appendingPathComponent("Inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    // MARK: Helpers

    private func makeStore() throws -> LibraryStore {
        try LibraryStore(root: root, fileManager: .default, now: { [unowned self] in self.clock })
    }

    @discardableResult
    private func makeFile(_ name: String, bytes: Int = 1024, contents: Data? = nil) throws -> URL {
        let url = inbox.appendingPathComponent(name)
        let data = contents ?? Data((0..<bytes).map { UInt8($0 % 251) })
        try data.write(to: url)
        return url
    }

    private let sampleSRT = """
    1
    00:00:03,000 --> 00:00:05,200
    Mara, are you still awake?

    2
    00:00:07,500 --> 00:00:10,400
    I can't sleep.

    """

    private func parserIsImplemented() -> Bool {
        do {
            _ = try SubtitleParser.parse(data: Data(sampleSRT.utf8), fileExtension: "srt")
            return true
        } catch SubtitleError.notImplemented {
            return false
        } catch {
            return true
        }
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    // MARK: Layout

    func testInitCreatesDirectoriesAndEmptyLibrary() throws {
        let store = try makeStore()
        var isDir: ObjCBool = false
        for dir in [store.mediaDirectory, store.subtitlesDirectory, store.thumbnailsDirectory,
                    store.extractedDirectory, store.translationsDirectory] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), dir.path)
            XCTAssertTrue(isDir.boolValue)
        }
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertNil(store.loadIssue)
        XCTAssertFalse(store.didRecoverFromCorruption)
    }

    // MARK: Import

    func testImportCopyKeepsSourceAndRecordsSizeAndTitle() throws {
        let store = try makeStore()
        let source = try makeFile("The.Night_Roof.2024.mkv", bytes: 4096)
        let item = try store.importVideo(from: source, copy: true)
        XCTAssertEqual(item.title, "The Night Roof 2024")
        XCTAssertEqual(item.fileName, "The.Night_Roof.2024.mkv")
        XCTAssertEqual(item.fileSize, 4096)
        XCTAssertEqual(item.addedAt, clock)
        XCTAssertEqual(item.fileExtension, "mkv")
        XCTAssertTrue(exists(source), "copy must keep the source")
        XCTAssertTrue(exists(store.mediaURL(for: item)))
        XCTAssertEqual(store.items.map(\.id), [item.id])
    }

    func testImportMoveRemovesSource() throws {
        let store = try makeStore()
        let source = try makeFile("night-roof.mp4")
        let item = try store.importVideo(from: source, copy: false)
        XCTAssertFalse(exists(source), "move must remove the source")
        XCTAssertTrue(exists(store.mediaURL(for: item)))
        XCTAssertEqual(item.title, "night-roof")
    }

    func testImportDeduplicatesFileNames() throws {
        let store = try makeStore()
        let source = try makeFile("Night Roof.mkv")
        let a = try store.importVideo(from: source, copy: true)
        let b = try store.importVideo(from: source, copy: true)
        let c = try store.importVideo(from: source, copy: true)
        XCTAssertEqual([a.fileName, b.fileName, c.fileName], ["Night Roof.mkv", "Night Roof (2).mkv", "Night Roof (3).mkv"])
        XCTAssertEqual(Set([a.id, b.id, c.id]).count, 3)
        XCTAssertEqual(a.title, "Night Roof")
        XCTAssertEqual(b.title, "Night Roof")
        let mediaFiles = try FileManager.default.contentsOfDirectory(atPath: store.mediaDirectory.path)
        XCTAssertEqual(mediaFiles.filter { !$0.hasPrefix(".") }.count, 3)
        XCTAssertFalse(mediaFiles.contains { $0.hasPrefix(".partial-") })
    }

    func testImportMissingFileThrowsFileNotFound() throws {
        let store = try makeStore()
        XCTAssertThrowsError(try store.importVideo(from: inbox.appendingPathComponent("gone.mkv"), copy: true)) { error in
            XCTAssertEqual(error as? LibraryError, .fileNotFound("gone.mkv"))
        }
        XCTAssertTrue(store.items.isEmpty)
    }

    func testImportRejectsSubtitleAndFolder() throws {
        let store = try makeStore()
        let srt = try makeFile("movie.en.srt", contents: Data(sampleSRT.utf8))
        XCTAssertThrowsError(try store.importVideo(from: srt, copy: true)) { error in
            XCTAssertEqual(error as? LibraryError, .unsupportedFileType("movie.en.srt"))
        }
        let folder = inbox.appendingPathComponent("Folder.mkv", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertThrowsError(try store.importVideo(from: folder, copy: true)) { error in
            XCTAssertEqual(error as? LibraryError, .unsupportedFileType("Folder.mkv"))
        }
        XCTAssertTrue(store.items.isEmpty)
    }

    func testTransferThenRegisterMatchesImport() throws {
        let store = try makeStore()
        let source = try makeFile("clip.webm", bytes: 10)
        let placed = try LibraryStore.transferFile(from: source, toDirectory: store.mediaDirectory, copy: true)
        XCTAssertEqual(placed, LibraryStore.TransferredFile(fileName: "clip.webm", fileSize: 10))
        let item = try store.registerImportedVideo(placed, originalFileName: "clip.webm")
        XCTAssertEqual(item.title, "clip")
        XCTAssertEqual(try makeStore().items.map(\.fileName), ["clip.webm"])
    }

    // MARK: Restart

    func testSimulatedRestartKeepsItemsAndPlaybackMemory() throws {
        let store = try makeStore()
        let item = try store.importVideo(from: try makeFile("night-roof.mkv"), copy: true)
        clock = clock.addingTimeInterval(60)
        try store.updatePlayback(itemID: item.id) { memory in
            memory.position = 751.5
            memory.rate = 1.25
            memory.audioTrackID = "2"
            memory.subtitleTrackID = "emb:mkv:3"
            memory.aspectMode = .ratio16x9
            memory.subtitleStyle = SubtitleStyle(scale: 1.4, background: .box, font: .pixel)
        }
        var renamed = try XCTUnwrap(store.item(id: item.id))
        renamed.duration = 1800
        try store.update(renamed)

        let reopened = try makeStore()
        XCTAssertNil(reopened.loadIssue)
        let restored = try XCTUnwrap(reopened.item(id: item.id))
        XCTAssertEqual(restored, try XCTUnwrap(store.item(id: item.id)))
        XCTAssertEqual(restored.playback.position, 751.5)
        XCTAssertEqual(restored.playback.rate, 1.25)
        XCTAssertEqual(restored.playback.subtitleTrackID, "emb:mkv:3")
        XCTAssertEqual(restored.playback.aspectMode, .ratio16x9)
        XCTAssertEqual(restored.playback.subtitleStyle?.background, .box)
        XCTAssertEqual(restored.lastPlayedAt, clock)
        XCTAssertEqual(restored.duration, 1800)
        XCTAssertEqual(restored.progressFraction, 751.5 / 1800, accuracy: 0.0001)
    }

    func testLibraryFileIsVersionedWrapper() throws {
        let store = try makeStore()
        try store.importVideo(from: try makeFile("a.mp4"), copy: true)
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: store.libraryFileURL)) as? [String: Any]
        XCTAssertEqual(json?["version"] as? Int, LibraryStore.currentVersion)
        XCTAssertEqual((json?["items"] as? [Any])?.count, 1)
    }

    func testUpdatePlaybackWithoutMarkPlayedKeepsLastPlayed() throws {
        let store = try makeStore()
        let item = try store.importVideo(from: try makeFile("a.mp4"), copy: true)
        try store.updatePlayback(itemID: item.id, markPlayed: false) { $0.aspectMode = .fill }
        XCTAssertNil(store.item(id: item.id)?.lastPlayedAt)
        XCTAssertEqual(store.item(id: item.id)?.playback.aspectMode, .fill)
    }

    func testUnknownItemThrows() throws {
        let store = try makeStore()
        let ghost = MediaItem(title: "x", fileName: "x.mp4", fileSize: 1)
        XCTAssertThrowsError(try store.update(ghost)) { XCTAssertEqual($0 as? LibraryError, .itemNotFound) }
        XCTAssertThrowsError(try store.updatePlayback(itemID: ghost.id) { $0.position = 1 })
        XCTAssertThrowsError(try store.remove(itemID: ghost.id))
        XCTAssertThrowsError(try store.attachSubtitle(from: try makeFile("x.srt", contents: Data(sampleSRT.utf8)), to: ghost.id, copy: true))
    }

    func testRenameAndMarkUnwatched() throws {
        let store = try makeStore()
        let item = try store.importVideo(from: try makeFile("a.mp4"), copy: true)
        try store.updatePlayback(itemID: item.id) { $0.position = 30; $0.completed = true }
        try store.rename(itemID: item.id, to: "  Night on the Roof ")
        try store.markUnwatched(itemID: item.id)
        let reopened = try XCTUnwrap(try makeStore().item(id: item.id))
        XCTAssertEqual(reopened.title, "Night on the Roof")
        XCTAssertEqual(reopened.fileName, "a.mp4")
        XCTAssertEqual(reopened.playback.position, 0)
        XCTAssertFalse(reopened.playback.completed)
        XCTAssertNil(reopened.lastPlayedAt)
        try store.rename(itemID: item.id, to: "   ")
        XCTAssertEqual(store.item(id: item.id)?.title, "Night on the Roof")
    }

    // MARK: Corruption

    func testCorruptFileIsMovedAsideAndLibraryStartsEmpty() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let garbage = Data("{ this is not json".utf8)
        try garbage.write(to: root.appendingPathComponent("library.json"))

        let store = try makeStore()
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertTrue(store.didRecoverFromCorruption)
        guard case let .corruptFileReplaced(backupName)? = store.loadIssue else {
            return XCTFail("expected corruptFileReplaced, got \(String(describing: store.loadIssue))")
        }
        XCTAssertTrue(backupName.hasPrefix("library.corrupt-"))
        XCTAssertTrue(backupName.hasSuffix(".json"))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(backupName)), garbage)

        // The fresh file is valid, so the next launch is clean.
        let reopened = try makeStore()
        XCTAssertNil(reopened.loadIssue)
        XCTAssertTrue(reopened.items.isEmpty)
    }

    func testCorruptBackupsDoNotOverwriteEachOther() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("garbage-1".utf8).write(to: root.appendingPathComponent("library.json"))
        let first = try makeStore().loadIssue?.backupFileName
        try Data("garbage-2".utf8).write(to: root.appendingPathComponent("library.json"))
        let second = try makeStore().loadIssue?.backupFileName
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertNotEqual(first, second)
    }

    func testDamagedEntryIsDroppedAndOthersKept() throws {
        let store = try makeStore()
        let good = try store.importVideo(from: try makeFile("good.mp4"), copy: true)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.libraryFileURL)) as? [String: Any])
        var items = try XCTUnwrap(json["items"] as? [Any])
        items.append(["id": "not-a-uuid", "title": 42])
        items.append("garbage")
        json["items"] = items
        try JSONSerialization.data(withJSONObject: json).write(to: store.libraryFileURL)

        let reopened = try makeStore()
        XCTAssertEqual(reopened.items.map(\.id), [good.id])
        guard case let .itemsDropped(count, backup)? = reopened.loadIssue else {
            return XCTFail("expected itemsDropped, got \(String(describing: reopened.loadIssue))")
        }
        XCTAssertEqual(count, 2)
        XCTAssertTrue(exists(root.appendingPathComponent(backup)))
        XCTAssertNil(try makeStore().loadIssue)
    }

    func testLegacyBareArrayIsMigrated() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Media"), withIntermediateDirectories: true)
        let legacy = MediaItem(title: "Old", fileName: "old.mkv", fileSize: 3)
        try Data([1, 2, 3]).write(to: root.appendingPathComponent("Media/old.mkv"))
        try JSONEncoder().encode([legacy]).write(to: root.appendingPathComponent("library.json"))
        let store = try makeStore()
        XCTAssertNil(store.loadIssue)
        XCTAssertEqual(store.items, [legacy])
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: store.libraryFileURL)) as? [String: Any]
        XCTAssertEqual(json?["version"] as? Int, 1)
    }

    func testOrphanedMediaIsAdoptedAndPartialsRemoved() throws {
        let media = root.appendingPathComponent("Media", isDirectory: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        try Data(count: 7).write(to: media.appendingPathComponent("Lost_Film.mkv"))
        try Data(count: 3).write(to: media.appendingPathComponent(".partial-123.mkv"))
        let store = try makeStore()
        XCTAssertEqual(store.adoptedOrphanCount, 1)
        XCTAssertEqual(store.items.map(\.title), ["Lost Film"])
        XCTAssertEqual(store.items.first?.fileSize, 7)
        XCTAssertFalse(exists(media.appendingPathComponent(".partial-123.mkv")))
        XCTAssertEqual(try makeStore().adoptedOrphanCount, 0)
    }

    // MARK: Subtitles

    func testAttachSubtitleCopiesAndGuessesLanguage() throws {
        let store = try makeStore()
        let item = try store.importVideo(from: try makeFile("night-roof.mkv"), copy: true)
        let source = try makeFile("night-roof.ar.srt", contents: Data(sampleSRT.utf8))
        let ref = try store.attachSubtitle(from: source, to: item.id, copy: true)
        XCTAssertTrue(ref.id.hasPrefix("ext:"))
        XCTAssertNotNil(UUID(uuidString: String(ref.id.dropFirst(4))))
        XCTAssertEqual(ref.fileName, "night-roof.ar.srt")
        XCTAssertEqual(ref.displayName, "night-roof.ar")
        XCTAssertEqual(ref.language, LanguageCode("ar"))
        XCTAssertEqual(ref.format, .srt)
        XCTAssertEqual(ref.addedAt, clock)
        XCTAssertTrue(exists(source))
        XCTAssertEqual(try Data(contentsOf: store.subtitleURL(for: ref)), Data(sampleSRT.utf8))
        XCTAssertEqual(try makeStore().item(id: item.id)?.externalSubtitles, [ref])
    }

    func testAttachSubtitleUniqueNamesAndMove() throws {
        let store = try makeStore()
        let item = try store.importVideo(from: try makeFile("v.mp4"), copy: true)
        let first = try store.attachSubtitle(from: try makeFile("movie.eng.srt", contents: Data(sampleSRT.utf8)), to: item.id, copy: false)
        let secondSource = try makeFile("movie.eng.srt", contents: Data(sampleSRT.utf8))
        let second = try store.attachSubtitle(from: secondSource, to: item.id, copy: false)
        XCTAssertFalse(exists(secondSource))
        XCTAssertEqual(first.fileName, "movie.eng.srt")
        XCTAssertEqual(second.fileName, "movie.eng (2).srt")
        XCTAssertEqual(first.language, .english)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(store.item(id: item.id)?.externalSubtitles.count, 2)
    }

    func testAttachSubtitleFormatsByExtension() throws {
        let store = try makeStore()
        let item = try store.importVideo(from: try makeFile("v.mp4"), copy: true)
        let vtt = "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nHello\n"
        let ass = """
        [Script Info]
        ScriptType: v4.00+

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,Hello

        """
        let vttRef = try store.attachSubtitle(from: try makeFile("clip.en-US.vtt", contents: Data(vtt.utf8)), to: item.id, copy: true)
        let assRef = try store.attachSubtitle(from: try makeFile("clip.fr.ass", contents: Data(ass.utf8)), to: item.id, copy: true)
        XCTAssertEqual(vttRef.format, .webvtt)
        XCTAssertEqual(vttRef.language, LanguageCode("en-US"))
        XCTAssertEqual(vttRef.language?.primary, "en")
        XCTAssertEqual(assRef.format, .ass)
        XCTAssertEqual(assRef.language, LanguageCode("fr"))
    }

    func testAttachSubtitleRejectsUnsupportedAndEmptyFiles() throws {
        let store = try makeStore()
        let item = try store.importVideo(from: try makeFile("v.mp4"), copy: true)
        XCTAssertThrowsError(try store.attachSubtitle(from: try makeFile("notes.pdf", contents: Data("%PDF-1.4".utf8)), to: item.id, copy: true)) { error in
            XCTAssertEqual(error as? LibraryError, .unsupportedSubtitleType("notes.pdf"))
        }
        XCTAssertThrowsError(try store.attachSubtitle(from: try makeFile("empty.srt", contents: Data()), to: item.id, copy: true)) { error in
            guard case .invalidSubtitle? = error as? LibraryError else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(store.item(id: item.id)?.externalSubtitles, [])
        let stored = try FileManager.default.contentsOfDirectory(atPath: store.subtitlesDirectory.path)
        XCTAssertTrue(stored.isEmpty, "rejected files must not be copied: \(stored)")
    }

    func testAttachSubtitleRejectsGarbageOnceParserExists() throws {
        guard parserIsImplemented() else { throw XCTSkip("SubtitleParser is still a stub; validation falls back to the extension") }
        let store = try makeStore()
        let item = try store.importVideo(from: try makeFile("v.mp4"), copy: true)
        let garbage = Data("this is not a subtitle file at all".utf8)
        XCTAssertThrowsError(try store.attachSubtitle(from: try makeFile("bad.srt", contents: garbage), to: item.id, copy: true)) { error in
            guard case .invalidSubtitle? = error as? LibraryError else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(store.item(id: item.id)?.externalSubtitles, [])
    }

    func testRemoveSubtitleDeletesFileAndClearsSelection() throws {
        let store = try makeStore()
        let item = try store.importVideo(from: try makeFile("v.mp4"), copy: true)
        let ref = try store.attachSubtitle(from: try makeFile("v.ar.srt", contents: Data(sampleSRT.utf8)), to: item.id, copy: true)
        try store.updatePlayback(itemID: item.id) { $0.subtitleTrackID = ref.id }
        try store.removeSubtitle(id: ref.id, from: item.id)
        XCTAssertEqual(store.item(id: item.id)?.externalSubtitles, [])
        XCTAssertNil(store.item(id: item.id)?.playback.subtitleTrackID)
        XCTAssertFalse(exists(store.subtitleURL(for: ref)))
    }

    // MARK: Translations

    private func arabicDocument(_ suffix: String = "") -> SubtitleDocument {
        SubtitleDocument(format: .srt, cues: [
            SubtitleCue(id: "1", index: 0, start: 3, end: 5.2, text: "مارا، هل ما زلتِ مستيقظة؟" + suffix),
            SubtitleCue(id: "2", index: 1, start: 7.5, end: 10.4, text: "لا أستطيع النوم." + suffix),
        ], language: .arabic)
    }

    func testSaveAndLoadTranslation() throws {
        let store = try makeStore()
        let item = try store.importVideo(from: try makeFile("night-roof.mkv"), copy: true)
        let ref = try store.saveTranslation(arabicDocument(), sourceTrackID: "emb:mkv:3", providerID: "claude",
                                            modelID: "claude-opus-5-5", to: item.id)
        XCTAssertEqual(ref.id, SubtitleTrackDescriptor.translatedID(target: .arabic, sourceTrackID: "emb:mkv:3"))
        XCTAssertEqual(ref.id, "tr:ar:emb:mkv:3")
        XCTAssertEqual(ref.sourceTrackID, "emb:mkv:3")
        XCTAssertEqual(ref.language, .arabic)
        XCTAssertEqual(ref.providerID, "claude")
        XCTAssertEqual(ref.modelID, "claude-opus-5-5")
        XCTAssertFalse(ref.fileName.contains(":"))
        XCTAssertTrue(ref.fileName.hasSuffix(".json"))
        XCTAssertEqual(try store.loadTranslation(ref), arabicDocument())

        let reopened = try makeStore()
        let restoredRef = try XCTUnwrap(reopened.item(id: item.id)?.translatedSubtitles.first)
        XCTAssertEqual(restoredRef, ref)
        XCTAssertEqual(try reopened.loadTranslation(restoredRef), arabicDocument())
    }

    func testSaveTranslationReplacesSameID() throws {
        let store = try makeStore()
        let item = try store.importVideo(from: try makeFile("night-roof.mkv"), copy: true)
        _ = try store.saveTranslation(arabicDocument(), sourceTrackID: "emb:mkv:3", providerID: "apple-on-device",
                                      modelID: nil, to: item.id)
        clock = clock.addingTimeInterval(10)
        let second = try store.saveTranslation(arabicDocument(" ✓"), sourceTrackID: "emb:mkv:3", providerID: "claude",
                                               modelID: "m", to: item.id)
        let other = try store.saveTranslation(arabicDocument(), sourceTrackID: "ext:ABC", providerID: "claude",
                                              modelID: "m", to: item.id)
        let refs = try XCTUnwrap(store.item(id: item.id)?.translatedSubtitles)
        XCTAssertEqual(refs.map(\.id), ["tr:ar:emb:mkv:3", "tr:ar:ext:ABC"])
        XCTAssertEqual(refs.first, second)
        XCTAssertEqual(refs.first?.providerID, "claude")
        XCTAssertEqual(refs.first?.createdAt, clock)
        XCTAssertEqual(try store.loadTranslation(second).cues.first?.text, "مارا، هل ما زلتِ مستيقظة؟ ✓")
        XCTAssertNotEqual(other.fileName, second.fileName)
        let jsonFiles = try FileManager.default.contentsOfDirectory(atPath: store.subtitlesDirectory.path).filter { $0.hasSuffix(".json") }
        XCTAssertEqual(jsonFiles.count, 2)
    }

    func testSaveTranslationDefaultsToArabicWhenLanguageMissing() throws {
        let store = try makeStore()
        let item = try store.importVideo(from: try makeFile("v.mp4"), copy: true)
        var doc = arabicDocument()
        doc.language = nil
        let ref = try store.saveTranslation(doc, sourceTrackID: "emb:mp4:3", providerID: "p", modelID: nil, to: item.id)
        XCTAssertEqual(ref.id, "tr:ar:emb:mp4:3")
        XCTAssertEqual(try store.loadTranslation(ref).language, .arabic)
    }

    func testLoadDamagedTranslationThrows() throws {
        let store = try makeStore()
        let item = try store.importVideo(from: try makeFile("v.mp4"), copy: true)
        let ref = try store.saveTranslation(arabicDocument(), sourceTrackID: "emb:mp4:3", providerID: "p", modelID: nil, to: item.id)
        try Data("nope".utf8).write(to: store.translationURL(for: ref))
        XCTAssertThrowsError(try store.loadTranslation(ref)) { error in
            guard case .invalidSubtitle? = error as? LibraryError else { return XCTFail("\(error)") }
        }
        try FileManager.default.removeItem(at: store.translationURL(for: ref))
        XCTAssertThrowsError(try store.loadTranslation(ref)) { error in
            XCTAssertEqual(error as? LibraryError, .fileNotFound(ref.fileName))
        }
    }

    // MARK: Remove

    func testRemoveDeletesEveryFileOfTheItem() throws {
        let store = try makeStore()
        let item = try store.importVideo(from: try makeFile("night-roof.mkv"), copy: true)
        let keep = try store.importVideo(from: try makeFile("other.mp4"), copy: true)
        let sub = try store.attachSubtitle(from: try makeFile("night-roof.en.srt", contents: Data(sampleSRT.utf8)), to: item.id, copy: true)
        let keepSub = try store.attachSubtitle(from: try makeFile("other.en.srt", contents: Data(sampleSRT.utf8)), to: keep.id, copy: true)
        let tr = try store.saveTranslation(arabicDocument(), sourceTrackID: sub.id, providerID: "p", modelID: nil, to: item.id)

        let thumbName = "\(item.id.uuidString).jpg"
        try Data([0xFF, 0xD8]).write(to: store.thumbnailsDirectory.appendingPathComponent(thumbName))
        var withThumb = try XCTUnwrap(store.item(id: item.id))
        withThumb.thumbnailFileName = thumbName
        try store.update(withThumb)
        let extracted = store.extractedDirectory(for: item.id)
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: extracted.appendingPathComponent("emb_mkv_3.json"))

        try store.remove(itemID: item.id)

        XCTAssertNil(store.item(id: item.id))
        XCTAssertFalse(exists(store.mediaURL(for: item)))
        XCTAssertFalse(exists(store.thumbnailsDirectory.appendingPathComponent(thumbName)))
        XCTAssertFalse(exists(store.subtitleURL(for: sub)))
        XCTAssertFalse(exists(store.translationURL(for: tr)))
        XCTAssertFalse(exists(extracted))
        // The other item is untouched.
        XCTAssertTrue(exists(store.mediaURL(for: keep)))
        XCTAssertTrue(exists(store.subtitleURL(for: keepSub)))
        let reopened = try makeStore()
        XCTAssertEqual(reopened.items.map(\.id), [keep.id])
        XCTAssertEqual(reopened.adoptedOrphanCount, 0)
    }

    // MARK: Storage

    func testStorageUsageAndCacheClearing() throws {
        let store = try makeStore()
        let item = try store.importVideo(from: try makeFile("v.mp4", bytes: 5000), copy: true)
        try Data(count: 300).write(to: store.thumbnailsDirectory.appendingPathComponent("\(item.id.uuidString).jpg"))
        var updated = try XCTUnwrap(store.item(id: item.id))
        updated.thumbnailFileName = "\(item.id.uuidString).jpg"
        try store.update(updated)
        let extracted = store.extractedDirectory(for: item.id)
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
        try Data(count: 200).write(to: extracted.appendingPathComponent("a.json"))

        let usage = store.storageUsage()
        XCTAssertEqual(usage.media, 5000)
        XCTAssertEqual(usage.thumbnails, 300)
        XCTAssertEqual(usage.extracted, 200)
        XCTAssertEqual(usage.caches, 500)
        XCTAssertGreaterThan(usage.other, 0, "library.json counts as other")
        XCTAssertEqual(usage.total, usage.media + usage.subtitles + usage.caches + usage.translations + usage.other)

        try store.clearThumbnails()
        try store.clearExtractionCache()
        XCTAssertNil(store.item(id: item.id)?.thumbnailFileName)
        XCTAssertNil(try makeStore().item(id: item.id)?.thumbnailFileName)
        let after = store.storageUsage()
        XCTAssertEqual(after.caches, 0)
        XCTAssertEqual(after.media, 5000)
        XCTAssertTrue(exists(store.extractedDirectory))
        XCTAssertTrue(exists(store.thumbnailsDirectory))
    }

    // MARK: Errors

    func testOutOfSpaceDetection() {
        XCTAssertTrue(LibraryError.isOutOfSpace(CocoaError(.fileWriteOutOfSpace)))
        XCTAssertTrue(LibraryError.isOutOfSpace(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))))
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileWriteUnknown.rawValue,
                              userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))])
        XCTAssertTrue(LibraryError.isOutOfSpace(wrapped))
        XCTAssertFalse(LibraryError.isOutOfSpace(CocoaError(.fileNoSuchFile)))
        XCTAssertNotNil(LibraryError.outOfSpace.errorDescription)
    }
}
