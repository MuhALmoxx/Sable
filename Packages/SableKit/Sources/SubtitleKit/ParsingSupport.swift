import Foundation

// OWNER: subtitles-core agent.
// Helpers shared by the SRT / WebVTT / ASS parsers and the Matroska text decoder.

enum TimestampParser {
    /// Parses "[-]H+:MM:SS[.,]fff", "MM:SS[.,]fff" (and without fraction). The fraction is a
    /// decimal fraction of any length ("1,5" = 1.5 s, ".05" = 50 ms) rounded to the millisecond.
    /// Hours may have any number of digits. Returns nil for anything else.
    static func parse<C: Collection>(_ input: C) -> TimeInterval? where C.Element == UInt8 {
        var bytes = Array(input)
        while let f = bytes.first, f == 0x20 || f == 0x09 { bytes.removeFirst() }
        while let l = bytes.last, l == 0x20 || l == 0x09 { bytes.removeLast() }
        guard !bytes.isEmpty else { return nil }
        var i = 0
        var negative = false
        if bytes[0] == UInt8(ascii: "-") {
            negative = true
            i = 1
        }
        var groups: [Int64] = []
        var current: Int64 = 0
        var digits = 0
        var fractionMillis: Int64 = 0
        while i < bytes.count {
            let b = bytes[i]
            if b >= 0x30 && b <= 0x39 {
                guard digits < 12 else { return nil }
                current = current * 10 + Int64(b - 0x30)
                digits += 1
            } else if b == UInt8(ascii: ":") {
                guard digits > 0, groups.count < 2 else { return nil }
                groups.append(current)
                current = 0
                digits = 0
            } else if b == UInt8(ascii: ".") || b == UInt8(ascii: ",") {
                guard digits > 0 else { return nil }
                // Fraction: the remaining bytes must all be digits.
                var fracDigits = 0
                var value: Int64 = 0
                var j = i + 1
                while j < bytes.count {
                    let d = bytes[j]
                    guard d >= 0x30 && d <= 0x39 else { return nil }
                    if fracDigits < 9 {
                        value = value * 10 + Int64(d - 0x30)
                        fracDigits += 1
                    }
                    j += 1
                }
                guard fracDigits > 0 else { return nil }
                var scale: Int64 = 1
                for _ in 0..<fracDigits { scale *= 10 }
                // Round to milliseconds.
                fractionMillis = (value * 1000 * 2 + scale) / (scale * 2)
                i = bytes.count
                break
            } else {
                return nil
            }
            i += 1
        }
        guard digits > 0 else { return nil }
        groups.append(current)
        guard groups.count >= 2 else { return nil }
        let hours: Int64 = groups.count == 3 ? groups[0] : 0
        let minutes = groups[groups.count - 2]
        let seconds = groups[groups.count - 1]
        let totalMillis = ((hours * 60 + minutes) * 60 + seconds) * 1000 + fractionMillis
        let value = Double(totalMillis) / 1000
        return negative ? -value : value
    }

    /// Finds "-->" (or a lone "->") and returns the byte ranges before and after the arrow.
    static func splitArrow(_ bytes: [UInt8]) -> (left: ArraySlice<UInt8>, right: ArraySlice<UInt8>)? {
        let dash = UInt8(ascii: "-"), gt = UInt8(ascii: ">")
        var i = 0
        while i + 1 < bytes.count {
            if bytes[i] == dash && bytes[i + 1] == gt {
                // Include any dashes directly before the '>' ("-->", "--->").
                var start = i
                while start > 0 && bytes[start - 1] == dash { start -= 1 }
                return (bytes[0..<start], bytes[(i + 2)...])
            }
            i += 1
        }
        return nil
    }

