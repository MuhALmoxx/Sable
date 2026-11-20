import Foundation

// OWNER: subtitles-core agent.

public enum TimecodeFormatter {
    /// U+2212 MINUS SIGN, used for negative values in every formatter.
    static let minus = "\u{2212}"

    /// "1:02:03" / "2:03" style for player chrome (no millis, seconds truncated).
    /// Negative values get a leading "−". Non-finite values render as "0:00".
    public static func playerTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "0:00" }
        let total = Int64(min(abs(seconds), 3.6e12).rounded(.down))
        guard total > 0 else { return "0:00" }
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        let body = h > 0 ? "\(h):\(SRTWriter.pad(m, 2)):\(SRTWriter.pad(s, 2))" : "\(m):\(SRTWriter.pad(s, 2))"
        return seconds < 0 ? minus + body : body
    }

    /// "01:02:03.456" for precise timelines and cue lists (rounded to the millisecond).
    public static func precise(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "00:00:00.000" }
        let totalMillis = Int64((min(abs(seconds), 3.6e12) * 1000).rounded())
        let ms = totalMillis % 1000
        let totalSeconds = totalMillis / 1000
        let body = "\(SRTWriter.pad(totalSeconds / 3600, 2)):\(SRTWriter.pad((totalSeconds / 60) % 60, 2)):\(SRTWriter.pad(totalSeconds % 60, 2)).\(SRTWriter.pad(ms, 3))"
        return seconds < 0 && totalMillis > 0 ? minus + body : body
    }

    /// Signed offset "+1.300 s" / "−0.100 s" / "0.000 s" (uses U+2212 minus).
    public static func signedOffset(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "0.000 s" }
        let millis = Int64((max(-3.6e12, min(seconds, 3.6e12)) * 1000).rounded())
        guard millis != 0 else { return "0.000 s" }
        let a = abs(millis)
        return "\(millis > 0 ? "+" : minus)\(a / 1000).\(SRTWriter.pad(a % 1000, 3)) s"
    }
}

public enum OffsetInput {
    /// Parses user-entered signed offsets without arbitrary limits:
    /// "1.5", "+1.5", "-1.5", "−1.5" (U+2212), "-90", "1:02.5" (m:ss.fff), "-1:02:03.25",
    /// "250ms", "-2s", ",5" / "0,5" (comma decimal). Returns seconds or nil if unparseable.
    /// Also accepts "1.5 s", "250 ms", "2 sec" and en-dash/hyphen-minus variants of the sign.
    public static func parse(_ text: String) -> TimeInterval? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        var negative = false
        if let first = s.unicodeScalars.first, ["-", "\u{2212}", "\u{2013}", "\u{FE63}", "\u{FF0D}"].contains(first) {
            negative = true
            s.unicodeScalars.removeFirst()
        } else if let first = s.unicodeScalars.first, first == "+" || first == "\u{FF0B}" {
            s.unicodeScalars.removeFirst()
        }
        s = s.trimmingCharacters(in: .whitespaces)

        // Unit suffix.
        var multiplier = 1.0
        let lower = s.lowercased()
        for (suffix, factor) in [("milliseconds", 0.001), ("millisecond", 0.001), ("msec", 0.001), ("ms", 0.001),
                                 ("seconds", 1.0), ("second", 1.0), ("secs", 1.0), ("sec", 1.0), ("s", 1.0)] {
            if lower.hasSuffix(suffix) {
                multiplier = factor
                s = String(s.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
                break
            }
        }
        guard !s.isEmpty else { return nil }

        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count <= 3 else { return nil }
        if parts.count > 1 && multiplier != 1.0 { return nil }  // "1:02ms" makes no sense
        var total = 0.0
        for (i, part) in parts.enumerated() {
            let isLast = i == parts.count - 1
            guard let value = isLast ? decimal(part) : integer(part) else { return nil }
            total = total * 60 + value
        }
        let result = total * multiplier
        guard result.isFinite else { return nil }
        return negative ? -result : result
    }

    private static func integer(_ part: Substring) -> Double? {
        guard !part.isEmpty, part.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
        return Double(part)
    }

    /// Digits with at most one '.' or ',' decimal separator (",5" and "5." allowed).
    private static func decimal(_ part: Substring) -> Double? {
        var digits = 0
        var separators = 0
        var normalized = ""
        for b in part.utf8 {
            if b >= 0x30 && b <= 0x39 {
                digits += 1
                normalized.unicodeScalars.append(Unicode.Scalar(b))
            } else if b == UInt8(ascii: ".") || b == UInt8(ascii: ",") {
                separators += 1
                normalized += "."
            } else {
                return nil
            }
        }
        guard digits > 0, separators <= 1 else { return nil }
        if normalized.hasPrefix(".") { normalized = "0" + normalized }
        if normalized.hasSuffix(".") { normalized += "0" }
        return Double(normalized)
    }
}
