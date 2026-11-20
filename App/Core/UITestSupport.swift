#if DEBUG
import Foundation
import Security
import UIKit
import LibraryKit
import SubtitleKit

// OWNER: build/QA agent. DEBUG-only hooks driven by launch arguments from UITests:
//   -uiTesting            start from a clean slate (library root, UserDefaults domain, the app's
//                         Keychain items, Documents exports) and disable UIKit animations
//   -seedLibrary          import the bundled fixtures (UITestFixtures/*) into the library
//   -mockTranslation      the translation feature registers a deterministic, offline, clearly
//                         labelled mock provider (reads `useMockTranslation`, optional
//                         `mockTranslationDelay` and `referenceTranslations()` below)
// None of this is compiled into Release builds; the fixtures folder is excluded from Release too.
enum UITestSupport {
    static var arguments: [String] { ProcessInfo.processInfo.arguments }
    static var isUITesting: Bool { arguments.contains("-uiTesting") }
    static var shouldSeedLibrary: Bool { arguments.contains("-seedLibrary") }
    static var useMockTranslation: Bool { arguments.contains("-mockTranslation") }

    /// Seconds the mock translation provider should wait per chunk so UI tests can observe
    /// progress and cancel mid-way. `-mockTranslationDelay <seconds>`; default 0.8 s.
    static var mockTranslationDelay: TimeInterval {
        guard let index = arguments.firstIndex(of: "-mockTranslationDelay"), index + 1 < arguments.count,
              let value = Double(arguments[index + 1]), value >= 0 else { return 0.8 }
        return value
    }

    /// Titles given to the seeded fixture items (UI tests look them up via `AX.Library.item`).
    enum SeedTitles {
        static let mkv = "Night Roof (MKV)"
        static let mp4 = "Night Roof (MP4)"
    }

    /// The bundled fixtures folder (Debug builds only), or nil.
    static var fixturesDirectory: URL? {
        Bundle.main.url(forResource: "UITestFixtures", withExtension: nil)
    }

    /// Human-written Arabic for the fixture dialogue, keyed by the English plain text
    /// (`SubtitleCue.plainText`). Used by the mock translation provider so screenshots show real,
    /// correctly shaped Arabic. Empty when the fixture is missing.
    static func referenceTranslations() -> [String: String] {
        guard let url = fixturesDirectory?.appendingPathComponent("reference-translations.ar.json"),
              let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var result: [String: String] = [:]
        for (key, value) in object where !key.hasPrefix("_") {
            if let text = value as? String { result[key] = text }
        }
        return result
    }

    // MARK: Hooks called by AppServices.bootstrap()

    /// Runs before AppServices is created. With `-uiTesting`: wipes the library root, the app's
    /// UserDefaults domain, the app's Keychain items and exported files, and disables animations.
    @MainActor
    static func prepareFileSystemIfNeeded(root: URL) {
        guard isUITesting else { return }
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: root.path) {
            do {
                try fileManager.removeItem(at: root)
            } catch {
                note("could not wipe the library root: \(error.localizedDescription)")
            }
        }
        if let domain = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: domain)
        }
        // API keys from a previous run must never leak into a test (no paid provider can run).
        let keychainQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.murisixz.sable",
        ]
        SecItemDelete(keychainQuery as CFDictionary)
        // Exports (SRT files) land in Documents; start without stale files.
        if let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first,
           let contents = try? fileManager.contentsOfDirectory(at: documents, includingPropertiesForKeys: nil) {
            for url in contents { try? fileManager.removeItem(at: url) }
        }
        UIView.setAnimationsEnabled(false)
        note("clean launch: library, defaults, keychain and exports reset; animations disabled")
    }

    /// Runs after AppServices is created: seeds the fixtures when `-seedLibrary` is passed.
    @MainActor
    static func configure(_ services: AppServices) {
        if isUITesting {
            // Some code paths re-enable animations; keep them off for the whole UI test run.
            UIView.setAnimationsEnabled(false)
        }
        if shouldSeedLibrary {
            seedLibrary(services)
        }
    }

    // MARK: Seeding

    /// Imports night-roof.mkv and night-roof.mp4 (copies), attaches the 2.5 s-late English SRT to
    /// the MP4, sets the titles, then fills durations and thumbnails in the background. Idempotent:
    /// an item that already exists (same title) is not imported again.
    @MainActor
    static func seedLibrary(_ services: AppServices) {
        guard let fixtures = fixturesDirectory else {
            note("seedLibrary: UITestFixtures folder missing from the bundle")
            services.banner = "UI-test fixtures are missing from this build."
            return
        }
        let library = services.library
        var seededIDs: [UUID] = []

        func existingItem(titled title: String) -> MediaItem? {
            library.items.first { $0.title == title }
        }

        func importFixture(_ fileName: String, title: String) -> MediaItem? {
            if let existing = existingItem(titled: title) { return existing }
            do {
                let imported = try library.importVideo(from: fixtures.appendingPathComponent(fileName), copy: true)
                guard var item = library.item(id: imported.id) else { return imported }
                item.title = title
                try library.update(item)
                return library.item(id: item.id) ?? item
            } catch {
                note("seedLibrary: importing \(fileName) failed: \(error.localizedDescription)")
                return nil
            }
        }

        if let mkv = importFixture("night-roof.mkv", title: SeedTitles.mkv) {
            seededIDs.append(mkv.id)
        }
        if let mp4 = importFixture("night-roof.mp4", title: SeedTitles.mp4) {
            seededIDs.append(mp4.id)
            let current = library.item(id: mp4.id) ?? mp4
            if current.externalSubtitles.isEmpty {
                do {
                    try library.attachSubtitle(from: fixtures.appendingPathComponent("night-roof.late.en.srt"),
                                               to: mp4.id, copy: true)
                } catch {
                    note("seedLibrary: attaching night-roof.late.en.srt failed: \(error.localizedDescription)")
                }
            }
        }
        do {
            try library.save()
        } catch {
            note("seedLibrary: saving the library failed: \(error.localizedDescription)")
        }
        services.libraryDidChange()
        note("seedLibrary: \(seededIDs.count) item(s) ready")

        // Durations + thumbnails (async; the list refreshes again when they are ready).
        let ids = seededIDs
        Task { @MainActor [weak services] in
            for id in ids {
                guard let services, let item = services.library.item(id: id) else { continue }
                let result = await services.probe.probe(url: services.library.mediaURL(for: item))
                if let duration = result.duration, var fresh = services.library.item(id: id) {
                    fresh.duration = duration
                    try? services.library.update(fresh)
                }
                if let fresh = services.library.item(id: id), fresh.thumbnailFileName == nil,
                   let thumbnail = await services.thumbnails.generateThumbnail(for: fresh),
                   var latest = services.library.item(id: id) {
                    latest.thumbnailFileName = thumbnail
                    try? services.library.update(latest)
                }
                services.libraryDidChange()
            }
            try? services?.library.save()
            UITestSupport.note("seedLibrary: durations and thumbnails generated")
        }
    }

    private static func note(_ message: String) {
        NSLog("[Sable UITestSupport] %@", message as NSString)
    }
}
#endif
