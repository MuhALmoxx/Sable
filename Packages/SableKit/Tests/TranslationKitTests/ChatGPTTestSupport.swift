import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import TranslationKit

/// Fixed clock for the ChatGPT tests.
let chatGPTNow = Date(timeIntervalSince1970: 1_800_000_000)

/// Scripted transport: every request is recorded and answered by `handler` (which may throw a
/// URLError to simulate the network). `delay` keeps a request in flight (concurrency tests).
final class RoutedHTTPClient: TranslationHTTPClient, @unchecked Sendable {
    struct Reply: Sendable {
        var status: Int
        var body: Data
        var headers: [String: String]
        var delay: TimeInterval

        static func json(_ status: Int, _ body: String, delay: TimeInterval = 0) -> Reply {
            Reply(status: status, body: Data(body.utf8), headers: ["Content-Type": "application/json"], delay: delay)
        }
        static func json(_ body: String, delay: TimeInterval = 0) -> Reply {
            json(200, body, delay: delay)
        }
        static func sse(_ body: String) -> Reply {
            Reply(status: 200, body: Data(body.utf8), headers: ["Content-Type": "text/event-stream"], delay: 0)
        }
        static func empty(_ status: Int = 200) -> Reply {
            Reply(status: status, body: Data(), headers: [:], delay: 0)
        }
    }

    typealias Handler = @Sendable (_ request: URLRequest, _ callToSameURL: Int) throws -> Reply

    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    private let handler: Handler

    init(_ handler: @escaping Handler) { self.handler = handler }

    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return _requests }

    func requests(to url: URL) -> [URLRequest] {
        requests.filter { $0.url?.absoluteString == url.absoluteString }
    }

    private func record(_ request: URLRequest) -> Int {
        lock.lock(); defer { lock.unlock() }
        _requests.append(request)
        return _requests.filter { $0.url?.absoluteString == request.url?.absoluteString }.count
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let call = record(request)
        let reply = try handler(request, call)
        if reply.delay > 0 { try await Task.sleep(nanoseconds: UInt64(reply.delay * 1_000_000_000)) }
        let response = HTTPURLResponse(url: request.url ?? ChatGPTPlan.responsesURL, statusCode: reply.status,
                                       httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        return (reply.body, response)
    }
}

/// In-memory stand-in for the app's Keychain store.
final class MemoryCredentialStore: ChatGPTCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var _credential: ChatGPTCredential?
    private var _account: ChatGPTAccount?
    private var _saves = 0
    private var _deletes = 0

    init(credential: ChatGPTCredential? = nil, account: ChatGPTAccount? = nil) {
        _credential = credential
        _account = account ?? credential?.account
    }

    var credential: ChatGPTCredential? { lock.lock(); defer { lock.unlock() }; return _credential }
    var account: ChatGPTAccount? { lock.lock(); defer { lock.unlock() }; return _account }
    var saveCount: Int { lock.lock(); defer { lock.unlock() }; return _saves }
    var deleteCount: Int { lock.lock(); defer { lock.unlock() }; return _deletes }

    func loadCredential() -> ChatGPTCredential? { credential }
    func saveCredential(_ credential: ChatGPTCredential) throws {
        lock.lock(); _credential = credential; _saves += 1; lock.unlock()
    }
    func deleteCredential() {
        lock.lock(); _credential = nil; _deletes += 1; lock.unlock()
    }
    func loadAccount() -> ChatGPTAccount? { account }
    func saveAccount(_ account: ChatGPTAccount) throws {
        lock.lock(); _account = account; lock.unlock()
    }
}

