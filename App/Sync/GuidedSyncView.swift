import SwiftUI
import SubtitleKit

// OWNER: sync agent. Guided "match a spoken line" synchronisation, presented from the player
// as a sheet with background interaction so the video stays visible above it.
// You mark the moment; Sable does the math. (This is not speech recognition.)
struct GuidedSyncView: View {
    let session: PlayerSession
    var onClose: () -> Void
    /// Optional: lets the player open its subtitle track list from the empty state.
    var onChooseTrack: (() -> Void)?

    @State private var model: GuidedSyncModel

    init(session: PlayerSession, onClose: @escaping () -> Void = {}, onChooseTrack: (() -> Void)? = nil) {
        self.session = session
        self.onClose = onClose
        self.onChooseTrack = onChooseTrack
        _model = State(initialValue: GuidedSyncModel(session: session))
    }

    var body: some View {
        let info = SyncTrackInfo(session: session)
        PixelSheet(title: "Sync subtitles", subtitle: info?.name, onClose: close) {
            if let info, info.cueCount > 0 {
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.md) {
                        SyncStepHeader(step: model.step, pointNumber: model.pointNumber)
                        if let notice = model.notice {
                            SyncNotice(text: notice)
                        }
                        switch model.step {
                        case .mark:
                            SyncMarkStep(model: model, session: session)
                        case .choose:
                            SyncChooseStep(model: model)
                        case .review:
                            SyncReviewStep(model: model, session: session, onDone: close)
                        }
                    }
                    .padding(Spacing.md)
                }
                .scrollDismissesKeyboard(.interactively)
            } else {
                ScrollView {
                    SyncNoTrackView(session: session, purpose: "sync it",
                                    buttonIdentifier: AX.Sync.chooseTrack,
                                    onChooseTrack: onChooseTrack, onClose: close)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier(AX.Sync.noTrack)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AX.Sync.flow)
        .modifier(SyncSheetPresentation(compact: .fraction(0.55)))
        .onAppear { model.begin() }
        .onDisappear { model.end() }
        .onChange(of: session.activeSubtitle?.descriptor.id) { _, _ in
            model.activeTrackChanged()
        }
    }

    private func close() {
        model.end()
        onClose()
    }
}

// MARK: - Header and notices

private struct SyncStepHeader: View {
    let step: GuidedSyncModel.Step
    let pointNumber: Int

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.xxs) {
                ForEach(GuidedSyncModel.Step.allCases, id: \.rawValue) { s in
                    Rectangle()
                        .fill(s == step ? Palette.accent : (s.rawValue < step.rawValue ? Palette.borderStrong : Palette.border))
                        .frame(height: Spacing.px * 2)
                }
            }
            Text(caption)
                .font(Typo.micro)
                .tracking(1)
                .foregroundStyle(Palette.textTertiary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
        .accessibilityIdentifier(AX.Sync.stepIndicator)
    }

    private var caption: String {
        let base = "STEP \(step.rawValue) OF 3 \u{00B7} \(step.title.uppercased())"
        return pointNumber == 2 ? "SECOND POINT \u{00B7} " + base : base
    }

    private var spoken: String {
        let base = "Step \(step.rawValue) of 3: \(step.title)"
        return pointNumber == 2 ? "Second sync point. " + base : base
    }
}

private struct SyncNotice: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
            PixelIcon(.info, size: 12, color: Palette.textSecondary)
            Text(text).font(Typo.callout).foregroundStyle(Palette.textSecondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AX.Sync.notice)
    }
}

// MARK: - a) Mark

