import UIKit
import LibraryKit

// OWNER: playback agent.
@MainActor
final class ThumbnailService {
    let library: LibraryStore

    init(library: LibraryStore) {
        self.library = library
    }

    /// Generates (AVAssetImageGenerator, or VLCMediaThumbnailer for non-AVFoundation files) and
    /// stores a JPEG thumbnail; returns its file name inside the thumbnails directory.
    func generateThumbnail(for item: MediaItem) async -> String? { nil }

    /// Cached image for the library grid.
    func image(for item: MediaItem) -> UIImage? { nil }
}
