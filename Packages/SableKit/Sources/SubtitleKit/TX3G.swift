import Foundation

// OWNER: subtitles-core agent.
/// MP4 3GPP timed text ("tx3g"/"mov_text") sample decoding. The app reads samples with
/// AVAssetReader; this pure function turns one sample's bytes into display text.
public enum TX3GDecoder {
    /// Sample layout: UInt16 big-endian text length, UTF-8 (or UTF-16 with BOM) text, then
    /// optional style boxes (ignored). Returns nil for empty samples (gaps between cues).
    /// A length larger than the sample is clamped; CRLF/CR become "\n"; trailing newlines and
    /// whitespace-only text yield nil.
    public static func decodeSample(_ data: Data) -> String? {
        let bytes = [UInt8](data)
        guard bytes.count >= 2 else { return nil }
        let declared = Int(bytes[0]) << 8 | Int(bytes[1])
        guard declared > 0 else { return nil }
        let end = min(bytes.count, 2 + declared)
        let body = bytes[2..<end]
        guard !body.isEmpty else { return nil }

        var text: String
        if body.starts(with: [0xFE, 0xFF]) {
            text = TextDecoding.decodeUTF16(body.dropFirst(2), bigEndian: true)
        } else if body.starts(with: [0xFF, 0xFE]) {
            text = TextDecoding.decodeUTF16(body.dropFirst(2), bigEndian: false)
        } else if body.starts(with: [0xEF, 0xBB, 0xBF]) {
            text = String(decoding: body.dropFirst(3), as: UTF8.self)
        } else if TextDecoding.isValidUTF8(body) {
            text = String(decoding: body, as: UTF8.self)
        } else {
            text = TextDecoding.decode(body, legacy: TextDecoding.detectLegacyEncoding(Array(body)))
        }
        text = TextLines.normalize(text)
        while let last = text.unicodeScalars.last, last == "\n" || last == "\0" { text.unicodeScalars.removeLast() }
        guard text.unicodeScalars.contains(where: { !StyledTextBuilder.isInvisible($0) && $0 != "\0" }) else { return nil }
        return text
    }
}
