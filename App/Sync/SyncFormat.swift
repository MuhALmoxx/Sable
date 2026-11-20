import Foundation
import SubtitleKit

// OWNER: sync agent. Text formatting and offset entry parsing for the timing panel and guided
// sync. Foundation-only (no UI) so it behaves identically everywhere and is easy to reason about.

enum SyncFormat {
    /// U+2212 MINUS SIGN, used for every displayed negative number.
    static let minus = "\u{2212}"
    /// U+200F RIGHT-TO-LEFT MARK, prefixed to each displayed Arabic (RTL) line.
    static let rtlMark = "\u{200F}"

    /// Whole milliseconds, safe for any finite input (huge values are clamped, never trap).
    static func milliseconds(_ seconds: TimeInterval) -> Int {
        guard seconds.isFinite else { return 0 }
        let clamped = min(max(seconds, -9_000_000_000), 9_000_000_000)
        return Int((clamped * 1000).rounded())
    }

    private static func pad(_ value: Int, _ width: Int) -> String {
        let s = String(value)
        return s.count >= width ? s : String(repeating: "0", count: width - s.count) + s
    }

    /// "+1.300 s" / "−0.100 s" / "0.000 s" (U+2212 minus).
    static func signedOffset(_ seconds: TimeInterval) -> String {
        let ms = milliseconds(seconds)
        if ms == 0 { return "0.000 s" }
        let sign = ms > 0 ? "+" : minus
        return "\(sign)\(magnitude(ms))"
    }

    /// "1.300 s" for a millisecond count (sign dropped).
    private static func magnitude(_ ms: Int) -> String {
        let a = abs(ms)
        return "\(a / 1000).\(pad(a % 1000, 3)) s"
    }

    /// "1.300 s" (unsigned magnitude of `seconds`).
    static func unsignedSeconds(_ seconds: TimeInterval) -> String { magnitude(milliseconds(seconds)) }

    /// For offsets of a minute or more, a friendlier reading: "= 1 min 15.500 s" (nil below 60 s).
    static func longOffsetHint(_ seconds: TimeInterval) -> String? {
        let ms = abs(milliseconds(seconds))
        guard ms >= 60_000 else { return nil }
        let hours = ms / 3_600_000
        let minutes = (ms / 60_000) % 60
        let rest = ms % 60_000
        let secs = "\(rest / 1000).\(pad(rest % 1000, 3)) s"
        let sign = seconds < 0 ? minus : "+"
        if hours > 0 { return "= \(sign)\(hours) h \(minutes) min \(secs)" }
        return "= \(sign)\(minutes) min \(secs)"
    }

    /// "01:02:03.456" — precise media time for timelines and cue lists (U+2212 for negatives).
    static func precise(_ seconds: TimeInterval) -> String {
        let ms = milliseconds(seconds)
        let a = abs(ms)
        let h = a / 3_600_000
        let m = (a / 60_000) % 60
        let s = (a / 1000) % 60
        let f = a % 1000
        return "\(ms < 0 ? minus : "")\(pad(h, 2)):\(pad(m, 2)):\(pad(s, 2)).\(pad(f, 3))"
    }

    /// "0:07" / "1:02:03" — short whole-second label for timeline ticks.
    static func tickLabel(_ seconds: Int) -> String {
        let a = abs(seconds)
        let sign = seconds < 0 ? minus : ""
        if a >= 3600 { return "\(sign)\(a / 3600):\(pad((a / 60) % 60, 2)):\(pad(a % 60, 2))" }
        return "\(sign)\(a / 60):\(pad(a % 60, 2))"
    }

    static func hasDrift(_ timing: SubtitleTiming) -> Bool { abs(timing.scale - 1) >= 1e-9 }

    /// "1.0010" (falls back to more digits when four would hide a real difference).
    static func scale(_ scale: Double) -> String {
        let four = String(format: "%.4f", scale)
        if four == "1.0000" && abs(scale - 1) >= 1e-9 { return String(format: "%.6f", scale) }
        return four
    }

    /// Plain-language meaning of an offset (positive = subtitles LATER).
    static func meaning(_ timing: SubtitleTiming) -> String {
        let ms = milliseconds(timing.offset)
        if ms == 0 { return hasDrift(timing) ? "No constant shift" : "Original timing" }
        let amount = magnitude(ms)
        return ms > 0
            ? "Subtitles appear \(amount) later than the file's timing"
            : "Subtitles appear \(amount) earlier than the file's timing"
    }

    /// Same as `meaning`, phrased for a value that is not applied yet.
    static func prospectiveMeaning(_ timing: SubtitleTiming) -> String {
        let ms = milliseconds(timing.offset)
        if ms == 0 { return hasDrift(timing) ? "No constant shift" : "Subtitles will use the file's original timing" }
        let amount = magnitude(ms)
        return ms > 0
            ? "Subtitles will appear \(amount) later than the file's timing"
            : "Subtitles will appear \(amount) earlier than the file's timing"
    }

    /// "Drift correction ×1.0010 active (from two-point sync)" or nil when scale == 1.
    static func driftNote(_ timing: SubtitleTiming) -> String? {
        guard hasDrift(timing) else { return nil }
        return "Drift correction \u{00D7}\(scale(timing.scale)) active (from two-point sync)"
    }

