import Foundation
import UIKit
import QuartzCore
import AVFoundation
import os
import SubtitleKit
import LibraryKit

// OWNER: playback agent. Small shared helpers used by the engines, the session and the player UI.

let playbackLog = Logger(subsystem: "com.murisixz.sable", category: "playback")

/// A problem worth showing to the user as-is.
struct PlayerError: LocalizedError, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Readable text for any error (LocalizedError first, then NSError).
func readableMessage(for error: Error) -> String {
    if let localized = error as? LocalizedError, let text = localized.errorDescription, !text.isEmpty {
        return text
    }
    return (error as NSError).localizedDescription
}

extension Double {
    /// `self` when finite, else 0 (CMTime.seconds is NaN for indefinite times).
    var finiteOrZero: Double { isFinite ? self : 0 }
}

// MARK: - Container sniffing

enum ContainerSniffer {
    /// Matroska/WebM by EBML magic (1A 45 DF A3), MP4/MOV by an "ftyp" box at offset 4,
    /// otherwise by file extension.
    static func sniff(header: Data, fileExtension: String) -> ContainerKind {
        let bytes = [UInt8](header.prefix(16))
        let ext = fileExtension.lowercased()
        if bytes.count >= 4, bytes[0] == 0x1A, bytes[1] == 0x45, bytes[2] == 0xDF, bytes[3] == 0xA3 {
            return .matroska
        }
        if bytes.count >= 8, let tag = String(bytes: bytes[4..<8], encoding: .ascii) {
            if tag == "ftyp" { return .mp4 }
            // Old QuickTime files can start with other top-level atoms; trust them only when the
            // extension agrees.
            if ["moov", "mdat", "wide", "free", "skip", "pnot"].contains(tag), mp4Extensions.contains(ext) {
                return .mp4
            }
        }
        if matroskaExtensions.contains(ext) { return .matroska }
        if mp4Extensions.contains(ext) && bytes.count < 8 { return .mp4 }
        return .other
    }

    static let matroskaExtensions: Set<String> = ["mkv", "mka", "mks", "mk3d", "webm"]
    static let mp4Extensions: Set<String> = ["mp4", "m4v", "mov", "qt", "3gp", "3g2"]

    static func sniff(url: URL) -> ContainerKind {
        var header = Data()
        if let handle = try? FileHandle(forReadingFrom: url) {
            header = (try? handle.read(upToCount: 16)) ?? Data()
            try? handle.close()
        }
        return sniff(header: header, fileExtension: url.pathExtension)
    }
}

// MARK: - Text direction

enum TextDirection {
    /// True when the text contains Hebrew/Arabic-script characters.
    static func containsRightToLeft(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF:
                return true
            default:
                continue
            }
        }
        return false
    }
}

// MARK: - Video geometry

enum VideoGeometry {
    /// Forced display ratio for the fixed-ratio modes.
    static func forcedRatio(for mode: AspectMode) -> CGFloat? {
        switch mode {
        case .ratio16x9: return 16.0 / 9.0
        case .ratio4x3: return 4.0 / 3.0
        case .ratio21x9: return 21.0 / 9.0
        case .fit, .fill, .stretch: return nil
        }
    }

