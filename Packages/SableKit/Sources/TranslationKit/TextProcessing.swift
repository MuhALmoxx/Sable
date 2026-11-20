import Foundation
import SubtitleKit

// OWNER: translation agent.

/// Source-side text preparation shared by every provider.
public enum TranslationText {
    /// Text handed to providers for one cue: "\n" line breaks, trimmed lines, collapsed spaces,
    /// no bidi controls, only <i>/<b> inline tags (underline is dropped; it is rare in dialogue
    /// and providers handle two tag kinds more reliably).
    public static func unitText(for cue: SubtitleCue) -> String {
        var text = TextCleanup.normalizeNewlines(cue.text)
        text = TextCleanup.removeBidiControls(text)
        text = text.replacingOccurrences(of: "</?[uU]>", with: "", options: .regularExpression)
        return TextCleanup.tidyLines(text)
    }

    /// True when the cue contains at least one letter. Cues without letters (empty, "♪ ♪",
    /// "...", "- -") pass through unchanged and are never sent to a provider.
    public static func needsTranslation(_ text: String) -> Bool {
        let plain = TextCleanup.stripInlineTags(text)
        return plain.unicodeScalars.contains { CharacterSet.letters.contains($0) }
    }

    /// Plain text (no tags) used for lookups and line-length measurement.
    public static func plain(_ text: String) -> String { TextCleanup.stripInlineTags(text) }
}

/// Low-level helpers (internal API kept public for the app's mock/on-device providers).
public enum TextCleanup {
    /// Bidi formatting controls that must never be stored in a translation: LRM, RLM, ALM,
    /// embeddings/overrides (LRE…RLO, PDF), isolates (LRI…PDI) and the BOM.
    public static let bidiControls: Set<Unicode.Scalar> = [
        "\u{200E}", "\u{200F}", "\u{061C}", "\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}",
        "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}", "\u{FEFF}",
    ]

    public static func removeBidiControls(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for s in text.unicodeScalars where !bidiControls.contains(s) { scalars.append(s) }
        return String(scalars)
    }

    /// CRLF/CR -> LF; a literal backslash-n (or ASS "\N") written by a model -> LF.
    public static func normalizeNewlines(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\N", with: "\n")
    }

