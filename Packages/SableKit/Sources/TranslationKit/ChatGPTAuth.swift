import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// OWNER: translation agent (ChatGPT core).

// MARK: - ID token

/// Claims Sable relies on from the OpenID Connect ID token.
struct ChatGPTIDTokenClaims: Equatable, Sendable {
    var issuer: String
    var subject: String
    var audiences: [String]
    var expiresAt: Date
    var nonce: String?
    var email: String?
    var authorizedParty: String?
}

/// The ID token comes straight from the token endpoint over TLS, so (OIDC Core 3.1.3.7) the TLS
/// server validation stands in for the signature check: Sable validates the claims only and
/// never hand-rolls RSA.
enum ChatGPTIDToken {
    static let leeway: TimeInterval = 60

    private struct Payload: Decodable {
        var iss: String?
        var sub: String?
        var aud: Audience?
        var exp: Double?
        var nonce: String?
        var email: String?
        var azp: String?
        var profile: Profile?

        struct Profile: Decodable { var email: String? }

        enum CodingKeys: String, CodingKey {
            case iss, sub, aud, exp, nonce, email, azp
            case profile = "https://api.openai.com/profile"
        }
    }

    private enum Audience: Decodable {
        case one(String)
        case many([String])
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) { self = .one(s) } else { self = .many(try c.decode([String].self)) }
        }
        var values: [String] {
            switch self {
            case let .one(s): return [s]
            case let .many(a): return a
            }
        }
    }

    static func claims(of jwt: String) throws -> ChatGPTIDTokenClaims {
        let segments = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3, let data = ChatGPTPKCE.base64URLDecode(String(segments[1])) else {
            throw ChatGPTAuthError.invalidIDToken("The ID token is not a JWT.")
        }
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw ChatGPTAuthError.invalidIDToken("The ID token's claims could not be read.")
        }
        guard let iss = payload.iss, !iss.isEmpty else { throw ChatGPTAuthError.invalidIDToken("The ID token has no issuer.") }
        guard let sub = payload.sub, !sub.isEmpty else { throw ChatGPTAuthError.invalidIDToken("The ID token has no subject.") }
        guard let exp = payload.exp else { throw ChatGPTAuthError.invalidIDToken("The ID token has no expiry.") }
        let email = payload.email ?? payload.profile?.email
        return ChatGPTIDTokenClaims(issuer: iss, subject: sub, audiences: payload.aud?.values ?? [],
                                    expiresAt: Date(timeIntervalSince1970: exp), nonce: payload.nonce,
                                    email: (email?.isEmpty == false) ? email : nil, authorizedParty: payload.azp)
    }

    /// Validates iss, aud (must contain the client id), exp (> now, small leeway) and, on sign-in,
    /// nonce (nil on refresh, where no nonce is present).
    static func validate(_ jwt: String, clientID: String, expectedIssuer: String, expectedNonce: String?,
                         now: Date) throws -> ChatGPTIDTokenClaims {
        let claims = try claims(of: jwt)
        guard normalizedIssuer(claims.issuer) == normalizedIssuer(expectedIssuer) else {
            throw ChatGPTAuthError.invalidIDToken("Unexpected issuer.")
        }
        guard claims.audiences.contains(clientID) else {
            throw ChatGPTAuthError.invalidIDToken("The ID token was issued for another client.")
        }
        if claims.audiences.count > 1, let azp = claims.authorizedParty, azp != clientID {
            throw ChatGPTAuthError.invalidIDToken("The ID token was issued for another client.")
        }
        guard claims.expiresAt.addingTimeInterval(leeway) > now else {
            throw ChatGPTAuthError.invalidIDToken("The ID token has expired.")
        }
        if let expectedNonce {
            guard claims.nonce == expectedNonce else { throw ChatGPTAuthError.invalidIDToken("The sign-in nonce did not match.") }
        }
        return claims
    }

    static func normalizedIssuer(_ issuer: String) -> String {
        var s = issuer.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }
}

// MARK: - Token endpoint response

