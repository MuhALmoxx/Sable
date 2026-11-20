import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
import SubtitleKit
@testable import TranslationKit

final class ClaudeProviderTests: XCTestCase {
    private func request() -> TranslationChunkRequest {
        TranslationChunkRequest(source: .english, target: TargetLanguages.arabic,
                                units: [TranslationUnit(id: "3", text: "Then let's go up to the roof."),
                                        TranslationUnit(id: "4", text: "<i>Is it safe?</i>")],
                                precedingContext: [.init(id: "2", source: "I can't sleep.", translation: "لا أستطيع النوم.")],
                                followingContext: [.init(id: "5", source: "Trust me.", translation: nil)],
                                glossary: [GlossaryEntry(source: "Mara", target: "مارا")])
    }

    private let okText = #"{"translations":[{"id":"3","text":"إذن لنصعد إلى السطح."},{"id":"4","text":"<i>هل هو آمن؟</i>"}],"names":[{"source":"Mara","target":"مارا"}]}"#

    func testRequestHeadersAndBodyShape() async throws {
        let http = FakeHTTPClient(json: messagesJSON(text: okText))
        let provider = ClaudeTranslationProvider(apiKey: "  sk-test-key \n", modelID: "claude-opus-5-5", httpClient: http)
        _ = try await provider.translate(request())
        let sent = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(sent.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(sent.httpMethod, "POST")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "x-api-key"), "sk-test-key")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "anthropic-version"), "2026-10-21")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "content-type"), "application/json")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "anthropic-beta"), "server-side-fallback-2026-07-01")
        XCTAssertEqual(sent.timeoutInterval, 180)

        let body = try jsonObject(sent.httpBody)
        XCTAssertEqual(body["model"] as? String, "claude-opus-5-5")
        XCTAssertEqual(body["max_tokens"] as? Int, 16000)
        XCTAssertEqual(body["fallbacks"] as? String, "default")
        for forbidden in ["temperature", "top_p", "top_k", "thinking", "stream"] {
            XCTAssertNil(body[forbidden], "\(forbidden) must not be sent")
        }
        let system = try XCTUnwrap(body["system"] as? [[String: Any]])
        let systemText = try XCTUnwrap(system.first?["text"] as? String)
        XCTAssertTrue(systemText.contains("from English into Arabic"))
        XCTAssertTrue(systemText.contains(TargetLanguages.arabic.promptGuidance))
        XCTAssertEqual((system.first?["cache_control"] as? [String: Any])?["type"] as? String, "ephemeral")

        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1, "no assistant prefill")
        XCTAssertEqual(messages[0]["role"] as? String, "user")
        let payload = try jsonObject(Data(try XCTUnwrap(messages[0]["content"] as? String).utf8))
        let units = try XCTUnwrap(payload["units"] as? [[String: Any]])
        XCTAssertEqual(units.map { $0["id"] as? String }, ["3", "4"])
        XCTAssertEqual(units[1]["text"] as? String, "<i>Is it safe?</i>")
        XCTAssertEqual((payload["preceding_context"] as? [[String: Any]])?.first?["translation"] as? String, "لا أستطيع النوم.")
        XCTAssertEqual((payload["following_context"] as? [[String: Any]])?.first?["id"] as? String, "5")
        XCTAssertEqual((payload["glossary"] as? [[String: Any]])?.first?["target"] as? String, "مارا")

        let output = try XCTUnwrap(body["output_config"] as? [String: Any])
        XCTAssertEqual(output["effort"] as? String, "medium")
        let format = try XCTUnwrap(output["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")
        let schema = try XCTUnwrap(format["schema"] as? [String: Any])
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
        XCTAssertEqual(schema["required"] as? [String], ["translations", "names"])
        let item = try XCTUnwrap(((schema["properties"] as? [String: Any])?["translations"] as? [String: Any])?["items"] as? [String: Any])
        XCTAssertEqual(item["required"] as? [String], ["id", "text"])
        XCTAssertEqual(item["additionalProperties"] as? Bool, false)
    }

    func testParsesTranslationsNamesAndUsage() async throws {
        let http = FakeHTTPClient(json: messagesJSON(text: okText))
        let response = try await ClaudeTranslationProvider(apiKey: "k", modelID: "claude-opus-5-5", httpClient: http).translate(request())
        XCTAssertEqual(response.translations, ["3": "إذن لنصعد إلى السطح.", "4": "<i>هل هو آمن؟</i>"])
        XCTAssertEqual(response.glossary, [GlossaryEntry(source: "Mara", target: "مارا")])
        XCTAssertEqual(response.usage, TokenUsage(inputTokens: 3000, outputTokens: 340))
        XCTAssertNil(response.servedByModel)
    }

    func testFallbackModelIsReported() async throws {
        let http = FakeHTTPClient(json: messagesJSON(text: okText, model: "claude-opus-5",
                                                     extraContent: #"{"type":"fallback","from":{"model":"claude-opus-5-5"},"to":{"model":"claude-opus-5"}},"#))
        let response = try await ClaudeTranslationProvider(apiKey: "k", modelID: "claude-opus-5-5", httpClient: http).translate(request())
        XCTAssertEqual(response.servedByModel, "claude-opus-5")
    }

    func testRefusalUsesExplanation() async throws {
        let json = #"{"model":"claude-opus-5-5","content":[],"stop_reason":"refusal","stop_details":{"type":"refusal","category":"cyber","explanation":"Declined."},"usage":{"input_tokens":10,"output_tokens":0}}"#
        let provider = ClaudeTranslationProvider(apiKey: "k", modelID: "claude-opus-5-5", httpClient: FakeHTTPClient(json: json))
        await assertThrows(.refused("Declined. (cyber)")) { _ = try await provider.translate(self.request()) }
    }

    func testMaxTokensIsMalformedSoTheEngineSplits() async throws {
        let provider = ClaudeTranslationProvider(apiKey: "k", modelID: "claude-opus-5-5",
                                                 httpClient: FakeHTTPClient(json: messagesJSON(text: #"{"translations":[{"id":"3","te"#, stopReason: "max_tokens")))
        do {
            _ = try await provider.translate(request())
            XCTFail("expected malformedResponse")
        } catch {
            guard case .malformedResponse? = error as? TranslationError else { return XCTFail("got \(error)") }
        }
    }

    func testInvalidJSONIsMalformed() async throws {
        let provider = ClaudeTranslationProvider(apiKey: "k", modelID: "claude-opus-5-5",
                                                 httpClient: FakeHTTPClient(json: messagesJSON(text: "Sorry, here you go: nope")))
        do {
            _ = try await provider.translate(request())
            XCTFail("expected malformedResponse")
        } catch {
            guard case .malformedResponse? = error as? TranslationError else { return XCTFail("got \(error)") }
        }
    }

    func testHTTPErrorMapping() async throws {
        let cases: [(Int, String, [String: String], TranslationError)] = [
            (401, #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#, [:], .invalidAPIKey),
            (403, #"{"type":"error","error":{"type":"permission_error","message":"nope"}}"#, [:], .invalidAPIKey),
            (429, #"{"type":"error","error":{"type":"rate_limit_error","message":"slow down"}}"#, ["Retry-After": "7"], .rateLimited(retryAfter: 7)),
            (429, #"{"type":"error","error":{"type":"rate_limit_error","message":"slow down"}}"#, [:], .rateLimited(retryAfter: nil)),
            (429, #"{"type":"error","error":{"type":"rate_limit_error","message":"cap","details":{"error_code":"enforced_spend_limit_reached"}}}"#, [:], .quotaExceeded),
            (400, #"{"type":"error","error":{"type":"invalid_request_error","message":"Your credit balance is too low to access the Anthropic API."}}"#, [:], .quotaExceeded),
            (400, #"{"type":"error","error":{"type":"invalid_request_error","message":"bad field"}}"#, [:], .server(status: 400, message: "bad field")),
            (402, #"{"type":"error","error":{"type":"billing_error","message":"pay"}}"#, [:], .quotaExceeded),
            (529, #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#, [:], .server(status: 529, message: "Overloaded")),
            (500, "not json", [:], .server(status: 500, message: HTTPURLResponse.localizedString(forStatusCode: 500))),
        ]
        for (status, json, headers, expected) in cases {
            let provider = ClaudeTranslationProvider(apiKey: "k", modelID: "claude-opus-5-5",
                                                     httpClient: FakeHTTPClient(status: status, json: json, headers: headers))
            await assertThrows(expected) { _ = try await provider.translate(self.request()) }
        }
    }

    func testMissingKeyFailsWithoutRequest() async throws {
        let http = FakeHTTPClient(json: "{}")
        await assertThrows(.missingAPIKey) {
            _ = try await ClaudeTranslationProvider(apiKey: "  ", modelID: "claude-opus-5-5", httpClient: http).translate(self.request())
        }
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testValidateUsesFreeModelsEndpoint() async throws {
        let ok = FakeHTTPClient(json: #"{"data":[{"id":"claude-opus-5-5"}]}"#)
        try await ClaudeTranslationProvider.validate(apiKey: "sk-valid", httpClient: ok)
        let sent = try XCTUnwrap(ok.requests.first)
        XCTAssertEqual(sent.httpMethod, "GET")
        XCTAssertEqual(sent.url?.path, "/v1/models")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "x-api-key"), "sk-valid")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "anthropic-version"), "2026-10-21")
        XCTAssertNil(sent.httpBody)

        let bad = FakeHTTPClient(status: 401, json: #"{"type":"error","error":{"type":"authentication_error","message":"invalid"}}"#)
        await assertThrows(.invalidAPIKey) { try await ClaudeTranslationProvider.validate(apiKey: "sk-bad", httpClient: bad) }
    }

    func testSystemPromptIsStableAcrossChunksForPromptCaching() throws {
        let provider = ClaudeTranslationProvider(apiKey: "k", modelID: "claude-opus-5-5", httpClient: FakeHTTPClient())
        var other = request()
        other.units = [TranslationUnit(id: "77", text: "Something else entirely.")]
        other.glossary = []
        func system(_ r: TranslationChunkRequest) throws -> String {
            let body = try jsonObject(provider.requestBody(for: r).data)
            return try XCTUnwrap((body["system"] as? [[String: Any]])?.first?["text"] as? String)
        }
        XCTAssertEqual(try system(request()), try system(other))
    }

    func testJSONValueEscaping() throws {
        let tricky = "Quote \" backslash \\ tab \t newline \n bell \u{07} sep \u{2028} عربي"
        let encoded = JSONValue.object([("k", .string(tricky)), ("n", .int(3)), ("b", .bool(false)), ("z", .null)]).serialized()
        XCTAssertEqual(encoded, #"{"k":"Quote \" backslash \\ tab \t newline \n bell \u0007 sep \u2028 عربي","n":3,"b":false,"z":null}"#)
        let decoded = try jsonObject(Data(encoded.utf8))
        XCTAssertEqual(decoded["k"] as? String, tricky)
        XCTAssertEqual(decoded["n"] as? Int, 3)
        XCTAssertEqual(decoded["b"] as? Bool, false)
    }

    func testModelOptions() {
        XCTAssertEqual(ClaudeModels.defaultModelID, "claude-opus-5-5")
        XCTAssertEqual(ClaudeModels.options.map(\.id), ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"])
        XCTAssertEqual(ClaudeModels.option(for: "claude-haiku-5-5")?.outputPricePerMTok, 0.5)
        XCTAssertEqual(ClaudeModels.option(for: "claude-opus-5-5")?.priceLabel, "$4 / $20 per MTok")
        XCTAssertEqual(ClaudeModels.option(for: "claude-haiku-5-5")?.priceLabel, "$0.10 / $0.50 per MTok")
        XCTAssertTrue(ClaudeTranslationProvider.descriptor.isPaid)
        XCTAssertTrue(ClaudeTranslationProvider.descriptor.usesContext)
    }

    func testEndToEndThroughEngineWithFakeHTTP() async throws {
        // Echo the requested ids back in Arabic so the engine maps a real HTTP round trip.
        final class EchoClient: TranslationHTTPClient, @unchecked Sendable {
            func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                let content = ((body["messages"] as! [[String: Any]])[0]["content"] as! String)
                let payload = try JSONSerialization.jsonObject(with: Data(content.utf8)) as! [String: Any]
                let ids = (payload["units"] as! [[String: Any]]).map { $0["id"] as! String }
                let items = ids.map { JSONValue.object([("id", .string($0)), ("text", .string("سطر \($0)?"))]) }
                let text = JSONValue.object([("translations", .array(items)), ("names", .array([]))]).serialized()
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (Data(messagesJSON(text: text).utf8), response)
            }
        }
        let provider = ClaudeTranslationProvider(apiKey: "k", modelID: "claude-opus-5-5", httpClient: EchoClient())
        let engine = TranslationEngine(storeDirectory: temporaryDirectory(), sleep: { _ in })
        let doc = makeDocument(count: 45)
        let spec = makeSpec(doc, chunkSize: 40, contextSize: 6, provider: ClaudeTranslationProvider.providerID, model: provider.modelID)
        let result = try await engine.run(spec, provider: provider, progress: { _ in })
        XCTAssertEqual(result.cues.map(\.id), doc.cues.map(\.id))
        XCTAssertEqual(result.cues[44].text, "سطر 45؟", "post-processing applied")
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
}