    /// "+2.5 s after your mark" / "−3.1 s before your mark" / "at your mark".
    static func relativeToMark(_ delta: TimeInterval) -> String {
        let tenths = Int((min(max(delta, -1e9), 1e9) * 10).rounded())
        if tenths == 0 { return "at your mark" }
        let a = abs(tenths)
        let value = "\(a / 10).\(a % 10) s"
        return tenths > 0 ? "+\(value) after your mark" : "\(minus)\(value) before your mark"
    }

    /// Prepares subtitle text for display: one RLM per line for right-to-left languages.
    static func displayLines(_ text: String, rightToLeft: Bool) -> String {
        guard rightToLeft else { return text }
        return text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in line.hasPrefix(rtlMark) ? String(line) : rtlMark + line }
            .joined(separator: "\n")
    }

    /// Text with inline tags removed and line breaks collapsed (for one-line labels).
    static func oneLine(_ text: String) -> String {
        text.replacingOccurrences(of: "</?[ibuIBU]>", with: "", options: .regularExpression)
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .joined(separator: " ")
    }
}

/// Signed offset entry. Prefers `OffsetInput.parse` (SubtitleKit); falls back to an equivalent
/// local parser so entry keeps working while that is unavailable.
enum OffsetEntry {
    /// Upper bound for a typed offset (about 11.5 days): any real video fits; typos like
    /// "99999999999" get a clear message instead of an unusable timing.
    static let maximumMagnitude: TimeInterval = 1_000_000

    enum Result: Equatable {
        case value(TimeInterval)
        case empty
        case invalid(String)
    }

    static func evaluate(_ text: String) -> Result {
        let trimmed = westernDigits(text).trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "-" || trimmed == "+" || trimmed == SyncFormat.minus { return .empty }
        guard let raw = OffsetInput.parse(trimmed) ?? parse(trimmed), raw.isFinite else {
            return .invalid("Enter seconds like 1.5, -75.5 or +1:02.5 (minutes:seconds).")
        }
        guard abs(raw) <= maximumMagnitude else {
            return .invalid("That offset is longer than any video. Enter less than 1,000,000 s.")
        }
        let rounded = (raw * 1000).rounded() / 1000
        return .value(rounded == 0 ? 0 : rounded)
    }

    /// Accepts "1.5", "+1.5", "-1.5", "−1.5", "-90", "1:02.5" (m:ss.fff), "-1:02:03.25" (h:mm:ss),
    /// "250ms", "-2s", ",5" / "0,5" (comma decimal). No limit on magnitude. nil when unparseable.
    static func parse(_ text: String) -> TimeInterval? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        s = s.replacingOccurrences(of: SyncFormat.minus, with: "-")
            .replacingOccurrences(of: "\u{2013}", with: "-") // en dash
            .replacingOccurrences(of: ",", with: ".")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: "")
        guard !s.isEmpty else { return nil }

        var sign: Double = 1
        if s.hasPrefix("+") {
            s.removeFirst()
        } else if s.hasPrefix("-") {
            sign = -1
            s.removeFirst()
        }

        var unit: Double = 1
        if s.hasSuffix("ms") {
            unit = 0.001
            s.removeLast(2)
        } else if s.hasSuffix("sec") {
            s.removeLast(3)
        } else if s.hasSuffix("s") {
            s.removeLast()
        }
        guard !s.isEmpty else { return nil }

        if s.contains(":") {
            guard unit == 1 else { return nil }
            let parts = s.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2 || parts.count == 3 else { return nil }
            var total: Double = 0
            for (i, part) in parts.enumerated() {
                let isLast = i == parts.count - 1
                if isLast {
                    guard let seconds = decimal(part), seconds < 60 else { return nil }
                    total = total * 60 + seconds
                } else {
                    guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }), let whole = Double(part) else { return nil }
                    if i > 0 && whole >= 60 { return nil }
                    total = total * 60 + whole
                }
            }
            return sign * total
        }
        guard let value = decimal(s) else { return nil }
        return sign * value * unit
    }

    /// "12", "12.5", ".5", "5." — ASCII digits with at most one dot.
    private static func decimal(_ s: String) -> Double? {
        guard !s.isEmpty, s != "." else { return nil }
        var dots = 0
        for ch in s {
            if ch == "." { dots += 1; continue }
            guard ch.isASCII, ch.isNumber else { return nil }
        }
        guard dots <= 1 else { return nil }
        let normalized = s.hasPrefix(".") ? "0" + s : (s.hasSuffix(".") ? s + "0" : s)
        return Double(normalized)
    }

    /// The iOS decimal pad types Arabic-Indic (U+0660…U+0669) or Persian (U+06F0…U+06F9) digits
    /// and the Arabic decimal separator U+066B in Arabic/Persian locales; both parsers read ASCII
    /// only, so map those to "0"…"9" and ".".
    static func westernDigits(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0660...0x0669: scalars.append(Unicode.Scalar(UInt8(scalar.value - 0x0660) + 0x30))
            case 0x06F0...0x06F9: scalars.append(Unicode.Scalar(UInt8(scalar.value - 0x06F0) + 0x30))
            case 0x066B: scalars.append(".")
            default: scalars.append(scalar)
            }
        }
        return String(scalars)
    }

    /// Flips the sign of the typed text ("1.5" ⇄ "-1.5"); used by the ± key next to the field
    /// because the iOS decimal pad has no minus key.
    static func toggledSign(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("-") || trimmed.hasPrefix(SyncFormat.minus) { return String(trimmed.dropFirst()) }
        if trimmed.hasPrefix("+") { return "-" + trimmed.dropFirst() }
        return "-" + trimmed
    }
}
