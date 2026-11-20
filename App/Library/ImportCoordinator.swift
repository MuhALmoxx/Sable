import Foundation
import Observation
import LibraryKit

// OWNER: library agent.

/// Runs video imports one at a time and exposes per-file progress for the library screen:
/// copy/move into the library (off the main actor) -> probe (duration, playability) ->
/// thumbnail. Also repairs missing durations/thumbnails lazily for existing items.
@Observable
@MainActor
final class ImportCoordinator {
    enum Phase: Equatable {
        case waiting
        case importing
        case reading
        case thumbnail
        case done
        /// Imported, but something is worth knowing (e.g. AVFoundation cannot read it).
        case warning(String)
        case failed(String)

        var label: String {
            switch self {
            case .waiting: return "Waiting"
            case .importing: return "Importing"
            case .reading: return "Reading"
            case .thumbnail: return "Thumbnail"
            case .done: return "Done"
            case .warning: return "Imported"
            case .failed: return "Failed"
            }
        }

        /// Step progress for the row's bar.
        var fraction: Double {
            switch self {
            case .waiting: return 0.04
            case .importing: return 0.3
            case .reading: return 0.6
            case .thumbnail: return 0.85
            case .done, .warning, .failed: return 1
            }
        }

        var isFinished: Bool {
            switch self {
            case .done, .warning, .failed: return true
            default: return false
            }
        }
    }

    struct Job: Identifiable, Equatable {
        let id: UUID
        let fileName: String
        var phase: Phase
        var itemID: UUID?
    }

    private(set) var jobs: [Job] = []
    private var queue: [(jobID: UUID, url: URL)] = []
    private var isRunning = false
    /// Items whose metadata repair already ran this session (prevents retry loops).
    private var repairAttempts: Set<UUID> = []

    init() {}

    var hasActiveJobs: Bool { jobs.contains { !$0.phase.isFinished } }

    func importVideos(_ urls: [URL], services: AppServices) {
        guard !urls.isEmpty else { return }
        for url in urls {
            let job = Job(id: UUID(), fileName: url.lastPathComponent, phase: .waiting)
            jobs.append(job)
            queue.append((job.id, url))
        }
        guard !isRunning else { return }
        isRunning = true
        Task {
            while !self.queue.isEmpty {
                let next = self.queue.removeFirst()
                await self.run(jobID: next.jobID, url: next.url, services: services)
            }
            self.isRunning = false
        }
    }

    func dismiss(_ jobID: UUID) {
        jobs.removeAll { $0.id == jobID }
    }

    /// Lets "Clear thumbnails" regenerate them on the next visit.
    func resetRepairAttempts() {
        repairAttempts.removeAll()
    }

    // MARK: Pipeline

    private func run(jobID: UUID, url: URL, services: AppServices) async {
        let name = url.lastPathComponent
        guard ImportPaths.isImportableVideo(url) else {
            ImportPaths.discardInboxCopy(url)
            setPhase(jobID, .failed("“\(name)” is not a video file Sable can play."))
            return
        }
        setPhase(jobID, .importing)

        let copy = !ImportPaths.isPrivateCopy(url)
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        if copy, let message = Self.spaceProblem(copying: url, into: services.library.root) {
            setPhase(jobID, .failed(message))
            return
        }

        let mediaDirectory = services.library.mediaDirectory
        let transferred: LibraryStore.TransferredFile
        do {
            transferred = try await Task.detached(priority: .userInitiated) {
                try LibraryStore.transferFile(from: url, toDirectory: mediaDirectory, copy: copy)
            }.value
        } catch {
            ImportPaths.discardInboxCopy(url)
            setPhase(jobID, .failed(Self.message(for: error)))
            return
        }

        let item: MediaItem
        do {
            item = try services.library.registerImportedVideo(transferred, originalFileName: name)
        } catch {
            setPhase(jobID, .failed(Self.message(for: error)))
            return
        }
        repairAttempts.insert(item.id)
        if let index = jobs.firstIndex(where: { $0.id == jobID }) { jobs[index].itemID = item.id }
        services.libraryDidChange()

        setPhase(jobID, .reading)
        let probe = await services.probe.probe(url: services.library.mediaURL(for: item))
        var warning: String?
        if let issue = probe.issue, !issue.isEmpty {
            warning = "\(issue) The file was kept: the VLC engine may still play it."
        }
        if let duration = probe.duration, duration.isFinite, duration > 0, var current = services.library.item(id: item.id) {
            current.duration = duration
            do {
                try services.library.update(current)
            } catch {
                warning = Self.message(for: error)
            }
            services.libraryDidChange()
        }

        setPhase(jobID, .thumbnail)
        if let current = services.library.item(id: item.id) {
            await storeThumbnail(for: current, services: services)
        }

        if let warning {
            setPhase(jobID, .warning(warning))
        } else {
            setPhase(jobID, .done)
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                self.dismiss(jobID)
            }
        }
    }

    /// Fills in a missing duration and thumbnail once per session (items imported before the
    /// probe/thumbnail services could read them, or after "Clear thumbnails").
    func repairMetadataIfNeeded(for item: MediaItem, services: AppServices) async {
        guard item.duration == nil || item.thumbnailFileName == nil else { return }
        guard !repairAttempts.contains(item.id) else { return }
        repairAttempts.insert(item.id)
        let url = services.library.mediaURL(for: item)
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        if item.duration == nil {
            let probe = await services.probe.probe(url: url)
            if let duration = probe.duration, duration.isFinite, duration > 0, var current = services.library.item(id: item.id) {
                current.duration = duration
                try? services.library.update(current)
                services.libraryDidChange()
            }
        }
        if let current = services.library.item(id: item.id), current.thumbnailFileName == nil {
            await storeThumbnail(for: current, services: services)
        }
    }

    private func storeThumbnail(for item: MediaItem, services: AppServices) async {
        guard let fileName = await services.thumbnails.generateThumbnail(for: item) else { return }
        guard var latest = services.library.item(id: item.id) else {
            // Removed while the thumbnail was being made.
            try? FileManager.default.removeItem(at: services.library.thumbnailsDirectory.appendingPathComponent(fileName))
            return
        }
        guard latest.thumbnailFileName != fileName else {
            services.libraryDidChange()
            return
        }
        latest.thumbnailFileName = fileName
        try? services.library.update(latest)
        services.libraryDidChange()
    }

    private func setPhase(_ jobID: UUID, _ phase: Phase) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        jobs[index].phase = phase
    }

    // MARK: Errors

    static func message(for error: Error) -> String {
        if let libraryError = error as? LibraryError {
            return libraryError.errorDescription ?? "The file could not be imported."
        }
        if LibraryError.isOutOfSpace(error) {
            return LibraryError.outOfSpace.errorDescription ?? "Not enough free space."
        }
        return "The file could not be imported: \(error.localizedDescription)"
    }

    /// A readable message when copying `url` would not fit on the device.
    private static func spaceProblem(copying url: URL, into root: URL) -> String? {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 0,
              let available = (try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                .volumeAvailableCapacityForImportantUsage
        else { return nil }
        guard Int64(size) > available else { return nil }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return "Not enough free space: this video needs \(formatter.string(fromByteCount: Int64(size))), "
            + "but only \(formatter.string(fromByteCount: max(0, available))) is free."
    }
}
