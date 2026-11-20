import Foundation
import SubtitleKit

// OWNER: library agent.

/// Pure helpers for file names: titles, unique names, subtitle language guessing, file kinds.
public enum LibraryFileNaming {
    // MARK: File kinds

    public enum FileKind: Equatable, Sendable {
        case video, subtitle, unknown
    }

    /// Extensions Sable treats as video (AVFoundation or VLC can usually play them).
    public static let videoExtensions: Set<String> = [
        "mp4", "m4v", "mov", "qt", "mkv", "mk3d", "webm", "avi", "divx", "xvid", "wmv", "asf", "flv", "f4v",
        "ts", "m2ts", "mts", "m2t", "tp", "trp", "mpg", "mpeg", "mpe", "m1v", "m2v", "mp2v", "vob", "ogv", "ogm",
        "3gp", "3g2", "rm", "rmvb", "mxf", "dv", "nut", "y4m", "h264", "264", "hevc", "h265", "265",
    ]

    /// Extensions of subtitle files Sable can attach.
    public static let subtitleExtensions: Set<String> = ["srt", "vtt", "webvtt", "ass", "ssa"]

    public static func kind(ofFileExtension ext: String) -> FileKind {
        let e = ext.lowercased()
        if subtitleExtensions.contains(e) { return .subtitle }
        if videoExtensions.contains(e) { return .video }
        return .unknown
    }

    // MARK: Titles

    /// "The.Night_Roof.2024.mkv" -> "The Night Roof 2024". Falls back to the raw base name.
    public static func title(fromFileName fileName: String) -> String {
        let base = (fileName as NSString).deletingPathExtension
        let cleaned = cleanTitle(base)
        if !cleaned.isEmpty { return cleaned }
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fileName : trimmed
    }

    /// Replaces dots/underscores with spaces and collapses runs of whitespace.
    public static func cleanTitle(_ raw: String) -> String {
        let replaced = raw.replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: "_", with: " ")
        return replaced.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    // MARK: Unique names

    /// Makes a file name safe to store: strips path separators, control characters and leading dots.
    public static func sanitizedFileName(_ name: String, fallbackExtension: String = "") -> String {
        var cleaned = String(name.unicodeScalars.map { scalar -> Character in
            if scalar == "/" || scalar == ":" || scalar == "\\" { return "-" }
            if CharacterSet.controlCharacters.contains(scalar) { return " " }
            return Character(scalar)
        })
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        // ".mkv" is all extension: give it a base name instead of hiding it.
        if cleaned.hasPrefix("."), !cleaned.dropFirst().contains("."), cleaned.count > 1 { cleaned = "file" + cleaned }
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        if (cleaned as NSString).deletingPathExtension.trimmingCharacters(in: .whitespaces).isEmpty {
            cleaned = "file" + (fallbackExtension.isEmpty ? "" : ".\(fallbackExtension)")
        }
        // Keep names comfortably below the 255-byte file system limit.
        if cleaned.utf8.count > 200 {
            let ext = (cleaned as NSString).pathExtension
            var base = (cleaned as NSString).deletingPathExtension
            while base.utf8.count > 180 { base.removeLast() }
            cleaned = ext.isEmpty ? base : "\(base).\(ext)"
        }
        return cleaned
    }

