import Foundation
@testable import SubtitleKit

// MARK: - EBML / Matroska builder

enum EBML {
    static func id(_ id: UInt32) -> [UInt8] {
        var out: [UInt8] = []
        var v = id
        while v > 0 {
            out.insert(UInt8(v & 0xFF), at: 0)
            v >>= 8
        }
        return out
    }

    /// Minimal-length EBML variable-size integer (also used for block track numbers).
    static func vint(_ n: UInt64, minLength: Int = 1) -> [UInt8] {
        var length = 1
        while length < 8 && n >= (UInt64(1) << UInt64(7 * length)) - 1 { length += 1 }
        length = max(length, minLength)
        var out = [UInt8](repeating: 0, count: length)
        var v = n
        for i in stride(from: length - 1, through: 0, by: -1) {
            out[i] = UInt8(v & 0xFF)
            v >>= 8
        }
        out[0] |= UInt8(0x80 >> (length - 1))
        return out
    }

    static let unknownSize: [UInt8] = [0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]

    static func element(_ id: UInt32, _ payload: [UInt8]) -> [UInt8] {
        self.id(id) + vint(UInt64(payload.count)) + payload
    }

    static func master(_ id: UInt32, _ children: [[UInt8]]) -> [UInt8] { element(id, children.flatMap { $0 }) }

    static func unknownSizeMaster(_ id: UInt32, _ children: [[UInt8]]) -> [UInt8] {
        self.id(id) + unknownSize + children.flatMap { $0 }
    }

    static func uint(_ id: UInt32, _ value: UInt64) -> [UInt8] {
        var out: [UInt8] = []
        var v = value
        repeat {
            out.insert(UInt8(v & 0xFF), at: 0)
            v >>= 8
        } while v > 0
        return element(id, out)
    }

    static func string(_ id: UInt32, _ s: String) -> [UInt8] { element(id, Array(s.utf8)) }

    static func float(_ id: UInt32, _ value: Double) -> [UInt8] {
        let bits = value.bitPattern
        return element(id, (0..<8).map { UInt8((bits >> UInt64(56 - 8 * $0)) & 0xFF) })
    }
}

struct MKVTrackSpec {
    var number: Int
    var type: UInt64 = 0x11
    var codecID: String
    var uid: UInt64? = nil
    var language: String? = nil
    var languageBCP47: String? = nil
    var name: String? = nil
    var flagDefault: UInt64? = nil
    var flagForced: UInt64? = nil
    var codecPrivate: [UInt8]? = nil
    /// Raw ContentEncoding elements (see MKV.zlibEncoding etc.).
    var encodings: [[UInt8]] = []
}

enum MKV {
    static func ebmlHeader(docType: String = "matroska") -> [UInt8] {
        EBML.master(MKVID.ebml, [
            EBML.uint(0x4286, 1), EBML.uint(0x42F7, 1), EBML.uint(0x42F2, 4), EBML.uint(0x42F3, 8),
            EBML.string(MKVID.docType, docType), EBML.uint(0x4287, 4), EBML.uint(0x4285, 2),
        ])
    }

    static func info(timestampScale: UInt64? = nil, duration: Double? = nil, title: String? = nil) -> [UInt8] {
        var children: [[UInt8]] = []
        if let timestampScale { children.append(EBML.uint(MKVID.timestampScale, timestampScale)) }
        if let duration { children.append(EBML.float(MKVID.duration, duration)) }
        if let title { children.append(EBML.string(MKVID.title, title)) }
        children.append(EBML.string(0x4D80, "SableTests")) // MuxingApp
        return EBML.master(MKVID.info, children)
    }

    static func tracks(_ specs: [MKVTrackSpec]) -> [UInt8] {
        EBML.master(MKVID.tracks, specs.map(trackEntry))
    }

    static func trackEntry(_ s: MKVTrackSpec) -> [UInt8] {
        var c: [[UInt8]] = [
            EBML.uint(MKVID.trackNumber, UInt64(s.number)),
            EBML.uint(MKVID.trackUID, s.uid ?? UInt64(1000 + s.number)),
            EBML.uint(MKVID.trackType, s.type),
            EBML.string(MKVID.codecID, s.codecID),
        ]
        if let v = s.language { c.append(EBML.string(MKVID.language, v)) }
        if let v = s.languageBCP47 { c.append(EBML.string(MKVID.languageBCP47, v)) }
        if let v = s.name { c.append(EBML.string(MKVID.name, v)) }
        if let v = s.flagDefault { c.append(EBML.uint(MKVID.flagDefault, v)) }
        if let v = s.flagForced { c.append(EBML.uint(MKVID.flagForced, v)) }
        if let v = s.codecPrivate { c.append(EBML.element(MKVID.codecPrivate, v)) }
        if !s.encodings.isEmpty { c.append(EBML.master(MKVID.contentEncodings, s.encodings)) }
        return EBML.master(MKVID.trackEntry, c)
    }