private struct SyncMarkStep: View {
    let model: GuidedSyncModel
    let session: PlayerSession

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            intro
            SyncTimeline(model: model, session: session)
            SyncTransportRow(model: model, session: session)
            markButton
            if let mark = model.markedTime {
                SyncMarkedSection(model: model, mark: mark)
            }
            nextButton
            if model.pointNumber == 2 {
                Button {
                    model.cancelSecondPoint()
                } label: {
                    Text("Cancel second point")
                        .frame(maxWidth: .infinity, minHeight: Spacing.touch)
                }
                .buttonStyle(PixelButtonStyle(kind: .ghost))
                .accessibilityIdentifier(AX.Sync.cancelSecondPoint)
            }
        }
    }

    @ViewBuilder
    private var intro: some View {
        if let first = model.firstPoint {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Find a line at least a minute away from your first point (\(SyncFormat.precise(first.videoTime))) — ideally near the end — and mark when it starts.")
                    .font(Typo.reading)
                    .foregroundStyle(Palette.textPrimary)
                Text("Two points let Sable correct drift as well as delay.")
                    .font(Typo.callout)
                    .foregroundStyle(Palette.textTertiary)
            }
        } else if model.markedTime == nil {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Play a few seconds, then tap Mark the instant a character starts speaking.")
                    .font(Typo.reading)
                    .foregroundStyle(Palette.textPrimary)
                Text("You mark the moment; Sable does the math.")
                    .font(Typo.callout)
                    .foregroundStyle(Palette.textTertiary)
            }
        }
    }

    private var markButton: some View {
        let hasMark = model.markedTime != nil
        return Button {
            model.mark()
            SyncHaptics.mark()
        } label: {
            HStack(spacing: Spacing.xs) {
                PixelIcon(.flag, size: 18)
                Text(hasMark ? "Mark again" : "Mark speech start")
            }
            .frame(maxWidth: .infinity, minHeight: 56)
        }
        .buttonStyle(PixelButtonStyle(kind: hasMark ? .secondary : .primary))
        .accessibilityLabel(hasMark ? "Mark speech start again" : "Mark speech start")
        .accessibilityHint("Captures the current playback time as the moment speech starts.")
        .accessibilityIdentifier(AX.Sync.mark)
    }

    private var nextButton: some View {
        let hasMark = model.markedTime != nil
        return Button {
            model.goToChoose()
        } label: {
            HStack(spacing: Spacing.xs) {
                Text("Next: which line was it?")
                PixelIcon(.chevronRight, size: 14)
            }
            .frame(maxWidth: .infinity, minHeight: Spacing.touch)
        }
        .buttonStyle(PixelButtonStyle(kind: hasMark ? .primary : .secondary))
        .syncDisabled(!hasMark)
        .accessibilityLabel("Next: choose which line was spoken")
        .accessibilityIdentifier(AX.Sync.next)
    }
}

/// A row of equal-width buttons that stacks vertically at accessibility text sizes.
private struct SyncButtonRow<Content: View>: View {
    let stacked: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        let layout = stacked
            ? AnyLayout(VStackLayout(spacing: Spacing.xs))
            : AnyLayout(HStackLayout(spacing: Spacing.xs))
        layout { content() }
    }
}

private struct SyncTransportRow: View {
    let model: GuidedSyncModel
    let session: PlayerSession
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        SyncButtonRow(stacked: dynamicTypeSize.isAccessibilitySize) {
            RepeatingButton(action: { _ in model.stepPlayhead(by: -0.1) }) {
                transportText("\(SyncFormat.minus)0.1 s")
            }
            .accessibilityLabel("Back 0.1 seconds")
            .accessibilityIdentifier(AX.Sync.stepBack)

            Button {
                model.replayLastFive()
            } label: {
                HStack(spacing: Spacing.xxs) {
                    PixelIcon(.skipBack, size: 14)
                    Text("5 s").font(Typo.callout)
                }
                .frame(maxWidth: .infinity, minHeight: Spacing.touch)
            }
            .buttonStyle(PixelButtonStyle(kind: .secondary, compact: true))
            .accessibilityLabel("Replay last 5 seconds")
            .accessibilityIdentifier(AX.Sync.replay)

            Button {
                model.togglePlay()
            } label: {
                PixelIcon(session.isPlaying ? .pause : .play, size: 18)
                    .frame(maxWidth: .infinity, minHeight: Spacing.touch)
            }
            .buttonStyle(PixelButtonStyle(kind: .secondary, compact: true))
            .accessibilityLabel(session.isPlaying ? "Pause" : "Play")
            .accessibilityIdentifier(AX.Sync.playPause)

            RepeatingButton(action: { _ in model.stepPlayhead(by: 0.1) }) {
                transportText("+0.1 s")
            }
            .accessibilityLabel("Forward 0.1 seconds")
            .accessibilityIdentifier(AX.Sync.stepForward)
        }
    }

    private func transportText(_ text: String) -> some View {
        Text(text)
            .font(Typo.callout)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity, minHeight: Spacing.touch)
    }
}