    /// Trims every line, collapses runs of spaces/tabs (and NBSP) to one space, drops empty lines.
    public static func tidyLines(_ text: String) -> String {
        text.components(separatedBy: "\n")
            .map { line -> String in
                var out = ""
                var lastWasSpace = false
                for ch in line {
                    let isSpace = ch == " " || ch == "\t" || ch == "\u{00A0}" || ch == "\u{2007}" || ch == "\u{202F}"
                    if isSpace {
                        if !lastWasSpace { out.append(" ") }
                        lastWasSpace = true
                    } else {
                        out.append(ch)
                        lastWasSpace = false
                    }
                }
                return out.trimmingCharacters(in: .whitespaces)
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    public static func stripInlineTags(_ text: String) -> String {
        text.replacingOccurrences(of: "</?[ibuIBU]>", with: "", options: .regularExpression)
    }

    /// "< i >", "<I>", "</ I>" -> canonical lowercase tags.
    public static func canonicalizeTags(_ text: String) -> String {
        guard text.contains("<") else { return text }
        let regex = try? NSRegularExpression(pattern: "<\\s*(/?)\\s*([ibuIBU])\\s*>")
        guard let regex else { return text }
        let ns = text as NSString
        var result = ""
        var last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let slash = ns.substring(with: match.range(at: 1))
            let name = ns.substring(with: match.range(at: 2)).lowercased()
            result += "<\(slash)\(name)>"
            last = match.range.location + match.range.length
        }
        result += ns.substring(from: last)
        return result
    }

    /// True when <i>/<b>/<u> tags are properly nested and closed.
    public static func tagsBalanced(_ text: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: "<(/?)([ibu])>") else { return true }
        let ns = text as NSString
        var stack: [String] = []
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let closing = ns.substring(with: match.range(at: 1)) == "/"
            let name = ns.substring(with: match.range(at: 2))
            if closing {
                guard stack.last == name else { return false }
                stack.removeLast()
            } else {
                stack.append(name)
            }
        }
        return stack.isEmpty
    }

    /// Removes "<i></i>", "<b> </b>" and similar empty pairs.
    public static func removeEmptyTagPairs(_ text: String) -> String {
        var current = text
        while true {
            let next = current.replacingOccurrences(of: "<([ibu])>\\s*</\\1>", with: "", options: .regularExpression)
            if next == current { return current }
            current = next
        }
    }

    /// When the source line is wrapped entirely in one tag (e.g. "<i>Is it safe?</i>") and the
    /// translation lost all tags, re-wrap the translation in the same tag.
    public static func restoreWholeLineTag(_ translated: String, source: String) -> String {
        guard !translated.contains("<") else { return translated }
        let s = source.trimmingCharacters(in: .whitespacesAndNewlines)
        for tag in ["i", "b"] {
            let open = "<\(tag)>", close = "</\(tag)>"
            guard s.hasPrefix(open), s.hasSuffix(close), s.count > open.count + close.count else { continue }
            let inner = String(s.dropFirst(open.count).dropLast(close.count))
            if !inner.contains("<") { return open + translated + close }
        }
        return translated
    }

    /// Visible character count (tags excluded).
    public static func visibleLength(_ text: String) -> Int { stripInlineTags(text).count }

    /// Caps text to two lines. More than two lines are merged and rebalanced; a line longer
    /// than `maxLineLength` is broken on the space nearest the middle. Dialogue lines that all
    /// start with a dash are kept as separate speakers (only lines past the second are merged).
    public static func capLines(_ text: String, maxLineLength: Int) -> String {
        var lines = text.components(separatedBy: "\n").filter { !$0.isEmpty }
        guard !lines.isEmpty else { return "" }
        let isDialogue = lines.count >= 2 && lines.allSatisfy { line in
            let plain = stripInlineTags(line)
            return plain.hasPrefix("-") || plain.hasPrefix("–") || plain.hasPrefix("—")
        }
        if lines.count > 2 {
            if isDialogue {
                lines = [lines[0], lines[1...].joined(separator: " ")]
            } else {
                let joined = lines.joined(separator: " ")
                return visibleLength(joined) <= maxLineLength ? joined : splitInTwo(joined).joined(separator: "\n")
            }
        }
        if isDialogue { return lines.joined(separator: "\n") }
        if lines.count == 1 {
            return visibleLength(lines[0]) > maxLineLength ? splitInTwo(lines[0]).joined(separator: "\n") : lines[0]
        }
        // Two lines: rebalance only when one is too long.
        if visibleLength(lines[0]) > maxLineLength || visibleLength(lines[1]) > maxLineLength {
            return splitInTwo(lines.joined(separator: " ")).joined(separator: "\n")
        }
        return lines.joined(separator: "\n")
    }

    /// Splits on the space that best balances the two visible halves (never inside a tag).
    static func splitInTwo(_ text: String) -> [String] {
        let chars = Array(text)
        var visibleBefore: [Int] = Array(repeating: 0, count: chars.count + 1)
        var inTag = false
        var count = 0
        for (i, ch) in chars.enumerated() {
            visibleBefore[i] = count
            if ch == "<" { inTag = true }
            if !inTag { count += 1 }
            if ch == ">" { inTag = false }
        }
        visibleBefore[chars.count] = count
        let total = count
        var best: Int?
        var bestScore = Int.max
        inTag = false
        for (i, ch) in chars.enumerated() {
            if ch == "<" { inTag = true }
            if ch == ">" { inTag = false; continue }
            guard ch == " ", !inTag else { continue }
            let left = visibleBefore[i]
            let right = total - left - 1
            let score = max(left, right)
            if score < bestScore { bestScore = score; best = i }
        }
        guard let split = best else { return [text] }
        let left = String(chars[..<split]).trimmingCharacters(in: .whitespaces)
        let right = String(chars[(split + 1)...]).trimmingCharacters(in: .whitespaces)
        return [left, right].filter { !$0.isEmpty }
    }

    // MARK: Script detection

    public static func isArabicLetter(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x0620...0x064A, 0x066E...0x06D3, 0x06D5, 0x06EE...0x06EF, 0x06FA...0x06FC, 0x06FF,
             0x0750...0x077F, 0x08A0...0x08FF, 0xFB50...0xFDFF, 0xFE70...0xFEFC:
            return true
        default:
            return false
        }
    }

    public static func containsArabicLetter(_ text: String) -> Bool { text.unicodeScalars.contains(where: isArabicLetter) }

    /// Words containing at least one Latin letter.
    public static func latinWordCount(_ text: String) -> Int {
        stripInlineTags(text)
            .split(whereSeparator: { $0 == " " || $0 == "\n" })
            .filter { word in word.unicodeScalars.contains { ($0.value >= 0x41 && $0.value <= 0x5A) || ($0.value >= 0x61 && $0.value <= 0x7A) } }
            .count
    }
}

