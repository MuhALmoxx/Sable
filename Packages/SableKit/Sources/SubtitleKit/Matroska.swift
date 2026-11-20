import Foundation

// OWNER: subtitles-core agent.
// Pure-Swift Matroska/WebM (EBML) reader for listing tracks and extracting TEXT subtitle tracks.

public struct MatroskaTrackInfo: Hashable, Sendable {
    public enum TrackType: Int, Sendable { case video = 1, audio = 2, complex = 3, logo = 0x10, subtitle = 0x11, buttons = 0x12, control = 0x20, metadata = 0x21, unknown = 0 }
    public var number: Int
    public var uid: UInt64
    public var type: TrackType
    public var codecID: String
    public var language: LanguageCode?
    public var name: String?
    public var isDefault: Bool
    public var isForced: Bool
    public var codecPrivate: Data?

    public init(number: Int, uid: UInt64, type: TrackType, codecID: String, language: LanguageCode?, name: String?,
                isDefault: Bool, isForced: Bool, codecPrivate: Data?) {
        self.number = number; self.uid = uid; self.type = type; self.codecID = codecID; self.language = language
        self.name = name; self.isDefault = isDefault; self.isForced = isForced; self.codecPrivate = codecPrivate
    }

    /// Subtitle kind from the codec ID: S_TEXT/UTF8, S_TEXT/ASS, S_TEXT/SSA, S_TEXT/WEBVTT,
    /// D_WEBVTT/SUBTITLES -> .text; S_HDMV/PGS, S_VOBSUB, S_DVBSUB, S_HDMV/TEXTST(?) -> .image.
    public var subtitleKind: SubtitleTrackKind? { MatroskaCodec.subtitleKind(forCodecID: codecID) }
    public var subtitleFormat: SubtitleFormat { MatroskaCodec.subtitleFormat(forCodecID: codecID) }
}

public enum MatroskaCodec {
    public static func subtitleKind(forCodecID codecID: String) -> SubtitleTrackKind? { nil }
    public static func subtitleFormat(forCodecID codecID: String) -> SubtitleFormat { .unknown }
    /// Human-readable codec label ("SRT", "ASS", "PGS (image)", "VobSub (image)").
    public static func displayName(forCodecID codecID: String) -> String { codecID }
}

/// Reads a Matroska file from disk with seeks (never loads the whole file into memory).
public final class MatroskaReader {
    public let url: URL

    public init(url: URL) throws {
        self.url = url
        throw SubtitleError.notImplemented("MatroskaReader")
    }

    /// Parses EBML header + Segment/Tracks. Fast: stops before the first Cluster when possible.
    public func readTracks() throws -> [MatroskaTrackInfo] { [] }

    /// Scans all Clusters once and extracts every requested TEXT subtitle track into documents,
    /// keyed by track number. Handles SimpleBlock and BlockGroup(+BlockDuration), TimestampScale,
    /// ContentEncoding header-stripping and zlib compression, ASS/SSA "ReadOrder,Layer,Style,…"
    /// block payloads (using CodecPrivate as header), and WebVTT blocks.
    /// `progress` receives 0...1 (by file offset). Throws `SubtitleError.cancelled` when
    /// `isCancelled()` returns true.
    public func extractTextSubtitles(trackNumbers: Set<Int>,
                                     progress: ((Double) -> Void)? = nil,
                                     isCancelled: () -> Bool = { false }) throws -> [Int: SubtitleDocument] {
        [:]
    }
}
