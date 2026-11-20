import UIKit
import AVFoundation
import MobileVLCKit
import LibraryKit
import SubtitleKit

// OWNER: playback agent.
@MainActor
final class ThumbnailService {
    let library: LibraryStore
    private let cache = NSCache<NSString, UIImage>()
    private var inFlight: [UUID: Task<String?, Never>] = [:]
    private var missingFiles: Set<String> = []

    init(library: LibraryStore) {
        self.library = library
        cache.countLimit = 200
    }

    /// Generates (AVAssetImageGenerator, or VLCMediaThumbnailer for non-AVFoundation files) and
    /// stores a JPEG thumbnail; returns its file name inside the thumbnails directory.
    func generateThumbnail(for item: MediaItem) async -> String? {
        if let running = inFlight[item.id] { return await running.value }
        let task = Task { await self.makeThumbnail(for: item) }
        inFlight[item.id] = task
        let name = await task.value
        inFlight[item.id] = nil
        return name
    }

    /// Cached image for the library grid.
    func image(for item: MediaItem) -> UIImage? {
        guard let name = item.thumbnailFileName else { return nil }
        let key = name as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard !missingFiles.contains(name) else { return nil }
        let url = library.thumbnailsDirectory.appendingPathComponent(name)
        guard let image = UIImage(contentsOfFile: url.path) else {
            missingFiles.insert(name)
            return nil
        }
        cache.setObject(image, forKey: key)
        return image
    }

    private func makeThumbnail(for item: MediaItem) async -> String? {
        let url = library.mediaURL(for: item)
        let container = await Task.detached(priority: .utility) { ContainerSniffer.sniff(url: url) }.value
        var image: CGImage?
        if container == .mp4 {
            image = await Self.avFoundationThumbnail(url: url)
        }
        if image == nil {
            image = await VLCThumbnailRequest().run(url: url)
        }
        guard let image else {
            playbackLog.info("No thumbnail could be generated for \(item.fileName, privacy: .private)")
            return nil
        }
        let fileName = "\(item.id.uuidString).jpg"
        let destination = library.thumbnailsDirectory.appendingPathComponent(fileName)
        let uiImage = UIImage(cgImage: image)
        guard let data = uiImage.jpegData(compressionQuality: 0.82) else { return nil }
        do {
            try FileManager.default.createDirectory(at: library.thumbnailsDirectory, withIntermediateDirectories: true)
            try data.write(to: destination, options: .atomic)
        } catch {
            playbackLog.error("Couldn't save thumbnail: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        missingFiles.remove(fileName)
        cache.setObject(uiImage, forKey: fileName as NSString)
        return fileName
    }

    /// Frame 10 % into the video, at most 640 px on the long side, rotation applied.
    private static func avFoundationThumbnail(url: URL) async -> CGImage? {
        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration).seconds.finiteOrZero
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 640, height: 640)
            let tolerance = CMTime(seconds: 1, preferredTimescale: 600)
            generator.requestedTimeToleranceBefore = tolerance
            generator.requestedTimeToleranceAfter = tolerance
            let time = CMTime(seconds: duration > 0 ? duration * 0.1 : 0, preferredTimescale: 600)
            let (image, _) = try await generator.image(at: time)
            return image
        } catch {
            return nil
        }
    }
}

/// One VLCMediaThumbnailer run. Keeps itself (and the thumbnailer, whose delegate is weak) alive
/// until the delegate reports back or the timeout fires.
@MainActor
private final class VLCThumbnailRequest: NSObject, VLCMediaThumbnailerDelegate {
    private var continuation: CheckedContinuation<CGImage?, Never>?
    private var thumbnailer: VLCMediaThumbnailer?
    private var media: VLCMedia?
    private var keepAlive: VLCThumbnailRequest?

    func run(url: URL, timeout: TimeInterval = 12) async -> CGImage? {
        await withCheckedContinuation { (continuation: CheckedContinuation<CGImage?, Never>) in
            self.continuation = continuation
            self.keepAlive = self
            let media = VLCMedia(url: url)
            self.media = media
            let thumbnailer = VLCMediaThumbnailer(media: media, andDelegate: self)
            thumbnailer.snapshotPosition = 0.1
            thumbnailer.thumbnailWidth = 640
            thumbnailer.thumbnailHeight = 360
            self.thumbnailer = thumbnailer
            thumbnailer.fetchThumbnail()
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                MainActor.assumeIsolated { self?.finish(nil) }
            }
        }
    }

    private func finish(_ image: CGImage?) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: image)
        thumbnailer?.delegate = nil
        thumbnailer = nil
        media = nil
        keepAlive = nil
    }

    nonisolated func mediaThumbnailerDidTimeOut(_ mediaThumbnailer: VLCMediaThumbnailer) {
        Task { @MainActor [weak self] in self?.finish(nil) }
    }

    nonisolated func mediaThumbnailer(_ mediaThumbnailer: VLCMediaThumbnailer, didFinishThumbnail thumbnail: CGImage) {
        // The thumbnailer owns the CGImage; copy it before hopping to the main actor.
        let copy = thumbnail.copy()
        Task { @MainActor [weak self] in self?.finish(copy) }
    }
}
