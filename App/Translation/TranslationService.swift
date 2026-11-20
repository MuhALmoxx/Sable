import Foundation
import Observation
import UIKit
import SubtitleKit
import LibraryKit
import TranslationKit

// OWNER: translation agent. AppServices constructs it with `init(library:settings:keychain:)`.

/// One translation job per (video, source track).
struct TranslationJobKey: Hashable, Sendable {
    let itemID: UUID
    let sourceTrackID: String
}

enum TranslationPhase: Equatable {
    case running
    /// Cancelled or interrupted; a checkpoint holds the finished lines.
    case paused
    case failed(String)
    case completed
}

struct TranslationJobState: Equatable {
    var phase: TranslationPhase
    var providerID: String
    var modelID: String
    var progress: TranslationProgress?
    /// Translated track id once saved to the library.
    var resultTrackID: String?
    /// First lines of the result, for the completion preview.
    var preview: [String] = []
    /// The failure needs the user to fix something in Settings (key, quota).
    var needsSettings = false
}

/// What the sheet shows before a job starts.
struct TranslationPreparation: Equatable {
    var hasCachedResult: Bool
    var checkpoint: TranslationProgress?
    var estimate: CostEstimate
}

struct TranslationProviderOption: Identifiable, Equatable {
    let descriptor: TranslationProviderDescriptor
    /// nil when usable; otherwise why not ("Add API key").
    var unavailableReason: String?
    var id: String { descriptor.id }
    var isAvailable: Bool { unavailableReason == nil }

    var tags: [String] {
        var tags: [String] = [descriptor.isPaid ? "Paid" : "Free"]
        if descriptor.id == AppleTranslationProvider.providerID { tags.append("On-device") }
        return tags
    }
}

enum TranslationExportError: LocalizedError {
    case writerUnavailable
    var errorDescription: String? {
        switch self {
        case .writerUnavailable: return "SRT export is not available in this build yet."
        }
    }
}

@Observable
@MainActor
final class TranslationService {
    let library: LibraryStore
    let settings: AppSettings
    let keychain: KeychainStore
    let engine: TranslationEngine
    let appleBroker: AppleTranslationBroker

    static let claudeKeyAccount = "anthropic-api-key"
    static let target = TargetLanguages.arabic

    private(set) var jobs: [TranslationJobKey: TranslationJobState] = [:]
    private(set) var appleAvailability: AppleTranslationAvailability = .unknown
    private(set) var hasClaudeKey = false
    /// Last four characters of the saved key ("…abcd"), never the key itself.
    private(set) var claudeKeySuffix: String? = nil

    @ObservationIgnored private var tasks: [TranslationJobKey: Task<Void, Never>] = [:]
    @ObservationIgnored private var specs: [TranslationJobKey: TranslationJobSpec] = [:]
    @ObservationIgnored private var results: [TranslationJobKey: SubtitleDocument] = [:]
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    init(library: LibraryStore, settings: AppSettings, keychain: KeychainStore) {
        self.library = library
        self.settings = settings
        self.keychain = keychain
        self.engine = TranslationEngine(storeDirectory: library.translationsDirectory)
        self.appleBroker = AppleTranslationBroker()
        refreshKeyState()
        Task { [weak self] in await self?.refreshAppleAvailability() }
    }

    // MARK: Providers

    var isMockEnabled: Bool {
        #if DEBUG
        return UITestSupport.useMockTranslation
        #else
        return false
        #endif
    }

    /// Providers in picker order: Mock (UI tests), Apple on-device (when supported), Claude.
    var providerOptions: [TranslationProviderOption] {
        var options: [TranslationProviderOption] = []
        #if DEBUG
        if UITestSupport.useMockTranslation {
            options.append(TranslationProviderOption(descriptor: MockTranslationProvider.shared.descriptor))
        }
        #endif
        if appleAvailability != .unsupported {
            options.append(TranslationProviderOption(descriptor: AppleTranslationProvider.descriptor))
        }
        options.append(TranslationProviderOption(descriptor: ClaudeTranslationProvider.descriptor,
                                                 unavailableReason: hasClaudeKey ? nil : "Add API key"))
        return options
    }

