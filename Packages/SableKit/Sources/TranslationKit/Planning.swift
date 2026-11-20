import Foundation
import SubtitleKit

// OWNER: translation agent.

// MARK: - Glossary

/// Names/terms fixed during a job. Merges case-insensitively; the first rendering of a name
/// wins (consistency beats late "improvements"); capped so prompts stay small.
public struct Glossary: Codable, Hashable, Sendable {
    public struct Entry: Codable, Hashable, Sendable {
        public var source: String
        public var target: String
        /// How many chunks reported this entry (used to evict the least useful entries).
        public var hits: Int
    }

    public static let defaultCapacity = 200
    public private(set) var entries: [Entry] = []
    public var capacity: Int

    public init(capacity: Int = Glossary.defaultCapacity, entries: [GlossaryEntry] = []) {
        self.capacity = capacity
        merge(entries)
    }

    public var asEntries: [GlossaryEntry] { entries.map { GlossaryEntry(source: $0.source, target: $0.target) } }
    public var count: Int { entries.count }

    static func key(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    public mutating func merge(_ newEntries: [GlossaryEntry]) {
        for raw in newEntries {
            let source = TextCleanup.tidyLines(TextCleanup.stripInlineTags(raw.source)).replacingOccurrences(of: "\n", with: " ")
            let target = TextCleanup.tidyLines(TextCleanup.removeBidiControls(TextCleanup.stripInlineTags(raw.target)))
                .replacingOccurrences(of: "\n", with: " ")
            guard !source.isEmpty, !target.isEmpty, source.count <= 60, target.count <= 60 else { continue }
            guard Self.key(source) != Self.key(target) else { continue }
            let k = Self.key(source)
            if let i = entries.firstIndex(where: { Self.key($0.source) == k }) {
                entries[i].hits += 1
            } else {
                entries.append(Entry(source: source, target: target, hits: 1))
            }
        }
        evictIfNeeded()
    }

    private mutating func evictIfNeeded() {
        while entries.count > max(0, capacity) {
            // Lowest hit count first; among equals the oldest goes.
            guard let victim = entries.indices.min(by: { entries[$0].hits < entries[$1].hits }) else { return }
            entries.remove(at: victim)
        }
    }

    /// Entries whose source term occurs (case/diacritic-insensitively) in `text`. Keeps each
    /// request's glossary relevant and small.
    public func relevant(to text: String, limit: Int = Glossary.defaultCapacity) -> [GlossaryEntry] {
        let haystack = Self.key(text)
        return entries
            .filter { haystack.contains(Self.key($0.source)) }
            .prefix(limit)
            .map { GlossaryEntry(source: $0.source, target: $0.target) }
    }
}

// MARK: - Planning

/// Cue-level view of a job: which cues need a provider, their prepared text, their order.
public struct TranslationPlan: Sendable {
    public struct Item: Sendable, Hashable {
        public var id: String
        public var position: Int
        public var text: String
        /// False for cues without words; those pass through untranslated.
        public var needsTranslation: Bool
    }

    public let items: [Item]
    public let chunkSize: Int
    public let contextSize: Int
    private let positionByID: [String: Int]

    public init(document: SubtitleDocument, chunkSize: Int, contextSize: Int) {
        var seen = Set<String>()
        var items: [Item] = []
        for (position, cue) in document.cues.enumerated() {
            // Ids must be unique for mapping; duplicate ids (malformed files) get a suffix.
            var id = cue.id
            if seen.contains(id) { id = "\(cue.id)#\(position)" }
            seen.insert(id)
            let text = TranslationText.unitText(for: cue)
            items.append(Item(id: id, position: position, text: text, needsTranslation: TranslationText.needsTranslation(text)))
        }
        self.items = items
        self.chunkSize = max(1, min(chunkSize, 200))
        self.contextSize = max(0, min(contextSize, 30))
        var map: [String: Int] = [:]
        for item in items { map[item.id] = item.position }
        self.positionByID = map
    }

    public var translatableItems: [Item] { items.filter(\.needsTranslation) }

