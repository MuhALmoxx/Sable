import Foundation

// OWNER: subtitles-core agent.
// Pure-Swift Matroska/WebM (EBML) reader for listing tracks and extracting TEXT subtitle tracks.

public struct MatroskaTrackInfo: Hashable, Sendable {
    public enum TrackType: Int, Sendable { case video = 1, audio = 2, complex = 3, logo = 0x10, subtitle = 0x11, buttons = 0x12, control = 0x20, metadata = 0x21, unknown = 0 }
    public var number: Int
    public var uid: UInt64
    public var type: TrackType
    public var codecID: String
    public var language: LanguageCode?
    public var name: String?
    public var isDefault: Bool
    public var isForced: Bool
    public var codecPrivate: Data?

    public init(number: Int, uid: UInt64, type: TrackType, codecID: String, language: LanguageCode?, name: String?,
                isDefault: Bool, isForced: Bool, codecPrivate: Data?) {
        self.number = number; self.uid = uid; self.type = type; self.codecID = codecID; self.language = language
        self.name = name; self.isDefault = isDefault; self.isForced = isForced; self.codecPrivate = codecPrivate
    }

    /// Subtitle kind from the codec ID: S_TEXT/UTF8, S_TEXT/ASS, S_TEXT/SSA, S_TEXT/WEBVTT,
    /// D_WEBVTT/SUBTITLES -> .text; S_HDMV/PGS, S_VOBSUB, S_DVBSUB, S_HDMV/TEXTST(?) -> .image.
    public var subtitleKind: SubtitleTrackKind? { MatroskaCodec.subtitleKind(forCodecID: codecID) }
    public var subtitleFormat: SubtitleFormat { MatroskaCodec.subtitleFormat(forCodecID: codecID) }
}

public enum MatroskaCodec {
    private static let textCodecs: Set<String> = [
        "S_TEXT/UTF8", "S_TEXT/ASCII", "S_TEXT/ASS", "S_TEXT/SSA", "S_ASS", "S_SSA", "S_TEXT/WEBVTT", "S_TEXT/USF",
        "D_WEBVTT/SUBTITLES", "D_WEBVTT/CAPTIONS", "D_WEBVTT/DESCRIPTIONS",
    ]
    private static let imageCodecs: Set<String> = [
        "S_HDMV/PGS", "S_VOBSUB", "S_VOBSUB/ZLIB", "S_DVBSUB", "S_IMAGE/BMP", "S_HDMV/TEXTST", "S_KATE", "S_ARIBSUB",
    ]

    /// `.text` for subtitle codecs Sable reads itself, `.image` for bitmap (and other
    /// unreadable) subtitle codecs, nil for non-subtitle codecs.
    /// S_HDMV/TEXTST is technically text but rare and not decoded: it is reported as `.image`.
    public static func subtitleKind(forCodecID codecID: String) -> SubtitleTrackKind? {
        let id = codecID.uppercased()
        if textCodecs.contains(id) { return .text }
        if imageCodecs.contains(id) { return .image }
        if id.hasPrefix("S_TEXT/") { return .text }
        if id.hasPrefix("S_") { return .image }
        return nil
    }

    public static func subtitleFormat(forCodecID codecID: String) -> SubtitleFormat {
        switch codecID.uppercased() {
        case "S_TEXT/UTF8", "S_TEXT/ASCII": return .srt
        case "S_TEXT/ASS", "S_ASS": return .ass
        case "S_TEXT/SSA", "S_SSA": return .ssa
        case "S_TEXT/WEBVTT", "D_WEBVTT/SUBTITLES", "D_WEBVTT/CAPTIONS", "D_WEBVTT/DESCRIPTIONS": return .webvtt
        default: return .unknown
        }
    }

    /// Human-readable codec label ("SRT", "ASS", "WebVTT", "PGS · image", "VobSub · image").
    public static func displayName(forCodecID codecID: String) -> String {
        switch codecID.uppercased() {
        case "S_TEXT/UTF8": return "SRT"
        case "S_TEXT/ASCII": return "Text"
        case "S_TEXT/ASS", "S_ASS": return "ASS"
        case "S_TEXT/SSA", "S_SSA": return "SSA"
        case "S_TEXT/WEBVTT", "D_WEBVTT/SUBTITLES", "D_WEBVTT/CAPTIONS", "D_WEBVTT/DESCRIPTIONS": return "WebVTT"
        case "S_TEXT/USF": return "USF"
        case "S_HDMV/PGS": return "PGS · image"
        case "S_VOBSUB", "S_VOBSUB/ZLIB": return "VobSub · image"
        case "S_DVBSUB": return "DVB · image"
        case "S_IMAGE/BMP": return "Bitmap · image"
        case "S_HDMV/TEXTST": return "HDMV Text · unsupported"
        case "S_KATE": return "Kate · unsupported"
        case "S_ARIBSUB": return "ARIB · unsupported"
        default: return codecID
        }
    }
}

