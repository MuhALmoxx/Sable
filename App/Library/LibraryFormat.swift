import Foundation
import LibraryKit

// OWNER: library agent.

/// Text shown in library rows (kept local so it does not depend on other modules' stubs).
enum LibraryFormat {
    /// "1:02:03" / "12:31" / "0:07".
    static func clock(_ seconds: TimeInterval) -> String {
        // Upper bound guards Int conversion against corrupt container durations.
        guard seconds.isFinite, seconds >= 0, seconds < 1e12 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    /// "12 minutes, 31 seconds" for VoiceOver.
    static func spokenDuration(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
        formatter.unitsStyle = .full
        formatter.zeroFormattingBehavior = .dropAll
        return formatter.string(from: max(0, seconds)) ?? clock(seconds)
    }

    /// "Played 2 days ago" / "Played just now".
    static func lastPlayed(_ date: Date, now: Date = Date()) -> String {
        if now.timeIntervalSince(date) < 60 { return "Played just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return "Played " + formatter.localizedString(for: date, relativeTo: now)
    }

    /// Container tag: "MKV", "MP4", …
    static func containerTag(_ item: MediaItem) -> String {
        let ext = item.fileExtension
        return ext.isEmpty ? "VIDEO" : ext.uppercased()
    }

    /// Position worth resuming from (not at the very start, not finished).
    static func resumePosition(_ item: MediaItem) -> TimeInterval? {
        guard !item.playback.completed, item.playback.position >= 5 else { return nil }
        if let duration = item.duration, duration > 0, item.playback.position >= duration - 5 { return nil }
        return item.playback.position
    }

    static func percentWatched(_ item: MediaItem) -> Int {
        Int((item.progressFraction * 100).rounded())
    }

    /// "Night Roof, 12 minutes, 31 seconds, 40 percent watched".
    static func accessibilityLabel(for item: MediaItem) -> String {
        var parts = [item.title]
        if let duration = item.duration, duration > 0 {
            parts.append(spokenDuration(duration))
        } else {
            parts.append("duration unknown")
        }
        parts.append("\(percentWatched(item)) percent watched")
        return parts.joined(separator: ", ")
    }

    /// True when the text contains Arabic letters (rendered with IBM Plex Sans Arabic, RTL).
    static func containsArabic(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x0600...0x06FF, 0x0750...0x077F, 0x08A0...0x08FF, 0xFB50...0xFDFF, 0xFE70...0xFEFF: return true
            default: return false
            }
        }
    }

    static func byteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