    /// Parses a cue timing line: start, end and whatever follows the end timestamp (VTT
    /// settings or SRT coordinates).
    static func parseTimingLine<S: StringProtocol>(_ line: S) -> (start: TimeInterval, end: TimeInterval, rest: String)? {
        let bytes = Array(line.utf8)
        guard bytes.count >= 9, let (left, right) = splitArrow(bytes) else { return nil }
        guard let start = parse(left) else { return nil }
        var r = right.startIndex
        while r < right.endIndex && (right[r] == 0x20 || right[r] == 0x09) { r += 1 }
        var e = r
        while e < right.endIndex && right[e] != 0x20 && right[e] != 0x09 { e += 1 }
        guard let end = parse(right[r..<e]) else { return nil }
        let rest = String(decoding: right[e...], as: UTF8.self).trimmingCharacters(in: .whitespaces)
        return (max(0, start), max(0, end), rest)
    }
}

enum CueIDs {
    /// Uses each preferred id that is present and unique in the document; every other cue
    /// gets "<prefix><n>" (n = 1-based position), avoiding collisions with the ids kept.
    static func assign(preferred: [String?], prefix: String) -> [String] {
        var counts: [String: Int] = [:]
        for case let id? in preferred { counts[id, default: 0] += 1 }
        var used = Set<String>()
        for case let id? in preferred where counts[id] == 1 { used.insert(id) }
        var result: [String] = []
        result.reserveCapacity(preferred.count)
        for (i, candidate) in preferred.enumerated() {
            if let id = candidate, counts[id] == 1 {
                result.append(id)
                continue
            }
            var fallback = "\(prefix)\(i + 1)"
            var suffix = 2
            while used.contains(fallback) {
                fallback = "\(prefix)\(i + 1)_\(suffix)"
                suffix += 1
            }
            used.insert(fallback)
            result.append(fallback)
        }
        return result
    }
}

// MARK: - Styled text

/// Inline emphasis while converting format-specific markup to Sable's canonical tags.
struct InlineStyle: Equatable, Sendable {
    var bold = false
    var italic = false
    var underline = false
}

/// Collects styled characters line by line and serialises them to Sable's canonical cue text:
/// each line trimmed, blank lines dropped, <b>/<i>/<u> balanced per line (nesting b > i > u).
struct StyledTextBuilder {
    private struct Run {
        var text: String.UnicodeScalarView
        var style: InlineStyle
    }

    private var lines: [[Run]] = [[]]

    mutating func append(_ scalar: Unicode.Scalar, style: InlineStyle) {
        let li = lines.count - 1
        if let ri = lines[li].indices.last, lines[li][ri].style == style {
            lines[li][ri].text.append(scalar)
        } else {
            var view = String.UnicodeScalarView()
            view.append(scalar)
            lines[li].append(Run(text: view, style: style))
        }
    }

    mutating func append(_ string: String, style: InlineStyle) {
        for s in string.unicodeScalars { append(s, style: style) }
    }

    mutating func newline() { lines.append([]) }

    private enum Tag: Int { case b = 0, i, u
        var name: String { self == .b ? "b" : (self == .i ? "i" : "u") }
    }

    private static func tags(for style: InlineStyle) -> [Tag] {
        var t: [Tag] = []
        if style.bold { t.append(.b) }
        if style.italic { t.append(.i) }
        if style.underline { t.append(.u) }
        return t
    }

    static func isInvisible(_ s: Unicode.Scalar) -> Bool {
        s.properties.isWhitespace || s.properties.generalCategory == .format
    }