/// One Matroska ContentEncoding (compression only; encryption is detected and refused).
struct MatroskaContentEncoding: Hashable, Sendable {
    var order: UInt64 = 0
    /// Bit 1: frames, bit 2: CodecPrivate, bit 4: next ContentEncoding.
    var scope: UInt64 = 1
    /// 0 = compression, 1 = encryption.
    var type: UInt64 = 0
    /// 0 = zlib, 1 = bzlib, 2 = lzo1x, 3 = header stripping.
    var compressionAlgorithm: UInt64 = 0
    var compressionSettings: [UInt8] = []
}

enum MatroskaDecodeError: Error, Equatable {
    case encrypted
    case unsupportedCompression(UInt64)
    case invalidCompressedData
}

/// Reads a Matroska file from disk with seeks (never loads the whole file into memory).
///
/// Not thread-safe: use one reader from one task at a time.
public final class MatroskaReader {
    public let url: URL
    /// EBML DocType: "matroska" or "webm".
    public private(set) var docType: String = "matroska"
    /// Segment title (Info/Title). Available after `readTracks()`.
    public private(set) var title: String?
    /// Segment duration in seconds (Info/Duration). Available after `readTracks()`.
    public private(set) var duration: TimeInterval?
    /// Nanoseconds per timestamp tick (Info/TimestampScale, default 1,000,000 = 1 ms).
    public private(set) var timestampScale: UInt64 = 1_000_000

    /// Largest single subtitle frame / CodecPrivate we read into memory.
    static let maxPayloadSize = 16 << 20

    let io: EBMLFileReader
    private var segmentDataStart: UInt64 = 0
    private var segmentEnd: UInt64 = 0
    private var cachedTracks: [MatroskaTrackInfo]?
    private var encodingsByTrack: [Int: [MatroskaContentEncoding]] = [:]
    private var firstClusterOffset: UInt64?

    /// Opens the file and validates the EBML header (DocType "matroska" or "webm").
    /// Throws `.io` when the file cannot be opened and `.unsupportedFormat` for other files.
    public init(url: URL) throws {
        self.url = url
        self.io = try EBMLFileReader(url: url)
        try openSegment()
    }

    // MARK: Header

    private func openSegment() throws {
        io.seek(to: 0)
        let header: EBMLElementHeader
        do {
            header = try io.readElementHeader()
        } catch {
            throw SubtitleError.unsupportedFormat("not a Matroska or WebM file")
        }
        guard header.id == MKVID.ebml, let headerSize = header.size, headerSize < 4096 else {
            throw SubtitleError.unsupportedFormat("not a Matroska or WebM file")
        }
        let headerEnd = header.dataStart + headerSize
        var p = header.dataStart
        while p < headerEnd {
            io.seek(to: p)
            guard let child = try? io.readElementHeader(), let size = child.size else { break }
            if child.id == MKVID.docType, let value = try? io.readString(size: size, limit: 64) {
                docType = value.lowercased()
            }
            p = child.dataStart + size
        }
        guard docType == "matroska" || docType == "webm" else {
            throw SubtitleError.unsupportedFormat("EBML document type \"\(docType)\"")
        }

        // Find the Segment (skipping Void or other top-level elements).
        p = headerEnd
        while p < io.fileSize {
            io.seek(to: p)
            guard let element = try? io.readElementHeader() else { break }
            if element.id == MKVID.segment {
                segmentDataStart = element.dataStart
                segmentEnd = element.end(clampedTo: io.fileSize)
                return
            }
            guard let size = element.size else { break }
            p = element.dataStart + size
        }
        throw SubtitleError.malformed("no Matroska Segment found")
    }

    // MARK: Element helpers

    /// Reads the element header at `offset`; nil at end of data or on garbage.
    private func header(at offset: UInt64) -> EBMLElementHeader? {
        guard offset < segmentEnd else { return nil }
        io.seek(to: offset)
        return try? io.readElementHeader()
    }

    /// Calls `body` for each child of a master element (the reader is positioned at the
    /// child's payload). Stops quietly on malformed data.
    private func forEachChild(of parent: EBMLElementHeader, _ body: (EBMLElementHeader) throws -> Void) rethrows {
        let end = parent.end(clampedTo: segmentEnd)
        var p = parent.dataStart
        while p < end {
            guard let child = header(at: p) else { return }
            if parent.size == nil && (MKVID.segmentLevel.contains(child.id) || child.id == MKVID.ebml) { return }
            try body(child)
            guard child.size != nil else { return }
            p = child.end(clampedTo: end)
        }
    }