private struct SyncMarkedSection: View {
    let model: GuidedSyncModel
    let mark: TimeInterval
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            SectionLabel("Marked", trailing: "precise to 1 ms")
            Text(SyncFormat.precise(mark))
                .font(SyncFont.readoutSmall)
                .foregroundStyle(Palette.textPrimary)
                .accessibilityIdentifier(AX.Sync.markedTime)

            SyncButtonRow(stacked: dynamicTypeSize.isAccessibilitySize) {
                nudge(-0.1, "\(SyncFormat.minus)0.1", "Mark 0.1 seconds earlier", AX.Sync.nudgeBack)
                nudge(-0.01, "\(SyncFormat.minus)0.01", "Mark 0.01 seconds earlier", AX.Sync.fineBack)
                nudge(0.01, "+0.01", "Mark 0.01 seconds later", AX.Sync.fineForward)
                nudge(0.1, "+0.1", "Mark 0.1 seconds later", AX.Sync.nudgeForward)
            }

            Button {
                model.hearAgain()
            } label: {
                HStack(spacing: Spacing.xs) {
                    PixelIcon(.audio, size: 14)
                    Text("Hear it again")
                }
                .frame(maxWidth: .infinity, minHeight: Spacing.touch)
            }
            .buttonStyle(PixelButtonStyle(kind: .secondary))
            .accessibilityHint("Plays from 1.5 seconds before your mark.")
            .accessibilityIdentifier(AX.Sync.hearAgain)

            SyncSuggestionView(model: model, mark: mark)

            if let gap = model.markGapToFirstPoint {
                SyncWarning(text: "This mark is only \(Int(gap.rounded())) s from your first point. Move at least a minute away so drift can be measured.")
            }

            Text("Most taps land 0.1–0.3 s late. Use Hear it again and nudge until the voice starts right at the mark.")
                .font(Typo.callout)
                .foregroundStyle(Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Spacing.sm)
        .pixelPanel(fill: Palette.surface)
    }

    private func nudge(_ delta: TimeInterval, _ title: String, _ spoken: String, _ identifier: String) -> some View {
        RepeatingButton(action: { _ in model.nudgeMark(by: delta) }) {
            Text(title)
                .font(Typo.callout)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, minHeight: Spacing.touch)
        }
        .accessibilityLabel(spoken)
        .accessibilityIdentifier(identifier)
    }
}

