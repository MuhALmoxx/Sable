import Foundation

// OWNER: subtitles-core agent.
// Byte -> String decoding for subtitle files. Foundation on Linux has no Windows-1256 constant,
// so the single-byte legacy code pages are decoded with our own tables.

/// Single-byte legacy encodings tried when the bytes are not valid UTF-8.
enum LegacyEncoding: Equatable, Sendable {
    /// Arabic (Windows-1256).
    case windows1256
    /// Western European (Windows-1252).
    case windows1252
    /// ISO-8859-1 (used when the bytes contain positions Windows-1252 leaves undefined).
    case isoLatin1
}

enum TextDecoding {
    /// Decodes subtitle bytes: BOM-marked UTF-8/UTF-16/UTF-32, BOM-less UTF-16 (detected from
    /// NUL-byte patterns), valid UTF-8, then Windows-1256 when the bytes read as plausible
    /// Arabic, else Windows-1252, else ISO-8859-1. Throws `.unreadableEncoding` for binary data.
    static func decode(_ input: [UInt8]) throws -> String {
        if input.starts(with: [0xEF, 0xBB, 0xBF]) {
            return String(decoding: input.dropFirst(3), as: UTF8.self)
        }
        if input.starts(with: [0xFF, 0xFE, 0x00, 0x00]) { return decodeUTF32(input.dropFirst(4), bigEndian: false) }
        if input.starts(with: [0x00, 0x00, 0xFE, 0xFF]) { return decodeUTF32(input.dropFirst(4), bigEndian: true) }
        if input.starts(with: [0xFF, 0xFE]) { return decodeUTF16(input.dropFirst(2), bigEndian: false) }
        if input.starts(with: [0xFE, 0xFF]) { return decodeUTF16(input.dropFirst(2), bigEndian: true) }

        if input.contains(0), let bigEndian = guessBOMLessUTF16(input) {
            var text = decodeUTF16(input[...], bigEndian: bigEndian)
            while text.unicodeScalars.last == "\0" { text.unicodeScalars.removeLast() }
            return text
        }

        var bytes = input
        while bytes.last == 0 { bytes.removeLast() }
        if bytes.isEmpty { return "" }

        if bytes.contains(0) {
            var nulCount = 0
            for b in bytes where b == 0 { nulCount += 1 }
            // More than a stray NUL or two: this is a binary file, not text.
            if nulCount * 100 > bytes.count || nulCount > 64 { throw SubtitleError.unreadableEncoding }
            bytes.removeAll { $0 == 0 }
        }

        if isValidUTF8(bytes) { return String(decoding: bytes, as: UTF8.self) }

        // UTF-8 with a few bad bytes (a stray Windows-1252 byte in a credit line, a file cut in
        // the middle of a character): keep it UTF-8, bad bytes becoming U+FFFD, instead of turning
        // every Arabic line of the file into Windows-1252 mojibake.
        if isMostlyUTF8(bytes) {
            let text = String(decoding: bytes, as: UTF8.self)
            if looksBinary(text) { throw SubtitleError.unreadableEncoding }
            return text
        }

        let text = decode(bytes, legacy: detectLegacyEncoding(bytes))
        if looksBinary(text) { throw SubtitleError.unreadableEncoding }
        return text
    }

    // MARK: Unicode

    static func isValidUTF8<C: Collection>(_ bytes: C) -> Bool where C.Element == UInt8 {
        var asciiOnly = true
        for b in bytes where b >= 0x80 { asciiOnly = false; break }
        if asciiOnly { return true }
        var iterator = bytes.makeIterator()
        var decoder = UTF8()
        while true {
            switch decoder.decode(&iterator) {
            case .scalarValue: continue
            case .emptyInput: return true
            case .error: return false
            }
        }
    }

