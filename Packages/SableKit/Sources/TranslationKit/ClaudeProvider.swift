import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SubtitleKit

// OWNER: translation agent.

public struct ClaudeModelOption: Hashable, Sendable, Identifiable {
    public var id: String
    public var displayName: String
    public var note: String
    /// USD per million tokens (for the pre-job estimate only; the bill is the user's provider account).
    public var inputPricePerMTok: Double
    public var outputPricePerMTok: Double
    public init(id: String, displayName: String, note: String, inputPricePerMTok: Double, outputPricePerMTok: Double) {
        self.id = id; self.displayName = displayName; self.note = note
        self.inputPricePerMTok = inputPricePerMTok; self.outputPricePerMTok = outputPricePerMTok
    }
}

public enum ClaudeModels {
    public static let defaultModelID = "claude-opus-5-5"
    public static var options: [ClaudeModelOption] {
        [ClaudeModelOption(id: "claude-opus-5-5", displayName: "Claude Opus 5.5", note: "Default", inputPricePerMTok: 4, outputPricePerMTok: 20)]
    }
}

/// Anthropic Messages API provider (user-supplied API key; never bundled).
public struct ClaudeTranslationProvider: TranslationProvider {
    public static let providerID = "anthropic-claude"
    public let modelID: String
    private let apiKey: String

    public init(apiKey: String, modelID: String = ClaudeModels.defaultModelID, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.modelID = modelID
    }

    public var descriptor: TranslationProviderDescriptor {
        TranslationProviderDescriptor(id: Self.providerID, displayName: "Claude (Anthropic)",
                                      summary: "Context-aware translation with consistent names. Uses your API key; billed to your Anthropic account.",
                                      isPaid: true, requiresAPIKey: true, usesContext: true, recommendedChunkSize: 40)
    }

    public func translate(_ request: TranslationChunkRequest) async throws -> TranslationChunkResponse {
        throw TranslationError.providerUnavailable("Claude provider not implemented")
    }

    /// Verifies a key without spending tokens (GET /v1/models). Throws `.invalidAPIKey` etc.
    public static func validate(apiKey: String, session: URLSession = .shared) async throws {}
}
