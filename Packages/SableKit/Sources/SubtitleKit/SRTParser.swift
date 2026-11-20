import Foundation

// OWNER: subtitles-core agent.
// SubRip (.srt) parsing, tolerant of the many malformed files found in the wild.

enum SRTParser {
    /// Parses SRT text. Cues are returned in file order (not yet normalised).
    ///
    /// A cue is a timing line ("start --> end [coordinates]") plus every line up to the next
    /// timing line, minus the next cue's counter (a digits-only line directly before it).
    /// Blank lines inside a cue are dropped, so blank-line noise and missing separators
    /// both work. Cues whose text is empty after markup cleanup are dropped.
    static func parse(_ text: String) -> SubtitleDocument {
        let lines = TextLines.split(text)
        var timings: [(line: Int, start: TimeInterval, end: TimeInterval)] = []
        for (i, line) in lines.enumerated() {
            if let t = TimestampParser.parseTimingLine(line) {
                timings.append((i, t.start, t.end))
            }
        }

        var counters: [String?] = []
        var drafts: [(start: TimeInterval, end: TimeInterval, raw: String, text: String, alignment: Int?)] = []
        for (k, timing) in timings.enumerated() {
            let blockEnd = k + 1 < timings.count ? timings[k + 1].line : lines.count
            var body = Array(lines[(timing.line + 1)..<blockEnd])
            if k + 1 < timings.count, let last = body.last, counterValue(last) != nil {
                body.removeLast()
            }
            var counter: String?
            if timing.line > 0 {
                let previousTimingLine = k > 0 ? timings[k - 1].line : -1
                if timing.line - 1 > previousTimingLine { counter = counterValue(lines[timing.line - 1]) }
            }
            while let first = body.first, TextLines.isBlank(first) { body.removeFirst() }
            while let last = body.last, TextLines.isBlank(last) { body.removeLast() }
            let raw = body.joined(separator: "\n")
            let content = body.filter { !TextLines.isBlank($0) }.joined(separator: "\n")
            let cleaned = InlineMarkup.clean(content, dialect: .srt)
            guard !cleaned.text.isEmpty else { continue }
            counters.append(counter)
            drafts.append((timing.start, max(timing.start, timing.end), raw, cleaned.text, cleaned.alignment))
        }

        let ids = CueIDs.assign(preferred: counters, prefix: "c")
        var cues: [SubtitleCue] = []
        cues.reserveCapacity(drafts.count)
        for (n, d) in drafts.enumerated() {
            cues.append(SubtitleCue(id: ids[n], index: n, start: d.start, end: d.end, text: d.text, rawText: d.raw,
                                    style: d.alignment.map { CueStyleHint(alignment: $0) }))
        }
        return SubtitleDocument(format: .srt, cues: cues)
    }

    /// "12" -> "12", "007" -> "7"; nil unless the trimmed line is all ASCII digits.
    static func counterValue<S: StringProtocol>(_ line: S) -> String? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
        let stripped = t.drop(while: { $0 == "0" })
        return stripped.isEmpty ? "0" : String(stripped)
    }
}

