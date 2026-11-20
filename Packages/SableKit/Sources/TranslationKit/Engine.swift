import Foundation
import SubtitleKit

// OWNER: translation agent.

/// Retry behaviour for transient provider errors.
public struct TranslationRetryPolicy: Sendable, Hashable {
    /// Total tries per request (first try included) for rate limits and transient failures.
    public var maxAttempts: Int
    /// Backoff before retry n (1-based); the last value repeats.
    public var backoff: [TimeInterval]
    /// A rate limit asking us to wait longer than this fails the job instead (with a checkpoint).
    public var maxRetryAfter: TimeInterval
    /// Re-requests of only the missing ids before the chunk is split in half.
    public var maxRepairRounds: Int

    public init(maxAttempts: Int = 4, backoff: [TimeInterval] = [2, 4, 8], maxRetryAfter: TimeInterval = 120, maxRepairRounds: Int = 2) {
        self.maxAttempts = maxAttempts; self.backoff = backoff; self.maxRetryAfter = maxRetryAfter
        self.maxRepairRounds = maxRepairRounds
    }

    public static let standard = TranslationRetryPolicy()

    func delay(forRetry n: Int) -> TimeInterval {
        guard !backoff.isEmpty else { return 0 }
        return backoff[min(max(n, 1), backoff.count) - 1]
    }
}

/// Persisted state of a partially translated job.
struct TranslationCheckpoint: Codable, Sendable {
    var version: Int = 1
    var key: String
    var sourceTrackKey: String
    var providerID: String
    var modelID: String
    var target: String
    var totalCues: Int
    var completed: [String: String]
    var glossary: Glossary
    var usage: TokenUsage
    var completedChunks: Int
    var requestsSent: Int
    var repairRequests: Int
    var ignoredUnexpectedIDs: Int
    var fallbackResponses: Int
    var updatedAt: Date
}

