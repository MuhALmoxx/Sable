import UIKit
import SubtitleKit
import LibraryKit

// OWNER: playback agent. Engine abstraction: AVFoundation for natively playable files (hardware
// decoding + system Picture in Picture), VLCKit for everything else (MKV, AVI, WebM, …).

enum PlaybackEngineKind: String, Codable, Sendable {
    case avFoundation
    case vlc

    var displayName: String { self == .avFoundation ? "AVFoundation" : "VLC" }
}

struct AudioTrackInfo: Identifiable, Hashable, Sendable {
    /// Engine-specific stable id (AVMediaSelectionOption index or VLC track index), as String.
    let id: String
    let title: String
    let language: LanguageCode?
    let isDefault: Bool
}

enum PlaybackEngineEvent: Sendable {
    case ready(duration: TimeInterval)
    case playingChanged(Bool)
    case bufferingChanged(Bool)
    case audioTracksChanged
    case ended
    case failed(String)
}

@MainActor
protocol PlaybackEngine: AnyObject {
    var kind: PlaybackEngineKind { get }
    /// The rendering surface; the player screen embeds it full-bleed.
    var view: UIView { get }
    var onEvent: ((PlaybackEngineEvent) -> Void)? { get set }

    func load(url: URL, startAt: TimeInterval) async throws
    func play()
    func pause()
    func seek(to seconds: TimeInterval) async
    var currentTime: TimeInterval { get }
    var duration: TimeInterval { get }
    var isPlaying: Bool { get }
    var rate: Float { get set }

    var audioTracks: [AudioTrackInfo] { get }
    var selectedAudioTrackID: String? { get }
    func selectAudioTrack(id: String)

    var aspectMode: AspectMode { get set }

    var supportsPictureInPicture: Bool { get }
    func togglePictureInPicture()

    /// For image-based (PGS/VobSub) tracks Sable cannot draw itself: let the engine render the
    /// embedded track natively (VLC only). `delay` applies the user's offset. nil disables.
    func setNativeSubtitle(streamOrdinal: Int?, delay: TimeInterval)

    func shutdown()
}
