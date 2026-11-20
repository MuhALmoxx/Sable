import SwiftUI
import SubtitleKit
import TranslationKit

// OWNER: translation agent. Presented from the player: `TranslationSheet(session:)`.
struct TranslationSheet: View {
    let session: PlayerSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var model: TranslationSheetModel

    init(session: PlayerSession) {
        self.session = session
        _model = State(initialValue: TranslationSheetModel(session: session))
    }

    var body: some View {
        PixelSheet(title: "Translate", subtitle: session.item.title, onClose: { dismiss() }) {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    sourceSection
                    targetSection
                    providerSection
                    statusSection
                }
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.lg)
            }
            .scrollIndicators(.hidden)
        }
        .overlay {
            if model.showingPlanNotice {
                ChatGPTPlanNotice { model.dismissPlanNotice() }
            }
        }
        .modifier(AppleTranslationHost(broker: model.service.appleBroker))
        .task { await model.onAppear() }
        .onDisappear { model.service.pauseOnDeviceJobs() }
        .onChange(of: model.job?.phase) { _, _ in
            Task { await model.refreshPreparation() }
        }
        .onChange(of: session.subtitleTracks) { _, _ in
            if model.selectedTrack == nil { Task { await model.onAppear() } }
        }
        .onChange(of: model.service.modelID(for: model.providerID)) { _, _ in
            // e.g. the ChatGPT model list arrived: the job key (and estimate) depend on the model.
            model.confirming = false
            Task { await model.refreshPreparation() }
        }
        .sheet(isPresented: Bindable(model).showingKeyEntry) {
            ClaudeKeySheet(service: model.service, onSaved: { model.keySaved() })
        }
        .accessibilityIdentifier(AX.Translation.sheet)
    }

    // MARK: Source

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            SectionLabel("Source subtitles")
            if model.sourceTracks.isEmpty {
                Text("This video has no subtitle tracks yet. Import an SRT, ASS or VTT file from the subtitles menu, then translate it here.")
                    .font(Typo.reading)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(model.sourceTracks) { track in
                    let reason = TranslationSheetModel.unavailableReason(track)
                    TranslationChoiceRow(title: Self.trackTitle(track), detail: reason ?? trackDetail(track),
                                         tags: trackTags(track), isSelected: track.id == model.selectedTrackID,
                                         isEnabled: reason == nil && !isBusy,
                                         accessibilityID: AX.Translation.sourceTrack(track.id)) {
                        model.selectTrack(track.id)
                    }
                }
            }
            if !model.translatedTracks.isEmpty {
                ForEach(model.translatedTracks) { track in
                    HStack(spacing: Spacing.xs) {
                        PixelTag("Translation", tint: Palette.textTertiary)
                        Text(Self.trackTitle(track)).font(Typo.callout).foregroundStyle(Palette.textSecondary)
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: 28)
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AX.Translation.sourcePicker)
    }

    static func trackTitle(_ track: SubtitleTrackDescriptor) -> String {
        let language = track.language?.displayName ?? "Unknown language"
        let title = track.title.trimmingCharacters(in: .whitespaces)
        return title.isEmpty || title == language ? language : "\(language) · \(title)"
    }

    private func trackDetail(_ track: SubtitleTrackDescriptor) -> String? {
        if model.existingTranslation(for: track.id) != nil { return "Arabic translation available" }
        return nil
    }

    private func trackTags(_ track: SubtitleTrackDescriptor) -> [String] {
        var tags: [String] = []
        switch track.origin {
        case .embedded: tags.append("Embedded")
        case .external: tags.append("File")
        case .translated: tags.append("Translation")
        }
        tags.append(track.kind == .image ? "Image" : track.format.displayName)
        if track.isDefault { tags.append("Default") }
        if model.existingTranslation(for: track.id) != nil { tags.append("AR ready") }
        return tags
    }

    private var isBusy: Bool { model.stage == .running }

    // MARK: Target

    private var targetSection: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            SectionLabel("Translate to")
            HStack(spacing: Spacing.xs) {
                Text("Arabic ·").font(Typo.bodyMedium).foregroundStyle(Palette.textPrimary)
                Text("\u{200F}العربية").font(Typo.arabic).foregroundStyle(Palette.textPrimary)
                Spacer(minLength: 0)
                PixelTag("RTL")
            }
            .padding(Spacing.sm)
            .frame(maxWidth: .infinity, minHeight: Spacing.touch, alignment: .leading)
            .pixelPanel()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Target language: Arabic")
        }
    }

    // MARK: Provider

    private var providerSection: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            SectionLabel("Translated by")
            ForEach(model.service.providerOptions) { option in
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    TranslationChoiceRow(title: option.descriptor.displayName,
                                         detail: option.descriptor.summary,
                                         tags: option.displayTags,
                                         isSelected: option.id == model.providerID && option.isAvailable,
                                         isEnabled: !isBusy,
                                         accessibilityID: AX.Translation.provider(option.id)) {
                        model.selectProvider(option.id)
                    }
                    if option.id == ChatGPTPlan.providerID, let reason = option.unavailableReason {
                        Text(reason + (reason.hasSuffix("…") || reason.hasSuffix(".") ? "" : "."))
                            .font(Typo.reading).foregroundStyle(Palette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, Spacing.xxs)
                            .accessibilityIdentifier(AX.ChatGPT.unavailableReason)
                    }
                    if option.id == ClaudeTranslationProvider.providerID, !option.isAvailable {
                        Button { model.showingKeyEntry = true } label: {
                            HStack(spacing: Spacing.xs) {
                                PixelIcon(.key, size: 16)
                                Text("Add API key")
                            }
                        }
                        .buttonStyle(PixelButtonStyle(kind: .ghost, compact: true))
                        .frame(minHeight: Spacing.touch)
                        .accessibilityLabel("Add Claude API key")
                        .accessibilityIdentifier(AX.Translation.addAPIKey)
                    }
                }
            }
            if model.providerID == ClaudeTranslationProvider.providerID, model.providerOption?.isAvailable == true {
                claudeModelMenu
            }
            if model.providerID == ChatGPTPlan.providerID, model.providerOption?.isAvailable == true {
                ChatGPTModelMenu(models: model.service.chatGPT.models,
                                 selectedID: model.service.chatGPTModelID,
                                 selectedName: model.service.chatGPTModelName,
                                 isEnabled: !isBusy) { model.selectChatGPTModel($0) }
                ChatGPTUsageIndicator()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AX.Translation.providerPicker)
    }

    private var claudeModelMenu: some View {
        Menu {
            ForEach(ClaudeModels.options) { option in
                Button("\(option.displayName) — \(option.priceLabel)") { model.selectClaudeModel(option.id) }
            }
        } label: {
            HStack(spacing: Spacing.xs) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Model").font(Typo.micro).foregroundStyle(Palette.textTertiary)
                    Text(model.selectedModel.map { "\($0.displayName) · \($0.priceLabel)" } ?? model.service.settings.claudeModelID)
                        .font(Typo.callout).foregroundStyle(Palette.textPrimary)
                }
                Spacer(minLength: 0)
                PixelIcon(.chevronDown, size: 14, color: Palette.textSecondary)
            }
            .padding(.horizontal, Spacing.sm)
            .frame(maxWidth: .infinity, minHeight: Spacing.touch, alignment: .leading)
            .pixelPanel()
            .contentShape(Rectangle())
        }
        .disabled(isBusy)
        .accessibilityLabel("Claude model: \(model.selectedModel?.displayName ?? model.service.settings.claudeModelID)")
        .accessibilityIdentifier(AX.Translation.claudeModel)
    }

    // MARK: Status

    @ViewBuilder private var statusSection: some View {
        switch model.stage {
        case .noTracks:
            EmptyView()
        case let .notTranslatable(reason):
            TranslationBanner(glyph: .info, message: reason, tint: Palette.textTertiary) { EmptyView() }
        case .loadingSource:
            loadingSourceView
        case let .sourceFailed(message):
            TranslationBanner(glyph: .warning, message: "Couldn't read this subtitle track. \(message)",
                              accessibilityID: AX.Translation.error) {
                Button("Try again") { model.reload() }
                    .buttonStyle(PixelButtonStyle(kind: .secondary, compact: true))
                    .frame(minHeight: Spacing.touch)
                    .accessibilityIdentifier(AX.Translation.retry)
            }
        case .ready:
            readyView
        case .running:
            runningView
        case let .failed(message):
            failedView(message)
        case let .done(trackID):
            doneView(trackID: trackID)
        }
    }

    private var loadingSourceView: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            SectionLabel("Reading subtitles")
            if case let .loading(progress?) = session.subtitleLoadState {
                PixelProgressBar(value: progress)
                    .accessibilityLabel("Subtitle extraction progress")
            }
            Text("Reading the source track (embedded tracks are extracted once)…")
                .font(Typo.reading).foregroundStyle(Palette.textSecondary)
        }
    }

    @ViewBuilder private var readyView: some View {
        let preparation = model.preparation
        VStack(alignment: .leading, spacing: Spacing.sm) {
            if let estimate = preparation?.estimate, !model.confirming {
                Text(summaryLine(estimate, checkpoint: preparation?.checkpoint))
                    .font(Typo.reading).foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(AX.Translation.estimate)
            }
            if model.confirming, let estimate = preparation?.estimate {
                confirmationPanel(estimate)
            } else if preparation?.hasCachedResult == true {
                Button { model.useCachedResult() } label: {
                    Label { Text("Already translated — use cached result") } icon: { PixelIcon(.check, size: 18) }
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PixelButtonStyle(kind: .primary))
                .accessibilityHint("Saves the earlier translation as the Arabic track without new requests.")
                .accessibilityIdentifier(AX.Translation.useCached)
                Button("Translate again") { model.translateAgain() }
                    .buttonStyle(PixelButtonStyle(kind: .ghost, compact: true))
                    .frame(minHeight: Spacing.touch)
                    .accessibilityIdentifier(AX.Translation.translateAgain)
            } else if let checkpoint = preparation?.checkpoint {
                Button { model.primaryAction() } label: {
                    Label { Text("Resume (\(checkpoint.completedCues) of \(checkpoint.totalCues) lines done)") } icon: { PixelIcon(.play, size: 18) }
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PixelButtonStyle(kind: .primary))
                .accessibilityIdentifier(AX.Translation.resume)
                PixelProgressBar(value: checkpoint.fraction)
                Button("Discard progress and start over") { model.discardProgress() }
                    .buttonStyle(PixelButtonStyle(kind: .destructive, compact: true))
                    .frame(minHeight: Spacing.touch)
                    .accessibilityIdentifier(AX.Translation.discard)
            } else {
                Button { model.primaryAction() } label: {
                    Label { Text("Translate to Arabic") } icon: { PixelIcon(.translate, size: 18) }
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PixelButtonStyle(kind: .primary))
                .disabled(preparation == nil)
                .accessibilityIdentifier(AX.Translation.start)
            }
            privacyNote
        }
    }

    private func summaryLine(_ estimate: CostEstimate, checkpoint: TranslationProgress?) -> String {
        let lines = estimate.cueCount == 1 ? "1 line" : "\(estimate.cueCount) lines"
        let requests = estimate.requestCount == 1 ? "1 request" : "\(estimate.requestCount) requests"
        if checkpoint != nil { return "\(lines) left · \(requests)." }
        return "\(lines) · \(requests)."
    }

    private var privacyNote: some View {
        Group {
            switch model.providerID {
            case ClaudeTranslationProvider.providerID:
                Text("The subtitle text of this track is sent to Anthropic with your API key and billed to your Anthropic account. Nothing is sent until you confirm.")
            case ChatGPTPlan.providerID:
                Text("The subtitle text of this track is sent to OpenAI with your ChatGPT sign-in and counts toward your ChatGPT plan's usage limits. Sable charges nothing. Nothing is sent until you confirm.")
            case AppleTranslationProvider.providerID:
                Text("Runs on this iPhone; nothing leaves the device. Keep this sheet open while it works — closing it pauses the job and keeps finished lines.")
            default:
                Text("Debug mock: no network, deterministic output.")
            }
        }
        .font(Typo.reading)
        .foregroundStyle(Palette.textTertiary)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func confirmationPanel(_ estimate: CostEstimate) -> some View {
        if model.descriptor.usesSubscriptionAllowance {
            planConfirmationPanel(estimate)
        } else {
            paidConfirmationPanel(estimate)
        }
    }

    /// ChatGPT plan: no price, but the person confirms that the job uses their plan's limits.
    private func planConfirmationPanel(_ estimate: CostEstimate) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            SectionLabel("Confirm ChatGPT plan usage")
            Text("\(model.descriptor.displayName) · \(model.service.chatGPTModelName)")
                .font(Typo.callout).foregroundStyle(Palette.textPrimary)
            VStack(spacing: Spacing.xxs) {
                TranslationFactRow(label: "Lines to translate", value: "\(estimate.cueCount)")
                TranslationFactRow(label: "Requests", value: "\(estimate.requestCount)")
            }
            Text("These requests count toward your ChatGPT plan's usage limits (on Plus, the 5-hour limit is shared with other apps). If you have allowed credits for apps in your ChatGPT settings, they may use credits. Sable itself charges nothing, and this is not OpenAI API usage. You can cancel at any time and keep finished lines.")
                .font(Typo.reading).foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(AX.ChatGPT.confirmation)
            HStack(spacing: Spacing.sm) {
                Button("Not now") { model.cancelConfirmation() }
                    .buttonStyle(PixelButtonStyle(kind: .secondary))
                    .accessibilityIdentifier(AX.Translation.cancelConfirm)
                Button { model.primaryAction() } label: {
                    Text("Confirm and translate").frame(maxWidth: .infinity)
                }
                .buttonStyle(PixelButtonStyle(kind: .primary))
                .accessibilityHint("Starts the translation using your ChatGPT plan.")
                .accessibilityIdentifier(AX.Translation.confirmPaid)
            }
        }
        .padding(Spacing.sm)
        .pixelPanel(fill: Palette.surface, border: Palette.borderStrong)
    }

    private func paidConfirmationPanel(_ estimate: CostEstimate) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            SectionLabel("Confirm paid translation")
            if model.providerID == ClaudeTranslationProvider.providerID, let option = model.selectedModel {
                Text("\(option.displayName) · \(option.priceLabel)").font(Typo.callout).foregroundStyle(Palette.textPrimary)
            } else {
                Text(model.descriptor.displayName).font(Typo.callout).foregroundStyle(Palette.textPrimary)
            }
            VStack(spacing: Spacing.xxs) {
                TranslationFactRow(label: "Lines to translate", value: "\(estimate.cueCount)")
                TranslationFactRow(label: "Requests", value: "\(estimate.requestCount)")
                TranslationFactRow(label: "Estimated tokens",
                                   value: "≈ \(TranslationSheetModel.tokens(estimate.estimatedInputTokens)) in · \(TranslationSheetModel.tokens(estimate.estimatedOutputTokens)) out")
                if let cost = model.costRangeLabel(estimate) {
                    TranslationFactRow(label: "Approximate cost", value: cost)
                }
            }
            Text("Billed by Anthropic to your account; the range allows for the model's reasoning tokens and occasional repair requests. You can cancel at any time and keep finished lines.")
                .font(Typo.reading).foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Spacing.sm) {
                Button("Not now") { model.cancelConfirmation() }
                    .buttonStyle(PixelButtonStyle(kind: .secondary))
                    .accessibilityIdentifier(AX.Translation.cancelConfirm)
                Button { model.primaryAction() } label: {
                    Text("Confirm and translate").frame(maxWidth: .infinity)
                }
                .buttonStyle(PixelButtonStyle(kind: .primary))
                .accessibilityIdentifier(AX.Translation.confirmPaid)
            }
        }
        .padding(Spacing.sm)
        .pixelPanel(fill: Palette.surface, border: Palette.borderStrong)
    }

    private var runningView: some View {
        let progress = model.job?.progress
        return VStack(alignment: .leading, spacing: Spacing.sm) {
            SectionLabel("Translating", trailing: progress.map { "\(Int(($0.fraction * 100).rounded()))%" })
            PixelProgressBar(value: progress?.fraction ?? 0, height: 8)
                .accessibilityLabel("Translation progress")
                .accessibilityIdentifier(AX.Translation.progress)
            Text(progress.map { TranslationSheetModel.progressLabel($0) } ?? "Starting…")
                .font(Typo.mono).foregroundStyle(Palette.textPrimary)
                .accessibilityIdentifier(AX.Translation.progressLabel)
            if let spent = model.spentLabel(progress?.usage) {
                Text(spent).font(Typo.callout).foregroundStyle(Palette.textSecondary)
            }
            if model.job?.providerID == AppleTranslationProvider.providerID {
                Text(model.service.appleBroker.isPreparing
                     ? "Waiting for iOS to prepare the languages (it may ask to download them)…"
                     : "Keep this sheet open — on-device translation pauses when it closes.")
                    .font(Typo.reading).foregroundStyle(Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("You can close this sheet; translation continues while Sable is open. Finished lines are saved after every request.")
                    .font(Typo.reading).foregroundStyle(Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button { model.cancelJob() } label: {
                Text("Cancel").frame(maxWidth: .infinity)
            }
            .buttonStyle(PixelButtonStyle(kind: .secondary))
            .accessibilityHint("Stops translating. Finished lines are kept so you can resume.")
            .accessibilityIdentifier(AX.Translation.cancel)
        }
    }

    private func failedView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            if model.job?.planLimitReached == true {
                planLimitBanner(message)
            } else {
                failureBanner(message)
            }
            if let progress = model.job?.progress, progress.completedCues > 0 {
                Text("\(progress.completedCues) of \(progress.totalCues) lines are saved; \(model.job?.planLimitReached == true ? "Resume" : "Retry") continues from there.")
                    .font(Typo.reading).foregroundStyle(Palette.textSecondary)
            }
            if model.confirming, let estimate = model.preparation?.estimate {
                confirmationPanel(estimate)
            }
        }
    }

    /// ChatGPT plan usage limit: Manage usage first (no guessed reset time), Resume later.
    private func planLimitBanner(_ message: String) -> some View {
        TranslationBanner(glyph: .warning, message: message, tint: Palette.textSecondary, accessibilityID: AX.Translation.error) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Spacing.sm) { planLimitActions }
                VStack(alignment: .leading, spacing: Spacing.xs) { planLimitActions }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AX.ChatGPT.limitReached)
    }

    @ViewBuilder private var planLimitActions: some View {
        Button { openURL(ChatGPTPlan.manageUsageURL) } label: {
            Label { Text("Manage usage") } icon: { PixelIcon(.export, size: 16) }
        }
        .buttonStyle(PixelButtonStyle(kind: .primary, compact: true))
        .frame(minHeight: Spacing.touch)
        .accessibilityHint("Opens your ChatGPT usage settings in the browser.")
        .accessibilityIdentifier(AX.ChatGPT.manageUsage)
        Button { model.primaryAction() } label: {
            Label { Text("Resume") } icon: { PixelIcon(.play, size: 16) }
        }
        .buttonStyle(PixelButtonStyle(kind: .secondary, compact: true))
        .frame(minHeight: Spacing.touch)
        .accessibilityHint("Continues from the saved lines.")
        .accessibilityIdentifier(AX.Translation.resume)
    }

    private func failureBanner(_ message: String) -> some View {
        TranslationBanner(glyph: .warning, message: message, accessibilityID: AX.Translation.error) {
            HStack(spacing: Spacing.sm) {
                Button { model.primaryAction() } label: {
                    Label { Text("Retry") } icon: { PixelIcon(.reset, size: 16) }
                }
                .buttonStyle(PixelButtonStyle(kind: .primary, compact: true))
                .frame(minHeight: Spacing.touch)
                .accessibilityIdentifier(AX.Translation.retry)
                if model.job?.needsSettings == true, model.providerID == ClaudeTranslationProvider.providerID {
                    Button("API key") { model.showingKeyEntry = true }
                        .buttonStyle(PixelButtonStyle(kind: .secondary, compact: true))
                        .frame(minHeight: Spacing.touch)
                        .accessibilityIdentifier(AX.Translation.addAPIKey)
                }
            }
        }
    }

    private func doneView(trackID: String?) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: Spacing.xs) {
                PixelIcon(.check, size: 16, color: Palette.success)
                Text("Arabic track ready").font(Typo.headline).foregroundStyle(Palette.textPrimary)
                    .accessibilityIdentifier(AX.Translation.done)
            }
            if !model.previewLines.isEmpty {
                ArabicPreview(lines: model.previewLines)
            }
            if let progress = model.job?.progress, let spent = model.spentLabel(progress.usage) {
                Text("Used \(spent.replacingOccurrences(of: " so far", with: ""))").font(Typo.callout).foregroundStyle(Palette.textSecondary)
            }
            if let fallbacks = model.job?.progress?.fallbackResponses, fallbacks > 0 {
                Text("\(fallbacks) request(s) were answered by Anthropic's fallback model after a safety decline.")
                    .font(Typo.reading).foregroundStyle(Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Spacing.sm) {
                Button {
                    Task { await model.show(trackID: trackID); dismiss() }
                } label: {
                    Text("Show Arabic").frame(maxWidth: .infinity)
                }
                .buttonStyle(PixelButtonStyle(kind: .primary))
                .disabled(trackID == nil)
                .accessibilityIdentifier(AX.Translation.showArabic)
                Button {
                    Task { await model.show(trackID: model.selectedTrackID); dismiss() }
                } label: {
                    Text("Show English").frame(maxWidth: .infinity)
                }
                .buttonStyle(PixelButtonStyle(kind: .secondary))
                .accessibilityIdentifier(AX.Translation.showEnglish)
            }
            exportSection
            Button("Translate again") { model.translateAgain() }
                .buttonStyle(PixelButtonStyle(kind: .ghost, compact: true))
                .frame(minHeight: Spacing.touch)
                .accessibilityIdentifier(AX.Translation.translateAgain)
        }
    }

    private var exportSection: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            SectionLabel("Export SRT")
            let offset = model.currentTiming
            PixelCheckRow(title: "Apply current offset",
                          detail: offset.isIdentity ? "No offset set — original timestamps." : "Shifts every line by \(TimecodeFormatter.signedOffset(offset.offset)).",
                          isOn: Bindable(model).exportApplyOffset, accessibilityID: AX.Translation.exportApplyOffset)
            PixelCheckRow(title: "RTL compatibility marks",
                          detail: "Helps players that don't set right-to-left direction place punctuation correctly.",
                          isOn: Bindable(model).exportRTLMarks, accessibilityID: AX.Translation.exportRTLMarks)
            Button {
                Task { await model.export() }
            } label: {
                Label { Text("Export SRT") } icon: { PixelIcon(.export, size: 16) }
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PixelButtonStyle(kind: .secondary))
            .accessibilityIdentifier(AX.Translation.export)
            if let url = model.exportedURL {
                Text("Saved to Files › On My iPhone › Sable › Exports › \(url.lastPathComponent)")
                    .font(Typo.reading).foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(AX.Translation.exportedPath)
                ShareLink(item: url) {
                    Label { Text("Share or save to Files") } icon: { PixelIcon(.export, size: 16) }
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PixelButtonStyle(kind: .secondary))
                .accessibilityIdentifier(AX.Translation.share)
            }
            if let error = model.exportError {
                Text(error).font(Typo.reading).foregroundStyle(Palette.danger)
                    .accessibilityIdentifier(AX.Translation.error)
            }
        }
    }
}

/// Small sheet for entering the Claude key from the Translate sheet.
struct ClaudeKeySheet: View {
    let service: TranslationService
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        PixelSheet(title: "Claude API key", onClose: { dismiss() }) {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    Text("Paste a key from console.anthropic.com. It is stored only in this iPhone's Keychain, and usage is billed to your Anthropic account.")
                        .font(Typo.reading).foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ClaudeAPIKeyEditor(service: service, onSaved: onSaved)
                }
                .padding(Spacing.md)
            }
        }
        .presentationDetents([.medium, .large])
    }
}