    private func uint(_ e: EBMLElementHeader) -> UInt64? {
        guard let size = e.size else { return nil }
        io.seek(to: e.dataStart)
        return try? io.readUInt(size: size)
    }

    private func string(_ e: EBMLElementHeader) -> String? {
        guard let size = e.size else { return nil }
        io.seek(to: e.dataStart)
        return try? io.readString(size: size)
    }

    private func binary(_ e: EBMLElementHeader, limit: Int = MatroskaReader.maxPayloadSize) -> [UInt8]? {
        guard let size = e.size, size <= UInt64(limit) else { return nil }
        io.seek(to: e.dataStart)
        return try? io.readBytes(Int(size))
    }

    /// Skips an unknown-size element: walks its children until a Segment-level ID appears.
    private func skipUnknownSized(_ e: EBMLElementHeader, depth: Int = 0) -> UInt64 {
        guard depth < 8 else { return segmentEnd }
        var p = e.dataStart
        while p < segmentEnd {
            guard let child = header(at: p) else { return segmentEnd }
            if MKVID.segmentLevel.contains(child.id) || child.id == MKVID.ebml { return p }
            if child.size == nil {
                p = skipUnknownSized(child, depth: depth + 1)
            } else {
                p = child.end(clampedTo: segmentEnd)
            }
        }
        return segmentEnd
    }

    // MARK: Tracks

    /// Parses EBML header + Segment/Tracks. Fast: stops before the first Cluster when possible.
    /// Returns every track (video, audio, subtitles…) in file order.
    public func readTracks() throws -> [MatroskaTrackInfo] {
        if let cachedTracks { return cachedTracks }
        var tracks: [MatroskaTrackInfo]?
        var infoSeen = false
        var seekTargets: [UInt32: UInt64] = [:]
        var p = segmentDataStart
        var passedCluster = false
        while p < segmentEnd {
            guard let e = header(at: p) else { break }
            switch e.id {
            case MKVID.info:
                parseInfo(e)
                infoSeen = true
            case MKVID.tracks:
                tracks = parseTracks(e)
            case MKVID.seekHead:
                for (id, position) in parseSeekHead(e) where seekTargets[id] == nil { seekTargets[id] = position }
            case MKVID.cluster:
                if firstClusterOffset == nil { firstClusterOffset = e.start }
                passedCluster = true
            default:
                break
            }
            if passedCluster {
                if tracks != nil { break }
                // Tracks after the first Cluster: use the SeekHead if it points there.
                if let rel = seekTargets[MKVID.tracks], let t = header(at: segmentDataStart + rel), t.id == MKVID.tracks {
                    tracks = parseTracks(t)
                    break
                }
            }
            p = e.size == nil ? skipUnknownSized(e) : e.end(clampedTo: segmentEnd)
        }
        if !infoSeen, let rel = seekTargets[MKVID.info], let i = header(at: segmentDataStart + rel), i.id == MKVID.info {
            parseInfo(i)
        }
        let result = tracks ?? []
        cachedTracks = result
        return result
    }

    private func parseInfo(_ e: EBMLElementHeader) {
        var rawDuration: Double?
        forEachChild(of: e) { c in
            switch c.id {
            case MKVID.timestampScale:
                if let v = uint(c), v > 0 { timestampScale = v }
            case MKVID.duration:
                if let size = c.size {
                    io.seek(to: c.dataStart)
                    rawDuration = try? io.readFloat(size: size)
                }
            case MKVID.title:
                if let t = string(c), !t.isEmpty { title = t }
            default:
                break
            }
        }
        if let d = rawDuration, d.isFinite, d > 0 {
            duration = d * Double(timestampScale) / 1e9
        }
    }

    private func parseSeekHead(_ e: EBMLElementHeader) -> [UInt32: UInt64] {
        var result: [UInt32: UInt64] = [:]
        forEachChild(of: e) { seek in
            guard seek.id == MKVID.seek else { return }
            var id: UInt32?
            var position: UInt64?
            forEachChild(of: seek) { c in
                if c.id == MKVID.seekID, let bytes = binary(c, limit: 4) {
                    id = bytes.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
                } else if c.id == MKVID.seekPosition {
                    position = uint(c)
                }
            }
            if let id, let position { result[id] = position }
        }
        return result
    }

