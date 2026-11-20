import Foundation
import SubtitleKit

// OWNER: library agent (except TimingStore.swift, owned by the sync agent).

public struct ExternalSubtitleRef: Codable, Hashable, Sendable, Identifiable {
    /// Track id, "ext:<uuid>".
    public var id: String
    /// File name inside the library's subtitles directory.
    public var fileName: String
    public var displayName: String
    public var language: LanguageCode?
    public var format: SubtitleFormat
    public var addedAt: Date

    public init(id: String, fileName: String, displayName: String, language: LanguageCode?, format: SubtitleFormat, addedAt: Date) {
        self.id = id; self.fileName = fileName; self.displayName = displayName
        self.language = language; self.format = format; self.addedAt = addedAt
    }
}

public struct TranslatedSubtitleRef: Codable, Hashable, Sendable, Identifiable {
    /// Track id, `SubtitleTrackDescriptor.translatedID(target:sourceTrackID:)`.
    public var id: String
    public var sourceTrackID: String
    public var language: LanguageCode
    public var providerID: String
    public var modelID: String?
    /// JSON-encoded `SubtitleDocument` inside the library's subtitles directory.
    public var fileName: String
    public var createdAt: Date

    public init(id: String, sourceTrackID: String, language: LanguageCode, providerID: String, modelID: String?, fileName: String, createdAt: Date) {
        self.id = id; self.sourceTrackID = sourceTrackID; self.language = language
        self.providerID = providerID; self.modelID = modelID; self.fileName = fileName; self.createdAt = createdAt
    }
}

public enum SubtitleBackground: String, Codable, Hashable, Sendable, CaseIterable {
    case outline, shadow, box
}

public enum SubtitleFontChoice: String, Codable, Hashable, Sendable, CaseIterable {
    /// IBM Plex Sans Arabic (covers Latin + Arabic) — default, most readable.
    case plex
    /// San Francisco system font (Arabic falls back to the system Arabic face).
    case system
    /// Pixelify Sans for Latin text. Arabic text ALWAYS uses Plex for correct shaping.
    case pixel
}

public struct SubtitleStyle: Codable, Hashable, Sendable {
    /// Multiplier on the base subtitle size (0.6...2.0).
    public var scale: Double
    /// Distance from the bottom edge as a fraction of the video height (0...0.4).
    public var bottomMargin: Double
    public var background: SubtitleBackground
    public var font: SubtitleFontChoice
    /// When a translation is shown, also show the source line in smaller type underneath.
    public var showOriginalUnderTranslation: Bool

    public init(scale: Double = 1, bottomMargin: Double = 0.06, background: SubtitleBackground = .outline,
                font: SubtitleFontChoice = .plex, showOriginalUnderTranslation: Bool = false) {
        self.scale = scale; self.bottomMargin = bottomMargin; self.background = background
        self.font = font; self.showOriginalUnderTranslation = showOriginalUnderTranslation
    }

    public static let `default` = SubtitleStyle()
}

public enum AspectMode: String, Codable, Hashable, Sendable, CaseIterable {
    case fit, fill, stretch, ratio16x9, ratio4x3, ratio21x9

    public var label: String {
        switch self {
        case .fit: return "Fit"
        case .fill: return "Fill"
        case .stretch: return "Stretch"
        case .ratio16x9: return "16:9"
        case .ratio4x3: return "4:3"
        case .ratio21x9: return "21:9"
        }
    }
}

/// Everything remembered per video.
public struct PlaybackMemory: Codable, Hashable, Sendable {
    public var position: TimeInterval
    public var completed: Bool
    public var rate: Float
    public var audioTrackID: String?
    /// nil = subtitles off.
    public var subtitleTrackID: String?
    public var aspectMode: AspectMode
    /// Per-video subtitle style override; nil = app default from settings.
    public var subtitleStyle: SubtitleStyle?

    public init(position: TimeInterval = 0, completed: Bool = false, rate: Float = 1, audioTrackID: String? = nil,
                subtitleTrackID: String? = nil, aspectMode: AspectMode = .fit, subtitleStyle: SubtitleStyle? = nil) {
        self.position = position; self.completed = completed; self.rate = rate; self.audioTrackID = audioTrackID
        self.subtitleTrackID = subtitleTrackID; self.aspectMode = aspectMode; self.subtitleStyle = subtitleStyle
    }
}

public struct MediaItem: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    /// File name inside the library's media directory.
    public var fileName: String
    public var fileSize: Int64
    public var duration: TimeInterval?
    public var addedAt: Date
    public var lastPlayedAt: Date?
    /// File name inside the library's thumbnails directory.
    public var thumbnailFileName: String?
    public var externalSubtitles: [ExternalSubtitleRef]
    public var translatedSubtitles: [TranslatedSubtitleRef]
    public var playback: PlaybackMemory

    public init(id: UUID = UUID(), title: String, fileName: String, fileSize: Int64, duration: TimeInterval? = nil,
                addedAt: Date = Date(), lastPlayedAt: Date? = nil, thumbnailFileName: String? = nil,
                externalSubtitles: [ExternalSubtitleRef] = [], translatedSubtitles: [TranslatedSubtitleRef] = [],
                playback: PlaybackMemory = PlaybackMemory()) {
        self.id = id; self.title = title; self.fileName = fileName; self.fileSize = fileSize; self.duration = duration
        self.addedAt = addedAt; self.lastPlayedAt = lastPlayedAt; self.thumbnailFileName = thumbnailFileName
        self.externalSubtitles = externalSubtitles; self.translatedSubtitles = translatedSubtitles; self.playback = playback
    }

    public var fileExtension: String { (fileName as NSString).pathExtension.lowercased() }

    /// 0...1 watched fraction for the library progress bar (1 when completed).
    public var progressFraction: Double {
        if playback.completed { return 1 }
        guard let d = duration, d > 0 else { return 0 }
        return min(1, max(0, playback.position / d))
    }
}

public enum LibrarySort: String, Codable, Hashable, Sendable, CaseIterable {
    case recentlyAdded, recentlyPlayed, title, duration, size

    public var label: String {
        switch self {
        case .recentlyAdded: return "Recently added"
        case .recentlyPlayed: return "Recently played"
        case .title: return "Title"
        case .duration: return "Duration"
        case .size: return "File size"
        }
    }
}

public enum LibraryQuery {
    /// Case/diacritic-insensitive title search, then sort. Stable for equal keys.
    public static func apply(_ items: [MediaItem], search: String, sort: LibrarySort) -> [MediaItem] { items }
}