private struct SyncSuggestionView: View {
    let model: GuidedSyncModel
    let mark: TimeInterval

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(AX.Sync.suggestion)
    }

    @ViewBuilder
    private var content: some View {
        switch model.onset {
        case .idle:
            EmptyView()
        case .analyzing:
            line(glyph: .waveform, "Looking for a loudness onset near your mark…")
        case let .unavailable(message):
            line(glyph: .info, message)
        case let .failed(message):
            line(glyph: .info, "No audio suggestion: \(message)")
        case .ready:
            if let suggestion = model.suggestedOnset {
                if abs(suggestion - mark) < 0.0005 {
                    line(glyph: .check, "Your mark matches the loudness onset at \(SyncFormat.precise(suggestion)).")
                } else {
                    HStack(alignment: .center, spacing: Spacing.sm) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Suggested onset \(SyncFormat.precise(suggestion))")
                                .font(Typo.bodyMedium)
                                .foregroundStyle(Palette.textPrimary)
                            Text("A suggestion from the audio's loudness, not speech recognition. Check it with Hear it again.")
                                .font(Typo.callout)
                                .foregroundStyle(Palette.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        Button {
                            model.useSuggestion()
                        } label: {
                            Text("Use").frame(minWidth: Spacing.touch, minHeight: Spacing.touch)
                        }
                        .buttonStyle(PixelButtonStyle(kind: .secondary, compact: true))
                        .accessibilityLabel("Use suggested onset \(SyncFormat.precise(suggestion))")
                        .accessibilityIdentifier(AX.Sync.useSuggestion)
                    }
                }
            } else {
                line(glyph: .info, "No clear speech onset near your mark. Trust your ears.")
            }
        }
    }

    private func line(glyph: PixelGlyph, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
            PixelIcon(glyph, size: 12, color: Palette.textTertiary)
            Text(text)
                .font(Typo.callout)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct SyncWarning: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
            PixelIcon(.warning, size: 12, color: Palette.danger)
            Text(text)
                .font(Typo.callout)
                .foregroundStyle(Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pixelPanel(fill: Palette.surface, border: Palette.danger.opacity(0.5))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AX.Sync.problem)
    }
}

// MARK: - b) Choose

private struct SyncChooseStep: View {
    @Bindable var model: GuidedSyncModel

    var body: some View {
        let list = model.candidates
        let nearest = model.nearestCandidateID(in: list)
        let searching = !model.trimmedQuery.isEmpty
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Which line did the character say?")
                .font(Typo.headline)
                .foregroundStyle(Palette.textPrimary)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier(AX.Sync.question)
            Text(scope(count: list.count, searching: searching))
                .font(Typo.callout)
                .foregroundStyle(Palette.textSecondary)

            searchField

            if !searching {
                windowControls
            }

            if list.isEmpty {
                emptyState(searching: searching)
            } else {
                LazyVStack(alignment: .leading, spacing: Spacing.xs) {
                    ForEach(list, id: \.index) { cue in
                        SyncCandidateRow(
                            cue: cue,
                            original: model.originalText(for: cue),
                            rightToLeft: model.isRightToLeft,
                            delta: model.distanceFromMark(cue),
                            isNearest: cue.id == nearest
                        ) {
                            model.select(cue)
                        }
                    }
                }
            }

            Button {
                model.backToMark()
            } label: {
                Text("Back: adjust the mark")
                    .frame(maxWidth: .infinity, minHeight: Spacing.touch)
            }
            .buttonStyle(PixelButtonStyle(kind: .ghost))
            .accessibilityIdentifier(AX.Sync.back)
        }
    }

    private func scope(count: Int, searching: Bool) -> String {
        let mark = model.markedTime.map(SyncFormat.precise) ?? "—"
        if searching {
            return count == 1 ? "1 line in the whole track matches." : "\(count) lines in the whole track match."
        }
        if model.window == .all {
            return "Every line in the track (\(count)). Your mark: \(mark)."
        }
        return "Lines on screen within \(model.window.label) of your mark at \(mark) (\(count))."
    }

    private var searchField: some View {
        HStack(spacing: Spacing.xs) {
            PixelIcon(.search, size: 14, color: Palette.textTertiary)
            TextField("Search lines", text: $model.query,
                      prompt: Text("Search words you heard").foregroundStyle(Palette.textTertiary))
                .font(Typo.reading)
                .foregroundStyle(Palette.textPrimary)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .accessibilityLabel("Search the whole track")
                .accessibilityIdentifier(AX.Sync.search)
            if !model.query.isEmpty {
                PixelIconButton(.close, label: "Clear search", size: 12) { model.query = "" }
            }
        }
        .padding(.leading, Spacing.sm)
        .frame(minHeight: Spacing.touch)
        .pixelPanel(fill: Palette.surface)
    }

    private var windowControls: some View {
        HStack(spacing: Spacing.xs) {
            PixelTag(model.window.label)
            Spacer(minLength: Spacing.xs)
            if model.window != .ten {
                Button {
                    model.narrow()
                } label: {
                    Text("Narrow").frame(minHeight: Spacing.touch)
                }
                .buttonStyle(PixelButtonStyle(kind: .ghost, compact: true))
                .accessibilityLabel("Back to 10 seconds around the mark")
                .accessibilityIdentifier(AX.Sync.narrow)
            }
            if let next = model.window.next {
                Button {
                    model.widen()
                } label: {
                    Text(next == .all ? "Show whole track" : "Widen to \(next.label)")
                        .frame(minHeight: Spacing.touch)
                }
                .buttonStyle(PixelButtonStyle(kind: .secondary, compact: true))
                .accessibilityLabel(next == .all ? "Show every line in the track" : "Widen to \(next.label) around the mark")
                .accessibilityIdentifier(AX.Sync.widen)
            }
        }
    }

    @ViewBuilder
    private func emptyState(searching: Bool) -> some View {
        if searching {
            PixelMessage(glyph: .search, title: "No matching line",
                         message: "No line contains “\(model.trimmedQuery)”. Try fewer or different words.")
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier(AX.Sync.emptyCandidates)
        } else {
            PixelMessage(glyph: .search, title: "No lines near your mark",
                         message: "Nothing is on screen within \(model.window.label) of your mark with the current timing. Widen the window or search for words you heard.")
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier(AX.Sync.emptyCandidates)
        }
    }
}

