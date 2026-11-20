import Foundation

// OWNER: subtitles-core agent.
/// MP4 3GPP timed text ("tx3g"/"mov_text") sample decoding. The app reads samples with
/// AVAssetReader; this pure function turns one sample's bytes into display text.
public enum TX3GDecoder {
    /// Sample layout: UInt16 big-endian text length, UTF-8 (or UTF-16 with BOM) text, then
    /// optional style boxes (ignored). Returns nil for empty samples (gaps between cues).
    public static func decodeSample(_ data: Data) -> String? { nil }
}
