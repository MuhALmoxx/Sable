import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import TranslationKit

final class ChatGPTAuthTests: XCTestCase {
    private let redirect = ChatGPTPlan.redirectURI(port: 1455)
    private let hostID = "urn:uuid:11111111-2222-4333-8444-555555555555"

    // MARK: PKCE, encoding, constants

    func testPKCEMatchesRFC7636AppendixB() {
        XCTAssertEqual(ChatGPTPKCE.codeChallenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
                       "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testBase64URLIsUnpaddedAndURLSafe() {
        XCTAssertEqual(ChatGPTPKCE.base64URL([0xfb, 0xff]), "-_8")
        XCTAssertEqual(ChatGPTPKCE.base64URLDecode("-_8"), Data([0xfb, 0xff]))
        XCTAssertEqual(ChatGPTPKCE.base64URL(Array("hello".utf8)), "aGVsbG8")
        XCTAssertNil(ChatGPTPKCE.base64URLDecode("a"))
    }

    func testRandomValuesAreFreshAndVerifierUsesTheUnreservedSet() {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let a = ChatGPTAuthorizationRequest.make(redirectURI: redirect, hostID: hostID, account: nil, idTokenHint: nil)
        let b = ChatGPTAuthorizationRequest.make(redirectURI: redirect, hostID: hostID, account: nil, idTokenHint: nil)
        XCTAssertNotEqual(a.state, b.state)
        XCTAssertNotEqual(a.nonce, b.nonce)
        XCTAssertNotEqual(a.codeVerifier, b.codeVerifier)
        XCTAssertNotEqual(a.state, a.nonce)
        for verifier in [a.codeVerifier, b.codeVerifier] {
            XCTAssertTrue((43...128).contains(verifier.count), "verifier length \(verifier.count)")
            XCTAssertTrue(verifier.allSatisfy { allowed.contains($0) })
        }
        XCTAssertGreaterThanOrEqual(a.state.count, 43)
    }

    func testFormEncodingEscapesReservedCharacters() {
        XCTAssertEqual(ChatGPTForm.encode([("a b", "x+y&z=1/2:3"), ("e", "ü~._-")]), "a%20b=x%2By%26z%3D1%2F2%3A3&e=%C3%BC~._-")
        XCTAssertEqual(formFields(ChatGPTForm.body([("scope", "a b+c")])), ["scope": "a b+c"])
    }

    func testConstantsAndRedirectURI() {
        XCTAssertEqual(ChatGPTPlan.providerID, "chatgpt-plan")
        XCTAssertEqual(ChatGPTPlan.authorizeURL.absoluteString, "https://auth.openai.com/api/accounts/authorize")
        XCTAssertEqual(ChatGPTPlan.tokenURL.absoluteString, "https://auth.openai.com/api/accounts/oauth/token")
        XCTAssertEqual(ChatGPTPlan.discoveryURL.absoluteString, "https://auth.openai.com/.well-known/openid-configuration")
        XCTAssertEqual(ChatGPTPlan.responsesURL.absoluteString, "https://api.openai.com/v1/responses")
        XCTAssertEqual(ChatGPTPlan.modelsURL.absoluteString, "https://api.openai.com/v1/models")
        XCTAssertEqual(ChatGPTPlan.manageUsageURL.absoluteString, "https://chatgpt.com/settings/usage")
        XCTAssertEqual(ChatGPTPlan.scope, "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct")
        XCTAssertEqual(ChatGPTPlan.redirectURI(port: 1455).absoluteString, "http://127.0.0.1:1455/auth/callback")
        XCTAssertEqual(ChatGPTPlan.redirectURI(port: 50123).absoluteString, "http://127.0.0.1:50123/auth/callback")

        let id = ChatGPTPlan.newHostID()
        XCTAssertTrue(id.hasPrefix("urn:uuid:"))
        XCTAssertEqual(id, id.lowercased())
        XCTAssertNotNil(UUID(uuidString: String(id.dropFirst("urn:uuid:".count))))
        XCTAssertNotEqual(id, ChatGPTPlan.newHostID())
    }

    // MARK: Authorize URL

    func testFirstRegistrationAuthorizeURL() throws {
        let request = ChatGPTAuthorizationRequest.make(redirectURI: redirect, hostID: hostID, account: nil, idTokenHint: "ignored")
        XCTAssertEqual(request.clientID, ChatGPTPlan.dynamicClientID)
        XCTAssertEqual(request.redirectURI, redirect)
        XCTAssertEqual(request.hostID, hostID)
        let components = try XCTUnwrap(URLComponents(url: request.url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "auth.openai.com")
        XCTAssertEqual(components.path, "/api/accounts/authorize")

        let q = queryFields(request.url)
        XCTAssertEqual(q, [
            "response_type": "code",
            "client_id": "dynamic_agent_client",
            "agent_name_hint": "Sable",
            "ext_agent_host_id": hostID,
            "redirect_uri": "http://127.0.0.1:1455/auth/callback",
            "scope": ChatGPTPlan.scope,
            "resource": "https://api.openai.com/v1",
            "state": request.state,
            "nonce": request.nonce,
            "code_challenge": ChatGPTPKCE.codeChallenge(for: request.codeVerifier),
            "code_challenge_method": "S256",
        ])
        let raw = try XCTUnwrap(components.percentEncodedQuery)
        XCTAssertTrue(raw.contains("scope=openid%20profile%20email%20offline_access%20resource.invoke%20chatgpt.tokens.use.direct"))
        XCTAssertTrue(raw.contains("redirect_uri=http%3A%2F%2F127.0.0.1%3A1455%2Fauth%2Fcallback"))
        XCTAssertTrue(raw.contains("ext_agent_host_id=urn%3Auuid%3A"))
        XCTAssertFalse(raw.contains("+"))
        XCTAssertFalse(raw.contains("localhost"))
    }

    func testReauthorizationReusesIssuedClientIDAndHints() {
        let account = ChatGPTAccount(clientID: "oaiapp_123", email: "mara+tv@example.com", subject: "user-1")
        let request = ChatGPTAuthorizationRequest.make(redirectURI: ChatGPTPlan.redirectURI(port: 50123), hostID: hostID,
                                                       account: account, idTokenHint: "eyJ.id.token")
        XCTAssertEqual(request.clientID, "oaiapp_123")
        let q = queryFields(request.url)
        XCTAssertEqual(q["client_id"], "oaiapp_123")
        XCTAssertNil(q["agent_name_hint"], "agent_name_hint only on the first registration")
        XCTAssertEqual(q["id_token_hint"], "eyJ.id.token")
        XCTAssertEqual(q["login_hint"], "mara+tv@example.com", "'+' must survive query encoding")
        XCTAssertEqual(q["ext_agent_host_id"], hostID)
        XCTAssertEqual(q["redirect_uri"], "http://127.0.0.1:50123/auth/callback")
        XCTAssertNil(q["prompt"])

        let bare = ChatGPTAuthorizationRequest.make(redirectURI: redirect, hostID: hostID,
                                                    account: ChatGPTAccount(clientID: "oaiapp_123", email: nil, subject: "user-1"),
                                                    idTokenHint: nil)
        XCTAssertNil(queryFields(bare.url)["login_hint"])
        XCTAssertNil(queryFields(bare.url)["id_token_hint"])

        let consent = ChatGPTAuthorizationRequest.make(redirectURI: redirect, hostID: hostID, account: account,
                                                       idTokenHint: nil, forceConsent: true)
        XCTAssertEqual(queryFields(consent.url)["prompt"], "consent")
    }

    func testAccountWithoutIssuedIDIsAFirstRegistration() {
        let request = ChatGPTAuthorizationRequest.make(redirectURI: redirect, hostID: hostID,
                                                       account: ChatGPTAccount(clientID: "dynamic_agent_client", email: "a@b.c", subject: "s"),
                                                       idTokenHint: "hint")
        let q = queryFields(request.url)
        XCTAssertEqual(q["client_id"], "dynamic_agent_client")
        XCTAssertEqual(q["agent_name_hint"], "Sable")
        XCTAssertNil(q["id_token_hint"])
        XCTAssertNil(q["login_hint"])
    }

    // MARK: Callback

    func testCallbackParsing() throws {
        let ok = try ChatGPTAuthorizationCallback(queryItems: [
            URLQueryItem(name: "code", value: "auth-code"), URLQueryItem(name: "state", value: "s1"),
            URLQueryItem(name: "scope", value: "openid+profile"), URLQueryItem(name: "client_id", value: "oaiapp_new"),
        ], expectedState: "s1")
        XCTAssertEqual(ok.code, "auth-code")
        XCTAssertEqual(ok.issuedClientID, "oaiapp_new")
        XCTAssertEqual(ok.grantedScope, "openid profile")

        let reauth = try ChatGPTAuthorizationCallback(callbackURL: URL(string: "http://127.0.0.1:1455/auth/callback?code=c2&state=s2")!,
                                                      expectedState: "s2")
        XCTAssertEqual(reauth.code, "c2")
        XCTAssertNil(reauth.issuedClientID)

        let cases: [([URLQueryItem], ChatGPTAuthError)] = [
            ([URLQueryItem(name: "error", value: "access_denied"), URLQueryItem(name: "state", value: "s1")], .accessDenied),
            ([URLQueryItem(name: "code", value: "c"), URLQueryItem(name: "state", value: "forged")], .stateMismatch),
            ([URLQueryItem(name: "code", value: "c")], .stateMismatch),
            ([URLQueryItem(name: "state", value: "s1")], .missingCode),
            ([URLQueryItem(name: "code", value: ""), URLQueryItem(name: "state", value: "s1")], .missingCode),
            ([URLQueryItem(name: "error", value: "server_error"), URLQueryItem(name: "error_description", value: "Try later"),
              URLQueryItem(name: "state", value: "s1")], .oauth(code: "server_error", description: "Try later")),
            ([URLQueryItem(name: "error", value: "access_denied"), URLQueryItem(name: "state", value: "forged")], .stateMismatch),
        ]
        for (items, expected) in cases {
            XCTAssertThrowsError(try ChatGPTAuthorizationCallback(queryItems: items, expectedState: "s1")) { error in
                XCTAssertEqual(error as? ChatGPTAuthError, expected, "\(items)")
            }
        }
    }

    // MARK: Token exchange

    private func signInRequest() -> ChatGPTAuthorizationRequest {
        ChatGPTAuthorizationRequest.make(redirectURI: redirect, hostID: hostID, account: nil, idTokenHint: nil, forceConsent: false,
                                         state: "state-1", nonce: "nonce-1", codeVerifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
    }

    private func callback(clientID: String? = "oaiapp_new") throws -> ChatGPTAuthorizationCallback {
        var items = [URLQueryItem(name: "code", value: "auth/code+1"), URLQueryItem(name: "state", value: "state-1"),
                     URLQueryItem(name: "scope", value: ChatGPTPlan.scope)]
        if let clientID { items.append(URLQueryItem(name: "client_id", value: clientID)) }
        return try ChatGPTAuthorizationCallback(queryItems: items, expectedState: "state-1")
    }

    func testCompleteSignInExchangesCodeAndBuildsCredential() async throws {
        let idToken = makeJWT(idTokenClaims(aud: ["oaiapp_new"], nonce: "nonce-1"))
        let earliest = Int(chatGPTNow.timeIntervalSince1970) + 1800
        let http = RoutedHTTPClient { _, _ in
            .json(tokenResponseJSON(access: "at-1", refresh: "rt-1", idToken: idToken, earliestRefreshAt: .int(earliest)))
        }
        let auth = ChatGPTAuthClient(httpClient: http)
        let credential = try await auth.completeSignIn(signInRequest(), callback: try callback(), now: chatGPTNow)

        let sent = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(http.requests.count, 1)
        XCTAssertEqual(sent.url, ChatGPTPlan.tokenURL)
        XCTAssertEqual(sent.httpMethod, "POST")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        XCTAssertNil(sent.value(forHTTPHeaderField: "Authorization"), "no client secret / basic auth")
        XCTAssertEqual(formFields(sent.httpBody), [
            "grant_type": "authorization_code",
            "client_id": "oaiapp_new",
            "code": "auth/code+1",
            "code_verifier": "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk",
            "redirect_uri": "http://127.0.0.1:1455/auth/callback",
            "resource": "https://api.openai.com/v1",
        ])
        let rawBody = String(decoding: try XCTUnwrap(sent.httpBody), as: UTF8.self)
        XCTAssertTrue(rawBody.contains("code=auth%2Fcode%2B1"))

        XCTAssertEqual(credential.account, ChatGPTAccount(clientID: "oaiapp_new", email: "mara@example.com", subject: "user-1"))
        XCTAssertEqual(credential.issuer, "https://auth.openai.com")
        XCTAssertEqual(credential.hostID, hostID)
        XCTAssertEqual(credential.idToken, idToken)
        XCTAssertEqual(credential.accessToken, "at-1")
        XCTAssertEqual(credential.refreshToken, "rt-1")
        XCTAssertEqual(credential.tokenType, "Bearer")
        XCTAssertEqual(credential.scopes, ["openid", "profile", "email", "offline_access", "resource.invoke", "chatgpt.tokens.use.direct"])
        XCTAssertEqual(credential.accessTokenExpiresAt, chatGPTNow.addingTimeInterval(3600))
        XCTAssertEqual(credential.earliestRefreshAt, Date(timeIntervalSince1970: TimeInterval(earliest)))
        XCTAssertEqual(credential.savedAt, chatGPTNow)
    }

    func testReauthorizationKeepsTheIssuedClientID() async throws {
        let account = ChatGPTAccount(clientID: "oaiapp_123", email: "mara@example.com", subject: "user-1")
        let request = ChatGPTAuthorizationRequest.make(redirectURI: redirect, hostID: hostID, account: account, idTokenHint: nil,
                                                       forceConsent: false, state: "state-1", nonce: "nonce-1", codeVerifier: "v" + String(repeating: "x", count: 50))
        let http = RoutedHTTPClient { _, _ in
            .json(tokenResponseJSON(access: "at", refresh: "rt", idToken: makeJWT(idTokenClaims(nonce: "nonce-1"))))
        }
        let credential = try await ChatGPTAuthClient(httpClient: http).completeSignIn(request, callback: try callback(clientID: nil), now: chatGPTNow)
        XCTAssertEqual(credential.account.clientID, "oaiapp_123")
        XCTAssertEqual(formFields(http.requests.first?.httpBody)["client_id"], "oaiapp_123")
    }

    func testCompleteSignInRejectsTheDynamicClientIDWithoutARequest() async throws {
        let http = RoutedHTTPClient { _, _ in .json("{}") }
        do {
            _ = try await ChatGPTAuthClient(httpClient: http).completeSignIn(signInRequest(), callback: try callback(clientID: nil), now: chatGPTNow)
            XCTFail("expected misconfigured")
        } catch {
            guard case .misconfigured? = error as? ChatGPTAuthError else { return XCTFail("got \(error)") }
        }
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testSignInValidatesTheIDToken() async throws {
        let cases: [(String, [String: Any])] = [
            ("wrong audience", idTokenClaims(aud: "oaiapp_other", nonce: "nonce-1")),
            ("wrong nonce", idTokenClaims(aud: "oaiapp_new", nonce: "replayed")),
            ("missing nonce", idTokenClaims(aud: "oaiapp_new", nonce: nil)),
            ("expired", idTokenClaims(aud: "oaiapp_new", nonce: "nonce-1", exp: chatGPTNow.addingTimeInterval(-120))),
            ("wrong issuer", idTokenClaims(aud: "oaiapp_new", nonce: "nonce-1", iss: "https://evil.example.com")),
        ]
        for (name, claims) in cases {
            let http = RoutedHTTPClient { _, _ in .json(tokenResponseJSON(access: "at", refresh: "rt", idToken: makeJWT(claims))) }
            do {
                _ = try await ChatGPTAuthClient(httpClient: http).completeSignIn(signInRequest(), callback: try callback(), now: chatGPTNow)
                XCTFail("\(name): expected invalidIDToken")
            } catch {
                guard case .invalidIDToken? = error as? ChatGPTAuthError else { return XCTFail("\(name): got \(error)") }
            }
        }
        let missing = RoutedHTTPClient { _, _ in .json(tokenResponseJSON(access: "at", refresh: "rt", idToken: nil)) }
        do {
            _ = try await ChatGPTAuthClient(httpClient: missing).completeSignIn(signInRequest(), callback: try callback(), now: chatGPTNow)
            XCTFail("expected invalidIDToken")
        } catch {
            guard case .invalidIDToken? = error as? ChatGPTAuthError else { return XCTFail("got \(error)") }
        }
    }

    func testIDTokenClaimValidation() throws {
        func validate(_ claims: [String: Any], nonce: String? = "n") throws -> ChatGPTIDTokenClaims {
            try ChatGPTIDToken.validate(makeJWT(claims), clientID: "oaiapp_123", expectedIssuer: "https://auth.openai.com/",
                                        expectedNonce: nonce, now: chatGPTNow)
        }
        let good = try validate(idTokenClaims(nonce: "n"))
        XCTAssertEqual(good.subject, "user-1")
        XCTAssertEqual(good.email, "mara@example.com")
        XCTAssertEqual(try validate(idTokenClaims(aud: ["other", "oaiapp_123"], nonce: "n")).audiences, ["other", "oaiapp_123"])
        XCTAssertNoThrow(try validate(idTokenClaims(nonce: nil), nonce: nil), "refresh: no nonce required")
        XCTAssertNoThrow(try validate(idTokenClaims(nonce: "n", exp: chatGPTNow.addingTimeInterval(-30))), "small leeway")
        XCTAssertNil(try validate(idTokenClaims(nonce: "n", email: nil)).email)

        var noSubject = idTokenClaims(nonce: "n"); noSubject["sub"] = nil
        var multiAudForeignAzp = idTokenClaims(aud: ["oaiapp_123", "x"], nonce: "n"); multiAudForeignAzp["azp"] = "x"
        for bad in [idTokenClaims(aud: "nope", nonce: "n"), idTokenClaims(nonce: "other"), noSubject, multiAudForeignAzp,
                    idTokenClaims(nonce: "n", exp: chatGPTNow.addingTimeInterval(-3600))] {
            XCTAssertThrowsError(try validate(bad)) { error in
                guard case .invalidIDToken? = error as? ChatGPTAuthError else { return XCTFail("got \(error)") }
            }
        }
        XCTAssertThrowsError(try ChatGPTIDToken.claims(of: "not-a-jwt"))
        XCTAssertThrowsError(try ChatGPTIDToken.claims(of: "a.%%%.c"))
    }

    func testTokenEndpointErrors() async throws {
        let cases: [(Int, String, ChatGPTAuthError)] = [
            (400, #"{"error":"invalid_grant","error_description":"Code expired"}"#, .oauth(code: "invalid_grant", description: "Code expired")),
            (401, #"{"error":"invalid_client","error_description":"Unknown client"}"#, .misconfigured("invalid_client: Unknown client")),
            (503, #"{"detail":"Unavailable"}"#, .server(status: 503, message: "Unavailable")),
        ]
        for (status, body, expected) in cases {
            let http = RoutedHTTPClient { _, _ in .json(status, body) }
            do {
                _ = try await ChatGPTAuthClient(httpClient: http).completeSignIn(signInRequest(), callback: try callback(), now: chatGPTNow)
                XCTFail("expected \(expected)")
            } catch {
                XCTAssertEqual(error as? ChatGPTAuthError, expected)
            }
        }
        let offline = RoutedHTTPClient { _, _ in throw URLError(.notConnectedToInternet) }
        do {
            _ = try await ChatGPTAuthClient(httpClient: offline).completeSignIn(signInRequest(), callback: try callback(), now: chatGPTNow)
            XCTFail("expected network")
        } catch {
            XCTAssertEqual(error as? ChatGPTAuthError, .network("You appear to be offline."))
        }
    }

    // MARK: Refresh

    func testNeedsRefresh() {
        let now = chatGPTNow
        XCTAssertFalse(makeChatGPTCredential(expiresAt: now.addingTimeInterval(3600)).needsRefresh(now: now))
        XCTAssertFalse(makeChatGPTCredential(expiresAt: now.addingTimeInterval(301)).needsRefresh(now: now))
        XCTAssertTrue(makeChatGPTCredential(expiresAt: now.addingTimeInterval(299)).needsRefresh(now: now))
        XCTAssertTrue(makeChatGPTCredential(expiresAt: now.addingTimeInterval(-1)).needsRefresh(now: now))
        XCTAssertFalse(makeChatGPTCredential(expiresAt: now.addingTimeInterval(120), earliestRefreshAt: now.addingTimeInterval(60)).needsRefresh(now: now),
                       "earliest_refresh_at in the future and still valid")
        XCTAssertTrue(makeChatGPTCredential(expiresAt: now.addingTimeInterval(120), earliestRefreshAt: now.addingTimeInterval(-1)).needsRefresh(now: now))
        XCTAssertTrue(makeChatGPTCredential(expiresAt: now.addingTimeInterval(-5), earliestRefreshAt: now.addingTimeInterval(600)).needsRefresh(now: now),
                      "expired always refreshes")
    }

    private func tokenProvider(_ store: MemoryCredentialStore, _ http: RoutedHTTPClient,
                               sleeps: Recorder<TimeInterval>? = nil) -> ChatGPTTokenProvider {
        let recorder = sleeps
        let auth = ChatGPTAuthClient(httpClient: http, revokeBackoff: [1, 3], sleep: { recorder?.add($0) })
        return ChatGPTTokenProvider(store: store, auth: auth, now: { chatGPTNow })
    }

    func testRefreshRotatesTokensAndPersistsThem() async throws {
        let store = MemoryCredentialStore(credential: makeChatGPTCredential(expiresAt: chatGPTNow.addingTimeInterval(-10)))
        let newID = makeJWT(idTokenClaims(email: "mara.new@example.com"))
        let http = RoutedHTTPClient { _, _ in
            .json(tokenResponseJSON(access: "at-2", refresh: "rt-2", idToken: newID, scope: nil, earliestRefreshAt: .int(600)))
        }
        let tokens = tokenProvider(store, http)
        let token = try await tokens.accessToken(forceRefresh: false)
        XCTAssertEqual(token, "at-2")

        let sent = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(sent.url, ChatGPTPlan.tokenURL)
        XCTAssertEqual(formFields(sent.httpBody), [
            "grant_type": "refresh_token",
            "client_id": "oaiapp_123",
            "refresh_token": "rt-1",
            "resource": "https://api.openai.com/v1",
        ], "no scope on refresh")

        let saved = try XCTUnwrap(store.credential)
        XCTAssertEqual(saved.accessToken, "at-2")
        XCTAssertEqual(saved.refreshToken, "rt-2", "rotated refresh token stored")
        XCTAssertEqual(saved.idToken, newID)
        XCTAssertEqual(saved.account.email, "mara.new@example.com")
        XCTAssertEqual(saved.accessTokenExpiresAt, chatGPTNow.addingTimeInterval(3600))
        XCTAssertEqual(saved.earliestRefreshAt, chatGPTNow.addingTimeInterval(600))
        XCTAssertEqual(saved.savedAt, chatGPTNow)
        XCTAssertEqual(saved.scopes, makeChatGPTCredential().scopes, "scopes kept when not returned")

        let again = try await tokens.accessToken(forceRefresh: false)
        XCTAssertEqual(again, "at-2")
        XCTAssertEqual(http.requests.count, 1, "fresh token is reused")
        let current = await tokens.currentCredential()
        XCTAssertEqual(current?.refreshToken, "rt-2")
    }

    func testValidTokenIsReturnedWithoutRefreshUnlessForced() async throws {
        let store = MemoryCredentialStore(credential: makeChatGPTCredential())
        let http = RoutedHTTPClient { _, _ in .json(tokenResponseJSON(access: "at-2", refresh: "rt-2", idToken: nil)) }
        let tokens = tokenProvider(store, http)
        let first = try await tokens.accessToken(forceRefresh: false)
        XCTAssertEqual(first, "at-1")
        XCTAssertTrue(http.requests.isEmpty)
        let forced = try await tokens.accessToken(forceRefresh: true)
        XCTAssertEqual(forced, "at-2")
        XCTAssertEqual(http.requests.count, 1)
    }

    func testConcurrentCallersShareOneRefresh() async throws {
        let store = MemoryCredentialStore(credential: makeChatGPTCredential(expiresAt: chatGPTNow.addingTimeInterval(-10)))
        let http = RoutedHTTPClient { _, call in
            .json(tokenResponseJSON(access: "at-\(call + 1)", refresh: "rt-\(call + 1)", idToken: nil), delay: 0.3)
        }
        let tokens = tokenProvider(store, http)
        let results = try await withThrowingTaskGroup(of: String.self) { group -> [String] in
            // Non-forced callers only: one that arrives after the refresh finished sees a fresh
            // token, so any second refresh can only come from callers failing to join the first.
            for _ in 0..<8 { group.addTask { try await tokens.accessToken(forceRefresh: false) } }
            var out: [String] = []
            for try await token in group { out.append(token) }
            return out
        }
        XCTAssertEqual(http.requests(to: ChatGPTPlan.tokenURL).count, 1, "exactly one refresh in flight")
        XCTAssertEqual(results, Array(repeating: "at-2", count: 8))
        XCTAssertEqual(store.credential?.refreshToken, "rt-2")
    }

    func testTerminalRefreshErrorsClearTokensButKeepTheAccount() async throws {
        let bodies = ChatGPTAuthError.terminalRefreshCodes.sorted().map { #"{"error":"\#($0)","error_description":"gone"}"# }
            + [#"{"error":{"code":"refresh_token_reused","message":"Already used","type":"invalid_request_error"}}"#]
        for body in bodies {
            let store = MemoryCredentialStore(credential: makeChatGPTCredential(expiresAt: chatGPTNow.addingTimeInterval(-10)))
            let http = RoutedHTTPClient { _, _ in .json(400, body) }
            let tokens = tokenProvider(store, http)
            do {
                _ = try await tokens.accessToken(forceRefresh: false)
                XCTFail("expected signInRequired for \(body)")
            } catch {
                XCTAssertEqual(error as? ChatGPTAuthError, .signInRequired, body)
            }
            XCTAssertNil(store.credential, body)
            XCTAssertEqual(store.account?.clientID, "oaiapp_123", "account/client mapping kept")
            let current = await tokens.currentCredential()
            XCTAssertNil(current)
            do {
                _ = try await tokens.accessToken(forceRefresh: false)
                XCTFail("expected notSignedIn")
            } catch {
                XCTAssertEqual(error as? ChatGPTAuthError, .notSignedIn)
            }
            XCTAssertEqual(http.requests.count, 1)
        }
    }

    func testRefreshWithAChangedSubjectRequiresSignIn() async throws {
        let store = MemoryCredentialStore(credential: makeChatGPTCredential(expiresAt: chatGPTNow.addingTimeInterval(-10)))
        let http = RoutedHTTPClient { _, _ in
            .json(tokenResponseJSON(access: "at-2", refresh: "rt-2", idToken: makeJWT(idTokenClaims(sub: "someone-else"))))
        }
        do {
            _ = try await tokenProvider(store, http).accessToken(forceRefresh: false)
            XCTFail("expected signInRequired")
        } catch {
            XCTAssertEqual(error as? ChatGPTAuthError, .signInRequired)
        }
        XCTAssertNil(store.credential)
        XCTAssertNotNil(store.account)
    }

    func testNetworkAndConfigurationErrorsKeepTokens() async throws {
        // Expired token + offline: the error surfaces, tokens stay for the next attempt.
        let expired = MemoryCredentialStore(credential: makeChatGPTCredential(expiresAt: chatGPTNow.addingTimeInterval(-10)))
        let offline = RoutedHTTPClient { _, _ in throw URLError(.timedOut) }
        do {
            _ = try await tokenProvider(expired, offline).accessToken(forceRefresh: false)
            XCTFail("expected network")
        } catch {
            XCTAssertEqual(error as? ChatGPTAuthError, .network("The request timed out."))
        }
        XCTAssertEqual(expired.credential?.refreshToken, "rt-1")
        XCTAssertEqual(expired.deleteCount, 0)

        // Due soon but still valid: keep using the current token when the refresh cannot connect.
        let dueSoon = MemoryCredentialStore(credential: makeChatGPTCredential(expiresAt: chatGPTNow.addingTimeInterval(120)))
        let token = try await tokenProvider(dueSoon, offline).accessToken(forceRefresh: false)
        XCTAssertEqual(token, "at-1")

        let misconfigured = MemoryCredentialStore(credential: makeChatGPTCredential(expiresAt: chatGPTNow.addingTimeInterval(-10)))
        let invalidClient = RoutedHTTPClient { _, _ in .json(401, #"{"error":"invalid_client"}"#) }
        do {
            _ = try await tokenProvider(misconfigured, invalidClient).accessToken(forceRefresh: false)
            XCTFail("expected misconfigured")
        } catch {
            guard case .misconfigured? = error as? ChatGPTAuthError else { return XCTFail("got \(error)") }
        }
        XCTAssertNotNil(misconfigured.credential)
    }

    func testNotSignedInAndInstall() async throws {
        let store = MemoryCredentialStore()
        let http = RoutedHTTPClient { _, _ in .json("{}") }
        let tokens = tokenProvider(store, http)
        do {
            _ = try await tokens.accessToken(forceRefresh: false)
            XCTFail("expected notSignedIn")
        } catch {
            XCTAssertEqual(error as? ChatGPTAuthError, .notSignedIn)
        }
        let credential = makeChatGPTCredential(access: "at-9")
        try await tokens.install(credential)
        XCTAssertEqual(store.credential, credential)
        XCTAssertEqual(store.account, credential.account)
        let token = try await tokens.accessToken(forceRefresh: false)
        XCTAssertEqual(token, "at-9")
        let account = await tokens.savedAccount()
        XCTAssertEqual(account, credential.account)
        XCTAssertTrue(http.requests.isEmpty)
    }

    // MARK: Sign-out and revocation

    private let discoveryJSON = #"{"issuer":"https://auth.openai.com","revocation_endpoint":"https://auth.openai.com/oauth/revoke","token_endpoint":"https://auth.openai.com/oauth/token"}"#
    private let revokeURL = URL(string: "https://auth.openai.com/oauth/revoke")!

    func testSignOutRevokesDeletesTokensAndKeepsTheAccount() async throws {
        let store = MemoryCredentialStore(credential: makeChatGPTCredential())
        let discovery = discoveryJSON
        let http = RoutedHTTPClient { request, _ in
            request.url == ChatGPTPlan.discoveryURL ? .json(discovery) : .empty(200)
        }
        let tokens = tokenProvider(store, http)
        await tokens.signOut()
        XCTAssertNil(store.credential)
        XCTAssertEqual(store.account?.clientID, "oaiapp_123")
        let lastError = await tokens.lastRevocationError
        XCTAssertNil(lastError)
        let current = await tokens.currentCredential()
        XCTAssertNil(current)

        XCTAssertEqual(http.requests(to: ChatGPTPlan.discoveryURL).first?.httpMethod, "GET")
        let revoke = try XCTUnwrap(http.requests(to: revokeURL).first)
        XCTAssertEqual(revoke.httpMethod, "POST")
        XCTAssertEqual(revoke.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        XCTAssertEqual(formFields(revoke.httpBody), ["token": "rt-1", "token_type_hint": "refresh_token", "client_id": "oaiapp_123"])

        // A new sign-in reuses the kept client id.
        let account = await tokens.savedAccount()
        let reauth = ChatGPTAuthorizationRequest.make(redirectURI: redirect, hostID: hostID, account: account, idTokenHint: nil)
        XCTAssertEqual(queryFields(reauth.url)["client_id"], "oaiapp_123")
    }

    func testRevokeRetriesTransientFailuresWithBoundedBackoff() async throws {
        let discovery = discoveryJSON
        let revokeURL = self.revokeURL
        let http = RoutedHTTPClient { request, call in
            if request.url == ChatGPTPlan.discoveryURL { return .json(discovery) }
            if request.url == revokeURL, call == 1 { throw URLError(.networkConnectionLost) }
            if request.url == revokeURL, call == 2 { return .json(503, #"{"detail":"busy"}"#) }
            return .empty(200)
        }
        let sleeps = Recorder<TimeInterval>()
        let auth = ChatGPTAuthClient(httpClient: http, revokeBackoff: [1, 3], sleep: { sleeps.add($0) })
        try await auth.revoke(makeChatGPTCredential())
        XCTAssertEqual(http.requests(to: revokeURL).count, 3)
        XCTAssertEqual(http.requests(to: ChatGPTPlan.discoveryURL).count, 1, "discovery is cached")
        XCTAssertEqual(sleeps.items, [1, 3])

        let alwaysDown = RoutedHTTPClient { request, _ in
            request.url == ChatGPTPlan.discoveryURL ? .json(discovery) : .json(500, #"{"detail":"down"}"#)
        }
        do {
            try await ChatGPTAuthClient(httpClient: alwaysDown, revokeBackoff: [0, 0], sleep: { _ in }).revoke(makeChatGPTCredential())
            XCTFail("expected server error")
        } catch {
            XCTAssertEqual(error as? ChatGPTAuthError, .server(status: 500, message: "down"))
        }
        XCTAssertEqual(alwaysDown.requests(to: revokeURL).count, 3, "first try + 2 retries")

        let rejected = RoutedHTTPClient { request, _ in
            request.url == ChatGPTPlan.discoveryURL ? .json(discovery) : .json(400, #"{"error":"unsupported_token_type"}"#)
        }
        do {
            try await ChatGPTAuthClient(httpClient: rejected, revokeBackoff: [0, 0], sleep: { _ in }).revoke(makeChatGPTCredential())
            XCTFail("expected oauth error")
        } catch {
            XCTAssertEqual(error as? ChatGPTAuthError, .oauth(code: "unsupported_token_type", description: nil))
        }
        XCTAssertEqual(rejected.requests(to: revokeURL).count, 1, "4xx is not retried")
    }

    func testSignOutDeletesTokensEvenWhenRevocationFails() async throws {
        let store = MemoryCredentialStore(credential: makeChatGPTCredential())
        let http = RoutedHTTPClient { _, _ in .json(500, #"{"detail":"discovery down"}"#) }
        let sleeps = Recorder<TimeInterval>()
        let tokens = tokenProvider(store, http, sleeps: sleeps)
        await tokens.signOut()
        XCTAssertNil(store.credential)
        XCTAssertNotNil(store.account)
        let lastError = await tokens.lastRevocationError
        XCTAssertEqual(lastError, .server(status: 500, message: "discovery down"))
        XCTAssertEqual(sleeps.items, [1, 3], "bounded retry")

        let noEndpoint = RoutedHTTPClient { _, _ in .json(#"{"issuer":"https://auth.openai.com"}"#) }
        do {
            try await ChatGPTAuthClient(httpClient: noEndpoint, revokeBackoff: [], sleep: { _ in }).revoke(makeChatGPTCredential())
            XCTFail("expected misconfigured")
        } catch {
            guard case .misconfigured? = error as? ChatGPTAuthError else { return XCTFail("got \(error)") }
        }
    }

    func testSignOutWithoutCredentialSendsNothing() async {
        let store = MemoryCredentialStore(account: ChatGPTAccount(clientID: "oaiapp_123", email: nil, subject: "user-1"))
        let http = RoutedHTTPClient { _, _ in .empty(200) }
        await tokenProvider(store, http).signOut()
        XCTAssertTrue(http.requests.isEmpty)
        XCTAssertNotNil(store.account)
    }

    // MARK: Hygiene

    func testCredentialDescriptionsNeverContainTokens() throws {
        let credential = makeChatGPTCredential(access: "secret-access", refresh: "secret-refresh")
        for text in [String(describing: credential), String(reflecting: credential), "\(credential)"] {
            XCTAssertFalse(text.contains("secret-access"))
            XCTAssertFalse(text.contains("secret-refresh"))
            XCTAssertFalse(text.contains(credential.idToken))
        }
        let data = try JSONEncoder().encode(credential)
        XCTAssertEqual(try JSONDecoder().decode(ChatGPTCredential.self, from: data), credential, "Codable round trip for the Keychain")
    }

    func testTokenResponseTimeFormats() throws {
        func decode(_ json: String) throws -> ChatGPTTokenResponse {
            try JSONDecoder().decode(ChatGPTTokenResponse.self, from: Data(json.utf8))
        }
        XCTAssertEqual(try decode(#"{"access_token":"a","earliest_refresh_at":600}"#).earliestRefresh(now: chatGPTNow),
                       chatGPTNow.addingTimeInterval(600))
        XCTAssertEqual(try decode(#"{"access_token":"a","earliest_refresh_at":1800000900}"#).earliestRefresh(now: chatGPTNow),
                       Date(timeIntervalSince1970: 1_800_000_900))
        XCTAssertEqual(try decode(#"{"access_token":"a","earliest_refresh_at":1800000900000}"#).earliestRefresh(now: chatGPTNow),
                       Date(timeIntervalSince1970: 1_800_000_900))
        XCTAssertEqual(try decode(#"{"access_token":"a","earliest_refresh_at":"2027-01-15T08:00:00Z"}"#).earliestRefresh(now: chatGPTNow),
                       ISO8601DateFormatter().date(from: "2027-01-15T08:00:00Z"))
        let defaults = try decode(#"{"access_token":"a","scope":["openid","email"]}"#)
        XCTAssertNil(defaults.earliestRefresh(now: chatGPTNow))
        XCTAssertEqual(defaults.accessTokenExpiry(now: chatGPTNow), chatGPTNow.addingTimeInterval(3600))
        XCTAssertEqual(defaults.scopes, ["openid", "email"])
        XCTAssertEqual(try decode(#"{"access_token":"a","expires_in":"1800"}"#).accessTokenExpiry(now: chatGPTNow),
                       chatGPTNow.addingTimeInterval(1800))
    }
}
