import Foundation

// OWNER: subtitles-core agent.

public struct SRTExportOptions: Sendable, Hashable {
    /// When set, exported timestamps are `timing.effective(original)` (offset baked in).
    /// When nil, original timestamps are written unchanged.
    public var timing: SubtitleTiming?
    /// Wrap each line of right-to-left text in U+202B…U+202C (RLE/PDF) so players that do not
    /// apply a RTL paragraph direction still order punctuation correctly.
    public var addRTLMarks: Bool
    /// "\r\n" (most compatible) or "\n".
    public var lineEnding: String
    /// Keep <i>/<b>/<u> tags (true) or strip them (false).
    public var keepInlineTags: Bool

    public init(timing: SubtitleTiming? = nil, addRTLMarks: Bool = false, lineEnding: String = "\r\n", keepInlineTags: Bool = true) {
        self.timing = timing
        self.addRTLMarks = addRTLMarks
        self.lineEnding = lineEnding
        self.keepInlineTags = keepInlineTags
    }
}

public enum SRTWriter {
    /// Serialises cues in dialogue order with counters 1...n, "HH:MM:SS,mmm --> HH:MM:SS,mmm".
    /// Negative effective times clamp to 0 (a cue entirely before 0 is dropped).
    public static func write(_ document: SubtitleDocument, options: SRTExportOptions = SRTExportOptions()) -> String {
        ""
    }

    /// "01:02:03,456"
    public static func timestamp(_ seconds: TimeInterval) -> String { "00:00:00,000" }
}
