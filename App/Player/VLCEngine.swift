import UIKit
import QuartzCore
import AVFoundation
import MobileVLCKit
import SubtitleKit
import LibraryKit

// OWNER: playback agent. MobileVLCKit 3.7.5 engine for everything AVFoundation can't play
// (MKV, WebM, AVI, …). VLC's own subtitle renderer stays off: Sable draws text subtitles itself.
// Only image-based tracks (PGS/VobSub) are handed to VLC via `setNativeSubtitle`.
// VLCKit 3 has no Picture in Picture API, so this engine doesn't offer PiP.

/// The drawable VLC renders into. VLC adds its own video subview; touches are left to SwiftUI.
final class VLCSurfaceView: UIView {
    var onLayout: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
}

@MainActor
final class VLCEngine: NSObject, PlaybackEngine {
    let kind: PlaybackEngineKind = .vlc
    var onEvent: ((PlaybackEngineEvent) -> Void)?
    var view: UIView { surface }

    private let surface = VLCSurfaceView()
    private let player: VLCMediaPlayer
    private let aspectRatioString = CStringHolder()
    private let cropGeometryString = CStringHolder()
    private var appliedAspect: String?
    private var appliedCrop: String?
    private var lastLayoutSize: CGSize = .zero

    private var nativeSubtitleOrdinal: Int?
    private var nativeSubtitleDelay: TimeInterval = 0

    private var knownDuration: TimeInterval = 0
    private var desiredRate: Float = 1
    private var reportedPlaying = false
    private var reportedBuffering = false
    private var isLoaded = false
    private var isShutDown = false
    private var didReachEnd = false
    /// Restart of a finished input in progress (shared by concurrent seeks).
    private var restartTask: Task<Void, Never>?
    /// Audio track to select again after a finished input was reopened.
    private var pendingAudioReselect: String?
    private var initialAudioTrackID: String?

    private var audioSessionObservers: [NSObjectProtocol] = []

    // Smooth clock: VLC reports time a few times per second; interpolate between reports.
    // `fromRaw` is VLC's reported time when the seek was issued: the seek counts as applied only
    // once VLC reports a different time (it reports nothing at all while paused).
    private var pendingSeek: (target: TimeInterval, issuedAt: CFTimeInterval, fromRaw: TimeInterval)?
    private var clockAnchor: (media: TimeInterval, host: CFTimeInterval)?
    private var lastReturnedTime: TimeInterval = 0

    private(set) var audioTracks: [AudioTrackInfo] = []
    private(set) var selectedAudioTrackID: String?

    var aspectMode: AspectMode = .fit {
        didSet { applyAspect() }
    }

    override init() {
        player = VLCMediaPlayer()
        super.init()
        player.delegate = self
        player.drawable = surface
        surface.onLayout = { [weak self] in self?.surfaceDidLayout() }
        observeAudioSession()
    }

