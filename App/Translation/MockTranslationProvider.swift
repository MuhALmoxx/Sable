#if DEBUG
import Foundation
import SubtitleKit
import TranslationKit

// OWNER: translation agent. DEBUG builds only; registered when UITestSupport.useMockTranslation.
//
// Deterministic offline provider for UI tests: English plain text -> the human-written Arabic in
// the bundled UITestFixtures/reference-translations.ar.json, falling back to "\u{200F}[ع] " + text.
// Chunk size 3 and a per-chunk delay (launch argument `-mockTranslationDelay <seconds>`, default
// 0.4) make progress, cancel and resume observable. `-mockTranslationPaid` marks it as paid so
// the confirmation step can be exercised without a real API key.
struct MockTranslationProvider: TranslationProvider {
    static let providerID = "mock-ui-tests"
    /// Loaded once (reads the bundled reference file).
    static let shared = MockTranslationProvider()
    let modelID = "mock-reference-v1"
    let delay: TimeInterval
    let isPaid: Bool
    private let reference: [String: String]

    init(arguments: [String] = ProcessInfo.processInfo.arguments, bundle: Bundle = .main) {
        delay = Self.argumentValue("-mockTranslationDelay", in: arguments).flatMap(Double.init) ?? 0.4
        isPaid = arguments.contains("-mockTranslationPaid")
        reference = Self.loadReference(bundle: bundle)
    }

    var descriptor: TranslationProviderDescriptor { Self.descriptor(isPaid: isPaid) }

    static func descriptor(isPaid: Bool) -> TranslationProviderDescriptor {
        TranslationProviderDescriptor(
            id: providerID, displayName: "Mock (UI tests)",
            summary: "Debug builds only. Deterministic offline translation from bundled reference lines.",
            isPaid: isPaid, requiresAPIKey: false, usesContext: false, recommendedChunkSize: 3)
    }

    func translate(_ request: TranslationChunkRequest) async throws -> TranslationChunkResponse {
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        try Task.checkCancellation()
        var out: [String: String] = [:]
        for unit in request.units {
            let plain = TextCleanup.stripInlineTags(unit.text)
            out[unit.id] = reference[plain] ?? "\u{200F}[ع] " + plain
        }
        let chars = request.units.reduce(0) { $0 + $1.text.count }
        return TranslationChunkResponse(translations: out, glossary: [],
                                        usage: TokenUsage(inputTokens: chars / 3 + 200, outputTokens: chars / 2))
    }

    static func argumentValue(_ name: String, in arguments: [String]) -> String? {
        guard let i = arguments.firstIndex(of: name), i + 1 < arguments.count else { return nil }
        return arguments[i + 1]
    }

    static func loadReference(bundle: Bundle) -> [String: String] {
        let url = bundle.url(forResource: "reference-translations.ar", withExtension: "json", subdirectory: "UITestFixtures")
            ?? bundle.url(forResource: "reference-translations.ar", withExtension: "json")
        guard let url, let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var map: [String: String] = [:]
        for (key, value) in object where !key.hasPrefix("_") {
            if let text = value as? String { map[key] = text }
        }
        return map
    }
}
#endif
