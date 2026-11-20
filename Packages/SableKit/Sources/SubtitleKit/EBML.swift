import Foundation

// OWNER: subtitles-core agent.
// Low-level EBML access over a FileHandle. Never loads the file: a small buffer (4 KB after a
// seek, growing to 256 KB while reads stay sequential) plus direct reads for large payloads.

enum EBMLError: Error, Equatable {
    case endOfData
    case invalidVInt
    case invalidID
    case elementTooLarge
}

/// Matroska / WebM element IDs used by the reader.
enum MKVID {
    static let ebml: UInt32 = 0x1A45DFA3
    static let docType: UInt32 = 0x4282
    static let segment: UInt32 = 0x18538067
    static let seekHead: UInt32 = 0x114D9B74
    static let seek: UInt32 = 0x4DBB
    static let seekID: UInt32 = 0x53AB
    static let seekPosition: UInt32 = 0x53AC
    static let info: UInt32 = 0x1549A966
    static let timestampScale: UInt32 = 0x2AD7B1
    static let duration: UInt32 = 0x4489
    static let title: UInt32 = 0x7BA9
    static let tracks: UInt32 = 0x1654AE6B
    static let trackEntry: UInt32 = 0xAE
    static let trackNumber: UInt32 = 0xD7
    static let trackUID: UInt32 = 0x73C5
    static let trackType: UInt32 = 0x83
    static let codecID: UInt32 = 0x86
    static let codecPrivate: UInt32 = 0x63A2
    static let language: UInt32 = 0x22B59C
    static let languageBCP47: UInt32 = 0x22B59D
    static let name: UInt32 = 0x536E
    static let flagDefault: UInt32 = 0x88
    static let flagForced: UInt32 = 0x55AA
    static let contentEncodings: UInt32 = 0x6D80
    static let contentEncoding: UInt32 = 0x6240
    static let contentEncodingOrder: UInt32 = 0x5031
    static let contentEncodingScope: UInt32 = 0x5032
    static let contentEncodingType: UInt32 = 0x5033
    static let contentCompression: UInt32 = 0x5034
    static let contentCompAlgo: UInt32 = 0x4254
    static let contentCompSettings: UInt32 = 0x4255
    static let cluster: UInt32 = 0x1F43B675
    static let clusterTimestamp: UInt32 = 0xE7
    static let simpleBlock: UInt32 = 0xA3
    static let blockGroup: UInt32 = 0xA0
    static let block: UInt32 = 0xA1
    static let blockDuration: UInt32 = 0x9B
    static let blockAdditions: UInt32 = 0x75A1
    static let blockMore: UInt32 = 0xA6
    static let blockAddID: UInt32 = 0xEE
    static let blockAdditional: UInt32 = 0xA5
    static let cues: UInt32 = 0x1C53BB6B
    static let chapters: UInt32 = 0x1043A770
    static let tags: UInt32 = 0x1254C367
    static let attachments: UInt32 = 0x1941A469
    static let void: UInt32 = 0xEC
    static let crc32: UInt32 = 0xBF

    /// Children of Segment (besides Void / CRC-32).
    static let segmentLevel: Set<UInt32> = [seekHead, info, tracks, cluster, cues, chapters, tags, attachments]

    /// Valid children of a Cluster: Timestamp, SilentTracks, Position, PrevSize, SimpleBlock,
    /// BlockGroup, EncryptedBlock, Void, CRC-32. Anything else ends an unknown-size Cluster.
    static let clusterChildren: Set<UInt32> = [clusterTimestamp, 0x5854, 0xA7, 0xAB, simpleBlock, blockGroup, 0xAF, void, crc32]
}

struct EBMLElementHeader: Equatable {
    let id: UInt32
    /// nil = unknown size (all value bits set).
    let size: UInt64?
    /// Offset of the ID's first byte.
    let start: UInt64
    /// Offset of the first payload byte.
    let dataStart: UInt64

    /// End of the payload, clamped to `limit` (unknown size -> `limit`).
    func end(clampedTo limit: UInt64) -> UInt64 {
        guard let size else { return limit }
        let (sum, overflow) = dataStart.addingReportingOverflow(size)
        return overflow ? limit : min(sum, limit)
    }
}

final class EBMLFileReader {
    static let minimumReadAhead = 4096
    static let maximumReadAhead = 256 * 1024

    private let handle: FileHandle
    let fileSize: UInt64
    private var buffer: [UInt8] = []
    private var bufferStart: UInt64 = 0
    private(set) var position: UInt64 = 0
    private var readAhead = EBMLFileReader.minimumReadAhead
    private var lastFillEnd: UInt64 = .max

    /// Statistics (tests use them to prove that payloads are skipped, not read).
    private(set) var bytesRead: UInt64 = 0
    private(set) var readCount = 0

    init(url: URL) throws {
        let h: FileHandle
        do {
            h = try FileHandle(forReadingFrom: url)
        } catch {
            throw SubtitleError.io(error.localizedDescription)
        }
        let size: UInt64
        do {
            size = try h.seekToEnd()
        } catch {
            try? h.close()
            throw SubtitleError.io(error.localizedDescription)
        }
        handle = h
        fileSize = size
    }

    deinit {
        try? handle.close()
    }

    func seek(to offset: UInt64) { position = offset }

