import Foundation
import Observation
import SubtitleKit
import LibraryKit
import TranslationKit

// OWNER: translation agent. State behind TranslationSheet; the long-running job itself lives in
// TranslationService so it survives the sheet being closed (except on-device jobs, which pause).

@Observable
@MainActor
final class TranslationSheetModel {
    enum SourceState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    enum Stage: Equatable {
        case noTracks
        case notTranslatable(String)
        case loadingSource
        case sourceFailed(String)
        /// Ready to start, resume or use the cache.
        case ready
        case running
        case failed(String)
        /// An Arabic track exists for the selected source (nil id: saved but not listed yet).
        case done(trackID: String?)
    }

    let session: PlayerSession
    var service: TranslationService { session.services.translation }

    private(set) var selectedTrackID: String? = nil
    private(set) var providerID: String
    private(set) var sourceDocument: SubtitleDocument? = nil
    private(set) var sourceState: SourceState = .idle
    private(set) var preparation: TranslationPreparation? = nil
    var confirming = false
    var showingKeyEntry = false
    /// The one-time "You're using your ChatGPT plan" notice is on screen.
    private(set) var showingPlanNotice = false
    /// The user asked to translate again although an Arabic track exists.
    private(set) var wantsNewTranslation = false

    var exportApplyOffset = false
    var exportRTLMarks = true
    private(set) var exportedURL: URL? = nil
    private(set) var exportError: String? = nil
    private(set) var existingPreview: [String] = []

    @ObservationIgnored private var loadTask: Task<Void, Never>? = nil

    init(session: PlayerSession) {
        self.session = session
        self.providerID = session.services.translation.preferredProviderID
    }

    // MARK: Tracks

    nonisolated static func isTranslation(_ track: SubtitleTrackDescriptor) -> Bool {
        if case .translated = track.origin { return true }
        return false
    }

    var sourceTracks: [SubtitleTrackDescriptor] { session.subtitleTracks.filter { !Self.isTranslation($0) } }
    var translatedTracks: [SubtitleTrackDescriptor] { session.subtitleTracks.filter { Self.isTranslation($0) } }
    var selectedTrack: SubtitleTrackDescriptor? { selectedTrackID.flatMap { id in session.subtitleTracks.first { $0.id == id } } }

    func existingTranslation(for sourceID: String) -> SubtitleTrackDescriptor? {
        session.subtitleTracks.first { track in
            if case let .translated(source, _, _) = track.origin {
                return source == sourceID && track.language?.primary == TranslationService.target.code.primary
            }
            return false
        }
    }

    /// nil when translatable, otherwise the reason shown on the row.
    nonisolated static func unavailableReason(_ track: SubtitleTrackDescriptor) -> String? {
        if track.kind == .image { return "Image-based (PGS/VobSub) — needs OCR, not supported" }
        if track.language?.primary == TargetLanguages.arabic.code.primary { return "Already Arabic" }
        return nil
    }

    private func defaultTrackID() -> String? {
        let candidates = sourceTracks.filter { Self.unavailableReason($0) == nil }
        let english = candidates.filter { $0.language?.primary == "en" }
        let active = session.activeSubtitle?.descriptor
        if let active, !Self.isTranslation(active), candidates.contains(where: { $0.id == active.id }) { return active.id }
        if let active, case let .translated(source, _, _) = active.origin, candidates.contains(where: { $0.id == source }) { return source }
        return (english.first { $0.isDefault } ?? english.first ?? candidates.first)?.id
    }

    // MARK: Job

    var jobKey: TranslationJobKey? { selectedTrackID.map { TranslationJobKey(itemID: session.itemID, sourceTrackID: $0) } }
    var job: TranslationJobState? { jobKey.flatMap { service.jobs[$0] } }
    var descriptor: TranslationProviderDescriptor { service.descriptor(for: providerID) }
    var providerOption: TranslationProviderOption? { service.providerOptions.first { $0.id == providerID } }

    var spec: TranslationJobSpec? {
        guard let track = selectedTrack, let document = sourceDocument else { return nil }
        return service.makeSpec(itemID: session.itemID, track: track, document: document, providerID: providerID)
    }

