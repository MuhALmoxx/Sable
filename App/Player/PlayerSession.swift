import SwiftUI
import UIKit
import QuartzCore
import SubtitleKit
import LibraryKit

// OWNER: playback agent. The API below is the contract consumed by the Sync and Translation
// features. Keep names/signatures (add freely).

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

    /// Stored in `PlaybackMemory.subtitleTrackID` when the user explicitly turned subtitles off
    /// (nil there means "never chosen": Sable then picks the embedded default/English track).
    static let subtitlesOffMarker = "off"
    static let rateRange: ClosedRange<Float> = 0.5...2.0

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
    var rate: Float = 1 {
        didSet {
            if !Self.rateRange.contains(rate) { rate = min(Self.rateRange.upperBound, max(Self.rateRange.lowerBound, rate)) }
            if rate != oldValue { engine?.rate = rate }
        }
    }

    private(set) var audioTracks: [AudioTrackInfo] = []
    private(set) var selectedAudioTrackID: String?

    /// Every subtitle track for this video: embedded (text + image), external and translated.
    private(set) var subtitleTracks: [SubtitleTrackDescriptor] = []
    /// nil = subtitles off. Image-based tracks are "active" with an empty document (VLC draws them).
    private(set) var activeSubtitle: LoadedSubtitleTrack?
    private(set) var subtitleLoadState: SubtitleLoadState = .idle
    /// Cues visible right now (updated ~30×/s while playing and immediately after seeks/timing changes).
    private(set) var visibleCues: [DisplayCue] = []

    /// Timing for the active track's timing group (shared by a source track and its translations).
    private(set) var timing: SubtitleTiming = .identity
    private(set) var canUndoTiming = false

    var subtitleStyle: SubtitleStyle = .default {
        didSet { if subtitleStyle != oldValue { refreshVisibleCues() } }
    }
    var aspectMode: AspectMode = .fit {
        didSet { if aspectMode != oldValue { engine?.aspectMode = aspectMode } }
    }
    private(set) var isPictureInPictureSupported = false

    /// The engine's rendering view (nil until loaded).
    private(set) var engineView: UIView?

    // MARK: Additional state for the player UI

    private(set) var isPictureInPictureActive = false
    /// Picture size (display aspect applied), from the probe or the engine.
    private(set) var videoSize: CGSize?
    /// Shown under the spinner while opening.
    private(set) var loadingMessage = "Opening…"
    /// Transient information ("switched to VLC", image track notices).
    private(set) var notice: String?
    /// Embedded tracks Sable can't use (e.g. CEA-608 captions), for the track sheet.
    private(set) var unsupportedSubtitleTracks: [String] = []
    /// Track whose document is being loaded/extracted right now.
    private(set) var loadingSubtitleTrackID: String?
    /// Time the user is dragging to (scrubber or pan), nil when not scrubbing.
    private(set) var scrubTime: TimeInterval?
    /// True when this video has its own subtitle style (otherwise the app default applies).
    private(set) var hasPerVideoStyle = false
    /// The last engine Sable tried (for the failure screen's "Try VLC engine").
    private(set) var lastAttemptedEngine: PlaybackEngineKind?
    /// AVFoundation reported the file as playable (so "Reopen with AVFoundation" makes sense).
    private(set) var isPlayableByAVFoundation = false
    /// Container found by the probe.
    private(set) var container: ContainerKind?

    @ObservationIgnored private var engine: PlaybackEngine?
    @ObservationIgnored private var displayLink: DisplayLinkDriver?
    @ObservationIgnored private var originalTextByID: [String: String] = [:]
    @ObservationIgnored private var originalDisplayTextByID: [String: String] = [:]
    @ObservationIgnored private var selectionGeneration = 0
    @ObservationIgnored private var lastPersist: CFTimeInterval = 0
    @ObservationIgnored private var lastScrubDispatch: CFTimeInterval = 0
    @ObservationIgnored private var forcedEngine: PlaybackEngineKind?
    @ObservationIgnored private var didAutoFallBack = false
    @ObservationIgnored private var restartPosition: TimeInterval?
    @ObservationIgnored private var pendingAudioRestoreID: String?
    @ObservationIgnored private var subtitleChoice: String?
    @ObservationIgnored private var perVideoStyle: SubtitleStyle?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var pipSaveTask: Task<Void, Never>?
    @ObservationIgnored private var isStarting = false
    @ObservationIgnored private var isTornDown = false

    init(item: MediaItem, services: AppServices) {
        self.services = services
        self.itemID = item.id
        self.item = item
        self.mediaURL = services.library.mediaURL(for: item)
    }

    var isLoaded: Bool { engine != nil && (status == .ready || status == .ended) }

    // MARK: Start

    /// Chooses an engine, loads media, restores position/tracks/style, starts playback.
    func start() async {
        guard !isTornDown, !isStarting, engine == nil else { return }
        isStarting = true
        let opened = await openMedia()
        isStarting = false
        if opened { await restoreSubtitles() }
    }

    /// Probe + engine load with AVFoundation -> VLC fallback. Returns true when playing.
    private func openMedia() async -> Bool {
        status = .loading
        loadingMessage = "Opening…"
        if let fresh = services.library.item(id: itemID) { item = fresh }

        let probe = await services.probe.probe(url: mediaURL)
        guard !isTornDown else { return false }
        services.subtitles.storeProbe(probe, for: itemID)
        if let issue = probe.issue {
            status = .failed(issue)
            return false
        }
        if let size = probe.videoSize, size.width > 0, size.height > 0 { videoSize = size }
        if let probed = probe.duration, probed > 0 { duration = probed }
        unsupportedSubtitleTracks = probe.unsupportedSubtitleTracks
        isPlayableByAVFoundation = probe.preferredEngine == .avFoundation
        container = probe.container
        restorePresentation()

        let kinds: [PlaybackEngineKind]
        if let forcedEngine {
            kinds = [forcedEngine]
        } else if services.settings.preferVLCForAll || probe.preferredEngine == .vlc {
            kinds = [.vlc]
        } else {
            kinds = [.avFoundation, .vlc]
        }

        let startAt = restartPosition ?? resumePosition()
        restartPosition = nil
        var failures: [(PlaybackEngineKind, String)] = []
        for kind in kinds {
            lastAttemptedEngine = kind
            if !failures.isEmpty { loadingMessage = "Trying the VLC engine…" }
            do {
                try await loadEngine(kind, startAt: startAt)
                break
            } catch {
                shutdownEngine()
                if isTornDown { return false }
                let message = readableMessage(for: error)
                playbackLog.error("\(kind.displayName, privacy: .public) failed to load: \(message, privacy: .public)")
                failures.append((kind, message))
            }
        }
        guard !isTornDown else {
            shutdownEngine()
            return false
        }
        guard let engine else {
            if failures.count == 1 {
                status = .failed(failures[0].1)
            } else {
                let lines = failures.map { "\($0.0.displayName): \($0.1)" }.joined(separator: "\n")
                status = .failed("Neither playback engine could open this video.\n\(lines)")
            }
            return false
        }
        if !failures.isEmpty {
            showNotice("AVFoundation couldn't play this file, so Sable switched to the VLC engine.")
        }

        status = .ready
        if engine.duration > 0 { duration = engine.duration }
        isPictureInPictureSupported = engine.supportsPictureInPicture
        syncAudioTracks()
        pendingAudioRestoreID = item.playback.audioTrackID
        restoreAudioTrackIfPending()
        if displayLink == nil {
            displayLink = DisplayLinkDriver(framesPerSecond: 30) { [weak self] in self?.tick() }
        }
        play()
        refreshTime()
        return true
    }

    /// Re-opens the video with the same engine choice (keeps the current position).
    func retry() async {
        await restart(forcing: forcedEngine)
    }

    /// Re-opens the video with VLCKit (from the failure screen).
    func retryWithVLC() async {
        await restart(forcing: .vlc)
    }

    /// Re-opens the video with AVFoundation (hardware decoding + Picture in Picture).
    func reopenWithAVFoundation() async {
        guard isPlayableByAVFoundation else { return }
        await restart(forcing: .avFoundation)
    }

    private func restart(forcing kind: PlaybackEngineKind?) async {
        guard !isTornDown, !isStarting else { return }
        if isLoaded { persistNow() }
        restartPosition = currentTime > 1 ? currentTime : nil
        forcedEngine = kind
        shutdownEngine()
        isPlaying = false
        isBuffering = false
        status = .idle
        await start()
    }

    private func loadEngine(_ kind: PlaybackEngineKind, startAt: TimeInterval) async throws {
        shutdownEngine()
        let engine: PlaybackEngine = kind == .avFoundation ? AVFoundationEngine() : VLCEngine()
        engine.aspectMode = aspectMode
        engine.rate = rate
        engine.onEvent = { [weak self, weak engine] event in
            guard let self, let engine else { return }
            self.handle(event, from: engine)
        }
        self.engine = engine
        engineKind = kind
        engineView = engine.view
        try await engine.load(url: mediaURL, startAt: startAt)
        if isTornDown { throw CancellationError() }
    }

    private func shutdownEngine() {
        engine?.shutdown()
        engine = nil
        engineView = nil
        engineKind = nil
        isPictureInPictureSupported = false
        isPictureInPictureActive = false
        pipSaveTask?.cancel()
        pipSaveTask = nil
        displayLink?.isPaused = true
    }

    private func restorePresentation() {
        let memory = item.playback
        perVideoStyle = memory.subtitleStyle
        hasPerVideoStyle = memory.subtitleStyle != nil
        subtitleStyle = memory.subtitleStyle ?? services.settings.subtitleStyle
        aspectMode = memory.aspectMode
        let playedBefore = item.lastPlayedAt != nil || memory.position > 0
        rate = playedBefore ? memory.rate : services.settings.defaultRate
        subtitleChoice = memory.subtitleTrackID
    }

    private func resumePosition() -> TimeInterval {
        let memory = item.playback
        guard services.settings.resumePlayback, !memory.completed, memory.position > 1 else { return 0 }
        let known = duration > 0 ? duration : (item.duration ?? 0)
        if known > 0 && memory.position >= known - 1 { return 0 }
        return memory.position
    }

    // MARK: Engine events and clock

    private func handle(_ event: PlaybackEngineEvent, from source: PlaybackEngine) {
        guard !isTornDown, source === engine else { return }
        switch event {
        case let .ready(engineDuration):
            if engineDuration > 0 { duration = engineDuration }
        case let .playingChanged(playing):
            isPlaying = playing
            displayLink?.isPaused = !playing
            refreshTime()
            if !playing && status == .ready { persistNow() }
        case let .bufferingChanged(buffering):
            isBuffering = buffering
        case .audioTracksChanged:
            syncAudioTracks()
            restoreAudioTrackIfPending()
        case .ended:
            isPlaying = false
            displayLink?.isPaused = true
            if duration > 0 { currentTime = duration }
            status = .ended
            refreshVisibleCues()
            persistNow()
        case let .failed(message):
            if isLoaded { persistNow() }
            isPlaying = false
            displayLink?.isPaused = true
            let failedRightAway = engineKind == .avFoundation && forcedEngine == nil && !didAutoFallBack && currentTime < 2
            status = .failed(message)
            if failedRightAway {
                // Failed right after opening: treat it like a load failure and fall back to VLC.
                didAutoFallBack = true
                showNotice("AVFoundation couldn't play this file, so Sable switched to the VLC engine.")
                Task { await self.restart(forcing: .vlc) }
            }
        case let .pictureInPictureChanged(active):
            isPictureInPictureActive = active
            updatePictureInPictureSaving()
        }
    }

    /// CADisplayLink (and with it the periodic save in `tick`) doesn't fire while Sable is in the
    /// background, where AVFoundation keeps playing in Picture in Picture; save on a timer then,
    /// so a long PiP session isn't lost if the app is terminated before playback pauses.
    private func updatePictureInPictureSaving() {
        pipSaveTask?.cancel()
        pipSaveTask = nil
        guard isPictureInPictureActive, !isTornDown else { return }
        pipSaveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled, let self else { return }
                if self.isPlaying, CACurrentMediaTime() - self.lastPersist > 4 {
                    self.refreshTime()
                    self.persist(bumpRevision: false)
                }
            }
        }
    }

    private func tick() {
        guard !isTornDown, engine != nil else { return }
        refreshTime()
        if isPlaying && CACurrentMediaTime() - lastPersist > 5 {
            persist(bumpRevision: false)
        }
    }

    private func refreshTime() {
        guard let engine else { return }
        let time = engine.currentTime
        if status != .ended, abs(time - currentTime) > 0.0005 { currentTime = time }
        let engineDuration = engine.duration
        if engineDuration > 0, abs(engineDuration - duration) > 0.01 { duration = engineDuration }
        let size = engine.presentationSize
        if size.width > 0, size.height > 0, size != videoSize { videoSize = size }
        refreshVisibleCues()
    }

    private func refreshVisibleCues() {
        guard let active = activeSubtitle, active.descriptor.kind == .text else {
            if !visibleCues.isEmpty { visibleCues = [] }
            return
        }
        let time = scrubTime ?? currentTime
        let cues = active.index.activeCues(at: time, timing: timing)
        let languageRTL = active.descriptor.language?.isRightToLeft ?? active.document.language?.isRightToLeft
        let showOriginal = subtitleStyle.showOriginalUnderTranslation && active.originalDocument != nil
        let display = cues.map { cue in
            DisplayCue(id: cue.id,
                       text: cue.text,
                       originalText: showOriginal ? originalDisplayTextByID[cue.id] : nil,
                       isRightToLeft: languageRTL ?? TextDirection.containsRightToLeft(cue.text),
                       style: cue.style)
        }
        if display != visibleCues { visibleCues = display }
    }

    // MARK: Transport

    func play() {
        guard let engine, !isTornDown else { return }
        if status == .ended {
            Task {
                await self.seek(to: 0)
                self.engine?.play()
            }
            return
        }
        guard status == .ready else { return }
        engine.play()
        displayLink?.isPaused = false
    }

    func pause() {
        guard let engine else { return }
        engine.pause()
        refreshTime()
    }

    func togglePlayPause() {
        if isPlaying { pause() } else { play() }
    }

    func seek(to seconds: TimeInterval) async {
        guard let engine, !isTornDown else { return }
        var target = max(0, seconds)
        if duration > 0 { target = min(target, max(0, duration - 0.05)) }
        if status == .ended { status = .ready }
        currentTime = target
        refreshVisibleCues()
        await engine.seek(to: target)
        guard !isTornDown, self.engine === engine else { return }
        refreshTime()
        persist(bumpRevision: false)
    }

    func skip(by delta: TimeInterval) {
        let target = (scrubTime ?? currentTime) + delta
        Task { await self.seek(to: target) }
    }

    func setRate(_ rate: Float) {
        self.rate = rate
        persistNow()
    }

    /// Live scrubbing (scrubber drag or horizontal pan): shows cues at `seconds` and performs
    /// throttled fast seeks so the picture follows the finger.
    func scrub(to seconds: TimeInterval) {
        guard engine != nil else { return }
        var target = max(0, seconds)
        if duration > 0 { target = min(target, duration) }
        scrubTime = target
        refreshVisibleCues()
        let now = CACurrentMediaTime()
        if now - lastScrubDispatch > 0.12 {
            lastScrubDispatch = now
            engine?.scrub(to: target)
        }
    }

    /// Ends a scrub with a precise seek to `seconds`.
    func endScrub(at seconds: TimeInterval) async {
        scrubTime = nil
        await seek(to: seconds)
    }

    func cancelScrub() {
        guard scrubTime != nil else { return }
        scrubTime = nil
        refreshVisibleCues()
    }

    // MARK: Audio

    func selectAudioTrack(_ id: String) {
        guard let engine else { return }
        pendingAudioRestoreID = nil
        engine.selectAudioTrack(id: id)
        syncAudioTracks()
        selectedAudioTrackID = id
        persistNow()
    }

    private func syncAudioTracks() {
        guard let engine else { return }
        audioTracks = engine.audioTracks
        selectedAudioTrackID = engine.selectedAudioTrackID
    }

    private func restoreAudioTrackIfPending() {
        guard let id = pendingAudioRestoreID, let engine,
              engine.audioTracks.contains(where: { $0.id == id }) else { return }
        pendingAudioRestoreID = nil
        if engine.selectedAudioTrackID != id { engine.selectAudioTrack(id: id) }
        syncAudioTracks()
    }

    // MARK: Subtitles

    /// nil turns subtitles off. Loads (extracting embedded text if needed) and persists the choice.
    func selectSubtitleTrack(_ id: String?) async {
        subtitleChoice = id ?? Self.subtitlesOffMarker
        await activateSubtitle(id)
        persistNow()
    }

    /// Re-reads the track list (after importing a file or finishing a translation).
    func reloadSubtitleTracks() async {
        if let fresh = services.library.item(id: itemID) { item = fresh }
        await refreshTrackList()
        guard let active = activeSubtitle else { return }
        if !subtitleTracks.contains(where: { $0.id == active.descriptor.id }) {
            deactivateSubtitles()
        } else if case .translated = active.descriptor.origin, loadingSubtitleTrackID == nil {
            // A translation may have been regenerated under the same id: reload its document.
            // Not while another track is loading: every persistNow (pause, rate, import…) bumps
            // libraryRevision and lands here, and re-activating would supersede the user's
            // in-flight selection (its result is then dropped by the generation check).
            await activateSubtitle(active.descriptor.id)
        }
    }

    /// Imports an external SRT/VTT/ASS/SSA file for this video and selects it.
    func importExternalSubtitle(from url: URL) async throws {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let ref = try services.library.attachSubtitle(from: url, to: itemID, copy: true)
        if let fresh = services.library.item(id: itemID) { item = fresh }
        if !item.externalSubtitles.contains(where: { $0.id == ref.id }) { item.externalSubtitles.append(ref) }
        services.libraryDidChange()
        await refreshTrackList()
        await selectSubtitleTrack(ref.id)
        if case let .failed(message) = subtitleLoadState { throw PlayerError(message) }
    }

    /// Loads any track's document (used by translation for the source track).
    func document(for trackID: String) async throws -> SubtitleDocument {
        if let active = activeSubtitle, active.descriptor.id == trackID, active.descriptor.kind == .text {
            return active.document
        }
        if !subtitleTracks.contains(where: { $0.id == trackID }) {
            if let fresh = services.library.item(id: itemID) { item = fresh }
            await refreshTrackList()
        }
        guard let descriptor = subtitleTracks.first(where: { $0.id == trackID }) else {
            throw PlayerError("That subtitle track isn't available for this video.")
        }
        return try await services.subtitles.document(for: descriptor, item: item)
    }

    /// When the active track is a translation: source text by cue id. Empty otherwise.
    func originalTextByCueID() -> [String: String] { originalTextByID }

    private func refreshTrackList() async {
        let tracks = await services.subtitles.tracks(for: item)
        guard !isTornDown else { return }
        subtitleTracks = tracks
    }

    private func restoreSubtitles() async {
        await refreshTrackList()
        guard !isTornDown, loadingSubtitleTrackID == nil else { return }
        if let active = activeSubtitle {
            // Restarted engine (retry / VLC fallback): keep the loaded track, re-apply native rendering.
            if active.descriptor.kind == .image { activateImageTrack(active.descriptor) }
            return
        }
        if subtitleChoice == Self.subtitlesOffMarker { return }
        if let choice = subtitleChoice, subtitleTracks.contains(where: { $0.id == choice }) {
            await activateSubtitle(choice)
        } else if let fallback = defaultSubtitleTrack() {
            await activateSubtitle(fallback.id)
        }
    }

    /// The embedded default text track, else the first embedded English text track.
    private func defaultSubtitleTrack() -> SubtitleTrackDescriptor? {
        let embedded = subtitleTracks.filter { track in
            if case .embedded = track.origin { return track.kind == .text }
            return false
        }
        return embedded.first { $0.isDefault && !$0.isForced }
            ?? embedded.first { $0.isDefault }
            ?? embedded.first { $0.language?.primary == "en" && !$0.isForced }
    }

    private func activateSubtitle(_ id: String?) async {
        selectionGeneration &+= 1
        let generation = selectionGeneration
        guard let id else {
            deactivateSubtitles()
            return
        }
        guard let descriptor = subtitleTracks.first(where: { $0.id == id }) else {
            subtitleLoadState = .failed("That subtitle track is no longer available.")
            return
        }
        if descriptor.kind == .image {
            activateImageTrack(descriptor)
            return
        }
        loadingSubtitleTrackID = id
        subtitleLoadState = .loading(progress: nil)
        do {
            let loadedDocument = try await services.subtitles.document(for: descriptor, item: item) { [weak self] fraction in
                guard let self, self.selectionGeneration == generation else { return }
                self.subtitleLoadState = .loading(progress: fraction)
            }
            var original: SubtitleDocument?
            if case let .translated(sourceTrackID, _, _) = descriptor.origin {
                original = try? await self.document(for: sourceTrackID)
            }
            guard generation == selectionGeneration, !isTornDown else { return }
            install(LoadedSubtitleTrack(descriptor: descriptor, document: loadedDocument,
                                        index: CueIndex(cues: loadedDocument.cues), originalDocument: original))
            subtitleLoadState = .idle
        } catch {
            guard generation == selectionGeneration else { return }
            loadingSubtitleTrackID = nil
            if error is CancellationError || (error as? SubtitleError) == .cancelled {
                subtitleLoadState = .idle
            } else {
                subtitleLoadState = .failed(readableMessage(for: error))
            }
        }
    }

    private func install(_ loaded: LoadedSubtitleTrack) {
        activeSubtitle = loaded
        loadingSubtitleTrackID = nil
        let originalCues = loaded.originalDocument?.cues ?? []
        originalTextByID = Dictionary(originalCues.map { ($0.id, $0.plainText) }, uniquingKeysWith: { first, _ in first })
        originalDisplayTextByID = Dictionary(originalCues.map { ($0.id, $0.text) }, uniquingKeysWith: { first, _ in first })
        loadTiming(for: loaded.descriptor)
        engine?.setNativeSubtitle(streamOrdinal: nil, delay: 0)
        refreshVisibleCues()
    }

    private func activateImageTrack(_ descriptor: SubtitleTrackDescriptor) {
        let empty = SubtitleDocument(format: .unknown, cues: [], language: descriptor.language, title: descriptor.title)
        install(LoadedSubtitleTrack(descriptor: descriptor, document: empty, index: CueIndex(cues: []), originalDocument: nil))
        subtitleLoadState = .idle
        if engineKind == .vlc, let ordinal = nativeOrdinal(for: descriptor) {
            engine?.setNativeSubtitle(streamOrdinal: ordinal, delay: timing.offset)
        } else {
            showNotice("“\(descriptor.title)” is an image-based track (\(SubtitleRepository.imageCodecLabel(descriptor))). Only the VLC engine can display it — turn on “Use VLC engine for every file” in Settings (or reopen this video with VLC from the More menu).")
        }
    }

    /// Position of an embedded track among the container's subtitle streams (VLC's ordering).
    private func nativeOrdinal(for descriptor: SubtitleTrackDescriptor) -> Int? {
        let embedded: [(id: String, stream: Int)] = subtitleTracks.compactMap { track in
            if case let .embedded(_, streamID, _) = track.origin { return (track.id, streamID) }
            return nil
        }.sorted { $0.stream < $1.stream }
        return embedded.firstIndex { $0.id == descriptor.id }
    }

    private func deactivateSubtitles() {
        activeSubtitle = nil
        loadingSubtitleTrackID = nil
        subtitleLoadState = .idle
        originalTextByID = [:]
        originalDisplayTextByID = [:]
        timing = .identity
        canUndoTiming = false
        engine?.setNativeSubtitle(streamOrdinal: nil, delay: 0)
        if !visibleCues.isEmpty { visibleCues = [] }
    }

    // MARK: Timing (applies immediately; persisted per video + timing group)

    private var timingKey: String? {
        activeSubtitle.map { TimingStore.key(videoID: itemID, timingGroupID: $0.descriptor.timingGroupID) }
    }

    private func loadTiming(for descriptor: SubtitleTrackDescriptor) {
        let key = TimingStore.key(videoID: itemID, timingGroupID: descriptor.timingGroupID)
        timing = services.timing.timing(forKey: key)
        canUndoTiming = services.timing.canUndo(forKey: key)
    }

    func setTiming(_ timing: SubtitleTiming, undoable: Bool = true) {
        if let key = timingKey {
            services.timing.setTiming(timing, forKey: key, undoable: undoable)
            canUndoTiming = services.timing.canUndo(forKey: key)
        }
        self.timing = timing
        timingDidChange()
    }

    func nudgeOffset(by delta: TimeInterval) {
        setTiming(timing.shifted(by: delta))
    }

    func undoTiming() {
        guard let key = timingKey, let previous = services.timing.undo(forKey: key) else { return }
        timing = previous
        canUndoTiming = services.timing.canUndo(forKey: key)
        timingDidChange()
    }

    func resetTiming() {
        if let key = timingKey {
            services.timing.reset(forKey: key)
            canUndoTiming = services.timing.canUndo(forKey: key)
        }
        timing = .identity
        timingDidChange()
    }

    private func timingDidChange() {
        if let active = activeSubtitle, active.descriptor.kind == .image, engineKind == .vlc,
           let ordinal = nativeOrdinal(for: active.descriptor) {
            engine?.setNativeSubtitle(streamOrdinal: ordinal, delay: timing.offset)
        }
        refreshVisibleCues()
    }

    // MARK: Presentation

    func togglePictureInPicture() {
        engine?.togglePictureInPicture()
    }

    func setAspectMode(_ mode: AspectMode) {
        aspectMode = mode
        persistNow()
    }

    /// Pinch: toggles between Fit and Fill.
    func toggleFitFill() {
        setAspectMode(aspectMode == .fill ? .fit : .fill)
    }

    /// Saves `style` as this video's own subtitle style.
    func updateSubtitleStyle(_ style: SubtitleStyle) {
        perVideoStyle = style
        hasPerVideoStyle = true
        subtitleStyle = style
        persistNow()
    }

    /// Drops this video's own style and goes back to the app-wide default.
    func useDefaultSubtitleStyle() {
        perVideoStyle = nil
        hasPerVideoStyle = false
        subtitleStyle = services.settings.subtitleStyle
        persistNow()
    }

    private func showNotice(_ text: String, seconds: Double = 6) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    func dismissNotice() {
        noticeTask?.cancel()
        notice = nil
    }

    // MARK: Persistence

    /// Saves position/tracks now (called on background, close and periodically).
    func persistNow() {
        persist(bumpRevision: true)
    }

    private func persist(bumpRevision: Bool) {
        guard !isTornDown, engine != nil, status == .ready || status == .ended else { return }
        lastPersist = CACurrentMediaTime()
        let total = duration
        let position = status == .ended ? total : currentTime
        let remaining = total - position
        let threshold = min(max(10, total * 0.03), total * 0.25)
        let completed = total > 0 && (status == .ended || remaining <= threshold)

        var updated = services.library.item(id: itemID) ?? item
        updated.playback.position = max(0, position)
        updated.playback.completed = completed
        updated.playback.rate = rate
        updated.playback.audioTrackID = selectedAudioTrackID
        updated.playback.subtitleTrackID = subtitleChoice
        updated.playback.aspectMode = aspectMode
        updated.playback.subtitleStyle = perVideoStyle
        updated.lastPlayedAt = Date()
        if total > 0, (updated.duration ?? 0) <= 0 { updated.duration = total }
        do {
            try services.library.update(updated)
        } catch {
            playbackLog.error("Couldn't save playback position: \(error.localizedDescription, privacy: .public)")
        }
        item = updated
        if bumpRevision { services.libraryDidChange() }
    }

    func tearDown() {
        guard !isTornDown else { return }
        persistNow()
        isTornDown = true
        selectionGeneration &+= 1
        noticeTask?.cancel()
        displayLink?.invalidate()
        displayLink = nil
        shutdownEngine()
        isPlaying = false
    }
}