/// Unsigned JWT with the given claims (signature checks are not part of this flow).
func makeJWT(_ claims: [String: Any]) -> String {
    let header = ChatGPTPKCE.base64URL(Data(#"{"alg":"RS256","typ":"JWT","kid":"test"}"#.utf8))
    let payload = ChatGPTPKCE.base64URL((try? JSONSerialization.data(withJSONObject: claims)) ?? Data())
    return header + "." + payload + ".c2lnbmF0dXJl"
}

func idTokenClaims(aud: Any = "oaiapp_123", sub: String = "user-1", nonce: String? = nil,
                   iss: String = "https://auth.openai.com", exp: Date = chatGPTNow.addingTimeInterval(3600),
                   email: String? = "mara@example.com") -> [String: Any] {
    var claims: [String: Any] = ["iss": iss, "sub": sub, "aud": aud, "exp": Int(exp.timeIntervalSince1970),
                                 "iat": Int(chatGPTNow.timeIntervalSince1970)]
    if let nonce { claims["nonce"] = nonce }
    if let email { claims["email"] = email }
    return claims
}

func tokenResponseJSON(access: String, refresh: String?, idToken: String?, expiresIn: Int = 3600,
                       scope: String? = ChatGPTPlan.scope, earliestRefreshAt: JSONValue? = nil) -> String {
    var fields: [(String, JSONValue)] = [("access_token", .string(access)), ("token_type", .string("Bearer")),
                                         ("expires_in", .int(expiresIn))]
    if let refresh { fields.append(("refresh_token", .string(refresh))) }
    if let idToken { fields.append(("id_token", .string(idToken))) }
    if let scope { fields.append(("scope", .string(scope))) }
    if let earliestRefreshAt { fields.append(("earliest_refresh_at", earliestRefreshAt)) }
    return JSONValue.object(fields).serialized()
}

func makeChatGPTCredential(access: String = "at-1", refresh: String = "rt-1",
                           expiresAt: Date = chatGPTNow.addingTimeInterval(3600), earliestRefreshAt: Date? = nil,
                           clientID: String = "oaiapp_123") -> ChatGPTCredential {
    ChatGPTCredential(account: ChatGPTAccount(clientID: clientID, email: "mara@example.com", subject: "user-1"),
                      issuer: "https://auth.openai.com", hostID: "urn:uuid:11111111-2222-4333-8444-555555555555",
                      idToken: makeJWT(idTokenClaims()), accessToken: access, refreshToken: refresh, tokenType: "Bearer",
                      scopes: ChatGPTPlan.scope.split(separator: " ").map(String.init), accessTokenExpiresAt: expiresAt,
                      earliestRefreshAt: earliestRefreshAt, savedAt: chatGPTNow.addingTimeInterval(-60))
}

/// Decodes an application/x-www-form-urlencoded body.
func formFields(_ data: Data?) -> [String: String] {
    guard let data, let text = String(data: data, encoding: .utf8) else { return [:] }
    var fields: [String: String] = [:]
    for pair in text.split(separator: "&") {
        let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let key = parts[0].removingPercentEncoding ?? parts[0]
        let value = parts.count > 1 ? (parts[1].replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? parts[1]) : ""
        fields[key] = value
    }
    return fields
}

func queryFields(_ url: URL) -> [String: String] {
    var fields: [String: String] = [:]
    for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] { fields[item.name] = item.value ?? "" }
    return fields
}

// MARK: Server-sent events

/// "event: <type>\ndata: <json>\n\n" for each event (`json` must carry the same "type").
func sseStream(_ events: [String], lineEnding: String = "\n") -> String {
    events.map { json -> String in
        let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
        let type = object?["type"] as? String ?? "message"
        return "event: \(type)\(lineEnding)data: \(json)\(lineEnding)\(lineEnding)"
    }.joined()
}

func deltaEvent(_ delta: String) -> String {
    JSONValue.object([("type", .string("response.output_text.delta")), ("item_id", .string("msg_1")),
                      ("output_index", .int(0)), ("content_index", .int(0)), ("delta", .string(delta))]).serialized()
}

func completedEvent(outputText: String? = nil, model: String = "gpt-5.5", inputTokens: Int = 1500,
                    outputTokens: Int = 400, refusal: String? = nil) -> String {
    var content: [JSONValue] = []
    if let outputText { content.append(.object([("type", .string("output_text")), ("text", .string(outputText)), ("annotations", .array([]))])) }
    if let refusal { content.append(.object([("type", .string("refusal")), ("refusal", .string(refusal))])) }
    let output: [JSONValue] = content.isEmpty ? [] : [.object([("type", .string("message")), ("id", .string("msg_1")),
                                                               ("role", .string("assistant")), ("content", .array(content))])]
    return JSONValue.object([
        ("type", .string("response.completed")),
        ("response", .object([
            ("id", .string("resp_1")), ("object", .string("response")), ("status", .string("completed")),
            ("model", .string(model)), ("output", .array(output)),
            ("usage", .object([("input_tokens", .int(inputTokens)), ("output_tokens", .int(outputTokens)),
                               ("total_tokens", .int(inputTokens + outputTokens))])),
        ])),
    ]).serialized()
}

func failedEvent(code: String, message: String = "failed") -> String {
    JSONValue.object([
        ("type", .string("response.failed")),
        ("response", .object([("id", .string("resp_1")), ("status", .string("failed")),
                              ("error", .object([("code", .string(code)), ("message", .string(message))]))])),
    ]).serialized()
}

/// A complete successful stream whose text arrives in `pieces`-sized deltas.
func successStream(_ text: String, pieceLength: Int = 7, model: String = "gpt-5.5") -> String {
    var deltas: [String] = []
    var rest = Substring(text)
    while !rest.isEmpty {
        deltas.append(deltaEvent(String(rest.prefix(pieceLength))))
        rest = rest.dropFirst(pieceLength)
    }
    return sseStream([#"{"type":"response.created","response":{"id":"resp_1","status":"in_progress"}}"#] + deltas + [completedEvent(model: model)])
}