    static func zlibEncoding(order: UInt64 = 0, scope: UInt64 = 1) -> [UInt8] {
        EBML.master(MKVID.contentEncoding, [
            EBML.uint(MKVID.contentEncodingOrder, order), EBML.uint(MKVID.contentEncodingScope, scope),
            EBML.uint(MKVID.contentEncodingType, 0),
            EBML.master(MKVID.contentCompression, [EBML.uint(MKVID.contentCompAlgo, 0)]),
        ])
    }

    static func headerStripping(_ stripped: [UInt8], order: UInt64 = 0) -> [UInt8] {
        EBML.master(MKVID.contentEncoding, [
            EBML.uint(MKVID.contentEncodingOrder, order), EBML.uint(MKVID.contentEncodingScope, 1),
            EBML.uint(MKVID.contentEncodingType, 0),
            EBML.master(MKVID.contentCompression, [EBML.uint(MKVID.contentCompAlgo, 3),
                                                   EBML.element(MKVID.contentCompSettings, stripped)]),
        ])
    }

    static func encryption() -> [UInt8] {
        EBML.master(MKVID.contentEncoding, [
            EBML.uint(MKVID.contentEncodingScope, 1), EBML.uint(MKVID.contentEncodingType, 1),
            EBML.master(0x5035, [EBML.uint(0x47E1, 5)]),
        ])
    }

    static func blockBody(track: Int, timestamp: Int16, flags: UInt8, payload: [UInt8]) -> [UInt8] {
        let ts = UInt16(bitPattern: timestamp)
        return EBML.vint(UInt64(track)) + [UInt8(ts >> 8), UInt8(ts & 0xFF), flags] + payload
    }

    static func simpleBlock(track: Int, timestamp: Int16, _ payload: [UInt8], flags: UInt8 = 0x80) -> [UInt8] {
        EBML.element(MKVID.simpleBlock, blockBody(track: track, timestamp: timestamp, flags: flags, payload: payload))
    }

    static func blockGroup(track: Int, timestamp: Int16, _ payload: [UInt8], duration: UInt64?,
                           addition: [UInt8]? = nil, durationFirst: Bool = false) -> [UInt8] {
        var children: [[UInt8]] = [EBML.element(MKVID.block, blockBody(track: track, timestamp: timestamp, flags: 0, payload: payload))]
        if let duration {
            let d = EBML.uint(MKVID.blockDuration, duration)
            if durationFirst { children.insert(d, at: 0) } else { children.append(d) }
        }
        if let addition {
            children.append(EBML.master(MKVID.blockAdditions, [
                EBML.master(MKVID.blockMore, [EBML.uint(MKVID.blockAddID, 1), EBML.element(MKVID.blockAdditional, addition)]),
            ]))
        }
        return EBML.master(MKVID.blockGroup, children)
    }

    static func cluster(timestamp: UInt64, _ blocks: [[UInt8]], unknownSize: Bool = false) -> [UInt8] {
        let children = [EBML.uint(MKVID.clusterTimestamp, timestamp)] + blocks
        return unknownSize ? EBML.unknownSizeMaster(MKVID.cluster, children) : EBML.master(MKVID.cluster, children)
    }

    static func file(docType: String = "matroska", unknownSegmentSize: Bool = false, _ children: [[UInt8]]) -> [UInt8] {
        let segment = unknownSegmentSize ? EBML.unknownSizeMaster(MKVID.segment, children) : EBML.master(MKVID.segment, children)
        return ebmlHeader(docType: docType) + segment
    }

    static func srtTrack(_ number: Int, language: String? = "eng", name: String? = nil, encodings: [[UInt8]] = []) -> MKVTrackSpec {
        MKVTrackSpec(number: number, codecID: "S_TEXT/UTF8", language: language, name: name, encodings: encodings)
    }

    static let videoTrack = MKVTrackSpec(number: 1, type: 1, codecID: "V_MPEG4/ISO/AVC", language: "und")
}