struct ChatGPTTokenResponse: Decodable {
    var accessToken: String
    var refreshToken: String?
    var idToken: String?
    var tokenType: String?
    var expiresIn: Double?
    var scopes: [String]?
    /// Either absolute (epoch seconds/ms, ISO 8601) or a delay in seconds; resolved by `earliestRefresh(now:)`.
    var earliestRefreshRaw: Double?
    var earliestRefreshDate: Date?

    enum CodingKeys: String, CodingKey {
        case access_token, refresh_token, id_token, token_type, expires_in, scope, earliest_refresh_at
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try c.decode(String.self, forKey: .access_token)
        refreshToken = try? c.decodeIfPresent(String.self, forKey: .refresh_token)
        idToken = try? c.decodeIfPresent(String.self, forKey: .id_token)
        tokenType = try? c.decodeIfPresent(String.self, forKey: .token_type)
        expiresIn = Self.number(c, .expires_in)
        if let s = try? c.decodeIfPresent(String.self, forKey: .scope) {
            scopes = Self.splitScopes(s)
        } else if let a = try? c.decodeIfPresent([String].self, forKey: .scope) {
            scopes = a
        }
        if let n = Self.number(c, .earliest_refresh_at) {
            earliestRefreshRaw = n
        } else if let s = try? c.decodeIfPresent(String.self, forKey: .earliest_refresh_at) {
            earliestRefreshDate = ISO8601DateFormatter().date(from: s)
        }
    }