    func build() -> String {
        var out = String.UnicodeScalarView()
        var firstLine = true
        for line in lines {
            var chars: [(Unicode.Scalar, InlineStyle)] = []
            for run in line { for s in run.text { chars.append((s, run.style)) } }
            var lo = 0, hi = chars.count
            while lo < hi && chars[lo].0.properties.isWhitespace { lo += 1 }
            while hi > lo && chars[hi - 1].0.properties.isWhitespace { hi -= 1 }
            guard lo < hi, chars[lo..<hi].contains(where: { !Self.isInvisible($0.0) }) else { continue }
            if !firstLine { out.append("\n") }
            firstLine = false
            var open: [Tag] = []
            for k in lo..<hi {
                let want = Self.tags(for: chars[k].1)
                if want != open {
                    var p = 0
                    while p < open.count && p < want.count && open[p] == want[p] { p += 1 }
                    for t in open[p...].reversed() { out.append(contentsOf: "</\(t.name)>".unicodeScalars) }
                    open.removeSubrange(p...)
                    for t in want[p...] {
                        out.append(contentsOf: "<\(t.name)>".unicodeScalars)
                        open.append(t)
                    }
                }
                out.append(chars[k].0)
            }
            for t in open.reversed() { out.append(contentsOf: "</\(t.name)>".unicodeScalars) }
        }
        return String(out)
    }
}

// MARK: - Entities

enum HTMLEntities {
    static let named: [String: Unicode.Scalar] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        "lrm": "\u{200E}", "rlm": "\u{200F}", "zwj": "\u{200D}", "zwnj": "\u{200C}",
        "ensp": "\u{2002}", "emsp": "\u{2003}", "thinsp": "\u{2009}", "shy": "\u{00AD}",
        "hellip": "\u{2026}", "mdash": "\u{2014}", "ndash": "\u{2013}", "lsquo": "\u{2018}",
        "rsquo": "\u{2019}", "ldquo": "\u{201C}", "rdquo": "\u{201D}", "laquo": "\u{00AB}",
        "raquo": "\u{00BB}", "copy": "\u{00A9}", "reg": "\u{00AE}", "trade": "\u{2122}",
        "deg": "\u{00B0}", "eacute": "\u{00E9}", "egrave": "\u{00E8}", "agrave": "\u{00E0}",
        "ccedil": "\u{00E7}",
    ]

    /// Parses an entity starting at `s[i] == "&"`. Returns the decoded scalar (nil for a
    /// numeric entity that decodes to nothing printable) and the index after ';'.
    static func parse(_ s: [Unicode.Scalar], at i: Int) -> (scalar: Unicode.Scalar?, next: Int)? {
        var j = i + 1
        var name = ""
        while j < s.count && j - i <= 32 {
            let c = s[j]
            if c == ";" { break }
            guard c.isASCII, c.properties.isAlphabetic || ("0"..."9").contains(c) || c == "#" else { return nil }
            name.unicodeScalars.append(c)
            j += 1
        }
        guard j < s.count, s[j] == ";", !name.isEmpty else { return nil }
        if name.hasPrefix("#") {
            let body = name.dropFirst()
            let value: UInt32?
            if body.hasPrefix("x") || body.hasPrefix("X") {
                value = UInt32(body.dropFirst(), radix: 16)
            } else {
                value = UInt32(body, radix: 10)
            }
            guard let v = value else { return nil }
            if v == 0 { return (nil, j + 1) }
            return (Unicode.Scalar(v) ?? "\u{FFFD}", j + 1)
        }
        guard let scalar = named[name] ?? named[name.lowercased()] else { return nil }
        return (scalar, j + 1)
    }
}

// MARK: - SRT / WebVTT inline markup

enum MarkupDialect { case srt, webvtt }

