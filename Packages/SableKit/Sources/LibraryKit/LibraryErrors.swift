import Foundation

// OWNER: library agent.

/// Errors thrown by `LibraryStore`. Messages are written for the person using the app.
public enum LibraryError: Error, Equatable, Sendable, LocalizedError {
    /// The picked file is not something Sable can import (folder, subtitle passed as video, …).
    case unsupportedFileType(String)
    /// The subtitle file's type is not SRT/WebVTT/ASS/SSA.
    case unsupportedSubtitleType(String)
    /// The subtitle file was read but could not be parsed.
    case invalidSubtitle(String)
    /// The source file no longer exists or cannot be opened.
    case fileNotFound(String)
    /// Copying or moving the file into the library failed.
    case copyFailed(String)
    /// The device has no room left for the file.
    case outOfSpace
    /// No library item with that id.
    case itemNotFound
    /// Reading or writing the library's own files failed.
    case io(String)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedFileType(name):
            return "\(name) is not a video Sable can import."
        case let .unsupportedSubtitleType(name):
            return "\(name) is not a subtitle file. Sable reads SRT, WebVTT, ASS and SSA."
        case let .invalidSubtitle(reason):
            return "The subtitle file could not be read: \(reason)"
        case let .fileNotFound(name):
            return "\(name) could not be found. It may have been moved or is still downloading."
        case let .copyFailed(reason):
            return "The file could not be copied into the library: \(reason)"
        case .outOfSpace:
            return "There is not enough free space on this iPhone. Free up some storage and try again."
        case .itemNotFound:
            return "That video is no longer in the library."
        case let .io(reason):
            return "The library could not be saved: \(reason)"
        }
    }

    /// Whether `error` (or an underlying error) means the volume is full.
    public static func isOutOfSpace(_ error: Error) -> Bool {
        if let libraryError = error as? LibraryError { return libraryError == .outOfSpace }
        var current: NSError? = error as NSError
        var depth = 0
        while let ns = current, depth < 6 {
            if ns.domain == NSCocoaErrorDomain && ns.code == CocoaError.fileWriteOutOfSpace.rawValue { return true }
            if ns.domain == NSPOSIXErrorDomain && (ns.code == Int(ENOSPC) || ns.code == Int(EDQUOT)) { return true }
            current = ns.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return false
    }
}

/// Why the library started in a recovered state. Shown once as a banner.
public enum LibraryLoadIssue: Equatable, Sendable {
    /// library.json could not be decoded; it was moved aside and the library started empty
    /// (video files still in Media/ were re-adopted as new items).
    case corruptFileReplaced(backupFileName: String)
    /// Some items could not be decoded and were dropped; a copy of the original file was kept.
    case itemsDropped(count: Int, backupFileName: String)

    public var backupFileName: String {
        switch self {
        case let .corruptFileReplaced(name): return name
        case let .itemsDropped(_, name): return name
        }
    }

    public var message: String {
        switch self {
        case .corruptFileReplaced:
            return "Your library file was damaged, so Sable started a fresh one. Your videos were kept; playback positions were reset."
        case let .itemsDropped(count, _):
            return count == 1
                ? "One library entry was damaged and has been removed. The rest of your library is intact."
                : "\(count) library entries were damaged and have been removed. The rest of your library is intact."
        }
    }
}
