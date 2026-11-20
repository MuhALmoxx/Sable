import Foundation

// OWNER: subtitles-core agent.
// ASS / SSA (Advanced SubStation Alpha / SubStation Alpha v4) parsing.

struct ASSStyle: Equatable, Sendable {
    var name: String
    var bold = false
    var italic = false
    var underline = false
    /// Numpad alignment (already converted from SSA numbering for [V4 Styles]).
    var alignment: Int?

    var inline: InlineStyle { InlineStyle(bold: bold, italic: italic, underline: underline) }
}

/// What the parsers need from an ASS/SSA header ([Script Info] + styles + [Events] Format).
struct ASSHeaderInfo: Sendable {
    var styles: [String: ASSStyle] = [:]
    var isSSA = false
    var title: String?
    var eventFormat: [String]?
    /// Everything before the [Events] line.
    var headerText: String?

    func style(named raw: String?) -> ASSStyle? {
        guard var name = raw?.trimmingCharacters(in: .whitespaces), !name.isEmpty else {
            return styles["Default"]
        }
        if let s = styles[name] { return s }
        if name.hasPrefix("*") { name.removeFirst() }
        if let s = styles[name] { return s }
        let lower = name.lowercased()
        if let match = styles.first(where: { $0.key.lowercased() == lower }) { return match.value }
        return styles["Default"]
    }
}

struct ASSOverrideContext {
    var style: InlineStyle
    /// Style defaults restored by "\i", "\b", "\u" without argument and by "\r".
    var base: InlineStyle
    /// First \an / \a in the line wins (as in VSFilter/libass).
    var alignment: Int?
    var drawing = false
    var styles: [String: ASSStyle] = [:]

    init(style: InlineStyle, base: InlineStyle) {
        self.style = style
        self.base = base
    }
}

enum ASSOverrides {
    /// Converts SSA "\aN" alignment numbering (1-3 bottom, +4 top, +8 middle) to numpad.
    static func numpad(fromSSA value: Int) -> Int? {
        guard value > 0 else { return nil }
        let h = value & 3
        guard h != 0 else { return nil }
        if value & 4 != 0 { return 6 + h }
        if value & 8 != 0 { return 3 + h }
        return h
    }

    /// Applies one override block's content (between '{' and '}') to `ctx`.
    static func apply(_ block: ArraySlice<Unicode.Scalar>, to ctx: inout ASSOverrideContext) {
        // Split into "\tag" tokens at parenthesis depth 0.
        var tokens: [String] = []
        var current: String.UnicodeScalarView?
        var depth = 0
        for c in block {
            if c == "(" { depth += 1 }
            if c == ")" { depth = max(0, depth - 1) }
            if c == "\\" && depth == 0 {
                if let t = current { tokens.append(String(t)) }
                current = String.UnicodeScalarView()
                continue
            }
            current?.append(c)
        }
        if let t = current { tokens.append(String(t)) }

        for raw in tokens {
            let token = raw.trimmingCharacters(in: .whitespaces)
            guard let first = token.unicodeScalars.first else { continue }
            let rest = String(token.unicodeScalars.dropFirst())
            switch first {
            case "a":
                if rest.hasPrefix("n"), let n = Int(rest.dropFirst()), (1...9).contains(n) {
                    if ctx.alignment == nil { ctx.alignment = n }
                } else if let n = Int(rest), let mapped = numpad(fromSSA: n) {
                    if ctx.alignment == nil { ctx.alignment = mapped }
                }
            case "i":
                if rest.isEmpty { ctx.style.italic = ctx.base.italic } else if let n = Int(rest) { ctx.style.italic = n != 0 }
            case "u":
                if rest.isEmpty { ctx.style.underline = ctx.base.underline } else if let n = Int(rest) { ctx.style.underline = n != 0 }
            case "b":
                if rest.isEmpty {
                    ctx.style.bold = ctx.base.bold
                } else if let n = Int(rest) {
                    ctx.style.bold = n == 1 || n >= 600
                }
            case "p":
                if let n = Int(rest) { ctx.drawing = n > 0 }
            case "r":
                let name = rest.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty, let s = ctx.styles[name] {
                    ctx.style = s.inline
                } else {
                    ctx.style = ctx.base
                }
            default:
                break
            }
        }
    }
}