private struct SyncCandidateRow: View {
    let cue: SubtitleCue
    let original: String?
    let rightToLeft: Bool
    let delta: TimeInterval
    let isNearest: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                    Text("\(SyncFormat.precise(cue.start)) – \(SyncFormat.precise(cue.end))")
                        .font(SyncFont.mono)
                        .foregroundStyle(Palette.textTertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Spacer(minLength: 0)
                    if isNearest { PixelTag("Nearest") }
                }
                SubtitleLineText(text: cue.plainText, rightToLeft: rightToLeft)
                if let original {
                    Text(original)
                        .font(Typo.reading)
                        .foregroundStyle(Palette.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text(SyncFormat.relativeToMark(delta))
                    .font(Typo.callout)
                    .foregroundStyle(Palette.textSecondary)
            }
            .padding(Spacing.sm)
            .frame(maxWidth: .infinity, minHeight: Spacing.touch, alignment: .leading)
            .contentShape(Rectangle())
            .pixelPanel(fill: Palette.surface, border: isNearest ? Palette.borderStrong : Palette.border)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(spokenLabel)
        .accessibilityHint("Uses this line for the sync.")
        .accessibilityIdentifier(AX.Sync.candidate(cue.id))
    }

    private var spokenLabel: String {
        var parts = [SyncFormat.oneLine(cue.plainText)]
        if let original { parts.append("Original: \(original)") }
        parts.append("Starts at \(SyncFormat.precise(cue.start)) in the file")
        parts.append(SyncFormat.relativeToMark(delta))
        return parts.joined(separator: ". ")
    }
}

// MARK: - c) Review

private struct SyncReviewStep: View {
    let model: GuidedSyncModel
    let session: PlayerSession
    let onDone: () -> Void

    var body: some View {
        if let cue = model.selectedCue, let mark = model.markedTime {
            VStack(alignment: .leading, spacing: Spacing.md) {
                selectedLine(cue, mark: mark)
                computedBlock(cue, mark: mark)
                if let problem = model.twoPointProblem {
                    SyncWarning(text: problem)
                }
                if model.applied {
                    appliedBlock
                } else {
                    applyBlock
                }
            }
        } else {
            VStack(spacing: Spacing.md) {
                PixelMessage(glyph: .info, title: "Pick the line again",
                             message: "The line you chose is no longer in the active track.")
                Button {
                    model.backToChoose()
                } label: {
                    Text("Choose a line").frame(maxWidth: .infinity, minHeight: Spacing.touch)
                }
                .buttonStyle(PixelButtonStyle(kind: .primary))
                .accessibilityIdentifier(AX.Sync.back)
            }
        }
    }

