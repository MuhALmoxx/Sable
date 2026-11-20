import Foundation
import Observation
import LibraryKit

// OWNER: library agent (app shell). Add settings here; keep existing names.

/// UserDefaults-backed app preferences.
@Observable
@MainActor
final class AppSettings {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedSeek = defaults.object(forKey: Keys.doubleTap) as? Double ?? 10
        doubleTapSeekSeconds = AppSettings.doubleTapOptions.contains(storedSeek) ? storedSeek : 10
        let storedRate = defaults.object(forKey: Keys.rate) as? Float ?? 1
        defaultRate = AppSettings.rateOptions.contains(storedRate) ? storedRate : 1
        resumePlayback = defaults.object(forKey: Keys.resume) as? Bool ?? true
        if let data = defaults.data(forKey: Keys.style), var style = try? JSONDecoder().decode(SubtitleStyle.self, from: data) {
            style.scale = min(AppSettings.subtitleScaleRange.upperBound, max(AppSettings.subtitleScaleRange.lowerBound, style.scale))
            subtitleStyle = style
        } else {
            subtitleStyle = .default
        }
        translationProviderID = defaults.string(forKey: Keys.provider) ?? "apple-on-device"
        claudeModelID = defaults.string(forKey: Keys.claudeModel) ?? "claude-opus-5-5"
        chatGPTModelID = defaults.string(forKey: Keys.chatGPTModel) ?? ""
        chatGPTPlanNoticeShown = defaults.object(forKey: Keys.chatGPTPlanNotice) as? Bool ?? false
        librarySortRaw = defaults.string(forKey: Keys.sort) ?? LibrarySort.recentlyAdded.rawValue
        preferVLCForAll = defaults.object(forKey: Keys.vlcAll) as? Bool ?? false
        libraryUsesGrid = defaults.object(forKey: Keys.grid) as? Bool ?? false
    }

    /// Seconds jumped by double-tapping the left/right half of the video (and skip buttons).
    var doubleTapSeekSeconds: Double { didSet { defaults.set(doubleTapSeekSeconds, forKey: Keys.doubleTap) } }
    var defaultRate: Float { didSet { defaults.set(defaultRate, forKey: Keys.rate) } }
    var resumePlayback: Bool { didSet { defaults.set(resumePlayback, forKey: Keys.resume) } }
    /// App-wide default subtitle style (per-video overrides live in PlaybackMemory).
    var subtitleStyle: SubtitleStyle {
        didSet { if let data = try? JSONEncoder().encode(subtitleStyle) { defaults.set(data, forKey: Keys.style) } }
    }
    var translationProviderID: String { didSet { defaults.set(translationProviderID, forKey: Keys.provider) } }
    var claudeModelID: String { didSet { defaults.set(claudeModelID, forKey: Keys.claudeModel) } }
    /// ChatGPT plan model slug chosen by the person; empty = the first model the account lists.
    var chatGPTModelID: String { didSet { defaults.set(chatGPTModelID, forKey: Keys.chatGPTModel) } }
    /// The one-time "You're using your ChatGPT plan" notice has been shown.
    var chatGPTPlanNoticeShown: Bool { didSet { defaults.set(chatGPTPlanNoticeShown, forKey: Keys.chatGPTPlanNotice) } }
    var librarySortRaw: String { didSet { defaults.set(librarySortRaw, forKey: Keys.sort) } }
    var librarySort: LibrarySort {
        get { LibrarySort(rawValue: librarySortRaw) ?? .recentlyAdded }
        set { librarySortRaw = newValue.rawValue }
    }
    /// Force the VLC engine even for files AVFoundation can play (disables native PiP).
    var preferVLCForAll: Bool { didSet { defaults.set(preferVLCForAll, forKey: Keys.vlcAll) } }

    /// Library shows a two-column grid instead of the list.
    var libraryUsesGrid: Bool { didSet { defaults.set(libraryUsesGrid, forKey: Keys.grid) } }

    static let doubleTapOptions: [Double] = [5, 10, 15, 30]
    static let rateOptions: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]
    /// Allowed `SubtitleStyle.scale` values (stepped by `subtitleScaleStep` in Settings).
    static let subtitleScaleRange: ClosedRange<Double> = 0.6...2.0
    static let subtitleScaleStep: Double = 0.1

    private enum Keys {
        static let doubleTap = "settings.doubleTapSeek"
        static let rate = "settings.defaultRate"
        static let resume = "settings.resume"
        static let style = "settings.subtitleStyle"
        static let provider = "settings.translationProvider"
        static let claudeModel = "settings.claudeModel"
        static let chatGPTModel = "settings.chatGPTModel"
        static let chatGPTPlanNotice = "settings.chatGPTPlanNoticeShown"
        static let sort = "settings.librarySort"
        static let vlcAll = "settings.preferVLC"
        static let grid = "settings.libraryGrid"
    }
}
