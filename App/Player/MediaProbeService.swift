import Foundation
import CoreGraphics
import CoreMedia
import QuartzCore
import AVFoundation
import MobileVLCKit
import SubtitleKit

// OWNER: playback agent.

struct MediaProbeResult: Sendable {
    var duration: TimeInterval?
    var container: ContainerKind
    var preferredEngine: PlaybackEngineKind
    var videoSize: CGSize?
    var subtitleTracks: [SubtitleTrackDescriptor]
    /// Human-readable problem (unsupported/inaccessible) or nil.
    var issue: String?
    /// Embedded subtitle tracks Sable can't use (e.g. CEA-608 closed captions), as display labels.
    var unsupportedSubtitleTracks: [String] = []
}

@MainActor
final class MediaProbeService {
    init() {}

    /// Container sniffing, AVFoundation playability, duration and embedded subtitle tracks
    /// (Matroska via SubtitleKit.MatroskaReader, MP4 text tracks via AVFoundation).
    /// `preferredEngine` is .avFoundation for files AVFoundation can play; the player applies the
    /// "use VLC for everything" setting on top of this.
    func probe(url: URL) async -> MediaProbeResult {
        let inspection = await Task.detached(priority: .userInitiated) { Self.inspectFile(url) }.value
        let container: ContainerKind
        switch inspection {
        case let .failure(error):
            return MediaProbeResult(duration: nil, container: .other, preferredEngine: .vlc, videoSize: nil,
                                    subtitleTracks: [], issue: error.message)
        case let .success(kind):
            container = kind
        }

        var result = MediaProbeResult(duration: nil, container: container, preferredEngine: .vlc, videoSize: nil,
                                      subtitleTracks: [], issue: nil)
        switch container {
        case .mp4:
            result = await probeWithAVFoundation(url: url, base: result)
        case .matroska:
            result = await probeMatroska(url: url, base: result)
        case .other:
            // Unknown containers (AVI, TS, FLV, OGG, WMV…) go to VLC.
            let parsed = await parseWithVLC(url: url)
            result.duration = parsed.duration
            result.videoSize = parsed.videoSize
            // A failed parse isn't fatal: VLC still gets to try, and reports its own error.
            if parsed.status == .done && parsed.hasVideo == false && parsed.hasAudio == true {
                result.issue = "This file has no video track."
            }
        }
        return result
    }

    // MARK: File checks

