import Foundation
import SubtitleKit

// OWNER: translation agent.

/// Prompt text and reply parsing shared by the LLM providers (Claude, ChatGPT plan). The text is
/// the same for every chunk of a job (prompt caching), so edit it deliberately: it changes what
/// every provider sends.
///
/// Prompt design: a stable system prompt (cacheable) with the translator brief and the
/// target-language guide, and a per-request JSON payload with the lines, read-only context
/// and the glossary. Output is constrained to a JSON schema (structured outputs).
enum SubtitlePrompt {
    static func system(source: LanguageCode, target: TargetLanguageProfile) -> String {
        let sourceName = source.displayName
        return """
        You are an expert subtitle translator. You translate film and TV subtitles from \(sourceName) \
        into \(target.englishName) for viewers who read them on screen while the video plays.

        INPUT
        The user message is one JSON object:
        - "units": the subtitle lines to translate, in dialogue order. Each has an "id" and the \
        "text" of one on-screen subtitle ("\\n" separates its two lines).
        - "preceding_context": the lines shown just before the units, with their "translation" \
        when one already exists. Read-only.
        - "following_context": the lines shown just after the units. Read-only.
        - "glossary": names and recurring terms already fixed earlier in this video. Whenever a \
        glossary "source" appears, use its "target" exactly.
        Use the context to understand who is speaking to whom, gender and number, tone, and \
        sentences that continue across lines. Never translate or return context lines. Units \
        may skip lines that are already translated; treat the ids as given.

        OUTPUT
        - "translations": exactly one entry for every unit id, with the same ids, in the same \
        order. Never merge, split, drop or invent ids. The text of each entry is only the \
        \(target.englishName) subtitle for that id.
        - "names": every person name, place, organisation, nickname or invented term that \
        appears in the units, with the \(target.englishName) rendering you used (reuse the \
        glossary rendering when one exists). Use an empty list when there are none.

        GENERAL RULES
        - Translate meaning, intent and tone the way a professional subtitler would, not \
        word for word. Keep it short enough to read in the time a subtitle is on screen.
        - Keep each unit's content in its own id. Keep speaker dashes at line starts.
        - Keep <i>…</i> and <b>…</b> tags around the corresponding words.
        - Translate sound and music descriptions and keep their brackets.
        - Lines that are only a name, an interjection or a number are still rendered in the \
        target language and script.
        - Never add notes, explanations, alternatives, quotation marks around whole lines, or \
        the source text.

        \(target.englishName.uppercased()) STYLE GUIDE
        \(target.promptGuidance)
        """
    }

    static func userPayload(for request: TranslationChunkRequest) -> JSONValue {
        var pairs: [(String, JSONValue)] = [
            ("source_language", .string("\(request.source.displayName) (\(request.source.rawValue))")),
            ("target_language", .string("\(request.target.englishName) (\(request.target.code.rawValue))")),
        ]
        pairs.append(("glossary", .array(request.glossary.map { .object([("source", .string($0.source)), ("target", .string($0.target))]) })))
        pairs.append(("preceding_context", .array(request.precedingContext.map { line in
            var fields: [(String, JSONValue)] = [("id", .string(line.id)), ("source", .string(line.source))]
            if let t = line.translation { fields.append(("translation", .string(t))) }
            return .object(fields)
        })))
        pairs.append(("units", .array(request.units.map { .object([("id", .string($0.id)), ("text", .string($0.text))]) })))
        pairs.append(("following_context", .array(request.followingContext.map {
            .object([("id", .string($0.id)), ("source", .string($0.source))])
        })))
        return .object(pairs)
    }

    /// JSON schema for structured outputs: { translations: [{id, text}], names: [{source, target}] }.
    static let outputSchema: JSONValue = .object([
        ("type", .string("object")),
        ("properties", .object([
            ("translations", .object([
                ("type", .string("array")),
                ("items", .object([
                    ("type", .string("object")),
                    ("properties", .object([
                        ("id", .object([("type", .string("string"))])),
                        ("text", .object([("type", .string("string"))])),
                    ])),
                    ("required", .array([.string("id"), .string("text")])),
                    ("additionalProperties", .bool(false)),
                ])),
            ])),
            ("names", .object([
                ("type", .string("array")),
                ("items", .object([
                    ("type", .string("object")),
                    ("properties", .object([
                        ("source", .object([("type", .string("string"))])),
                        ("target", .object([("type", .string("string"))])),
                    ])),
                    ("required", .array([.string("source"), .string("target")])),
                    ("additionalProperties", .bool(false)),
                ])),
            ])),
        ])),
        ("required", .array([.string("translations"), .string("names")])),
        ("additionalProperties", .bool(false)),
    ])

    /// Reply format spelled out in words, for requests that cannot carry the JSON schema.
    static let jsonReplyInstruction = """
    REPLY FORMAT
    Reply with exactly one JSON object and nothing else: no code fences, no commentary. Its shape \
    is {"translations":[{"id":"<unit id>","text":"<translation>"}],"names":[{"source":"<name>",\
    "target":"<rendering>"}]}. Use an empty "names" list when there are none.
    """

    // MARK: Reply

    struct Payload: Decodable {
        struct Item: Decodable {
            var id: String
            var text: String
            enum CodingKeys: String, CodingKey { case id, text }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                if let s = try? c.decode(String.self, forKey: .id) {
                    id = s
                } else {
                    id = String(try c.decode(Int.self, forKey: .id))
                }
                text = try c.decode(String.self, forKey: .text)
            }
        }
        struct Name: Decodable {
            var source: String
            var target: String
        }
        var translations: [Item]
        var names: [Name]?
    }

    /// Decodes the reply text, tolerating stray prose or code fences around the object.
    static func decodePayload(_ text: String) throws -> Payload {
        let decoder = JSONDecoder()
        if let payload = try? decoder.decode(Payload.self, from: Data(text.utf8)) { return payload }
        // Be lenient with stray prose or code fences around the object.
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
           let payload = try? decoder.decode(Payload.self, from: Data(text[start...end].utf8)) {
            return payload
        }
        throw TranslationError.malformedResponse("The reply did not match the translation format.")
    }

    /// Translations keyed by unit id (the first entry for an id wins) and the reported names.
    static func translations(from payload: Payload) -> (translations: [String: String], glossary: [GlossaryEntry]) {
        var translations: [String: String] = [:]
        for item in payload.translations where translations[item.id] == nil {
            translations[item.id] = item.text
        }
        let glossary = (payload.names ?? []).map { GlossaryEntry(source: $0.source, target: $0.target) }
        return (translations, glossary)
    }
}
