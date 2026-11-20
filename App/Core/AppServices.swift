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

    /// Bumped whenever library contents change so list views refresh.
    var libraryRevision = 0
    /// Item currently open in the full-screen player (nil = library).
    var playingItemID: UUID?
    /// User-visible error banner.
    var banner: String?

    init(root: URL) throws {
        library = try LibraryStore(root: root)
        timing = TimingStore(fileURL: library.timingFileURL)
        settings = AppSettings()
        keychain = KeychainStore(service: "com.murisixz.sable")
        probe = MediaProbeService()
        thumbnails = ThumbnailService(library: library)
        subtitles = SubtitleRepository(library: library, probe: probe)
        translation = TranslationService(library: library, settings: settings, keychain: keychain)
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
            // swiftlint:disable:next force_try
            let services = try! AppServices(root: temp)
            services.banner = "Your library could not be opened (\(error.localizedDescription)). Using a temporary library."
            return services
        }
    }

    func libraryDidChange() { libraryRevision &+= 1 }
}
