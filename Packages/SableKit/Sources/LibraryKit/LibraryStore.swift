import Foundation
import SubtitleKit

// OWNER: library agent.

/// On-disk layout under `root` (Application Support/Sable in the app):
///   library.json          — {"version": 1, "items": [MediaItem]}
///   Media/                — imported video files
///   Subtitles/            — imported subtitle files and translated documents (JSON)
///   Thumbnails/           — JPEG thumbnails
///   Extracted/<itemID>/   — cached embedded-subtitle extractions (JSON SubtitleDocument)
///   Translations/         — TranslationEngine store (checkpoints + completed cache)
///   timing.json           — TimingStore
/// Not thread-safe: use from one actor (the app uses it on the main actor). Writes are atomic.
/// The static helpers (`transferFile`, `measureStorage`) touch only the file system and may run
/// off the main actor.
public final class LibraryStore {
    public static let currentVersion = 1

    public let root: URL
    public private(set) var items: [MediaItem] = []
    /// Set when library.json was damaged at launch (the app shows a one-time banner).
    public private(set) var loadIssue: LibraryLoadIssue?
    /// Video files found in Media/ without a library entry and re-added at launch.
    public private(set) var adoptedOrphanCount = 0

    public var didRecoverFromCorruption: Bool { loadIssue != nil }

    public var libraryFileURL: URL { root.appendingPathComponent("library.json") }
    public var mediaDirectory: URL { root.appendingPathComponent("Media", isDirectory: true) }
    public var subtitlesDirectory: URL { root.appendingPathComponent("Subtitles", isDirectory: true) }
    public var thumbnailsDirectory: URL { root.appendingPathComponent("Thumbnails", isDirectory: true) }
    public var extractedDirectory: URL { root.appendingPathComponent("Extracted", isDirectory: true) }
    public var translationsDirectory: URL { root.appendingPathComponent("Translations", isDirectory: true) }
    public var timingFileURL: URL { root.appendingPathComponent("timing.json") }

    private let fileManager: FileManager
    private let now: () -> Date

    public convenience init(root: URL) throws {
        try self.init(root: root, fileManager: .default, now: Date.init)
    }

    /// `now` is injectable for tests (corrupt-file timestamps, addedAt).
    public init(root: URL, fileManager: FileManager, now: @escaping () -> Date) throws {
        self.root = root
        self.fileManager = fileManager
        self.now = now
        try createDirectories()
        try load()
        adoptOrphanedMedia()
    }

    // MARK: Lookup

    public func item(id: UUID) -> MediaItem? { items.first { $0.id == id } }
    public func mediaURL(for item: MediaItem) -> URL { mediaDirectory.appendingPathComponent(item.fileName) }

    public func thumbnailURL(for item: MediaItem) -> URL? {
        item.thumbnailFileName.map { thumbnailsDirectory.appendingPathComponent($0) }
    }

    public func subtitleURL(for ref: ExternalSubtitleRef) -> URL {
        subtitlesDirectory.appendingPathComponent(ref.fileName)
    }

    public func translationURL(for ref: TranslatedSubtitleRef) -> URL {
        subtitlesDirectory.appendingPathComponent(ref.fileName)
    }

    /// Cache folder for embedded-subtitle extractions of one item (not created here).
    public func extractedDirectory(for itemID: UUID) -> URL {
        extractedDirectory.appendingPathComponent(itemID.uuidString, isDirectory: true)
    }

    // MARK: Import

    /// Moves (or copies when `copy` is true) a picked file into Media/, de-duplicating the file
    /// name, and appends a new item. Title defaults to the file name without extension.
    @discardableResult
    public func importVideo(from url: URL, copy: Bool) throws -> MediaItem {
        let sourceName = url.lastPathComponent
        if LibraryFileNaming.kind(ofFileExtension: url.pathExtension) == .subtitle {
            throw LibraryError.unsupportedFileType(sourceName)
        }
        let transferred = try Self.transferFile(from: url, toDirectory: mediaDirectory, copy: copy)
        return try registerImportedVideo(transferred, originalFileName: sourceName)
    }