// MARK: - Target post-processing

/// Post-processing applied to every translated line before it is stored. Dispatches on the
/// target language; Arabic has its own rules, other targets get the generic cleanup.
public enum TranslationPostProcessor {
    public static func process(_ text: String, source: String, target: TargetLanguageProfile) -> String {
        switch target.code.primary {
        case "ar": return ArabicPostProcessor.process(text, source: source, maxLineLength: target.maxLineLength)
        default: return generic(text, source: source, maxLineLength: target.maxLineLength)
        }
    }

    /// Whitespace, bidi controls, tag balance, two-line cap.
    public static func generic(_ text: String, source: String, maxLineLength: Int) -> String {
        var out = TextCleanup.normalizeNewlines(text)
        out = TextCleanup.removeBidiControls(out)
        out = TextCleanup.tidyLines(out)
        out = balanceTags(out)
        out = TextCleanup.restoreWholeLineTag(out, source: source)
        out = TextCleanup.capLines(out, maxLineLength: maxLineLength)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func balanceTags(_ text: String) -> String {
        var out = TextCleanup.canonicalizeTags(text)
        if !TextCleanup.tagsBalanced(out) { out = TextCleanup.stripInlineTags(out) }
        out = TextCleanup.removeEmptyTagPairs(out)
        return TextCleanup.tidyLines(out)
    }
}

/// Arabic-specific cleanup: Arabic punctuation, spacing around it, plus the generic steps.
public enum ArabicPostProcessor {
    public static func process(_ text: String, source: String, maxLineLength: Int = 42) -> String {
        var out = TextCleanup.normalizeNewlines(text)
        out = TextCleanup.removeBidiControls(out)
        out = TextCleanup.tidyLines(out)
        out = TranslationPostProcessor.balanceTags(out)
        out = out.components(separatedBy: "\n").map(normalizePunctuation).joined(separator: "\n")
        out = TextCleanup.tidyLines(out)
        out = TextCleanup.restoreWholeLineTag(out, source: source)
        out = TextCleanup.capLines(out, maxLineLength: maxLineLength)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// ASCII ? , ; -> ؟ ، ؛ on lines that contain Arabic, except inside tags, URLs/e-mail
    /// addresses and numbers ("1,000", "3;4"). Removes spaces before ، ؛ ؟ ! and adds a space
    /// after ، ؛ when a letter follows directly.
    public static func normalizePunctuation(_ line: String) -> String {
        guard TextCleanup.containsArabicLetter(line) else { return line }
        let tokens = line.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        let converted = tokens.map { token -> String in
            if isURLLike(token) { return token }
            let chars = Array(token)
            var out = ""
            var inTag = false
            for (i, ch) in chars.enumerated() {
                if ch == "<" { inTag = true }
                if inTag {
                    out.append(ch)
                    if ch == ">" { inTag = false }
                    continue
                }
                let prevDigit = i > 0 && chars[i - 1].isNumber
                let nextDigit = i + 1 < chars.count && chars[i + 1].isNumber
                switch ch {
                case "?": out.append("؟")
                case ",": out.append(prevDigit && nextDigit ? "," : "،")
                case ";": out.append(prevDigit && nextDigit ? ";" : "؛")
                default: out.append(ch)
                }
            }
            return out
        }
        // Spacing around Arabic punctuation.
        var chars = Array(converted.joined(separator: " "))
        var result: [Character] = []
        result.reserveCapacity(chars.count + 4)
        let tight: Set<Character> = ["،", "؛", "؟", "!"]
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if ch == " " {
                // Drop spaces directly before tight punctuation.
                var j = i
                while j < chars.count, chars[j] == " " { j += 1 }
                if j < chars.count, tight.contains(chars[j]), !result.isEmpty {
                    i = j
                    continue
                }
            }
            result.append(ch)
            if ch == "،" || ch == "؛", i + 1 < chars.count {
                let next = chars[i + 1]
                if next.isLetter { result.append(" ") }
            }
            i += 1
        }
        chars = result
        return String(chars)
    }

    static func isURLLike(_ token: String) -> Bool {
        let lower = token.lowercased()
        if lower.contains("://") || lower.hasPrefix("www.") { return true }
        if lower.contains("@"), lower.contains(".") { return true }
        return false
    }
}