    private func parseTracks(_ e: EBMLElementHeader) -> [MatroskaTrackInfo] {
        var result: [MatroskaTrackInfo] = []
        forEachChild(of: e) { entry in
            guard entry.id == MKVID.trackEntry, let track = parseTrackEntry(entry) else { return }
            result.append(track)
        }
        return result
    }

    private func parseTrackEntry(_ e: EBMLElementHeader) -> MatroskaTrackInfo? {
        var number = 0
        var uid: UInt64 = 0
        var type = MatroskaTrackInfo.TrackType.unknown
        var codecID = ""
        var codecPrivate: [UInt8]?
        var language = "eng" // Matroska default when the element is absent
        var bcp47: String?
        var name: String?
        var isDefault = true
        var isForced = false
        var encodings: [MatroskaContentEncoding] = []
        forEachChild(of: e) { c in
            switch c.id {
            case MKVID.trackNumber: number = Int(clamping: uint(c) ?? 0)
            case MKVID.trackUID: uid = uint(c) ?? 0
            case MKVID.trackType: type = MatroskaTrackInfo.TrackType(rawValue: Int(clamping: uint(c) ?? 0)) ?? .unknown
            case MKVID.codecID: codecID = string(c) ?? ""
            case MKVID.codecPrivate: codecPrivate = binary(c)
            case MKVID.language: if let l = string(c) { language = l }
            case MKVID.languageBCP47: bcp47 = string(c)
            case MKVID.name: name = string(c)
            case MKVID.flagDefault: isDefault = (uint(c) ?? 1) != 0
            case MKVID.flagForced: isForced = (uint(c) ?? 0) != 0
            case MKVID.contentEncodings:
                forEachChild(of: c) { enc in
                    if enc.id == MKVID.contentEncoding { encodings.append(parseContentEncoding(enc)) }
                }
            default: break
            }
        }
        guard number > 0 else { return nil }
        encodingsByTrack[number] = encodings
        // Decode CodecPrivate if an encoding applies to it (scope bit 2).
        if let raw = codecPrivate, encodings.contains(where: { $0.scope & 2 != 0 }) {
            codecPrivate = try? Self.decodeContent(raw, encodings: encodings, scopeBit: 2)
        }
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let lang = LanguageCode.normalized(bcp47?.isEmpty == false ? bcp47 : language)
        return MatroskaTrackInfo(number: number, uid: uid, type: type, codecID: codecID, language: lang,
                                 name: trimmedName?.isEmpty == false ? trimmedName : nil,
                                 isDefault: isDefault, isForced: isForced, codecPrivate: codecPrivate.map { Data($0) })
    }

    private func parseContentEncoding(_ e: EBMLElementHeader) -> MatroskaContentEncoding {
        var enc = MatroskaContentEncoding()
        forEachChild(of: e) { c in
            switch c.id {
            case MKVID.contentEncodingOrder: enc.order = uint(c) ?? 0
            case MKVID.contentEncodingScope: enc.scope = uint(c) ?? 1
            case MKVID.contentEncodingType: enc.type = uint(c) ?? 0
            case MKVID.contentCompression:
                forEachChild(of: c) { cc in
                    if cc.id == MKVID.contentCompAlgo { enc.compressionAlgorithm = uint(cc) ?? 0 }
                    if cc.id == MKVID.contentCompSettings { enc.compressionSettings = binary(cc, limit: 1 << 16) ?? [] }
                }
            default: break
            }
        }
        return enc
    }

    /// Undoes content encodings (highest ContentEncodingOrder first, as the spec requires).
    static func decodeContent(_ data: [UInt8], encodings: [MatroskaContentEncoding], scopeBit: UInt64) throws -> [UInt8] {
        var out = data
        for enc in encodings.sorted(by: { $0.order > $1.order }) where enc.scope & scopeBit != 0 {
            guard enc.type == 0 else { throw MatroskaDecodeError.encrypted }
            switch enc.compressionAlgorithm {
            case 0:
                do {
                    out = try Inflate.decompress(out, maxOutputSize: maxPayloadSize)
                } catch {
                    throw MatroskaDecodeError.invalidCompressedData
                }
            case 3:
                out = enc.compressionSettings + out
            default:
                throw MatroskaDecodeError.unsupportedCompression(enc.compressionAlgorithm)
            }
        }
        return out
    }

    // MARK: Extraction

