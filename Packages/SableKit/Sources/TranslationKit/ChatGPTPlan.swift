import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// OWNER: translation agent (ChatGPT core).
//
// "Sign in with ChatGPT" plan usage for open-source / locally hosted apps (OpenAI, preview).
// Eligible ChatGPT Plus and Pro users authorize Sable in the system browser (OAuth 2.0
// authorization code + PKCE, loopback redirect on 127.0.0.1); Sable then calls the Responses API
// with the user's access token, and usage counts against the user's ChatGPT plan (shared
// five-hour total for Plus). This is NOT OpenAI API access or API billing. No client secret and no
// partner key exist: the client id is issued on first registration and reused afterwards.

// MARK: - Constants

public enum ChatGPTPlan {
    public static let providerID = "chatgpt-plan"
    /// Fallback issuer; the discovery document's "issuer" is preferred once it has been fetched.
    public static let issuer = "https://auth.openai.com"
    public static let authorizeURL = URL(string: "https://auth.openai.com/api/accounts/authorize")!
    public static let tokenURL = URL(string: "https://auth.openai.com/api/accounts/oauth/token")!
    public static let discoveryURL = URL(string: "https://auth.openai.com/.well-known/openid-configuration")!
    public static let resource = "https://api.openai.com/v1"
    public static let responsesURL = URL(string: "https://api.openai.com/v1/responses")!
    public static let modelsURL = URL(string: "https://api.openai.com/v1/models")!
    /// client_id for the first registration; the callback then carries the issued id ("oaiapp_…").
    public static let dynamicClientID = "dynamic_agent_client"
    public static let scope = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
    public static let callbackPath = "/auth/callback"
    public static let preferredCallbackPort: UInt16 = 1455
    public static let manageUsageURL = URL(string: "https://chatgpt.com/settings/usage")!
    public static let appNameHint = "Sable"
    /// A refresh falls due this long before the access token expires.
    public static let refreshLeeway: TimeInterval = 5 * 60

    /// http://127.0.0.1:<port>/auth/callback. Always the 127.0.0.1 literal (never "localhost");
    /// only the port may vary between sign-ins, and one attempt uses the identical URI throughout.
    public static func redirectURI(port: UInt16) -> URL {
        URL(string: "http://127.0.0.1:\(port)\(callbackPath)")!
    }

    /// Opaque, per-installation ext_agent_host_id ("urn:uuid:<UUIDv4>"). Generate once, persist
    /// before the first sign-in and reuse it. Not a credential and not tied to the user.
    public static func newHostID() -> String {
        "urn:uuid:" + UUID().uuidString.lowercased()
    }
}

// MARK: - Account and credential

/// Kept after sign-out (account/client mapping) so re-auth reuses the issued client id.
public struct ChatGPTAccount: Codable, Sendable, Equatable {
    public var clientID: String
    public var email: String?
    public var subject: String
    public init(clientID: String, email: String?, subject: String) {
        self.clientID = clientID; self.email = email; self.subject = subject
    }
}

/// One protected record per issued client id + identity. Store it only in the Keychain; its
/// `description` is redacted so it never prints tokens into logs.
public struct ChatGPTCredential: Codable, Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public var account: ChatGPTAccount
    public var issuer: String
    public var hostID: String
    public var idToken: String
    public var accessToken: String
    public var refreshToken: String
    public var tokenType: String
    public var scopes: [String]
    public var accessTokenExpiresAt: Date
    public var earliestRefreshAt: Date?
    public var savedAt: Date

    public init(account: ChatGPTAccount, issuer: String, hostID: String, idToken: String, accessToken: String,
                refreshToken: String, tokenType: String, scopes: [String], accessTokenExpiresAt: Date,
                earliestRefreshAt: Date?, savedAt: Date) {
        self.account = account; self.issuer = issuer; self.hostID = hostID; self.idToken = idToken
        self.accessToken = accessToken; self.refreshToken = refreshToken; self.tokenType = tokenType
        self.scopes = scopes; self.accessTokenExpiresAt = accessTokenExpiresAt
        self.earliestRefreshAt = earliestRefreshAt; self.savedAt = savedAt
    }

    /// True when the access token is expired or within `ChatGPTPlan.refreshLeeway` (5 min) of
    /// expiring — unless the server's earliest_refresh_at is still in the future and the token
    /// has not expired yet.
    public func needsRefresh(now: Date) -> Bool {
        if now >= accessTokenExpiresAt { return true }
        if let earliestRefreshAt, earliestRefreshAt > now { return false }
        return accessTokenExpiresAt.timeIntervalSince(now) <= ChatGPTPlan.refreshLeeway
    }

    public var description: String {
        "ChatGPTCredential(subject: \(account.subject), clientID: \(account.clientID), expires: \(accessTokenExpiresAt), tokens: <redacted>)"
    }
    public var debugDescription: String { description }
}

