import Foundation
@testable import SubtitleKit

/// zlib stream made of stored (uncompressed) blocks, for building compressed test payloads.
func zlibStored(_ data: [UInt8]) -> [UInt8] {
    var out: [UInt8] = [0x78, 0x01]
    var i = 0
    repeat {
        let n = min(65535, data.count - i)
        let final: UInt8 = i + n >= data.count ? 1 : 0
        out.append(final)
        out += [UInt8(n & 0xFF), UInt8(n >> 8), UInt8(~n & 0xFF), UInt8((~n >> 8) & 0xFF)]
        out += data[i..<(i + n)]
        i += n
    } while i < data.count
    let adler = Inflate.adler32(data)
    out += [UInt8(adler >> 24), UInt8((adler >> 16) & 0xFF), UInt8((adler >> 8) & 0xFF), UInt8(adler & 0xFF)]
    return out
}
