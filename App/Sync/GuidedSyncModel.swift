import Foundation
import Observation
import SubtitleKit

// OWNER: sync agent. State and maths of the guided "match a spoken line" flow.
//
//   a) mark   — the user marks the instant speech starts (optionally helped by a loudness
//               onset suggestion on AVFoundation media)
//   b) choose — the user says which line was spoken (candidates around the mark, by EFFECTIVE
//               time with the current timing; widen or search)
//   c) review — offset = mark − original cue start; apply & preview, fine-tune, confirm or undo
//   d) second point (optional) — another line ≥ 60 s away gives a two-point (drift) correction
//
// Undo semantics: the whole session is ONE undo step in the timing history. The first change
// is applied with `undoable: true` (pushing the timing that was active when the flow opened);
// every later change in the flow uses `undoable: false`. "Undo" therefore pops exactly that
// entry, restoring the pre-sync timing and the undo history as they were.
@Observable
@MainActor
final class GuidedSyncModel {
    enum Step: Int, CaseIterable {
        case mark = 1, choose, review

        var title: String {
            switch self {
            case .mark: return "Mark"
            case .choose: return "Line"
            case .review: return "Check"
            }
        }
    }

    enum SearchWindow: CaseIterable, Equatable {
        case ten, thirty, sixty, all

        var seconds: TimeInterval {
            switch self {
            case .ten: return 10
            case .thirty: return 30
            case .sixty: return 60
            case .all: return .infinity
            }
        }

        var label: String {
            switch self {
            case .ten: return "\u{00B1}10 s"
            case .thirty: return "\u{00B1}30 s"
            case .sixty: return "\u{00B1}60 s"
            case .all: return "whole track"
            }
        }

        var next: SearchWindow? {
            switch self {
            case .ten: return .thirty
            case .thirty: return .sixty
            case .sixty: return .all
            case .all: return nil
            }
        }
    }

    enum OnsetState: Equatable {
        case idle
        case unavailable(String)
        case analyzing
        case ready(OnsetSuggestionResult)
        case failed(String)
    }

    /// A confirmed sync point: the cue's ORIGINAL start and the video time it now maps to.
    struct SyncPoint: Equatable {
        let cueID: String
        let cueStart: TimeInterval
        let videoTime: TimeInterval
        let mark: TimeInterval
    }

    /// Two points closer than this cannot measure drift reliably.
    static let minimumPointSeparation: TimeInterval = 60

    let session: PlayerSession

    private(set) var step: Step = .mark
    private(set) var pointNumber = 1
    private(set) var markedTime: TimeInterval?
    var window: SearchWindow = .ten
    var query = ""
    private(set) var selectedCueID: String?
    private(set) var applied = false
    private(set) var firstPoint: SyncPoint?
    private(set) var onset: OnsetState = .idle
    /// Time shown while scrubbing / stepping, until the player has caught up.
    private(set) var scrubTime: TimeInterval?
    private(set) var originalTextByID: [String: String] = [:]
    var notice: String?
    /// The timing that was active when the flow opened (restored by Undo).
    private(set) var initialTiming: SubtitleTiming = .identity

    @ObservationIgnored private var timingAfterFirstPoint: SubtitleTiming?
    @ObservationIgnored private var pushedUndo = false
    @ObservationIgnored private var groupID: String?
    @ObservationIgnored private var trackID: String?
    @ObservationIgnored private var began = false
    @ObservationIgnored private var isDragging = false
    @ObservationIgnored private var analysisTask: Task<Void, Never>?
    @ObservationIgnored private var clearScrubTask: Task<Void, Never>?
    private let seeker = SeekThrottle()

    init(session: PlayerSession) {
        self.session = session
        seeker.onSettled = { [weak self] in self?.scheduleScrubClear() }
    }

    // MARK: Derived state

    /// The active TEXT track (nil when subtitles are off or image-based).
    var track: LoadedSubtitleTrack? {
        guard let t = session.activeSubtitle, t.descriptor.kind == .text else { return nil }
        return t
    }

    var cues: [SubtitleCue] { track?.document.cues ?? [] }

    var isTranslation: Bool {
        if case .translated? = track?.descriptor.origin { return true }
        return false
    }

    var isRightToLeft: Bool { track?.descriptor.language?.isRightToLeft ?? false }

