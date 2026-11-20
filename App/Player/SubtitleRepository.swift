import Foundation
import SubtitleKit
import LibraryKit

// OWNER: playback agent.
@MainActor
final class SubtitleRepository {
    let library: LibraryStore
    let probe: MediaProbeService

    private var probeCache: [UUID: MediaProbeResult] = [:]
    private var memoryCache: [String: SubtitleDocument] = [:]
    private var memoryOrder: [String] = []
    private let memoryLimit = 12
    private var matroskaJobs: [UUID: ExtractionJob] = [:]

    init(library: LibraryStore, probe: MediaProbeService) {
        self.library = library
        self.probe = probe
    }

    // MARK: Probe cache

    /// The probe result for an item (probed once per launch; failed probes are not cached).
    func probeResult(for item: MediaItem) async -> MediaProbeResult {
        if let cached = probeCache[item.id] { return cached }
        let result = await probe.probe(url: library.mediaURL(for: item))
        if result.issue == nil { probeCache[item.id] = result }
        return result
    }

    /// Lets the player share the probe it already ran.
    func storeProbe(_ result: MediaProbeResult, for itemID: UUID) {
        if result.issue == nil { probeCache[itemID] = result }
    }

    func cachedProbe(for itemID: UUID) -> MediaProbeResult? { probeCache[itemID] }

    /// Drops everything cached in memory for an item (e.g. after it was removed).
    func forget(itemID: UUID) {
        probeCache[itemID] = nil
        let prefix = itemID.uuidString + "|"
        memoryOrder.removeAll { $0.hasPrefix(prefix) }
        memoryCache = memoryCache.filter { !$0.key.hasPrefix(prefix) }
    }

    // MARK: Tracks

    /// Embedded (probed; cached per item) + external + translated tracks, embedded first.
    func tracks(for item: MediaItem) async -> [SubtitleTrackDescriptor] {
        let embedded = await probeResult(for: item).subtitleTracks
        var tracks = embedded
        tracks += item.externalSubtitles.sorted { $0.addedAt < $1.addedAt }.map(Self.descriptor(for:))
        let sources = tracks
        let translations = item.translatedSubtitles.sorted { $0.createdAt < $1.createdAt }
        var perLanguage: [String: Int] = [:]
        for ref in translations { perLanguage[ref.language.primary, default: 0] += 1 }
        for ref in translations {
            let source = sources.first { $0.id == ref.sourceTrackID }
            var title = "\(ref.language.displayName) (translated)"
            if (perLanguage[ref.language.primary] ?? 0) > 1, let source { title += " · from \(source.title)" }
            tracks.append(SubtitleTrackDescriptor(
                id: ref.id,
                title: title,
                language: ref.language,
                format: source?.format ?? .srt,
                kind: .text,
                origin: .translated(sourceTrackID: ref.sourceTrackID, providerID: ref.providerID, modelID: ref.modelID)))
        }
        return tracks
    }

    nonisolated static func descriptor(for ref: ExternalSubtitleRef) -> SubtitleTrackDescriptor {
        SubtitleTrackDescriptor(id: ref.id, title: ref.displayName, language: ref.language, format: ref.format,
                                kind: .text, origin: .external(fileName: ref.fileName))
    }

    // MARK: Documents

    /// Loads a text track's document. Embedded tracks are extracted once (progress 0...1) and
    /// cached under Extracted/<itemID>/. Throws for image-based tracks.
    func document(for track: SubtitleTrackDescriptor, item: MediaItem,
                  progress: ((Double) -> Void)? = nil) async throws -> SubtitleDocument {
        guard track.kind == .text else {
            throw PlayerError("“\(track.title)” is an image-based subtitle track (\(Self.imageCodecLabel(track))). Sable can't read it as text, so it can't be translated or synced; the VLC engine can still display it.")
        }
        switch track.origin {
        case let .external(fileName):
            return try await externalDocument(track: track, item: item, fileName: fileName)
        case let .translated(sourceTrackID, _, _):
            return try translatedDocument(track: track, item: item, sourceTrackID: sourceTrackID)
        case let .embedded(container, streamID, _):
            return try await embeddedDocument(track: track, item: item, container: container,
                                              streamID: streamID, progress: progress)
        }
    }