    private static func number(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Double? {
        if let d = try? c.decodeIfPresent(Double.self, forKey: key) { return d }
        if let s = try? c.decodeIfPresent(String.self, forKey: key) { return Double(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    static func splitScopes(_ s: String) -> [String]? {
        let parts = s.split(whereSeparator: { $0 == " " || $0 == "+" }).map(String.init)
        return parts.isEmpty ? nil : parts
    }

    func earliestRefresh(now: Date) -> Date? {
        if let earliestRefreshDate { return earliestRefreshDate }
        guard let raw = earliestRefreshRaw, raw.isFinite, raw >= 0 else { return nil }
        if raw > 100_000_000_000 { return Date(timeIntervalSince1970: raw / 1000) } // epoch milliseconds
        if raw > 1_000_000_000 { return Date(timeIntervalSince1970: raw) }          // epoch seconds
        return now.addingTimeInterval(raw)                                           // delay in seconds
    }

    func accessTokenExpiry(now: Date) -> Date {
        let seconds = expiresIn.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 3600
        return now.addingTimeInterval(seconds)
    }
}

struct ChatGPTDiscovery: Decodable, Sendable {
    var issuer: String?
    var revocation_endpoint: String?
}

// MARK: - Auth client

/// OAuth calls against auth.openai.com: code exchange (with ID-token claim validation), refresh
/// (rotating), revocation (endpoint from discovery, bounded retry). Holds no tokens itself.
public actor ChatGPTAuthClient {
    public static let requestTimeout: TimeInterval = 30

    private let http: any TranslationHTTPClient
    private let revokeBackoff: [TimeInterval]
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private var discovery: ChatGPTDiscovery?

    public init(httpClient: any TranslationHTTPClient) {
        self.init(httpClient: httpClient, revokeBackoff: [1, 3], sleep: TranslationEngine.taskSleep)
    }

    /// `revokeBackoff`: waits before each revocation retry (its count is the number of retries).
    public init(httpClient: any TranslationHTTPClient, revokeBackoff: [TimeInterval],
                sleep: @escaping @Sendable (TimeInterval) async throws -> Void) {
        self.http = httpClient
        self.revokeBackoff = revokeBackoff
        self.sleep = sleep
    }

    /// Token exchange + ID-token claim validation (iss, aud contains client id, exp, nonce). Uses
    /// callback.issuedClientID ?? request.clientID as the client id; rejects dynamic_agent_client
    /// as a final client id. `invalid_grant` throws `.oauth(code: "invalid_grant", …)`: discard
    /// the code and start a new sign-in.
    public func completeSignIn(_ request: ChatGPTAuthorizationRequest, callback: ChatGPTAuthorizationCallback,
                               now: Date) async throws -> ChatGPTCredential {
        let clientID = callback.issuedClientID ?? request.clientID
        guard !clientID.isEmpty, clientID != ChatGPTPlan.dynamicClientID else {
            throw ChatGPTAuthError.misconfigured("ChatGPT did not issue a client id for Sable.")
        }
        let tokens = try await postToken([
            ("grant_type", "authorization_code"),
            ("client_id", clientID),
            ("code", callback.code),
            ("code_verifier", request.codeVerifier),
            ("redirect_uri", request.redirectURI.absoluteString),
            ("resource", ChatGPTPlan.resource),
        ], isRefresh: false)
        guard let idToken = tokens.idToken, !idToken.isEmpty else {
            throw ChatGPTAuthError.invalidIDToken("The sign-in response had no ID token.")
        }
        let claims = try ChatGPTIDToken.validate(idToken, clientID: clientID,
                                                 expectedIssuer: discovery?.issuer ?? ChatGPTPlan.issuer,
                                                 expectedNonce: request.nonce, now: now)
        guard let refreshToken = tokens.refreshToken, !refreshToken.isEmpty else {
            throw ChatGPTAuthError.misconfigured("ChatGPT did not return a refresh token (offline_access).")
        }
        let scopes = tokens.scopes
            ?? callback.grantedScope.flatMap(ChatGPTTokenResponse.splitScopes)
            ?? ChatGPTTokenResponse.splitScopes(ChatGPTPlan.scope) ?? []
        return ChatGPTCredential(account: ChatGPTAccount(clientID: clientID, email: claims.email, subject: claims.subject),
                                 issuer: claims.issuer, hostID: request.hostID, idToken: idToken,
                                 accessToken: tokens.accessToken, refreshToken: refreshToken,
                                 tokenType: tokens.tokenType ?? "Bearer", scopes: scopes,
                                 accessTokenExpiresAt: tokens.accessTokenExpiry(now: now),
                                 earliestRefreshAt: tokens.earliestRefresh(now: now), savedAt: now)
    }

    /// One refresh. The response's refresh token REPLACES the old one (rotation): persist the
    /// returned credential before using it. Terminal refresh errors throw `.signInRequired`;
    /// `invalid_client` throws `.misconfigured`; network problems `.network`.
    public func refresh(_ credential: ChatGPTCredential, now: Date) async throws -> ChatGPTCredential {
        let tokens = try await postToken([
            ("grant_type", "refresh_token"),
            ("client_id", credential.account.clientID),
            ("refresh_token", credential.refreshToken),
            ("resource", ChatGPTPlan.resource),
        ], isRefresh: true)
        var updated = credential
        updated.accessToken = tokens.accessToken
        if let rotated = tokens.refreshToken, !rotated.isEmpty { updated.refreshToken = rotated }
        if let idToken = tokens.idToken, !idToken.isEmpty {
            let claims = try ChatGPTIDToken.validate(idToken, clientID: credential.account.clientID,
                                                     expectedIssuer: credential.issuer, expectedNonce: nil, now: now)
            guard claims.subject == credential.account.subject else {
                throw ChatGPTAuthError.invalidIDToken("The refreshed identity belongs to a different account.")
            }
            updated.idToken = idToken
            if let email = claims.email { updated.account.email = email }
        }
        if let tokenType = tokens.tokenType, !tokenType.isEmpty { updated.tokenType = tokenType }
        if let scopes = tokens.scopes { updated.scopes = scopes }
        updated.accessTokenExpiresAt = tokens.accessTokenExpiry(now: now)
        updated.earliestRefreshAt = tokens.earliestRefresh(now: now)
        updated.savedAt = now
        return updated
    }

    /// Revokes the refresh token at the discovery document's revocation_endpoint. An empty 200 is
    /// success. Network failures and 5xx answers are retried with bounded backoff.
    public func revoke(_ credential: ChatGPTCredential) async throws {
        var attempt = 0
        while true {
            do {
                try await revokeOnce(credential)
                return
            } catch let error as ChatGPTAuthError {
                guard error.isTransient, attempt < revokeBackoff.count else { throw error }
                try await sleep(revokeBackoff[attempt])
                attempt += 1
            }
        }
    }

    // MARK: Internals

    private func revokeOnce(_ credential: ChatGPTCredential) async throws {
        let endpoint = try await revocationEndpoint()
        var request = URLRequest(url: endpoint, timeoutInterval: Self.requestTimeout)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = ChatGPTForm.body([
            ("token", credential.refreshToken),
            ("token_type_hint", "refresh_token"),
            ("client_id", credential.account.clientID),
        ])
        let (data, response) = try await send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw Self.endpointError(status: response.statusCode, data: data, isRefresh: false)
        }
    }

    private func revocationEndpoint() async throws -> URL {
        let document = try await discoveryDocument()
        guard let raw = document.revocation_endpoint, let url = URL(string: raw), url.scheme?.lowercased() == "https" else {
            throw ChatGPTAuthError.misconfigured("ChatGPT's sign-in configuration lists no revocation endpoint.")
        }
        return url
    }

    /// Fetched lazily and cached for the actor's lifetime.
    func discoveryDocument() async throws -> ChatGPTDiscovery {
        if let discovery { return discovery }
        var request = URLRequest(url: ChatGPTPlan.discoveryURL, timeoutInterval: Self.requestTimeout)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw Self.endpointError(status: response.statusCode, data: data, isRefresh: false)
        }
        guard let document = try? JSONDecoder().decode(ChatGPTDiscovery.self, from: data) else {
            throw ChatGPTAuthError.server(status: response.statusCode, message: "The sign-in configuration could not be read.")
        }
        discovery = document
        return document
    }

    private func postToken(_ form: [(String, String)], isRefresh: Bool) async throws -> ChatGPTTokenResponse {
        var request = URLRequest(url: ChatGPTPlan.tokenURL, timeoutInterval: Self.requestTimeout)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = ChatGPTForm.body(form)
        let (data, response) = try await send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw Self.endpointError(status: response.statusCode, data: data, isRefresh: isRefresh)
        }
        guard let tokens = try? JSONDecoder().decode(ChatGPTTokenResponse.self, from: data), !tokens.accessToken.isEmpty else {
            throw ChatGPTAuthError.server(status: response.statusCode, message: "The token response could not be read.")
        }
        return tokens
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await http.send(request)
        } catch {
            throw ChatGPTTransport.authError(for: error)
        }
    }