    /// True when invalid sequences are rare next to valid multi-byte UTF-8 ones (at most one per
    /// ten). Single-byte code pages produce the opposite: Windows-1256 Arabic or Persian and
    /// Windows-1252 Western text yield far more invalid sequences than valid multi-byte ones.
    static func isMostlyUTF8(_ bytes: [UInt8]) -> Bool {
        var iterator = bytes.makeIterator()
        var decoder = UTF8()
        var multibyte = 0, errors = 0
        while true {
            switch decoder.decode(&iterator) {
            case let .scalarValue(scalar): if scalar.value >= 0x80 { multibyte += 1 }
            case .emptyInput: return errors > 0 && multibyte >= errors * 10
            case .error: errors += 1
            }
        }
    }

    static func decodeUTF16(_ bytes: ArraySlice<UInt8>, bigEndian: Bool) -> String {
        var units: [UInt16] = []
        units.reserveCapacity(bytes.count / 2)
        var i = bytes.startIndex
        while i + 1 < bytes.endIndex {
            let a = UInt16(bytes[i]), b = UInt16(bytes[i + 1])
            units.append(bigEndian ? (a << 8 | b) : (b << 8 | a))
            i += 2
        }
        return String(decoding: units, as: UTF16.self)
    }

    static func decodeUTF32(_ bytes: ArraySlice<UInt8>, bigEndian: Bool) -> String {
        var scalars = String.UnicodeScalarView()
        var i = bytes.startIndex
        while i + 3 < bytes.endIndex {
            let b0 = UInt32(bytes[i]), b1 = UInt32(bytes[i + 1]), b2 = UInt32(bytes[i + 2]), b3 = UInt32(bytes[i + 3])
            let value = bigEndian ? (b0 << 24 | b1 << 16 | b2 << 8 | b3) : (b3 << 24 | b2 << 16 | b1 << 8 | b0)
            scalars.append(Unicode.Scalar(value) ?? "\u{FFFD}")
            i += 4
        }
        return String(scalars)
    }

    /// BOM-less UTF-16 shows up as text where every other byte is NUL (ASCII range).
    /// Returns true for big-endian, false for little-endian, nil when the pattern is absent.
    static func guessBOMLessUTF16(_ bytes: [UInt8]) -> Bool? {
        let sample = bytes.prefix(8192)
        guard sample.count >= 4 else { return nil }
        var zeroEven = 0, zeroOdd = 0
        for (offset, b) in sample.enumerated() where b == 0 {
            if offset % 2 == 0 { zeroEven += 1 } else { zeroOdd += 1 }
        }
        let pairs = sample.count / 2
        if zeroOdd * 4 >= pairs && zeroEven * 8 <= zeroOdd { return false }
        if zeroEven * 4 >= pairs && zeroOdd * 8 <= zeroEven { return true }
        return nil
    }

    // MARK: Legacy code pages

    static func detectLegacyEncoding(_ bytes: [UInt8]) -> LegacyEncoding {
        if looksLikeWindows1256Arabic(bytes) { return .windows1256 }
        let undefinedIn1252: Set<UInt8> = [0x81, 0x8D, 0x8F, 0x90, 0x9D]
        for b in bytes where undefinedIn1252.contains(b) { return .isoLatin1 }
        return .windows1252
    }

    static func decode<C: Collection>(_ bytes: C, legacy: LegacyEncoding) -> String where C.Element == UInt8 {
        var scalars = String.UnicodeScalarView()
        for b in bytes {
            if b < 0x80 {
                scalars.append(Unicode.Scalar(b))
                continue
            }
            let value: UInt32
            switch legacy {
            case .windows1256: value = windows1256[Int(b) - 0x80]
            case .windows1252: value = windows1252[Int(b) - 0x80]
            case .isoLatin1: value = UInt32(b)
            }
            scalars.append(Unicode.Scalar(value) ?? "\u{FFFD}")
        }
        return String(scalars)
    }