    /// Scans all Clusters once and extracts every requested TEXT subtitle track into documents,
    /// keyed by track number. Handles SimpleBlock and BlockGroup(+BlockDuration), TimestampScale,
    /// ContentEncoding header-stripping and zlib compression, ASS/SSA "ReadOrder,Layer,Style,…"
    /// block payloads (using CodecPrivate as header), and WebVTT blocks.
    /// `progress` receives 0...1 (by file offset). Throws `SubtitleError.cancelled` when
    /// `isCancelled()` returns true.
    ///
    /// Requested numbers that are not text subtitle tracks are ignored. A requested text track
    /// with no readable cues yields a document with no cues. Only the requested tracks'
    /// payloads are read; every other block is skipped with a seek.
    public func extractTextSubtitles(trackNumbers: Set<Int>,
                                     progress: ((Double) -> Void)? = nil,
                                     isCancelled: () -> Bool = { false }) throws -> [Int: SubtitleDocument] {
        let tracks = try readTracks()
        var targets: [Int: MatroskaTrackInfo] = [:]
        for t in tracks where trackNumbers.contains(t.number) && t.subtitleKind == .text && targets[t.number] == nil {
            targets[t.number] = t
        }
        guard !targets.isEmpty else { return [:] }
        if isCancelled() { throw SubtitleError.cancelled }

        var frames: [Int: [MatroskaRawFrame]] = [:]
        for number in targets.keys { frames[number] = [] }
        var sequence = 0
        let fileSize = Double(max(io.fileSize, 1))
        var lastReported = -1.0
        func report(_ offset: UInt64) {
            guard let progress else { return }
            let value = min(1, Double(offset) / fileSize)
            if value - lastReported >= 0.002 || value >= 1 {
                lastReported = value
                progress(value)
            }
        }
        report(0)

        var p = firstClusterOffset ?? segmentDataStart
        var elementCounter = 0
        while p < segmentEnd {
            if isCancelled() { throw SubtitleError.cancelled }
            report(p)
            io.seek(to: p)
            let e: EBMLElementHeader
            do {
                e = try io.readElementHeader()
            } catch EBMLError.endOfData {
                break
            } catch let error as SubtitleError {
                throw error
            } catch {
                // Corrupt data: resynchronise on the next Cluster ID.
                guard let next = try io.find([0x1F, 0x43, 0xB6, 0x75], from: p + 1, limit: segmentEnd) else { break }
                p = next
                continue
            }
            if e.id == MKVID.cluster {
                p = try scanCluster(e, targets: targets, frames: &frames, sequence: &sequence,
                                    elementCounter: &elementCounter, isCancelled: isCancelled)
            } else if e.size == nil {
                p = skipUnknownSized(e)
            } else {
                p = e.end(clampedTo: segmentEnd)
            }
        }
        if isCancelled() { throw SubtitleError.cancelled }

        var documents: [Int: SubtitleDocument] = [:]
        for (number, track) in targets {
            let encodings = encodingsByTrack[number] ?? []
            var decoded: [MatroskaRawFrame] = []
            var usable = true
            for var frame in frames[number] ?? [] where usable {
                if encodings.isEmpty {
                    decoded.append(frame)
                    continue
                }
                do {
                    frame.data = try Self.decodeContent(frame.data, encodings: encodings, scopeBit: 1)
                    decoded.append(frame)
                } catch MatroskaDecodeError.invalidCompressedData {
                    continue // skip this frame only
                } catch {
                    usable = false // encrypted or unsupported compression: nothing readable
                }
            }
            documents[number] = MatroskaSubtitleDecoder.document(for: track, frames: usable ? decoded : [])
        }
        progress?(1)
        return documents
    }

    /// Walks one Cluster. Returns the offset after it (for an unknown-size Cluster: the offset
    /// of the element that ended it).
    private func scanCluster(_ cluster: EBMLElementHeader, targets: [Int: MatroskaTrackInfo],
                             frames: inout [Int: [MatroskaRawFrame]], sequence: inout Int,
                             elementCounter: inout Int, isCancelled: () -> Bool) throws -> UInt64 {
        let known = cluster.size != nil
        let end = cluster.end(clampedTo: segmentEnd)
        var clusterTimestamp: Int64 = 0
        var p = cluster.dataStart
        while p < end {
            elementCounter += 1
            if elementCounter & 1023 == 0, isCancelled() { throw SubtitleError.cancelled }
            guard let child = header(at: p) else { return known ? end : p }
            if !known && (MKVID.segmentLevel.contains(child.id) || child.id == MKVID.ebml) { return p }
            guard child.size != nil else { return known ? end : p }
            let childEnd = child.end(clampedTo: end)
            switch child.id {
            case MKVID.clusterTimestamp:
                clusterTimestamp = Int64(clamping: uint(child) ?? 0)
            case MKVID.simpleBlock:
                if let block = readBlock(child, targets: targets) {
                    append(block, clusterTimestamp: clusterTimestamp, duration: nil, addition: nil,
                           frames: &frames, sequence: &sequence)
                }
            case MKVID.blockGroup:
                readBlockGroup(child, clusterTimestamp: clusterTimestamp, targets: targets, frames: &frames, sequence: &sequence)
            default:
                break
            }
            p = childEnd
        }
        return end
    }