    /// Playhead used by the timeline and by Mark.
    var displayTime: TimeInterval { scrubTime ?? session.currentTime }

    var selectedCue: SubtitleCue? {
        guard let id = selectedCueID else { return nil }
        return cues.first { $0.id == id }
    }

    var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Candidate lines: a text search over the whole track (primary + original text), or every
    /// cue whose EFFECTIVE interval overlaps the window around the mark.
    var candidates: [SubtitleCue] {
        guard let mark = markedTime else { return [] }
        if !trimmedQuery.isEmpty {
            return SyncMath.search(cues, query: trimmedQuery, originalTextByID: originalTextByID)
        }
        return SyncMath.candidateCues(cues, around: mark, window: window.seconds, timing: session.timing)
    }

    /// Where the cue currently appears relative to the mark (positive = after the mark).
    func distanceFromMark(_ cue: SubtitleCue) -> TimeInterval {
        guard let mark = markedTime else { return 0 }
        return session.timing.effective(cue.start) - mark
    }

    func nearestCandidateID(in list: [SubtitleCue]) -> String? {
        guard markedTime != nil, list.count > 1 else { return nil }
        return list.min { abs(distanceFromMark($0)) < abs(distanceFromMark($1)) }?.id
    }

    /// Source-language line for a translated cue (nil when not a translation or identical).
    func originalText(for cue: SubtitleCue) -> String? {
        guard isTranslation, let text = originalTextByID[cue.id] else { return nil }
        let plain = SyncFormat.oneLine(text)
        return plain.isEmpty || plain == SyncFormat.oneLine(cue.text) ? nil : plain
    }

    /// The timing this selection would apply.
    var computedTiming: SubtitleTiming? {
        guard let cue = selectedCue, let mark = markedTime else { return nil }
        if pointNumber == 2, let first = firstPoint {
            return SyncMath.twoPointTiming(markA: first.videoTime, cueStartA: first.cueStart,
                                           markB: mark, cueStartB: cue.start)
        }
        return SyncMath.timing(markedSpeechStart: mark, originalCueStart: cue.start, keepingScale: initialTiming.scale)
    }

    /// Why the second point cannot be used (nil when fine or for the first point).
    var twoPointProblem: String? {
        guard pointNumber == 2, let first = firstPoint, let cue = selectedCue, let mark = markedTime else { return nil }
        if cue.id == first.cueID {
            return "That's the line you used for the first point. Pick a different line, at least a minute away."
        }
        let markGap = abs(mark - first.videoTime)
        let lineGap = abs(cue.start - first.cueStart)
        if markGap < Self.minimumPointSeparation || lineGap < Self.minimumPointSeparation {
            let gap = Int(min(markGap, lineGap).rounded())
            return "Your two points are only \(gap) s apart. Drift can only be measured with points at least 60 s apart — ideally one near the start and one near the end."
        }
        if computedTiming == nil {
            return "These two points would mean the subtitles run more than 10 % faster or slower than the video, which is almost certainly a wrong line. Check that you picked the line that was actually spoken."
        }
        return nil
    }

    /// For the second point's mark step: the gap to the first point when it is too small.
    var markGapToFirstPoint: TimeInterval? {
        guard pointNumber == 2, let first = firstPoint, let mark = markedTime else { return nil }
        let gap = abs(mark - first.videoTime)
        return gap < Self.minimumPointSeparation ? gap : nil
    }

    /// Loudness-onset suggestion nearest the mark (nil when none / unavailable).
    var suggestedOnset: TimeInterval? {
        guard case let .ready(result) = onset, let mark = markedTime else { return nil }
        return OnsetAnalysis.bestOnset(result.onsets, near: mark)
    }

    // MARK: Lifecycle

    func begin() {
        guard !began else { return }
        began = true
        captureContext()
    }

    func end() {
        analysisTask?.cancel()
        analysisTask = nil
        clearScrubTask?.cancel()
        clearScrubTask = nil
        isDragging = false
        scrubTime = nil
    }

    private func captureContext() {
        initialTiming = session.timing
        pushedUndo = false
        groupID = track?.descriptor.timingGroupID
        trackID = track?.descriptor.id
        originalTextByID = session.originalTextByCueID()
    }

