import Foundation

// OWNER: subtitles-core agent. Signatures are the contract; bodies are stubs to replace.

public enum SubtitleError: Error, Equatable, Sendable, LocalizedError {
    case unreadableEncoding
    case unsupportedFormat(String)
    case empty
    case malformed(String)
    case notImplemented(String)
    case io(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .unreadableEncoding: return "The subtitle file's text encoding could not be read."
        case let .unsupportedFormat(f): return "Unsupported subtitle format: \(f)."
        case .empty: return "The subtitle file contains no cues."
        case let .malformed(m): return "The subtitle file is malformed: \(m)"
        case let .notImplemented(m): return "Not implemented: \(m)"
        case let .io(m): return "Could not read the file: \(m)"
        case .cancelled: return "Cancelled."
        }
    }
}

public enum SubtitleParser {
    /// Decodes bytes (UTF-8 with/without BOM, UTF-16 LE/BE with BOM, then Windows-1256/1252 and
    /// ISO-8859-1 fallbacks), detects the format from `fileExtension` or by sniffing, and parses.
    /// The result is `normalized()` (sorted, re-indexed). Throws `.empty` when no cue survives.
    public static func parse(data: Data, fileExtension: String?) throws -> SubtitleDocument {
        throw SubtitleError.notImplemented("SubtitleParser.parse(data:)")
    }

    /// Parses already-decoded text in a known format.
    public static func parse(string: String, format: SubtitleFormat) throws -> SubtitleDocument {
        throw SubtitleError.notImplemented("SubtitleParser.parse(string:)")
    }

    /// Best-effort format sniffing from content ("WEBVTT" header, "[Script Info]", SRT arrows).
    public static func sniffFormat(_ text: String) -> SubtitleFormat? { nil }

    /// Decodes subtitle bytes to a String using the fallback chain described above.
    public static func decodeText(_ data: Data) throws -> String {
        throw SubtitleError.notImplemented("SubtitleParser.decodeText")
    }
}