    /// Maps an auth endpoint error body. Messages come from the server's error text only (never
    /// from the request), so they cannot contain tokens.
    static func endpointError(status: Int, data: Data, isRefresh: Bool) -> ChatGPTAuthError {
        let body = ChatGPTErrorBody.parse(data)
        let message = body.message ?? HTTPURLResponse.localizedString(forStatusCode: status)
        if let code = body.code?.lowercased() {
            if isRefresh, ChatGPTAuthError.terminalRefreshCodes.contains(code) { return .signInRequired }
            switch code {
            case "invalid_client", "unauthorized_client", "invalid_scope", "invalid_target":
                return .misconfigured("\(code): \(message)")
            default:
                if status >= 500 { return .server(status: status, message: message) }
                return .oauth(code: code, description: body.message)
            }
        }
        return .server(status: status, message: message)
    }
}

// MARK: - Token provider

/// One per app. Lazily loads the stored credential, refreshes near expiry, serializes refreshes
/// (concurrent callers share one in-flight refresh, so a rotated refresh token is never used
/// twice) and persists every rotated credential through the store.
public actor ChatGPTTokenProvider {
    private let store: any ChatGPTCredentialStore
    private let auth: ChatGPTAuthClient
    private let clock: @Sendable () -> Date
    private var credential: ChatGPTCredential?
    private var didLoad = false
    private var refreshTask: Task<ChatGPTCredential, Error>?
    /// Bumped by install/sign-out so a refresh that started earlier never resurrects old tokens.
    private var generation = 0
    /// Why the last sign-out could not revoke the refresh token (local tokens were deleted anyway).
    public private(set) var lastRevocationError: ChatGPTAuthError?

    public init(store: any ChatGPTCredentialStore, auth: ChatGPTAuthClient) {
        self.init(store: store, auth: auth, now: { Date() })
    }

    public init(store: any ChatGPTCredentialStore, auth: ChatGPTAuthClient, now: @escaping @Sendable () -> Date) {
        self.store = store
        self.auth = auth
        self.clock = now
    }

    public func currentCredential() -> ChatGPTCredential? { loadIfNeeded() }

    /// The account/client mapping kept across sign-outs (pass it to `ChatGPTAuthorizationRequest.make`).
    public func savedAccount() -> ChatGPTAccount? { store.loadAccount() }

    /// After sign-in: saves the account mapping and the credential, then uses it.
    public func install(_ credential: ChatGPTCredential) throws {
        try store.saveAccount(credential.account)
        try store.saveCredential(credential)
        generation += 1
        refreshTask = nil
        self.credential = credential
        didLoad = true
    }

    /// A valid access token, refreshing first when it is due (or when `forceRefresh`, e.g. after a
    /// 401). Throws `ChatGPTAuthError.notSignedIn` without a credential, `.signInRequired` after a
    /// terminal refresh error (tokens are deleted, the account mapping is kept), `.network` when
    /// the refresh could not reach the server (tokens are kept).
    public func accessToken(forceRefresh: Bool) async throws -> String {
        if let pending = refreshTask {
            return try await token(from: pending, forced: forceRefresh)
        }
        guard let current = loadIfNeeded() else { throw ChatGPTAuthError.notSignedIn }
        if !forceRefresh && !current.needsRefresh(now: clock()) { return current.accessToken }
        let started = generation
        let task = Task<ChatGPTCredential, Error> { try await self.performRefresh(from: current, generation: started) }
        refreshTask = task
        return try await token(from: task, forced: forceRefresh)
    }

    /// Stops requests, deletes the local tokens (keeping the account/client mapping), then
    /// revokes the refresh token best-effort with bounded retry. Local tokens go first so they
    /// never outlive a sign-out (app killed mid-revoke, or a new sign-in during the revoke).
    public func signOut() async {
        // Let an in-flight rotation finish so the newest refresh token is the one revoked.
        if let pending = refreshTask { _ = try? await pending.value }
        let current = loadIfNeeded()
        generation += 1
        refreshTask = nil
        credential = nil
        didLoad = true
        store.deleteCredential()
        lastRevocationError = nil
        guard let current else { return }
        do {
            try await auth.revoke(current)
        } catch let error as ChatGPTAuthError {
            lastRevocationError = error
        } catch {
            lastRevocationError = .network(error.localizedDescription)
        }
    }

    // MARK: Internals

    private func loadIfNeeded() -> ChatGPTCredential? {
        if !didLoad {
            credential = store.loadCredential()
            didLoad = true
        }
        return credential
    }

    private func token(from task: Task<ChatGPTCredential, Error>, forced: Bool) async throws -> String {
        do {
            return try await task.value.accessToken
        } catch let error as ChatGPTAuthError where error.isTransient && !forced {
            // The refresh fell due early but could not reach the server: an access token that is
            // still valid for a while keeps working until the next attempt.
            if let credential, credential.accessTokenExpiresAt.timeIntervalSince(clock()) > 30 {
                return credential.accessToken
            }
            throw error
        }
    }

    private func performRefresh(from current: ChatGPTCredential, generation started: Int) async throws -> ChatGPTCredential {
        defer { if started == generation { refreshTask = nil } }
        do {
            let refreshed = try await auth.refresh(current, now: clock())
            guard started == generation else { throw ChatGPTAuthError.notSignedIn }
            credential = refreshed
            // The old refresh token is now spent: keep the new pair even if the Keychain write
            // fails (this session keeps working; the next launch would ask to sign in again).
            try? store.saveCredential(refreshed)
            return refreshed
        } catch let error as ChatGPTAuthError {
            switch error {
            case .signInRequired, .invalidIDToken:
                // Terminal (or the rotated tokens could not be trusted): sign in again.
                if started == generation {
                    credential = nil
                    store.deleteCredential()
                }
                throw ChatGPTAuthError.signInRequired
            default:
                throw error
            }
        }
    }
}
