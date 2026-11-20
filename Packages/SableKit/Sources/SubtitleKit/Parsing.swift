import Foundation

// OWNER: subtitles-core agent.

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
    ///
    /// A header found in the content wins over a contradicting extension (a ".srt" that starts
    /// with "WEBVTT" is parsed as WebVTT). Unknown extensions (".txt", nil) are sniffed.
    public static func parse(data: Data, fileExtension: String?) throws -> SubtitleDocument {
        let text = try decodeText(data)
        var ext = fileExtension?.trimmingCharacters(in: .whitespaces) ?? ""
        while ext.hasPrefix(".") { ext.removeFirst() }
        let declared = ext.isEmpty ? nil : SubtitleFormat.fromFileExtension(ext)
        let sniffed = sniffFormat(text)

        var candidates: [SubtitleFormat] = []
        switch (declared, sniffed) {
        case (nil, nil):
            throw SubtitleError.unsupportedFormat(ext.isEmpty ? "unknown" : ext)
        case let (d?, nil):
            candidates = [d]
        case let (nil, s?):
            candidates = [s]
        case let (d?, s?):
            let sameFamily = d == s || (d == .ass || d == .ssa) && (s == .ass || s == .ssa)
            if sameFamily {
                candidates = [s]
            } else if hasStrongSignature(s) {
                candidates = [s, d]
            } else {
                candidates = [d, s]
            }
        }

        var lastError: Error = SubtitleError.empty
        for format in candidates {
            do {
                return try parse(string: text, format: format)
            } catch let error as SubtitleError where error == .empty {
                lastError = error
            }
        }
        throw lastError
    }

    /// Parses already-decoded text in a known format. The result is `normalized()`.
    /// Throws `.empty` when no cue survives and `.unsupportedFormat` for tx3g/unknown.
    public static func parse(string: String, format: SubtitleFormat) throws -> SubtitleDocument {
        let document: SubtitleDocument
        switch format {
        case .srt: document = SRTParser.parse(string)
        case .webvtt: document = WebVTTParser.parse(string)
        case .ass, .ssa: document = ASSParser.parse(string)
        case .tx3g, .unknown: throw SubtitleError.unsupportedFormat(format.displayName)
        }
        guard !document.cues.isEmpty else { throw SubtitleError.empty }
        return document.normalized()
    }

    /// Best-effort format sniffing from content ("WEBVTT" header, "[Script Info]", SRT arrows).
    public static func sniffFormat(_ text: String) -> SubtitleFormat? {
        var head = String(text.unicodeScalars.prefix(65536))
        if head.unicodeScalars.first == "\u{FEFF}" { head.unicodeScalars.removeFirst() }
        let trimmed = head.drop(while: { $0.isWhitespace })
        if WebVTTParser.isSignature(trimmed.prefix(16)) { return .webvtt }
        let lower = head.lowercased()
        if lower.contains("[script info]") || lower.contains("[v4+ styles]") || lower.contains("[v4 styles]")
            || (lower.contains("[events]") && lower.contains("dialogue:")) {
            if lower.contains("[v4+ styles]") { return .ass }
            if lower.contains("[v4 styles]") { return .ssa }
            if let range = lower.range(of: "scripttype:") {
                let value = lower[range.upperBound...].prefix(while: { $0 != "\n" && $0 != "\r" })
                return value.contains("+") ? .ass : .ssa
            }
            return .ass
        }
        for line in TextLines.split(head) where TimestampParser.parseTimingLine(line) != nil {
            return .srt
        }
        return nil
    }

    /// Decodes subtitle bytes to a String using the fallback chain described above.
    /// Throws `.unreadableEncoding` for binary data.
    public static func decodeText(_ data: Data) throws -> String {
        try TextDecoding.decode([UInt8](data))
    }

    private static func hasStrongSignature(_ format: SubtitleFormat) -> Bool {
        format == .webvtt || format == .ass || format == .ssa
    }
}