enum ASSParser {
    static let defaultASSEventFormat = ["layer", "start", "end", "style", "name", "marginl", "marginr", "marginv", "effect", "text"]
    static let defaultSSAEventFormat = ["marked", "start", "end", "style", "name", "marginl", "marginr", "marginv", "effect", "text"]
    static let defaultASSStyleFormat = ["name", "fontname", "fontsize", "primarycolour", "secondarycolour", "outlinecolour",
                                        "backcolour", "bold", "italic", "underline", "strikeout", "scalex", "scaley",
                                        "spacing", "angle", "borderstyle", "outline", "shadow", "alignment", "marginl",
                                        "marginr", "marginv", "encoding"]
    static let defaultSSAStyleFormat = ["name", "fontname", "fontsize", "primarycolour", "secondarycolour", "tertiarycolour",
                                        "backcolour", "bold", "italic", "borderstyle", "outline", "shadow", "alignment",
                                        "marginl", "marginr", "marginv", "alphalevel", "encoding"]

    /// Splits `body` into exactly `count` comma-separated fields; the last field keeps the
    /// remainder (ASS Text may contain commas). Returns fewer fields if the line is short.
    static func splitFields<S: StringProtocol>(_ body: S, count: Int) -> [Substring] {
        var fields: [Substring] = []
        let str = Substring(body)
        var start = str.startIndex
        var i = str.startIndex
        while i < str.endIndex && fields.count < count - 1 {
            if str[i] == "," {
                fields.append(str[start..<i])
                start = str.index(after: i)
            }
            i = str.index(after: i)
        }
        fields.append(str[start..<str.endIndex])
        return fields
    }

    static func parseFormat<S: StringProtocol>(_ body: S) -> [String] {
        body.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
    }

    private static func lineValue(_ line: Substring, key: String) -> Substring? {
        guard line.count > key.count else { return nil }
        let head = line.prefix(key.count)
        guard head.lowercased() == key.lowercased() else { return nil }
        return line.dropFirst(key.count)
    }

    /// Parses an ASS/SSA header (a full file or a Matroska CodecPrivate).
    static func parseHeader(_ text: String) -> ASSHeaderInfo {
        parse(lines: TextLines.split(text), collectEvents: false).info
    }

    /// Parses a complete ASS/SSA script. Cues are in file order (not yet normalised).
    static func parse(_ text: String) -> SubtitleDocument {
        let result = parse(lines: TextLines.split(text), collectEvents: true)
        return SubtitleDocument(format: result.info.isSSA ? .ssa : .ass, cues: result.cues,
                                language: nil, title: result.info.title, header: result.info.headerText)
    }