    var stage: Stage {
        guard !sourceTracks.isEmpty else { return .noTracks }
        guard let track = selectedTrack else { return .noTracks }
        if let reason = Self.unavailableReason(track) { return .notTranslatable(reason) }
        if let job {
            switch job.phase {
            case .running: return .running
            case let .failed(message): return .failed(message)
            case .completed: if !wantsNewTranslation { return .done(trackID: job.resultTrackID ?? existingTranslation(for: track.id)?.id) }
            case .paused: break
            }
        }
        if !wantsNewTranslation, let existing = existingTranslation(for: track.id) { return .done(trackID: existing.id) }
        switch sourceState {
        case .idle, .loading: return .loadingSource
        case let .failed(message): return .sourceFailed(message)
        case .loaded: return .ready
        }
    }

    /// The translated track to switch to / export for the selected source.
    var translatedTrackID: String? {
        if let id = job?.resultTrackID { return id }
        return selectedTrackID.flatMap { existingTranslation(for: $0)?.id }
    }

    var previewLines: [String] {
        if let preview = job?.preview, !preview.isEmpty { return preview }
        return existingPreview
    }

    /// A paid or plan-backed (ChatGPT) job needs confirmation unless the user already confirmed
    /// this exact job in this app session (retry/resume after an error or cancel).
    var needsConfirmation: Bool {
        guard descriptor.isPaid || descriptor.usesSubscriptionAllowance else { return false }
        guard let job else { return true }
        return job.providerID != providerID || job.modelID != service.modelID(for: providerID)
    }

    var currentTiming: SubtitleTiming {
        guard let source = selectedTrackID else { return .identity }
        return session.services.timing.timing(forKey: TimingStore.key(videoID: session.itemID, timingGroupID: source))
    }

    // MARK: Actions

    func onAppear() async {
        if selectedTrackID == nil || selectedTrack == nil {
            selectedTrackID = defaultTrackID()
        }
        if !service.providerOptions.contains(where: { $0.id == providerID }) { providerID = service.preferredProviderID }
        reload()
        showPlanNoticeIfNeeded()
        await service.refreshAppleAvailability()
        if !service.providerOptions.contains(where: { $0.id == providerID }) { providerID = service.preferredProviderID }
    }

    func selectTrack(_ id: String) {
        guard id != selectedTrackID else { return }
        selectedTrackID = id
        sourceDocument = nil
        preparation = nil
        confirming = false
        wantsNewTranslation = false
        exportedURL = nil
        exportError = nil
        existingPreview = []
        reload()
    }

    func selectProvider(_ id: String) {
        guard let option = service.providerOptions.first(where: { $0.id == id }) else { return }
        if !option.isAvailable, id == ClaudeTranslationProvider.providerID {
            showingKeyEntry = true
            return
        }
        // Signed out (or no model yet): the row explains that sign-in happens in Settings.
        if !option.isAvailable, id == ChatGPTPlan.providerID { return }
        guard id != providerID else { return }
        providerID = id
        confirming = false
        showPlanNoticeIfNeeded()
        Task { await refreshPreparation() }
    }

    func selectChatGPTModel(_ slug: String) {
        guard service.settings.chatGPTModelID != slug else { return }
        service.settings.chatGPTModelID = slug
        confirming = false
        Task { await refreshPreparation() }
    }

    /// Shows the ChatGPT plan notice the first time the plan provider is in use (exactly once:
    /// the flag is saved as soon as it is shown).
    func showPlanNoticeIfNeeded() {
        guard providerID == ChatGPTPlan.providerID, providerOption?.isAvailable == true,
              !service.settings.chatGPTPlanNoticeShown else { return }
        service.settings.chatGPTPlanNoticeShown = true
        showingPlanNotice = true
    }

    func dismissPlanNotice() {
        showingPlanNotice = false
    }

    func selectClaudeModel(_ modelID: String) {
        guard service.settings.claudeModelID != modelID else { return }
        service.settings.claudeModelID = modelID
        confirming = false
        Task { await refreshPreparation() }
    }

    func keySaved() {
        showingKeyEntry = false
        providerID = ClaudeTranslationProvider.providerID
        Task { await refreshPreparation() }
    }

    func reload() {
        loadTask?.cancel()
        loadTask = Task { [weak self] in await self?.loadSource() }
    }

    private func loadSource() async {
        guard let track = selectedTrack, Self.unavailableReason(track) == nil else {
            sourceState = .idle
            return
        }
        if let existing = existingTranslation(for: track.id) { await loadExistingPreview(existing.id) }
        sourceState = .loading
        do {
            let document = try await session.document(for: track.id)
            guard !Task.isCancelled, track.id == selectedTrackID else { return }
            sourceDocument = document
            sourceState = .loaded
            await refreshPreparation()
        } catch {
            guard !Task.isCancelled, track.id == selectedTrackID else { return }
            sourceState = .failed(error.localizedDescription)
        }
    }

