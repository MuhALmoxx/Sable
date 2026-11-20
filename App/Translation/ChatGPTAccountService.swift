import AuthenticationServices
import Foundation
import Observation
import UIKit
import TranslationKit

// OWNER: ChatGPT app layer (translation). "Sign in with ChatGPT" for Sable (OpenAI preview:
// ChatGPT plan usage for open-source / locally hosted apps).
//
// Flow (TranslationKit implements the protocol; this file only drives it):
// 1. Start the loopback receiver (ChatGPTLoopbackServer) on 127.0.0.1:1455 (or an OS port).
// 2. Build the authorize request for http://127.0.0.1:<port>/auth/callback with this
//    installation's ext_agent_host_id and the saved account (issued client id) if any.
// 3. Open it in the system browser with ASWebAuthenticationSession (no callback scheme: the
//    redirect goes to the loopback receiver, not to a URL scheme).
// 4. When the receiver gets the redirect: close the browser, validate state, exchange the code,
//    validate the ID token (ChatGPTAuthClient) and store the tokens (ChatGPTTokenProvider, Keychain).
// Closing the browser first just returns to signed out. Tokens are never logged.

@Observable
@MainActor
final class ChatGPTAccountService {
    enum SignInState: Equatable {
        case signedOut
        /// The browser is open (or the code is being exchanged).
        case signingIn
        case signedIn(email: String?)
        case signingOut
        /// Signed out, with the reason (declined, expired, error).
        case failed(String)
    }

    enum ModelsState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    let store: KeychainChatGPTStore
    let tokens: ChatGPTTokenProvider
    let auth: ChatGPTAuthClient
    let httpClient: any TranslationHTTPClient

    private(set) var state: SignInState
    /// Models the signed-in account may use (`visibility == "list"`), in server order.
    private(set) var models: [ChatGPTModel] = []
    private(set) var modelsState: ModelsState = .idle

    @ObservationIgnored private var attempt: ChatGPTSignInAttempt?
    @ObservationIgnored private var modelsTask: Task<Void, Never>?
    /// The person declined consent in this app session: the next attempt asks again (prompt=consent).
    @ObservationIgnored private var declinedConsent = false

    init(store: KeychainChatGPTStore, httpClient: any TranslationHTTPClient = URLSessionHTTPClient(session: .shared)) {
        self.store = store
        self.httpClient = httpClient
        let auth = ChatGPTAuthClient(httpClient: httpClient)
        self.auth = auth
        self.tokens = ChatGPTTokenProvider(store: store, auth: auth)
        if let credential = store.loadCredential() {
            state = .signedIn(email: credential.account.email)
        } else {
            state = .signedOut
        }
        if isSignedIn { loadModels() }
    }

    var isSignedIn: Bool {
        if case .signedIn = state { return true }
        return false
    }

    var email: String? {
        if case let .signedIn(email) = state { return email }
        return nil
    }

    var isBusy: Bool {
        switch state {
        case .signingIn, .signingOut: return true
        default: return false
        }
    }

    func model(for slug: String) -> ChatGPTModel? { models.first { $0.slug == slug } }

    /// The model a job uses: `chosen` when the account lists it (or the list is not loaded yet),
    /// otherwise the first listed model. nil when there is none.
    func effectiveModelID(chosen: String) -> String? {
        let chosen = chosen.trimmingCharacters(in: .whitespacesAndNewlines)
        if modelsState == .loaded {
            if !chosen.isEmpty, models.contains(where: { $0.slug == chosen }) { return chosen }
            return models.first?.slug
        }
        return chosen.isEmpty ? nil : chosen
    }

    // MARK: Sign in

    func signIn() {
        guard !isBusy, !isSignedIn else { return }
        state = .signingIn
        let attempt = ChatGPTSignInAttempt()
        self.attempt = attempt
        Task { await self.run(attempt) }
    }

