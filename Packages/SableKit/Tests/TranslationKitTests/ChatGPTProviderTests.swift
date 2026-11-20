import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
import SubtitleKit
@testable import TranslationKit

final class ChatGPTProviderTests: XCTestCase {
    private func request() -> TranslationChunkRequest {
        TranslationChunkRequest(source: .english, target: TargetLanguages.arabic,
                                units: [TranslationUnit(id: "3", text: "Then let's go up to the roof."),
                                        TranslationUnit(id: "4", text: "<i>Is it safe?</i>")],
                                precedingContext: [.init(id: "2", source: "I can't sleep.", translation: "لا أستطيع النوم.")],
                                followingContext: [.init(id: "5", source: "Trust me.", translation: nil)],
                                glossary: [GlossaryEntry(source: "Mara", target: "مارا")])
    }

    private let okText = #"{"translations":[{"id":"3","text":"إذن لنصعد إلى السطح."},{"id":"4","text":"<i>هل هو آمن؟</i>"}],"names":[{"source":"Mara","target":"مارا"}]}"#

    private struct Harness {
        let http: RoutedHTTPClient
        let store: MemoryCredentialStore
        let tokens: ChatGPTTokenProvider
        let provider: ChatGPTPlanTranslationProvider
    }

    /// `responses` answers POST /v1/responses (call index per URL); the token endpoint rotates to
    /// at-2/rt-2, at-3/rt-3, …; /v1/models answers `models`.
    private func harness(credential: ChatGPTCredential? = makeChatGPTCredential(), modelID: String = "gpt-5.5",
                         tokenReply: RoutedHTTPClient.Reply? = nil,
                         models: (@Sendable (URLRequest, Int) -> RoutedHTTPClient.Reply)? = nil,
                         responses: @escaping @Sendable (URLRequest, Int) throws -> RoutedHTTPClient.Reply) -> Harness {
        let http = RoutedHTTPClient { request, call in
            if request.url == ChatGPTPlan.tokenURL {
                return tokenReply ?? .json(tokenResponseJSON(access: "at-\(call + 1)", refresh: "rt-\(call + 1)", idToken: nil))
            }
            if request.url == ChatGPTPlan.modelsURL {
                return models?(request, call) ?? .json(404, "{}")
            }
            return try responses(request, call)
        }
        let store = MemoryCredentialStore(credential: credential)
        let auth = ChatGPTAuthClient(httpClient: http, revokeBackoff: [], sleep: { _ in })
        let tokens = ChatGPTTokenProvider(store: store, auth: auth, now: { chatGPTNow })
        return Harness(http: http, store: store, tokens: tokens,
                       provider: ChatGPTPlanTranslationProvider(modelID: modelID, tokens: tokens, httpClient: http))
    }