    /// Windows-1256 wins when the high bytes mostly (>= 2/3) decode to Arabic letters or harakat that sit
    /// next to other Arabic letters, spaces or punctuation — not glued to Latin letters, which is
    /// what accented Western text (ä, ß, á…) looks like when misread as 1256.
    static func looksLikeWindows1256Arabic(_ bytes: [UInt8]) -> Bool {
        func isLatinLetter(_ b: UInt8) -> Bool {
            if (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) { return true }
            guard b >= 0x80 else { return false }
            let v = windows1256[Int(b) - 0x80]
            return (0x00C0...0x024F).contains(v) && v != 0x00D7 && v != 0x00F7
        }
        func isArabicLetter(_ b: UInt8) -> Bool {
            guard b >= 0x80 else { return false }
            let v = windows1256[Int(b) - 0x80]
            return (0x0621...0x064A).contains(v) || (0x0671...0x06D3).contains(v)
        }
        /// Harakat (fatha, damma, kasra, shadda, sukun, tanween): fully vocalised text has about
        /// one per letter, so they count as Arabic too (and, like letters, must not touch Latin).
        func isArabicMark(_ b: UInt8) -> Bool {
            guard b >= 0x80 else { return false }
            return (0x064B...0x0652).contains(windows1256[Int(b) - 0x80])
        }
        var high = 0, letters = 0, arabic = 0, glued = 0
        for i in bytes.indices where bytes[i] >= 0x80 {
            high += 1
            let isLetter = isArabicLetter(bytes[i])
            guard isLetter || isArabicMark(bytes[i]) else { continue }
            if isLetter { letters += 1 }
            arabic += 1
            let before = i > bytes.startIndex && isLatinLetter(bytes[i - 1])
            let after = i + 1 < bytes.endIndex && isLatinLetter(bytes[i + 1])
            if before || after { glued += 1 }
        }
        return letters >= 1 && glued * 10 <= arabic && arabic * 3 >= high * 2
    }

    /// True when more than 5% of the text is C0 control characters (other than tab, newlines and
    /// form feed) or DEL: a binary file opened as text. Random bytes score about 10%; real
    /// subtitle text scores ~0. (C1 controls are not counted: ISO-8859-1 decoding produces them.)
    static func looksBinary(_ text: String) -> Bool {
        var total = 0, control = 0
        for s in text.unicodeScalars.prefix(16384) {
            total += 1
            let v = s.value
            if (v < 0x20 && v != 0x09 && v != 0x0A && v != 0x0D && v != 0x0C) || v == 0x7F {
                control += 1
            }
        }
        return total > 0 && control * 20 > total
    }

    /// Windows-1256 (Arabic), bytes 0x80...0xFF.
    static let windows1256: [UInt32] = [
        0x20AC, 0x067E, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
        0x02C6, 0x2030, 0x0679, 0x2039, 0x0152, 0x0686, 0x0698, 0x0688,
        0x06AF, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
        0x06A9, 0x2122, 0x0691, 0x203A, 0x0153, 0x200C, 0x200D, 0x06BA,
        0x00A0, 0x060C, 0x00A2, 0x00A3, 0x00A4, 0x00A5, 0x00A6, 0x00A7,
        0x00A8, 0x00A9, 0x06BE, 0x00AB, 0x00AC, 0x00AD, 0x00AE, 0x00AF,
        0x00B0, 0x00B1, 0x00B2, 0x00B3, 0x00B4, 0x00B5, 0x00B6, 0x00B7,
        0x00B8, 0x00B9, 0x061B, 0x00BB, 0x00BC, 0x00BD, 0x00BE, 0x061F,
        0x06C1, 0x0621, 0x0622, 0x0623, 0x0624, 0x0625, 0x0626, 0x0627,
        0x0628, 0x0629, 0x062A, 0x062B, 0x062C, 0x062D, 0x062E, 0x062F,
        0x0630, 0x0631, 0x0632, 0x0633, 0x0634, 0x0635, 0x0636, 0x00D7,
        0x0637, 0x0638, 0x0639, 0x063A, 0x0640, 0x0641, 0x0642, 0x0643,
        0x00E0, 0x0644, 0x00E2, 0x0645, 0x0646, 0x0647, 0x0648, 0x00E7,
        0x00E8, 0x00E9, 0x00EA, 0x00EB, 0x0649, 0x064A, 0x00EE, 0x00EF,
        0x064B, 0x064C, 0x064D, 0x064E, 0x00F4, 0x064F, 0x0650, 0x00F7,
        0x0651, 0x00F9, 0x0652, 0x00FB, 0x00FC, 0x200E, 0x200F, 0x06D2,
    ]

