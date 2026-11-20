import Foundation
import SubtitleKit

// OWNER: sync agent.

/// Persists the `SubtitleTiming` per (video, timing group) plus an undo history.
/// Keys: "<videoUUID>|<SubtitleTrackDescriptor.timingGroupID>". Writes are atomic JSON.
/// Not thread-safe: use from the main actor.
public final class TimingStore {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public static func key(videoID: UUID, timingGroupID: String) -> String { "\(videoID.uuidString)|\(timingGroupID)" }

    public func timing(forKey key: String) -> SubtitleTiming { .identity }

    /// Sets a new timing. When `undoable`, pushes the previous value onto the key's undo stack
    /// (cap 50). Persists immediately.
    public func setTiming(_ timing: SubtitleTiming, forKey key: String, undoable: Bool = true) {}

    public func canUndo(forKey key: String) -> Bool { false }

    /// Restores the previous timing and returns it (nil if nothing to undo).
    @discardableResult
    public func undo(forKey key: String) -> SubtitleTiming? { nil }

    /// Resets to identity (undoable).
    public func reset(forKey key: String) {}

    /// Removes every key for a video (used when an item is deleted).
    public func removeAll(videoID: UUID) {}
}