    private static func parse(lines: [Substring], collectEvents: Bool) -> (info: ASSHeaderInfo, cues: [SubtitleCue]) {
        var info = ASSHeaderInfo()
        var section = ""
        var headerLines: [Substring] = []
        var inHeader = true
        var styleFormat: [String]?
        var scriptTypeSSA: Bool?
        var sawV4Plus = false, sawV4 = false
        var dialogues: [(start: TimeInterval, end: TimeInterval, style: String, text: String)] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                section = trimmed.lowercased()
                switch section {
                case "[events]": inHeader = false
                case "[v4 styles]": sawV4 = true
                case "[v4+ styles]", "[v4 styles+]": sawV4Plus = true
                default: break
                }
                if inHeader { headerLines.append(line) }
                continue
            }
            if inHeader { headerLines.append(line) }
            let body = Substring(trimmed)
            switch section {
            case "[script info]":
                if let v = lineValue(body, key: "Title:") {
                    let t = v.trimmingCharacters(in: .whitespaces)
                    if !t.isEmpty { info.title = t }
                } else if let v = lineValue(body, key: "ScriptType:") {
                    let t = v.trimmingCharacters(in: .whitespaces).lowercased()
                    scriptTypeSSA = !t.contains("+")
                }
            case "[v4 styles]", "[v4+ styles]", "[v4 styles+]":
                let legacy = section == "[v4 styles]"
                if let v = lineValue(body, key: "Format:") {
                    styleFormat = parseFormat(v)
                } else if let v = lineValue(body, key: "Style:") {
                    let format = styleFormat ?? (legacy ? defaultSSAStyleFormat : defaultASSStyleFormat)
                    if let style = parseStyle(v, format: format, legacyAlignment: legacy) {
                        info.styles[style.name] = style
                    }
                }
            case "[events]":
                if let v = lineValue(body, key: "Format:") {
                    info.eventFormat = parseFormat(v)
                } else if collectEvents, let v = lineValue(body, key: "Dialogue:") {
                    let ssa = sawV4 && !sawV4Plus
                    let format = info.eventFormat ?? (ssa ? defaultSSAEventFormat : defaultASSEventFormat)
                    if let d = parseDialogue(v, format: format) {
                        dialogues.append(d)
                    } else {
                        dialogues.append((-1, -1, "", "")) // keeps "a<n>" numbering aligned with the file
                    }
                }
            default:
                break
            }
        }

        info.isSSA = sawV4Plus ? false : (sawV4 || scriptTypeSSA == true)
        var header = headerLines.joined(separator: "\n")
        while let last = header.unicodeScalars.last, last.properties.isWhitespace { header.unicodeScalars.removeLast() }
        info.headerText = header.isEmpty ? nil : header + "\n"

        var cues: [SubtitleCue] = []
        for (n, d) in dialogues.enumerated() where d.start >= 0 {
            let style = info.style(named: d.style)
            guard let converted = convertDialogueText(d.text, style: style, styles: info.styles) else { continue }
            let hint = CueStyleHint(alignment: converted.alignment ?? style?.alignment,
                                    styleName: d.style.isEmpty ? nil : d.style,
                                    italic: style?.italic ?? false, bold: style?.bold ?? false)
            cues.append(SubtitleCue(id: "a\(n + 1)", index: cues.count, start: d.start, end: max(d.start, d.end),
                                    text: converted.text, rawText: d.text, style: hint))
        }
        return (info, cues)
    }

    private static func parseStyle(_ body: Substring, format: [String], legacyAlignment: Bool) -> ASSStyle? {
        let fields = splitFields(body, count: format.count)
        func field(_ key: String) -> String? {
            guard let idx = format.firstIndex(of: key), idx < fields.count else { return nil }
            return fields[idx].trimmingCharacters(in: .whitespaces)
        }
        guard let name = field("name"), !name.isEmpty else { return nil }
        func flag(_ key: String) -> Bool {
            guard let v = field(key), let n = Int(v) else { return false }
            return n != 0
        }
        var style = ASSStyle(name: name, bold: flag("bold"), italic: flag("italic"), underline: flag("underline"))
        if let a = field("alignment").flatMap({ Int($0) }) {
            style.alignment = legacyAlignment ? ASSOverrides.numpad(fromSSA: a) : ((1...9).contains(a) ? a : nil)
        }
        return style
    }

    private static func parseDialogue(_ body: Substring, format: [String]) -> (start: TimeInterval, end: TimeInterval, style: String, text: String)? {
        let fields = splitFields(body, count: format.count)
        guard fields.count == format.count else { return nil }
        func field(_ key: String) -> Substring? {
            guard let idx = format.firstIndex(of: key) else { return nil }
            return fields[idx]
        }
        guard let startField = field("start"), let endField = field("end"),
              let start = TimestampParser.parse(startField.utf8),
              let end = TimestampParser.parse(endField.utf8) else { return nil }
        let textField = field("text") ?? fields[fields.count - 1]
        let style = field("style").map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return (max(0, start), max(0, end), style, String(textField))
    }

    /// Converts ASS dialogue text to canonical text. Returns nil when nothing visible remains
    /// (empty lines, pure drawing-mode lines). Override handling: {\i1}/{\i0} -> <i>, {\b1} -> <b>,
    /// {\u1} -> <u>, {\anN}/{\aN} -> alignment, \p1 drawings dropped, \N \n -> newline, \h -> space,
    /// every other override and {comment} removed. Style italic/bold are applied as tags too.
    static func convertDialogueText(_ raw: String, style: ASSStyle?, styles: [String: ASSStyle]) -> (text: String, alignment: Int?)? {
        let s = Array(raw.unicodeScalars)
        let base = style?.inline ?? InlineStyle()
        var ctx = ASSOverrideContext(style: base, base: base)
        ctx.styles = styles
        var builder = StyledTextBuilder()
        var i = 0
        while i < s.count {
            let c = s[i]
            if c == "{", let close = s[(i + 1)...].firstIndex(of: "}") {
                if s[(i + 1)..<close].contains("\\") {
                    ASSOverrides.apply(s[(i + 1)..<close], to: &ctx)
                }
                i = close + 1
                continue
            }
            if c == "\\" && i + 1 < s.count {
                let n = s[i + 1]
                if n == "N" || n == "n" {
                    builder.newline()
                    i += 2
                    continue
                }
                if n == "h" {
                    if !ctx.drawing { builder.append(" ", style: ctx.style) }
                    i += 2
                    continue
                }
            }
            if c == "\n" {
                builder.newline()
            } else if !ctx.drawing {
                builder.append(c, style: ctx.style)
            }
            i += 1
        }
        let text = builder.build()
        guard !text.isEmpty else { return nil }
        return (text, ctx.alignment)
    }
}