enum WebVTTParser {
    /// Parses WebVTT text. Cues are returned in file order (not yet normalised).
    static func parse(_ text: String) -> SubtitleDocument {
        let lines = TextLines.split(text)
        // Blocks separated by blank lines.
        var blocks: [[Substring]] = []
        var current: [Substring] = []
        for line in lines {
            if TextLines.isBlank(line) {
                if !current.isEmpty { blocks.append(current); current = [] }
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty { blocks.append(current) }

        var language: LanguageCode?
        var preferredIDs: [String?] = []
        var drafts: [(start: TimeInterval, end: TimeInterval, raw: String, text: String, alignment: Int?)] = []

        for (b, original) in blocks.enumerated() {
            var block = original
            var isHeaderBlock = false
            if b == 0, let first = block.first, isSignature(first) {
                block.removeFirst()
                isHeaderBlock = true
            }
            guard let first = block.first else { continue }
            let head = first.trimmingCharacters(in: .whitespaces)
            if !head.contains("-->") && (keyword(head, "NOTE") || keyword(head, "STYLE") || keyword(head, "REGION")) {
                continue
            }
            guard let arrowLine = block.firstIndex(where: { TimestampParser.parseTimingLine($0) != nil }),
                  let timing = TimestampParser.parseTimingLine(block[arrowLine]) else {
                if isHeaderBlock {
                    for line in block {
                        let parts = line.split(separator: ":", maxSplits: 1)
                        if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "language" {
                            language = LanguageCode.normalized(parts[1].trimmingCharacters(in: .whitespaces))
                        }
                    }
                }
                continue
            }
            var identifier: String?
            if arrowLine > 0 && !isHeaderBlock {
                let id = block[arrowLine - 1].trimmingCharacters(in: .whitespaces)
                if !id.isEmpty { identifier = id }
            }
            let payload = block[(arrowLine + 1)...].joined(separator: "\n")
            let text = cleanPayload(payload)
            guard !text.isEmpty else { continue }
            preferredIDs.append(identifier)
            drafts.append((timing.start, max(timing.start, timing.end), payload, text, alignment(fromSettings: timing.rest)))
        }

        let ids = CueIDs.assign(preferred: preferredIDs, prefix: "c")
        var cues: [SubtitleCue] = []
        for (n, d) in drafts.enumerated() {
            cues.append(SubtitleCue(id: ids[n], index: n, start: d.start, end: d.end, text: d.text, rawText: d.raw,
                                    style: d.alignment.map { CueStyleHint(alignment: $0) }))
        }
        return SubtitleDocument(format: .webvtt, cues: cues, language: language)
    }

    static func isSignature<S: StringProtocol>(_ line: S) -> Bool {
        var s = String(line)
        if s.unicodeScalars.first == "\u{FEFF}" { s.unicodeScalars.removeFirst() }
        guard s.hasPrefix("WEBVTT") else { return false }
        return s.dropFirst(6).first.map { $0.isWhitespace } ?? true
    }

    private static func keyword(_ line: String, _ word: String) -> Bool {
        guard line.hasPrefix(word) else { return false }
        let rest = line.dropFirst(word.count)
        return rest.isEmpty || rest.first == " " || rest.first == "\t"
    }

    /// Cue payload -> canonical text (voice/class/lang/ruby spans stripped, timestamps removed,
    /// entities decoded, <i>/<b>/<u> kept).
    static func cleanPayload(_ payload: String) -> String {
        InlineMarkup.clean(payload, dialect: .webvtt).text
    }

    /// Best-effort numpad alignment from cue settings ("line:0 align:start position:10%").
    /// Returns nil for the default (bottom centre) or when no positioning setting is present.
    static func alignment(fromSettings settings: String) -> Int? {
        var column: Int?
        var positionColumn: Int?
        var row: Int?
        for token in settings.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
            guard let colon = token.firstIndex(of: ":") else { continue }
            let key = token[..<colon].lowercased()
            let value = token[token.index(after: colon)...]
            let primary = value.split(separator: ",").first.map { String($0) } ?? ""
            switch key {
            case "align":
                switch primary.lowercased() {
                case "start", "left": column = 1
                case "center", "middle": column = 2
                case "end", "right": column = 3
                default: break
                }
            case "line":
                if primary.hasSuffix("%"), let pct = Double(primary.dropLast()) {
                    row = pct < 34 ? 2 : (pct < 67 ? 1 : 0)
                } else if let n = Double(primary) {
                    row = n < 0 ? 0 : 2
                }
            case "position":
                if primary.hasSuffix("%"), let pct = Double(primary.dropLast()) {
                    positionColumn = pct < 34 ? 1 : (pct > 66 ? 3 : 2)
                }
            default:
                break
            }
        }
        guard column != nil || positionColumn != nil || row != nil else { return nil }
        let result = (row ?? 0) * 3 + (positionColumn ?? column ?? 2)
        return result == 2 ? nil : result
    }
}