    /// Largest rect with `ratio` (width / height) centred inside `bounds`.
    static func fit(ratio: CGFloat, in bounds: CGRect) -> CGRect {
        guard ratio > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        var size = CGSize(width: bounds.width, height: bounds.width / ratio)
        if size.height > bounds.height { size = CGSize(width: bounds.height * ratio, height: bounds.height) }
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    /// Smallest rect with `ratio` centred on `bounds` that covers it (extends past `bounds`).
    static func fill(ratio: CGFloat, in bounds: CGRect) -> CGRect {
        guard ratio > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        var size = CGSize(width: bounds.width, height: bounds.width / ratio)
        if size.height < bounds.height { size = CGSize(width: bounds.height * ratio, height: bounds.height) }
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    /// Frame of the AVPlayerLayer inside its host view: fixed ratios size the layer (and the
    /// layer then stretches the picture into it); other modes fill the view and use gravity.
    static func layerFrame(mode: AspectMode, in bounds: CGRect) -> CGRect {
        if let ratio = forcedRatio(for: mode) { return fit(ratio: ratio, in: bounds) }
        return bounds
    }

    /// Where the picture is drawn inside `bounds` (may extend past `bounds` for `.fill`).
    static func pictureRect(videoSize: CGSize?, mode: AspectMode, in bounds: CGRect) -> CGRect {
        if let ratio = forcedRatio(for: mode) { return fit(ratio: ratio, in: bounds) }
        guard let videoSize, videoSize.width > 0, videoSize.height > 0 else { return bounds }
        let ratio = videoSize.width / videoSize.height
        switch mode {
        case .fit: return fit(ratio: ratio, in: bounds)
        case .fill: return fill(ratio: ratio, in: bounds)
        default: return bounds
        }
    }
}

// MARK: - Audio session

enum PlaybackAudioSession {
    /// Movie playback category; activated right before playback starts.
    static func activate() {
        let session = AVAudioSession.sharedInstance()
        do {
            if session.category != .playback || session.mode != .moviePlayback {
                try session.setCategory(.playback, mode: .moviePlayback, options: [])
            }
            try session.setActive(true)
        } catch {
            playbackLog.error("Audio session activation failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - KVO

enum KVO {
    /// Observes `keyPath` and runs `handler` on the main actor for each change. Built outside any
    /// actor so the change closure is never treated as main-actor isolated (KVO can fire on any
    /// thread).
    static func observe<Root: NSObject, Value>(_ object: Root, _ keyPath: KeyPath<Root, Value>,
                                                handler: @escaping @MainActor @Sendable () -> Void) -> NSKeyValueObservation {
        object.observe(keyPath, options: [.new]) { _, _ in
            Task { @MainActor in handler() }
        }
    }
}

// MARK: - Display link

/// CADisplayLink wrapper (CADisplayLink needs an Objective-C target). Owned by the session;
/// call `invalidate()` to break the link's retain on this object.
@MainActor
final class DisplayLinkDriver: NSObject {
    private var link: CADisplayLink?
    private let handler: () -> Void

    init(framesPerSecond: Float = 30, handler: @escaping () -> Void) {
        self.handler = handler
        super.init()
        let link = CADisplayLink(target: self, selector: #selector(step))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: framesPerSecond, preferred: framesPerSecond)
        link.isPaused = true
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    var isPaused: Bool {
        get { link?.isPaused ?? true }
        set { link?.isPaused = newValue }
    }

    @objc private func step() { handler() }

    func invalidate() {
        link?.invalidate()
        link = nil
    }
}

// MARK: - C strings handed to libVLC

/// Keeps a strdup'ed C string alive until it is replaced or this holder is released.
final class CStringHolder {
    private var pointer: UnsafeMutablePointer<CChar>?

    /// Passes a fresh copy of `value` (or nil) to `apply`, then frees the previous copy.
    func assign(_ value: String?, apply: (UnsafeMutablePointer<CChar>?) -> Void) {
        let fresh: UnsafeMutablePointer<CChar>? = value.flatMap { strdup($0) }
        apply(fresh)
        if let old = pointer { free(old) }
        pointer = fresh
    }

    deinit {
        if let pointer { free(pointer) }
    }
}

// MARK: - Four character codes

enum FourCC {
    static func code(_ string: String) -> FourCharCode {
        string.utf8.prefix(4).reduce(0) { ($0 << 8) | FourCharCode($1) }
    }

    static func string(_ code: FourCharCode) -> String {
        let bytes = [UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF), UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF)]
        let text = String(bytes: bytes, encoding: .ascii) ?? ""
        return text.trimmingCharacters(in: .controlCharacters)
    }
}