    private struct BlockPayload {
        var track: Int
        var relativeTimestamp: Int16
        var frames: [[UInt8]]
    }

    /// Reads a (Simple)Block header; reads the payload only for requested tracks.
    private func readBlock(_ e: EBMLElementHeader, targets: [Int: MatroskaTrackInfo]) -> BlockPayload? {
        guard let size = e.size else { return nil }
        io.seek(to: e.dataStart)
        guard let track = try? io.readVInt(), track.length <= 8,
              targets[Int(clamping: track.value)] != nil,
              let hi = try? io.readByte(), let lo = try? io.readByte(), let flags = try? io.readByte() else { return nil }
        let headerLength = UInt64(track.length + 3)
        guard size >= headerLength else { return nil }
        let payloadSize = size - headerLength
        guard payloadSize <= UInt64(Self.maxPayloadSize), let payload = try? io.readBytes(Int(payloadSize)) else { return nil }
        let rel = Int16(bitPattern: UInt16(hi) << 8 | UInt16(lo))
        guard let laced = Self.splitLaces(payload, lacing: (flags >> 1) & 0x03) else { return nil }
        return BlockPayload(track: Int(clamping: track.value), relativeTimestamp: rel, frames: laced)
    }

    private func readBlockGroup(_ group: EBMLElementHeader, clusterTimestamp: Int64, targets: [Int: MatroskaTrackInfo],
                                frames: inout [Int: [MatroskaRawFrame]], sequence: inout Int) {
        let end = group.end(clampedTo: segmentEnd)
        var block: BlockPayload?
        var duration: UInt64?
        var addition: [UInt8]?
        var p = group.dataStart
        while p < end {
            guard let c = header(at: p), c.size != nil else { break }
            switch c.id {
            case MKVID.block:
                guard let b = readBlock(c, targets: targets) else { return } // not ours (or broken): skip the group
                block = b
            case MKVID.blockDuration:
                duration = uint(c)
            case MKVID.blockAdditions:
                forEachChild(of: c) { more in
                    guard more.id == MKVID.blockMore else { return }
                    forEachChild(of: more) { a in
                        if a.id == MKVID.blockAdditional, addition == nil { addition = binary(a, limit: 1 << 16) }
                    }
                }
            default:
                break
            }
            p = c.end(clampedTo: end)
        }
        if let block {
            append(block, clusterTimestamp: clusterTimestamp, duration: duration, addition: addition,
                   frames: &frames, sequence: &sequence)
        }
    }

    private func append(_ block: BlockPayload, clusterTimestamp: Int64, duration: UInt64?, addition: [UInt8]?,
                        frames: inout [Int: [MatroskaRawFrame]], sequence: inout Int) {
        let ticks = clusterTimestamp + Int64(block.relativeTimestamp)
        let start = max(0, seconds(ticks: ticks))
        let length = duration.flatMap { $0 > 0 ? seconds(ticks: Int64(clamping: $0)) : nil }
        for data in block.frames {
            frames[block.track, default: []].append(MatroskaRawFrame(start: start, duration: length, data: data,
                                                                      addition: addition, sequence: sequence))
            sequence += 1
        }
    }

    private func seconds(ticks: Int64) -> TimeInterval {
        let (ns, overflow) = ticks.multipliedReportingOverflow(by: Int64(clamping: timestampScale))
        if overflow { return Double(ticks) * Double(timestampScale) / 1e9 }
        return Double(ns) / 1e9
    }