    /// Closes the browser and abandons the attempt (back to signed out).
    func cancelSignIn() {
        attempt?.finish(.cancelled)
    }

    private func run(_ attempt: ChatGPTSignInAttempt) async {
        defer { if self.attempt === attempt { self.attempt = nil } }
        let request: ChatGPTAuthorizationRequest
        do {
            let hostID = try store.hostID()
            request = try await attempt.prepare(hostID: hostID, account: store.loadAccount(), forceConsent: declinedConsent)
        } catch {
            attempt.finish(.cancelled)
            guard self.attempt === attempt else { return }
            state = .failed(Self.message(for: error))
            return
        }
        let outcome = await attempt.waitForCallback(opening: request.url)
        guard self.attempt === attempt else { return }
        switch outcome {
        case .browserClosed, .cancelled:
            state = .signedOut
        case .timedOut:
            state = .failed("Sign-in timed out. Try again.")
        case let .failed(message):
            state = .failed(message)
        case let .callback(items):
            do {
                let callback = try ChatGPTAuthorizationCallback(queryItems: items, expectedState: request.state)
                let credential = try await auth.completeSignIn(request, callback: callback, now: Date())
                try await tokens.install(credential)
                guard self.attempt === attempt else { return }
                declinedConsent = false
                state = .signedIn(email: credential.account.email)
                loadModels()
            } catch {
                if let auth = error as? ChatGPTAuthError, auth == .accessDenied { declinedConsent = true }
                guard self.attempt === attempt else { return }
                state = .failed(Self.message(for: error))
            }
        }
    }

    // MARK: Sign out

    /// Stops model requests, revokes the refresh token (best effort), deletes the tokens from the
    /// Keychain and keeps the account/client mapping so the next sign-in reuses the client id.
    func signOut() async {
        guard state != .signingOut else { return }
        attempt?.finish(.cancelled)
        modelsTask?.cancel()
        modelsTask = nil
        state = .signingOut
        await tokens.signOut()
        models = []
        modelsState = .idle
        state = .signedOut
    }

    /// A request found the sign-in revoked or expired for good: clear the tokens and ask the person
    /// to sign in again.
    func sessionEnded() async {
        guard isSignedIn else { return }
        modelsTask?.cancel()
        modelsTask = nil
        state = .signingOut
        await tokens.signOut()
        models = []
        modelsState = .idle
        state = .failed("Your ChatGPT sign-in has ended. Sign in again to keep using your plan.")
    }

    // MARK: Models

    func loadModels() {
        guard isSignedIn else { return }
        modelsTask?.cancel()
        modelsState = .loading
        let tokens = self.tokens
        let httpClient = self.httpClient
        modelsTask = Task { [weak self] in
            do {
                let list = try await ChatGPTModels.list(tokens: tokens, httpClient: httpClient)
                guard !Task.isCancelled, let self else { return }
                self.models = list
                self.modelsState = .loaded
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, let self else { return }
                if ChatGPTAccountService.isSignInRequired(error) {
                    // This task is done: sessionEnded must not cancel it (that would skip the revoke).
                    self.modelsTask = nil
                    await self.sessionEnded()
                } else {
                    self.modelsState = .failed(ChatGPTAccountService.message(for: error))
                }
            }
        }
    }

    // MARK: Messages

    static func isSignInRequired(_ error: Error) -> Bool {
        if let auth = error as? ChatGPTAuthError {
            switch auth {
            case .signInRequired, .notSignedIn: return true
            default: return false
            }
        }
        if let translation = error as? TranslationError, case .signInRequired = translation { return true }
        return false
    }

    static func message(for error: Error) -> String {
        if let auth = error as? ChatGPTAuthError {
            switch auth {
            case .notSignedIn, .signInRequired:
                return "Your ChatGPT sign-in has ended. Sign in with ChatGPT again."
            default:
                // accessDenied: "You didn't allow Sable to use your ChatGPT plan. Nothing was connected."
                return auth.errorDescription ?? "Signing in with ChatGPT failed."
            }
        }
        if let translation = error as? TranslationError {
            return translation.errorDescription ?? "The request to ChatGPT failed."
        }
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return error.localizedDescription
    }
}

