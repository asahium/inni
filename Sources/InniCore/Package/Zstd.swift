import Foundation

/// Zstandard (RFC 8878) decoder, plus a writer that emits valid frames of raw blocks.
/// Anki's current package format compresses the collection and media with zstd.
public enum Zstd {
    public struct Error: Swift.Error, CustomStringConvertible {
        public let description: String
        init(_ d: String) { description = "zstd: " + d }
    }

    public static func decompress(_ data: Data) throws -> Data {
        var d = Decoder(Array(data))
        return Data(try d.run())
    }

    public static func isCompressed(_ data: Data) -> Bool {
        data.count >= 4 && data.starts(with: [0x28, 0xB5, 0x2F, 0xFD])
    }

    /// A frame holding `data` in uncompressed blocks: readable by any zstd decoder, no compression cost.
    public static func frame(_ data: Data) -> Data {
        var out = Data([0x28, 0xB5, 0x2F, 0xFD, 0xE0])
        out.le64(data.count)
        let block = 128 * 1024
        var i = 0
        repeat {
            let n = min(block, data.count - i)
            let last = i + n >= data.count ? 1 : 0
            let h = last | (n << 3)
            out.append(contentsOf: [UInt8(h & 0xFF), UInt8((h >> 8) & 0xFF), UInt8((h >> 16) & 0xFF)])
            out.append(data[(data.startIndex + i)..<(data.startIndex + i + n)])
            i += n
        } while i < data.count
        return out
    }

    // MARK: - Decoder

    struct FSETable {
        var accuracy: Int
        var symbol: [UInt8]
        var nbBits: [UInt8]
        var base: [UInt16]

        static func rle(_ s: UInt8) -> FSETable { FSETable(accuracy: 0, symbol: [s], nbBits: [0], base: [0]) }

        init(accuracy: Int, symbol: [UInt8], nbBits: [UInt8], base: [UInt16]) {
            self.accuracy = accuracy
            self.symbol = symbol
            self.nbBits = nbBits
            self.base = base
        }

        init(probs: [Int], accuracy al: Int) throws {
            let size = 1 << al
            accuracy = al
            symbol = Array(repeating: 0, count: size)
            nbBits = Array(repeating: 0, count: size)
            base = Array(repeating: 0, count: size)
            var high = size - 1
            var next = Array(repeating: 0, count: probs.count)
            for (s, p) in probs.enumerated() {
                if p == -1 {
                    symbol[high] = UInt8(s)
                    high -= 1
                    next[s] = 1
                } else {
                    next[s] = p
                }
            }
            var pos = 0
            let step = (size >> 1) + (size >> 3) + 3, mask = size - 1
            for (s, p) in probs.enumerated() where p > 0 {
                for _ in 0..<p {
                    symbol[pos] = UInt8(s)
                    repeat { pos = (pos + step) & mask } while pos > high
                }
            }
            guard pos == 0 else { throw Error("bad FSE distribution") }
            for u in 0..<size {
                let s = Int(symbol[u])
                let n = next[s]
                next[s] += 1
                let nb = al - (Int.bitWidth - 1 - n.leadingZeroBitCount)
                nbBits[u] = UInt8(nb)
                base[u] = UInt16((n << nb) - size)
            }
        }
    }

    struct HuffTable {
        var maxBits: Int
        var symbol: [UInt8]
        var nbBits: [UInt8]
    }

    /// Bits read backwards from the end of a slice, as zstd's entropy streams are.
    struct BackBits {
        let b: [UInt8]
        let start: Int
        let end: Int
        var p: Int

        init(_ b: [UInt8], _ start: Int, _ end: Int) throws {
            guard end > start, b[end - 1] != 0 else { throw Error("bad bitstream") }
            self.b = b
            self.start = start
            self.end = end
            let last = Int(b[end - 1])
            p = (end - start - 1) * 8 + (7 - (UInt8(last).leadingZeroBitCount))
        }

