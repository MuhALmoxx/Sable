import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
import SubtitleKit
@testable import TranslationKit

/// Builds an English document with `count` cues ("Line N." texts) unless texts are given.
func makeDocument(_ texts: [String], title: String? = "Night Roof") -> SubtitleDocument {
    let cues = texts.enumerated().map { i, text in
        SubtitleCue(id: "\(i + 1)", index: i, start: Double(i) * 3 + 1, end: Double(i) * 3 + 2.5, text: text,
                    rawText: "raw \(i)", style: i % 4 == 0 ? CueStyleHint(alignment: 8, styleName: "Top", italic: true) : nil)
    }
    return SubtitleDocument(format: .ass, cues: cues, language: .english, title: title, header: "[Script Info]")
}

func makeDocument(count: Int) -> SubtitleDocument {
    makeDocument((1...count).map { "This is line number \($0), Mara." })
}

func makeSpec(_ doc: SubtitleDocument, chunkSize: Int = 4, contextSize: Int = 2, provider: String = "fake",
              model: String = "fake-1") -> TranslationJobSpec {
    TranslationJobSpec(source: doc, sourceTrackKey: "video|emb:mkv:3", sourceLanguage: .english, target: TargetLanguages.arabic,
                       providerID: provider, modelID: model, chunkSize: chunkSize, contextSize: contextSize)
}

func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("sable-tk-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Records every request and answers through a scripted closure (default: Arabic for every unit).
final class FakeProvider: TranslationProvider, @unchecked Sendable {
    typealias Script = @Sendable (_ call: Int, _ request: TranslationChunkRequest) async throws -> TranslationChunkResponse

    let descriptor: TranslationProviderDescriptor
    let modelID = "fake-1"
    private let lock = NSLock()
    private var _requests: [TranslationChunkRequest] = []
    private let script: Script

    init(usesContext: Bool = true, script: Script? = nil) {
        descriptor = TranslationProviderDescriptor(id: "fake", displayName: "Fake", summary: "test", isPaid: false,
                                                   requiresAPIKey: false, usesContext: usesContext, recommendedChunkSize: 4)
        self.script = script ?? { _, request in FakeProvider.arabic(for: request) }
    }

    var requests: [TranslationChunkRequest] { lock.lock(); defer { lock.unlock() }; return _requests }
    var callCount: Int { requests.count }
    var requestedIDs: [String] { requests.flatMap { $0.units.map(\.id) } }

    func translate(_ request: TranslationChunkRequest) async throws -> TranslationChunkResponse {
        let call: Int = { lock.lock(); defer { lock.unlock() }; _requests.append(request); return _requests.count }()
        return try await script(call, request)
    }

    static func arabic(for request: TranslationChunkRequest, dropping: Set<String> = [],
                       names: [GlossaryEntry] = [], usage: TokenUsage = TokenUsage(inputTokens: 100, outputTokens: 50)) -> TranslationChunkResponse {
        var out: [String: String] = [:]
        for unit in request.units where !dropping.contains(unit.id) { out[unit.id] = "سطر \(unit.id)" }
        return TranslationChunkResponse(translations: out, glossary: names, usage: usage)
    }
}

/// Thread-safe recorder for progress callbacks and sleeps.
final class Recorder<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _items: [T] = []
    func add(_ item: T) { lock.lock(); _items.append(item); lock.unlock() }
    var items: [T] { lock.lock(); defer { lock.unlock() }; return _items }
}

/// Fake transport for the Claude provider.
final class FakeHTTPClient: TranslationHTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    var status: Int
    var body: Data
    var headers: [String: String]

    init(status: Int = 200, body: Data = Data(), headers: [String: String] = [:]) {
        self.status = status; self.body = body; self.headers = headers
    }

    convenience init(status: Int = 200, json: String, headers: [String: String] = [:]) {
        self.init(status: status, body: Data(json.utf8), headers: headers)
    }

    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return _requests }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.lock(); _requests.append(request); lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        return (body, response)
    }
}

func jsonObject(_ data: Data?) throws -> [String: Any] {
    let data = try XCTUnwrap(data)
    return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

func messagesJSON(text: String, stopReason: String = "end_turn", model: String = "claude-opus-5-5",
                  extraContent: String = "") -> String {
    let escaped = JSONValue.string(text).serialized()
    return """
    {"id":"msg_1","type":"message","role":"assistant","model":"\(model)",
     "content":[{"type":"thinking","thinking":"","signature":"sig"},\(extraContent){"type":"text","text":\(escaped)}],
     "stop_reason":"\(stopReason)","stop_details":null,
     "usage":{"input_tokens":1200,"output_tokens":340,"cache_creation_input_tokens":0,"cache_read_input_tokens":1800}}
    """
}