    /// Windows-1252 (Western), bytes 0x80...0xFF. The five positions Windows-1252 leaves
    /// undefined (0x81, 0x8D, 0x8F, 0x90, 0x9D) map to the C1 control of the same value.
    static let windows1252: [UInt32] = [
        0x20AC, 0x0081, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
        0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x008D, 0x017D, 0x008F,
        0x0090, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
        0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x009D, 0x017E, 0x0178,
        0x00A0, 0x00A1, 0x00A2, 0x00A3, 0x00A4, 0x00A5, 0x00A6, 0x00A7,
        0x00A8, 0x00A9, 0x00AA, 0x00AB, 0x00AC, 0x00AD, 0x00AE, 0x00AF,
        0x00B0, 0x00B1, 0x00B2, 0x00B3, 0x00B4, 0x00B5, 0x00B6, 0x00B7,
        0x00B8, 0x00B9, 0x00BA, 0x00BB, 0x00BC, 0x00BD, 0x00BE, 0x00BF,
        0x00C0, 0x00C1, 0x00C2, 0x00C3, 0x00C4, 0x00C5, 0x00C6, 0x00C7,
        0x00C8, 0x00C9, 0x00CA, 0x00CB, 0x00CC, 0x00CD, 0x00CE, 0x00CF,
        0x00D0, 0x00D1, 0x00D2, 0x00D3, 0x00D4, 0x00D5, 0x00D6, 0x00D7,
        0x00D8, 0x00D9, 0x00DA, 0x00DB, 0x00DC, 0x00DD, 0x00DE, 0x00DF,
        0x00E0, 0x00E1, 0x00E2, 0x00E3, 0x00E4, 0x00E5, 0x00E6, 0x00E7,
        0x00E8, 0x00E9, 0x00EA, 0x00EB, 0x00EC, 0x00ED, 0x00EE, 0x00EF,
        0x00F0, 0x00F1, 0x00F2, 0x00F3, 0x00F4, 0x00F5, 0x00F6, 0x00F7,
        0x00F8, 0x00F9, 0x00FA, 0x00FB, 0x00FC, 0x00FD, 0x00FE, 0x00FF,
    ]
}

/// Line handling shared by the text parsers.
enum TextLines {
    /// Drops BOMs (a leading one, and stray ones left by concatenated files) and converts
    /// CRLF / lone CR to LF.
    static func normalize(_ text: String) -> String {
        // Fast path: no CR and no byte that could start U+FEFF (EF BB BF).
        var needsWork = false
        for b in text.utf8 where b == 13 || b == 0xEF { needsWork = true; break }
        guard needsWork else { return text }
        var out = String.UnicodeScalarView()
        var previousWasCR = false
        for u in text.unicodeScalars {
            if u == "\u{FEFF}" { continue }
            if u == "\r" {
                out.append("\n")
                previousWasCR = true
                continue
            }
            if u == "\n" && previousWasCR {
                previousWasCR = false
                continue
            }
            previousWasCR = false
            out.append(u)
        }
        return String(out)
    }

    /// Normalises newlines and splits into lines (empty lines kept).
    static func split(_ text: String) -> [Substring] {
        let s = normalize(text)
        var result: [Substring] = []
        var lineStart = s.startIndex
        var i = s.utf8.startIndex
        while i != s.utf8.endIndex {
            if s.utf8[i] == 10 {
                result.append(s[lineStart..<i])
                lineStart = s.utf8.index(after: i)
            }
            i = s.utf8.index(after: i)
        }
        result.append(s[lineStart..<s.endIndex])
        return result
    }

    static func isBlank<S: StringProtocol>(_ line: S) -> Bool {
        line.unicodeScalars.allSatisfy { $0.properties.isWhitespace }
    }

    static func trimmed<S: StringProtocol>(_ line: S) -> String {
        line.trimmingCharacters(in: .whitespaces)
    }
}