    private func selectedLine(_ cue: SubtitleCue, mark: TimeInterval) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            SectionLabel(model.pointNumber == 2 ? "Second line" : "Your line")
            SubtitleLineText(text: cue.plainText, rightToLeft: model.isRightToLeft)
            if let original = model.originalText(for: cue) {
                Text(original)
                    .font(Typo.reading)
                    .foregroundStyle(Palette.textSecondary)
            }
            Text("Starts at \(SyncFormat.precise(cue.start)) in the file \u{00B7} you marked \(SyncFormat.precise(mark))")
                .font(SyncFont.mono)
                .foregroundStyle(Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pixelPanel(fill: Palette.surface)
    }

    @ViewBuilder
    private func computedBlock(_ cue: SubtitleCue, mark: TimeInterval) -> some View {
        let computed = model.computedTiming
        let current = session.timing
        VStack(alignment: .leading, spacing: Spacing.xs) {
            SectionLabel(model.pointNumber == 2 ? "Two-point correction" : "Computed offset")
            Text(computed.map { SyncFormat.signedOffset($0.offset) } ?? "\u{2014}")
                .font(SyncFont.readout)
                .monospacedDigit()
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .accessibilityIdentifier(AX.Sync.computedOffset)
            if let computed {
                Text(model.applied ? SyncFormat.meaning(computed) : SyncFormat.prospectiveMeaning(computed))
                    .font(Typo.reading)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if model.pointNumber == 2 {
                    Text(stretchDescription(computed.scale))
                        .font(Typo.reading)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier(AX.Sync.drift)
                } else {
                    Text("\(SyncFormat.precise(mark)) (your mark) \(SyncFormat.minus) \(SyncFormat.precise(cue.start)) (line start) = \(SyncFormat.signedOffset(mark - cue.start * computed.scale))")
                        .font(SyncFont.mono)
                        .foregroundStyle(Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    if SyncFormat.hasDrift(computed) {
                        Text("Keeps the existing drift correction \u{00D7}\(SyncFormat.scale(computed.scale)) from an earlier two-point sync.")
                            .font(Typo.callout)
                            .foregroundStyle(Palette.textTertiary)
                    }
                }
                if model.applied && !GuidedSyncModel.same(current, computed) {
                    Text("Now \(SyncFormat.signedOffset(current.offset)) after fine-tuning.")
                        .font(Typo.callout)
                        .foregroundStyle(Palette.textSecondary)
                }
            }
        }
    }

    private func stretchDescription(_ scale: Double) -> String {
        let percent = abs(scale - 1) * 100
        let amount = String(format: percent < 0.01 ? "%.4f" : "%.2f", percent)
        let verb = scale >= 1 ? "stretched" : "compressed"
        return "Drift correction \u{00D7}\(SyncFormat.scale(scale)): subtitle timing is \(verb) by \(amount) % so both of your points line up."
    }

    private var applyBlock: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Button {
                model.applyAndPreview()
            } label: {
                HStack(spacing: Spacing.xs) {
                    PixelIcon(.play, size: 16)
                    Text("Apply & preview")
                }
                .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(PixelButtonStyle(kind: .primary))
            .syncDisabled(model.computedTiming == nil || model.twoPointProblem != nil)
            .accessibilityHint("Applies the offset and plays from 2 seconds before your mark.")
            .accessibilityIdentifier(AX.Sync.apply)
            Text("Plays from 2 s before your mark so you can watch the line appear.")
                .font(Typo.callout)
                .foregroundStyle(Palette.textTertiary)
            Button {
                model.backToChoose()
            } label: {
                Text("Choose a different line")
                    .frame(maxWidth: .infinity, minHeight: Spacing.touch)
            }
            .buttonStyle(PixelButtonStyle(kind: .ghost))
            .accessibilityIdentifier(AX.Sync.back)
            if model.pointNumber == 2 {
                cancelSecondPointButton
            }
        }
    }

