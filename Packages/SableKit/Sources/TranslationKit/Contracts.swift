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
                              promptGuidance: arabicGuidance, maxLineLength: 42)
    }

    /// Arabic subtitle style guide injected into LLM prompts. Stable text (it is part of the
    /// cached system prompt), so edit deliberately.
    static let arabicGuidance = """
    Write Modern Standard Arabic (الفصحى المعاصرة) as used in professional film and TV subtitles: \
    natural, fluent and idiomatic, never word-for-word. Prefer the wording a skilled Arabic \
    subtitler would choose; keep the register of each speaker (casual, formal, rude, tender) \
    within MSA. Do not use colloquial dialect.

    Length: viewers read while watching. Keep each line at most about 42 characters and each \
    subtitle at most 2 lines. Drop filler ("well", "you know", "I mean", "like") and repetition \
    before you drop meaning. Keep a "\\n" line break where the source has one if both halves \
    read naturally; otherwise break at a natural phrase boundary, or use one line when short.

    Agreement: choose masculine/feminine and singular/dual/plural forms for "you", verbs, \
    adjectives and pronouns from context: who is speaking to whom, names, earlier lines and \
    the translations already given in preceding_context. Once a character is addressed in the \
    feminine (أنتِ، مستيقظة) or plural, stay consistent. When the gender is truly unknown, use \
    the masculine.

    Names: transliterate person and place names into Arabic script with one consistent spelling \
    (Mara → مارا, Idris → إدريس, New York → نيويورك). If a name or term is in the glossary, \
    reuse its target spelling exactly. Report every name and recurring invented term you \
    render in "names". Keep brand names and titles recognisable. Translate titles and forms of \
    address idiomatically: "Mr. Hale" → "السيد هيل", "sir" → "سيدي", "Doctor" → "دكتور".

    Punctuation: use Arabic punctuation ، ؛ ؟ instead of , ; ?. Keep ! . … and the speaker dash \
    "-" at the start of a line. Quotes as «…» or "…". No space before punctuation.

    Numbers: write digits as Western digits 0-9 (2:14, 1984, 3.5), never ٠-٩. Spell out \
    numbers only where Arabic subtitles normally would (e.g. "one day" → "يومًا ما").

    Formatting: keep <i>…</i> and <b>…</b> around the Arabic words that correspond to the \
    tagged English words (whole-line italics stay whole-line). Never add other markup, \
    diacritics-heavy spelling, invisible direction marks or control characters; use tashkeel \
    only where needed to prevent a real ambiguity (e.g. أنتَ / أنتِ).

    Sound and music descriptions: translate them and keep the same brackets, e.g. \
    "[door slams]" → "[يُغلق الباب بقوة]", "(laughs)" → "(يضحك)", "♪ ... ♪" keeps the notes.

    Continuity: a sentence that runs across several units is translated as fragments of one \
    Arabic sentence in the same order, each fragment staying in its own id. Move words between \
    ids only when Arabic word order forces it, and then as little as possible. Never leave an id \
    empty when its source has words.

    Never add notes, explanations, alternatives, transliterations in Latin script or the \
    English text. Output only the Arabic subtitle text for each id.
    """
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

extension TokenUsage {
    public static let zero = TokenUsage(inputTokens: 0, outputTokens: 0)
    public static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        TokenUsage(inputTokens: lhs.inputTokens + rhs.inputTokens, outputTokens: lhs.outputTokens + rhs.outputTokens)
    }
    /// USD for this usage at the given per-million-token prices.
    public func cost(inputPricePerMTok: Double, outputPricePerMTok: Double) -> Double {
        (Double(inputTokens) * inputPricePerMTok + Double(outputTokens) * outputPricePerMTok) / 1_000_000
    }
}

