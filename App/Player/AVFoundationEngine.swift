import AVFoundation
import AVKit
import UIKit
import SubtitleKit
import LibraryKit

// OWNER: playback agent. AVPlayer-based engine: hardware decoding and system Picture in Picture
// for files AVFoundation can play (MP4/MOV/M4V). Subtitles are drawn by Sable, so the legible
// media selection is always forced off.

/// Hosts the AVPlayerLayer as a sublayer so fixed display ratios can size the layer inside the
/// view; layoutSubviews keeps the layer in sync with rotation and aspect changes.
final class PlayerLayerView: UIView {
    let playerLayer = AVPlayerLayer()

    var aspectMode: AspectMode = .fit {
        didSet {
            applyGravity()
            setNeedsLayout()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true
        isUserInteractionEnabled = false
        playerLayer.backgroundColor = UIColor.black.cgColor
        layer.addSublayer(playerLayer)
        applyGravity()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = VideoGeometry.layerFrame(mode: aspectMode, in: bounds)
        CATransaction.commit()
    }

    private func applyGravity() {
        switch aspectMode {
        case .fit: playerLayer.videoGravity = .resizeAspect
        case .fill: playerLayer.videoGravity = .resizeAspectFill
        case .stretch, .ratio16x9, .ratio4x3, .ratio21x9: playerLayer.videoGravity = .resize
        }
    }
}

@MainActor
final class AVFoundationEngine: NSObject, PlaybackEngine {
    let kind: PlaybackEngineKind = .avFoundation
    var onEvent: ((PlaybackEngineEvent) -> Void)?
    var view: UIView { surface }

    private let surface = PlayerLayerView()
    private let player = AVPlayer()
    private var item: AVPlayerItem?
    private var audibleGroup: AVMediaSelectionGroup?
    private var legibleGroup: AVMediaSelectionGroup?
    private var audibleOptions: [AVMediaSelectionOption] = []
    private var itemObservations: [NSKeyValueObservation] = []
    private var playerObservations: [NSKeyValueObservation] = []
    private var notificationTokens: [NSObjectProtocol] = []
    private var pipController: AVPictureInPictureController?
    private var loadedDuration: TimeInterval = 0
    private var desiredRate: Float = 1
    private var reportedPlaying = false
    private var reportedBuffering = false
    private var isLoaded = false
    private var isShutDown = false
    private(set) var isPictureInPictureActive = false

    private(set) var audioTracks: [AudioTrackInfo] = []
    private(set) var selectedAudioTrackID: String?

    override init() {
        super.init()
        player.appliesMediaSelectionCriteriaAutomatically = false
        player.automaticallyWaitsToMinimizeStalling = true
        player.actionAtItemEnd = .pause
        player.preventsDisplaySleepDuringVideoPlayback = true
        surface.playerLayer.player = player

        if AVPictureInPictureController.isPictureInPictureSupported(),
           let pip = AVPictureInPictureController(playerLayer: surface.playerLayer) {
            pip.canStartPictureInPictureAutomaticallyFromInline = true
            pip.delegate = self
            pipController = pip
        }
        playerObservations.append(KVO.observe(player, \.timeControlStatus) { [weak self] in
            self?.timeControlStatusChanged()
        })
    }

    // MARK: Loading