    /// "name.mkv" if free, otherwise "name (2).mkv", "name (3).mkv", …
    public static func uniqueFileName(_ desired: String, isTaken: (String) -> Bool) -> String {
        if !isTaken(desired) { return desired }
        let ns = desired as NSString
        let ext = ns.pathExtension
        let base = ns.deletingPathExtension
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
            if !isTaken(candidate) { return candidate }
            n += 1
        }
    }

    /// File-system-safe rendering of a track id ("tr:ar:emb:mkv:3" -> "tr_ar_emb_mkv_3").
    public static func safeComponent(_ id: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        return String(id.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
    }

    // MARK: Subtitle language

    /// Guesses the language from a subtitle file name suffix:
    /// "movie.ar.srt" -> ar, "movie.eng.srt" -> en, "movie.en-US.srt" -> en-US,
    /// "movie.en.forced.srt" -> en, "Movie_English.srt" -> en. Returns nil when nothing matches.
    public static func guessLanguage(fromFileName fileName: String) -> LanguageCode? {
        var base = fileName
        if subtitleExtensions.contains((fileName as NSString).pathExtension.lowercased()) {
            base = (fileName as NSString).deletingPathExtension
        }
        let components = base.split(separator: ".", omittingEmptySubsequences: true).map(String.init)
        if components.count >= 2 {
            // Inspect up to three trailing components, skipping flags like "forced"/"sdh".
            var candidates: [LanguageCode] = []
            var inspected = 0
            for component in components.dropFirst().reversed() {
                guard inspected < 3 else { break }
                inspected += 1
                let lower = component.lowercased()
                if flagComponents.contains(lower) || lower.allSatisfy(\.isNumber) { continue }
                if let code = languageTag(component) {
                    candidates.append(code)
                    // "movie.en.hi.srt": "hi" is the hearing-impaired flag when a language precedes it.
                    if lower == "hi" { continue }
                    break
                }
                break
            }
            if let first = candidates.first {
                if first.rawValue == "hi", candidates.count > 1 { return candidates[1] }
                return first
            }
        }
        // "Movie_English", "movie-eng", "Movie Arabic": only unambiguous tokens after a separator.
        guard let last = components.last else { return nil }
        let tokens = last.split(whereSeparator: { $0 == "_" || $0 == "-" || $0 == " " }).map(String.init)
        guard tokens.count >= 2 else { return nil }
        for token in tokens.reversed().prefix(2) {
            let lower = token.lowercased()
            if flagComponents.contains(lower) { continue }
            if let name = languageNames[lower] { return LanguageCode.normalized(name) }
            if lower.count == 3, let two = threeLetterCodes[lower] ?? normalizedTwoLetter(lower) {
                return LanguageCode.normalized(two)
            }
            if lower.count == 2, separatorSafeTwoLetter.contains(lower) { return LanguageCode.normalized(lower) }
            return nil
        }
        return nil
    }

    /// Parses one component as a BCP-47-ish tag. Region/script subtags keep canonical casing.
    static func languageTag(_ component: String) -> LanguageCode? {
        let lower = component.lowercased()
        if let name = languageNames[lower] { return LanguageCode.normalized(name) }
        let parts = component.split(whereSeparator: { $0 == "-" || $0 == "_" }).map(String.init)
        guard let primaryRaw = parts.first?.lowercased(), !primaryRaw.isEmpty else { return nil }
        let primary: String
        if primaryRaw.count == 2, iso639_1.contains(primaryRaw) {
            primary = primaryRaw
        } else if primaryRaw.count == 3, let two = threeLetterCodes[primaryRaw] ?? normalizedTwoLetter(primaryRaw) {
            primary = two
        } else {
            return nil
        }
        guard let normalizedPrimary = LanguageCode.normalized(primary)?.rawValue else { return nil }
        var tag = normalizedPrimary
        for sub in parts.dropFirst() {
            if sub.count == 2, sub.allSatisfy(\.isLetter) {
                tag += "-" + sub.uppercased()
            } else if sub.count == 4, sub.allSatisfy(\.isLetter) {
                tag += "-" + sub.prefix(1).uppercased() + sub.dropFirst().lowercased()
            } else if sub.count == 3, sub.allSatisfy(\.isNumber) {
                tag += "-" + sub
            } else {
                break
            }
        }
        return LanguageCode(tag)
    }

    /// Three-letter codes `LanguageCode.normalized` maps to two letters.
    private static func normalizedTwoLetter(_ three: String) -> String? {
        guard let code = LanguageCode.normalized(three), code.rawValue.count == 2 else { return nil }
        return code.rawValue
    }

    private static let flagComponents: Set<String> = [
        "forced", "sdh", "cc", "default", "full", "signs", "songs", "hearing", "impaired", "sub", "subs", "subtitle",
        "subtitles", "track", "commentary",
    ]

    private static let separatorSafeTwoLetter: Set<String> = [
        "ar", "en", "fr", "es", "de", "pt", "ru", "ja", "ko", "zh", "tr", "fa", "ur", "nl", "sv", "pl", "el",
        "cs", "fi", "hu", "uk", "vi", "th",
    ]

    private static let languageNames: [String: String] = [
        "english": "en", "arabic": "ar", "french": "fr", "spanish": "es", "german": "de", "italian": "it",
        "portuguese": "pt", "russian": "ru", "japanese": "ja", "korean": "ko", "chinese": "zh", "turkish": "tr",
        "hebrew": "he", "persian": "fa", "farsi": "fa", "urdu": "ur", "hindi": "hi", "dutch": "nl",
        "swedish": "sv", "polish": "pl", "indonesian": "id", "greek": "el", "czech": "cs", "danish": "da",
        "finnish": "fi", "hungarian": "hu", "romanian": "ro", "ukrainian": "uk", "vietnamese": "vi",
        "thai": "th", "norwegian": "no", "malay": "ms",
    ]

    /// ISO 639-2 (B and T) codes beyond the ones `LanguageCode.normalized` already maps.
    private static let threeLetterCodes: [String: String] = [
        "ces": "cs", "cze": "cs", "dan": "da", "ell": "el", "gre": "el", "fin": "fi", "hun": "hu",
        "ron": "ro", "rum": "ro", "slk": "sk", "slo": "sk", "slv": "sl", "srp": "sr", "hrv": "hr",
        "bul": "bg", "ukr": "uk", "vie": "vi", "tha": "th", "msa": "ms", "may": "ms", "nor": "no",
        "nob": "nb", "nno": "nn", "cat": "ca", "eus": "eu", "baq": "eu", "glg": "gl", "lit": "lt",
        "lav": "lv", "est": "et", "isl": "is", "ice": "is", "ben": "bn", "tam": "ta", "tel": "te",
        "mal": "ml", "mar": "mr", "kan": "kn", "guj": "gu", "pan": "pa", "sin": "si", "khm": "km",
        "lao": "lo", "mya": "my", "bur": "my", "kat": "ka", "geo": "ka", "hye": "hy", "arm": "hy",
        "aze": "az", "kaz": "kk", "uzb": "uz", "mon": "mn", "nep": "ne", "tgl": "tl", "swa": "sw",
        "afr": "af", "alb": "sq", "sqi": "sq", "mac": "mk", "mkd": "mk", "bos": "bs", "wel": "cy",
        "cym": "cy", "gle": "ga", "kur": "ku", "pus": "ps", "snd": "sd", "uig": "ug", "yid": "yi",
        "amh": "am", "som": "so", "hau": "ha", "yor": "yo", "ibo": "ig", "zul": "zu", "xho": "xh",
    ]

    private static let iso639_1: Set<String> = Set("""
    aa ab ae af ak am an ar as av ay az ba be bg bh bi bm bn bo br bs ca ce ch co cr cs cu cv cy da de dv dz \
    ee el en eo es et eu fa ff fi fj fo fr fy ga gd gl gn gu gv ha he hi ho hr ht hu hy hz ia id ie ig ii ik \
    io is it iu ja jv ka kg ki kj kk kl km kn ko kr ks ku kv kw ky la lb lg li ln lo lt lu lv mg mh mi mk ml \
    mn mr ms mt my na nb nd ne ng nl nn no nr nv ny oc oj om or os pa pi pl ps pt qu rm rn ro ru rw sa sc sd \
    se sg si sk sl sm sn so sq sr ss st su sv sw ta te tg th ti tk tl tn to tr ts tt tw ty ug uk ur uz ve vi \
    vo wa wo xh yi yo za zh zu
    """.split(separator: " ").map(String.init))
}