// MARK: - Errors

public enum ChatGPTAuthError: Error, Equatable, Sendable, LocalizedError {
    case accessDenied
    case stateMismatch
    case missingCode
    case oauth(code: String, description: String?)
    case invalidIDToken(String)
    case notSignedIn
    case signInRequired           // terminal refresh error or confirmed revocation
    case network(String)
    case server(status: Int, message: String)
    case misconfigured(String)    // invalid_client, scope/grant config

    public var errorDescription: String? {
        switch self {
        case .accessDenied: return "You didn't allow Sable to use your ChatGPT plan. Nothing was connected."
        case .stateMismatch: return "The sign-in reply didn't match this sign-in attempt. Try Sign in with ChatGPT again."
        case .missingCode: return "The sign-in reply had no authorization code. Try Sign in with ChatGPT again."
        case let .oauth(code, description):
            let detail = description.map { ": \($0)" } ?? "."
            return "ChatGPT sign-in failed (\(code))\(detail)"
        case let .invalidIDToken(m): return "ChatGPT sign-in returned an identity Sable couldn't verify: \(m)"
        case .notSignedIn: return "Sign in with ChatGPT in Settings › Translation first."
        case .signInRequired: return "Your ChatGPT sign-in has expired or was disconnected. Sign in with ChatGPT again in Settings › Translation."
        case let .network(m): return "Network problem: \(m)"
        case let .server(status, m): return "ChatGPT returned \(status): \(m)"
        case let .misconfigured(m): return "ChatGPT sign-in is misconfigured: \(m)"
        }
    }

    /// Network failures and 5xx/429 answers: worth a bounded retry; credentials stay.
    var isTransient: Bool {
        switch self {
        case .network: return true
        case let .server(status, _): return status >= 500 || status == 429 || status == 408
        default: return false
        }
    }

    /// Refresh-token errors after which the stored tokens are useless: clear them and ask the
    /// user to sign in again (keeping the account/client mapping).
    static let terminalRefreshCodes: Set<String> = [
        "invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired",
        "refresh_token_invalidated", "refresh_token_reused",
    ]
}

// MARK: - Storage

/// Implemented by the app with the Keychain. Synchronous; called from the token provider actor.
public protocol ChatGPTCredentialStore: Sendable {
    func loadCredential() -> ChatGPTCredential?
    func saveCredential(_ credential: ChatGPTCredential) throws
    func deleteCredential()
    func loadAccount() -> ChatGPTAccount?
    func saveAccount(_ account: ChatGPTAccount) throws
}

// MARK: - PKCE, random values, encoding

enum ChatGPTPKCE {
    /// Cryptographically secure random bytes (SystemRandomNumberGenerator).
    static func randomBytes(_ count: Int) -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        return (0..<count).map { _ in UInt8.random(in: UInt8.min...UInt8.max, using: &generator) }
    }

    /// 32 random bytes as base64url: 43 characters of the RFC 7636 unreserved set.
    static func randomToken(byteCount: Int = 32) -> String {
        base64URL(randomBytes(byteCount))
    }

    /// code_challenge = base64url(SHA-256(ASCII(verifier))), unpadded (S256).
    static func codeChallenge(for verifier: String) -> String {
        var digest = SHA256Digest()
        digest.update(verifier)
        return base64URL(digest.finalize())
    }

    static func base64URL<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func base64URLDecode(_ string: String) -> Data? {
        var base64 = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder == 1 { return nil }
        if remainder > 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: base64)
    }
}