    private func loadExistingPreview(_ trackID: String) async {
        guard let document = try? await session.document(for: trackID) else { return }
        existingPreview = TranslationService.preview(of: document)
    }

    func refreshPreparation() async {
        guard let spec else {
            preparation = nil
            return
        }
        let result = await service.prepare(spec)
        // Ignore a stale answer if the selection changed meanwhile.
        if self.spec?.sourceTrackKey == spec.sourceTrackKey, self.spec?.providerID == spec.providerID, self.spec?.modelID == spec.modelID {
            preparation = result
        }
    }

    /// The big button: start, resume, or (paid) show the confirmation first.
    func primaryAction() {
        guard let spec, let key = jobKey else { return }
        if showingPlanNotice { return }
        if providerOption?.isAvailable == false {
            if providerID == ClaudeTranslationProvider.providerID { showingKeyEntry = true }
            return
        }
        if needsConfirmation, !confirming {
            confirming = true
            return
        }
        confirming = false
        wantsNewTranslation = false
        exportedURL = nil
        service.start(spec, key: key, session: session)
    }

    func cancelConfirmation() { confirming = false }

    func cancelJob() {
        guard let key = jobKey else { return }
        service.cancel(key)
    }

    func useCachedResult() {
        guard let spec, let key = jobKey else { return }
        wantsNewTranslation = false
        Task { await service.useCachedResult(spec, key: key, session: session) }
    }

    func discardProgress() {
        guard let spec, let key = jobKey else { return }
        Task {
            await service.discard(spec, key: key)
            await refreshPreparation()
        }
    }

    func translateAgain() {
        guard let key = jobKey else { return }
        wantsNewTranslation = true
        service.clearJob(key)
        exportedURL = nil
        Task {
            if let spec { await service.discardCachedResult(spec) }
            await refreshPreparation()
        }
    }

    func show(trackID: String?) async {
        await session.selectSubtitleTrack(trackID)
    }

    func export() async {
        exportError = nil
        exportedURL = nil
        do {
            let document: SubtitleDocument
            if let key = jobKey, let result = service.resultDocument(for: key) {
                document = result
            } else if let id = translatedTrackID {
                document = try await session.document(for: id)
            } else {
                return
            }
            exportedURL = try service.exportSRT(document, title: session.item.title,
                                                timing: exportApplyOffset ? currentTiming : nil, rtlMarks: exportRTLMarks)
        } catch {
            exportError = error.localizedDescription
        }
    }

    // MARK: Labels

    static func progressLabel(_ p: TranslationProgress) -> String {
        if p.isComplete || p.totalChunks == 0 { return "\(p.completedCues) / \(p.totalCues) lines" }
        let request = min(p.completedChunks + 1, p.totalChunks)
        return "\(p.completedCues) / \(p.totalCues) lines · request \(request) of \(p.totalChunks)"
    }

    static func tokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 10_000 { return "\(Int((Double(n) / 1000).rounded()))k" }
        if n >= 1000 { return String(format: "%.1fk", Double(n) / 1000) }
        return "\(n)"
    }

    static func dollars(_ value: Double) -> String {
        if value < 0.01 { return "< $0.01" }
        return String(format: "$%.2f", value)
    }

    var selectedModel: ClaudeModelOption? { ClaudeModels.option(for: service.settings.claudeModelID) }

    func costRangeLabel(_ estimate: CostEstimate) -> String? {
        guard providerID == ClaudeTranslationProvider.providerID, let model = selectedModel else { return nil }
        let range = estimate.costRange(inputPricePerMTok: model.inputPricePerMTok, outputPricePerMTok: model.outputPricePerMTok)
        return "\(Self.dollars(range.lowerBound)) – \(Self.dollars(range.upperBound))"
    }

    func spentLabel(_ usage: TokenUsage?) -> String? {
        guard let usage, providerID == ClaudeTranslationProvider.providerID || job?.providerID == ClaudeTranslationProvider.providerID,
              let model = ClaudeModels.option(for: job?.modelID ?? service.settings.claudeModelID) else { return nil }
        let total = usage.inputTokens + usage.outputTokens
        let cost = usage.cost(inputPricePerMTok: model.inputPricePerMTok, outputPricePerMTok: model.outputPricePerMTok)
        return "\(Self.tokens(total)) tokens so far · about \(Self.dollars(cost))"
    }
}
