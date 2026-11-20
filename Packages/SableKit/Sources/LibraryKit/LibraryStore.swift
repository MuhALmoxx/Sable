import Foundation
import SubtitleKit

// OWNER: library agent.

/// On-disk layout under `root` (Application Support/Sable in the app):
///   library.json          — [MediaItem]
///   Media/                — imported video files
///   Subtitles/            — imported subtitle files and translated documents (JSON)
///   Thumbnails/           — JPEG thumbnails
///   Extracted/<itemID>/   — cached embedded-subtitle extractions (JSON SubtitleDocument)
///   Translations/         — TranslationEngine store (checkpoints + completed cache)
///   timing.json           — TimingStore
/// Not thread-safe: use from one actor (the app uses it on the main actor). Writes are atomic.
public final class LibraryStore {
    public let root: URL
    public private(set) var items: [MediaItem] = []

    public var mediaDirectory: URL { root.appendingPathComponent("Media", isDirectory: true) }
    public var subtitlesDirectory: URL { root.appendingPathComponent("Subtitles", isDirectory: true) }
    public var thumbnailsDirectory: URL { root.appendingPathComponent("Thumbnails", isDirectory: true) }
    public var extractedDirectory: URL { root.appendingPathComponent("Extracted", isDirectory: true) }
    public var translationsDirectory: URL { root.appendingPathComponent("Translations", isDirectory: true) }
    public var timingFileURL: URL { root.appendingPathComponent("timing.json") }

    public init(root: URL) throws {
        self.root = root
    }

    public func item(id: UUID) -> MediaItem? { items.first { $0.id == id } }
    public func mediaURL(for item: MediaItem) -> URL { mediaDirectory.appendingPathComponent(item.fileName) }

    /// Moves (or copies when `copy` is true) a picked file into Media/, de-duplicating the file
    /// name, and appends a new item. Title defaults to the file name without extension.
    @discardableResult
    public func importVideo(from url: URL, copy: Bool) throws -> MediaItem {
        throw SubtitleError.notImplemented("LibraryStore.importVideo")
    }

    /// Copies a subtitle file into Subtitles/ and attaches it to the item. Validates by parsing.
    @discardableResult
    public func attachSubtitle(from url: URL, to itemID: UUID, copy: Bool) throws -> ExternalSubtitleRef {
        throw SubtitleError.notImplemented("LibraryStore.attachSubtitle")
    }

    /// Stores a translated document (JSON) and attaches/replaces the ref on the item.
    @discardableResult
    public func saveTranslation(_ document: SubtitleDocument, sourceTrackID: String, providerID: String,
                                modelID: String?, to itemID: UUID) throws -> TranslatedSubtitleRef {
        throw SubtitleError.notImplemented("LibraryStore.saveTranslation")
    }

    public func loadTranslation(_ ref: TranslatedSubtitleRef) throws -> SubtitleDocument {
        throw SubtitleError.notImplemented("LibraryStore.loadTranslation")
    }

    public func update(_ item: MediaItem) throws {}
    public func updatePlayback(itemID: UUID, _ mutate: (inout PlaybackMemory) -> Void) throws {}

    /// Removes the item, its media file, thumbnails, subtitles, extractions and timing.
    public func remove(itemID: UUID) throws {}

    public func save() throws {}
}