    private func assertThrows(_ expected: TranslationError, file: StaticString = #filePath, line: UInt = #line,
                              _ body: @escaping () async throws -> Void) async {
        do {
            try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? TranslationError, expected, file: file, line: line)
        }
    }

    private func body(_ request: URLRequest?) throws -> [String: Any] { try jsonObject(request?.httpBody) }

    // MARK: Descriptor and contract additions

    func testDescriptor() {
        let d = ChatGPTPlanTranslationProvider.descriptor
        XCTAssertEqual(d.id, "chatgpt-plan")
        XCTAssertEqual(d.displayName, "ChatGPT plan")
        XCTAssertFalse(d.isPaid)
        XCTAssertFalse(d.requiresAPIKey)
        XCTAssertTrue(d.usesContext)
        XCTAssertEqual(d.recommendedChunkSize, 40)
        XCTAssertTrue(d.usesSubscriptionAllowance)
        XCTAssertTrue(d.summary.contains("Plus or Pro"))
        XCTAssertFalse(ClaudeTranslationProvider.descriptor.usesSubscriptionAllowance)
        XCTAssertFalse(TranslationProviderDescriptor(id: "x", displayName: "X", summary: "", isPaid: false, requiresAPIKey: false,
                                                     usesContext: false, recommendedChunkSize: 1).usesSubscriptionAllowance,
                       "existing call sites default to false")
        let h = harness { _, _ in .sse("") }
        XCTAssertEqual(h.provider.descriptor, d)
        XCTAssertEqual(h.provider.modelID, "gpt-5.5")
    }

    func testNewErrorDescriptions() {
        XCTAssertEqual(TranslationError.planUsageLimitReached.errorDescription,
                       "You've reached your ChatGPT plan's usage limit. Sable paused the translation; finished lines are kept. Check Manage usage in ChatGPT settings, then resume later.")
        XCTAssertEqual(TranslationError.signInRequired("Sign in again.").errorDescription, "Sign in again.")
        XCTAssertEqual(TranslationError.planNotEligible("Plus or Pro is required.").errorDescription, "Plus or Pro is required.")
    }

    // MARK: Models

    func testModelsListKeepsListedEntries() async throws {
        let h = harness(models: { _, _ in
            .json(#"""
            {"models":[
              {"slug":"gpt-5.5","display_name":"GPT-5.5","visibility":"list","supported_in_api":true},
              {"slug":"internal-eval","display_name":"Hidden","visibility":"hide"},
              {"slug":"gpt-5.5-mini","display_name":"GPT-5.5 mini","visibility":"list"},
              {"slug":"no-visibility","display_name":"Unknown"},
              {"slug":"gpt-5.5","display_name":"Duplicate","visibility":"list"},
              {"slug":"bare","visibility":"list"}
            ]}
            """#)
        }, responses: { _, _ in .empty(500) })
        let models = try await ChatGPTModels.list(tokens: h.tokens, httpClient: h.http)
        XCTAssertEqual(models, [ChatGPTModel(slug: "gpt-5.5", displayName: "GPT-5.5"),
                                ChatGPTModel(slug: "gpt-5.5-mini", displayName: "GPT-5.5 mini"),
                                ChatGPTModel(slug: "bare", displayName: "bare")])
        XCTAssertEqual(models.first?.id, "gpt-5.5")
        let sent = try XCTUnwrap(h.http.requests(to: ChatGPTPlan.modelsURL).first)
        XCTAssertEqual(sent.httpMethod, "GET")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Bearer at-1")
        XCTAssertNil(sent.httpBody)

        XCTAssertEqual(ChatGPTModels.parse(Data(#"{"data":[{"id":"gpt-x","visibility":"list"}]}"#.utf8)),
                       [ChatGPTModel(slug: "gpt-x", displayName: "gpt-x")])
        XCTAssertNil(ChatGPTModels.parse(Data("nope".utf8)))
    }

    func testModelsListRefreshesOnceOn401() async throws {
        let h = harness(models: { _, call in
            call == 1 ? .json(401, #"{"detail":"Unauthorized"}"#) : .json(#"{"models":[{"slug":"gpt-5.5","display_name":"GPT-5.5","visibility":"list"}]}"#)
        }, responses: { _, _ in .empty(500) })
        let models = try await ChatGPTModels.list(tokens: h.tokens, httpClient: h.http)
        XCTAssertEqual(models.map(\.slug), ["gpt-5.5"])
        XCTAssertEqual(h.http.requests(to: ChatGPTPlan.tokenURL).count, 1)
        XCTAssertEqual(h.http.requests(to: ChatGPTPlan.modelsURL).map { $0.value(forHTTPHeaderField: "Authorization") },
                       ["Bearer at-1", "Bearer at-2"])
        XCTAssertEqual(h.store.credential?.refreshToken, "rt-2")

        let rejected = harness(models: { _, _ in .json(401, #"{"detail":"Unauthorized"}"#) }, responses: { _, _ in .empty(500) })
        do {
            _ = try await ChatGPTModels.list(tokens: rejected.tokens, httpClient: rejected.http)
            XCTFail("expected signInRequired")
        } catch {
            XCTAssertEqual(error as? ChatGPTAuthError, .signInRequired)
        }
        XCTAssertEqual(rejected.http.requests(to: ChatGPTPlan.modelsURL).count, 2)

        let notEligible = harness(models: { _, _ in
            .json(403, #"{"error":{"code":"subscription_sharing_user_not_eligible","message":"no"}}"#)
        }, responses: { _, _ in .empty(500) })
        do {
            _ = try await ChatGPTModels.list(tokens: notEligible.tokens, httpClient: notEligible.http)
            XCTFail("expected server error")
        } catch {
            XCTAssertEqual(error as? ChatGPTAuthError, .server(status: 403, message: ChatGPTPlanTranslationProvider.notEligibleMessage))
        }

        let signedOut = harness(credential: nil, responses: { _, _ in .empty(500) })
        do {
            _ = try await ChatGPTModels.list(tokens: signedOut.tokens, httpClient: signedOut.http)
            XCTFail("expected notSignedIn")
        } catch {
            XCTAssertEqual(error as? ChatGPTAuthError, .notSignedIn)
        }
        XCTAssertTrue(signedOut.http.requests.isEmpty)
    }

    // MARK: Request

    func testRequestShapeFollowsThePlanUsageRules() async throws {
        let text = okText
        let h = harness { _, _ in .sse(successStream(text)) }
        _ = try await h.provider.translate(request())
        let sent = try XCTUnwrap(h.http.requests(to: ChatGPTPlan.responsesURL).first)
        XCTAssertEqual(sent.httpMethod, "POST")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Bearer at-1")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Accept"), "text/event-stream")
        XCTAssertEqual(sent.timeoutInterval, 180)

        let json = try body(sent)
        XCTAssertEqual(Set(json.keys), ["model", "instructions", "input", "text", "stream", "store"])
        XCTAssertEqual(json["model"] as? String, "gpt-5.5")
        XCTAssertEqual(json["stream"] as? Bool, true)
        XCTAssertEqual(json["store"] as? Bool, false)
        for forbidden in ChatGPTPlanTranslationProvider.forbiddenBodyFields {
            XCTAssertNil(json[forbidden], "\(forbidden) must never be sent")
        }
        XCTAssertNil(json["messages"])
        XCTAssertNil(json["system"])

        let instructions = try XCTUnwrap(json["instructions"] as? String)
        XCTAssertTrue(instructions.contains("from English into Arabic"))
        XCTAssertTrue(instructions.contains(TargetLanguages.arabic.promptGuidance))
        XCTAssertTrue(instructions.contains("REPLY FORMAT"))
        XCTAssertTrue(instructions.hasPrefix(ClaudePrompt.system(source: .english, target: TargetLanguages.arabic)),
                      "same translator brief as the Claude provider")

        let input = try XCTUnwrap(json["input"] as? [[String: Any]])
        XCTAssertEqual(input.count, 1)
        XCTAssertEqual(input[0]["role"] as? String, "user")
        XCTAssertFalse(input.contains { ($0["role"] as? String) == "system" }, "no system role items")
        let content = try XCTUnwrap(input[0]["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, 1)
        XCTAssertEqual(content[0]["type"] as? String, "input_text")
        let payload = try jsonObject(Data(try XCTUnwrap(content[0]["text"] as? String).utf8))
        XCTAssertEqual((payload["units"] as? [[String: Any]])?.map { $0["id"] as? String }, ["3", "4"])
        XCTAssertEqual((payload["preceding_context"] as? [[String: Any]])?.first?["translation"] as? String, "لا أستطيع النوم.")
        XCTAssertEqual((payload["following_context"] as? [[String: Any]])?.first?["id"] as? String, "5")
        XCTAssertEqual((payload["glossary"] as? [[String: Any]])?.first?["target"] as? String, "مارا")

        let format = try XCTUnwrap((json["text"] as? [String: Any])?["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")
        XCTAssertEqual(format["name"] as? String, "subtitle_translations")
        XCTAssertEqual(format["strict"] as? Bool, true)
        let schema = try XCTUnwrap(format["schema"] as? [String: Any])
        XCTAssertEqual(schema["required"] as? [String], ["translations", "names"])
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)

        let plain = try jsonObject(h.provider.requestBody(for: request(), structuredOutput: false).data)
        XCTAssertEqual(Set(plain.keys), ["model", "instructions", "input", "stream", "store"])
        XCTAssertEqual(plain["instructions"] as? String, instructions, "instructions identical with or without the schema")
    }

    func testMissingModelFailsWithoutRequest() async {
        let h = harness(modelID: "  ") { _, _ in .sse("") }
        await assertThrows(.providerUnavailable("Choose a ChatGPT model in Settings › Translation.")) {
            _ = try await h.provider.translate(self.request())
        }
        XCTAssertTrue(h.http.requests.isEmpty)
    }

    // MARK: Streaming

    func testParsesDeltasSplitMidJSON() async throws {
        let text = "```json\n" + okText + "\n```"
        let stream = sseStream([#"{"type":"response.created","response":{"id":"resp_1","status":"in_progress"}}"#]
                               + [#"{"type":"response.in_progress","response":{"id":"resp_1","status":"in_progress"}}"#]
                               + stride(from: 0, to: text.count, by: 5).map { start -> String in
                                   let from = text.index(text.startIndex, offsetBy: start)
                                   let to = text.index(from, offsetBy: min(5, text.distance(from: from, to: text.endIndex)))
                                   return deltaEvent(String(text[from..<to]))
                               }
                               + [#"{"type":"response.output_text.done","text":"ignored when deltas exist"}"#,
                                  completedEvent(model: "gpt-5.5-2026-06-01", inputTokens: 1500, outputTokens: 400)],
                               lineEnding: "\r\n")
        let h = harness { _, _ in .sse(": ping\r\n\r\n" + stream + "data: [DONE]\r\n\r\n") }
        let response = try await h.provider.translate(request())
        XCTAssertEqual(response.translations, ["3": "إذن لنصعد إلى السطح.", "4": "<i>هل هو آمن؟</i>"])
        XCTAssertEqual(response.glossary, [GlossaryEntry(source: "Mara", target: "مارا")])
        XCTAssertEqual(response.usage, TokenUsage(inputTokens: 1500, outputTokens: 400))
        XCTAssertNil(response.servedByModel, "a dated snapshot of the requested model is not a fallback")
    }

    func testCompletedResponseTextAndServedModel() async throws {
        let text = okText
        let h = harness { _, _ in .sse(sseStream([completedEvent(outputText: text, model: "gpt-5.4")])) }
        let response = try await h.provider.translate(request())
        XCTAssertEqual(response.translations.count, 2)
        XCTAssertEqual(response.servedByModel, "gpt-5.4")
    }

    func testEventParser() {
        let events = ChatGPTStream.events(in: "event: a\ndata: {\"x\":\ndata: 1}\n\n: comment\nid: 7\ndata:{\"y\":2}\n\nevent: tail\ndata: z")
        XCTAssertEqual(events, [ChatGPTStream.Event(name: "a", data: "{\"x\":\n1}"),
                                ChatGPTStream.Event(name: nil, data: "{\"y\":2}"),
                                ChatGPTStream.Event(name: "tail", data: "z")])
        // Non-streamed Response object fallback.
        let object = #"{"id":"r","object":"response","status":"completed","model":"gpt-5.5","output":[{"type":"message","content":[{"type":"output_text","text":"hi"}]}]}"#
        XCTAssertEqual(ChatGPTStream.parse(Data(object.utf8)),
                       .completed(ChatGPTStream.Result(text: "hi", refusal: nil, usage: nil, model: "gpt-5.5")))
        XCTAssertEqual(ChatGPTStream.parse(Data("<html>".utf8)), .unreadable)
    }

    func testIncompleteTruncatedRefusedAndUnreadableStreams() async throws {
        let cases: [(String, TranslationError)] = [
            (sseStream([#"{"type":"response.incomplete","response":{"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"}}}"#]),
             .malformedResponse("The reply was cut off (max_output_tokens).")),
            (sseStream([#"{"type":"response.incomplete","response":{"status":"incomplete","incomplete_details":{"reason":"content_filter"}}}"#]),
             .refused("ChatGPT stopped the reply (content filter).")),
            (sseStream([deltaEvent(#"{"translations":[{"id":"3","te"#)]), .network("The reply stream ended before it completed.")),
            (sseStream([completedEvent(refusal: "I can't help with that.")]), .refused("I can't help with that.")),
            (sseStream([completedEvent(outputText: "Sorry, no JSON here")]), .malformedResponse("The reply did not match the translation format.")),
            (sseStream([completedEvent()]), .malformedResponse("The reply contained no text.")),
            ("<html>oops</html>", .malformedResponse("The reply was not a ChatGPT response stream.")),
        ]
        for (stream, expected) in cases {
            let h = harness { _, _ in .sse(stream) }
            await assertThrows(expected) { _ = try await h.provider.translate(self.request()) }
            XCTAssertEqual(h.http.requests(to: ChatGPTPlan.responsesURL).count, 1, "\(expected): no provider-level retry")
        }
    }

    // MARK: Errors

    func testStreamedFailureCodes() async throws {
        let cases: [(String, TranslationError)] = [
            ("subscription_sharing_user_not_eligible",
             .planNotEligible("Your ChatGPT account isn't eligible for plan usage in apps. ChatGPT Plus or Pro is required.")),
            ("subscription_sharing_usage_limit_exceeded", .planUsageLimitReached),
            ("subscription_sharing_usage_unavailable", .server(status: 503, message: ChatGPTPlanTranslationProvider.temporarilyUnavailableMessage)),
            ("subscription_sharing_user_unavailable", .server(status: 503, message: ChatGPTPlanTranslationProvider.temporarilyUnavailableMessage)),
            ("subscription_sharing_route_not_supported",
             .providerUnavailable("ChatGPT plan usage doesn't support this kind of request. Choose another provider in Settings › Translation.")),
            ("chatpass_v2_scope_not_authorized",
             .providerUnavailable("ChatGPT didn't authorize Sable for plan usage (chatpass_v2_scope_not_authorized). Sign out and sign in with ChatGPT again in Settings › Translation.")),
            ("chatpass_v2_invalid_authorization_context",
             .providerUnavailable("ChatGPT didn't authorize Sable for plan usage (chatpass_v2_invalid_authorization_context). Sign out and sign in with ChatGPT again in Settings › Translation.")),
            ("server_error", .server(status: 500, message: "failed")),
            ("rate_limit_exceeded", .rateLimited(retryAfter: nil)),
            ("context_length_exceeded", .malformedResponse("The request was too large.")),
            ("something_new", .providerUnavailable("ChatGPT couldn't complete the request (something_new): failed")),
        ]
        for (code, expected) in cases {
            let h = harness { _, _ in .sse(sseStream([deltaEvent("{\"tra"), failedEvent(code: code)])) }
            await assertThrows(expected) { _ = try await h.provider.translate(self.request()) }
            XCTAssertEqual(h.http.requests(to: ChatGPTPlan.responsesURL).count, 1, code)
            XCTAssertTrue(h.http.requests(to: ChatGPTPlan.tokenURL).isEmpty, code)
        }
        // A bare "error" event carries the code at the top level.
        let h = harness { _, _ in .sse(sseStream([#"{"type":"error","code":"subscription_sharing_usage_limit_exceeded","message":"limit","param":null}"#])) }
        await assertThrows(.planUsageLimitReached) { _ = try await h.provider.translate(self.request()) }
    }

    func testHTTPErrorsBeforeTheStream() async throws {
        let cases: [(Int, String, TranslationError)] = [
            (403, #"{"detail":"Not available in your region"}"#, .providerUnavailable("ChatGPT declined the request (policy or region): Not available in your region")),
            (403, #"{"error":{"code":"subscription_sharing_user_not_eligible","message":"x","type":"invalid_request_error"}}"#,
             .planNotEligible(ChatGPTPlanTranslationProvider.notEligibleMessage)),
            (429, #"{"error":{"code":"subscription_sharing_usage_limit_exceeded","message":"Usage limit reached"}}"#, .planUsageLimitReached),
            (429, #"{"detail":"Too many requests"}"#, .planUsageLimitReached),
            (503, #"{"detail":"Service unavailable"}"#, .server(status: 503, message: ChatGPTPlanTranslationProvider.temporarilyUnavailableMessage)),
            (400, #"{"error":{"message":"Bad input","type":"invalid_request_error","param":"input","code":null}}"#, .server(status: 400, message: "Bad input")),
            (404, #"{"error":{"code":"model_not_found","message":"nope"}}"#,
             .providerUnavailable("The model gpt-5.5 isn't available to your ChatGPT account. Choose another model in Settings › Translation.")),
            (413, "", .malformedResponse("The request was too large.")),
            (500, "not json", .server(status: 500, message: HTTPURLResponse.localizedString(forStatusCode: 500))),
        ]
        for (status, json, expected) in cases {
            let h = harness { _, _ in .json(status, json) }
            await assertThrows(expected) { _ = try await h.provider.translate(self.request()) }
            XCTAssertEqual(h.http.requests(to: ChatGPTPlan.responsesURL).count, 1, "\(status) \(json)")
        }
    }

    func testErrorMessagesNeverContainTokens() async throws {
        let h = harness(credential: makeChatGPTCredential(access: "secret-access-token", refresh: "secret-refresh")) { _, _ in
            .json(403, #"{"detail":"blocked"}"#)
        }
        do {
            _ = try await h.provider.translate(request())
            XCTFail("expected an error")
        } catch {
            let text = "\(error) \(error.localizedDescription)"
            XCTAssertFalse(text.contains("secret-access-token"))
            XCTAssertFalse(text.contains("secret-refresh"))
        }
    }

    func testUnauthorizedRefreshesOnceAndRetries() async throws {
        let text = okText
        let h = harness { _, call in call == 1 ? .json(401, #"{"detail":"Unauthorized"}"#) : .sse(successStream(text)) }
        let response = try await h.provider.translate(request())
        XCTAssertEqual(response.translations.count, 2)
        XCTAssertEqual(h.http.requests(to: ChatGPTPlan.tokenURL).count, 1)
        XCTAssertEqual(h.http.requests(to: ChatGPTPlan.responsesURL).map { $0.value(forHTTPHeaderField: "Authorization") },
                       ["Bearer at-1", "Bearer at-2"])
        XCTAssertEqual(h.store.credential?.refreshToken, "rt-2", "rotated pair persisted")

        // subscription_sharing_invalid_user inside the stream takes the same path.
        let streamed = harness { _, call in
            call == 1 ? .sse(sseStream([failedEvent(code: "subscription_sharing_invalid_user")])) : .sse(successStream(text))
        }
        _ = try await streamed.provider.translate(request())
        XCTAssertEqual(streamed.http.requests(to: ChatGPTPlan.tokenURL).count, 1)
    }

    func testUnauthorizedTwiceAsksToSignInAgain() async throws {
        let h = harness { _, _ in .json(401, #"{"detail":"Unauthorized"}"#) }
        await assertThrows(.signInRequired("Sign in with ChatGPT again in Settings › Translation.")) {
            _ = try await h.provider.translate(self.request())
        }
        XCTAssertEqual(h.http.requests(to: ChatGPTPlan.responsesURL).count, 2)
        XCTAssertEqual(h.http.requests(to: ChatGPTPlan.tokenURL).count, 1, "exactly one forced refresh")
    }

    func testSignInProblemsMapToSignInRequired() async throws {
        let signedOut = harness(credential: nil) { _, _ in .sse("") }
        await assertThrows(.signInRequired("Sign in with ChatGPT in Settings › Translation first.")) {
            _ = try await signedOut.provider.translate(self.request())
        }
        XCTAssertTrue(signedOut.http.requests.isEmpty)

        let revoked = harness(credential: makeChatGPTCredential(expiresAt: chatGPTNow.addingTimeInterval(-5)),
                              tokenReply: .json(400, #"{"error":"refresh_token_invalidated"}"#)) { _, _ in .sse("") }
        await assertThrows(.signInRequired("Sign in with ChatGPT again in Settings › Translation.")) {
            _ = try await revoked.provider.translate(self.request())
        }
        XCTAssertTrue(revoked.http.requests(to: ChatGPTPlan.responsesURL).isEmpty)
        XCTAssertNil(revoked.store.credential)
        XCTAssertNotNil(revoked.store.account)

        let offline = harness(credential: makeChatGPTCredential(expiresAt: chatGPTNow.addingTimeInterval(-5))) { _, _ in .sse("") }
        let offlineHTTP = RoutedHTTPClient { _, _ in throw URLError(.notConnectedToInternet) }
        let offlineTokens = ChatGPTTokenProvider(store: offline.store,
                                                 auth: ChatGPTAuthClient(httpClient: offlineHTTP, revokeBackoff: [], sleep: { _ in }),
                                                 now: { chatGPTNow })
        let provider = ChatGPTPlanTranslationProvider(modelID: "gpt-5.5", tokens: offlineTokens, httpClient: offlineHTTP)
        await assertThrows(.network("You appear to be offline.")) { _ = try await provider.translate(self.request()) }
        XCTAssertNotNil(offline.store.credential, "network errors keep tokens")
    }

    func testTransportErrorsMapToNetwork() async throws {
        let h = harness { _, _ in throw URLError(.timedOut) }
        await assertThrows(.network("The request timed out.")) { _ = try await h.provider.translate(self.request()) }
    }

    // MARK: text.format fallback

    func testUnsupportedTextFormatFallsBackOnceAndIsRemembered() async throws {
        let text = okText
        let h = harness { request, call in
            if call == 1 {
                return .sse(sseStream([#"{"type":"error","code":"subscription_sharing_unsupported_capability","message":"text.format is not supported","param":"text.format"}"#]))
            }
            return .sse(successStream(text))
        }
        XCTAssertTrue(h.provider.usesStructuredOutput)
        let first = try await h.provider.translate(request())
        XCTAssertEqual(first.translations.count, 2)
        _ = try await h.provider.translate(request())
        let sent = h.http.requests(to: ChatGPTPlan.responsesURL)
        XCTAssertEqual(sent.count, 3)
        XCTAssertNotNil(try body(sent[0])["text"])
        XCTAssertNil(try body(sent[1])["text"], "rejected field removed on the retry")
        XCTAssertNil(try body(sent[2])["text"], "remembered for the provider's lifetime")
        XCTAssertNotEqual(sent[0].httpBody, sent[1].httpBody, "never resend the same body")
        XCTAssertTrue((try body(sent[1])["instructions"] as? String)?.contains("REPLY FORMAT") == true)
        XCTAssertFalse(h.provider.usesStructuredOutput)
        XCTAssertEqual(h.http.requests(to: ChatGPTPlan.tokenURL).count, 0)
    }

    func testUnsupportedTextFormatBeforeTheStream() async throws {
        let text = okText
        let h = harness { _, call in
            call == 1
                ? .json(400, #"{"error":{"code":"subscription_sharing_unsupported_capability","message":"Unsupported","param":"text","type":"invalid_request_error"}}"#)
                : .sse(successStream(text))
        }
        _ = try await h.provider.translate(request())
        XCTAssertEqual(h.http.requests(to: ChatGPTPlan.responsesURL).count, 2)
    }

    func testOtherUnsupportedCapabilitiesStopWithoutResending() async throws {
        let unsupportedInput = #"{"type":"error","code":"subscription_sharing_unsupported_capability","message":"no","param":"input[0].content"}"#
        let h = harness { _, _ in .sse(sseStream([unsupportedInput])) }
        await assertThrows(.providerUnavailable("ChatGPT plan usage doesn't support part of Sable's request (input[0].content).")) {
            _ = try await h.provider.translate(self.request())
        }
        XCTAssertEqual(h.http.requests(to: ChatGPTPlan.responsesURL).count, 1)

        let unsupportedFormat = #"{"type":"error","code":"subscription_sharing_unsupported_capability","message":"no","param":"text.format"}"#
        let always = harness { _, _ in .sse(sseStream([unsupportedFormat])) }
        await assertThrows(.providerUnavailable("ChatGPT plan usage doesn't support part of Sable's request (text.format).")) {
            _ = try await always.provider.translate(self.request())
        }
        XCTAssertEqual(always.http.requests(to: ChatGPTPlan.responsesURL).count, 2, "one fallback retry only")
    }

    // MARK: Engine

    func testEngineTreatsPlanErrorsAsTerminalAndKeepsTheCheckpoint() async throws {
        for fatal in [TranslationError.planUsageLimitReached, .signInRequired("Sign in again."), .planNotEligible("Plus or Pro.")] {
            let sleeps = Recorder<TimeInterval>()
            let provider = FakeProvider { call, request in
                if call == 2 { throw fatal }
                return FakeProvider.arabic(for: request)
            }
            let engine = TranslationEngine(storeDirectory: temporaryDirectory(), sleep: { sleeps.add($0) })
            let spec = makeSpec(makeDocument(count: 8), chunkSize: 4)
            do {
                _ = try await engine.run(spec, provider: provider, progress: { _ in })
                XCTFail("expected \(fatal)")
            } catch {
                XCTAssertEqual(error as? TranslationError, fatal)
            }
            XCTAssertEqual(provider.callCount, 2, "no retry for \(fatal)")
            XCTAssertTrue(sleeps.items.isEmpty)
            let checkpoint = await engine.checkpointProgress(for: spec)
            XCTAssertEqual(checkpoint?.completedCues, 4, "finished lines kept for Resume")
        }
    }

    func testEndToEndThroughEngineWithStreamedReplies() async throws {
        // Echo the requested ids back in Arabic as a streamed reply so the engine maps a real round trip.
        let h = harness { request, _ in
            let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
            let input = try XCTUnwrap(body["input"] as? [[String: Any]])
            let content = try XCTUnwrap(input.first?["content"] as? [[String: Any]])
            let payloadText = try XCTUnwrap(content.first?["text"] as? String)
            let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(payloadText.utf8)) as? [String: Any])
            let ids = (payload["units"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
            let items = ids.map { JSONValue.object([("id", .string($0)), ("text", .string("سطر \($0)?"))]) }
            let text = JSONValue.object([("translations", .array(items)), ("names", .array([]))]).serialized()
            return .sse(successStream(text, pieceLength: 11))
        }
        let engine = TranslationEngine(storeDirectory: temporaryDirectory(), sleep: { _ in })
        let doc = makeDocument(count: 45)
        let spec = makeSpec(doc, chunkSize: 40, contextSize: 6, provider: ChatGPTPlan.providerID, model: h.provider.modelID)
        let progress = Recorder<TranslationProgress>()
        let result = try await engine.run(spec, provider: h.provider, progress: { progress.add($0) })
        XCTAssertEqual(result.cues.map(\.id), doc.cues.map(\.id))
        XCTAssertEqual(result.cues[44].text, "سطر 45؟", "post-processing applied")
        XCTAssertEqual(h.http.requests(to: ChatGPTPlan.responsesURL).count, 2)
        XCTAssertEqual(progress.items.last?.fallbackResponses, 0)
        XCTAssertEqual(progress.items.last?.usage, TokenUsage(inputTokens: 3000, outputTokens: 800))
    }
}
