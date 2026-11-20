import Foundation
import SubtitleKit

// OWNER: translation agent. These types are the contract used by the app; extend freely but keep
// the existing signatures (or update every call site in App/Translation yourself).

// MARK: - Languages

/// Everything a provider needs to know about a target language. Arabic is the first fully
/// implemented target; adding a language means adding a profile here (and its post-processing).
public struct TargetLanguageProfile: Hashable, Sendable, Identifiable {
    public var code: LanguageCode
    public var englishName: String
    public var nativeName: String
    public var isRightToLeft: Bool
    /// Style guidance injected into LLM prompts (register, punctuation, names, line length).
    public var promptGuidance: String
    /// Maximum characters per subtitle line we aim for (readability).
    public var maxLineLength: Int
    public var id: String { code.rawValue }

    public init(code: LanguageCode, englishName: String, nativeName: String, isRightToLeft: Bool,
                promptGuidance: String, maxLineLength: Int) {
        self.code = code; self.englishName = englishName; self.nativeName = nativeName
        self.isRightToLeft = isRightToLeft; self.promptGuidance = promptGuidance; self.maxLineLength = maxLineLength
    }
}

public enum TargetLanguages {
    public static var arabic: TargetLanguageProfile {
        TargetLanguageProfile(code: .arabic, englishName: "Arabic", nativeName: "العربية", isRightToLeft: true,
                              promptGuidance: "", maxLineLength: 42)
    }
    /// Fully supported targets, in UI order.
    public static var all: [TargetLanguageProfile] { [arabic] }
    public static func profile(for code: LanguageCode) -> TargetLanguageProfile? { all.first { $0.code.primary == code.primary } }
}

// MARK: - Provider protocol

public struct GlossaryEntry: Codable, Hashable, Sendable {
    public var source: String
    public var target: String
    public init(source: String, target: String) { self.source = source; self.target = target }
}

/// One line handed to a provider. `text` is cleaned for translation (inline tags kept as
/// <i>…</i> only; ASS overrides removed; "\n" line breaks).
public struct TranslationUnit: Codable, Hashable, Sendable {
    public var id: String
    public var text: String
    public init(id: String, text: String) { self.id = id; self.text = text }
}

public struct TranslationChunkRequest: Sendable {
    public var source: LanguageCode
    public var target: TargetLanguageProfile
    /// Lines to translate, in dialogue order. Every id must come back exactly once.
    public var units: [TranslationUnit]
    /// Read-only context: preceding source lines (with their translations when known).
    public var precedingContext: [ContextLine]
    /// Read-only context: following source lines.
    public var followingContext: [ContextLine]
    /// Names/terms already fixed by earlier chunks; providers should reuse them verbatim.
    public var glossary: [GlossaryEntry]

    public struct ContextLine: Codable, Hashable, Sendable {
        public var id: String
        public var source: String
        public var translation: String?
        public init(id: String, source: String, translation: String?) { self.id = id; self.source = source; self.translation = translation }
    }

    public init(source: LanguageCode, target: TargetLanguageProfile, units: [TranslationUnit],
                precedingContext: [ContextLine], followingContext: [ContextLine], glossary: [GlossaryEntry]) {
        self.source = source; self.target = target; self.units = units
        self.precedingContext = precedingContext; self.followingContext = followingContext; self.glossary = glossary
    }
}

public struct TokenUsage: Codable, Hashable, Sendable {
    public var inputTokens: Int
    public var outputTokens: Int
    public init(inputTokens: Int, outputTokens: Int) { self.inputTokens = inputTokens; self.outputTokens = outputTokens }
}

public struct TranslationChunkResponse: Sendable {
    /// id -> translated text.
    public var translations: [String: String]
    /// New or confirmed name/term renderings discovered in this chunk.
    public var glossary: [GlossaryEntry]
    public var usage: TokenUsage?
    public init(translations: [String: String], glossary: [GlossaryEntry] = [], usage: TokenUsage? = nil) {
        self.translations = translations; self.glossary = glossary; self.usage = usage
    }
}

public struct TranslationProviderDescriptor: Hashable, Sendable, Identifiable {
    public var id: String
    public var displayName: String
    /// One-line explanation shown in the provider picker.
    public var summary: String
    /// True when requests cost the user money (requires explicit confirmation before a job).
    public var isPaid: Bool
    public var requiresAPIKey: Bool
    /// True when the provider uses surrounding context and the glossary (LLM providers).
    public var usesContext: Bool
    /// Units per request the job planner should use.
    public var recommendedChunkSize: Int

    public init(id: String, displayName: String, summary: String, isPaid: Bool, requiresAPIKey: Bool,
                usesContext: Bool, recommendedChunkSize: Int) {
        self.id = id; self.displayName = displayName; self.summary = summary; self.isPaid = isPaid
        self.requiresAPIKey = requiresAPIKey; self.usesContext = usesContext; self.recommendedChunkSize = recommendedChunkSize
    }
}

public protocol TranslationProvider: Sendable {
    var descriptor: TranslationProviderDescriptor { get }
    /// Model identifier used for cache keys (e.g. "claude-opus-5-5", "apple-on-device").
    var modelID: String { get }
    func translate(_ request: TranslationChunkRequest) async throws -> TranslationChunkResponse
}

