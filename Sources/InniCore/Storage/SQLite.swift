import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public struct SQLiteError: Error, CustomStringConvertible {
    public let code: Int32
    public let description: String
    public var isBusy: Bool { code == SQLITE_BUSY || code == SQLITE_LOCKED }
}

/// A thin SQLite connection. Registers the `unicase` collation Anki's schema refers to and a `regexp` function for searches.
public final class SQLiteDB {
    private(set) var handle: OpaquePointer?
    public let path: String

    public init(path: String, readOnly: Bool = false) throws {
        self.path = path
        let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        let rc = sqlite3_open_v2(path, &handle, flags | SQLITE_OPEN_FULLMUTEX, nil)
        guard rc == SQLITE_OK else {
            defer { sqlite3_close_v2(handle) }
            throw SQLiteError(code: rc, description: "open \(path): \(String(cString: sqlite3_errmsg(handle)))")
        }
        sqlite3_busy_timeout(handle, 2000)
        registerUnicase()
        registerRegexp()
    }

    deinit { sqlite3_close_v2(handle) }

    public func close() {
        sqlite3_close_v2(handle)
        handle = nil
    }

    private func registerUnicase() {
        sqlite3_create_collation_v2(handle, "unicase", SQLITE_UTF8, nil, { _, l1, p1, l2, p2 in
            let a = String(decoding: UnsafeRawBufferPointer(start: p1, count: Int(l1)), as: UTF8.self)
            let b = String(decoding: UnsafeRawBufferPointer(start: p2, count: Int(l2)), as: UTF8.self)
            switch a.compare(b, options: [.caseInsensitive, .literal]) {
            case .orderedAscending: return -1
            case .orderedDescending: return 1
            case .orderedSame: return 0
            }
        }, nil)
    }

    private func registerRegexp() {
        sqlite3_create_function_v2(handle, "regexp", 2, SQLITE_UTF8 | SQLITE_DETERMINISTIC, nil, { ctx, _, argv in
            guard let argv, let p = sqlite3_value_text(argv[0]), let t = sqlite3_value_text(argv[1]) else {
                sqlite3_result_int(ctx, 0)
                return
            }
            let pattern = String(cString: p), text = String(cString: t)
            let re = RegexCache.shared.regex(pattern)
            let hit = re?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
            sqlite3_result_int(ctx, hit ? 1 : 0)
        }, nil, nil, nil)
        // field_at_index(flds, idx) → one field of a note's \x1f-joined fields.
        sqlite3_create_function_v2(handle, "field_at_index", 2, SQLITE_UTF8 | SQLITE_DETERMINISTIC, nil, { ctx, _, argv in
            guard let argv, let p = sqlite3_value_text(argv[0]) else {
                sqlite3_result_null(ctx)
                return
            }
            let idx = Int(sqlite3_value_int64(argv[1]))
            let parts = String(cString: p).split(separator: "\u{1f}", omittingEmptySubsequences: false)
            if idx >= 0, idx < parts.count {
                sqlite3_result_text(ctx, String(parts[idx]), -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_result_null(ctx)
            }
        }, nil, nil, nil)
    }

    public func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &err)
        guard rc == SQLITE_OK else {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw SQLiteError(code: rc, description: msg)
        }
    }

    public func prepare(_ sql: String) throws -> Statement {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let s = stmt else {
            throw SQLiteError(code: rc, description: "\(String(cString: sqlite3_errmsg(handle))) in \(sql)")
        }
        return Statement(s, db: self)
    }

    /// Runs a statement for its side effects.
    public func run(_ sql: String, _ values: Any?...) throws {
        try prepare(sql).bind(values).run()
    }

    public func scalar(_ sql: String, _ values: Any?...) throws -> Int? {
        let s = try prepare(sql).bind(values)
        return try s.step() ? s.int(0) : nil
    }

    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("SAVEPOINT inni")
        do {
            let r = try body()
            try exec("RELEASE inni")
            return r
        } catch {
            try? exec("ROLLBACK TO inni")
            try? exec("RELEASE inni")
            throw error
        }
    }

    public var changes: Int { Int(sqlite3_changes(handle)) }

    var lastError: String { String(cString: sqlite3_errmsg(handle)) }
}

public final class Statement {
    private let stmt: OpaquePointer
    private unowned let db: SQLiteDB

    init(_ stmt: OpaquePointer, db: SQLiteDB) {
        self.stmt = stmt
        self.db = db
    }

    deinit { sqlite3_finalize(stmt) }

    @discardableResult
    public func bind(_ values: [Any?]) -> Statement {
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        for (i, v) in values.enumerated() {
            let idx = Int32(i + 1)
            switch v {
            case nil: sqlite3_bind_null(stmt, idx)
            case let s as String: sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT)
            case let n as Int: sqlite3_bind_int64(stmt, idx, Int64(n))
            case let n as Int64: sqlite3_bind_int64(stmt, idx, n)
            case let n as Int32: sqlite3_bind_int64(stmt, idx, Int64(n))
            case let n as UInt32: sqlite3_bind_int64(stmt, idx, Int64(n))
            case let d as Double: sqlite3_bind_double(stmt, idx, d)
            case let b as Bool: sqlite3_bind_int(stmt, idx, b ? 1 : 0)
            case let d as Data:
                _ = d.withUnsafeBytes { sqlite3_bind_blob(stmt, idx, $0.baseAddress ?? UnsafeRawPointer(bitPattern: 1), Int32($0.count), SQLITE_TRANSIENT) }
            default: sqlite3_bind_null(stmt, idx)
            }
        }
        return self
    }

    public func step() throws -> Bool {
        let rc = sqlite3_step(stmt)
        if rc == SQLITE_ROW { return true }
        if rc == SQLITE_DONE { return false }
        throw SQLiteError(code: rc, description: db.lastError)
    }

    public func run() throws { while try step() {} }

    public func string(_ i: Int32) -> String? {
        guard let p = sqlite3_column_text(stmt, i) else { return nil }
        return String(cString: p)
    }

    public func text(_ i: Int32) -> String { string(i) ?? "" }

    public func int(_ i: Int32) -> Int? {
        sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, i))
    }

    public func integer(_ i: Int32) -> Int { Int(sqlite3_column_int64(stmt, i)) }

    public func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }

    public func blob(_ i: Int32) -> Data {
        let n = Int(sqlite3_column_bytes(stmt, i))
        guard n > 0, let p = sqlite3_column_blob(stmt, i) else { return Data() }
        return Data(bytes: p, count: n)
    }

    /// All rows mapped by `row`.
    public func map<T>(_ row: (Statement) throws -> T) throws -> [T] {
        var out: [T] = []
        while try step() { out.append(try row(self)) }
        return out
    }
}

final class RegexCache: @unchecked Sendable {
    static let shared = RegexCache()
    private var cache: [String: NSRegularExpression] = [:]
    private let lock = NSLock()

    func regex(_ pattern: String) -> NSRegularExpression? {
        lock.lock()
        defer { lock.unlock() }
        if let r = cache[pattern] { return r }
        var opts: NSRegularExpression.Options = []
        var p = pattern
        if p.hasPrefix("(?i)") {
            opts.insert(.caseInsensitive)
            p.removeFirst(4)
        }
        guard let r = try? NSRegularExpression(pattern: p, options: opts) else { return nil }
        if cache.count > 64 { cache.removeAll() }
        cache[pattern] = r
        return r
    }
}