// MARK: - One sign-in attempt

/// Owns the loopback receiver and the browser session of one attempt and reports the first of:
/// the redirect, the browser closing, a cancel, the receiver timing out or failing.
@MainActor
final class ChatGPTSignInAttempt {
    enum Outcome: Sendable {
        case callback([URLQueryItem])
        case browserClosed
        case cancelled
        case timedOut
        case failed(String)
    }

    private let server = ChatGPTLoopbackServer()
    private let anchorProvider = ChatGPTPresentationAnchorProvider()
    private var session: ASWebAuthenticationSession?
    private var continuation: CheckedContinuation<Outcome, Never>?
    private var result: Outcome?

    /// Starts the receiver and builds the authorize request for its redirect URI. `forceConsent`
    /// adds prompt=consent (asking again after a decline).
    func prepare(hostID: String, account: ChatGPTAccount?, forceConsent: Bool) async throws -> ChatGPTAuthorizationRequest {
        let port = try await server.start(preferredPort: ChatGPTPlan.preferredCallbackPort) { [weak self] event in
            Task { @MainActor in self?.receiverEvent(event) }
        }
        let request = ChatGPTAuthorizationRequest.make(redirectURI: ChatGPTPlan.redirectURI(port: port), hostID: hostID,
                                                       account: account, idTokenHint: nil, forceConsent: forceConsent)
        server.expectState(request.state)
        return request
    }

    /// Opens the system browser on `url` and waits for the outcome.
    func waitForCallback(opening url: URL) async -> Outcome {
        if let result { return result }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
            self.continuation = continuation
            self.openBrowser(url)
        }
    }

    /// Ends the attempt once: stops the receiver, closes the browser and resumes the waiter.
    func finish(_ outcome: Outcome) {
        guard result == nil else { return }
        result = outcome
        server.stop()
        let session = self.session
        self.session = nil
        session?.cancel()
        if let continuation {
            self.continuation = nil
            continuation.resume(returning: outcome)
        }
    }

    private func openBrowser(_ url: URL) {
        guard result == nil else {
            if let result, let continuation {
                self.continuation = nil
                continuation.resume(returning: result)
            }
            return
        }
        // No callback scheme: OpenAI redirects to the loopback receiver, which reports the result;
        // the session only ends by itself when the person closes the browser.
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: nil) { [weak self] _, error in
            Task { @MainActor in self?.browserEnded(error) }
        }
        session.presentationContextProvider = anchorProvider
        session.prefersEphemeralWebBrowserSession = false
        self.session = session
        if !session.start() {
            finish(.failed("Sable couldn't open the ChatGPT sign-in page."))
        }
    }

    private func receiverEvent(_ event: ChatGPTLoopbackServer.Event) {
        switch event {
        case let .callback(items): finish(.callback(items))
        case .timedOut: finish(.timedOut)
        case let .failed(message): finish(.failed(message))
        }
    }

    private func browserEnded(_ error: Error?) {
        guard result == nil else { return }
        if let error, let sessionError = error as? ASWebAuthenticationSessionError, sessionError.code != .canceledLogin {
            finish(.failed("The sign-in page could not be shown (\(sessionError.localizedDescription))."))
        } else {
            finish(.browserClosed)
        }
    }
}

/// Presents the browser over Sable's key window.
final class ChatGPTPresentationAnchorProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // UIKit calls this on the main thread.
        MainActor.assumeIsolated {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let windows = scenes.flatMap { $0.windows }
            if let key = windows.first(where: { $0.isKeyWindow }) ?? windows.first { return key }
            if let scene = scenes.first { return UIWindow(windowScene: scene) }
            return ASPresentationAnchor()
        }
    }
}