/// application/x-www-form-urlencoded and query encoding: everything except the RFC 3986
/// unreserved set is percent-encoded (so "+", "&", "=", "/", ":" and spaces are always escaped;
/// URLComponents would leave "+" alone in a query).
enum ChatGPTForm {
    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func percentEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    static func encode(_ pairs: [(String, String)]) -> String {
        pairs.map { percentEncode($0.0) + "=" + percentEncode($0.1) }.joined(separator: "&")
    }

    static func body(_ pairs: [(String, String)]) -> Data { Data(encode(pairs).utf8) }
}

// MARK: - Authorization request

public struct ChatGPTAuthorizationRequest: Codable, Sendable, Equatable {
    public let url: URL              // full authorize URL to open in the browser
    public let state: String
    public let nonce: String
    public let codeVerifier: String
    public let redirectURI: URL
    public let clientID: String      // dynamic_agent_client or the issued id
    public let hostID: String

    /// account == nil => first registration (dynamic client id + agent_name_hint); else reuse
    /// account.clientID, omit agent_name_hint, pass id_token_hint when given and
    /// login_hint = account.email when present. Fresh state, nonce and PKCE verifier every call.
    public static func make(redirectURI: URL, hostID: String, account: ChatGPTAccount?, idTokenHint: String?) -> ChatGPTAuthorizationRequest {
        make(redirectURI: redirectURI, hostID: hostID, account: account, idTokenHint: idTokenHint, forceConsent: false)
    }

    /// Same as `make(redirectURI:hostID:account:idTokenHint:)`; `forceConsent` adds
    /// prompt=consent (asking again after the user declined).
    public static func make(redirectURI: URL, hostID: String, account: ChatGPTAccount?, idTokenHint: String?,
                            forceConsent: Bool) -> ChatGPTAuthorizationRequest {
        make(redirectURI: redirectURI, hostID: hostID, account: account, idTokenHint: idTokenHint, forceConsent: forceConsent,
             state: ChatGPTPKCE.randomToken(), nonce: ChatGPTPKCE.randomToken(), codeVerifier: ChatGPTPKCE.randomToken())
    }

    static func make(redirectURI: URL, hostID: String, account: ChatGPTAccount?, idTokenHint: String?, forceConsent: Bool,
                     state: String, nonce: String, codeVerifier: String) -> ChatGPTAuthorizationRequest {
        // An account without a real issued id is treated as a first registration.
        let registered = account.flatMap { $0.clientID.isEmpty || $0.clientID == ChatGPTPlan.dynamicClientID ? nil : $0 }
        let clientID = registered?.clientID ?? ChatGPTPlan.dynamicClientID
        var items: [(String, String)] = [
            ("response_type", "code"),
            ("client_id", clientID),
        ]
        if registered == nil { items.append(("agent_name_hint", ChatGPTPlan.appNameHint)) }
        items += [
            ("ext_agent_host_id", hostID),
            ("redirect_uri", redirectURI.absoluteString),
            ("scope", ChatGPTPlan.scope),
            ("resource", ChatGPTPlan.resource),
            ("state", state),
            ("nonce", nonce),
            ("code_challenge", ChatGPTPKCE.codeChallenge(for: codeVerifier)),
            ("code_challenge_method", "S256"),
        ]
        if let registered {
            if let hint = idTokenHint, !hint.isEmpty { items.append(("id_token_hint", hint)) }
            if let email = registered.email, !email.isEmpty { items.append(("login_hint", email)) }
        }
        if forceConsent { items.append(("prompt", "consent")) }
        // Every value is fully percent-encoded, so the string always parses as a URL.
        let url = URL(string: ChatGPTPlan.authorizeURL.absoluteString + "?" + ChatGPTForm.encode(items)) ?? ChatGPTPlan.authorizeURL
        return ChatGPTAuthorizationRequest(url: url, state: state, nonce: nonce, codeVerifier: codeVerifier,
                                           redirectURI: redirectURI, clientID: clientID, hostID: hostID)
    }
}