    /// Splits a block payload into frames per its lacing (0 none, 1 Xiph, 2 fixed, 3 EBML).
    static func splitLaces(_ payload: [UInt8], lacing: UInt8) -> [[UInt8]]? {
        guard lacing != 0 else { return [payload] }
        guard let countByte = payload.first else { return nil }
        let count = Int(countByte) + 1
        var p = 1
        var sizes: [Int] = []
        switch lacing {
        case 1: // Xiph
            for _ in 0..<(count - 1) {
                var size = 0
                while true {
                    guard p < payload.count else { return nil }
                    let b = Int(payload[p])
                    p += 1
                    size += b
                    if b != 255 { break }
                }
                sizes.append(size)
            }
        case 3: // EBML
            func vint(signed: Bool) -> Int? {
                guard p < payload.count, payload[p] != 0 else { return nil }
                let first = payload[p]
                let length = first.leadingZeroBitCount + 1
                guard p + length <= payload.count else { return nil }
                var value = Int(first & (UInt8(0xFF) >> UInt8(length)))
                for k in 1..<length { value = value << 8 | Int(payload[p + k]) }
                p += length
                if signed { value -= (1 << (7 * length - 1)) - 1 }
                return value
            }
            guard count > 1 else { break }
            guard let first = vint(signed: false) else { return nil }
            sizes.append(first)
            for _ in 0..<max(0, count - 2) {
                guard let delta = vint(signed: true) else { return nil }
                let next = sizes[sizes.count - 1] + delta
                guard next >= 0 else { return nil }
                sizes.append(next)
            }
        case 2: // fixed
            let remaining = payload.count - 1
            guard remaining % count == 0 else { return nil }
            sizes = [Int](repeating: remaining / count, count: count - 1)
        default:
            return nil
        }
        let used = sizes.reduce(0, +)
        guard used <= payload.count - p else { return nil }
        sizes.append(payload.count - p - used)
        var result: [[UInt8]] = []
        for size in sizes {
            result.append(Array(payload[p..<(p + size)]))
            p += size
        }
        return result
    }
}

/// One subtitle frame as stored in a block (after lacing, before decoding).
struct MatroskaRawFrame {
    var start: TimeInterval
    var duration: TimeInterval?
    var data: [UInt8]
    var addition: [UInt8]?
    var sequence: Int
}

/// Turns raw subtitle frames of one track into a SubtitleDocument.
enum MatroskaSubtitleDecoder {
    static func document(for track: MatroskaTrackInfo, frames: [MatroskaRawFrame]) -> SubtitleDocument {
        let codec = track.codecID.uppercased()
        let format = track.subtitleFormat
        let texts = decodeTexts(frames.map(\.data))
        let privateText = track.codecPrivate.map { decodeTexts([[UInt8]($0)])[0] }

        struct Draft {
            var start: TimeInterval
            var duration: TimeInterval?
            var order: Int
            var preferredID: String?
            var text: String
            var raw: String
            var style: CueStyleHint?
        }
        var drafts: [Draft] = []
        var header: String?

        switch format {
        case .ass, .ssa:
            let info = ASSParser.parseHeader(privateText ?? "")
            header = info.headerText
            for (frame, text) in zip(frames, texts) {
                let block = parseASSBlock(text, info: info)
                let style = info.style(named: block.style)
                guard let converted = ASSParser.convertDialogueText(block.text, style: style, styles: info.styles) else { continue }
                let hint = CueStyleHint(alignment: converted.alignment ?? style?.alignment,
                                        styleName: (block.style?.isEmpty ?? true) ? nil : block.style,
                                        italic: style?.italic ?? false, bold: style?.bold ?? false)
                drafts.append(Draft(start: frame.start, duration: frame.duration, order: block.readOrder ?? (1 << 40) + frame.sequence,
                                    preferredID: block.readOrder.map { "a\($0 + 1)" }, text: converted.text, raw: block.text, style: hint))
            }
        case .webvtt:
            let webmStyle = codec.hasPrefix("D_WEBVTT/")
            for (frame, text) in zip(frames, texts) {
                var identifier: String?
                var settings = ""
                var payload = TextLines.normalize(text)
                if webmStyle {
                    // "identifier\nsettings\npayload"
                    let parts = payload.split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: false)
                    if parts.count == 3 {
                        let id = parts[0].trimmingCharacters(in: .whitespaces)
                        identifier = id.isEmpty ? nil : id
                        settings = String(parts[1])
                        payload = String(parts[2])
                    }
                } else if let addition = frame.addition {
                    // S_TEXT/WEBVTT keeps settings (and comments) in BlockAdditional.
                    let lines = TextLines.split(String(decoding: addition, as: UTF8.self))
                    settings = lines.first(where: { WebVTTParser.alignment(fromSettings: String($0)) != nil }).map { String($0) } ?? ""
                }
                let cleaned = WebVTTParser.cleanPayload(payload)
                guard !cleaned.isEmpty else { continue }
                drafts.append(Draft(start: frame.start, duration: frame.duration, order: frame.sequence, preferredID: identifier,
                                    text: cleaned, raw: payload,
                                    style: WebVTTParser.alignment(fromSettings: settings).map { CueStyleHint(alignment: $0) }))
            }
        default:
            let isUSF = codec == "S_TEXT/USF"
            for (frame, text) in zip(frames, texts) {
                let raw = TextLines.normalize(text)
                let source = isUSF ? stripXMLTags(raw) : raw
                let cleaned = InlineMarkup.clean(source, dialect: .srt)
                guard !cleaned.text.isEmpty else { continue }
                drafts.append(Draft(start: frame.start, duration: frame.duration, order: frame.sequence, preferredID: nil,
                                    text: cleaned.text, raw: raw, style: cleaned.alignment.map { CueStyleHint(alignment: $0) }))
            }
        }