        @inline(__always) private func word(_ bit: Int) -> UInt64 {
            let byte = bit >> 3
            var v: UInt64 = 0
            let base = start + byte
            let avail = min(8, end - base)
            if avail == 8 {
                v = UInt64(b[base]) | UInt64(b[base + 1]) << 8 | UInt64(b[base + 2]) << 16 | UInt64(b[base + 3]) << 24
                    | UInt64(b[base + 4]) << 32 | UInt64(b[base + 5]) << 40 | UInt64(b[base + 6]) << 48 | UInt64(b[base + 7]) << 56
            } else if avail > 0 {
                for k in 0..<avail { v |= UInt64(b[base + k]) << (8 * UInt64(k)) }
            }
            return v >> UInt64(bit & 7)
        }

        @inline(__always) func peek(_ n: Int) -> Int {
            guard n > 0 else { return 0 }
            let lo = p - n
            if lo >= 0 { return Int(word(lo) & ((1 << UInt64(n)) - 1)) }
            guard p > 0 else { return 0 }
            return Int(word(0) & ((1 << UInt64(p)) - 1)) << (-lo)
        }

        @inline(__always) mutating func read(_ n: Int) -> Int {
            let v = peek(n)
            p -= n
            return v
        }

        var overflowed: Bool { p < 0 }
    }

    struct Decoder {
        let src: [UInt8]
        var pos = 0
        var out: [UInt8] = []
        var frameStart = 0
        var rep = [1, 4, 8]
        var huff: HuffTable?
        var ll: FSETable?
        var of: FSETable?
        var ml: FSETable?

        init(_ src: [UInt8]) { self.src = src }

        mutating func run() throws -> [UInt8] {
            while pos + 4 <= src.count {
                let magic = u32(pos)
                if magic & 0xFFFF_FFF0 == 0x184D_2A50 {
                    pos += 8 + u32(pos + 4)
                    continue
                }
                guard magic == 0xFD2F_B528 else { throw Error("bad magic") }
                pos += 4
                try frame()
            }
            return out
        }

        func u32(_ i: Int) -> Int {
            Int(src[i]) | Int(src[i + 1]) << 8 | Int(src[i + 2]) << 16 | Int(src[i + 3]) << 24
        }

        mutating func byte() throws -> Int {
            guard pos < src.count else { throw Error("truncated") }
            defer { pos += 1 }
            return Int(src[pos])
        }

        mutating func frame() throws {
            let fhd = try byte()
            let fcsFlag = fhd >> 6, single = (fhd >> 5) & 1, checksum = (fhd >> 2) & 1, dictFlag = fhd & 3
            if single == 0 { pos += 1 }
            let dictSize = [0, 1, 2, 4][dictFlag]
            var dictID = 0
            for k in 0..<dictSize { dictID |= try byte() << (8 * k) }
            guard dictID == 0 else { throw Error("dictionaries are not supported") }
            let fcsSize = fcsFlag == 0 ? (single == 1 ? 1 : 0) : [0, 2, 4, 8][fcsFlag]
            var fcs = 0
            for k in 0..<fcsSize { fcs |= try byte() << (8 * k) }
            if fcsSize == 2 { fcs += 256 }
            if fcs > 0, fcs < 1 << 31 { out.reserveCapacity(out.count + fcs) }
            frameStart = out.count
            rep = [1, 4, 8]
            huff = nil
            ll = nil
            of = nil
            ml = nil
            while true {
                guard pos + 3 <= src.count else { throw Error("truncated block") }
                let h = Int(src[pos]) | Int(src[pos + 1]) << 8 | Int(src[pos + 2]) << 16
                pos += 3
                let last = h & 1, type = (h >> 1) & 3, size = h >> 3
                switch type {
                case 0:
                    guard pos + size <= src.count else { throw Error("truncated raw block") }
                    out.append(contentsOf: src[pos..<(pos + size)])
                    pos += size
                case 1:
                    let b = try byte()
                    out.append(contentsOf: repeatElement(UInt8(b), count: size))
                case 2:
                    guard pos + size <= src.count else { throw Error("truncated block") }
                    try compressedBlock(pos, pos + size)
                    pos += size
                default:
                    throw Error("reserved block type")
                }
                if last == 1 { break }
            }
            if checksum == 1 { pos += 4 }
        }

        // MARK: Blocks

        mutating func compressedBlock(_ start: Int, _ end: Int) throws {
            var i = start
            let literals = try readLiterals(&i, end)
            try sequences(i, end, literals)
        }