    /// Called when the active subtitle track changes while the flow is open.
    func activeTrackChanged() {
        // A switch takes the previous track off screen before the new one has loaded
        // (`activeSubtitle` is nil meanwhile): wait for the new track rather than restarting the
        // flow for that gap (English <-> Arabic must keep going on the same timing group).
        if session.activeSubtitle == nil, session.loadingSubtitleTrackID != nil { return }
        let newTrackID = track?.descriptor.id
        let newGroupID = track?.descriptor.timingGroupID
        guard newTrackID != trackID || newGroupID != groupID else { return }
        // No text track before (sheet opened while the track was still loading): nothing to restart.
        let hadTrack = groupID != nil
        originalTextByID = session.originalTextByCueID()
        if newGroupID == groupID {
            // Same timing group (e.g. English <-> its Arabic translation): same cue ids and
            // timestamps, so the flow simply continues on the other text.
            trackID = newTrackID
            return
        }
        analysisTask?.cancel()
        resetFlow(keepMark: false)
        captureContext()
        if hadTrack && newGroupID != nil {
            notice = "The subtitle track changed, so sync started over for the new track."
        }
    }

    // MARK: Transport

    func togglePlay() {
        if session.isPlaying { session.pause() } else { session.play() }
    }

    /// Replay last 5 s: seek −5 s and play.
    func replayLastFive() {
        seek(to: displayTime - 5, thenPlay: true)
    }

    /// Frame-style step: pauses and moves the playhead by `delta`.
    func stepPlayhead(by delta: TimeInterval) {
        session.pause()
        seek(to: displayTime + delta, thenPlay: false)
    }

    func beginScrub() {
        isDragging = true
        clearScrubTask?.cancel()
        session.pause()
        SyncHaptics.prepare()
    }

    func scrub(to time: TimeInterval) {
        let t = clampToMedia(time)
        scrubTime = t
        seeker.request(session, to: t)
    }

    func endScrub() {
        isDragging = false
        if !seeker.isBusy { scheduleScrubClear() }
    }

    private func seek(to time: TimeInterval, thenPlay: Bool) {
        let t = clampToMedia(time)
        clearScrubTask?.cancel()
        scrubTime = t
        seeker.request(session, to: t, thenPlay: thenPlay)
    }

