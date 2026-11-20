import Foundation
import UniformTypeIdentifiers
import LibraryKit

// OWNER: library agent.

/// Where picked/opened files live and which content types the pickers offer.
enum ImportPaths {
    /// True for the private copies iOS hands the app: the document picker's `asCopy` copies
    /// (tmp/…-Inbox) and "Open in Sable" copies (Documents/Inbox). Those are moved into the
    /// library; anything else (e.g. a file in the person's own folders) is copied.
    static func isPrivateCopy(_ url: URL) -> Bool {
        let path = canonicalPath(url)
        let home = canonicalPath(URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true))
        let tmp = canonicalPath(FileManager.default.temporaryDirectory)
        let inbox = home + "/Documents/Inbox"
        return path.hasPrefix(tmp + "/") || path.hasPrefix(inbox + "/")
    }

    /// Deletes a private copy that will not be imported, so it does not linger in Files.
    static func discardInboxCopy(_ url: URL) {
        guard isPrivateCopy(url) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static func canonicalPath(_ url: URL) -> String {
        var path = url.resolvingSymlinksInPath().standardizedFileURL.path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// Whether the file looks like something AVFoundation or VLC can play.
    static func isImportableVideo(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        switch LibraryFileNaming.kind(ofFileExtension: ext) {
        case .video: return true
        case .subtitle: return false
        case .unknown:
            if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType,
               type.conforms(to: .audiovisualContent) {
                return true
            }
            if !ext.isEmpty, let type = UTType(filenameExtension: ext) {
                return type.conforms(to: .audiovisualContent)
            }
            return false
        }
    }

    /// Content types for the video picker: every movie/audiovisual type plus the containers
    /// iOS does not know natively (declared in Info.plist or resolved dynamically).
    static let videoTypes: [UTType] = {
        var types: [UTType] = [.movie, .video, .audiovisualContent, .mpeg4Movie, .quickTimeMovie, .avi,
                               .mpeg, .mpeg2Video]
        for ext in ["mkv", "webm", "avi", "ts", "m2ts", "mts", "flv", "wmv", "ogv", "3gp", "vob", "divx", "rmvb", "m4v"] {
            if let type = UTType(filenameExtension: ext) { types.append(type) }
        }
        return unique(types)
    }()

    /// Content types for the subtitle picker.
    static let subtitleTypes: [UTType] = {
        var types: [UTType] = []
        for ext in ["srt", "vtt", "ass", "ssa"] {
            if let type = UTType(filenameExtension: ext) { types.append(type) }
        }
        types.append(.plainText)
        return unique(types)
    }()

    private static func unique(_ types: [UTType]) -> [UTType] {
        var seen = Set<String>()
        return types.filter { seen.insert($0.identifier).inserted }
    }
}
