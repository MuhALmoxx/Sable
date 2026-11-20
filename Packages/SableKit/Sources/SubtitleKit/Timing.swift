import Foundation

/// Timing correction applied to a subtitle track at display/export time.
///
///     effective = original * scale + offset
///
/// `offset` > 0 means subtitles appear LATER than their original timestamps; < 0 means EARLIER.
/// `scale` corrects gradual drift (frame-rate mismatch) and is 1 unless the user sets two
/// sync points. Original cue timestamps are never modified.
public struct SubtitleTiming: Codable, Hashable, Sendable {
    public var offset: TimeInterval
    public var scale: Double

    public init(offset: TimeInterval = 0, scale: Double = 1) {
        self.offset = offset
        self.scale = scale
    }

    public static let identity = SubtitleTiming()

    public var isIdentity: Bool { abs(offset) < 0.0005 && abs(scale - 1) < 1e-9 }

    /// Original subtitle time -> video playback time.
    public func effective(_ original: TimeInterval) -> TimeInterval { original * scale + offset }

    /// Video playback time -> original subtitle time.
    public func original(forEffective effective: TimeInterval) -> TimeInterval {
        (effective - offset) / (scale == 0 ? 1 : scale)
    }

    public func effectiveStart(of cue: SubtitleCue) -> TimeInterval { effective(cue.start) }
    public func effectiveEnd(of cue: SubtitleCue) -> TimeInterval { effective(cue.end) }

    /// Returns a copy with `offset` shifted by `delta`, rounded to the millisecond to avoid
    /// floating point creep from repeated ±0.1 s taps.
    public func shifted(by delta: TimeInterval) -> SubtitleTiming {
        SubtitleTiming(offset: ((offset + delta) * 1000).rounded() / 1000, scale: scale)
    }
}

/// Pure math behind guided synchronisation.
public enum SyncMath {
    /// offset = marked speech start − original selected cue start (for scale == 1).
    /// With a drift scale already set, keeps the scale and solves for the offset:
    /// marked = cueStart * scale + offset.
    public static func timing(markedSpeechStart: TimeInterval, originalCueStart: TimeInterval,
                              keepingScale scale: Double = 1) -> SubtitleTiming {
        let raw = markedSpeechStart - originalCueStart * scale
        return SubtitleTiming(offset: (raw * 1000).rounded() / 1000, scale: scale)
    }

    /// Two-point (linear) correction for drift: maps cue A's original start to markA and cue B's
    /// to markB. Returns nil when the points are too close (< 1 s apart in either domain) or the
    /// resulting scale is implausible (outside 0.9...1.1).
    public static func twoPointTiming(markA: TimeInterval, cueStartA: TimeInterval,
                                      markB: TimeInterval, cueStartB: TimeInterval) -> SubtitleTiming? {
        let dOriginal = cueStartB - cueStartA
        let dMarked = markB - markA
        guard abs(dOriginal) >= 1, abs(dMarked) >= 1 else { return nil }
        let scale = dMarked / dOriginal
        guard scale >= 0.9, scale <= 1.1 else { return nil }
        let offset = markA - cueStartA * scale
        return SubtitleTiming(offset: (offset * 1000).rounded() / 1000, scale: scale)
    }

    /// Every cue whose EFFECTIVE interval (with the currently applied `timing`) overlaps
    /// [markedTime − window, markedTime + window], in dialogue order. `window == .infinity`
    /// returns every cue.
    public static func candidateCues(_ cues: [SubtitleCue], around markedTime: TimeInterval,
                                     window: TimeInterval, timing: SubtitleTiming) -> [SubtitleCue] {
        guard window.isFinite else { return cues }
        let lower = markedTime - window
        let upper = markedTime + window
        return cues.filter { cue in
            let s = timing.effective(cue.start)
            let e = max(s, timing.effective(cue.end))
            return e >= lower && s <= upper
        }
    }

    /// Full-text search across cues (case/diacritic-insensitive), in dialogue order. Searches
    /// both `primary` text and, when provided, an `original` text lookup by cue id (so English
    /// can be searched while an Arabic translation is active).
    public static func search(_ cues: [SubtitleCue], query: String, originalTextByID: [String: String] = [:]) -> [SubtitleCue] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return cues }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return cues.filter { cue in
            if cue.plainText.range(of: q, options: options) != nil { return true }
            if let original = originalTextByID[cue.id], original.range(of: q, options: options) != nil { return true }
            return false
        }
    }
}

/// Fast lookup of the cues visible at a playback time. Build once per document; O(log n + k).
public struct CueIndex: Sendable {
    public let cues: [SubtitleCue]
    private let maxDuration: TimeInterval

    public init(cues: [SubtitleCue]) {
        self.cues = cues.sorted { ($0.start, $0.index) < ($1.start, $1.index) }
        self.maxDuration = cues.map(\.duration).max() ?? 0
    }

    /// Cues visible at `playbackTime` under `timing`, ordered by start (overlapping dialogue
    /// returns several cues).
    public func activeCues(at playbackTime: TimeInterval, timing: SubtitleTiming = .identity) -> [SubtitleCue] {
        guard !cues.isEmpty else { return [] }
        let t = timing.original(forEffective: playbackTime)
        // First cue whose start > t.
        var lo = 0
        var hi = cues.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if cues[mid].start <= t { lo = mid + 1 } else { hi = mid }
        }
        var result: [SubtitleCue] = []
        var i = lo - 1
        while i >= 0 {
            let cue = cues[i]
            if t - cue.start > maxDuration { break }
            if cue.start <= t && t < cue.end { result.append(cue) }
            i -= 1
        }
        return result.reversed()
    }

    /// The next cue that starts strictly after `playbackTime` (for "jump to next line").
    public func nextCue(after playbackTime: TimeInterval, timing: SubtitleTiming = .identity) -> SubtitleCue? {
        let t = timing.original(forEffective: playbackTime)
        return cues.first { $0.start > t + 0.001 }
    }

    /// The last cue that started before `playbackTime`.
    public func previousCue(before playbackTime: TimeInterval, timing: SubtitleTiming = .identity) -> SubtitleCue? {
        let t = timing.original(forEffective: playbackTime)
        return cues.last { $0.start < t - 0.001 }
    }
}