    nonisolated static func imageCodecLabel(_ track: SubtitleTrackDescriptor) -> String {
        if case let .embedded(_, _, codecID) = track.origin {
            return MediaProbeService.codecLabel(forCodecID: codecID)
        }
        return "bitmap"
    }

    private func externalDocument(track: SubtitleTrackDescriptor, item: MediaItem, fileName: String) async throws -> SubtitleDocument {
        let key = "\(item.id.uuidString)|\(track.id)|\(fileName)"
        if let cached = memoryCache[key] { return cached }
        let url = library.subtitlesDirectory.appendingPathComponent(fileName)
        let language = track.language
        let title = track.title
        let document = try await Task.detached(priority: .userInitiated) { () throws -> SubtitleDocument in
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                throw PlayerError("The subtitle file “\(title)” can't be read. It may have been removed.")
            }
            var document = try SubtitleParser.parse(data: data, fileExtension: url.pathExtension)
            if document.language == nil { document.language = language }
            if document.title == nil { document.title = title }
            return document
        }.value
        remember(document, key: key)
        return document
    }

    private func translatedDocument(track: SubtitleTrackDescriptor, item: MediaItem, sourceTrackID: String) throws -> SubtitleDocument {
        let refs = item.translatedSubtitles + (library.item(id: item.id)?.translatedSubtitles ?? [])
        guard let ref = refs.first(where: { $0.id == track.id }) else {
            throw PlayerError("This translation is no longer available.")
        }
        let key = "\(item.id.uuidString)|\(track.id)|\(ref.fileName)|\(ref.createdAt.timeIntervalSince1970)"
        if let cached = memoryCache[key] { return cached }
        var document = try library.loadTranslation(ref)
        if document.language == nil { document.language = ref.language }
        remember(document, key: key)
        return document
    }

    private func embeddedDocument(track: SubtitleTrackDescriptor, item: MediaItem, container: ContainerKind,
                                  streamID: Int, progress: ((Double) -> Void)?) async throws -> SubtitleDocument {
        let key = "\(item.id.uuidString)|\(track.id)"
        if let cached = memoryCache[key] { return cached }
        let cacheURL = extractionDirectory(for: item.id).appendingPathComponent(Self.cacheFileName(for: track.id))
        if let cached = await Task.detached(priority: .userInitiated, operation: { Self.readCache(cacheURL) }).value {
            remember(cached, key: key)
            return cached
        }

        var document: SubtitleDocument
        switch container {
        case .matroska:
            document = try await extractMatroska(item: item, requested: streamID, progress: progress)
        case .mp4:
            document = try await extractMP4(item: item, track: track, streamID: streamID, cacheURL: cacheURL, progress: progress)
        case .other:
            throw PlayerError("Sable can't read embedded subtitles from this kind of file.")
        }
        if document.language == nil { document.language = track.language }
        if document.title == nil { document.title = track.title }
        remember(document, key: key)
        return document
    }

    // MARK: Extraction

    func extractionDirectory(for itemID: UUID) -> URL {
        library.extractedDirectory.appendingPathComponent(itemID.uuidString, isDirectory: true)
    }

    /// "emb:mkv:3" -> "emb_mkv_3.json".
    nonisolated static func cacheFileName(for trackID: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        let sanitized = String(trackID.map { allowed.contains($0) ? $0 : "_" })
        return sanitized + ".json"
    }

    nonisolated static func readCache(_ url: URL) -> SubtitleDocument? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let document = try? JSONDecoder().decode(SubtitleDocument.self, from: data), !document.cues.isEmpty else {
            try? FileManager.default.removeItem(at: url) // corrupt or empty cache entry
            return nil
        }
        return document
    }

    nonisolated static func writeCache(_ document: SubtitleDocument, to url: URL) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(document)
            try data.write(to: url, options: .atomic)
        } catch {
            playbackLog.error("Couldn't cache extracted subtitles: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Extracts every text track of the file in one pass over its clusters (the expensive part)
    /// and caches all of them, so switching to another embedded track afterwards is instant.
    /// Concurrent requests for the same file share one extraction.
    private func extractMatroska(item: MediaItem, requested: Int, progress: ((Double) -> Void)?) async throws -> SubtitleDocument {
        let job: ExtractionJob
        // A job whose waiters all gave up is cancelled but stays registered until they return;
        // joining it would fail this request with a spurious cancellation, so start afresh.
        if let running = matroskaJobs[item.id], running.trackNumbers.contains(requested), running.task?.isCancelled == false {
            job = running
        } else {
            var numbers: Set<Int> = [requested]
            for descriptor in probeCache[item.id]?.subtitleTracks ?? [] where descriptor.kind == .text {
                if case let .embedded(.matroska, number, _) = descriptor.origin { numbers.insert(number) }
            }
            job = startMatroskaJob(url: library.mediaURL(for: item), directory: extractionDirectory(for: item.id),
                                   numbers: numbers)
            matroskaJobs[item.id] = job
        }

        let token = UUID()
        if let progress { job.listeners[token] = progress }
        job.waiters += 1
        defer {
            job.listeners[token] = nil
            job.waiters -= 1
            if job.waiters == 0, matroskaJobs[item.id] === job { matroskaJobs[item.id] = nil }
        }
        guard let task = job.task else { throw SubtitleError.cancelled }
        let documents = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            Task { @MainActor in job.waiterCancelled() }
        }
        guard let document = documents[requested], !document.cues.isEmpty else {
            throw PlayerError("This subtitle track contains no text lines.")
        }
        return document
    }

    private func startMatroskaJob(url: URL, directory: URL, numbers: Set<Int>) -> ExtractionJob {
        let job = ExtractionJob(trackNumbers: numbers)
        let relay: @Sendable (Double) -> Void = { fraction in
            Task { @MainActor in job.report(fraction) }
        }
        job.task = Task.detached(priority: .userInitiated) {
            let reader = try MatroskaReader(url: url)
            let documents = try reader.extractTextSubtitles(trackNumbers: numbers, progress: relay,
                                                            isCancelled: { Task.isCancelled })
            for (number, document) in documents where !document.cues.isEmpty {
                let trackID = SubtitleTrackDescriptor.embeddedID(container: .matroska, streamID: number)
                Self.writeCache(document, to: directory.appendingPathComponent(Self.cacheFileName(for: trackID)))
            }
            return documents
        }
        return job
    }

    private func extractMP4(item: MediaItem, track: SubtitleTrackDescriptor, streamID: Int, cacheURL: URL,
                            progress: ((Double) -> Void)?) async throws -> SubtitleDocument {
        let url = library.mediaURL(for: item)
        let format = track.format
        let language = track.language
        let title = track.title
        let job = ExtractionJob(trackNumbers: [streamID])
        if let progress { job.listeners[UUID()] = progress }
        let relay: @Sendable (Double) -> Void = { fraction in
            Task { @MainActor in job.report(fraction) }
        }
        let task = Task.detached(priority: .userInitiated) { () async throws -> SubtitleDocument in
            let document = try await MP4TextExtractor.extract(url: url, trackID: streamID, format: format,
                                                              language: language, title: title,
                                                              progress: relay, isCancelled: { Task.isCancelled })
            Self.writeCache(document, to: cacheURL)
            return document
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func remember(_ document: SubtitleDocument, key: String) {
        memoryCache[key] = document
        memoryOrder.removeAll { $0 == key }
        memoryOrder.append(key)
        while memoryOrder.count > memoryLimit {
            let evicted = memoryOrder.removeFirst()
            memoryCache[evicted] = nil
        }
    }
}

/// One background extraction shared by every caller waiting for it.
@MainActor
private final class ExtractionJob {
    let trackNumbers: Set<Int>
    var task: Task<[Int: SubtitleDocument], Error>?
    var listeners: [UUID: (Double) -> Void] = [:]
    var waiters = 0
    private var cancelledWaiters = 0
    private var lastReported = -1.0

    init(trackNumbers: Set<Int>) {
        self.trackNumbers = trackNumbers
    }

    func report(_ fraction: Double) {
        guard fraction >= 1 || fraction - lastReported >= 0.01 else { return }
        lastReported = fraction
        for listener in listeners.values { listener(fraction) }
    }

    /// Cancels the extraction once every waiter has given up on it.
    func waiterCancelled() {
        cancelledWaiters += 1
        if cancelledWaiters >= waiters { task?.cancel() }
    }
}