enum InlineMarkup {
    /// Converts SRT/WebVTT cue text to canonical text: keeps <i>/<b>/<u> (lowercased, balanced
    /// per line), strips <font>, <span>, <c.class>, <v Name>, <lang>, <ruby> (keeping base
    /// text and dropping <rt> annotations), WebVTT inline timestamps, ASS-style override
    /// blocks ({\an8} -> alignment, {\i1} -> <i>), decodes entities and drops blank lines.
    static func clean(_ raw: String, dialect: MarkupDialect) -> (text: String, alignment: Int?) {
        let s = Array(raw.unicodeScalars)
        var builder = StyledTextBuilder()
        var style = InlineStyle()
        var alignment: Int?
        var suppressDepth = 0
        var i = 0
        func emit(_ c: Unicode.Scalar) {
            if suppressDepth == 0 { builder.append(c, style: style) }
        }
        while i < s.count {
            let c = s[i]
            switch c {
            case "\n":
                builder.newline()
                i += 1
            case "{" where i + 1 < s.count && s[i + 1] == "\\":
                if let close = s[(i + 1)...].firstIndex(of: "}") {
                    var ctx = ASSOverrideContext(style: style, base: InlineStyle())
                    ctx.alignment = alignment
                    ASSOverrides.apply(s[(i + 1)..<close], to: &ctx)
                    style = ctx.style
                    alignment = ctx.alignment
                    i = close + 1
                } else {
                    emit(c)
                    i += 1
                }
            case "<":
                if let tag = parseTag(s, at: i, dialect: dialect) {
                    switch tag.kind {
                    case .italic: style.italic = !tag.closing
                    case .bold: style.bold = !tag.closing
                    case .underline: style.underline = !tag.closing
                    case .lineBreak: builder.newline()
                    case .annotation:
                        suppressDepth = tag.closing ? max(0, suppressDepth - 1) : suppressDepth + 1
                    case .rubyContainer:
                        if tag.closing { suppressDepth = 0 }
                    case .ignored: break
                    }
                    i = tag.next
                } else {
                    emit(c)
                    i += 1
                }
            case "&":
                if let entity = HTMLEntities.parse(s, at: i) {
                    if let scalar = entity.scalar { emit(scalar) }
                    i = entity.next
                } else {
                    emit(c)
                    i += 1
                }
            default:
                emit(c)
                i += 1
            }
        }
        return (builder.build(), alignment)
    }

    private enum TagKind { case italic, bold, underline, lineBreak, annotation, rubyContainer, ignored }

    private static let strippedTags: Set<String> = [
        "font", "span", "s", "strike", "del", "ins", "c", "v", "lang", "small", "big", "sub", "sup",
        "a", "p", "div", "q", "mark", "rb", "rtc", "rp", "tt", "center",
    ]

    private static func parseTag(_ s: [Unicode.Scalar], at i: Int, dialect: MarkupDialect) -> (kind: TagKind, closing: Bool, next: Int)? {
        var j = i + 1
        guard j < s.count else { return nil }
        var closing = false
        if s[j] == "/" {
            closing = true
            j += 1
        }
        guard j < s.count else { return nil }
        // Find the closing '>' on this line.
        var close = j
        while close < s.count && s[close] != ">" && s[close] != "\n" && s[close] != "<" && close - i < 512 { close += 1 }
        guard close < s.count, s[close] == ">" else { return nil }

        if dialect == .webvtt && !closing && ("0"..."9").contains(s[j]) {
            // Inline timestamp <00:00:01.000> / <01.000>
            let body = s[j..<close]
            guard body.allSatisfy({ ("0"..."9").contains($0) || $0 == ":" || $0 == "." }) else { return nil }
            return (.ignored, false, close + 1)
        }

        var name = ""
        var k = j
        while k < close, s[k].isASCII, s[k].properties.isAlphabetic || ("0"..."9").contains(s[k]) {
            name.unicodeScalars.append(s[k])
            k += 1
        }
        guard !name.isEmpty else { return nil }
        // Whatever follows the name must be a separator: class (.x), space + annotation, or '/'.
        if k < close {
            let sep = s[k]
            guard sep == "." || sep == " " || sep == "\t" || sep == "/" || sep == "=" else { return nil }
        }
        let lower = name.lowercased()
        let next = close + 1
        switch lower {
        case "i", "em": return (.italic, closing, next)
        case "b", "strong": return (.bold, closing, next)
        case "u": return (.underline, closing, next)
        case "br": return (.lineBreak, false, next)
        case "rt": return (.annotation, closing, next)
        case "ruby": return (.rubyContainer, closing, next)
        default:
            return strippedTags.contains(lower) ? (.ignored, closing, next) : nil
        }
    }
}