        mutating func readLiterals(_ i: inout Int, _ end: Int) throws -> [UInt8] {
            let b0 = Int(src[i])
            let type = b0 & 3, sf = (b0 >> 2) & 3
            if type < 2 {
                var size: Int, hdr: Int
                switch sf {
                case 1:
                    size = (b0 >> 4) + (Int(src[i + 1]) << 4)
                    hdr = 2
                case 3:
                    size = (b0 >> 4) + (Int(src[i + 1]) << 4) + (Int(src[i + 2]) << 12)
                    hdr = 3
                default:
                    size = b0 >> 3
                    hdr = 1
                }
                i += hdr
                if type == 0 {
                    guard i + size <= end else { throw Error("truncated literals") }
                    defer { i += size }
                    return Array(src[i..<(i + size)])
                }
                defer { i += 1 }
                return Array(repeating: src[i], count: size)
            }
            let (hdr, bits, streams) = sf == 0 ? (3, 10, 1) : sf == 1 ? (3, 10, 4) : sf == 2 ? (4, 14, 4) : (5, 18, 4)
            var h = 0
            for k in 0..<hdr { h |= Int(src[i + k]) << (8 * k) }
            let mask = (1 << bits) - 1
            let regen = (h >> 4) & mask
            let comp = (h >> (4 + bits)) & mask
            i += hdr
            var streamStart = i
            let streamEnd = i + comp
            guard streamEnd <= end else { throw Error("truncated literals") }
            if type == 2 {
                streamStart = try readHuffmanTable(i, streamEnd)
            }
            guard let table = huff else { throw Error("missing Huffman table") }
            i = streamEnd
            var outLits = [UInt8]()
            outLits.reserveCapacity(regen)
            if streams == 1 {
                try decodeHuff(table, streamStart, streamEnd, regen, into: &outLits)
            } else {
                let s1 = Int(src[streamStart]) | Int(src[streamStart + 1]) << 8
                let s2 = Int(src[streamStart + 2]) | Int(src[streamStart + 3]) << 8
                let s3 = Int(src[streamStart + 4]) | Int(src[streamStart + 5]) << 8
                var p = streamStart + 6
                let per = (regen + 3) / 4
                let sizes = [s1, s2, s3, streamEnd - p - s1 - s2 - s3]
                guard sizes[3] >= 0 else { throw Error("bad jump table") }
                for k in 0..<4 {
                    let n = k < 3 ? per : regen - 3 * per
                    try decodeHuff(table, p, p + sizes[k], n, into: &outLits)
                    p += sizes[k]
                }
            }
            return outLits
        }

        func decodeHuff(_ t: HuffTable, _ start: Int, _ end: Int, _ count: Int, into out: inout [UInt8]) throws {
            guard count > 0 else { return }
            var bits = try BackBits(src, start, end)
            for _ in 0..<count {
                let v = bits.peek(t.maxBits)
                out.append(t.symbol[v])
                bits.p -= Int(t.nbBits[v])
            }
            guard bits.p == 0 else { throw Error("Huffman stream not fully consumed") }
        }

        /// Returns the position after the table description.
        mutating func readHuffmanTable(_ start: Int, _ end: Int) throws -> Int {
            let hb = Int(src[start])
            var weights: [Int] = []
            var next: Int
            if hb < 128 {
                next = start + 1 + hb
                guard next <= end else { throw Error("truncated Huffman weights") }
                let (table, used) = try readFSEDescription(start + 1, maxSymbol: 255, maxAccuracy: 6)
                var bits = try BackBits(src, start + 1 + used, next)
                var s1 = bits.read(table.accuracy), s2 = bits.read(table.accuracy)
                while weights.count < 255 {
                    weights.append(Int(table.symbol[s1]))
                    s1 = Int(table.base[s1]) + bits.read(Int(table.nbBits[s1]))
                    if bits.overflowed {
                        weights.append(Int(table.symbol[s2]))
                        break
                    }
                    weights.append(Int(table.symbol[s2]))
                    s2 = Int(table.base[s2]) + bits.read(Int(table.nbBits[s2]))
                    if bits.overflowed {
                        weights.append(Int(table.symbol[s1]))
                        break
                    }
                }
            } else {
                let n = hb - 127
                next = start + 1 + (n + 1) / 2
                guard next <= end else { throw Error("truncated Huffman weights") }
                for k in 0..<n {
                    let b = Int(src[start + 1 + k / 2])
                    weights.append(k % 2 == 0 ? b >> 4 : b & 0xF)
                }
            }
            var sum = 0
            for w in weights where w > 0 { sum += 1 << (w - 1) }
            guard sum > 0 else { throw Error("bad Huffman weights") }
            let maxBits = Int.bitWidth - sum.leadingZeroBitCount
            let rest = (1 << maxBits) - sum
            guard rest > 0, rest & (rest - 1) == 0 else { throw Error("bad Huffman weights") }
            weights.append(Int.bitWidth - rest.leadingZeroBitCount)
            guard maxBits <= 11 else { throw Error("Huffman table too deep") }
            let size = 1 << maxBits
            var symbol = [UInt8](repeating: 0, count: size), nb = [UInt8](repeating: 0, count: size)
            var p = 0
            for w in 1...maxBits {
                for (s, sw) in weights.enumerated() where sw == w {
                    let len = 1 << (w - 1)
                    for k in p..<(p + len) {
                        symbol[k] = UInt8(s)
                        nb[k] = UInt8(maxBits + 1 - w)
                    }
                    p += len
                }
            }
            huff = HuffTable(maxBits: maxBits, symbol: symbol, nbBits: nb)
            return next
        }

