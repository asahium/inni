import Foundation

/// A protobuf message kept as raw wire fields, so fields Inni doesn't know about survive a read/modify/write.
public struct Proto: Equatable, Sendable {
    public enum Value: Equatable, Sendable {
        case varint(UInt64)
        case fixed64(UInt64)
        case bytes(Data)
        case fixed32(UInt32)
    }

    public var fields: [(number: Int, value: Value)] = []

    public init() {}

    public init(_ data: Data) {
        var r = Reader(data)
        while let (n, v) = r.next() { fields.append((n, v)) }
    }

    public static func == (a: Proto, b: Proto) -> Bool {
        a.fields.count == b.fields.count && zip(a.fields, b.fields).allSatisfy { $0.number == $1.number && $0.value == $1.value }
    }

    // MARK: Reading

    public func values(_ n: Int) -> [Value] { fields.filter { $0.number == n }.map(\.value) }
    public func has(_ n: Int) -> Bool { fields.contains { $0.number == n } }

    public func uint(_ n: Int) -> UInt64 {
        for f in fields.reversed() where f.number == n {
            switch f.value {
            case .varint(let v), .fixed64(let v): return v
            case .fixed32(let v): return UInt64(v)
            case .bytes: continue
            }
        }
        return 0
    }

    public func int(_ n: Int) -> Int { Int(truncatingIfNeeded: Int64(bitPattern: uint(n))) }
    /// sint32/sint64 (zigzag).
    public func sint(_ n: Int) -> Int { let u = uint(n); return Int(Int64(bitPattern: (u >> 1) ^ (0 &- (u & 1)))) }
    public func bool(_ n: Int) -> Bool { uint(n) != 0 }

    public func float(_ n: Int) -> Float {
        for f in fields.reversed() where f.number == n {
            if case .fixed32(let v) = f.value { return Float(bitPattern: v) }
        }
        return 0
    }

    public func optionalFloat(_ n: Int) -> Float? { has(n) ? float(n) : nil }
    public func optionalInt(_ n: Int) -> Int? { has(n) ? int(n) : nil }

    public func bytes(_ n: Int) -> Data {
        for f in fields.reversed() where f.number == n {
            if case .bytes(let d) = f.value { return d }
        }
        return Data()
    }

    public func string(_ n: Int) -> String { String(decoding: bytes(n), as: UTF8.self) }
    public func message(_ n: Int) -> Proto { Proto(bytes(n)) }
    public func messages(_ n: Int) -> [Proto] {
        values(n).compactMap { if case .bytes(let d) = $0 { return Proto(d) } else { return nil } }
    }

    /// Repeated float, packed or not.
    public func floats(_ n: Int) -> [Float] {
        var out: [Float] = []
        for v in values(n) {
            switch v {
            case .fixed32(let x): out.append(Float(bitPattern: x))
            case .bytes(let d):
                var i = d.startIndex
                while i + 4 <= d.endIndex {
                    let x = UInt32(d[i]) | UInt32(d[i + 1]) << 8 | UInt32(d[i + 2]) << 16 | UInt32(d[i + 3]) << 24
                    out.append(Float(bitPattern: x))
                    i += 4
                }
            default: break
            }
        }
        return out
    }

    /// Repeated uint32, packed or not.
    public func uints(_ n: Int) -> [UInt64] {
        var out: [UInt64] = []
        for v in values(n) {
            switch v {
            case .varint(let x): out.append(x)
            case .bytes(let d):
                var r = Reader(d)
                while let x = r.varint() { out.append(x) }
            default: break
            }
        }
        return out
    }

    // MARK: Writing (proto3: default values are omitted)

    public mutating func remove(_ n: Int) { fields.removeAll { $0.number == n } }

    private mutating func put(_ n: Int, _ v: Value?) {
        if let i = fields.firstIndex(where: { $0.number == n }) {
            var kept = fields.filter { $0.number != n }
            if let v { kept.insert((n, v), at: min(i, kept.count)) }
            fields = kept
        } else if let v {
            let at = fields.firstIndex { $0.number > n } ?? fields.count
            fields.insert((n, v), at: at)
        }
    }

