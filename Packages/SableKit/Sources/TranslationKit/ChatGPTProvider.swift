import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SubtitleKit

// OWNER: translation agent (ChatGPT core).

// MARK: - Models

public struct ChatGPTModel: Codable, Sendable, Hashable, Identifiable {
    public var slug: String
    public var displayName: String
    public var id: String { slug }
    public init(slug: String, displayName: String) { self.slug = slug; self.displayName = displayName }
}

public enum ChatGPTModels {
    /// GET /v1/models, keeps visibility == "list". Maps 401 to ChatGPTAuthError.signInRequired after one forced refresh.
    public static func list(tokens: ChatGPTTokenProvider, httpClient: any TranslationHTTPClient) async throws -> [ChatGPTModel] {
        var forceRefresh = false
        while true {
            let token = try await tokens.accessToken(forceRefresh: forceRefresh)
            var request = URLRequest(url: ChatGPTPlan.modelsURL, timeoutInterval: 30)
            request.httpMethod = "GET"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response): (Data, HTTPURLResponse)
            do {
                (data, response) = try await httpClient.send(request)
            } catch {
                throw ChatGPTTransport.authError(for: error)
            }
            let body = (200..<300).contains(response.statusCode) ? ChatGPTErrorBody() : ChatGPTErrorBody.parse(data)
            if response.statusCode == 401 || body.code == "subscription_sharing_invalid_user" {
                if forceRefresh { throw ChatGPTAuthError.signInRequired }
                forceRefresh = true
                continue
            }
            guard (200..<300).contains(response.statusCode) else {
                throw listError(status: response.statusCode, body: body)
            }
            guard let models = parse(data) else {
                throw ChatGPTAuthError.server(status: response.statusCode, message: "The model list could not be read.")
            }
            return models
        }
    }

    /// Entries with visibility == "list", in server order, de-duplicated by slug. Accepts the
    /// list under "models" or "data" (or a bare array).
    static func parse(_ data: Data) -> [ChatGPTModel]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let entries: [[String: Any]]
        if let object = json as? [String: Any] {
            guard let list = (object["models"] as? [[String: Any]]) ?? (object["data"] as? [[String: Any]]) else { return nil }
            entries = list
        } else if let list = json as? [[String: Any]] {
            entries = list
        } else {
            return nil
        }
        var seen: Set<String> = []
        var models: [ChatGPTModel] = []
        for entry in entries {
            guard (entry["visibility"] as? String) == "list" else { continue }
            let slug = ((entry["slug"] as? String) ?? (entry["id"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !slug.isEmpty, seen.insert(slug).inserted else { continue }
            let name = (entry["display_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            models.append(ChatGPTModel(slug: slug, displayName: name.flatMap { $0.isEmpty ? nil : $0 } ?? slug))
        }
        return models
    }

    static func listError(status: Int, body: ChatGPTErrorBody) -> ChatGPTAuthError {
        switch body.code {
        case "subscription_sharing_user_not_eligible":
            return .server(status: status, message: ChatGPTPlanTranslationProvider.notEligibleMessage)
        case "subscription_sharing_usage_limit_exceeded":
            return .server(status: status, message: ChatGPTPlanTranslationProvider.usageLimitMessage)
        case let code? where code.hasPrefix("chatpass_v2_"):
            return .misconfigured("\(code): \(body.message ?? "the sign-in grant does not allow plan usage")")
        default:
            return .server(status: status, message: body.message ?? HTTPURLResponse.localizedString(forStatusCode: status))
        }
    }
}

// MARK: - Provider

/// Translation through the signed-in user's ChatGPT plan (Responses API, streamed, store=false).
/// Usage counts against the user's ChatGPT plan limits (Plus: shared five-hour total), never
/// API billing.
public struct ChatGPTPlanTranslationProvider: TranslationProvider {
    public static let requestTimeout: TimeInterval = 180
    /// Body fields this flow must never send (OpenAI's ChatGPT plan usage rules).
    public static let forbiddenBodyFields: Set<String> = [
        "background", "conversation", "max_output_tokens", "max_tool_calls", "metadata", "moderation",
        "multi_agent", "prompt", "prompt_cache_retention", "safety_identifier", "temperature",
        "top_logprobs", "top_p", "truncation", "user", "previous_response_id",
    ]
    static let schemaName = "subtitle_translations"
    static let signInAgainMessage = "Sign in with ChatGPT again in Settings › Translation."
    static let signInFirstMessage = "Sign in with ChatGPT in Settings › Translation first."
    static let notEligibleMessage = "Your ChatGPT account isn't eligible for plan usage in apps. ChatGPT Plus or Pro is required."
    static let usageLimitMessage = "You've reached your ChatGPT plan's usage limit. Check Manage usage in ChatGPT settings."
    static let temporarilyUnavailableMessage = "ChatGPT plan usage is temporarily unavailable. Sable will try again shortly."

    public let modelID: String
    private let tokens: ChatGPTTokenProvider
    private let http: any TranslationHTTPClient
    private let options = RequestOptions()

    public init(modelID: String, tokens: ChatGPTTokenProvider, httpClient: any TranslationHTTPClient) {
        self.modelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.tokens = tokens
        self.http = httpClient
    }

    public var descriptor: TranslationProviderDescriptor { Self.descriptor }

    public static var descriptor: TranslationProviderDescriptor {
        TranslationProviderDescriptor(id: ChatGPTPlan.providerID, displayName: "ChatGPT plan",
                                      summary: "Context-aware: reads the surrounding lines and keeps names and gender agreement consistent. Sign in with ChatGPT (Plus or Pro required); uses your ChatGPT plan's usage limits, not API billing.",
                                      isPaid: false, requiresAPIKey: false, usesContext: true, recommendedChunkSize: 40,
                                      usesSubscriptionAllowance: true)
    }

    /// False once the server rejected the JSON-schema `text.format` for this provider: later
    /// requests ask for JSON in the instructions only.
    var usesStructuredOutput: Bool { options.structuredOutput }

    public func translate(_ request: TranslationChunkRequest) async throws -> TranslationChunkResponse {
        guard !modelID.isEmpty else {
            throw TranslationError.providerUnavailable("Choose a ChatGPT model in Settings › Translation.")
        }
        var forceRefresh = false
        var retriedAuthorization = false
        var retriedWithoutFormat = false
        while true {
            let token = try await accessToken(forceRefresh: forceRefresh)
            forceRefresh = false
            let structured = options.structuredOutput
            let urlRequest = makeURLRequest(for: request, accessToken: token, structuredOutput: structured)
            let (data, response): (Data, HTTPURLResponse)
            do {
                (data, response) = try await http.send(urlRequest)
            } catch {
                throw ClaudeTranslationProvider.mapTransportError(error)
            }
            switch Self.interpret(data: data, response: response, requestedModel: modelID) {
            case let .success(result):
                return result
            case .failure(.unauthorized):
                // One forced refresh and one retry; a second rejection means sign in again.
                guard !retriedAuthorization else { throw TranslationError.signInRequired(Self.signInAgainMessage) }
                retriedAuthorization = true
                forceRefresh = true
            case let .failure(.unsupportedCapability(param, message)):
                if structured, !retriedWithoutFormat, Self.concernsTextFormat(param: param, message: message) {
                    // Remove the rejected field (never resend the same body) and remember it.
                    options.disableStructuredOutput()
                    retriedWithoutFormat = true
                } else {
                    let detail = param.map { " (\($0))" } ?? ""
                    throw TranslationError.providerUnavailable("ChatGPT plan usage doesn't support part of Sable's request\(detail).")
                }
            case let .failure(.translation(error)):
                throw error
            }
        }
    }

    // MARK: Request

    public func makeURLRequest(for request: TranslationChunkRequest, accessToken: String,
                               structuredOutput: Bool = true) -> URLRequest {
        var urlRequest = URLRequest(url: ChatGPTPlan.responsesURL, timeoutInterval: Self.requestTimeout)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        urlRequest.httpBody = requestBody(for: request, structuredOutput: structuredOutput).data
        return urlRequest
    }

    /// {"model", "instructions", "input": [user input_text], "text": {"format": json_schema}?,
    /// "stream": true, "store": false}. Never a "system" role item, never a forbidden field.
    public func requestBody(for request: TranslationChunkRequest, structuredOutput: Bool = true) -> JSONValue {
        var fields: [(String, JSONValue)] = [
            ("model", .string(modelID)),
            ("instructions", .string(Self.instructions(source: request.source, target: request.target))),
            ("input", .array([.object([
                ("role", .string("user")),
                ("content", .array([.object([
                    ("type", .string("input_text")),
                    ("text", .string(SubtitlePrompt.userPayload(for: request).serialized())),
                ])])),
            ])])),
        ]
        if structuredOutput {
            fields.append(("text", .object([("format", .object([
                ("type", .string("json_schema")),
                ("name", .string(Self.schemaName)),
                ("schema", SubtitlePrompt.outputSchema),
                ("strict", .bool(true)),
            ]))])))
        }
        fields.append(("stream", .bool(true)))
        fields.append(("store", .bool(false)))
        return .object(fields)
    }

    /// Same translator brief and target-language guide as the Claude provider, plus the reply
    /// format in words (identical for every chunk, with or without the JSON schema).
    public static func instructions(source: LanguageCode, target: TargetLanguageProfile) -> String {
        SubtitlePrompt.system(source: source, target: target) + "\n\n" + SubtitlePrompt.jsonReplyInstruction
    }

    // MARK: Response

    enum Failure: Error, Equatable {
        /// 401 / subscription_sharing_invalid_user: refresh once and retry.
        case unauthorized
        /// subscription_sharing_unsupported_capability: remove error.param and resend once.
        case unsupportedCapability(param: String?, message: String?)
        case translation(TranslationError)
    }

    static func interpret(data: Data, response: HTTPURLResponse, requestedModel: String) -> Result<TranslationChunkResponse, Failure> {
        guard (200..<300).contains(response.statusCode) else {
            return .failure(classify(status: response.statusCode, body: ChatGPTErrorBody.parse(data), modelID: requestedModel))
        }
        switch ChatGPTStream.parse(data) {
        case let .completed(result):
            return chunkResponse(from: result, requestedModel: requestedModel)
        case let .failed(body):
            return .failure(classify(status: nil, body: body, modelID: requestedModel))
        case let .incomplete(reason):
            if reason == "content_filter" {
                return .failure(.translation(.refused("ChatGPT stopped the reply (content filter).")))
            }
            return .failure(.translation(.malformedResponse("The reply was cut off (\(reason ?? "incomplete")).")))
        case .truncated:
            return .failure(.translation(.network("The reply stream ended before it completed.")))
        case .unreadable:
            return .failure(.translation(.malformedResponse("The reply was not a ChatGPT response stream.")))
        }
    }

    static func chunkResponse(from result: ChatGPTStream.Result, requestedModel: String) -> Result<TranslationChunkResponse, Failure> {
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            if let refusal = result.refusal?.trimmingCharacters(in: .whitespacesAndNewlines), !refusal.isEmpty {
                return .failure(.translation(.refused(refusal)))
            }
            return .failure(.translation(.malformedResponse("The reply contained no text.")))
        }
        let payload: SubtitlePrompt.Payload
        do {
            payload = try SubtitlePrompt.decodePayload(text)
        } catch let error as TranslationError {
            return .failure(.translation(error))
        } catch {
            return .failure(.translation(.malformedResponse("The reply did not match the translation format.")))
        }
        let parsed = SubtitlePrompt.translations(from: payload)
        // servedByModel is only set when another model answered (the engine counts those as
        // fallbacks); dated snapshots of the requested model ("gpt-x-2026-01-01") are the same model.
        let served = result.model.flatMap { $0 == requestedModel || $0.hasPrefix(requestedModel) ? nil : $0 }
        return .success(TranslationChunkResponse(translations: parsed.translations, glossary: parsed.glossary,
                                                 usage: result.usage, servedByModel: served))
    }

    /// Maps an error (HTTP status before the stream, or a streamed error.code) for the engine.
    /// Messages never include request headers or tokens.
    static func classify(status: Int?, body: ChatGPTErrorBody, modelID: String) -> Failure {
        let code = body.code?.lowercased()
        switch code {
        case "subscription_sharing_invalid_user", "invalid_api_key", "token_expired", "invalid_token":
            return .unauthorized
        case "subscription_sharing_user_not_eligible":
            return .translation(.planNotEligible(notEligibleMessage))
        case "subscription_sharing_usage_limit_exceeded", "usage_limit_reached", "usage_limit_exceeded":
            return .translation(.planUsageLimitReached)
        case "subscription_sharing_usage_unavailable", "subscription_sharing_user_unavailable":
            return .translation(.server(status: 503, message: temporarilyUnavailableMessage))
        case "subscription_sharing_unsupported_capability":
            return .unsupportedCapability(param: body.param, message: body.message)
        case "subscription_sharing_route_not_supported":
            return .translation(.providerUnavailable("ChatGPT plan usage doesn't support this kind of request. Choose another provider in Settings › Translation."))
        case let c? where c.hasPrefix("chatpass_v2_"):
            return .translation(.providerUnavailable("ChatGPT didn't authorize Sable for plan usage (\(c)). Sign out and sign in with ChatGPT again in Settings › Translation."))
        case "model_not_found":
            return .translation(modelUnavailable(modelID))
        case "context_length_exceeded":
            // Smaller requests fix it: the engine splits malformed/too-large chunks.
            return .translation(.malformedResponse("The request was too large."))
        default:
            break
        }
        let message = body.message ?? status.map { HTTPURLResponse.localizedString(forStatusCode: $0) } ?? "The request failed."
        guard let status else {
            // A streamed failure with an unknown code.
            switch code {
            case "rate_limit_exceeded": return .translation(.rateLimited(retryAfter: nil))
            case nil, "server_error", "internal_error", "server_is_overloaded":
                return .translation(.server(status: 500, message: message))
            case let c?:
                return .translation(.providerUnavailable("ChatGPT couldn't complete the request (\(c)): \(message)"))
            }
        }
        switch status {
        case 401:
            return .unauthorized
        case 403:
            return .translation(.providerUnavailable("ChatGPT declined the request (policy or region): \(message)"))
        case 404:
            return .translation(modelUnavailable(modelID))
        case 413:
            return .translation(.malformedResponse("The request was too large."))
        case 429:
            // Plan usage: pause, no guessed reset time.
            return .translation(.planUsageLimitReached)
        case 503:
            return .translation(.server(status: 503, message: temporarilyUnavailableMessage))
        default:
            return .translation(.server(status: status, message: message))
        }
    }

    static func modelUnavailable(_ modelID: String) -> TranslationError {
        .providerUnavailable("The model \(modelID) isn't available to your ChatGPT account. Choose another model in Settings › Translation.")
    }

    static func concernsTextFormat(param: String?, message: String?) -> Bool {
        if let param = param?.lowercased(), !param.isEmpty {
            return param.contains("text") || param.contains("format")
        }
        let lower = message?.lowercased() ?? ""
        return lower.contains("text.format") || lower.contains("json_schema")
    }

    private func accessToken(forceRefresh: Bool) async throws -> String {
        do {
            return try await tokens.accessToken(forceRefresh: forceRefresh)
        } catch let error as ChatGPTAuthError {
            throw Self.translationError(for: error)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw TranslationError.network(error.localizedDescription)
        }
    }

    static func translationError(for error: ChatGPTAuthError) -> TranslationError {
        switch error {
        case .notSignedIn:
            return .signInRequired(signInFirstMessage)
        case .signInRequired, .invalidIDToken, .accessDenied, .stateMismatch, .missingCode:
            return .signInRequired(signInAgainMessage)
        case let .network(message):
            return .network(message)
        case let .server(status, message):
            return .server(status: status, message: message)
        case .misconfigured, .oauth:
            return .providerUnavailable(error.errorDescription ?? "ChatGPT sign-in failed.")
        }
    }

    /// Lock-protected flags shared by copies of one provider (the struct stays Sendable).
    final class RequestOptions: @unchecked Sendable {
        private let lock = NSLock()
        private var _structuredOutput = true
        var structuredOutput: Bool {
            lock.lock(); defer { lock.unlock() }
            return _structuredOutput
        }
        func disableStructuredOutput() {
            lock.lock(); _structuredOutput = false; lock.unlock()
        }
    }
}

// MARK: - Server-sent events

/// Parses a buffered Responses API event stream ("event: …" / "data: {…}" blocks separated by
/// blank lines). Success only after response.completed.
enum ChatGPTStream {
    struct Result: Equatable {
        var text: String
        var refusal: String?
        var usage: TokenUsage?
        var model: String?
    }

    enum Outcome: Equatable {
        case completed(Result)
        case failed(ChatGPTErrorBody)
        case incomplete(reason: String?)
        /// Events arrived but the stream ended without a terminal event.
        case truncated
        /// Not an event stream (and not a response object).
        case unreadable
    }

    struct Event: Equatable {
        var name: String?
        var data: String
    }

    static func events(in text: String) -> [Event] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var events: [Event] = []
        var name: String?
        var dataLines: [String] = []
        func dispatch() {
            if !dataLines.isEmpty { events.append(Event(name: name, data: dataLines.joined(separator: "\n"))) }
            name = nil
            dataLines = []
        }
        for line in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.isEmpty { dispatch(); continue }
            if line.hasPrefix(":") { continue }
            let field: Substring
            var value: Substring
            if let colon = line.firstIndex(of: ":") {
                field = line[..<colon]
                value = line[line.index(after: colon)...]
                if value.hasPrefix(" ") { value = value.dropFirst() }
            } else {
                field = line
                value = ""
            }
            switch field {
            case "event": name = String(value)
            case "data": dataLines.append(String(value))
            default: continue
            }
        }
        dispatch()
        return events
    }

    static func parse(_ data: Data) -> Outcome {
        let text = String(decoding: data, as: UTF8.self)
        let events = events(in: text)
        if events.isEmpty { return parseResponseObject(data) }
        var deltas = ""
        var doneTexts: [String] = []
        var refusal = ""
        var sawEvent = false
        for event in events {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(event.data.utf8))) as? [String: Any] else { continue }
            sawEvent = true
            let type = (object["type"] as? String) ?? event.name ?? ""
            switch type {
            case "response.output_text.delta":
                if let delta = object["delta"] as? String { deltas += delta }
            case "response.output_text.done":
                if let done = object["text"] as? String { doneTexts.append(done) }
            case "response.refusal.delta":
                if let delta = object["delta"] as? String { refusal += delta }
            case "response.refusal.done":
                if let done = object["refusal"] as? String { refusal = done }
            case "response.completed":
                let response = object["response"] as? [String: Any] ?? [:]
                var result = summary(of: response)
                if result.text.isEmpty { result.text = deltas.isEmpty ? doneTexts.joined() : deltas }
                if result.refusal == nil, !refusal.isEmpty { result.refusal = refusal }
                return .completed(result)
            case "response.failed":
                let response = object["response"] as? [String: Any] ?? [:]
                return .failed(ChatGPTErrorBody.parse(object: response))
            case "response.incomplete":
                let response = object["response"] as? [String: Any] ?? [:]
                let details = response["incomplete_details"] as? [String: Any]
                return .incomplete(reason: details?["reason"] as? String)
            case "error":
                return .failed(ChatGPTErrorBody.parse(object: object))
            default:
                continue
            }
        }
        return sawEvent ? .truncated : .unreadable
    }

    /// Text, refusal, usage and model from a Response object (the response.completed payload).
    static func summary(of response: [String: Any]) -> Result {
        var text = ""
        var refusal: String?
        for item in response["output"] as? [[String: Any]] ?? [] where (item["type"] as? String ?? "message") == "message" {
            for part in item["content"] as? [[String: Any]] ?? [] {
                switch part["type"] as? String {
                case "output_text": text += part["text"] as? String ?? ""
                case "refusal": refusal = (refusal ?? "") + (part["refusal"] as? String ?? "")
                default: continue
                }
            }
        }
        var usage: TokenUsage?
        if let u = response["usage"] as? [String: Any] {
            usage = TokenUsage(inputTokens: ChatGPTJSON.int(u["input_tokens"]) ?? 0, outputTokens: ChatGPTJSON.int(u["output_tokens"]) ?? 0)
        }
        return Result(text: text, refusal: refusal, usage: usage, model: response["model"] as? String)
    }

    /// A non-streamed Response object, in case the server ignored stream=true.
    private static func parseResponseObject(_ data: Data) -> Outcome {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let status = object["status"] as? String else { return .unreadable }
        switch status {
        case "completed": return .completed(summary(of: object))
        case "failed": return .failed(ChatGPTErrorBody.parse(object: object))
        case "incomplete":
            return .incomplete(reason: (object["incomplete_details"] as? [String: Any])?["reason"] as? String)
        default: return .unreadable
        }
    }
}