        /// FSE table description; returns the table and bytes used.
        func readFSEDescription(_ start: Int, maxSymbol: Int, maxAccuracy: Int) throws -> (FSETable, Int) {
            var bitPos = 0
            func peek(_ n: Int) -> Int {
                var v = 0
                for k in 0..<n {
                    let bit = bitPos + k
                    let idx = start + bit >> 3
                    if idx < src.count, (src[idx] >> UInt8(bit & 7)) & 1 == 1 { v |= 1 << k }
                }
                return v
            }
            func read(_ n: Int) -> Int {
                let v = peek(n)
                bitPos += n
                return v
            }
            let al = read(4) + 5
            guard al <= maxAccuracy else { throw Error("FSE accuracy too high") }
            var remaining = (1 << al) + 1
            var threshold = 1 << al
            var nbBits = al + 1
            var probs: [Int] = []
            while remaining > 1 && probs.count <= maxSymbol {
                let maxV = 2 * threshold - 1 - remaining
                var count: Int
                let low = peek(nbBits - 1)
                if low < maxV {
                    count = low
                    bitPos += nbBits - 1
                } else {
                    count = peek(nbBits)
                    if count >= threshold { count -= maxV }
                    bitPos += nbBits
                }
                count -= 1
                remaining -= abs(count)
                probs.append(count)
                if count == 0 {
                    var r = read(2)
                    while r == 3 {
                        probs += [0, 0, 0]
                        r = read(2)
                    }
                    probs += Array(repeating: 0, count: r)
                }
                while remaining < threshold && nbBits > 1 {
                    nbBits -= 1
                    threshold >>= 1
                }
            }
            guard remaining == 1, probs.count <= maxSymbol + 1 else { throw Error("bad FSE description") }
            return (try FSETable(probs: probs, accuracy: al), (bitPos + 7) / 8)
        }

        // MARK: Sequences

        static let llBase: [Int] = Array(0...15) + [16, 18, 20, 22, 24, 28, 32, 40, 48, 64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384, 32768, 65536]
        static let llBits: [Int] = Array(repeating: 0, count: 16) + [1, 1, 1, 1, 2, 2, 3, 3, 4, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]
        static let mlBase: [Int] = Array(3...34) + [35, 37, 39, 41, 43, 47, 51, 59, 67, 83, 99, 131, 259, 515, 1027, 2051, 4099, 8195, 16387, 32771, 65539]
        static let mlBits: [Int] = Array(repeating: 0, count: 32) + [1, 1, 1, 1, 2, 2, 3, 3, 4, 4, 5, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]

        static let llDefault = try! FSETable(probs: [4, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2, 2, 3, 2, 1, 1, 1, 1, 1, -1, -1, -1, -1], accuracy: 6)
        static let mlDefault = try! FSETable(probs: [1, 4, 3, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1, -1, -1], accuracy: 6)
        static let ofDefault = try! FSETable(probs: [1, 1, 1, 1, 1, 1, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1], accuracy: 5)

