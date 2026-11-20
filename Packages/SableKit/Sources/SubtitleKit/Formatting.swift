import Foundation

// OWNER: subtitles-core agent.

public enum TimecodeFormatter {
    /// "1:02:03" / "2:03" style for player chrome (no millis). Negative values get a leading "−".
    public static func playerTime(_ seconds: TimeInterval) -> String { "0:00" }
    /// "01:02:03.456" for precise timelines and cue lists.
    public static func precise(_ seconds: TimeInterval) -> String { "00:00:00.000" }
    /// Signed offset "+1.300 s" / "−0.100 s" / "0.000 s" (uses U+2212 minus).
    public static func signedOffset(_ seconds: TimeInterval) -> String { "0.000 s" }
}

public enum OffsetInput {
    /// Parses user-entered signed offsets without arbitrary limits:
    /// "1.5", "+1.5", "-1.5", "−1.5" (U+2212), "-90", "1:02.5" (m:ss.fff), "-1:02:03.25",
    /// "250ms", "-2s", ",5" / "0,5" (comma decimal). Returns seconds or nil if unparseable.
    public static func parse(_ text: String) -> TimeInterval? { nil }
}