    public mutating func setUInt(_ n: Int, _ v: UInt64) { put(n, v == 0 ? nil : .varint(v)) }
    public mutating func setInt(_ n: Int, _ v: Int) { put(n, v == 0 ? nil : .varint(UInt64(bitPattern: Int64(v)))) }
    public mutating func setSInt(_ n: Int, _ v: Int) {
        let z = UInt64(bitPattern: (Int64(v) << 1) ^ (Int64(v) >> 63))
        put(n, v == 0 ? nil : .varint(z))
    }
    public mutating func setBool(_ n: Int, _ v: Bool) { put(n, v ? .varint(1) : nil) }
    public mutating func setFloat(_ n: Int, _ v: Float) { put(n, v == 0 ? nil : .fixed32(v.bitPattern)) }
    public mutating func setOptionalFloat(_ n: Int, _ v: Float?) { put(n, v.map { .fixed32($0.bitPattern) }) }
    public mutating func setOptionalInt(_ n: Int, _ v: Int?) { put(n, v.map { .varint(UInt64(bitPattern: Int64($0))) }) }
    public mutating func setString(_ n: Int, _ v: String) { put(n, v.isEmpty ? nil : .bytes(Data(v.utf8))) }
    public mutating func setBytes(_ n: Int, _ v: Data) { put(n, v.isEmpty ? nil : .bytes(v)) }
    public mutating func setMessage(_ n: Int, _ m: Proto?) { put(n, m.map { .bytes($0.encoded) }) }

    public mutating func setMessages(_ n: Int, _ ms: [Proto]) {
        let at = fields.firstIndex { $0.number >= n } ?? fields.count
        remove(n)
        fields.insert(contentsOf: ms.map { (n, Value.bytes($0.encoded)) }, at: min(at, fields.count))
    }

    public mutating func setFloats(_ n: Int, _ v: [Float]) {
        var d = Data()
        for x in v { withUnsafeBytes(of: x.bitPattern.littleEndian) { d.append(contentsOf: $0) } }
        put(n, v.isEmpty ? nil : .bytes(d))
    }

    public mutating func setUInts(_ n: Int, _ v: [UInt64]) {
        var d = Data()
        for x in v { Proto.appendVarint(x, to: &d) }
        put(n, v.isEmpty ? nil : .bytes(d))
    }

    public var encoded: Data {
        var d = Data()
        for (n, v) in fields {
            switch v {
            case .varint(let x):
                Proto.appendVarint(UInt64(n << 3), to: &d)
                Proto.appendVarint(x, to: &d)
            case .fixed64(let x):
                Proto.appendVarint(UInt64(n << 3 | 1), to: &d)
                withUnsafeBytes(of: x.littleEndian) { d.append(contentsOf: $0) }
            case .bytes(let b):
                Proto.appendVarint(UInt64(n << 3 | 2), to: &d)
                Proto.appendVarint(UInt64(b.count), to: &d)
                d.append(b)
            case .fixed32(let x):
                Proto.appendVarint(UInt64(n << 3 | 5), to: &d)
                withUnsafeBytes(of: x.littleEndian) { d.append(contentsOf: $0) }
            }
        }
        return d
    }

    static func appendVarint(_ v: UInt64, to d: inout Data) {
        var v = v
        while v >= 0x80 {
            d.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        d.append(UInt8(v))
    }

    struct Reader {
        let data: Data
        var i: Data.Index

        init(_ data: Data) {
            self.data = data
            i = data.startIndex
        }

        mutating func varint() -> UInt64? {
            var shift: UInt64 = 0, out: UInt64 = 0
            while i < data.endIndex {
                let b = data[i]
                i += 1
                out |= UInt64(b & 0x7F) << shift
                if b < 0x80 { return out }
                shift += 7
                if shift > 63 { return nil }
            }
            return nil
        }

        mutating func next() -> (Int, Value)? {
            guard let key = varint() else { return nil }
            let n = Int(key >> 3)
            switch key & 7 {
            case 0:
                guard let v = varint() else { return nil }
                return (n, .varint(v))
            case 1:
                guard i + 8 <= data.endIndex else { return nil }
                var v: UInt64 = 0
                for k in 0..<8 { v |= UInt64(data[i + k]) << (8 * UInt64(k)) }
                i += 8
                return (n, .fixed64(v))
            case 2:
                guard let len = varint(), i + Int(len) <= data.endIndex else { return nil }
                let d = data.subdata(in: i..<(i + Int(len)))
                i += Int(len)
                return (n, .bytes(d))
            case 5:
                guard i + 4 <= data.endIndex else { return nil }
                var v: UInt32 = 0
                for k in 0..<4 { v |= UInt32(data[i + k]) << (8 * UInt32(k)) }
                i += 4
                return (n, .fixed32(v))
            default:
                return nil
            }
        }
    }
}