        mutating func table(_ mode: Int, _ i: inout Int, previous: FSETable?, def: FSETable, maxSymbol: Int, maxAccuracy: Int) throws -> FSETable {
            switch mode {
            case 0: return def
            case 1:
                let s = src[i]
                i += 1
                return .rle(s)
            case 2:
                let (t, used) = try readFSEDescription(i, maxSymbol: maxSymbol, maxAccuracy: maxAccuracy)
                i += used
                return t
            default:
                guard let p = previous else { throw Error("repeat mode without a table") }
                return p
            }
        }

        mutating func sequences(_ start: Int, _ end: Int, _ literals: [UInt8]) throws {
            var i = start
            guard i < end else {
                out.append(contentsOf: literals)
                return
            }
            let b0 = Int(src[i])
            var nbSeq: Int
            if b0 == 0 {
                out.append(contentsOf: literals)
                return
            } else if b0 < 128 {
                nbSeq = b0
                i += 1
            } else if b0 < 255 {
                nbSeq = ((b0 - 128) << 8) + Int(src[i + 1])
                i += 2
            } else {
                nbSeq = Int(src[i + 1]) + (Int(src[i + 2]) << 8) + 0x7F00
                i += 3
            }
            let modes = Int(src[i])
            i += 1
            let llT = try table(modes >> 6, &i, previous: ll, def: Decoder.llDefault, maxSymbol: 35, maxAccuracy: 9)
            let ofT = try table((modes >> 4) & 3, &i, previous: of, def: Decoder.ofDefault, maxSymbol: 31, maxAccuracy: 8)
            let mlT = try table((modes >> 2) & 3, &i, previous: ml, def: Decoder.mlDefault, maxSymbol: 52, maxAccuracy: 9)
            ll = llT
            of = ofT
            ml = mlT

            var bits = try BackBits(src, i, end)
            var llS = bits.read(llT.accuracy), ofS = bits.read(ofT.accuracy), mlS = bits.read(mlT.accuracy)
            var litPos = 0
            for k in 0..<nbSeq {
                let ofCode = Int(ofT.symbol[ofS]), llCode = Int(llT.symbol[llS]), mlCode = Int(mlT.symbol[mlS])
                guard llCode < 36, mlCode < 53, ofCode < 32 else { throw Error("bad sequence code") }
                let ofValue = (1 << ofCode) + bits.read(ofCode)
                let mlValue = Decoder.mlBase[mlCode] + bits.read(Decoder.mlBits[mlCode])
                let llValue = Decoder.llBase[llCode] + bits.read(Decoder.llBits[llCode])

                var offset: Int
                if ofValue > 3 {
                    offset = ofValue - 3
                    rep[2] = rep[1]
                    rep[1] = rep[0]
                    rep[0] = offset
                } else {
                    let idx = ofValue - 1 + (llValue == 0 ? 1 : 0)
                    if idx == 0 {
                        offset = rep[0]
                    } else {
                        offset = idx == 3 ? rep[0] - 1 : rep[idx]
                        if idx != 1 { rep[2] = rep[1] }
                        rep[1] = rep[0]
                        rep[0] = offset
                    }
                }

                if k != nbSeq - 1 {
                    llS = Int(llT.base[llS]) + bits.read(Int(llT.nbBits[llS]))
                    mlS = Int(mlT.base[mlS]) + bits.read(Int(mlT.nbBits[mlS]))
                    ofS = Int(ofT.base[ofS]) + bits.read(Int(ofT.nbBits[ofS]))
                }

                guard litPos + llValue <= literals.count else { throw Error("literal overrun") }
                out.append(contentsOf: literals[litPos..<(litPos + llValue)])
                litPos += llValue
                let n = out.count
                let from = n - offset
                guard offset > 0, from >= 0 else { throw Error("bad match offset") }
                // Appending a slice of `out` to itself would copy the whole buffer each time.
                out.append(contentsOf: repeatElement(0, count: mlValue))
                out.withUnsafeMutableBufferPointer { p in
                    let base = p.baseAddress!
                    if offset >= mlValue {
                        (base + n).update(from: base + from, count: mlValue)
                    } else {
                        for j in 0..<mlValue { base[n + j] = base[from + j] }
                    }
                }
            }
            guard bits.p == 0 else { throw Error("sequence stream not fully consumed") }
            out.append(contentsOf: literals[litPos...])
        }
    }
}
