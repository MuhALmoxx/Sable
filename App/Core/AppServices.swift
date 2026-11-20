import SwiftUI
import LibraryKit
import SubtitleKit
import TranslationKit

// OWNER: library agent (app shell). Other agents: do not edit — ask the integrator for changes.

/// Dependency container injected through the SwiftUI environment.
@Observable
@MainActor
final class AppServices {
    let library: LibraryStore
    let timing: TimingStore
    let settings: AppSettings
    let keychain: KeychainStore
    let probe: MediaProbeService
    let thumbnails: ThumbnailService
    let subtitles: SubtitleRepository
    let translation: TranslationService
    /// Video import queue (Files picker, "Open in Sable") and lazy thumbnail/duration repair.
    let imports: ImportCoordinator

    /// Bumped whenever library contents change so list views refresh.
    var libraryRevision = 0
    /// Item currently open in the full-screen player (nil = library).
    var playingItemID: UUID?
    /// User-visible error banner.
    var banner: String?
    /// Subtitle files opened from another app while several videos could own them; the root view
    /// asks which video to attach the first one to.
    var pendingSubtitleFiles: [URL] = []

    init(root: URL) throws {
        library = try LibraryStore(root: root)
        timing = TimingStore(fileURL: library.timingFileURL)
        settings = AppSettings()
        keychain = KeychainStore(service: "com.murisixz.sable")
        probe = MediaProbeService()
        thumbnails = ThumbnailService(library: library)
        subtitles = SubtitleRepository(library: library, probe: probe)
        translation = TranslationService(library: library, settings: settings, keychain: keychain)
        imports = ImportCoordinator()

        if let issue = library.loadIssue {
            banner = issue.message
        } else if library.adoptedOrphanCount > 0 {
            let count = library.adoptedOrphanCount
            banner = count == 1
                ? "Recovered 1 video from an interrupted import."
                : "Recovered \(count) videos from an interrupted import."
        }
    }

    static var defaultRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Sable", isDirectory: true)
    }

    static func bootstrap() -> AppServices {
        #if DEBUG
        UITestSupport.prepareFileSystemIfNeeded(root: defaultRoot)
        #endif
        do {
            let services = try AppServices(root: defaultRoot)
            #if DEBUG
            UITestSupport.configure(services)
            #endif
            return services
        } catch {
            // Fall back to a temporary library so the app still launches and can report the problem.
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("Sable-fallback", isDirectory: true)
            try? FileManager.default.removeItem(at: temp)
            // swiftlint:disable:next force_try
            let services = try! AppServices(root: temp)
            services.banner = "Your library could not be opened (\(error.localizedDescription)). Using a temporary library."
            return services
        }
    }

    func libraryDidChange() { libraryRevision &+= 1 }

    // MARK: Library actions

    /// Removes an item with all its files and its subtitle timing.
    func removeItem(id: UUID) throws {
        try library.remove(itemID: id)
        timing.removeAll(videoID: id)
        subtitles.forget(itemID: id)
        if playingItemID == id { playingItemID = nil }
        libraryDidChange()
    }

    /// Queues videos for import (move when the file is a private copy, copy otherwise).
    func importVideos(_ urls: [URL]) {
        imports.importVideos(urls, services: self)
    }

    /// Attaches subtitle files to a video and reports the outcome in the banner.
    /// Returns the refs that were added.
    @discardableResult
    func attachSubtitles(_ urls: [URL], to itemID: UUID) -> [ExternalSubtitleRef] {
        guard let item = library.item(id: itemID) else {
            banner = LibraryError.itemNotFound.localizedDescription
            return []
        }
        var added: [ExternalSubtitleRef] = []
        var failures: [String] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let ref = try library.attachSubtitle(from: url, to: itemID, copy: !ImportPaths.isPrivateCopy(url))
                added.append(ref)
            } catch {
                failures.append(error.localizedDescription)
                ImportPaths.discardInboxCopy(url)
            }
        }
        if !added.isEmpty { libraryDidChange() }

        if let failure = failures.first, added.isEmpty {
            banner = failures.count == 1 ? failure : "\(failures.count) subtitle files could not be added. \(failure)"
        } else if added.count == 1, let ref = added.first {
            let language = ref.language.map { " (\($0.displayName))" } ?? ""
            let suffix = failures.isEmpty ? "" : " \(failures.count) other file(s) could not be added."
            banner = "Added “\(ref.displayName)”\(language) to \(item.title). Pick it from the subtitles menu while playing.\(suffix)"
        } else if !added.isEmpty {
            let suffix = failures.isEmpty ? "" : " \(failures.count) other file(s) could not be added."
            banner = "Added \(added.count) subtitle files to \(item.title).\(suffix)"
        }
        return added
    }

    // MARK: Files opened from other apps

    /// Entry point for `.onOpenURL`: videos are imported, subtitle files are attached to the
    /// playing video, the only video, or a video the person picks.
    func handleOpenedURL(_ url: URL) {
        guard url.isFileURL else { return }
        switch LibraryFileNaming.kind(ofFileExtension: url.pathExtension) {
        case .subtitle:
            handleOpenedSubtitle(url)
        case .video, .unknown:
            importVideos([url])
        }
    }

    private func handleOpenedSubtitle(_ url: URL) {
        if let playing = playingItemID, library.item(id: playing) != nil {
            attachSubtitles([url], to: playing)
        } else if library.items.isEmpty {
            banner = "Import the video first, then open the subtitle file again."
            ImportPaths.discardInboxCopy(url)
        } else if library.items.count == 1, let only = library.items.first {
            attachSubtitles([url], to: only.id)
        } else {
            pendingSubtitleFiles.append(url)
        }
    }

    /// Attaches a pending subtitle file to `itemID`.
    func attachPendingSubtitle(_ url: URL, to itemID: UUID) {
        guard let index = pendingSubtitleFiles.firstIndex(of: url) else { return }
        pendingSubtitleFiles.remove(at: index)
        attachSubtitles([url], to: itemID)
    }

    /// Drops a pending subtitle file (the person cancelled). No-op if it is no longer pending.
    func cancelPendingSubtitle(_ url: URL) {
        guard let index = pendingSubtitleFiles.firstIndex(of: url) else { return }
        pendingSubtitleFiles.remove(at: index)
        ImportPaths.discardInboxCopy(url)
    }
}
