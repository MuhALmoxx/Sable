import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SubtitleKit

// OWNER: translation agent.

// MARK: - Models

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

    /// "$4 / $20 per million tokens (input / output)".
    public var priceLabel: String {
        "\(Self.price(inputPricePerMTok)) / \(Self.price(outputPricePerMTok)) per MTok"
    }

    static func price(_ value: Double) -> String {
        if value == value.rounded() { return "$\(Int(value))" }
        return "$" + String(format: "%.2f", value)
    }
}

public enum ClaudeModels {
    public static let defaultModelID = "claude-opus-5-5"
    public static var options: [ClaudeModelOption] {
        [
            ClaudeModelOption(id: "claude-opus-5-5", displayName: "Claude Opus 5.5",
                              note: "Default · best Arabic quality and consistency", inputPricePerMTok: 4, outputPricePerMTok: 20),
            ClaudeModelOption(id: "claude-sonnet-5-5", displayName: "Claude Sonnet 5.5",
                              note: "Faster · about half the price", inputPricePerMTok: 2, outputPricePerMTok: 10),
            ClaudeModelOption(id: "claude-haiku-5-5", displayName: "Claude Haiku 5.5",
                              note: "Fastest · lowest cost · simpler phrasing", inputPricePerMTok: 0.10, outputPricePerMTok: 0.50),
        ]
    }

    public static func option(for id: String) -> ClaudeModelOption? { options.first { $0.id == id } }
}

// MARK: - HTTP

/// Injected transport so tests can run without the network.
public protocol TranslationHTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// URLSession transport with cooperative cancellation (cancels the data task).
public struct URLSessionHTTPClient: TranslationHTTPClient, @unchecked Sendable {
    public let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let box = TaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>) in
                let task = session.dataTask(with: request) { data, response, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let http = response as? HTTPURLResponse {
                        continuation.resume(returning: (data ?? Data(), http))
                    } else {
                        continuation.resume(throwing: URLError(.badServerResponse))
                    }
                }
                box.set(task)
                task.resume()
            }
        } onCancel: {
            box.cancel()
        }
    }

    private final class TaskBox: @unchecked Sendable {
        private let lock = NSLock()
        private var task: URLSessionDataTask?
        private var cancelled = false
        func set(_ task: URLSessionDataTask) {
            lock.lock(); self.task = task; let c = cancelled; lock.unlock()
            if c { task.cancel() }
        }
        func cancel() {
            lock.lock(); cancelled = true; let t = task; lock.unlock()
            t?.cancel()
        }
    }
}

// MARK: - Provider

/// Anthropic Messages API provider (user-supplied API key; never bundled). Raw HTTPS: there is
/// no official Anthropic SDK for Swift, so this follows the documented REST shape.
public struct ClaudeTranslationProvider: TranslationProvider {
    public static let providerID = "anthropic-claude"
    public static let messagesURL = URL(string: "https://api.anthropic.com/v1/messages")!
    public static let modelsURL = URL(string: "https://api.anthropic.com/v1/models?limit=1")!
    public static let apiVersion = "2026-10-21"
    public static let betaHeader = "server-side-fallback-2026-07-01"
    public static let maxTokens = 16_000
    public static let requestTimeout: TimeInterval = 180

    public let modelID: String
    private let apiKey: String
    private let http: any TranslationHTTPClient

    public init(apiKey: String, modelID: String = ClaudeModels.defaultModelID, session: URLSession = .shared) {
        self.init(apiKey: apiKey, modelID: modelID, httpClient: URLSessionHTTPClient(session: session))
    }