    /// AVPlayer pauses by itself when headphones/AirPods disconnect or a call/Siri interrupts the
    /// audio session; VLCKit doesn't (VLC's own app does it at app level). Without this, VLC keeps
    /// playing out loud through the speaker, or silently through a phone call.
    private func observeAudioSession() {
        let center = NotificationCenter.default
        audioSessionObservers = [
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] notification in
                guard let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                      reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
                Task { @MainActor [weak self] in self?.pauseForAudioSession() }
            },
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
                guard let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      type == AVAudioSession.InterruptionType.began.rawValue else { return }
                Task { @MainActor [weak self] in self?.pauseForAudioSession() }
            },
        ]
    }

    private func pauseForAudioSession() {
        guard !isShutDown, player.isPlaying else { return }
        player.pause()
    }

    // MARK: Loading

    func load(url: URL, startAt: TimeInterval) async throws {
        let media = VLCMedia(url: url)
        // Sable manages subtitle files itself; don't let VLC pick up sidecar files.
        media.addOption(":no-sub-autodetect-file")
        if startAt > 0.05 {
            media.addOption(":start-time=\(String(format: "%.3f", startAt))")
        }
        player.media = media
        PlaybackAudioSession.activate()
        player.play()

        let deadline = CACurrentMediaTime() + 25
        waiting: while true {
            try Task.checkCancellation()
            let state = player.state
            if state == .playing || player.isPlaying {
                break waiting
            }
            if state == .error {
                throw PlayerError("VLC couldn't open this file. It may be damaged or use a codec VLC can't decode.")
            }
            if state == .ended {
                // Extremely short or truncated file: treat as loaded; the end event follows.
                break waiting
            }
            if CACurrentMediaTime() > deadline {
                throw PlayerError("VLC took too long to open this file.")
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        isLoaded = true
        enforceSubtitleSelection()
        refreshAudioTracks()
        applyAspect()
        player.rate = desiredRate
        knownDuration = mediaLength()
        onEvent?(.ready(duration: knownDuration))
        reportBuffering(false)
        reportPlaying(player.isPlaying)
    }

    // MARK: Delegate handling

    fileprivate func stateChanged() {
        guard !isShutDown else { return }
        let state = player.state
        if state == .playing {
            didReachEnd = false
            if let id = pendingAudioReselect {
                pendingAudioReselect = nil
                if let value = Int32(id) {
                    player.currentAudioTrackIndex = value
                    selectedAudioTrackID = id
                }
            }
            reportBuffering(false)
            reportPlaying(true)
            enforceSubtitleSelection()
            if audioTracks.isEmpty { refreshAudioTracks() }
            updateDuration()
        } else if state == .paused || state == .stopped {
            reportBuffering(false)
            reportPlaying(false)
        } else if state == .ended {
            reportBuffering(false)
            reportPlaying(false)
            if isLoaded && !didReachEnd {
                didReachEnd = true
                onEvent?(.ended)
            }
        } else if state == .error {
            reportPlaying(false)
            if isLoaded {
                onEvent?(.failed("VLC stopped playing: the file couldn't be decoded any further."))
            }
        } else if state == .buffering {
            reportBuffering(!player.isPlaying)
        } else if state == .opening {
            reportBuffering(true)
        } else {
            // Elementary stream added: tracks may have changed and VLC may have auto-selected
            // a subtitle track that we must switch off again.
            refreshAudioTracks()
            enforceSubtitleSelection()
        }
    }

    fileprivate func timeChanged() {
        guard !isShutDown else { return }
        updateDuration()
        if audioTracks.isEmpty { refreshAudioTracks() }
        if nativeSubtitleOrdinal == nil && player.currentVideoSubTitleIndex != -1 {
            player.currentVideoSubTitleIndex = -1
        }
    }

    private func reportPlaying(_ playing: Bool) {
        guard playing != reportedPlaying else { return }
        reportedPlaying = playing
        if !playing { clockAnchor = nil }
        onEvent?(.playingChanged(playing))
    }

    private func reportBuffering(_ buffering: Bool) {
        guard buffering != reportedBuffering else { return }
        reportedBuffering = buffering
        onEvent?(.bufferingChanged(buffering))
    }

    private func updateDuration() {
        let length = mediaLength()
        guard length > 0, abs(length - knownDuration) > 0.01 else { return }
        knownDuration = length
        if isLoaded { onEvent?(.ready(duration: length)) }
    }

    private func mediaLength() -> TimeInterval {
        guard let value = player.media?.length.value else { return 0 }
        return max(0, value.doubleValue / 1000)
    }

    private func rawTime() -> TimeInterval {
        guard let value = player.time.value else { return 0 }
        return max(0, value.doubleValue / 1000)
    }

    // MARK: Tracks

    private func refreshAudioTracks() {
        let indexes = (player.audioTrackIndexes as? [NSNumber]) ?? []
        let names = (player.audioTrackNames as? [String]) ?? []
        let languages = trackLanguages(ofType: VLCMediaTracksInformationTypeAudio)
        var tracks: [AudioTrackInfo] = []
        for (position, number) in indexes.enumerated() {
            let trackID = number.int32Value
            guard trackID != -1 else { continue } // "Disable"
            var title = position < names.count ? names[position] : ""
            if title.trimmingCharacters(in: .whitespaces).isEmpty { title = "Track \(tracks.count + 1)" }
            tracks.append(AudioTrackInfo(id: String(trackID), title: title, language: languages[trackID], isDefault: false))
        }
        let current = player.currentAudioTrackIndex
        let selected: String? = current == -1 ? nil : String(current)
        if initialAudioTrackID == nil, let selected { initialAudioTrackID = selected }
        tracks = tracks.map {
            AudioTrackInfo(id: $0.id, title: $0.title, language: $0.language, isDefault: $0.id == initialAudioTrackID)
        }
        guard tracks != audioTracks || selected != selectedAudioTrackID else { return }
        audioTracks = tracks
        selectedAudioTrackID = selected
        onEvent?(.audioTracksChanged)
    }

    /// ES id -> language from VLCMedia.tracksInformation.
    private func trackLanguages(ofType type: String) -> [Int32: LanguageCode] {
        guard let infos = player.media?.tracksInformation as? [[String: Any]] else { return [:] }
        var result: [Int32: LanguageCode] = [:]
        for info in infos {
            guard (info[VLCMediaTracksInformationType] as? String) == type,
                  let id = info[VLCMediaTracksInformationId] as? NSNumber,
                  let language = LanguageCode.normalized(info[VLCMediaTracksInformationLanguage] as? String) else { continue }
            result[id.int32Value] = language
        }
        return result
    }

    func selectAudioTrack(id: String) {
        guard let value = Int32(id) else { return }
        player.currentAudioTrackIndex = value
        selectedAudioTrackID = id
    }

    func setNativeSubtitle(streamOrdinal: Int?, delay: TimeInterval) {
        nativeSubtitleOrdinal = streamOrdinal
        nativeSubtitleDelay = delay
        enforceSubtitleSelection()
    }

    /// Keeps VLC's renderer off unless an image-based track was requested; then selects the Nth
    /// subtitle ES (excluding the "Disable" -1 entry) and applies the delay in microseconds.
    private func enforceSubtitleSelection() {
        let ids = ((player.videoSubTitlesIndexes as? [NSNumber]) ?? []).map(\.int32Value).filter { $0 != -1 }
        if let ordinal = nativeSubtitleOrdinal, ids.indices.contains(ordinal) {
            let target = ids[ordinal]
            if player.currentVideoSubTitleIndex != target { player.currentVideoSubTitleIndex = target }
            let microseconds = Int((nativeSubtitleDelay * 1_000_000).rounded())
            if player.currentVideoSubTitleDelay != microseconds { player.currentVideoSubTitleDelay = microseconds }
        } else if player.currentVideoSubTitleIndex != -1 {
            player.currentVideoSubTitleIndex = -1
        }
    }

    // MARK: Transport

    func play() {
        guard !isShutDown else { return }
        PlaybackAudioSession.activate()
        if didReachEnd || player.state == .ended {
            restartFinishedInput()
            return
        }
        didReachEnd = false
        player.play()
        player.rate = desiredRate
    }

    /// MobileVLCKit 3 does not reliably reopen an input that reached Ended with `play()` alone
    /// (the picture stays on the last frame); VLC for iOS re-assigns the media. The user's audio
    /// choice is re-applied once the reopened input is playing.
    private func restartFinishedInput() {
        pendingAudioReselect = selectedAudioTrackID
        let media = player.media
        player.stop()
        if let media { player.media = media }
        didReachEnd = false
        PlaybackAudioSession.activate()
        player.play()
        player.rate = desiredRate
    }

    func pause() {
        guard !isShutDown else { return }
        player.pause()
    }

    func seek(to seconds: TimeInterval) async {
        guard !isShutDown, player.media != nil else { return }
        let target = max(0, seconds)
        let state = player.state
        if restartTask != nil || didReachEnd || state == .ended || state == .stopped {
            // VLC can't seek a finished input: restart it, then jump. Rapid seeks (several
            // skip-back taps after the end) share one restart instead of racing each other.
            if restartTask == nil {
                restartFinishedInput()
                restartTask = Task { @MainActor [weak self] in
                    let deadline = CACurrentMediaTime() + 10
                    while let self, !self.isShutDown, !self.player.isPlaying, CACurrentMediaTime() < deadline {
                        try? await Task.sleep(nanoseconds: 50_000_000)
                    }
                }
            }
            await restartTask?.value
            restartTask = nil
            guard !isShutDown else { return }
        }
        let fromRaw = rawTime()
        pendingSeek = (target, CACurrentMediaTime(), fromRaw)
        clockAnchor = nil
        player.time = VLCTime(number: NSNumber(value: Int64((target * 1000).rounded())))
        // Give VLC a moment to apply the jump so time reads are consistent afterwards. While
        // paused VLC publishes no time, so there is nothing to wait for (currentTime keeps the target).
        guard player.isPlaying else { return }
        for _ in 0..<20 {
            let raw = rawTime()
            if raw != fromRaw && abs(raw - target) < 0.75 { break }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
    }

    func scrub(to seconds: TimeInterval) {
        guard !isShutDown, player.media != nil, !didReachEnd else { return }
        let target = max(0, seconds)
        pendingSeek = (target, CACurrentMediaTime(), rawTime())
        clockAnchor = nil
        player.time = VLCTime(number: NSNumber(value: Int64((target * 1000).rounded())))
    }

    var currentTime: TimeInterval {
        let now = CACurrentMediaTime()
        let raw = rawTime()
        if let pending = pendingSeek {
            // Applied once VLC reports a new time near the target. Comparing against the pre-seek
            // time alone would accept a short seek (< 0.75 s) before VLC even ran it, snapping the
            // clock back. Paused, VLC reports nothing, so the target stands until playback resumes.
            let reported = raw != pending.fromRaw
            if reported && (abs(raw - pending.target) < 0.75 || (player.isPlaying && now - pending.issuedAt > 1.5)) {
                pendingSeek = nil
                clockAnchor = nil
            } else {
                lastReturnedTime = pending.target
                return pending.target
            }
        }
        guard player.isPlaying else {
            clockAnchor = nil
            lastReturnedTime = raw
            return raw
        }
        if clockAnchor == nil || clockAnchor?.media != raw {
            clockAnchor = (raw, now)
        }
        let anchorHost = clockAnchor?.host ?? now
        var time = raw + (now - anchorHost) * Double(max(desiredRate, 0.1))
        time = min(time, raw + 0.6)
        if time < lastReturnedTime && lastReturnedTime - time < 0.3 { time = lastReturnedTime }
        lastReturnedTime = time
        return time
    }

    var duration: TimeInterval { knownDuration > 0 ? knownDuration : mediaLength() }

    var isPlaying: Bool { player.isPlaying }

    var rate: Float {
        get { desiredRate }
        set {
            desiredRate = newValue
            player.rate = newValue
        }
    }

    var presentationSize: CGSize { player.videoSize }

    // MARK: Aspect

    private func surfaceDidLayout() {
        let size = surface.bounds.size
        guard size != lastLayoutSize else { return }
        lastLayoutSize = size
        if aspectMode == .fill || aspectMode == .stretch { applyAspect() }
    }

    private func applyAspect() {
        let size = surface.bounds.size
        let viewRatio: String? = (size.width >= 1 && size.height >= 1)
            ? "\(Int(size.width.rounded())):\(Int(size.height.rounded()))" : nil
        player.scaleFactor = 0 // fit the picture to the drawable
        switch aspectMode {
        case .fit:
            setAspectRatio(nil)
            setCropGeometry(nil)
        case .fill:
            // Crop the picture to the view's ratio; fitted, it then covers the view exactly.
            setAspectRatio(nil)
            setCropGeometry(viewRatio)
        case .stretch:
            // Force the display ratio to the view's ratio; fitted, it fills the view.
            setCropGeometry(nil)
            setAspectRatio(viewRatio)
        case .ratio16x9:
            setCropGeometry(nil)
            setAspectRatio("16:9")
        case .ratio4x3:
            setCropGeometry(nil)
            setAspectRatio("4:3")
        case .ratio21x9:
            setCropGeometry(nil)
            setAspectRatio("21:9")
        }
    }

    private func setAspectRatio(_ value: String?) {
        guard value != appliedAspect else { return }
        appliedAspect = value
        aspectRatioString.assign(value) { player.videoAspectRatio = $0 }
    }

    private func setCropGeometry(_ value: String?) {
        guard value != appliedCrop else { return }
        appliedCrop = value
        cropGeometryString.assign(value) { player.videoCropGeometry = $0 }
    }

    // MARK: Picture in Picture (not available in VLCKit 3)

    var supportsPictureInPicture: Bool { false }
    var isPictureInPictureActive: Bool { false }
    func togglePictureInPicture() {}

    func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true
        onEvent = nil
        audioSessionObservers.forEach { NotificationCenter.default.removeObserver($0) }
        audioSessionObservers = []
        surface.onLayout = nil
        player.delegate = nil
        player.stop()
        player.drawable = nil
        player.media = nil
    }
}

extension VLCEngine: VLCMediaPlayerDelegate {
    @objc(mediaPlayerStateChanged:)
    nonisolated func mediaPlayerStateChanged(_ aNotification: Notification) {
        Task { @MainActor [weak self] in self?.stateChanged() }
    }

    @objc(mediaPlayerTimeChanged:)
    nonisolated func mediaPlayerTimeChanged(_ aNotification: Notification) {
        Task { @MainActor [weak self] in self?.timeChanged() }
    }
}