public enum TranslationError: Error, Equatable, Sendable, LocalizedError {
    case missingAPIKey
    case invalidAPIKey
    case rateLimited(retryAfter: TimeInterval?)
    case quotaExceeded
    case network(String)
    case server(status: Int, message: String)
    case refused(String)
    case malformedResponse(String)
    case mappingMismatch(missing: [String], unexpected: [String])
    case unsupportedLanguagePair
    case providerUnavailable(String)
    case nothingToTranslate

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "Add your API key in Settings › Translation first."
        case .invalidAPIKey: return "The API key was rejected. Check it in Settings › Translation."
        case let .rateLimited(after): return after.map { "Rate limited. Try again in \(Int($0)) s." } ?? "Rate limited. Try again shortly."
        case .quotaExceeded: return "Your API account has no remaining credit or quota."
        case let .network(m): return "Network problem: \(m)"
        case let .server(status, m): return "The translation service returned \(status): \(m)"
        case let .refused(m): return "The provider declined this request: \(m)"
        case let .malformedResponse(m): return "Unexpected response from the provider: \(m)"
        case let .mappingMismatch(missing, unexpected): return "Translation did not line up with the original cues (missing \(missing.count), unexpected \(unexpected.count))."
        case .unsupportedLanguagePair: return "This provider cannot translate between these languages."
        case let .providerUnavailable(m): return m
        case .nothingToTranslate: return "This track has no text to translate."
        }
    }
}

// MARK: - Jobs

public struct TranslationJobSpec: Sendable {
    /// Source document (original timestamps). Cue ids are preserved in the result.
    public var source: SubtitleDocument
    /// Stable key of the source track within its video, e.g. "<videoUUID>|emb:mkv:3".
    public var sourceTrackKey: String
    public var sourceLanguage: LanguageCode
    public var target: TargetLanguageProfile
    public var providerID: String
    public var modelID: String
    public var chunkSize: Int
    public var contextSize: Int

    public init(source: SubtitleDocument, sourceTrackKey: String, sourceLanguage: LanguageCode, target: TargetLanguageProfile,
                providerID: String, modelID: String, chunkSize: Int = 40, contextSize: Int = 6) {
        self.source = source; self.sourceTrackKey = sourceTrackKey; self.sourceLanguage = sourceLanguage; self.target = target
        self.providerID = providerID; self.modelID = modelID; self.chunkSize = chunkSize; self.contextSize = contextSize
    }
}

public struct TranslationProgress: Codable, Hashable, Sendable {
    public var completedCues: Int
    public var totalCues: Int
    public var completedChunks: Int
    public var totalChunks: Int
    public var usage: TokenUsage?
    public init(completedCues: Int, totalCues: Int, completedChunks: Int, totalChunks: Int, usage: TokenUsage? = nil) {
        self.completedCues = completedCues; self.totalCues = totalCues
        self.completedChunks = completedChunks; self.totalChunks = totalChunks; self.usage = usage
    }
    public var fraction: Double { totalCues == 0 ? 0 : Double(completedCues) / Double(totalCues) }
}

public struct CostEstimate: Hashable, Sendable {
    public var cueCount: Int
    public var characterCount: Int
    public var requestCount: Int
    public var estimatedInputTokens: Int
    public var estimatedOutputTokens: Int
    public init(cueCount: Int, characterCount: Int, requestCount: Int, estimatedInputTokens: Int, estimatedOutputTokens: Int) {
        self.cueCount = cueCount; self.characterCount = characterCount; self.requestCount = requestCount
        self.estimatedInputTokens = estimatedInputTokens; self.estimatedOutputTokens = estimatedOutputTokens
    }
}

/// Orchestrates a whole-track translation: chunking with context, mapping validation and
/// repair, checkpointing after every chunk (resume after cancel/crash), and a completed cache.
public actor TranslationEngine {
    public init(storeDirectory: URL) {}

    /// Completed translation for exactly this source content + target + provider + model, if cached.
    public func cachedResult(for spec: TranslationJobSpec) -> SubtitleDocument? { nil }

    /// Progress of a resumable partial job, if a checkpoint exists.
    public func checkpointProgress(for spec: TranslationJobSpec) -> TranslationProgress? { nil }

    public func discardCheckpoint(for spec: TranslationJobSpec) {}

    public func estimate(for spec: TranslationJobSpec) -> CostEstimate {
        CostEstimate(cueCount: spec.source.cues.count, characterCount: 0, requestCount: 0, estimatedInputTokens: 0, estimatedOutputTokens: 0)
    }

    /// Runs (or resumes) the job. Reports progress after every chunk. On task cancellation,
    /// saves the checkpoint and throws `CancellationError`. On success returns a document with
    /// the same cue ids/order/timestamps as the source, `language == target.code`, stores it in
    /// the cache and removes the checkpoint.
    public func run(_ spec: TranslationJobSpec, provider: any TranslationProvider,
                    progress: @escaping @Sendable (TranslationProgress) -> Void) async throws -> SubtitleDocument {
        throw TranslationError.providerUnavailable("TranslationEngine not implemented")
    }
}
