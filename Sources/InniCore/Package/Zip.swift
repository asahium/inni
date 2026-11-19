import Compression
import Foundation

/// Reads zip archives (stored and deflated entries, zip64 sizes) from a memory-mapped file.
public final class ZipReader {
    public struct Entry {
        public let name: String
        let method: UInt16
        let compressedSize: Int
        public let size: Int
        let localOffset: Int
    }

    let data: Data
    public private(set) var entries: [String: Entry] = [:]

    public init(url: URL) throws {
        data = try Data(contentsOf: url, options: .alwaysMapped)
        try readDirectory()
    }

    public init(data: Data) throws {
        self.data = data
        try readDirectory()
    }

    private func u16(_ o: Int) -> Int { Int(data[data.startIndex + o]) | Int(data[data.startIndex + o + 1]) << 8 }
    private func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
    private func u64(_ o: Int) -> Int { u32(o) | u32(o + 4) << 32 }

    private func readDirectory() throws {
        let n = data.count
        guard n >= 22 else { throw CollectionError("Not a zip file.") }
        var eocd = -1
        var i = n - 22
        while i >= max(0, n - 65_557) {
            if u32(i) == 0x0605_4B50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw CollectionError("Not a zip file.") }
        var count = u16(eocd + 10)
        var dirOffset = u32(eocd + 16)
        if (count == 0xFFFF || dirOffset == 0xFFFF_FFFF), eocd >= 20, u32(eocd - 20) == 0x0706_4B50 {
            let z64 = u64(eocd - 20 + 8)
            if u32(z64) == 0x0606_4B50 {
                count = u64(z64 + 32)
                dirOffset = u64(z64 + 48)
            }
        }
        var p = dirOffset
        for _ in 0..<count {
            guard p + 46 <= n, u32(p) == 0x0201_4B50 else { throw CollectionError("Damaged zip directory.") }
            let method = UInt16(u16(p + 10))
            var csize = u32(p + 20), usize = u32(p + 24)
            let nameLen = u16(p + 28), extraLen = u16(p + 30), commentLen = u16(p + 32)
            var local = u32(p + 42)
            let name = String(decoding: data[(data.startIndex + p + 46)..<(data.startIndex + p + 46 + nameLen)], as: UTF8.self)
            // zip64 extra field
            var e = p + 46 + nameLen
            let eEnd = e + extraLen
            while e + 4 <= eEnd {
                let id = u16(e), len = u16(e + 2)
                if id == 1 {
                    var q = e + 4
                    if usize == 0xFFFF_FFFF { usize = u64(q); q += 8 }
                    if csize == 0xFFFF_FFFF { csize = u64(q); q += 8 }
                    if local == 0xFFFF_FFFF { local = u64(q) }
                }
                e += 4 + len
            }
            entries[name] = Entry(name: name, method: method, compressedSize: csize, size: usize, localOffset: local)
            p = eEnd + commentLen
        }
    }

    public func contains(_ name: String) -> Bool { entries[name] != nil }

    public func read(_ name: String) throws -> Data {
        guard let e = entries[name] else { throw CollectionError("\(name) missing from the package.") }
        let lo = e.localOffset
        guard u32(lo) == 0x0403_4B50 else { throw CollectionError("Damaged zip entry \(name).") }
        let start = lo + 30 + u16(lo + 26) + u16(lo + 28)
        let raw = data[(data.startIndex + start)..<(data.startIndex + start + e.compressedSize)]
        switch e.method {
        case 0: return Data(raw)
        case 8: return try Inflate.raw(raw, expectedSize: e.size)
        default: throw CollectionError("Unsupported zip compression in \(name).")
        }
    }
}

enum Inflate {
    static func raw(_ input: Data, expectedSize: Int) throws -> Data {
        if expectedSize == 0 { return Data() }
        var out = Data(count: expectedSize)
        let written = input.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
            out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, expectedSize,
                                          src.bindMemory(to: UInt8.self).baseAddress!, input.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == expectedSize else { throw CollectionError("Couldn't inflate a zip entry.") }
        return out
    }

