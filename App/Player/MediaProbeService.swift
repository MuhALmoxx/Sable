import Foundation
import CoreGraphics
import SubtitleKit

// OWNER: playback agent.

struct MediaProbeResult: Sendable {
    var duration: TimeInterval?
    var container: ContainerKind
    var preferredEngine: PlaybackEngineKind
    var videoSize: CGSize?
    var subtitleTracks: [SubtitleTrackDescriptor]
    /// Human-readable problem (unsupported/inaccessible) or nil.
    var issue: String?
}

@MainActor
final class MediaProbeService {
    init() {}

    /// Container sniffing, AVFoundation playability, duration and embedded subtitle tracks
    /// (Matroska via SubtitleKit.MatroskaReader, MP4 text tracks via AVFoundation).
    func probe(url: URL) async -> MediaProbeResult {
        MediaProbeResult(duration: nil, container: .other, preferredEngine: .vlc, videoSize: nil, subtitleTracks: [], issue: nil)
    }
}
