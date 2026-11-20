import Foundation

// MARK: - Language

/// BCP-47-ish language code ("en", "ar", "fr", "pt-BR"). Matroska/ISO-639-2 codes ("eng", "ara")
/// are normalised with `LanguageCode.normalized(_:)`.
public struct LanguageCode: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ value: String) { self.rawValue = value }

    public static let english = LanguageCode("en")
    public static let arabic = LanguageCode("ar")

    public var description: String { rawValue }

    /// Primary subtag, lowercased ("pt-BR" -> "pt").
    public var primary: String {
        rawValue.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map { String($0).lowercased() } ?? rawValue.lowercased()
    }

    public var isRightToLeft: Bool {
        ["ar", "he", "fa", "ur", "ps", "sd", "ug", "yi", "dv", "ku"].contains(primary)
    }

    /// English display name for UI ("English", "Arabic"); falls back to the raw code.
    public var displayName: String {
        let names: [String: String] = [
            "en": "English", "ar": "Arabic", "fr": "French", "es": "Spanish", "de": "German",
            "it": "Italian", "pt": "Portuguese", "ru": "Russian", "ja": "Japanese", "ko": "Korean",
            "zh": "Chinese", "tr": "Turkish", "he": "Hebrew", "fa": "Persian", "ur": "Urdu",
            "hi": "Hindi", "nl": "Dutch", "sv": "Swedish", "pl": "Polish", "id": "Indonesian",
        ]
        return names[primary] ?? rawValue
    }

    /// Normalises ISO-639-2/B/T three-letter codes and common variants to a two-letter primary code.
    /// Returns nil for "und", "zxx", empty and unknown placeholders.
    public static func normalized(_ value: String?) -> LanguageCode? {
        guard var v = value?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return nil }
        v = v.lowercased()
        if ["und", "zxx", "mis", "mul", "unknown"].contains(v) { return nil }
        let map: [String: String] = [
            "eng": "en", "ara": "ar", "fre": "fr", "fra": "fr", "spa": "es", "ger": "de", "deu": "de",
            "ita": "it", "por": "pt", "rus": "ru", "jpn": "ja", "kor": "ko", "chi": "zh", "zho": "zh",
            "tur": "tr", "heb": "he", "per": "fa", "fas": "fa", "urd": "ur", "hin": "hi", "dut": "nl",
            "nld": "nl", "swe": "sv", "pol": "pl", "ind": "id",
        ]
        if let two = map[v] { return LanguageCode(two) }
        return LanguageCode(v)
    }
}

// MARK: - Cues and documents

/// Positioning/formatting hints carried alongside a cue. Rendering is best-effort (see docs/SUBTITLES.md).
public struct CueStyleHint: Codable, Hashable, Sendable {
    /// Numpad alignment (1...9, ASS `\anN` semantics). 2 = bottom-centre (default).
    public var alignment: Int?
    /// ASS/SSA style name the cue referenced.
    public var styleName: String?
    public var italic: Bool
    public var bold: Bool

    public init(alignment: Int? = nil, styleName: String? = nil, italic: Bool = false, bold: Bool = false) {
        self.alignment = alignment
        self.styleName = styleName
        self.italic = italic
        self.bold = bold
    }
}

/// One subtitle cue. `start`/`end` are the ORIGINAL timestamps from the source and are never
/// mutated by offsets or sync; timing corrections live in `SubtitleTiming` and are applied at
/// display/export time.
public struct SubtitleCue: Codable, Hashable, Sendable, Identifiable {
    /// Stable identifier preserved through translation (SRT counter if present, else "c<index>").
    public var id: String
    /// Position in the document (0-based, dialogue order).
    public var index: Int
    public var start: TimeInterval
    public var end: TimeInterval
    /// Display text. Plain Unicode with "\n" line breaks; may contain the inline tags
    /// <i> <b> <u> (and their closers). Format-specific markup (ASS override blocks, VTT
    /// voice/class spans, <font>) is removed here and kept in `rawText`.
    public var text: String
    /// Original markup as it appeared in the source, for formats that carry more than `text`.
    public var rawText: String?
    public var style: CueStyleHint?

    public init(id: String, index: Int, start: TimeInterval, end: TimeInterval, text: String,
                rawText: String? = nil, style: CueStyleHint? = nil) {
        self.id = id
        self.index = index
        self.start = start
        self.end = end
        self.text = text
        self.rawText = rawText
        self.style = style
    }

    public var duration: TimeInterval { max(0, end - start) }

    /// `text` with inline tags removed.
    public var plainText: String {
        text.replacingOccurrences(of: "</?[ibuIBU]>", with: "", options: .regularExpression)
    }
}

