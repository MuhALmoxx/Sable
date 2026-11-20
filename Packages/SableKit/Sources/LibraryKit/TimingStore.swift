import Foundation
import SubtitleKit

// OWNER: sync agent.

/// Persists the `SubtitleTiming` per (video, timing group) plus an undo history.
/// Keys: "<videoUUID>|<SubtitleTrackDescriptor.timingGroupID>". Writes are atomic JSON.
/// Not thread-safe: use from the main actor.
///
/// File format (`timing.json`):
///
///     { "version": 1,
///       "entries": { "<key>": { "timing": {"offset": 1.3, "scale": 1},
///                               "undo": [ {"offset": 1.2, "scale": 1}, ... ] } } }
///
/// `undo` is oldest-first; the last element is what `undo(forKey:)` restores next.
/// Loading is tolerant: a missing file starts empty; an unreadable or corrupt file is moved
/// aside to `<file>.corrupt` (so nothing is silently lost) and the store starts empty.
public final class TimingStore {
    public let fileURL: URL

    /// Maximum number of undo steps kept per key (oldest are dropped first).
    public static let undoLimit = 50
    /// Current on-disk format version.
    public static let formatVersion = 1

    /// Description of the last load/save problem (nil when everything worked). For diagnostics
    /// only: the store keeps working in memory even when a write fails.
    public private(set) var lastError: String?
    /// True when the last load found a corrupt file and moved it to `corruptBackupURL`.
    public private(set) var recoveredFromCorruptFile = false

    /// Where a corrupt timing file is preserved.
    public var corruptBackupURL: URL { fileURL.appendingPathExtension("corrupt") }

    private var entries: [String: Entry] = [:]

    struct Entry: Codable, Equatable {
        var timing: SubtitleTiming
        var undo: [SubtitleTiming]
    }

    private struct FileModel: Codable {
        var version: Int
        var entries: [String: Entry]
    }

    public init(fileURL: URL) {
        self.fileURL = fileURL
        load()
    }

    public static func key(videoID: UUID, timingGroupID: String) -> String { "\(videoID.uuidString)|\(timingGroupID)" }

    // MARK: Reading

    public func timing(forKey key: String) -> SubtitleTiming {
        entries[key]?.timing ?? .identity
    }

    public func canUndo(forKey key: String) -> Bool {
        !(entries[key]?.undo.isEmpty ?? true)
    }

    /// Number of undo steps available for `key`.
    public func undoDepth(forKey key: String) -> Int {
        entries[key]?.undo.count ?? 0
    }

    /// Every stored key (sorted), mainly for diagnostics and tests.
    public var allKeys: [String] { entries.keys.sorted() }

    // MARK: Writing

    /// Sets a new timing. When `undoable`, pushes the previous value onto the key's undo stack
    /// (cap 50). Persists immediately. Setting the value that is already active is a no-op
    /// (nothing is pushed). Non-finite values and non-positive scales are rejected.
    public func setTiming(_ timing: SubtitleTiming, forKey key: String, undoable: Bool = true) {
        guard Self.isValid(timing) else {
            lastError = "Rejected invalid timing (offset \(timing.offset), scale \(timing.scale))."
            return
        }
        var timing = timing
        if timing.offset == 0 { timing.offset = 0 } // drop a negative zero so it never shows as "−0.000"
        var entry = entries[key] ?? Entry(timing: .identity, undo: [])
        guard !Self.same(entry.timing, timing) else { return }
        if undoable {
            entry.undo.append(entry.timing)
            if entry.undo.count > Self.undoLimit {
                entry.undo.removeFirst(entry.undo.count - Self.undoLimit)
            }
        }
        entry.timing = timing
        store(entry, forKey: key)
        save()
    }

    /// Restores the previous timing and returns it (nil if nothing to undo).
    @discardableResult
    public func undo(forKey key: String) -> SubtitleTiming? {
        guard var entry = entries[key], let previous = entry.undo.popLast() else { return nil }
        entry.timing = previous
        store(entry, forKey: key)
        save()
        return previous
    }

    /// Resets to identity (undoable).
    public func reset(forKey key: String) {
        setTiming(.identity, forKey: key, undoable: true)
    }

    /// Removes every key for a video (used when an item is deleted).
    public func removeAll(videoID: UUID) {
        let prefix = "\(videoID.uuidString)|"
        let doomed = entries.keys.filter { $0.hasPrefix(prefix) }
        guard !doomed.isEmpty else { return }
        for key in doomed { entries[key] = nil }
        save()
    }

    // MARK: Helpers

    /// Two timings are "the same" when they differ by less than half a millisecond of offset
    /// and a negligible amount of scale (so float noise never creates undo steps).
    static func same(_ a: SubtitleTiming, _ b: SubtitleTiming) -> Bool {
        abs(a.offset - b.offset) < 0.0005 && abs(a.scale - b.scale) < 1e-12
    }

    static func isValid(_ timing: SubtitleTiming) -> Bool {
        timing.offset.isFinite && timing.scale.isFinite && timing.scale > 0
    }

    /// Keeps the dictionary small: an identity timing with no history needs no entry.
    private func store(_ entry: Entry, forKey key: String) {
        if entry.undo.isEmpty && entry.timing == .identity {
            entries[key] = nil
        } else {
            entries[key] = entry
        }
    }

    // MARK: Persistence

    private func load() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else { return }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            lastError = "Could not read timing file: \(error.localizedDescription)"
            moveAsideCorruptFile()
            return
        }
        if data.isEmpty {
            // An empty file is what an interrupted non-atomic copy leaves; nothing to recover.
            return
        }
        do {
            let model = try JSONDecoder().decode(FileModel.self, from: data)
            var loaded: [String: Entry] = [:]
            for (key, var entry) in model.entries where Self.isValid(entry.timing) {
                entry.undo = Array(entry.undo.filter(Self.isValid).suffix(Self.undoLimit))
                loaded[key] = entry
            }
            entries = loaded
        } catch {
            lastError = "Timing file was unreadable and has been reset: \(error.localizedDescription)"
            moveAsideCorruptFile()
        }
    }

    private func moveAsideCorruptFile() {
        let fm = FileManager.default
        let backup = corruptBackupURL
        do {
            if fm.fileExists(atPath: backup.path) { try fm.removeItem(at: backup) }
            try fm.moveItem(at: fileURL, to: backup)
            recoveredFromCorruptFile = true
        } catch {
            lastError = "Timing file was unreadable and could not be backed up: \(error.localizedDescription)"
        }
        entries = [:]
    }

    private func save() {
        let model = FileModel(version: Self.formatVersion, entries: entries)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            let data = try encoder.encode(model)
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
            lastError = nil
        } catch {
            lastError = "Could not save subtitle timing: \(error.localizedDescription)"
        }
    }
}