    static func deflate(_ input: Data) -> Data? {
        guard !input.isEmpty else { return Data() }
        let cap = input.count + input.count / 10 + 1024
        var out = Data(count: cap)
        let n = input.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
            out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
                compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, cap,
                                          src.bindMemory(to: UInt8.self).baseAddress!, input.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard n > 0 else { return nil }
        out.count = n
        return out
    }
}

/// Writes a zip file entry by entry, without holding the whole archive in memory.
public final class ZipWriter {
    private let handle: FileHandle
    private var offset = 0
    private var central = Data()
    private var count = 0

    public init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
    }

    public func add(_ name: String, _ content: Data, deflate: Bool = false) throws {
        let crc = CRC32.checksum(content)
        var payload = content
        var method: UInt16 = 0
        if deflate, let d = Inflate.deflate(content), d.count < content.count {
            payload = d
            method = 8
        }
        let nameData = Data(name.utf8)
        let big = payload.count >= 0xFFFF_FFFF || content.count >= 0xFFFF_FFFF || offset >= 0xFFFF_FFFF
        var zip64Extra = Data()
        if big {
            zip64Extra.le16(1)
            zip64Extra.le16(24)
            zip64Extra.le64(content.count)
            zip64Extra.le64(payload.count)
            zip64Extra.le64(offset)
        }
        var local = Data()
        local.le32(0x0403_4B50)
        local.le16(big ? 45 : 20)
        local.le16(0x0800)
        local.le16(Int(method))
        local.le16(0)
        local.le16(0x21)
        local.le32(crc)
        local.le32(big ? 0xFFFF_FFFF : payload.count)
        local.le32(big ? 0xFFFF_FFFF : content.count)
        local.le16(nameData.count)
        local.le16(big ? 20 : 0)
        local.append(nameData)
        if big {
            local.le16(1)
            local.le16(16)
            local.le64(content.count)
            local.le64(payload.count)
        }
        handle.write(local)
        handle.write(payload)

        var c = Data()
        c.le32(0x0201_4B50)
        c.le16(big ? 45 : 20)
        c.le16(big ? 45 : 20)
        c.le16(0x0800)
        c.le16(Int(method))
        c.le16(0)
        c.le16(0x21)
        c.le32(crc)
        c.le32(big ? 0xFFFF_FFFF : payload.count)
        c.le32(big ? 0xFFFF_FFFF : content.count)
        c.le16(nameData.count)
        c.le16(zip64Extra.count)
        c.le16(0)
        c.le16(0)
        c.le16(0)
        c.le32(0)
        c.le32(big ? 0xFFFF_FFFF : offset)
        c.append(nameData)
        c.append(zip64Extra)
        central.append(c)
        offset += local.count + payload.count
        count += 1
    }

    public func finish() throws {
        let dirOffset = offset
        handle.write(central)
        let needs64 = count >= 0xFFFF || dirOffset >= 0xFFFF_FFFF
        if needs64 {
            var z = Data()
            z.le32(0x0606_4B50)
            z.le64(44)
            z.le16(45)
            z.le16(45)
            z.le32(0)
            z.le32(0)
            z.le64(count)
            z.le64(count)
            z.le64(central.count)
            z.le64(dirOffset)
            z.le32(0x0706_4B50)
            z.le32(0)
            z.le64(dirOffset + central.count)
            z.le32(1)
            handle.write(z)
        }
        var e = Data()
        e.le32(0x0605_4B50)
        e.le16(0)
        e.le16(0)
        e.le16(min(count, 0xFFFF))
        e.le16(min(count, 0xFFFF))
        e.le32(central.count)
        e.le32(needs64 ? 0xFFFF_FFFF : dirOffset)
        e.le16(0)
        handle.write(e)
        try handle.close()
    }
}

extension Data {
    mutating func le16(_ v: Int) { append(UInt8(v & 0xFF)); append(UInt8((v >> 8) & 0xFF)) }
    mutating func le32(_ v: Int) { le16(v & 0xFFFF); le16((v >> 16) & 0xFFFF) }
    mutating func le32(_ v: UInt32) { le32(Int(v)) }
    mutating func le64(_ v: Int) { le32(v & 0xFFFF_FFFF); le32((v >> 32) & 0xFFFF_FFFF) }
}

enum CRC32 {
    static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum(_ d: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        d.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
            for b in p { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        }
        return c ^ 0xFFFF_FFFF
    }
}
