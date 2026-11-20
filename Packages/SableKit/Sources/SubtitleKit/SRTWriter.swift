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
    /// Blank lines inside a cue (which would end the cue in SRT) are removed; cues without
    /// visible text are skipped. Each block ends with an empty line.
    public static func write(_ document: SubtitleDocument, options: SRTExportOptions = SRTExportOptions()) -> String {
        let eol = options.lineEnding.isEmpty ? "\r\n" : options.lineEnding
        let ordered = document.cues.enumerated().sorted { lhs, rhs in
            if lhs.element.start != rhs.element.start { return lhs.element.start < rhs.element.start }
            if lhs.element.index != rhs.element.index { return lhs.element.index < rhs.element.index }
            return lhs.offset < rhs.offset
        }.map(\.element)

        var out = ""
        var counter = 0
        for cue in ordered {
            var start = cue.start
            var end = cue.end
            if let timing = options.timing {
                start = timing.effective(start)
                end = timing.effective(end)
            }
            guard start.isFinite, end.isFinite else { continue }
            if end < start { end = start }
            if end <= 0 { continue }
            start = max(0, start)

            let text = options.keepInlineTags ? cue.text : cue.plainText
            var lines: [String] = []
            for raw in TextLines.split(text) {
                var line = String(raw)
                guard !line.unicodeScalars.allSatisfy({ StyledTextBuilder.isInvisible($0) }) else { continue }
                if options.addRTLMarks && containsRTLLetter(line) && !isWrappedInEmbedding(line) {
                    line = "\u{202B}" + line + "\u{202C}"
                }
                lines.append(line)
            }
            guard !lines.isEmpty else { continue }
            counter += 1
            out += "\(counter)\(eol)\(timestamp(start)) --> \(timestamp(end))\(eol)"
            for line in lines { out += line + eol }
            out += eol
        }
        return out
    }

    /// "01:02:03,456" (hours keep growing past 99; negative and non-finite clamp to 0).
    public static func timestamp(_ seconds: TimeInterval) -> String {
        let clamped = seconds.isFinite ? max(0, min(seconds, 3.6e9)) : 0
        let totalMillis = Int64((clamped * 1000).rounded())
        let ms = totalMillis % 1000
        let totalSeconds = totalMillis / 1000
        let s = totalSeconds % 60
        let m = (totalSeconds / 60) % 60
        let h = totalSeconds / 3600
        return "\(pad(h, 2)):\(pad(m, 2)):\(pad(s, 2)),\(pad(ms, 3))"
    }

    static func pad(_ value: Int64, _ width: Int) -> String {
        let digits = String(value)
        return digits.count >= width ? digits : String(repeating: "0", count: width - digits.count) + digits
    }

    /// True when the line contains a letter from a right-to-left script (Hebrew, Arabic,
    /// Syriac, Thaana, N'Ko and their presentation forms).
    static func containsRTLLetter(_ line: String) -> Bool {
        line.unicodeScalars.contains { s in
            let v = s.value
            let inRTLBlock = (0x0590...0x08FF).contains(v) || (0xFB1D...0xFDFF).contains(v) || (0xFE70...0xFEFF).contains(v)
                || (0x10800...0x10FFF).contains(v) || (0x1E800...0x1EFFF).contains(v)
            return inRTLBlock && s.properties.isAlphabetic
        }
    }

    private static func isWrappedInEmbedding(_ line: String) -> Bool {
        line.unicodeScalars.first == "\u{202B}" && line.unicodeScalars.last == "\u{202C}"
    }
}