    private func rawRead(at offset: UInt64, count: Int) throws -> [UInt8] {
        do {
            try handle.seek(toOffset: offset)
            let data = try handle.read(upToCount: count) ?? Data()
            bytesRead += UInt64(data.count)
            readCount += 1
            return [UInt8](data)
        } catch {
            throw SubtitleError.io(error.localizedDescription)
        }
    }

    private func fill(minimum: Int) throws {
        guard position < fileSize else { throw EBMLError.endOfData }
        if position == lastFillEnd {
            readAhead = min(readAhead * 2, Self.maximumReadAhead)
        } else {
            readAhead = Self.minimumReadAhead
        }
        let available = fileSize - position
        let want = Int(min(UInt64(max(minimum, readAhead)), available))
        buffer = try rawRead(at: position, count: want)
        bufferStart = position
        lastFillEnd = position + UInt64(buffer.count)
        guard !buffer.isEmpty else { throw EBMLError.endOfData }
    }

    private var bufferEnd: UInt64 { bufferStart + UInt64(buffer.count) }

    func readByte() throws -> UInt8 {
        if position < bufferStart || position >= bufferEnd { try fill(minimum: 1) }
        let b = buffer[Int(position - bufferStart)]
        position += 1
        return b
    }

    func readBytes(_ count: Int) throws -> [UInt8] {
        guard count > 0 else { return [] }
        guard position <= fileSize, UInt64(count) <= fileSize - position else { throw EBMLError.endOfData }
        if position >= bufferStart && position + UInt64(count) <= bufferEnd {
            let s = Int(position - bufferStart)
            position += UInt64(count)
            return Array(buffer[s..<(s + count)])
        }
        if count >= Self.maximumReadAhead {
            let bytes = try rawRead(at: position, count: count)
            guard bytes.count == count else { throw EBMLError.endOfData }
            position += UInt64(count)
            return bytes
        }
        try fill(minimum: count)
        guard buffer.count >= count else { throw EBMLError.endOfData }
        position += UInt64(count)
        return Array(buffer[0..<count])
    }

    /// Variable-size integer (1-8 bytes). `unknown` is true when all value bits are set.
    func readVInt() throws -> (value: UInt64, length: Int, unknown: Bool) {
        let first = try readByte()
        guard first != 0 else { throw EBMLError.invalidVInt }
        let length = first.leadingZeroBitCount + 1
        let mask = UInt8(0xFF) >> UInt8(length)
        var value = UInt64(first & mask)
        var allOnes = (first & mask) == mask
        for _ in 1..<length {
            let b = try readByte()
            value = value << 8 | UInt64(b)
            if b != 0xFF { allOnes = false }
        }
        return (value, length, allOnes)
    }

    /// Element ID (1-4 bytes, marker bit kept, as written in the spec).
    func readID() throws -> UInt32 {
        let first = try readByte()
        guard first != 0, first != 0xFF else { throw EBMLError.invalidID }
        let length = first.leadingZeroBitCount + 1
        guard length <= 4 else { throw EBMLError.invalidID }
        var id = UInt32(first)
        for _ in 1..<length { id = id << 8 | UInt32(try readByte()) }
        return id
    }

    func readElementHeader() throws -> EBMLElementHeader {
        let start = position
        let id = try readID()
        let size = try readVInt()
        return EBMLElementHeader(id: id, size: size.unknown ? nil : size.value, start: start, dataStart: position)
    }

    func readUInt(size: UInt64) throws -> UInt64 {
        guard size <= 8 else { throw EBMLError.elementTooLarge }
        var v: UInt64 = 0
        for _ in 0..<size { v = v << 8 | UInt64(try readByte()) }
        return v
    }

    func readSInt(size: UInt64) throws -> Int64 {
        guard size <= 8 else { throw EBMLError.elementTooLarge }
        guard size > 0 else { return 0 }
        let raw = try readUInt(size: size)
        let shift = UInt64(64 - 8 * Int(size))
        return Int64(bitPattern: raw << shift) >> Int64(shift)
    }

    func readFloat(size: UInt64) throws -> Double {
        switch size {
        case 0: return 0
        case 4: return Double(Float(bitPattern: UInt32(truncatingIfNeeded: try readUInt(size: 4))))
        case 8: return Double(bitPattern: try readUInt(size: 8))
        default: throw EBMLError.elementTooLarge
        }
    }

    func readString(size: UInt64, limit: UInt64 = 1 << 20) throws -> String {
        guard size <= limit else { throw EBMLError.elementTooLarge }
        var bytes = try readBytes(Int(size))
        while bytes.last == 0 { bytes.removeLast() }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Searches forward for a 4-byte pattern (resynchronisation after corrupt data).
    func find(_ pattern: [UInt8], from offset: UInt64, limit: UInt64) throws -> UInt64? {
        guard pattern.count == 4 else { return nil }
        var p = offset
        let chunk = 64 * 1024
        while p + 4 <= limit {
            let count = Int(min(UInt64(chunk), limit - p))
            let bytes = try rawRead(at: p, count: count)
            guard bytes.count >= 4 else { return nil }
            var i = 0
            while i + 4 <= bytes.count {
                if bytes[i] == pattern[0] && bytes[i + 1] == pattern[1] && bytes[i + 2] == pattern[2] && bytes[i + 3] == pattern[3] {
                    return p + UInt64(i)
                }
                i += 1
            }
            p += UInt64(bytes.count - 3)
        }
        return nil
    }
}