// MARK: - Callback

public struct ChatGPTAuthorizationCallback: Sendable, Equatable {
    public let code: String
    /// Present on a new registration: the issued client id. Save it and reuse it.
    public let issuedClientID: String?
    public let grantedScope: String?

    /// Parses the loopback callback's query items and validates state. Throws ChatGPTAuthError.
    public init(queryItems: [URLQueryItem], expectedState: String) throws {
        func value(_ name: String) -> String? {
            guard let raw = queryItems.first(where: { $0.name == name })?.value else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        let state = value("state")
        if let state, state != expectedState { throw ChatGPTAuthError.stateMismatch }
        if let error = value("error") {
            // A declined consent (or any error) stops the attempt; nothing is exchanged.
            if error == "access_denied" { throw ChatGPTAuthError.accessDenied }
            throw ChatGPTAuthError.oauth(code: error, description: value("error_description"))
        }
        guard state != nil else { throw ChatGPTAuthError.stateMismatch }
        guard let code = value("code") else { throw ChatGPTAuthError.missingCode }
        self.code = code
        self.issuedClientID = value("client_id")
        self.grantedScope = value("scope")?.replacingOccurrences(of: "+", with: " ")
    }

    /// Convenience for a full callback URL (http://127.0.0.1:<port>/auth/callback?…).
    public init(callbackURL: URL, expectedState: String) throws {
        let items = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        try self.init(queryItems: items, expectedState: expectedState)
    }
}

// MARK: - Shared response helpers

/// Error bodies seen from auth.openai.com and api.openai.com: RFC 6749 {"error","error_description"},
/// OpenAI {"error":{"code","message","param","type"}}, {"detail":"…"}, or a streamed error event.
struct ChatGPTErrorBody: Equatable, Sendable {
    var code: String?
    var message: String?
    var param: String?

    static func parse(_ data: Data) -> ChatGPTErrorBody {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return ChatGPTErrorBody() }
        return parse(object: object)
    }

    static func parse(object: [String: Any]) -> ChatGPTErrorBody {
        var body = ChatGPTErrorBody()
        if let code = object["error"] as? String {
            body.code = code
            body.message = object["error_description"] as? String
        } else if let error = object["error"] as? [String: Any] {
            body.code = nonEmpty(error["code"] as? String) ?? nonEmpty(error["type"] as? String)
            body.message = error["message"] as? String
            body.param = error["param"] as? String
        }
        if body.code == nil { body.code = nonEmpty(object["code"] as? String) }
        if body.message == nil {
            body.message = (object["detail"] as? String) ?? (object["message"] as? String) ?? (object["error_description"] as? String)
        }
        if body.param == nil { body.param = object["param"] as? String }
        body.message = nonEmpty(body.message?.trimmingCharacters(in: .whitespacesAndNewlines))
        return body
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }
}

enum ChatGPTJSON {
    static func int(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let d = value as? Double, d.isFinite { return Int(d) }
        if let s = value as? String { return Int(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    static func double(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let s = value as? String { return Double(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }
}

enum ChatGPTTransport {
    /// Maps URLSession failures to ChatGPTAuthError.network; cancellation stays cancellation.
    static func authError(for error: Error) -> Error {
        if error is CancellationError { return error }
        if let authError = error as? ChatGPTAuthError { return authError }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled: return CancellationError()
            case .timedOut: return ChatGPTAuthError.network("The request timed out.")
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                return ChatGPTAuthError.network("You appear to be offline.")
            default: return ChatGPTAuthError.network(urlError.localizedDescription)
            }
        }
        return ChatGPTAuthError.network(error.localizedDescription)
    }
}
