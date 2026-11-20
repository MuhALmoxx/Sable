import SwiftUI
import UIKit
import SubtitleKit
import LibraryKit

// OWNER: sync agent. Building blocks shared by TimingPanel and GuidedSyncView.

// MARK: - Type

/// Monospaced readouts that scale with Dynamic Type (text-style based, unlike fixed-size mono).
enum SyncFont {
    static let readout = Font.system(.largeTitle, design: .monospaced, weight: .semibold)
    static let readoutSmall = Font.system(.title2, design: .monospaced, weight: .semibold)
    static let mono = Font.system(.footnote, design: .monospaced, weight: .medium)
    static let monoBody = Font.system(.body, design: .monospaced, weight: .medium)

    /// Pixel type for Latin labels, IBM Plex Sans Arabic whenever the text contains Arabic.
    static func label(for text: String) -> Font {
        SyncText.containsArabic(text) ? Typo.arabic : Typo.bodyMedium
    }
}

enum SyncText {
    static func containsArabic(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x0600...0x06FF, 0x0750...0x077F, 0x08A0...0x08FF, 0xFB50...0xFDFF, 0xFE70...0xFEFF: return true
            default: return false
            }
        }
    }
}

// MARK: - Haptics

@MainActor
enum SyncHaptics {
    private static let selection = UISelectionFeedbackGenerator()
    private static let impact = UIImpactFeedbackGenerator(style: .light)
    private static let notification = UINotificationFeedbackGenerator()

    static func prepare() {
        selection.prepare()
        impact.prepare()
    }

    /// Every 0.1 s crossed while scrubbing, and each press-and-hold repeat.
    static func tick() { selection.selectionChanged() }
    /// Whole seconds crossed while scrubbing.
    static func majorTick() { impact.impactOccurred(intensity: 0.7) }
    /// A mark was captured.
    static func mark() { impact.impactOccurred(intensity: 1) }
    static func success() { notification.notificationOccurred(.success) }
}

// MARK: - Press-and-hold repeat

/// Drives press-and-hold repetition for `RepeatingButton`. A short tap fires once on release
/// (normal button behaviour); holding fires after 0.45 s, then repeatedly and faster.
/// The first firing of a gesture is reported with `isRepeat == false`, later ones with `true`
/// (so callers can make a whole hold a single undo step).
@MainActor
final class HoldRepeater {
    private var task: Task<Void, Never>?
    private var didRepeat = false

    func pressChanged(_ pressed: Bool, fire: @escaping (_ isRepeat: Bool) -> Void) {
        task?.cancel()
        task = nil
        guard pressed else { return }
        didRepeat = false
        task = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            var count = 0
            while !Task.isCancelled {
                self?.didRepeat = true
                fire(count > 0)
                if count > 0 { SyncHaptics.tick() }
                count += 1
                let interval = count < 8 ? 140 : 60
                try? await Task.sleep(for: .milliseconds(interval))
            }
        }
    }

    func tapped(fire: (_ isRepeat: Bool) -> Void) {
        if didRepeat {
            didRepeat = false // the hold already applied the change
        } else {
            fire(false)
        }
    }
}

private struct HoldAwareButtonStyle: ButtonStyle {
    var kind: PixelButtonKind
    var compact: Bool
    let onPressChange: (Bool) -> Void

    func makeBody(configuration: Configuration) -> some View {
        PixelButtonStyle(kind: kind, compact: compact)
            .makeBody(configuration: configuration)
            .onChange(of: configuration.isPressed) { _, pressed in onPressChange(pressed) }
    }
}

/// A pixel button that repeats while held. Accessibility activation fires once.
struct RepeatingButton<Label: View>: View {
    var kind: PixelButtonKind
    var compact: Bool
    let action: (_ isRepeat: Bool) -> Void
    let label: () -> Label
    @State private var repeater = HoldRepeater()

