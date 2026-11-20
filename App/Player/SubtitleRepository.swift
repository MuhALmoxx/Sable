import Foundation
import SubtitleKit
import LibraryKit

// OWNER: playback agent.
@MainActor
final class SubtitleRepository {
    let library: LibraryStore
    let probe: MediaProbeService

    init(library: LibraryStore, probe: MediaProbeService) {
        self.library = library
        self.probe = probe
    }

    /// Embedded (probed; cached per item) + external + translated tracks, embedded first.
    func tracks(for item: MediaItem) async -> [SubtitleTrackDescriptor] { [] }

    /// Loads a text track's document. Embedded tracks are extracted once (progress 0...1) and
    /// cached under Extracted/<itemID>/. Throws for image-based tracks.
    func document(for track: SubtitleTrackDescriptor, item: MediaItem,
                  progress: ((Double) -> Void)? = nil) async throws -> SubtitleDocument {
        throw SubtitleError.notImplemented("SubtitleRepository.document")
    }
}
