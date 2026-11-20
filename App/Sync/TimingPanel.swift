import SwiftUI
import SubtitleKit

// OWNER: sync agent. Manual offset panel, presented from the player (compact, non-blocking).
//
// Everything applies immediately through PlayerSession (which persists per video + timing
// group and recomputes visible cues from playback time), so changes show while the video plays
// and survive seeks and speed changes. Positive offset = subtitles appear LATER.
struct TimingPanel: View {
    let session: PlayerSession
    var onClose: () -> Void
    /// Optional: lets the player open its subtitle track list from the empty state.
    var onChooseTrack: (() -> Void)?

    init(session: PlayerSession, onClose: @escaping () -> Void = {}, onChooseTrack: (() -> Void)? = nil) {
        self.session = session
        self.onClose = onClose
        self.onChooseTrack = onChooseTrack
    }

    @State private var entryText = ""
    @State private var entryMessage: EntryMessage?
    @FocusState private var entryFocused: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private enum EntryMessage: Equatable {
        case error(String)
        case done(String)
    }

    private struct Nudge: Identifiable {
        let delta: TimeInterval
        let amount: String
        let direction: String
        let spoken: String
        let identifier: String
        var id: String { identifier }
    }

    private static let nudges: [Nudge] = [
        Nudge(delta: -1, amount: "\(SyncFormat.minus)1 s", direction: "Earlier", spoken: "1 second earlier", identifier: AX.Timing.minusOne),
        Nudge(delta: -0.1, amount: "\(SyncFormat.minus)0.1 s", direction: "Earlier", spoken: "0.1 seconds earlier", identifier: AX.Timing.minusTenth),
        Nudge(delta: 0.1, amount: "+0.1 s", direction: "Later", spoken: "0.1 seconds later", identifier: AX.Timing.plusTenth),
        Nudge(delta: 1, amount: "+1 s", direction: "Later", spoken: "1 second later", identifier: AX.Timing.plusOne),
    ]

    var body: some View {
        let info = SyncTrackInfo(session: session)
        PixelSheet(title: "Subtitle timing", subtitle: info?.name, onClose: onClose) {
            ScrollView {
                if let info {
                    content(info)
                } else {
                    SyncNoTrackView(session: session, purpose: "adjust its timing",
                                    buttonIdentifier: AX.Timing.chooseTrack,
                                    onChooseTrack: onChooseTrack, onClose: onClose)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier(AX.Timing.noTrack)
                }
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AX.Timing.panel)
        .modifier(SyncSheetPresentation(compact: .fraction(0.45)))
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ info: SyncTrackInfo) -> some View {
        let timing = session.timing
        VStack(alignment: .leading, spacing: Spacing.md) {
            readout(timing)
            nudgeButtons
            undoResetRow(timing)
            entrySection
            trackSection(info)
        }
        .padding(Spacing.md)
    }

    private func readout(_ timing: SubtitleTiming) -> some View {
        VStack(spacing: Spacing.xxs) {
            Text(SyncFormat.signedOffset(timing.offset))
                .font(SyncFont.readout)
                .monospacedDigit()
                .foregroundStyle(timing.isIdentity ? Palette.textPrimary : Palette.accent)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .accessibilityIdentifier(AX.Timing.offsetValue)
            if let long = SyncFormat.longOffsetHint(timing.offset) {
                Text(long)
                    .font(SyncFont.mono)
                    .foregroundStyle(Palette.textSecondary)
            }
            Text(SyncFormat.meaning(timing))
                .font(Typo.reading)
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier(AX.Timing.offsetMeaning)
            if let drift = SyncFormat.driftNote(timing) {
                Text(drift)
                    .font(Typo.callout)
                    .foregroundStyle(Palette.textTertiary)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier(AX.Timing.driftNote)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Spacing.xs)
    }

    @ViewBuilder
    private var nudgeButtons: some View {
        let n = Self.nudges
        if dynamicTypeSize.isAccessibilitySize {
            Grid(horizontalSpacing: Spacing.xs, verticalSpacing: Spacing.xs) {
                GridRow { nudgeButton(n[0]); nudgeButton(n[3]) }
                GridRow { nudgeButton(n[1]); nudgeButton(n[2]) }
            }
        } else {
            HStack(spacing: Spacing.xs) {
                ForEach(n) { nudgeButton($0) }
            }
        }
    }

    private func nudgeButton(_ nudge: Nudge) -> some View {
        RepeatingButton(compact: true, action: { isRepeat in apply(nudge: nudge.delta, isRepeat: isRepeat) }) {
            NudgeLabel(amount: nudge.amount, direction: nudge.direction)
        }
        .accessibilityLabel(nudge.spoken)
        .accessibilityIdentifier(nudge.identifier)
    }

    private func undoResetRow(_ timing: SubtitleTiming) -> some View {
        HStack(spacing: Spacing.xs) {
            Button {
                session.undoTiming()
            } label: {
                HStack(spacing: Spacing.xs) {
                    PixelIcon(.undo, size: 14)
                    Text("Undo")
                }
                .frame(maxWidth: .infinity, minHeight: Spacing.touch)
            }
            .buttonStyle(PixelButtonStyle(kind: .secondary))
            .syncDisabled(!session.canUndoTiming)
            .accessibilityLabel("Undo last timing change")
            .accessibilityIdentifier(AX.Timing.undo)

            Button {
                session.resetTiming()
                entryMessage = nil
            } label: {
                HStack(spacing: Spacing.xs) {
                    PixelIcon(.reset, size: 14)
                    Text("Reset")
                }
                .frame(maxWidth: .infinity, minHeight: Spacing.touch)
            }
            .buttonStyle(PixelButtonStyle(kind: .secondary))
            .syncDisabled(timing.isIdentity)
            .accessibilityLabel("Reset to the file's original timing")
            .accessibilityHint("You can undo this.")
            .accessibilityIdentifier(AX.Timing.reset)
        }
    }

    // MARK: Direct entry

    private var entrySection: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            SectionLabel("Exact offset")
            if dynamicTypeSize.isAccessibilitySize {
                entryField
                HStack(spacing: Spacing.xs) { signButton; colonButton; applyButton }
            } else {
                HStack(spacing: Spacing.xs) { signButton; entryField; colonButton; applyButton }
            }
            entryFooter
        }
    }