    nonisolated static func inspectFile(_ url: URL) -> Result<ContainerKind, PlayerError> {
        let path = url.path
        let manager = FileManager.default
        guard manager.fileExists(atPath: path) else {
            return .failure(PlayerError("The video file is missing. It may have been removed outside Sable."))
        }
        let size = (try? manager.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? -1
        if size == 0 {
            return .failure(PlayerError("This file is empty (0 bytes), so there's nothing to play."))
        }
        guard manager.isReadableFile(atPath: path), let handle = try? FileHandle(forReadingFrom: url) else {
            return .failure(PlayerError("The video file can't be read. Check that it's fully downloaded and not locked."))
        }
        let header = (try? handle.read(upToCount: 16)) ?? Data()
        try? handle.close()
        if header.isEmpty {
            return .failure(PlayerError("The video file can't be read. Check that it's fully downloaded and not locked."))
        }
        return .success(ContainerSniffer.sniff(header: header, fileExtension: url.pathExtension))
    }

    // MARK: MP4 / MOV

    private func probeWithAVFoundation(url: URL, base: MediaProbeResult) async -> MediaProbeResult {
        var result = base
        let asset = AVURLAsset(url: url)
        do {
            let (isPlayable, duration, isProtected) = try await asset.load(.isPlayable, .duration, .hasProtectedContent)
            if isProtected {
                result.issue = "This video is protected by DRM (FairPlay) and can't be played by Sable."
                return result
            }
            let seconds = duration.seconds.finiteOrZero
            if seconds > 0 { result.duration = seconds }
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            guard let videoTrack = videoTracks.first else {
                result.issue = "This file has no video track."
                return result
            }
            let (naturalSize, transform) = try await videoTrack.load(.naturalSize, .preferredTransform)
            let rect = CGRect(origin: .zero, size: naturalSize).applying(transform)
            if abs(rect.width) > 0, abs(rect.height) > 0 {
                result.videoSize = CGSize(width: abs(rect.width), height: abs(rect.height))
            }
            result.preferredEngine = isPlayable ? .avFoundation : .vlc
            let subtitles = await Self.mp4SubtitleTracks(asset)
            result.subtitleTracks = subtitles.tracks
            result.unsupportedSubtitleTracks = subtitles.unsupported
        } catch {
            // AVFoundation can't even read the container: let VLC try.
            playbackLog.info("AVFoundation probe failed, falling back to VLC: \(error.localizedDescription, privacy: .public)")
            result.preferredEngine = .vlc
            let parsed = await parseWithVLC(url: url)
            result.duration = result.duration ?? parsed.duration
            result.videoSize = result.videoSize ?? parsed.videoSize
        }
        return result
    }

    private static let tx3g = FourCC.code("tx3g")
    private static let quickTimeText = FourCC.code("text")
    private static let webVTT = FourCC.code("wvtt")
    private static let cea608 = FourCC.code("c608")
    private static let cea708 = FourCC.code("c708")

    private static func mp4SubtitleTracks(_ asset: AVURLAsset) async -> (tracks: [SubtitleTrackDescriptor], unsupported: [String]) {
        var assetTracks: [AVAssetTrack] = []
        for mediaType in [AVMediaType.text, .subtitle, .closedCaption] {
            let found = (try? await asset.loadTracks(withMediaType: mediaType)) ?? []
            for track in found where !assetTracks.contains(where: { $0.trackID == track.trackID }) {
                assetTracks.append(track)
            }
        }
        assetTracks.sort { $0.trackID < $1.trackID }

        var tracks: [SubtitleTrackDescriptor] = []
        var unsupported: [String] = []
        for (position, track) in assetTracks.enumerated() {
            let descriptions = (try? await track.load(.formatDescriptions)) ?? []
            let subtype = descriptions.first.map { CMFormatDescriptionGetMediaSubType($0) } ?? 0
            let extendedTag = (try? await track.load(.extendedLanguageTag)) ?? nil
            let languageCode = (try? await track.load(.languageCode)) ?? nil
            let language = LanguageCode.normalized(extendedTag ?? languageCode)
            let characteristics = (try? await track.load(.mediaCharacteristics)) ?? []
            let isEnabled = (try? await track.load(.isEnabled)) ?? false
            let metadata = (try? await track.load(.commonMetadata)) ?? []
            let title = await trackTitle(metadata) ?? fallbackTitle(ordinal: position + 1, language: language)
            let codec = FourCC.string(subtype)

            let format: SubtitleFormat
            switch subtype {
            case tx3g, quickTimeText:
                format = .tx3g
            case webVTT:
                format = .webvtt
            case cea608:
                unsupported.append("\(title) · CEA-608 closed captions (not supported)")
                continue
            case cea708:
                unsupported.append("\(title) · CEA-708 closed captions (not supported)")
                continue
            default:
                unsupported.append("\(title) · \(codec.isEmpty ? "unknown" : codec) subtitles (not supported)")
                continue
            }
            let streamID = Int(track.trackID)
            tracks.append(SubtitleTrackDescriptor(
                id: SubtitleTrackDescriptor.embeddedID(container: .mp4, streamID: streamID),
                title: title,
                language: language,
                format: format,
                kind: .text,
                origin: .embedded(container: .mp4, streamID: streamID, codecID: codec),
                isDefault: isEnabled,
                isForced: characteristics.contains(.containsOnlyForcedSubtitles)))
        }
        return (tracks, unsupported)
    }

    private static func trackTitle(_ metadata: [AVMetadataItem]) async -> String? {
        let items = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierTitle)
        guard let first = items.first else { return nil }
        let value = try? await first.load(.stringValue)
        guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return value
    }

    nonisolated static func fallbackTitle(ordinal: Int, language: LanguageCode?) -> String {
        if let language { return "Track \(ordinal) · \(language.primary.uppercased())" }
        return "Track \(ordinal)"
    }

    // MARK: Matroska / WebM

    private func probeMatroska(url: URL, base: MediaProbeResult) async -> MediaProbeResult {
        var result = base
        result.preferredEngine = .vlc
        let read = await Task.detached(priority: .userInitiated) { () -> Result<[MatroskaTrackInfo], Error> in
            do {
                let reader = try MatroskaReader(url: url)
                return .success(try reader.readTracks())
            } catch {
                return .failure(error)
            }
        }.value

        var hasVideo: Bool?
        switch read {
        case let .success(infos):
            result.subtitleTracks = Self.matroskaSubtitleTracks(infos)
            hasVideo = infos.isEmpty ? nil : infos.contains { $0.type == .video }
        case let .failure(error):
            // Embedded subtitles just won't be listed; playback still goes through VLC.
            playbackLog.error("Matroska track listing failed: \(error.localizedDescription, privacy: .public)")
        }

        let parsed = await parseWithVLC(url: url)
        result.duration = parsed.duration
        result.videoSize = parsed.videoSize
        if hasVideo == false || (hasVideo == nil && parsed.status == .done && parsed.hasVideo == false && parsed.hasAudio == true) {
            result.issue = "This file has no video track."
        }
        return result
    }

