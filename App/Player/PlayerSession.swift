import SwiftUI
import SubtitleKit
import LibraryKit

// OWNER: playback agent. The API below is the contract consumed by the Sync and Translation
// features; bodies are stubs to replace. Keep names/signatures (add freely).

/// Subtitle track currently loaded for display.
struct LoadedSubtitleTrack {
    let descriptor: SubtitleTrackDescriptor
    let document: SubtitleDocument
    let index: CueIndex
    /// For a translated track: the source document (same cue ids/timestamps), so the original
    /// English line stays available. nil otherwise.
    let originalDocument: SubtitleDocument?
}

/// A cue ready to draw (timing already applied by the session).
struct DisplayCue: Identifiable, Equatable {
    let id: String
    let text: String
    /// Source-language line when a translation is shown and the style asks for it.
    let originalText: String?
    let isRightToLeft: Bool
    let style: CueStyleHint?
}

enum SubtitleLoadState: Equatable {
    case idle
    case loading(progress: Double?)
    case failed(String)
}

@Observable
@MainActor
final class PlayerSession {
    enum Status: Equatable {
        case idle, loading, ready, ended
        case failed(String)
    }

    let services: AppServices
    let itemID: UUID
    private(set) var item: MediaItem
    let mediaURL: URL

    private(set) var status: Status = .idle
    private(set) var engineKind: PlaybackEngineKind?
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var isPlaying = false
    private(set) var isBuffering = false
    var rate: Float = 1

    private(set) var audioTracks: [AudioTrackInfo] = []
    private(set) var selectedAudioTrackID: String?

    /// Every subtitle track for this video: embedded (text + image), external and translated.
    private(set) var subtitleTracks: [SubtitleTrackDescriptor] = []
    /// nil = subtitles off.
    private(set) var activeSubtitle: LoadedSubtitleTrack?
    private(set) var subtitleLoadState: SubtitleLoadState = .idle
    /// Cues visible right now (updated ~30×/s while playing and immediately after seeks/timing changes).
    private(set) var visibleCues: [DisplayCue] = []

    /// Timing for the active track's timing group (shared by a source track and its translations).
    private(set) var timing: SubtitleTiming = .identity
    private(set) var canUndoTiming = false

    var subtitleStyle: SubtitleStyle = .default
    var aspectMode: AspectMode = .fit
    private(set) var isPictureInPictureSupported = false

    /// The engine's rendering view (nil until loaded).
    private(set) var engineView: UIView?

    init(item: MediaItem, services: AppServices) {
        self.services = services
        self.itemID = item.id
        self.item = item
        self.mediaURL = services.library.mediaURL(for: item)
    }

    /// Chooses an engine, loads media, restores position/tracks/style, starts playback.
    func start() async {}

    func play() {}
    func pause() {}
    func togglePlayPause() {}
    func seek(to seconds: TimeInterval) async {}
    func skip(by delta: TimeInterval) {}
    func setRate(_ rate: Float) {}

    func selectAudioTrack(_ id: String) {}
    /// nil turns subtitles off. Loads (extracting embedded text if needed) and persists the choice.
    func selectSubtitleTrack(_ id: String?) async {}
    /// Re-reads the track list (after importing a file or finishing a translation).
    func reloadSubtitleTracks() async {}
    /// Imports an external SRT/VTT/ASS/SSA file for this video and selects it.
    func importExternalSubtitle(from url: URL) async throws {}

    /// Loads any track's document (used by translation for the source track).
    func document(for trackID: String) async throws -> SubtitleDocument {
        throw SubtitleError.notImplemented("PlayerSession.document(for:)")
    }

    // MARK: Timing (applies immediately; persisted per video + timing group)

    func setTiming(_ timing: SubtitleTiming, undoable: Bool = true) {}
    func nudgeOffset(by delta: TimeInterval) {}
    func undoTiming() {}
    func resetTiming() {}

    /// When the active track is a translation: source text by cue id. Empty otherwise.
    func originalTextByCueID() -> [String: String] { [:] }

    func togglePictureInPicture() {}
    func setAspectMode(_ mode: AspectMode) {}
    func updateSubtitleStyle(_ style: SubtitleStyle) {}

    /// Saves position/tracks now (called on background, close and periodically).
    func persistNow() {}
    func tearDown() {}
}