    public init(apiKey: String, modelID: String, httpClient: any TranslationHTTPClient) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.modelID = modelID
        self.http = httpClient
    }

    public var descriptor: TranslationProviderDescriptor {
        Self.descriptor
    }

    public static var descriptor: TranslationProviderDescriptor {
        TranslationProviderDescriptor(id: providerID, displayName: "Claude (Anthropic)",
                                      summary: "Context-aware: reads the surrounding lines and keeps names and gender agreement consistent. Uses your API key; billed to your Anthropic account.",
                                      isPaid: true, requiresAPIKey: true, usesContext: true, recommendedChunkSize: 40)
    }

    public func translate(_ request: TranslationChunkRequest) async throws -> TranslationChunkResponse {
        guard !apiKey.isEmpty else { throw TranslationError.missingAPIKey }
        let urlRequest = try makeURLRequest(for: request)
        let (data, response): (Data, HTTPURLResponse)
        do {
            (data, response) = try await http.send(urlRequest)
        } catch {
            throw Self.mapTransportError(error)
        }
        return try Self.parseMessagesResponse(data: data, response: response, requestedModel: modelID,
                                               requestedIDs: request.units.map(\.id))
    }

    /// Verifies a key without spending tokens (GET /v1/models). Throws `.invalidAPIKey` etc.
    public static func validate(apiKey: String, session: URLSession = .shared) async throws {
        try await validate(apiKey: apiKey, httpClient: URLSessionHTTPClient(session: session))
    }

    public static func validate(apiKey: String, httpClient: any TranslationHTTPClient) async throws {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw TranslationError.missingAPIKey }
        var request = URLRequest(url: modelsURL, timeoutInterval: 30)
        request.httpMethod = "GET"
        applyHeaders(to: &request, apiKey: key)
        let (data, response): (Data, HTTPURLResponse)
        do {
            (data, response) = try await httpClient.send(request)
        } catch {
            throw mapTransportError(error)
        }
        guard (200..<300).contains(response.statusCode) else {
            throw mapHTTPError(status: response.statusCode, data: data, response: response, modelID: nil)
        }
    }

    // MARK: Request

    static func applyHeaders(to request: inout URLRequest, apiKey: String, fallbackBeta: Bool = false) {
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        if fallbackBeta { request.setValue(betaHeader, forHTTPHeaderField: "anthropic-beta") }
    }

    /// Server-side refusal fallbacks exist for the Opus/Sonnet/Fable lines; Claude Haiku has none,
    /// so the parameter (and its beta header) is only sent where the API accepts it.
    public static func supportsServerSideFallback(modelID: String) -> Bool {
        !modelID.lowercased().contains("haiku")
    }

    public func makeURLRequest(for request: TranslationChunkRequest) throws -> URLRequest {
        var urlRequest = URLRequest(url: Self.messagesURL, timeoutInterval: Self.requestTimeout)
        urlRequest.httpMethod = "POST"
        Self.applyHeaders(to: &urlRequest, apiKey: apiKey,
                          fallbackBeta: Self.supportsServerSideFallback(modelID: modelID))
        urlRequest.httpBody = requestBody(for: request).data
        return urlRequest
    }

    public func requestBody(for request: TranslationChunkRequest) -> JSONValue {
        let system = ClaudePrompt.system(source: request.source, target: request.target)
        var fields: [(String, JSONValue)] = [
            ("model", .string(modelID)),
            ("max_tokens", .int(Self.maxTokens)),
            // Stable prefix (instructions + language guidance) marked for prompt caching: every
            // chunk of a job reuses it, so later requests read it at a fraction of the price.
            ("system", .array([.object([
                ("type", .string("text")),
                ("text", .string(system)),
                ("cache_control", .object([("type", .string("ephemeral"))])),
            ])])),
            ("messages", .array([.object([
                ("role", .string("user")),
                ("content", .string(ClaudePrompt.userPayload(for: request).serialized())),
            ])])),
            ("output_config", .object([
                ("effort", .string("medium")),
                ("format", .object([
                    ("type", .string("json_schema")),
                    ("schema", ClaudePrompt.outputSchema),
                ])),
            ])),
        ]
        if Self.supportsServerSideFallback(modelID: modelID) {
            fields.append(("fallbacks", .string("default")))
        }
        return .object(fields)
    }

    // MARK: Response

    struct MessagesResponse: Decodable {
        struct Block: Decodable {
            var type: String
            var text: String?
        }
        struct StopDetails: Decodable {
            var category: String?
            var explanation: String?
        }
        struct Usage: Decodable {
            var input_tokens: Int?
            var output_tokens: Int?
            var cache_creation_input_tokens: Int?
            var cache_read_input_tokens: Int?
        }
        var model: String?
        var stop_reason: String?
        var stop_details: StopDetails?
        var content: [Block]?
        var usage: Usage?
    }

    struct ErrorEnvelope: Decodable {
        struct Body: Decodable {
            struct Details: Decodable { var error_code: String? }
            var type: String?
            var message: String?
            var details: Details?
        }
        var error: Body?
    }

    typealias TranslationPayload = SubtitlePrompt.Payload

    static func parseMessagesResponse(data: Data, response: HTTPURLResponse, requestedModel: String,
                                      requestedIDs: [String]) throws -> TranslationChunkResponse {
        guard (200..<300).contains(response.statusCode) else {
            throw mapHTTPError(status: response.statusCode, data: data, response: response, modelID: requestedModel)
        }
        let message: MessagesResponse
        do {
            message = try JSONDecoder().decode(MessagesResponse.self, from: data)
        } catch {
            throw TranslationError.malformedResponse("The response was not valid JSON.")
        }
        switch message.stop_reason {
        case "refusal":
            let explanation = message.stop_details?.explanation?.trimmingCharacters(in: .whitespacesAndNewlines)
            let category = message.stop_details?.category.map { " (\($0))" } ?? ""
            throw TranslationError.refused((explanation?.isEmpty == false ? explanation! : "The model declined to translate part of this track") + category)
        case "max_tokens":
            throw TranslationError.malformedResponse("The reply was cut off (max_tokens).")
        default:
            break
        }
        guard let text = message.content?.first(where: { $0.type == "text" })?.text else {
            throw TranslationError.malformedResponse("The reply contained no text.")
        }
        let payload = try decodePayload(text)
        var translations: [String: String] = [:]
        for item in payload.translations where translations[item.id] == nil {
            translations[item.id] = item.text
        }
        let glossary = (payload.names ?? []).map { GlossaryEntry(source: $0.source, target: $0.target) }
        let usage = message.usage.map { u in
            TokenUsage(inputTokens: (u.input_tokens ?? 0) + (u.cache_creation_input_tokens ?? 0) + (u.cache_read_input_tokens ?? 0),
                       outputTokens: u.output_tokens ?? 0)
        }
        let usedFallback = message.content?.contains(where: { $0.type == "fallback" }) == true
            || (message.model.map { $0 != requestedModel && !$0.hasPrefix(requestedModel) } ?? false)
        return TranslationChunkResponse(translations: translations, glossary: glossary, usage: usage,
                                        servedByModel: usedFallback ? (message.model ?? "fallback") : nil)
    }

    static func decodePayload(_ text: String) throws -> TranslationPayload {
        try SubtitlePrompt.decodePayload(text)
    }

    static func mapHTTPError(status: Int, data: Data, response: HTTPURLResponse, modelID: String?) -> TranslationError {
        let body = (try? JSONDecoder().decode(ErrorEnvelope.self, from: data))?.error
        let message = body?.message ?? HTTPURLResponse.localizedString(forStatusCode: status)
        let lower = message.lowercased()
        switch status {
        case 400:
            if lower.contains("credit") || lower.contains("billing") || lower.contains("balance") { return .quotaExceeded }
            return .server(status: status, message: message)
        case 401, 403:
            return .invalidAPIKey
        case 402:
            return .quotaExceeded
        case 404:
            if let modelID { return .providerUnavailable("The model \(modelID) is not available to this API key. Choose another model in Settings › Translation.") }
            return .server(status: status, message: message)
        case 413:
            return .malformedResponse("The request was too large.")
        case 429:
            if body?.details?.error_code == "enforced_spend_limit_reached" || lower.contains("spend limit") { return .quotaExceeded }
            return .rateLimited(retryAfter: retryAfter(from: response))
        default:
            return .server(status: status, message: message)
        }
    }

    static func retryAfter(from response: HTTPURLResponse) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "retry-after")?.trimmingCharacters(in: .whitespaces),
              let seconds = Double(raw), seconds >= 0 else { return nil }
        return seconds
    }

    static func mapTransportError(_ error: Error) -> Error {
        if error is CancellationError { return error }
        if let urlError = error as? URLError {
            if urlError.code == .cancelled { return CancellationError() }
            switch urlError.code {
            case .timedOut: return TranslationError.network("The request timed out.")
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                return TranslationError.network("You appear to be offline.")
            default: return TranslationError.network(urlError.localizedDescription)
            }
        }
        if let translationError = error as? TranslationError { return translationError }
        return TranslationError.network(error.localizedDescription)
    }
}

// MARK: - Prompt

/// Prompt design: a stable system prompt (cacheable) with the translator brief and the
/// target-language guide, and a per-request JSON payload with the lines, read-only context
/// and the glossary. Output is constrained to a JSON schema (structured outputs).
public enum ClaudePrompt {
    public static func system(source: LanguageCode, target: TargetLanguageProfile) -> String {
        SubtitlePrompt.system(source: source, target: target)
    }

    public static func userPayload(for request: TranslationChunkRequest) -> JSONValue {
        SubtitlePrompt.userPayload(for: request)
    }

    /// JSON schema for structured outputs: { translations: [{id, text}], names: [{source, target}] }.
    public static let outputSchema: JSONValue = SubtitlePrompt.outputSchema
}