    /// Keeps the requested time on screen briefly after the seek settles so the readout does
    /// not flicker back while the player publishes its new position.
    private func scheduleScrubClear() {
        clearScrubTask?.cancel()
        clearScrubTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard let self, !Task.isCancelled, !self.isDragging, !self.seeker.isBusy else { return }
            self.scrubTime = nil
        }
    }

    func clampToMedia(_ time: TimeInterval) -> TimeInterval {
        let upper = session.duration > 0 ? session.duration : .greatestFiniteMagnitude
        return min(max(0, time), upper)
    }

    private static func ms(_ t: TimeInterval) -> TimeInterval { (t * 1000).rounded() / 1000 }

    // MARK: a) Mark

    func mark() {
        let t = Self.ms(clampToMedia(displayTime))
        session.pause()
        markedTime = t
        notice = nil
        analyzeOnsets(around: t)
    }

    func nudgeMark(by delta: TimeInterval) {
        guard let mark = markedTime else { return }
        let t = Self.ms(clampToMedia(mark + delta))
        markedTime = t
        session.pause()
        seek(to: t, thenPlay: false)
        if case let .ready(result) = onset, abs(t - result.center) > 2 {
            analyzeOnsets(around: t)
        }
    }

    func useSuggestion() {
        guard let suggestion = suggestedOnset else { return }
        let t = Self.ms(suggestion)
        markedTime = t
        session.pause()
        seek(to: t, thenPlay: false)
    }

    /// "Hear it again": plays from 1.5 s before the mark.
    func hearAgain() {
        guard let mark = markedTime else { return }
        seek(to: mark - 1.5, thenPlay: true)
    }

    func goToChoose() {
        guard markedTime != nil else { return }
        session.pause()
        window = .ten
        query = ""
        step = .choose
    }

    // MARK: b) Choose

    func widen() {
        if let next = window.next { window = next }
    }

    func narrow() { window = .ten }

    func select(_ cue: SubtitleCue) {
        selectedCueID = cue.id
        applied = false
        step = .review
    }

    func backToMark() {
        step = .mark
    }

    func backToChoose() {
        applied = false
        step = .choose
    }

    // MARK: c) Review

    func applyAndPreview() {
        guard let timing = computedTiming, twoPointProblem == nil else { return }
        commit(timing)
        applied = true
        notice = nil
        preview()
    }

    /// Plays from 2 s before the mark so the user sees the line appear.
    func preview() {
        guard let mark = markedTime else { return }
        seek(to: mark - 2, thenPlay: true)
    }

    /// ±0.1 s fine-tuning after applying (part of the same single undo step).
    func fineTune(by delta: TimeInterval) {
        commit(session.timing.shifted(by: delta))
    }

    /// Restores the exact timing that was active when the flow opened and returns to step a.
    func undoSync() {
        revertToInitial()
        resetFlow(keepMark: true)
        notice = "Sync undone. Timing is back to \(SyncFormat.signedOffset(initialTiming.offset))."
    }

    // MARK: d) Second point

    func startSecondPoint() {
        guard applied, let cue = selectedCue, let mark = markedTime else { return }
        firstPoint = SyncPoint(cueID: cue.id, cueStart: cue.start,
                               videoTime: Self.ms(session.timing.effective(cue.start)), mark: mark)
        timingAfterFirstPoint = session.timing
        pointNumber = 2
        markedTime = nil
        selectedCueID = nil
        applied = false
        window = .ten
        query = ""
        onset = .idle
        analysisTask?.cancel()
        notice = nil
        step = .mark
    }

    /// Drops the second point and goes back to the first point's result.
    func cancelSecondPoint() {
        guard let first = firstPoint else { return }
        if let timing = timingAfterFirstPoint, !Self.same(session.timing, timing) {
            commit(timing)
        }
        pointNumber = 1
        markedTime = first.mark
        selectedCueID = first.cueID
        firstPoint = nil
        timingAfterFirstPoint = nil
        window = .ten
        query = ""
        onset = .idle
        analysisTask?.cancel()
        applied = true
        step = .review
    }

    // MARK: Timing transaction

    private func commit(_ timing: SubtitleTiming) {
        if pushedUndo {
            session.setTiming(timing, undoable: false)
        } else {
            let before = session.timing
            session.setTiming(timing, undoable: true)
            pushedUndo = !Self.same(before, timing)
        }
    }

    private func revertToInitial() {
        if pushedUndo {
            session.undoTiming()
            if !Self.same(session.timing, initialTiming) {
                session.setTiming(initialTiming, undoable: false)
            }
        } else if !Self.same(session.timing, initialTiming) {
            session.setTiming(initialTiming, undoable: false)
        }
        pushedUndo = false
    }

    private func resetFlow(keepMark: Bool) {
        let keptMark = keepMark ? (firstPoint?.mark ?? markedTime) : nil
        pointNumber = 1
        step = .mark
        markedTime = keptMark
        selectedCueID = nil
        applied = false
        firstPoint = nil
        timingAfterFirstPoint = nil
        window = .ten
        query = ""
        onset = .idle
        if let keptMark { analyzeOnsets(around: keptMark) }
    }

    static func same(_ a: SubtitleTiming, _ b: SubtitleTiming) -> Bool {
        abs(a.offset - b.offset) < 0.0005 && abs(a.scale - b.scale) < 1e-12
    }

    // MARK: Onset suggestion

    private func analyzeOnsets(around center: TimeInterval) {
        analysisTask?.cancel()
        analysisTask = nil
        guard let kind = session.engineKind else {
            onset = .unavailable("Audio suggestions appear once the video has loaded.")
            return
        }
        guard kind == .avFoundation else {
            onset = .unavailable("No audio suggestion for this file: it plays through VLC, which Sable can't analyse. Use your ears and the fine nudges.")
            return
        }
        onset = .analyzing
        let url = session.mediaURL
        let duration = session.duration
        analysisTask = Task { [weak self] in
            do {
                let result = try await SpeechOnsetDetector.detectOnsets(in: url, around: center, radius: 3,
                                                                        mediaDuration: duration)
                guard !Task.isCancelled else { return }
                self?.onset = .ready(result)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self?.onset = .failed(error.localizedDescription)
            }
        }
    }
}