    nonisolated static func matroskaSubtitleTracks(_ infos: [MatroskaTrackInfo]) -> [SubtitleTrackDescriptor] {
        let subtitles = infos.filter { $0.type == .subtitle }.sorted { $0.number < $1.number }
        return subtitles.enumerated().map { position, info in
            let kind = MatroskaCodec.subtitleKind(forCodecID: info.codecID) ?? fallbackKind(forCodecID: info.codecID)
            var format = MatroskaCodec.subtitleFormat(forCodecID: info.codecID)
            if format == .unknown { format = fallbackFormat(forCodecID: info.codecID) }
            let name = info.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = (name?.isEmpty == false ? name : nil) ?? fallbackTitle(ordinal: position + 1, language: info.language)
            return SubtitleTrackDescriptor(
                id: SubtitleTrackDescriptor.embeddedID(container: .matroska, streamID: info.number),
                title: title,
                language: info.language,
                format: kind == .image ? .unknown : format,
                kind: kind,
                origin: .embedded(container: .matroska, streamID: info.number, codecID: info.codecID),
                isDefault: info.isDefault,
                isForced: info.isForced)
        }
    }

    /// Used while SubtitleKit's codec table is unavailable; mirrors the Matroska codec registry.
    nonisolated static func fallbackKind(forCodecID codecID: String) -> SubtitleTrackKind {
        let id = codecID.uppercased()
        if id.hasPrefix("S_TEXT") || id.hasPrefix("D_WEBVTT") || id == "S_SSA" || id == "S_ASS" { return .text }
        return .image
    }

    nonisolated static func fallbackFormat(forCodecID codecID: String) -> SubtitleFormat {
        switch codecID.uppercased() {
        case "S_TEXT/UTF8", "S_TEXT/ASCII": return .srt
        case "S_TEXT/ASS", "S_ASS": return .ass
        case "S_TEXT/SSA", "S_SSA": return .ssa
        case "S_TEXT/WEBVTT", "D_WEBVTT/SUBTITLES", "D_WEBVTT/CAPTIONS", "D_WEBVTT/DESCRIPTIONS": return .webvtt
        default: return .unknown
        }
    }

    /// Human label for an embedded codec ("PGS", "VobSub", "SRT").
    nonisolated static func codecLabel(forCodecID codecID: String) -> String {
        let id = codecID.uppercased()
        if id.contains("PGS") { return "PGS" }
        if id.contains("VOBSUB") { return "VobSub" }
        if id.contains("DVBSUB") { return "DVB" }
        let format = fallbackFormat(forCodecID: codecID)
        return format == .unknown ? codecID : format.displayName
    }

    // MARK: VLC parsing (duration and picture size for non-AVFoundation files)

    struct VLCParseResult {
        enum Status { case done, failed, timedOut }
        var status: Status
        var duration: TimeInterval?
        var videoSize: CGSize?
        var hasVideo: Bool?
        var hasAudio: Bool?
    }

    func parseWithVLC(url: URL, timeout: TimeInterval = 6) async -> VLCParseResult {
        let media = VLCMedia(url: url)
        let started = media.parse(options: VLCMediaParsingOptions(rawValue: 0), timeout: Int32(timeout * 1000))
        var status = VLCParseResult.Status.timedOut
        if started != 0 {
            status = .failed
        } else {
            let deadline = CACurrentMediaTime() + timeout + 0.5
            while CACurrentMediaTime() < deadline {
                let parsed = media.parsedStatus
                if parsed == .done { status = .done; break }
                if parsed == .failed { status = .failed; break }
                if parsed == .timeout || parsed == .skipped { status = .timedOut; break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        var result = VLCParseResult(status: status)
        let lengthMS = media.length.value?.doubleValue ?? 0
        if lengthMS > 0 { result.duration = lengthMS / 1000 }
        if let infos = media.tracksInformation as? [[String: Any]], !infos.isEmpty {
            var hasVideo = false
            var hasAudio = false
            for info in infos {
                let type = info[VLCMediaTracksInformationType] as? String
                if type == VLCMediaTracksInformationTypeAudio { hasAudio = true }
                guard type == VLCMediaTracksInformationTypeVideo else { continue }
                hasVideo = true
                let width = (info[VLCMediaTracksInformationVideoWidth] as? NSNumber)?.doubleValue ?? 0
                let height = (info[VLCMediaTracksInformationVideoHeight] as? NSNumber)?.doubleValue ?? 0
                if width > 0, height > 0, result.videoSize == nil {
                    let sarNum = (info[VLCMediaTracksInformationSourceAspectRatio] as? NSNumber)?.doubleValue ?? 1
                    let sarDen = (info[VLCMediaTracksInformationSourceAspectRatioDenominator] as? NSNumber)?.doubleValue ?? 1
                    let sar = (sarNum > 0 && sarDen > 0) ? sarNum / sarDen : 1
                    result.videoSize = CGSize(width: width * sar, height: height)
                }
            }
            result.hasVideo = hasVideo
            result.hasAudio = hasAudio
        }
        return result
    }
}