public enum SubtitleFormat: String, Codable, Hashable, Sendable, CaseIterable {
    case srt, webvtt, ass, ssa, tx3g, unknown

    public var displayName: String {
        switch self {
        case .srt: return "SRT"
        case .webvtt: return "WebVTT"
        case .ass: return "ASS"
        case .ssa: return "SSA"
        case .tx3g: return "MP4 Timed Text"
        case .unknown: return "Text"
        }
    }

    public static func fromFileExtension(_ ext: String) -> SubtitleFormat? {
        switch ext.lowercased() {
        case "srt": return .srt
        case "vtt", "webvtt": return .webvtt
        case "ass": return .ass
        case "ssa": return .ssa
        default: return nil
        }
    }
}

public struct SubtitleDocument: Codable, Hashable, Sendable {
    public var format: SubtitleFormat
    /// Sorted by (start, index). `index` values are 0..<count in this order.
    public var cues: [SubtitleCue]
    public var language: LanguageCode?
    public var title: String?
    /// Preserved ASS/SSA header ([Script Info] + styles) for formats that have one.
    public var header: String?

    public init(format: SubtitleFormat, cues: [SubtitleCue], language: LanguageCode? = nil,
                title: String? = nil, header: String? = nil) {
        self.format = format
        self.cues = cues
        self.language = language
        self.title = title
        self.header = header
    }

    /// Returns a copy with cues sorted by (start, original index) and re-indexed 0..<n.
    public func normalized() -> SubtitleDocument {
        var copy = self
        copy.cues = cues.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.start != rhs.element.start { return lhs.element.start < rhs.element.start }
                return lhs.offset < rhs.offset
            }
            .enumerated()
            .map { newIndex, pair in
                var cue = pair.element
                cue.index = newIndex
                return cue
            }
        return copy
    }
}

// MARK: - Tracks

public enum SubtitleTrackKind: String, Codable, Hashable, Sendable {
    /// Text-based (SRT/ASS/VTT/tx3g): selectable, renderable by Sable, translatable.
    case text
    /// Bitmap-based (PGS, VobSub, DVB): cannot be read as text without OCR. Never offered for
    /// translation or guided sync; may be rendered by the VLC engine natively.
    case image
}

public enum ContainerKind: String, Codable, Hashable, Sendable {
    case matroska, mp4, other
}

public enum SubtitleTrackOrigin: Codable, Hashable, Sendable {
    /// A subtitle file imported by the user and stored in the library.
    case external(fileName: String)
    /// A track inside the video container. `streamID` is the Matroska TrackNumber or MP4 track ID.
    case embedded(container: ContainerKind, streamID: Int, codecID: String)
    /// A machine translation produced by Sable from `sourceTrackID`.
    case translated(sourceTrackID: String, providerID: String, modelID: String?)
}

public struct SubtitleTrackDescriptor: Codable, Hashable, Sendable, Identifiable {
    /// Stable ID. Conventions:
    ///   external:   "ext:<uuid>"
    ///   embedded:   "emb:mkv:<trackNumber>" / "emb:mp4:<trackID>"
    ///   translated: "tr:<target language>:<sourceTrackID>"
    public var id: String
    public var title: String
    public var language: LanguageCode?
    public var format: SubtitleFormat
    public var kind: SubtitleTrackKind
    public var origin: SubtitleTrackOrigin
    public var isDefault: Bool
    public var isForced: Bool

    public init(id: String, title: String, language: LanguageCode?, format: SubtitleFormat,
                kind: SubtitleTrackKind, origin: SubtitleTrackOrigin, isDefault: Bool = false, isForced: Bool = false) {
        self.id = id
        self.title = title
        self.language = language
        self.format = format
        self.kind = kind
        self.origin = origin
        self.isDefault = isDefault
        self.isForced = isForced
    }

    /// Timing is shared between a source track and its translations (same original timestamps),
    /// so an offset tuned on English also applies to its Arabic translation and vice versa.
    public var timingGroupID: String {
        if case let .translated(sourceTrackID, _, _) = origin { return sourceTrackID }
        return id
    }

    public var isTranslatable: Bool { kind == .text }

    public static func embeddedID(container: ContainerKind, streamID: Int) -> String {
        switch container {
        case .matroska: return "emb:mkv:\(streamID)"
        case .mp4: return "emb:mp4:\(streamID)"
        case .other: return "emb:other:\(streamID)"
        }
    }

    public static func translatedID(target: LanguageCode, sourceTrackID: String) -> String {
        "tr:\(target.rawValue):\(sourceTrackID)"
    }
}