    init(kind: PixelButtonKind = .secondary, compact: Bool = true,
         action: @escaping (_ isRepeat: Bool) -> Void, @ViewBuilder label: @escaping () -> Label) {
        self.kind = kind
        self.compact = compact
        self.action = action
        self.label = label
    }

    var body: some View {
        Button {
            repeater.tapped(fire: action)
        } label: {
            label()
        }
        .buttonStyle(HoldAwareButtonStyle(kind: kind, compact: compact) { pressed in
            repeater.pressChanged(pressed, fire: action)
        })
        // A button removed mid-hold never sees isPressed go false: stop repeating explicitly.
        .onDisappear { repeater.pressChanged(false, fire: action) }
        .accessibilityHint("Hold to repeat.")
    }
}

/// Two-line label used by the nudge buttons: amount on top, direction underneath.
struct NudgeLabel: View {
    let amount: String
    let direction: String

    var body: some View {
        VStack(spacing: 2) {
            Text(amount).font(Typo.bodyMedium).monospacedDigit()
            Text(direction.uppercased()).font(Typo.micro).foregroundStyle(Palette.textSecondary)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .frame(maxWidth: .infinity, minHeight: 52)
        .contentShape(Rectangle())
    }
}

// MARK: - Seeking

/// Coalesces rapid seeks (scrubbing, repeated frame steps): at most one seek is in flight and
/// only the latest requested target is sent next. Optionally starts playback when it settles.
@MainActor
final class SeekThrottle {
    private var inFlight = false
    private var pending: TimeInterval?
    private var playWhenSettled = false
    /// Called each time the queue drains.
    var onSettled: (() -> Void)?

    var isBusy: Bool { inFlight || pending != nil }

    func request(_ session: PlayerSession, to time: TimeInterval, thenPlay: Bool = false) {
        pending = time
        playWhenSettled = thenPlay
        guard !inFlight else { return }
        pump(session)
    }

    private func pump(_ session: PlayerSession) {
        guard let target = pending else {
            inFlight = false
            if playWhenSettled {
                playWhenSettled = false
                session.play()
            }
            onSettled?()
            return
        }
        pending = nil
        inFlight = true
        Task { [weak self] in
            await session.seek(to: target)
            self?.pump(session)
        }
    }
}

// MARK: - Track context

/// What the panels need to know about the active subtitle track.
@MainActor
struct SyncTrackInfo {
    let descriptor: SubtitleTrackDescriptor
    let name: String
    let kindTag: String
    let isTranslation: Bool
    let isRightToLeft: Bool
    let cueCount: Int
    let sharingNote: String
    let savedNote: String

    /// nil unless a TEXT track is active.
    init?(session: PlayerSession) {
        guard let track = session.activeSubtitle, track.descriptor.kind == .text else { return nil }
        let d = track.descriptor
        descriptor = d
        name = Self.displayName(d)
        isRightToLeft = d.language?.isRightToLeft ?? false
        cueCount = track.document.cues.count

        let groupID = d.timingGroupID
        let siblings = session.subtitleTracks.filter { $0.id != d.id && $0.timingGroupID == groupID }
        switch d.origin {
        case let .translated(sourceTrackID, _, _):
            isTranslation = true
            kindTag = "Translation"
            let source = session.subtitleTracks.first { $0.id == sourceTrackID }.map(Self.displayName) ?? "its source track"
            sharingNote = "Translated from \(source). Both use one shared timing, so a change here also moves \(source)."
        case .external:
            isTranslation = false
            kindTag = "\(d.format.displayName) file"
            sharingNote = Self.sourceSharingNote(siblings)
        case .embedded:
            isTranslation = false
            kindTag = "Embedded \(d.format.displayName)"
            sharingNote = Self.sourceSharingNote(siblings)
        }
        savedNote = "Saved for this video and track: “\(session.item.title)” opens with this timing next time."
    }

    private static func sourceSharingNote(_ siblings: [SubtitleTrackDescriptor]) -> String {
        guard !siblings.isEmpty else {
            return "A translation made from this track will share this timing."
        }
        let names = siblings.map(displayName).joined(separator: ", ")
        return "Shared with its translation (\(names)): a change here moves both."
    }