    /// The provider to preselect: the default from Settings when usable, else the first usable one.
    var preferredProviderID: String {
        #if DEBUG
        if UITestSupport.useMockTranslation { return MockTranslationProvider.providerID }
        #endif
        let options = providerOptions
        if let preferred = options.first(where: { $0.id == settings.translationProviderID && $0.isAvailable }) { return preferred.id }
        return options.first(where: \.isAvailable)?.id ?? AppleTranslationProvider.providerID
    }

    func descriptor(for providerID: String) -> TranslationProviderDescriptor {
        providerOptions.first { $0.id == providerID }?.descriptor ?? AppleTranslationProvider.descriptor
    }

    func modelID(for providerID: String) -> String {
        switch providerID {
        case ClaudeTranslationProvider.providerID: return settings.claudeModelID
        case AppleTranslationProvider.providerID: return "apple-on-device"
        default:
            #if DEBUG
            return MockTranslationProvider.shared.modelID
            #else
            return providerID
            #endif
        }
    }

    func makeProvider(id: String) throws -> any TranslationProvider {
        switch id {
        case ClaudeTranslationProvider.providerID:
            guard let key = keychain.string(for: Self.claudeKeyAccount), !key.isEmpty else { throw TranslationError.missingAPIKey }
            return ClaudeTranslationProvider(apiKey: key, modelID: settings.claudeModelID)
        case AppleTranslationProvider.providerID:
            guard appleAvailability != .unsupported else {
                throw TranslationError.providerUnavailable("On-device translation is not supported on this iPhone.")
            }
            return AppleTranslationProvider(broker: appleBroker)
        default:
            #if DEBUG
            if id == MockTranslationProvider.providerID { return MockTranslationProvider.shared }
            #endif
            throw TranslationError.providerUnavailable("Unknown translation provider.")
        }
    }

    func refreshAppleAvailability() async {
        appleAvailability = await AppleTranslationBroker.availability()
    }

    // MARK: Claude key

    func refreshKeyState() {
        let key = keychain.string(for: Self.claudeKeyAccount)
        hasClaudeKey = !(key ?? "").isEmpty
        claudeKeySuffix = key.flatMap { $0.count >= 8 ? String($0.suffix(4)) : nil }
    }