    private var appliedBlock: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                PixelIcon(.check, size: 14, color: Palette.success)
                Text("Applied. Watch the line appear at your mark.")
                    .font(Typo.reading)
                    .foregroundStyle(Palette.textPrimary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(AX.Sync.status)

            Button {
                model.preview()
            } label: {
                HStack(spacing: Spacing.xs) {
                    PixelIcon(.play, size: 14)
                    Text("Preview again")
                }
                .frame(maxWidth: .infinity, minHeight: Spacing.touch)
            }
            .buttonStyle(PixelButtonStyle(kind: .secondary))
            .accessibilityHint("Plays from 2 seconds before your mark.")
            .accessibilityIdentifier(AX.Sync.preview)

            SectionLabel("Fine-tune", trailing: SyncFormat.signedOffset(session.timing.offset))
            HStack(spacing: Spacing.xs) {
                RepeatingButton(action: { _ in model.fineTune(by: -0.1) }) {
                    NudgeLabel(amount: "\(SyncFormat.minus)0.1 s", direction: "Earlier")
                }
                .accessibilityLabel("Subtitles 0.1 seconds earlier")
                .accessibilityIdentifier(AX.Sync.fineTuneEarlier)
                RepeatingButton(action: { _ in model.fineTune(by: 0.1) }) {
                    NudgeLabel(amount: "+0.1 s", direction: "Later")
                }
                .accessibilityLabel("Subtitles 0.1 seconds later")
                .accessibilityIdentifier(AX.Sync.fineTuneLater)
            }

            HStack(spacing: Spacing.xs) {
                Button {
                    model.undoSync()
                } label: {
                    HStack(spacing: Spacing.xs) {
                        PixelIcon(.undo, size: 14)
                        Text("Undo")
                    }
                    .frame(maxWidth: .infinity, minHeight: Spacing.touch)
                }
                .buttonStyle(PixelButtonStyle(kind: .secondary))
                .accessibilityLabel("Undo sync")
                .accessibilityHint("Restores the timing from before you opened sync.")
                .accessibilityIdentifier(AX.Sync.undo)

                Button {
                    SyncHaptics.success()
                    model.end()
                    onDone()
                } label: {
                    HStack(spacing: Spacing.xs) {
                        PixelIcon(.check, size: 14)
                        Text("Looks right")
                    }
                    .frame(maxWidth: .infinity, minHeight: Spacing.touch)
                }
                .buttonStyle(PixelButtonStyle(kind: .primary))
                .accessibilityHint("Keeps this timing and closes sync.")
                .accessibilityIdentifier(AX.Sync.confirm)
            }

            if model.pointNumber == 1 {
                driftExplanation
            } else {
                cancelSecondPointButton
            }
        }
    }

    private var driftExplanation: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            SectionLabel("Still drifting later on?")
            Text("One sync point fixes a constant delay. If subtitles drift (good at the start, wrong later), add a second point far from the first.")
                .font(Typo.reading)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(AX.Sync.drift)
            Button {
                model.startSecondPoint()
            } label: {
                HStack(spacing: Spacing.xs) {
                    PixelIcon(.plus, size: 14)
                    Text("Add a second point")
                }
                .frame(maxWidth: .infinity, minHeight: Spacing.touch)
            }
            .buttonStyle(PixelButtonStyle(kind: .secondary))
            .accessibilityHint("Mark another line at least a minute away to correct drift.")
            .accessibilityIdentifier(AX.Sync.secondPoint)
        }
        .padding(Spacing.sm)
        .pixelPanel(fill: Palette.surface)
    }

    private var cancelSecondPointButton: some View {
        Button {
            model.cancelSecondPoint()
        } label: {
            Text(model.applied ? "Remove second point (keep the first)" : "Cancel second point")
                .frame(maxWidth: .infinity, minHeight: Spacing.touch)
        }
        .buttonStyle(PixelButtonStyle(kind: .ghost))
        .accessibilityIdentifier(AX.Sync.cancelSecondPoint)
    }
}