public struct TranslationChunkResponse: Sendable {
    /// id -> translated text.
    public var translations: [String: String]
    /// New or confirmed name/term renderings discovered in this chunk.
    public var glossary: [GlossaryEntry]
    public var usage: TokenUsage?
    /// Model that actually produced the response when it differs from the requested one
    /// (server-side refusal fallback). nil when the requested model answered.
    public var servedByModel: String?
    public init(translations: [String: String], glossary: [GlossaryEntry] = [], usage: TokenUsage? = nil,
                servedByModel: String? = nil) {
        self.translations = translations; self.glossary = glossary; self.usage = usage
        self.servedByModel = servedByModel
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
    /// True when requests count against the user's subscription plan's usage limits (not
    /// dollars), e.g. the ChatGPT plan: the UI must disclose it and get confirmation before a job.
    public var usesSubscriptionAllowance: Bool

    public init(id: String, displayName: String, summary: String, isPaid: Bool, requiresAPIKey: Bool,
                usesContext: Bool, recommendedChunkSize: Int, usesSubscriptionAllowance: Bool = false) {
        self.id = id; self.displayName = displayName; self.summary = summary; self.isPaid = isPaid
        self.requiresAPIKey = requiresAPIKey; self.usesContext = usesContext; self.recommendedChunkSize = recommendedChunkSize
        self.usesSubscriptionAllowance = usesSubscriptionAllowance
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
    /// The subscription sign-in (e.g. Sign in with ChatGPT) is missing, expired or revoked.
    /// Terminal for the job; the checkpoint is kept so Resume continues after signing in.
    case signInRequired(String)
    /// The subscription plan's usage limit is reached. Terminal for the job (no retry, no guessed
    /// reset time); the checkpoint is kept so Resume continues later.
    case planUsageLimitReached
    /// The signed-in account's plan cannot be used by apps. Terminal for the job.
    case planNotEligible(String)

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
        case let .signInRequired(m): return m
        case .planUsageLimitReached:
            return "You've reached your ChatGPT plan's usage limit. Sable paused the translation; finished lines are kept. Check Manage usage in ChatGPT settings, then resume later."
        case let .planNotEligible(m): return m
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
    /// Cues with a final translation (pass-through cues without words count as done).
    public var completedCues: Int
    public var totalCues: Int
    /// Planned chunks finished / planned chunks for the whole job (repairs and splits are
    /// extra requests inside a chunk and do not change these).
    public var completedChunks: Int
    public var totalChunks: Int
    /// Accumulated provider usage for the job (including earlier sessions when resumed).
    public var usage: TokenUsage?
    /// Provider requests actually sent (including repairs, splits and retries).
    public var requestsSent: Int
    /// Repair or split requests made because a response did not line up with the cue ids.
    public var repairRequests: Int
    /// Ids returned by the provider that were not asked for (ignored).
    public var ignoredUnexpectedIDs: Int
    /// Requests answered by a server-side fallback model after a safety decline.
    public var fallbackResponses: Int

    public init(completedCues: Int, totalCues: Int, completedChunks: Int, totalChunks: Int, usage: TokenUsage? = nil,
                requestsSent: Int = 0, repairRequests: Int = 0, ignoredUnexpectedIDs: Int = 0, fallbackResponses: Int = 0) {
        self.completedCues = completedCues; self.totalCues = totalCues
        self.completedChunks = completedChunks; self.totalChunks = totalChunks; self.usage = usage
        self.requestsSent = requestsSent; self.repairRequests = repairRequests
        self.ignoredUnexpectedIDs = ignoredUnexpectedIDs; self.fallbackResponses = fallbackResponses
    }
    public var fraction: Double { totalCues == 0 ? 0 : Double(completedCues) / Double(totalCues) }
    public var isComplete: Bool { totalCues > 0 && completedCues >= totalCues }
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

    /// Approximate USD range for the job. The low end assumes the estimate is a little high
    /// (cached system prompt, short replies); the high end adds room for the model's internal
    /// reasoning tokens (billed as output), repair requests and retries.
    public func costRange(inputPricePerMTok: Double, outputPricePerMTok: Double) -> ClosedRange<Double> {
        let low = (Double(estimatedInputTokens) * 0.8 * inputPricePerMTok
            + Double(estimatedOutputTokens) * 0.9 * outputPricePerMTok) / 1_000_000
        let high = (Double(estimatedInputTokens) * 1.25 * inputPricePerMTok
            + Double(estimatedOutputTokens) * 2.5 * outputPricePerMTok) / 1_000_000
        return low...max(low, high)
    }
}

// `TranslationEngine` lives in Engine.swift.