    func saveClaudeKey(_ raw: String) throws {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw TranslationError.missingAPIKey }
        try keychain.set(key, for: Self.claudeKeyAccount)
        refreshKeyState()
        if settings.translationProviderID != ClaudeTranslationProvider.providerID, appleAvailability == .unsupported {
            settings.translationProviderID = ClaudeTranslationProvider.providerID
        }
    }

    func removeClaudeKey() {
        keychain.remove(Self.claudeKeyAccount)
        refreshKeyState()
    }

    /// GET /v1/models with the saved key (free).
    func validateClaudeKey() async throws {
        guard let key = keychain.string(for: Self.claudeKeyAccount) else { throw TranslationError.missingAPIKey }
        try await ClaudeTranslationProvider.validate(apiKey: key)
    }

    // MARK: Jobs

    static func sourceTrackKey(itemID: UUID, trackID: String) -> String { "\(itemID.uuidString)|\(trackID)" }

    func makeSpec(itemID: UUID, track: SubtitleTrackDescriptor, document: SubtitleDocument, providerID: String) -> TranslationJobSpec {
        let descriptor = descriptor(for: providerID)
        return TranslationJobSpec(source: document, sourceTrackKey: Self.sourceTrackKey(itemID: itemID, trackID: track.id),
                                  sourceLanguage: track.language ?? .english, target: Self.target,
                                  providerID: providerID, modelID: modelID(for: providerID),
                                  chunkSize: descriptor.recommendedChunkSize, contextSize: descriptor.usesContext ? 6 : 0)
    }

    func job(for key: TranslationJobKey) -> TranslationJobState? { jobs[key] }

    func isRunning(_ key: TranslationJobKey) -> Bool { tasks[key] != nil }

    /// Cache, checkpoint and estimate for a spec (no provider requests).
    func prepare(_ spec: TranslationJobSpec) async -> TranslationPreparation {
        let cached = await engine.cachedResult(for: spec) != nil
        let checkpoint = await engine.checkpointProgress(for: spec)
        let estimate = await engine.estimate(for: spec)
        return TranslationPreparation(hasCachedResult: cached, checkpoint: checkpoint, estimate: estimate)
    }

    /// Starts or resumes (the engine continues from a checkpoint automatically).
    func start(_ spec: TranslationJobSpec, key: TranslationJobKey, session: PlayerSession) {
        guard tasks[key] == nil else { return }
        let provider: any TranslationProvider
        do {
            provider = try makeProvider(id: spec.providerID)
        } catch {
            markFailed(key, spec: spec, error: error)
            return
        }
        specs[key] = spec
        var state = TranslationJobState(phase: .running, providerID: spec.providerID, modelID: spec.modelID)
        state.progress = jobs[key]?.progress
        jobs[key] = state

        let engine = self.engine
        let onProgress: @Sendable (TranslationProgress) -> Void = { [weak self] progress in
            Task { @MainActor in self?.updateProgress(key, progress) }
        }
        tasks[key] = Task { [weak self, weak session] in
            do {
                let result = try await engine.run(spec, provider: provider, progress: onProgress)
                await self?.finish(key, spec: spec, result: result, session: session)
            } catch is CancellationError {
                self?.markPaused(key)
            } catch {
                self?.markFailed(key, spec: spec, error: error)
            }
            self?.taskEnded(key)
        }
        updateBackgroundTask()
    }

    /// Stops the job; finished lines stay in the checkpoint.
    func cancel(_ key: TranslationJobKey) {
        tasks[key]?.cancel()
    }

    /// On-device jobs need the Translate sheet on screen; pause them when it closes.
    func pauseOnDeviceJobs() {
        for (key, state) in jobs where state.providerID == AppleTranslationProvider.providerID && state.phase == .running {
            tasks[key]?.cancel()
        }
    }

    func discard(_ spec: TranslationJobSpec, key: TranslationJobKey) async {
        tasks[key]?.cancel()
        await engine.discardCheckpoint(for: spec)
        jobs[key] = nil
    }

    /// Forgets a finished or failed job's state (not its checkpoint or cache).
    func clearJob(_ key: TranslationJobKey) {
        guard tasks[key] == nil else { return }
        jobs[key] = nil
        results[key] = nil
    }

    /// "Translate again": forget the cached result so the next start makes new requests.
    func discardCachedResult(_ spec: TranslationJobSpec) async {
        await engine.discardCachedResult(for: spec)
    }

    /// Saves the cached result as the Arabic track without any provider request.
    func useCachedResult(_ spec: TranslationJobSpec, key: TranslationJobKey, session: PlayerSession) async {
        guard let cached = await engine.cachedResult(for: spec) else {
            markFailed(key, spec: spec, error: TranslationError.providerUnavailable("The cached translation is no longer available."))
            return
        }
        jobs[key] = TranslationJobState(phase: .running, providerID: spec.providerID, modelID: spec.modelID)
        await finish(key, spec: spec, result: cached, session: session)
    }

    /// The finished document for a job in this app session, if any.
    func resultDocument(for key: TranslationJobKey) -> SubtitleDocument? { results[key] }

    private func updateProgress(_ key: TranslationJobKey, _ progress: TranslationProgress) {
        guard var state = jobs[key], state.phase == .running else { return }
        if let old = state.progress, old.completedCues > progress.completedCues, old.totalCues == progress.totalCues { return }
        state.progress = progress
        jobs[key] = state
    }

    private func finish(_ key: TranslationJobKey, spec: TranslationJobSpec, result: SubtitleDocument, session: PlayerSession?) async {
        results[key] = result
        do {
            let ref = try library.saveTranslation(result, sourceTrackID: key.sourceTrackID, providerID: spec.providerID,
                                                  modelID: spec.modelID, to: key.itemID)
            var state = jobs[key] ?? TranslationJobState(phase: .completed, providerID: spec.providerID, modelID: spec.modelID)
            state.phase = .completed
            state.resultTrackID = ref.id
            state.preview = Self.preview(of: result)
            if state.progress == nil || state.progress?.isComplete == false {
                let total = result.cues.count
                state.progress = TranslationProgress(completedCues: total, totalCues: total,
                                                     completedChunks: state.progress?.totalChunks ?? 0,
                                                     totalChunks: state.progress?.totalChunks ?? 0, usage: state.progress?.usage,
                                                     requestsSent: state.progress?.requestsSent ?? 0)
            }
            jobs[key] = state
            if let session {
                session.services.libraryDidChange()
                await session.reloadSubtitleTracks()
            }
        } catch {
            jobs[key] = TranslationJobState(phase: .failed("The translation finished but could not be saved: \(error.localizedDescription)"),
                                            providerID: spec.providerID, modelID: spec.modelID, progress: jobs[key]?.progress)
        }
    }

    private func markPaused(_ key: TranslationJobKey) {
        guard var state = jobs[key] else { return }
        state.phase = .paused
        jobs[key] = state
    }

    private func markFailed(_ key: TranslationJobKey, spec: TranslationJobSpec, error: Error) {
        var state = jobs[key] ?? TranslationJobState(phase: .running, providerID: spec.providerID, modelID: spec.modelID)
        state.phase = .failed(Self.message(for: error))
        if let t = error as? TranslationError {
            switch t {
            case .missingAPIKey, .invalidAPIKey, .quotaExceeded: state.needsSettings = true
            default: state.needsSettings = false
            }
        }
        jobs[key] = state
    }

    private func taskEnded(_ key: TranslationJobKey) {
        tasks[key] = nil
        updateBackgroundTask()
    }

    static func message(for error: Error) -> String {
        if let t = error as? TranslationError {
            if case let .mappingMismatch(missing, _) = t {
                return "Line \(missing.first ?? "?") could not be matched to its translation after several attempts. Finished lines are saved — tap Retry to continue."
            }
            return t.errorDescription ?? "Translation failed."
        }
        return error.localizedDescription
    }

    static func preview(of document: SubtitleDocument, lines: Int = 3) -> [String] {
        document.cues
            .map { TextCleanup.stripInlineTags($0.text).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(lines)
            .map { $0 }
    }

    // MARK: Background execution

    private func updateBackgroundTask() {
        if !tasks.isEmpty, backgroundTask == .invalid {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Sable translation") { [weak self] in
                MainActor.assumeIsolated { self?.backgroundTimeExpired() }
            }
        } else if tasks.isEmpty, backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }

    /// iOS is about to suspend the app: stop jobs (each keeps its checkpoint) and end the task.
    private func backgroundTimeExpired() {
        for task in tasks.values { task.cancel() }
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }

    // MARK: Export

    static var exportsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Exports", isDirectory: true)
    }

    /// Writes "<title>.ar.srt" to Documents/Exports (visible in the Files app) and returns its URL.
    func exportSRT(_ document: SubtitleDocument, title: String, timing: SubtitleTiming?, rtlMarks: Bool) throws -> URL {
        let options = SRTExportOptions(timing: timing, addRTLMarks: rtlMarks, lineEnding: "\r\n", keepInlineTags: true)
        let text = SRTWriter.write(document, options: options)
        guard !text.isEmpty else { throw TranslationExportError.writerUnavailable }
        let directory = Self.exportsDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let code = document.language?.rawValue ?? Self.target.code.rawValue
        let url = directory.appendingPathComponent("\(Self.safeFileName(title)).\(code).srt")
        // UTF-8 with BOM: the most compatible encoding for Arabic SRT in other players and TVs.
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data(text.utf8))
        try data.write(to: url, options: .atomic)
        return url
    }

    static func safeFileName(_ title: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r\t").union(.controlCharacters)
        let cleaned = title.unicodeScalars.map { forbidden.contains($0) ? "_" : String($0) }.joined()
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        let short = String(cleaned.prefix(80))
        return short.isEmpty ? "Subtitles" : short
    }
}