/// Orchestrates a whole-track translation: chunking with context, mapping validation and
/// repair, checkpointing after every chunk (resume after cancel/crash), and a completed cache.
///
/// Store layout under `storeDirectory`:
///   checkpoints/<key>.json   partial jobs (completed id -> text, glossary, usage)
///   completed/<key>.json     finished SubtitleDocument (cache)
/// where key = sha256(source cue ids + times + texts | target | provider | model).
public actor TranslationEngine {
    public nonisolated let storeDirectory: URL
    private let retryPolicy: TranslationRetryPolicy
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private var activeKeys: Set<String> = []

    public init(storeDirectory: URL, retryPolicy: TranslationRetryPolicy = .standard,
                sleep: @escaping @Sendable (TimeInterval) async throws -> Void = TranslationEngine.taskSleep) {
        self.storeDirectory = storeDirectory
        self.retryPolicy = retryPolicy
        self.sleep = sleep
    }

    public static let taskSleep: @Sendable (TimeInterval) async throws -> Void = { seconds in
        guard seconds > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    // MARK: Keys and files

    /// Digest of everything that defines the translation input (cue ids, times, texts).
    public nonisolated static func contentDigest(of document: SubtitleDocument) -> String {
        var d = SHA256Digest()
        d.update("sable-translation-source-v1\n")
        for cue in document.cues {
            let startMs = Int((cue.start * 1000).rounded())
            let endMs = Int((cue.end * 1000).rounded())
            d.update("\(cue.id)\u{1F}\(startMs)\u{1F}\(endMs)\u{1F}\(cue.text)\u{1E}")
        }
        return d.hexDigest()
    }

    public nonisolated static func cacheKey(for spec: TranslationJobSpec) -> String {
        SHA256.hex([contentDigest(of: spec.source), spec.target.code.rawValue, spec.providerID, spec.modelID].joined(separator: "|"))
    }

    private var checkpointsDirectory: URL { storeDirectory.appendingPathComponent("checkpoints", isDirectory: true) }
    private var completedDirectory: URL { storeDirectory.appendingPathComponent("completed", isDirectory: true) }

    private func checkpointURL(_ key: String) -> URL { checkpointsDirectory.appendingPathComponent("\(key).json") }
    private func completedURL(_ key: String) -> URL { completedDirectory.appendingPathComponent("\(key).json") }

    private func loadCheckpoint(_ key: String) -> TranslationCheckpoint? {
        guard let data = try? Data(contentsOf: checkpointURL(key)) else { return nil }
        guard let checkpoint = try? Self.decoder.decode(TranslationCheckpoint.self, from: data), checkpoint.key == key else {
            // Unreadable checkpoint (e.g. from a newer version): ignore rather than fail.
            return nil
        }
        return checkpoint
    }

    private func saveCheckpoint(_ checkpoint: TranslationCheckpoint) throws {
        try FileManager.default.createDirectory(at: checkpointsDirectory, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(checkpoint)
        try data.write(to: checkpointURL(checkpoint.key), options: .atomic)
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: Public API

    /// Completed translation for exactly this source content + target + provider + model, if cached.
    public func cachedResult(for spec: TranslationJobSpec) -> SubtitleDocument? {
        let key = Self.cacheKey(for: spec)
        guard let data = try? Data(contentsOf: completedURL(key)),
              let doc = try? Self.decoder.decode(SubtitleDocument.self, from: data),
              doc.cues.count == spec.source.cues.count else { return nil }
        return doc
    }

    /// Progress of a resumable partial job, if a checkpoint exists.
    public func checkpointProgress(for spec: TranslationJobSpec) -> TranslationProgress? {
        let key = Self.cacheKey(for: spec)
        guard let checkpoint = loadCheckpoint(key) else { return nil }
        let plan = TranslationPlan(document: spec.source, chunkSize: spec.chunkSize, contextSize: spec.contextSize)
        return progress(plan: plan, checkpoint: checkpoint, plannedRemainingChunks: plan.remainingChunks(completed: checkpoint.completed).count)
    }

    public func discardCheckpoint(for spec: TranslationJobSpec) {
        try? FileManager.default.removeItem(at: checkpointURL(Self.cacheKey(for: spec)))
    }

    /// Removes a cached completed translation (e.g. "translate again").
    public func discardCachedResult(for spec: TranslationJobSpec) {
        try? FileManager.default.removeItem(at: completedURL(Self.cacheKey(for: spec)))
    }

    /// True while `run` is executing for this spec.
    public func isRunning(_ spec: TranslationJobSpec) -> Bool { activeKeys.contains(Self.cacheKey(for: spec)) }

    /// Character-based estimate for the work that remains (everything for a fresh job):
    /// ~1 token per 3.5 characters of input, counting the per-request prompt overhead and the
    /// context lines each request repeats; Arabic output ~1.3x the source characters at ~1
    /// token per 3 characters, plus JSON framing.
    public func estimate(for spec: TranslationJobSpec) -> CostEstimate {
        let plan = TranslationPlan(document: spec.source, chunkSize: spec.chunkSize, contextSize: spec.contextSize)
        let completed = loadCheckpoint(Self.cacheKey(for: spec))?.completed ?? [:]
        return Self.estimate(plan: plan, completed: completed)
    }

    /// Fixed per-request input overhead: system prompt (translator instructions + language
    /// guidance), output schema and JSON framing.
    public static let promptOverheadTokens = 1_900

    static func estimate(plan: TranslationPlan, completed: [String: String]) -> CostEstimate {
        let chunks = plan.remainingChunks(completed: completed)
        let units = chunks.flatMap { $0 }
        let chars = units.reduce(0) { $0 + $1.text.count }
        guard !units.isEmpty else {
            return CostEstimate(cueCount: 0, characterCount: 0, requestCount: 0, estimatedInputTokens: 0, estimatedOutputTokens: 0)
        }
        let avgLine = Double(chars) / Double(units.count)
        let framingPerUnit = 22.0 // {"id":"123","text":""},
        let n = Double(plan.contextSize)
        // Preceding context carries source + translation (~1.3x), following context source only.
        let contextCharsPerRequest = n * (avgLine * 2.3 + framingPerUnit * 1.5) + n * (avgLine + framingPerUnit)
        let glossaryCharsPerRequest = 12.0 * 28.0
        let requestCount = chunks.count
        let inputChars = Double(chars) + Double(units.count) * framingPerUnit
            + Double(requestCount) * (contextCharsPerRequest + glossaryCharsPerRequest)
        let inputTokens = Double(requestCount * promptOverheadTokens) + inputChars / 3.5
        let outputChars = Double(chars) * 1.3 + Double(units.count) * framingPerUnit + Double(requestCount) * 80
        let outputTokens = outputChars / 3.0
        return CostEstimate(cueCount: units.count, characterCount: chars, requestCount: requestCount,
                            estimatedInputTokens: Int(inputTokens.rounded(.up)), estimatedOutputTokens: Int(outputTokens.rounded(.up)))
    }

    /// Runs (or resumes) the job. Reports progress after every chunk. On task cancellation,
    /// saves the checkpoint and throws `CancellationError`. On success returns a document with
    /// the same cue ids/order/timestamps as the source, `language == target.code`, stores it in
    /// the cache and removes the checkpoint.
    public func run(_ spec: TranslationJobSpec, provider: any TranslationProvider,
                    progress: @escaping @Sendable (TranslationProgress) -> Void) async throws -> SubtitleDocument {
        let key = Self.cacheKey(for: spec)
        let plan = TranslationPlan(document: spec.source, chunkSize: spec.chunkSize, contextSize: spec.contextSize)
        guard !spec.source.cues.isEmpty, !plan.translatableItems.isEmpty else { throw TranslationError.nothingToTranslate }

        if let cached = cachedResult(for: spec) {
            progress(TranslationProgress(completedCues: plan.items.count, totalCues: plan.items.count,
                                         completedChunks: plan.plannedChunkCount, totalChunks: plan.plannedChunkCount))
            return cached
        }
        guard !activeKeys.contains(key) else {
            throw TranslationError.providerUnavailable("This track is already being translated.")
        }
        activeKeys.insert(key)
        defer { activeKeys.remove(key) }

        var checkpoint = loadCheckpoint(key) ?? TranslationCheckpoint(
            key: key, sourceTrackKey: spec.sourceTrackKey, providerID: spec.providerID, modelID: spec.modelID,
            target: spec.target.code.rawValue, totalCues: plan.items.count, completed: [:], glossary: Glossary(), usage: .zero,
            completedChunks: 0, requestsSent: 0, repairRequests: 0, ignoredUnexpectedIDs: 0, fallbackResponses: 0, updatedAt: Date())
        // Cues without words pass through without a request.
        for item in plan.items where !item.needsTranslation { checkpoint.completed[item.id] = item.text }

        let chunks = plan.remainingChunks(completed: checkpoint.completed)
        progress(self.progress(plan: plan, checkpoint: checkpoint, plannedRemainingChunks: chunks.count))

        let context = JobContext(spec: spec, plan: plan, provider: provider, includeContext: provider.descriptor.usesContext)
        for (index, chunk) in chunks.enumerated() {
            do {
                try Task.checkCancellation()
                let translated = try await translateChunk(chunk, context: context, extraKnown: [:], isRepair: false,
                                                          checkpoint: &checkpoint)
                for (id, text) in translated { checkpoint.completed[id] = text }
                checkpoint.completedChunks += 1
                checkpoint.updatedAt = Date()
                try saveCheckpoint(checkpoint)
                progress(self.progress(plan: plan, checkpoint: checkpoint, plannedRemainingChunks: chunks.count - index - 1))
            } catch {
                // Keep whatever finished (usage and partial repairs included) for a later resume.
                checkpoint.updatedAt = Date()
                try? saveCheckpoint(checkpoint)
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                throw error
            }
        }

        let result = Self.resultDocument(spec: spec, plan: plan, completed: checkpoint.completed)
        try FileManager.default.createDirectory(at: completedDirectory, withIntermediateDirectories: true)
        try Self.encoder.encode(result).write(to: completedURL(key), options: .atomic)
        try? FileManager.default.removeItem(at: checkpointURL(key))
        progress(self.progress(plan: plan, checkpoint: checkpoint, plannedRemainingChunks: 0))
        return result
    }

    // MARK: Internals

    private struct JobContext {
        let spec: TranslationJobSpec
        let plan: TranslationPlan
        let provider: any TranslationProvider
        let includeContext: Bool
    }

    private func progress(plan: TranslationPlan, checkpoint: TranslationCheckpoint, plannedRemainingChunks: Int) -> TranslationProgress {
        let done = plan.items.filter { checkpoint.completed[$0.id] != nil }.count
        return TranslationProgress(completedCues: done, totalCues: plan.items.count,
                                   completedChunks: checkpoint.completedChunks,
                                   totalChunks: checkpoint.completedChunks + plannedRemainingChunks,
                                   usage: checkpoint.usage, requestsSent: checkpoint.requestsSent,
                                   repairRequests: checkpoint.repairRequests,
                                   ignoredUnexpectedIDs: checkpoint.ignoredUnexpectedIDs,
                                   fallbackResponses: checkpoint.fallbackResponses)
    }

    /// Translates one planned chunk: request, validate, re-request only the missing ids (with
    /// context) up to `maxRepairRounds` times, then split what is still missing in half,
    /// recursively. A single cue that still fails throws `.mappingMismatch`.
    /// `extraKnown` holds translations finished earlier in the same chunk (context for splits).
    /// On failure (or cancellation) the lines that did come back are written into the
    /// checkpoint, so a resume does not pay for them again.
    private func translateChunk(_ units: [TranslationPlan.Item], context: JobContext, extraKnown: [String: String],
                                isRepair: Bool, checkpoint: inout TranslationCheckpoint) async throws -> [String: String] {
        var result: [String: String] = [:]
        do {
            try await fillChunk(units, context: context, extraKnown: extraKnown, isRepair: isRepair,
                                checkpoint: &checkpoint, result: &result)
            return result
        } catch {
            for (id, text) in result where checkpoint.completed[id] == nil { checkpoint.completed[id] = text }
            throw error
        }
    }

    private func fillChunk(_ units: [TranslationPlan.Item], context: JobContext, extraKnown: [String: String],
                           isRepair: Bool, checkpoint: inout TranslationCheckpoint, result: inout [String: String]) async throws {
        var pending = units
        var round = 0
        var unexpectedSeen: [String] = []
        while !pending.isEmpty {
            try Task.checkCancellation()
            var known = checkpoint.completed
            for (id, text) in extraKnown { known[id] = text }
            for (id, text) in result { known[id] = text }
            let request = context.plan.request(for: pending, completed: known, glossary: checkpoint.glossary,
                                               source: context.spec.sourceLanguage, target: context.spec.target,
                                               includeContext: context.includeContext)
            if round > 0 || isRepair { checkpoint.repairRequests += 1 }
            let response: TranslationChunkResponse
            do {
                response = try await send(request, provider: context.provider, checkpoint: &checkpoint)
            } catch TranslationError.malformedResponse {
                // Truncated (max_tokens) or unparseable: smaller requests usually fix it.
                if pending.count > 1 { break }
                round += 1
                if round > retryPolicy.maxRepairRounds { break }
                continue
            }
            if let usage = response.usage { checkpoint.usage = checkpoint.usage + usage }
            if response.servedByModel != nil { checkpoint.fallbackResponses += 1 }
            let validation = ChunkValidator.validate(response, units: request.units, target: context.spec.target)
            if !validation.unexpected.isEmpty {
                checkpoint.ignoredUnexpectedIDs += validation.unexpected.count
                unexpectedSeen.append(contentsOf: validation.unexpected)
            }
            for (id, text) in validation.accepted { result[id] = text }
            if !response.glossary.isEmpty { checkpoint.glossary.merge(response.glossary) }
            let missing = Set(validation.missing)
            pending = pending.filter { missing.contains($0.id) }
            if pending.isEmpty { break }
            round += 1
            if round > retryPolicy.maxRepairRounds { break }
        }
        guard !pending.isEmpty else { return }
        guard pending.count > 1 else {
            throw TranslationError.mappingMismatch(missing: pending.map(\.id), unexpected: Array(Set(unexpectedSeen)).sorted())
        }
        let mid = pending.count / 2
        for half in [Array(pending[..<mid]), Array(pending[mid...])] {
            var known = extraKnown
            for (id, text) in result { known[id] = text }
            let sub = try await translateChunk(half, context: context, extraKnown: known, isRepair: true, checkpoint: &checkpoint)
            for (id, text) in sub { result[id] = text }
        }
    }

    /// One provider request with retries for rate limits and transient failures.
    private func send(_ request: TranslationChunkRequest, provider: any TranslationProvider,
                      checkpoint: inout TranslationCheckpoint) async throws -> TranslationChunkResponse {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            attempt += 1
            checkpoint.requestsSent += 1
            do {
                return try await provider.translate(request)
            } catch let error as TranslationError {
                if Task.isCancelled { throw CancellationError() }
                let wait: TimeInterval
                switch error {
                case let .rateLimited(retryAfter):
                    if let retryAfter, retryAfter > retryPolicy.maxRetryAfter { throw error }
                    wait = retryAfter ?? retryPolicy.delay(forRetry: attempt)
                case let .server(status, _) where status >= 500 || status == 408 || status == 409:
                    wait = retryPolicy.delay(forRetry: attempt)
                case .network:
                    wait = retryPolicy.delay(forRetry: attempt)
                default:
                    throw error
                }
                guard attempt < retryPolicy.maxAttempts else { throw error }
                try await sleep(wait)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                throw TranslationError.providerUnavailable(error.localizedDescription)
            }
        }
    }

    static func resultDocument(spec: TranslationJobSpec, plan: TranslationPlan, completed: [String: String]) -> SubtitleDocument {
        let cues = spec.source.cues.enumerated().map { position, cue -> SubtitleCue in
            let planID = plan.items[position].id
            var text = completed[planID] ?? ""
            if !plan.items[position].needsTranslation { text = plan.items[position].text }
            return SubtitleCue(id: cue.id, index: cue.index, start: cue.start, end: cue.end, text: text, rawText: nil, style: cue.style)
        }
        let title = spec.source.title.map { "\($0) — \(spec.target.englishName)" } ?? spec.target.englishName
        return SubtitleDocument(format: .srt, cues: cues, language: spec.target.code, title: title, header: nil)
    }
}