    public func item(for id: String) -> Item? { positionByID[id].map { items[$0] } }

    /// Remaining translatable items (not yet in `completed`), in dialogue order, cut into chunks.
    public func remainingChunks(completed: [String: String]) -> [[Item]] {
        let remaining = translatableItems.filter { completed[$0.id] == nil }
        return stride(from: 0, to: remaining.count, by: chunkSize).map { Array(remaining[$0..<min($0 + chunkSize, remaining.count)]) }
    }

    /// Number of chunks a fresh job over this plan needs.
    public var plannedChunkCount: Int {
        let n = translatableItems.count
        return n == 0 ? 0 : (n + chunkSize - 1) / chunkSize
    }

    /// Builds the provider request for `units`: N translatable lines before the first unit
    /// (with their translations when known) and N after the last, never including the units.
    public func request(for units: [Item], completed: [String: String], glossary: Glossary,
                        source: LanguageCode, target: TargetLanguageProfile, includeContext: Bool) -> TranslationChunkRequest {
        let unitIDs = Set(units.map(\.id))
        var preceding: [TranslationChunkRequest.ContextLine] = []
        var following: [TranslationChunkRequest.ContextLine] = []
        if includeContext, contextSize > 0, let first = units.map(\.position).min(), let last = units.map(\.position).max() {
            var p = first - 1
            while p >= 0, preceding.count < contextSize {
                let item = items[p]
                if item.needsTranslation, !unitIDs.contains(item.id) {
                    preceding.insert(.init(id: item.id, source: item.text, translation: completed[item.id]), at: 0)
                }
                p -= 1
            }
            p = last + 1
            while p < items.count, following.count < contextSize {
                let item = items[p]
                if item.needsTranslation, !unitIDs.contains(item.id) {
                    following.append(.init(id: item.id, source: item.text, translation: nil))
                }
                p += 1
            }
        }
        let unitList = units.sorted { $0.position < $1.position }.map { TranslationUnit(id: $0.id, text: $0.text) }
        var glossaryEntries: [GlossaryEntry] = []
        if includeContext {
            let allText = (unitList.map(\.text) + preceding.map(\.source) + following.map(\.source)).joined(separator: "\n")
            glossaryEntries = glossary.relevant(to: allText)
        }
        return TranslationChunkRequest(source: source, target: target, units: unitList, precedingContext: preceding,
                                       followingContext: following, glossary: glossaryEntries)
    }
}

// MARK: - Validation

public struct ChunkValidation: Sendable, Equatable {
    /// id -> post-processed translation, for every unit that came back usable.
    public var accepted: [String: String]
    /// Requested ids that are missing, empty or unusable, in dialogue order.
    public var missing: [String]
    /// Ids in the response that were not requested (ignored).
    public var unexpected: [String]
}

public enum ChunkValidator {
    /// Checks a response against the requested units: exact id set, non-empty text for each
    /// unit, and (for scripts with their own alphabet) that a wordy line was actually
    /// translated rather than echoed back in Latin script.
    public static func validate(_ response: TranslationChunkResponse, units: [TranslationUnit],
                                target: TargetLanguageProfile) -> ChunkValidation {
        let requested = Set(units.map(\.id))
        var accepted: [String: String] = [:]
        var missing: [String] = []
        for unit in units {
            guard let raw = response.translations[unit.id] else { missing.append(unit.id); continue }
            let processed = TranslationPostProcessor.process(raw, source: unit.text, target: target)
            guard !TextCleanup.stripInlineTags(processed).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                missing.append(unit.id); continue
            }
            if target.code.primary == "ar", TextCleanup.latinWordCount(unit.text) >= 2, !TextCleanup.containsArabicLetter(processed) {
                missing.append(unit.id); continue
            }
            accepted[unit.id] = processed
        }
        let unexpected = response.translations.keys.filter { !requested.contains($0) }.sorted()
        return ChunkValidation(accepted: accepted, missing: missing, unexpected: unexpected)
    }
}