    private var entryField: some View {
        TextField("Offset in seconds", text: $entryText,
                  prompt: Text("e.g. \(SyncFormat.minus)75.5 or 1:02.5").foregroundStyle(Palette.textTertiary))
            .font(SyncFont.monoBody)
            .foregroundStyle(Palette.textPrimary)
            .keyboardType(.decimalPad)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .focused($entryFocused)
            .submitLabel(.done)
            .onSubmit(applyEntry)
            .onChange(of: entryText) { _, _ in
                if case .error? = entryMessage { entryMessage = nil }
            }
            .padding(.horizontal, Spacing.sm)
            .frame(maxWidth: .infinity, minHeight: Spacing.touch)
            .pixelPanel(fill: Palette.surface, border: entryFocused ? Palette.borderStrong : Palette.border)
            .accessibilityLabel("Offset in seconds")
            .accessibilityHint("Positive makes subtitles later, negative earlier. Minutes and seconds like 1:02.5 also work.")
            .accessibilityIdentifier(AX.Timing.entry)
    }

    private var signButton: some View {
        Button {
            entryText = OffsetEntry.toggledSign(entryText)
            entryFocused = true
        } label: {
            Text("\u{00B1}")
                .font(Typo.headline)
                .frame(minWidth: Spacing.touch, minHeight: Spacing.touch)
        }
        .buttonStyle(PixelButtonStyle(kind: .secondary, compact: true))
        .accessibilityLabel("Toggle minus sign")
        .accessibilityIdentifier(AX.Timing.signToggle)
    }

    private var colonButton: some View {
        Button {
            entryText += ":"
            entryFocused = true
        } label: {
            Text(":")
                .font(Typo.headline)
                .frame(minWidth: Spacing.touch, minHeight: Spacing.touch)
        }
        .buttonStyle(PixelButtonStyle(kind: .secondary, compact: true))
        .accessibilityLabel("Insert colon, for minutes and seconds")
        .accessibilityIdentifier(AX.Timing.colon)
    }

    private var applyButton: some View {
        let isEmpty = entryText.trimmingCharacters(in: .whitespaces).isEmpty
        return Button(action: applyEntry) {
            Text("Apply")
                .frame(minHeight: Spacing.touch)
        }
        // Secondary on purpose: the amber accent belongs to the active offset readout.
        .buttonStyle(PixelButtonStyle(kind: .secondary))
        .syncDisabled(isEmpty)
        .accessibilityLabel("Apply offset")
        .accessibilityIdentifier(AX.Timing.apply)
    }

    @ViewBuilder
    private var entryFooter: some View {
        switch entryMessage {
        case let .error(message)?:
            HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                PixelIcon(.warning, size: 12, color: Palette.danger)
                Text(message).font(Typo.callout).foregroundStyle(Palette.danger)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(AX.Timing.entryMessage)
        case let .done(message)?:
            HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                PixelIcon(.check, size: 12, color: Palette.success)
                Text(message).font(Typo.callout).foregroundStyle(Palette.textSecondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(AX.Timing.entryMessage)
        case nil:
            Text("Seconds, any size. + is later, \(SyncFormat.minus) is earlier: \(SyncFormat.minus)75.5, +1:02.5, 250ms.")
                .font(Typo.callout)
                .foregroundStyle(Palette.textTertiary)
        }
    }

    // MARK: Track

    private func trackSection(_ info: SyncTrackInfo) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            SectionLabel("Applies to")
            HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                Text(info.name)
                    .font(SyncFont.label(for: info.name))
                    .foregroundStyle(Palette.textPrimary)
                PixelTag(info.kindTag)
                if let language = info.descriptor.language {
                    PixelTag(language.primary)
                }
            }
            Text(info.sharingNote)
                .font(Typo.reading)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(info.savedNote)
                .font(Typo.callout)
                .foregroundStyle(Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pixelPanel(fill: Palette.surface)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AX.Timing.trackInfo)
    }

    // MARK: Actions

    private func apply(nudge delta: TimeInterval, isRepeat: Bool) {
        entryMessage = nil
        if isRepeat {
            // A press-and-hold is one undo step: only its first change goes on the undo stack.
            session.setTiming(session.timing.shifted(by: delta), undoable: false)
        } else {
            session.nudgeOffset(by: delta)
        }
    }

    private func applyEntry() {
        switch OffsetEntry.evaluate(entryText) {
        case .empty:
            entryMessage = .error("Type an offset first, for example \(SyncFormat.minus)75.5 or 1:02.5.")
        case let .invalid(message):
            entryMessage = .error(message)
        case let .value(seconds):
            let current = session.timing
            session.setTiming(SubtitleTiming(offset: seconds, scale: current.scale), undoable: true)
            entryMessage = .done("Offset set to \(SyncFormat.signedOffset(seconds)).")
            entryText = ""
            entryFocused = false
        }
    }
}