    /// Second half of an import whose file was already placed in Media/ by `transferFile`
    /// (typically off the main actor). Appends and saves the item; on a failed save the file is
    /// deleted again so nothing is left orphaned.
    @discardableResult
    public func registerImportedVideo(_ file: TransferredFile, originalFileName: String? = nil) throws -> MediaItem {
        let item = MediaItem(
            title: LibraryFileNaming.title(fromFileName: originalFileName ?? file.fileName),
            fileName: file.fileName,
            fileSize: file.fileSize,
            addedAt: now()
        )
        items.append(item)
        do {
            try save()
        } catch {
            items.removeAll { $0.id == item.id }
            try? fileManager.removeItem(at: mediaDirectory.appendingPathComponent(file.fileName))
            throw error
        }
        return item
    }

    /// Result of placing a file into a library folder.
    public struct TransferredFile: Equatable, Sendable {
        public let fileName: String
        public let fileSize: Int64
        public init(fileName: String, fileSize: Int64) { self.fileName = fileName; self.fileSize = fileSize }
    }

    /// Moves (or copies) `source` into `directory` under a unique, sanitized name. The data is
    /// first written to a hidden ".partial-…" file and renamed when complete, so an interrupted
    /// import never leaves a truncated file with a real name. A failed move falls back to a copy.
    public static func transferFile(from source: URL, toDirectory directory: URL, copy: Bool,
                                    preferredName: String? = nil) throws -> TransferredFile {
        let fm = FileManager.default
        let sourceName = source.lastPathComponent
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDirectory) else {
            throw LibraryError.fileNotFound(sourceName)
        }
        if isDirectory.boolValue { throw LibraryError.unsupportedFileType(sourceName) }
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw mapCopyError(error)
        }

        let desired = LibraryFileNaming.sanitizedFileName(preferredName ?? sourceName,
                                                          fallbackExtension: source.pathExtension)
        let ext = (desired as NSString).pathExtension
        let partial = directory.appendingPathComponent(".partial-\(UUID().uuidString)" + (ext.isEmpty ? "" : ".\(ext)"))

        do {
            if copy {
                try fm.copyItem(at: source, to: partial)
            } else {
                do {
                    try fm.moveItem(at: source, to: partial)
                } catch {
                    if LibraryError.isOutOfSpace(error) { throw error }
                    try fm.copyItem(at: source, to: partial)
                    try? fm.removeItem(at: source)
                }
            }
        } catch {
            try? fm.removeItem(at: partial)
            throw mapCopyError(error)
        }

        var finalName = ""
        var attempts = 0
        while true {
            finalName = LibraryFileNaming.uniqueFileName(desired) { name in
                fm.fileExists(atPath: directory.appendingPathComponent(name).path)
            }
            do {
                try fm.moveItem(at: partial, to: directory.appendingPathComponent(finalName))
                break
            } catch {
                attempts += 1
                // Another import took the name between the check and the rename: try the next one.
                if attempts < 5, fm.fileExists(atPath: directory.appendingPathComponent(finalName).path) { continue }
                try? fm.removeItem(at: partial)
                throw mapCopyError(error)
            }
        }

        let finalURL = directory.appendingPathComponent(finalName)
        let size = (try? fm.attributesOfItem(atPath: finalURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        return TransferredFile(fileName: finalName, fileSize: size)
    }

    private static func mapCopyError(_ error: Error) -> LibraryError {
        if let libraryError = error as? LibraryError { return libraryError }
        if LibraryError.isOutOfSpace(error) { return .outOfSpace }
        return .copyFailed(error.localizedDescription)
    }

    // MARK: Subtitles

    /// Copies a subtitle file into Subtitles/ and attaches it to the item. Validates by parsing
    /// (while the parser is unavailable, by extension). The language is guessed from the file
    /// name ("movie.ar.srt"), falling back to the language the parser reports.
    @discardableResult
    public func attachSubtitle(from url: URL, to itemID: UUID, copy: Bool) throws -> ExternalSubtitleRef {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { throw LibraryError.itemNotFound }
        let sourceName = url.lastPathComponent
        if let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value,
           size > Self.maxSubtitleFileSize {
            throw LibraryError.unsupportedSubtitleType(sourceName)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            if !fileManager.fileExists(atPath: url.path) { throw LibraryError.fileNotFound(sourceName) }
            throw LibraryError.copyFailed(error.localizedDescription)
        }
        let validated = try Self.validateSubtitle(data: data, fileName: sourceName)

        // Store with a real subtitle extension even if the source had none (e.g. sniffed .txt).
        var storedName = sourceName
        let ext = (sourceName as NSString).pathExtension.lowercased()
        if SubtitleFormat.fromFileExtension(ext) == nil, let canonical = Self.canonicalExtension(validated.format) {
            storedName = (sourceName as NSString).deletingPathExtension + ".\(canonical)"
        }
        let transferred = try Self.transferFile(from: url, toDirectory: subtitlesDirectory, copy: copy,
                                                preferredName: storedName)
        let displayBase = (sourceName as NSString).deletingPathExtension
        let ref = ExternalSubtitleRef(
            id: "ext:\(UUID().uuidString)",
            fileName: transferred.fileName,
            displayName: displayBase.isEmpty ? sourceName : displayBase,
            language: LibraryFileNaming.guessLanguage(fromFileName: sourceName) ?? validated.language,
            format: validated.format,
            addedAt: now()
        )
        items[index].externalSubtitles.append(ref)
        do {
            try save()
        } catch {
            items[index].externalSubtitles.removeAll { $0.id == ref.id }
            try? fileManager.removeItem(at: subtitlesDirectory.appendingPathComponent(transferred.fileName))
            throw error
        }
        return ref
    }

    /// Detaches an imported subtitle file and deletes it.
    public func removeSubtitle(id: String, from itemID: UUID) throws {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { throw LibraryError.itemNotFound }
        guard let ref = items[index].externalSubtitles.first(where: { $0.id == id }) else { return }
        items[index].externalSubtitles.removeAll { $0.id == id }
        if items[index].playback.subtitleTrackID == id { items[index].playback.subtitleTrackID = nil }
        try save()
        try? fileManager.removeItem(at: subtitleURL(for: ref))
    }

    /// Subtitle files are text; anything larger than this is not one.
    public static let maxSubtitleFileSize: Int64 = 64 * 1024 * 1024

    public struct ValidatedSubtitle: Equatable, Sendable {
        public let format: SubtitleFormat
        public let language: LanguageCode?
        public let cueCount: Int?
    }

    /// Parses `data` to make sure it is a usable subtitle file. When `SubtitleParser` is not
    /// implemented yet, accepts SRT/WebVTT/ASS/SSA by extension.
    public static func validateSubtitle(data: Data, fileName: String) throws -> ValidatedSubtitle {
        let ext = (fileName as NSString).pathExtension.lowercased()
        let extensionFormat = SubtitleFormat.fromFileExtension(ext)
        if data.isEmpty { throw LibraryError.invalidSubtitle(SubtitleError.empty.errorDescription ?? "empty file") }
        do {
            let document = try SubtitleParser.parse(data: data, fileExtension: ext.isEmpty ? nil : ext)
            var format = document.format
            if format == .unknown, let extensionFormat { format = extensionFormat }
            return ValidatedSubtitle(format: format, language: document.language, cueCount: document.cues.count)
        } catch SubtitleError.notImplemented {
            guard let extensionFormat else { throw LibraryError.unsupportedSubtitleType(fileName) }
            return ValidatedSubtitle(format: extensionFormat, language: nil, cueCount: nil)
        } catch let error as SubtitleError {
            // Not a subtitle extension and not recognisable content: wrong kind of file.
            if extensionFormat == nil { throw LibraryError.unsupportedSubtitleType(fileName) }
            throw LibraryError.invalidSubtitle(error.errorDescription ?? "\(error)")
        } catch {
            if extensionFormat == nil { throw LibraryError.unsupportedSubtitleType(fileName) }
            throw LibraryError.invalidSubtitle(error.localizedDescription)
        }
    }

    private static func canonicalExtension(_ format: SubtitleFormat) -> String? {
        switch format {
        case .srt: return "srt"
        case .webvtt: return "vtt"
        case .ass: return "ass"
        case .ssa: return "ssa"
        case .tx3g, .unknown: return nil
        }
    }

    // MARK: Translations

    /// Stores a translated document (JSON) and attaches/replaces the ref on the item.
    /// The target language is `document.language` (Arabic when the document does not say).
    @discardableResult
    public func saveTranslation(_ document: SubtitleDocument, sourceTrackID: String, providerID: String,
                                modelID: String?, to itemID: UUID) throws -> TranslatedSubtitleRef {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { throw LibraryError.itemNotFound }
        let target = document.language ?? .arabic
        let id = SubtitleTrackDescriptor.translatedID(target: target, sourceTrackID: sourceTrackID)
        let fileName = "\(itemID.uuidString).\(LibraryFileNaming.safeComponent(id)).json"
        let url = subtitlesDirectory.appendingPathComponent(fileName)

        var stored = document
        stored.language = target
        let data: Data
        do {
            data = try Self.encoder().encode(stored)
        } catch {
            throw LibraryError.io(error.localizedDescription)
        }
        try write(data, to: url)

        let ref = TranslatedSubtitleRef(id: id, sourceTrackID: sourceTrackID, language: target, providerID: providerID,
                                        modelID: modelID, fileName: fileName, createdAt: now())
        let previous = items[index].translatedSubtitles
        if let existing = previous.firstIndex(where: { $0.id == id }) {
            let oldFile = previous[existing].fileName
            items[index].translatedSubtitles[existing] = ref
            if oldFile != fileName { try? fileManager.removeItem(at: subtitlesDirectory.appendingPathComponent(oldFile)) }
        } else {
            items[index].translatedSubtitles.append(ref)
        }
        do {
            try save()
        } catch {
            items[index].translatedSubtitles = previous
            throw error
        }
        return ref
    }

    public func loadTranslation(_ ref: TranslatedSubtitleRef) throws -> SubtitleDocument {
        let url = translationURL(for: ref)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw LibraryError.fileNotFound(ref.fileName)
        }
        do {
            return try JSONDecoder().decode(SubtitleDocument.self, from: data)
        } catch {
            throw LibraryError.invalidSubtitle("the saved translation is damaged (\(error.localizedDescription))")
        }
    }

    /// Deletes a translated track (its JSON document and the ref).
    public func removeTranslation(id: String, from itemID: UUID) throws {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { throw LibraryError.itemNotFound }
        guard let ref = items[index].translatedSubtitles.first(where: { $0.id == id }) else { return }
        items[index].translatedSubtitles.removeAll { $0.id == id }
        if items[index].playback.subtitleTrackID == id { items[index].playback.subtitleTrackID = nil }
        try save()
        try? fileManager.removeItem(at: translationURL(for: ref))
    }

    // MARK: Updates

    /// Replaces the stored item with the same id and saves.
    public func update(_ item: MediaItem) throws {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { throw LibraryError.itemNotFound }
        let previous = items[index]
        items[index] = item
        do {
            try save()
        } catch {
            items[index] = previous
            throw error
        }
    }

    /// Mutates the item's playback memory and saves. `markPlayed` also stamps `lastPlayedAt`
    /// (used by the "Recently played" sort).
    public func updatePlayback(itemID: UUID, markPlayed: Bool = true, _ mutate: (inout PlaybackMemory) -> Void) throws {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { throw LibraryError.itemNotFound }
        let previous = items[index]
        mutate(&items[index].playback)
        if markPlayed { items[index].lastPlayedAt = now() }
        if items[index] == previous { return }
        do {
            try save()
        } catch {
            items[index] = previous
            throw error
        }
    }

    /// "Mark as unwatched": clears position, completion and the last-played date.
    public func markUnwatched(itemID: UUID) throws {
        guard var item = item(id: itemID) else { throw LibraryError.itemNotFound }
        item.playback.position = 0
        item.playback.completed = false
        item.lastPlayedAt = nil
        try update(item)
    }

    /// Renames the item's title (the file on disk keeps its name). Empty titles are rejected.
    public func rename(itemID: UUID, to title: String) throws {
        guard var item = item(id: itemID) else { throw LibraryError.itemNotFound }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != item.title else { return }
        item.title = trimmed
        try update(item)
    }

    /// Removes the item, its media file, thumbnail, subtitles, translations and extractions.
    /// Timing is removed by the app (`TimingStore.removeAll(videoID:)`).
    public func remove(itemID: UUID) throws {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { throw LibraryError.itemNotFound }
        let item = items[index]
        items.remove(at: index)
        do {
            try save()
        } catch {
            items.insert(item, at: index)
            throw error
        }
        try? fileManager.removeItem(at: mediaURL(for: item))
        if let thumb = thumbnailURL(for: item) { try? fileManager.removeItem(at: thumb) }
        // Thumbnails written under the item's id but not (yet) recorded on the item.
        if let names = try? fileManager.contentsOfDirectory(atPath: thumbnailsDirectory.path) {
            for name in names where name.hasPrefix(item.id.uuidString) {
                try? fileManager.removeItem(at: thumbnailsDirectory.appendingPathComponent(name))
            }
        }
        for ref in item.externalSubtitles { try? fileManager.removeItem(at: subtitleURL(for: ref)) }
        for ref in item.translatedSubtitles { try? fileManager.removeItem(at: translationURL(for: ref)) }
        try? fileManager.removeItem(at: extractedDirectory(for: item.id))
    }

    // MARK: Caches

    /// Deletes every thumbnail and clears the references (the app regenerates them on demand).
    public func clearThumbnails() throws {
        try removeContents(of: thumbnailsDirectory)
        var changed = false
        for index in items.indices where items[index].thumbnailFileName != nil {
            items[index].thumbnailFileName = nil
            changed = true
        }
        if changed { try save() }
    }

    /// Deletes every cached embedded-subtitle extraction (re-extracted on next use).
    public func clearExtractionCache() throws {
        try removeContents(of: extractedDirectory)
    }

    private func removeContents(of directory: URL) throws {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names {
            do {
                try fileManager.removeItem(at: directory.appendingPathComponent(name))
            } catch {
                throw LibraryError.io(error.localizedDescription)
            }
        }
    }

    /// Bytes used per area of the library.
    public struct StorageUsage: Equatable, Sendable {
        public var media: Int64 = 0
        public var subtitles: Int64 = 0
        public var thumbnails: Int64 = 0
        public var extracted: Int64 = 0
        public var translations: Int64 = 0
        public var other: Int64 = 0
        public init() {}
        public var caches: Int64 { thumbnails + extracted }
        public var total: Int64 { media + subtitles + thumbnails + extracted + translations + other }
    }

    public func storageUsage() -> StorageUsage { Self.measureStorage(root: root) }

    /// File-system walk; safe to call off the main actor.
    public static func measureStorage(root: URL) -> StorageUsage {
        var usage = StorageUsage()
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return usage }
        for name in names {
            let url = root.appendingPathComponent(name)
            let size = allocatedSize(of: url)
            switch name {
            case "Media": usage.media += size
            case "Subtitles": usage.subtitles += size
            case "Thumbnails": usage.thumbnails += size
            case "Extracted": usage.extracted += size
            case "Translations": usage.translations += size
            default: usage.other += size
            }
        }
        return usage
    }

    private static func allocatedSize(of url: URL) -> Int64 {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        if !isDirectory.boolValue {
            return (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        }
        var total: Int64 = 0
        guard let enumerator = fm.enumerator(atPath: url.path) else { return 0 }
        while let relative = enumerator.nextObject() as? String {
            let path = url.appendingPathComponent(relative).path
            guard let attributes = try? fm.attributesOfItem(atPath: path), isRegularFile(attributes) else { continue }
            total += (attributes[.size] as? NSNumber)?.int64Value ?? 0
        }
        return total
    }

    private static func isRegularFile(_ attributes: [FileAttributeKey: Any]) -> Bool {
        if let type = attributes[.type] as? FileAttributeType { return type == .typeRegular }
        if let raw = attributes[.type] as? String { return raw == FileAttributeType.typeRegular.rawValue }
        return false
    }

    // MARK: Persistence

    private struct LibraryFile: Codable {
        var version: Int
        var items: [MediaItem]
    }

    /// Decodes each item on its own so one damaged entry does not take the whole library down.
    private struct LossyLibraryFile: Decodable {
        var version: Int
        var items: [MediaItem]
        var droppedCount: Int

        private enum CodingKeys: String, CodingKey { case version, items }
        /// Consumes one array element of any shape without reading it.
        private struct Skip: Decodable { init(from decoder: Decoder) throws {} }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decode(Int.self, forKey: .version)
            var list = try container.nestedUnkeyedContainer(forKey: .items)
            var decoded: [MediaItem] = []
            var dropped = 0
            while !list.isAtEnd {
                if let item = try? list.decode(MediaItem.self) {
                    decoded.append(item)
                } else {
                    _ = try? list.decode(Skip.self)
                    dropped += 1
                }
            }
            items = decoded
            droppedCount = dropped
        }
    }

    public func save() throws {
        let data: Data
        do {
            data = try Self.encoder().encode(LibraryFile(version: Self.currentVersion, items: items))
        } catch {
            throw LibraryError.io(error.localizedDescription)
        }
        try write(data, to: libraryFileURL)
    }

    private func write(_ data: Data, to url: URL) throws {
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            if LibraryError.isOutOfSpace(error) { throw LibraryError.outOfSpace }
            throw LibraryError.io(error.localizedDescription)
        }
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private func createDirectories() throws {
        for directory in [root, mediaDirectory, subtitlesDirectory, thumbnailsDirectory, extractedDirectory, translationsDirectory] {
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                throw LibraryError.io(error.localizedDescription)
            }
        }
        #if canImport(Darwin)
        // Caches can be rebuilt: keep them out of device backups.
        for var directory in [thumbnailsDirectory, extractedDirectory] {
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? directory.setResourceValues(values)
        }
        #endif
    }

    private func load() throws {
        let url = libraryFileURL
        guard fileManager.fileExists(atPath: url.path) else { items = []; return }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            // Unreadable (not undecodable): never overwrite it with an empty library.
            throw LibraryError.io(error.localizedDescription)
        }
        let decoder = JSONDecoder()
        if let file = try? decoder.decode(LossyLibraryFile.self, from: data) {
            items = file.items
            if file.droppedCount > 0 {
                let backup = try backupCorruptFile(move: false)
                loadIssue = .itemsDropped(count: file.droppedCount, backupFileName: backup)
                try save()
            }
            return
        }
        // Pre-release layout: a bare array of items.
        if let legacy = try? decoder.decode([MediaItem].self, from: data) {
            items = legacy
            try save()
            return
        }
        let backup = try backupCorruptFile(move: true)
        loadIssue = .corruptFileReplaced(backupFileName: backup)
        items = []
        try save()
    }

    /// Moves (or copies) library.json aside to "library.corrupt-<timestamp>.json".
    private func backupCorruptFile(move: Bool) throws -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: now())
        let name = LibraryFileNaming.uniqueFileName("library.corrupt-\(stamp).json") { candidate in
            fileManager.fileExists(atPath: root.appendingPathComponent(candidate).path)
        }
        let destination = root.appendingPathComponent(name)
        do {
            if move {
                try fileManager.moveItem(at: libraryFileURL, to: destination)
            } else {
                try fileManager.copyItem(at: libraryFileURL, to: destination)
            }
        } catch {
            throw LibraryError.io(error.localizedDescription)
        }
        return name
    }

    /// Re-adds video files that sit in Media/ without an entry (after a damaged library file, or
    /// an import interrupted between copying and saving). Leftover ".partial-" files are deleted.
    private func adoptOrphanedMedia() {
        guard let names = try? fileManager.contentsOfDirectory(atPath: mediaDirectory.path) else { return }
        let known = Set(items.map(\.fileName))
        var adopted = 0
        for name in names.sorted() {
            let url = mediaDirectory.appendingPathComponent(name)
            if name.hasPrefix(".partial-") {
                try? fileManager.removeItem(at: url)
                continue
            }
            guard !name.hasPrefix("."), !known.contains(name) else { continue }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            let attributes = try? fileManager.attributesOfItem(atPath: url.path)
            let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            let added = (attributes?[.creationDate] as? Date) ?? (attributes?[.modificationDate] as? Date) ?? now()
            items.append(MediaItem(title: LibraryFileNaming.title(fromFileName: name), fileName: name,
                                   fileSize: size, addedAt: added))
            adopted += 1
        }
        guard adopted > 0 else { return }
        adoptedOrphanCount = adopted
        try? save()
    }
}
