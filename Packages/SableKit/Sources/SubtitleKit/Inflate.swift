import Foundation

// OWNER: subtitles-core agent.
// Small pure-Swift DEFLATE decoder (RFC 1951) with zlib framing (RFC 1950): stored, fixed
// and dynamic Huffman blocks. Used for Matroska ContentCompression (ContentCompAlgo 0).
// Modelled on Mark Adler's puff.c: canonical Huffman decoding, no tables beyond counts/symbols.
// Fast enough for subtitle payloads (kilobytes), and bounded by `maxOutputSize`.

enum InflateError: Error, Equatable {
    case truncated
    case invalidHeader
    case presetDictionary
    case invalidBlockType
    case invalidStoredLength
    case invalidCode
    case distanceTooFar
    case outputLimitExceeded
    case checksumMismatch
}

enum Inflate {
    /// Decompresses zlib data; falls back to raw DEFLATE when there is no valid zlib header.
    static func decompress(_ input: [UInt8], maxOutputSize: Int = 64 << 20) throws -> [UInt8] {
        if hasZlibHeader(input) { return try zlibDecompress(input, maxOutputSize: maxOutputSize) }
        return try inflateRaw(input, maxOutputSize: maxOutputSize).output
    }

    static func hasZlibHeader(_ input: [UInt8]) -> Bool {
        guard input.count >= 2 else { return false }
        let cmf = Int(input[0]), flg = Int(input[1])
        return cmf & 0x0F == 8 && (cmf >> 4) <= 7 && (cmf * 256 + flg) % 31 == 0
    }

    /// RFC 1950 stream. The Adler-32 trailer is verified when present.
    static func zlibDecompress(_ input: [UInt8], maxOutputSize: Int = 64 << 20) throws -> [UInt8] {
        guard hasZlibHeader(input) else { throw InflateError.invalidHeader }
        guard input[1] & 0x20 == 0 else { throw InflateError.presetDictionary }
        let (output, end) = try inflateRaw(input, start: 2, maxOutputSize: maxOutputSize)
        if end + 4 <= input.count {
            let expected = UInt32(input[end]) << 24 | UInt32(input[end + 1]) << 16 | UInt32(input[end + 2]) << 8 | UInt32(input[end + 3])
            guard adler32(output) == expected else { throw InflateError.checksumMismatch }
        }
        return output
    }

    static func adler32(_ data: [UInt8]) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        var i = 0
        while i < data.count {
            let chunkEnd = min(i + 5552, data.count)
            while i < chunkEnd {
                a += UInt32(data[i])
                b += a
                i += 1
            }
            a %= 65521
            b %= 65521
        }
        return b << 16 | a
    }

    /// Raw DEFLATE starting at `start`. Returns the output and the index of the first byte after
    /// the final block (byte-aligned).
    static func inflateRaw(_ input: [UInt8], start: Int = 0, maxOutputSize: Int = 64 << 20) throws -> (output: [UInt8], end: Int) {
        var state = InflateState(input: input, position: start, maxOutput: maxOutputSize)
        var last = false
        repeat {
            last = try state.bits(1) == 1
            switch try state.bits(2) {
            case 0: try state.stored()
            case 1: try state.codes(Inflate.fixedLength, Inflate.fixedDistance)
            case 2: try state.dynamic()
            default: throw InflateError.invalidBlockType
            }
        } while !last
        return (state.output, state.position)
    }

    static let lengthBase: [Int] = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    static let lengthExtra: [Int] = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    static let distanceBase: [Int] = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537,
                                      2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
    static let distanceExtra: [Int] = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]

    static let fixedLength: Huffman = {
        var lengths = [Int](repeating: 8, count: 288)
        for i in 144..<256 { lengths[i] = 9 }
        for i in 256..<280 { lengths[i] = 7 }
        return Huffman.build(lengths[...]).huffman
    }()

    static let fixedDistance: Huffman = Huffman.build([Int](repeating: 5, count: 30)[...]).huffman
}

/// Canonical Huffman code: number of codes per length and symbols ordered by code.
struct Huffman {
    var count: [Int]
    var symbol: [Int]

    /// Builds the code from per-symbol code lengths; `left` > 0 means the code is incomplete,
    /// < 0 over-subscribed (invalid).
    static func build(_ lengths: ArraySlice<Int>) -> (huffman: Huffman, left: Int) {
        var count = [Int](repeating: 0, count: 16)
        for l in lengths { count[l] += 1 }
        var symbol = [Int](repeating: 0, count: lengths.count)
        if count[0] == lengths.count { return (Huffman(count: count, symbol: symbol), 0) }
        var left = 1
        for len in 1..<16 {
            left <<= 1
            left -= count[len]
            if left < 0 { return (Huffman(count: count, symbol: symbol), left) }
        }
        var offsets = [Int](repeating: 0, count: 16)
        for len in 1..<15 { offsets[len + 1] = offsets[len] + count[len] }
        for (sym, l) in lengths.enumerated() where l != 0 {
            symbol[offsets[l]] = sym
            offsets[l] += 1
        }
        return (Huffman(count: count, symbol: symbol), left)
    }
}