    static func displayName(_ d: SubtitleTrackDescriptor) -> String {
        let title = d.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return title }
        return d.language?.displayName ?? "Subtitle track"
    }
}

// MARK: - Subtitle text

/// A cue's text: IBM Plex Sans Arabic + right-to-left for RTL tracks, reading type otherwise.
struct SubtitleLineText: View {
    let text: String
    let rightToLeft: Bool

    var body: some View {
        if rightToLeft {
            Text(SyncFormat.displayLines(text, rightToLeft: true))
                .font(Typo.arabic)
                .foregroundStyle(Palette.textPrimary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .environment(\.layoutDirection, .rightToLeft)
        } else {
            Text(text)
                .font(SyncText.containsArabic(text) ? Typo.arabic : Typo.readingMedium)
                .foregroundStyle(Palette.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - No text track

/// Guidance shown instead of the panels when no TEXT subtitle track is active.
struct SyncNoTrackView: View {
    let session: PlayerSession
    /// "adjust its timing" / "sync it"
    let purpose: String
    let buttonIdentifier: String
    let onChooseTrack: (() -> Void)?
    let onClose: () -> Void

    var body: some View {
        let copy = Self.copy(session: session, purpose: purpose)
        VStack(spacing: Spacing.md) {
            PixelMessage(glyph: .subtitles, title: copy.title, message: copy.message)
            if copy.showButton {
                Button {
                    if let onChooseTrack { onChooseTrack() } else { onClose() }
                } label: {
                    Text("Choose a subtitle track")
                        .frame(maxWidth: .infinity, minHeight: Spacing.touch)
                }
                .buttonStyle(PixelButtonStyle(kind: .primary))
                .accessibilityIdentifier(buttonIdentifier)
                .accessibilityHint(onChooseTrack == nil
                    ? "Closes this panel. Then use the Subtitles button in the player."
                    : "Opens the subtitle track list.")
                if onChooseTrack == nil {
                    Text("Then pick it with the Subtitles button in the player controls.")
                        .font(Typo.callout)
                        .foregroundStyle(Palette.textTertiary)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity)
    }

    static func copy(session: PlayerSession, purpose: String) -> (title: String, message: String, showButton: Bool) {
        if case .loading = session.subtitleLoadState {
            return ("Loading subtitles…", "Wait a moment while the subtitle track loads.", false)
        }
        if case let .failed(reason) = session.subtitleLoadState {
            return ("Subtitles couldn't load", "\(reason) Choose another text subtitle track to \(purpose).", true)
        }
        if let track = session.activeSubtitle {
            if track.descriptor.kind == .image {
                return ("Image-based subtitles",
                        "This track is made of pictures (PGS/VobSub), so Sable can't read its lines. Choose a text track (SRT, ASS, WebVTT or MP4 text) to \(purpose).",
                        true)
            }
            if track.document.cues.isEmpty {
                return ("This track has no lines", "The active subtitle track is empty. Choose another text track to \(purpose).", true)
            }
        }
        return ("Subtitles are off",
                "Turn on a text subtitle track (SRT, ASS, WebVTT or MP4 text) to \(purpose).",
                true)
    }
}

// MARK: - Presentation

/// Short sheet over the playing video: the video stays visible and interactive above it.
struct SyncSheetPresentation: ViewModifier {
    let compact: PresentationDetent

    func body(content: Content) -> some View {
        content
            .presentationDetents([compact, .large])
            .presentationBackgroundInteraction(.enabled(upThrough: compact))
            .presentationBackground(Palette.background)
            .presentationContentInteraction(.scrolls)
            .presentationDragIndicator(.visible)
    }
}

extension View {
    /// Applies a disabled look (PixelButtonStyle does not dim itself) together with `.disabled`.
    func syncDisabled(_ disabled: Bool) -> some View {
        self.disabled(disabled).opacity(disabled ? 0.4 : 1)
    }
}