        drafts.sort { ($0.start, $0.order) < ($1.start, $1.order) }
        let ids = CueIDs.assign(preferred: drafts.map(\.preferredID), prefix: format == .ass || format == .ssa ? "a" : "c")
        var cues: [SubtitleCue] = []
        cues.reserveCapacity(drafts.count)
        for (i, d) in drafts.enumerated() {
            let end: TimeInterval
            if let duration = d.duration {
                end = d.start + duration
            } else if let next = drafts[(i + 1)...].first(where: { $0.start > d.start }) {
                end = min(next.start, d.start + 5)
            } else {
                end = d.start + 2
            }
            cues.append(SubtitleCue(id: ids[i], index: i, start: d.start, end: end, text: d.text, rawText: d.raw, style: d.style))
        }
        return SubtitleDocument(format: format, cues: cues, language: track.language, title: track.name, header: header).normalized()
    }

    /// Matroska ASS/SSA block: "ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,Effect,Text"
    /// (SSA: "ReadOrder,Marked,Style,…"). Old muxers stored full "Dialogue:" lines; both work.
    static func parseASSBlock(_ text: String, info: ASSHeaderInfo) -> (readOrder: Int?, style: String?, text: String) {
        let trimmed = text.drop(while: { $0 == " " || $0 == "\t" })
        if trimmed.lowercased().hasPrefix("dialogue:") {
            let body = trimmed.dropFirst("dialogue:".count)
            let format = info.eventFormat ?? (info.isSSA ? ASSParser.defaultSSAEventFormat : ASSParser.defaultASSEventFormat)
            let fields = ASSParser.splitFields(body, count: format.count)
            if fields.count == format.count {
                let style = format.firstIndex(of: "style").map { fields[$0].trimmingCharacters(in: .whitespaces) }
                let textIndex = format.firstIndex(of: "text") ?? (format.count - 1)
                return (nil, style, String(fields[textIndex]))
            }
        }
        let fields = ASSParser.splitFields(text, count: 9)
        guard fields.count == 9 else { return (nil, nil, text) }
        let readOrder = Int(fields[0].trimmingCharacters(in: .whitespaces))
        return (readOrder, fields[2].trimmingCharacters(in: .whitespaces), String(fields[8]))
    }

    /// Frames are UTF-8 per the Matroska spec; when some are not, one legacy encoding is
    /// detected for the whole track so all cues decode consistently.
    static func decodeTexts(_ payloads: [[UInt8]]) -> [String] {
        let trimmed = payloads.map { bytes -> [UInt8] in
            var b = bytes
            while b.last == 0 { b.removeLast() }
            if b.starts(with: [0xEF, 0xBB, 0xBF]) { b.removeFirst(3) }
            return b
        }
        let invalid = trimmed.filter { !TextDecoding.isValidUTF8($0) }
        guard !invalid.isEmpty else { return trimmed.map { String(decoding: $0, as: UTF8.self) } }
        var sample: [UInt8] = []
        for bytes in invalid where sample.count < 1 << 20 {
            sample.append(contentsOf: bytes)
            sample.append(0x0A)
        }
        let legacy = TextDecoding.detectLegacyEncoding(sample)
        return trimmed.map { TextDecoding.isValidUTF8($0) ? String(decoding: $0, as: UTF8.self) : TextDecoding.decode($0, legacy: legacy) }
    }

    /// USF payloads are XML; keep text, translate <i>/<b>/<u>-like elements, drop other tags.
    static func stripXMLTags(_ text: String) -> String {
        var out = ""
        var inTag = false
        var tag = ""
        for ch in text {
            if inTag {
                if ch == ">" {
                    inTag = false
                    let lower = tag.lowercased().trimmingCharacters(in: .whitespaces)
                    if ["i", "/i", "b", "/b", "u", "/u"].contains(lower) { out += "<\(lower)>" }
                    if lower == "br" || lower == "br/" || lower == "br /" { out += "\n" }
                    tag = ""
                } else {
                    tag.append(ch)
                }
            } else if ch == "<" {
                inTag = true
            } else {
                out.append(ch)
            }
        }
        return out
    }
}