private struct InflateState {
    let input: [UInt8]
    var position: Int
    let maxOutput: Int
    var bitBuffer: UInt32 = 0
    var bitCount = 0
    var output: [UInt8] = []

    init(input: [UInt8], position: Int, maxOutput: Int) {
        self.input = input
        self.position = position
        self.maxOutput = maxOutput
        output.reserveCapacity(min(maxOutput, max(64, input.count * 4)))
    }

    mutating func bits(_ need: Int) throws -> Int {
        var value = bitBuffer
        while bitCount < need {
            guard position < input.count else { throw InflateError.truncated }
            value |= UInt32(input[position]) << UInt32(bitCount)
            position += 1
            bitCount += 8
        }
        bitBuffer = need >= 32 ? 0 : value >> UInt32(need)
        bitCount -= need
        return Int(value & ((1 << UInt32(need)) - 1))
    }

    mutating func stored() throws {
        bitBuffer = 0
        bitCount = 0
        guard position + 4 <= input.count else { throw InflateError.truncated }
        let len = Int(input[position]) | Int(input[position + 1]) << 8
        let nlen = Int(input[position + 2]) | Int(input[position + 3]) << 8
        guard len == (~nlen & 0xFFFF) else { throw InflateError.invalidStoredLength }
        position += 4
        guard position + len <= input.count else { throw InflateError.truncated }
        guard output.count + len <= maxOutput else { throw InflateError.outputLimitExceeded }
        output.append(contentsOf: input[position..<(position + len)])
        position += len
    }

    mutating func decode(_ h: Huffman) throws -> Int {
        var code = 0, first = 0, index = 0
        for len in 1..<16 {
            code |= try bits(1)
            let count = h.count[len]
            if code - count < first { return h.symbol[index + (code - first)] }
            index += count
            first += count
            first <<= 1
            code <<= 1
        }
        throw InflateError.invalidCode
    }

    mutating func codes(_ lengthCode: Huffman, _ distanceCode: Huffman) throws {
        while true {
            let symbol = try decode(lengthCode)
            if symbol < 256 {
                guard output.count < maxOutput else { throw InflateError.outputLimitExceeded }
                output.append(UInt8(symbol))
                continue
            }
            if symbol == 256 { return }
            let ls = symbol - 257
            guard ls < 29 else { throw InflateError.invalidCode }
            let length = Inflate.lengthBase[ls] + (try bits(Inflate.lengthExtra[ls]))
            let ds = try decode(distanceCode)
            guard ds < 30 else { throw InflateError.invalidCode }
            let distance = Inflate.distanceBase[ds] + (try bits(Inflate.distanceExtra[ds]))
            guard distance <= output.count else { throw InflateError.distanceTooFar }
            guard output.count + length <= maxOutput else { throw InflateError.outputLimitExceeded }
            var from = output.count - distance
            for _ in 0..<length {
                output.append(output[from])
                from += 1
            }
        }
    }

    mutating func dynamic() throws {
        let nlen = try bits(5) + 257
        let ndist = try bits(5) + 1
        let ncode = try bits(4) + 4
        guard nlen <= 286, ndist <= 30 else { throw InflateError.invalidCode }
        let order = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]
        var lengths = [Int](repeating: 0, count: 320)
        for i in 0..<ncode { lengths[order[i]] = try bits(3) }
        let (lencode, left) = Huffman.build(lengths[0..<19])
        guard left == 0 else { throw InflateError.invalidCode }

        var index = 0
        while index < nlen + ndist {
            var symbol = try decode(lencode)
            if symbol < 16 {
                lengths[index] = symbol
                index += 1
                continue
            }
            var len = 0
            if symbol == 16 {
                guard index > 0 else { throw InflateError.invalidCode }
                len = lengths[index - 1]
                symbol = 3 + (try bits(2))
            } else if symbol == 17 {
                symbol = 3 + (try bits(3))
            } else {
                symbol = 11 + (try bits(7))
            }
            guard index + symbol <= nlen + ndist else { throw InflateError.invalidCode }
            for _ in 0..<symbol {
                lengths[index] = len
                index += 1
            }
        }
        guard lengths[256] != 0 else { throw InflateError.invalidCode }

        let (lengthCode, lengthLeft) = Huffman.build(lengths[0..<nlen])
        // Incomplete codes are only allowed for a single length-1 code.
        guard lengthLeft >= 0, lengthLeft == 0 || nlen - lengthCode.count[0] == 1 else { throw InflateError.invalidCode }
        let (distanceCode, distanceLeft) = Huffman.build(lengths[nlen..<(nlen + ndist)])
        guard distanceLeft >= 0, distanceLeft == 0 || ndist - distanceCode.count[0] == 1 else { throw InflateError.invalidCode }
        try codes(lengthCode, distanceCode)
    }
}