    func load(url: URL, startAt: TimeInterval) async throws {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let properties: (Bool, CMTime, Bool)
        do {
            properties = try await asset.load(.isPlayable, .duration, .hasProtectedContent)
        } catch {
            throw PlayerError(Self.describe(error, fallback: "AVFoundation couldn't open this file"))
        }
        let (isPlayable, duration, isProtected) = properties
        guard !isProtected else {
            throw PlayerError("This video is protected by DRM (FairPlay) and can't be played by Sable.")
        }
        guard isPlayable else {
            throw PlayerError("AVFoundation can't play this file's video or audio format.")
        }
        loadedDuration = duration.seconds.finiteOrZero
        audibleGroup = try? await asset.loadMediaSelectionGroup(for: .audible)
        legibleGroup = try? await asset.loadMediaSelectionGroup(for: .legible)
        try Task.checkCancellation()

        let item = AVPlayerItem(asset: asset)
        disableLegibleSelection(on: item)
        self.item = item
        observe(item)
        player.replaceCurrentItem(with: item)

        try await waitUntilReady(item)
        disableLegibleSelection(on: item)
        await rebuildAudioTracks()

        if startAt > 0.05 {
            let target = CMTime(seconds: startAt, preferredTimescale: 600)
            _ = await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        let itemDuration = item.duration.seconds.finiteOrZero
        if itemDuration > 0 { loadedDuration = itemDuration }
        isLoaded = true
        onEvent?(.ready(duration: loadedDuration))
    }

    private func waitUntilReady(_ item: AVPlayerItem, timeout: TimeInterval = 30) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            try Task.checkCancellation()
            switch item.status {
            case .readyToPlay:
                return
            case .failed:
                throw PlayerError(Self.describe(item.error, fallback: "AVFoundation couldn't play this file"))
            default:
                break
            }
            if Date() > deadline {
                throw PlayerError("AVFoundation took too long to open this file.")
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func disableLegibleSelection(on item: AVPlayerItem) {
        // Sable draws text subtitles itself; never let AVPlayerLayer render a legible track.
        guard let legibleGroup else { return }
        item.select(nil, in: legibleGroup)
    }

    private func observe(_ item: AVPlayerItem) {
        itemObservations.forEach { $0.invalidate() }
        itemObservations = [
            KVO.observe(item, \.status) { [weak self] in self?.itemStatusChanged() },
        ]
        notificationTokens.forEach { NotificationCenter.default.removeObserver($0) }
        notificationTokens = [
            NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                   object: item, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.itemDidEnd() }
            },
            NotificationCenter.default.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification,
                                                   object: item, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.itemFailedDuringPlayback() }
            },
        ]
    }

    private func rebuildAudioTracks() async {
        guard let group = audibleGroup, let item else {
            audioTracks = []
            selectedAudioTrackID = nil
            return
        }
        let options = group.options
        audibleOptions = options
        var tracks: [AudioTrackInfo] = []
        var titleCounts: [String: Int] = [:]
        for (index, option) in options.enumerated() {
            var title = await Self.metadataTitle(option.commonMetadata) ?? option.displayName
            if title.trimmingCharacters(in: .whitespaces).isEmpty { title = "Track \(index + 1)" }
            let count = (titleCounts[title] ?? 0) + 1
            titleCounts[title] = count
            if count > 1 { title += " \(count)" }
            let language = LanguageCode.normalized(option.extendedLanguageTag ?? option.locale?.identifier)
            tracks.append(AudioTrackInfo(id: String(index), title: title, language: language,
                                         isDefault: group.defaultOption == option))
        }
        audioTracks = tracks
        if let selected = item.currentMediaSelection.selectedMediaOption(in: group),
           let index = options.firstIndex(of: selected) {
            selectedAudioTrackID = String(index)
        } else {
            selectedAudioTrackID = tracks.first(where: \.isDefault)?.id ?? tracks.first?.id
        }
        onEvent?(.audioTracksChanged)
    }

    private static func metadataTitle(_ metadata: [AVMetadataItem]) async -> String? {
        let titles = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierTitle)
        guard let first = titles.first else { return nil }
        let value = try? await first.load(.stringValue)
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    // MARK: Observation

    private func itemStatusChanged() {
        guard isLoaded, !isShutDown, let item, item.status == .failed else { return }
        onEvent?(.failed(Self.describe(item.error, fallback: "Playback failed")))
    }

    private func itemDidEnd() {
        guard !isShutDown else { return }
        reportPlaying(false)
        onEvent?(.ended)
    }

    private func itemFailedDuringPlayback() {
        guard !isShutDown else { return }
        onEvent?(.failed(Self.describe(item?.error, fallback: "Playback stopped unexpectedly")))
    }

    private func timeControlStatusChanged() {
        guard !isShutDown else { return }
        let status = player.timeControlStatus
        reportPlaying(status != .paused)
        let buffering = status == .waitingToPlayAtSpecifiedRate && player.reasonForWaitingToPlay != nil
        if buffering != reportedBuffering {
            reportedBuffering = buffering
            onEvent?(.bufferingChanged(buffering))
        }
    }

    private func reportPlaying(_ playing: Bool) {
        guard playing != reportedPlaying else { return }
        reportedPlaying = playing
        onEvent?(.playingChanged(playing))
    }

    // MARK: Transport

    func play() {
        guard !isShutDown else { return }
        PlaybackAudioSession.activate()
        player.defaultRate = desiredRate
        player.play()
    }

    func pause() {
        player.pause()
    }

    func seek(to seconds: TimeInterval) async {
        guard item != nil else { return }
        let target = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        _ = await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func scrub(to seconds: TimeInterval) {
        guard item != nil else { return }
        let target = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        let tolerance = CMTime(seconds: 0.4, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: tolerance, toleranceAfter: tolerance) { _ in }
    }

    var currentTime: TimeInterval {
        max(0, player.currentTime().seconds.finiteOrZero)
    }

    var duration: TimeInterval {
        let itemDuration = item?.duration.seconds.finiteOrZero ?? 0
        return itemDuration > 0 ? itemDuration : loadedDuration
    }

    var isPlaying: Bool { player.timeControlStatus != .paused }

    var rate: Float {
        get { desiredRate }
        set {
            desiredRate = newValue
            player.defaultRate = newValue
            if player.timeControlStatus != .paused { player.rate = newValue }
        }
    }

    func selectAudioTrack(id: String) {
        guard let group = audibleGroup, let item, let index = Int(id), audibleOptions.indices.contains(index) else { return }
        item.select(audibleOptions[index], in: group)
        selectedAudioTrackID = id
        // Selecting an audible option must never re-enable a legible one.
        disableLegibleSelection(on: item)
    }

    var aspectMode: AspectMode {
        get { surface.aspectMode }
        set { surface.aspectMode = newValue }
    }

    var presentationSize: CGSize { item?.presentationSize ?? .zero }

    // MARK: Picture in Picture

    var supportsPictureInPicture: Bool { pipController != nil }

    func togglePictureInPicture() {
        guard let pipController else { return }
        if pipController.isPictureInPictureActive {
            pipController.stopPictureInPicture()
        } else if pipController.isPictureInPicturePossible {
            pipController.startPictureInPicture()
        }
    }

    fileprivate func pictureInPictureDidChange(_ active: Bool) {
        isPictureInPictureActive = active
        onEvent?(.pictureInPictureChanged(active))
    }

    fileprivate func pictureInPictureFailed(_ message: String) {
        isPictureInPictureActive = false
        onEvent?(.pictureInPictureChanged(false))
        playbackLog.error("Picture in Picture failed: \(message, privacy: .public)")
    }

    func setNativeSubtitle(streamOrdinal: Int?, delay: TimeInterval) {
        // AVFoundation cannot render image-based tracks for Sable; the session shows a notice.
    }

    func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true
        if let pipController, pipController.isPictureInPictureActive { pipController.stopPictureInPicture() }
        pipController?.delegate = nil
        pipController = nil
        itemObservations.forEach { $0.invalidate() }
        playerObservations.forEach { $0.invalidate() }
        itemObservations = []
        playerObservations = []
        notificationTokens.forEach { NotificationCenter.default.removeObserver($0) }
        notificationTokens = []
        player.pause()
        player.replaceCurrentItem(with: nil)
        item = nil
        onEvent = nil
    }

    // MARK: Errors

    static func describe(_ error: Error?, fallback: String) -> String {
        guard let error else { return fallback + "." }
        if let avError = error as? AVError {
            switch avError.code {
            case .fileFormatNotRecognized:
                return "AVFoundation doesn't recognise this file's format."
            case .decoderNotFound, .decoderTemporarilyUnavailable:
                return "This iPhone has no decoder for the video's codec in AVFoundation."
            case .contentIsProtected, .contentIsNotAuthorized:
                return "This video is protected by DRM and can't be played by Sable."
            case .fileFailedToParse:
                return "The file is damaged or incomplete and couldn't be read."
            case .mediaServicesWereReset:
                return "The iPhone's media services were reset. Try again."
            case .noLongerPlayable:
                return "The file is no longer available."
            case .decodeFailed:
                return "The video couldn't be decoded. The file may be damaged."
            default:
                break
            }
        }
        return "\(fallback): \(error.localizedDescription)"
    }
}

extension AVFoundationEngine: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor [weak self] in self?.pictureInPictureDidChange(true) }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor [weak self] in self?.pictureInPictureDidChange(false) }
    }

    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                                failedToStartPictureInPictureWithError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor [weak self] in self?.pictureInPictureFailed(message) }
    }
}
