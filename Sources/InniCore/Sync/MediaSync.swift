import CryptoKit
import Foundation

/// AnkiWeb media sync. State lives in `collection.media.db2`, the same file and format Anki uses,
/// so switching between Anki and Inni on one profile doesn't re-upload everything.
public final class MediaSync {
    static let maxFilesPerZip = 25
    static let targetZipBytes = 2_621_440
    static let maxFileBytes = 100 * 1024 * 1024

    public let folder: URL
    let db: SQLiteDB
    let http: SyncHTTP

    public init(collectionURL: URL, auth: SyncAuth) throws {
        folder = collectionURL.deletingPathExtension().appendingPathExtension("media")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let dbURL = collectionURL.deletingPathExtension().appendingPathExtension("media.db2")
        db = try SQLiteDB(path: dbURL.path)
        http = SyncHTTP(auth: auth)
        try db.exec("PRAGMA journal_mode = wal")
        if try db.scalar("select count() from sqlite_master where type = 'table' and name = 'media'") == 0 {
            try db.exec("""
                CREATE TABLE media (fname text NOT NULL PRIMARY KEY, csum text, mtime int NOT NULL, dirty int NOT NULL) without rowid;
                CREATE INDEX idx_media_dirty ON media (dirty) WHERE dirty = 1;
                CREATE TABLE meta (dirMod int, lastUsn int);
                INSERT INTO meta VALUES (0, 0);
                PRAGMA user_version = 4;
                """)
        }
    }

    deinit { db.close() }

    public struct Progress: Sendable {
        public var downloaded = 0, uploaded = 0, removed = 0
    }

    /// `serverUSN` from the collection sync skips the handshake.
    @discardableResult
    public func sync(serverUSN: Int? = nil) async throws -> Progress {
        var progress = Progress()
        try registerChanges()
        let lastUSN = try db.scalar("select lastUsn from meta") ?? 0
        let remoteUSN: Int
        if let serverUSN {
            remoteUSN = serverUSN
        } else {
            let begin = try await call("msync/begin", ["v": SyncHTTP.longClientVersion]) as? JSONObject ?? [:]
            remoteUSN = Schema11.int(begin["usn"])
        }
        var acted = false
        if lastUSN != remoteUSN {
            try await fetchChanges(from: lastUSN, &progress)
            acted = true
        }
        if try db.scalar("select 1 from media where dirty = 1 limit 1") != nil {
            try await sendChanges(&progress)
            acted = true
        }
        if acted {
            let local = try db.scalar("select count() from media where csum is not null") ?? 0
            let reply = try await call("msync/mediaSanity", ["local": local])
            if Schema11.string(reply) != "OK" {
                try db.exec("delete from media; update meta set lastUsn = 0, dirMod = 0")
                throw SyncError.resyncRequired("media counts differed; the next media sync starts over")
            }
        }
        return progress
    }

    /// Media requests are safe to repeat, so a dropped connection gets two more tries.
    private func post(_ path: String, _ body: Data) async throws -> Data {
        var attempt = 0
        while true {
            do {
                return try await http.post(path, body)
            } catch where SyncError.isNetwork(error) && attempt < 2 {
                attempt += 1
                try await Task.sleep(for: .seconds(2 * attempt))
            }
        }
    }

    /// Media endpoints wrap results as {"data": …, "err": ""}.
    private func call(_ path: String, _ body: Any) async throws -> Any {
        let raw = try body as? Data ?? Schema11.encode(body)
        let data = try await post(path, raw)
        let reply = (data.isEmpty ? nil : try Schema11.decode(data)) as? JSONObject ?? [:]
        if let data = reply["data"], !(data is NSNull) { return data }
        let err = Schema11.string(reply["err"])
        throw SyncError.serverMessage(err.isEmpty ? "Media sync failed." : err)
    }

    // MARK: Local changes

    private func folderMtime() -> Int {
        let d = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
        return Int(d.timeIntervalSince1970 * 1000)
    }

    static func isSyncable(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower != "thumbs.db" && lower != ".ds_store" && name == name.precomposedStringWithCanonicalMapping
            && MediaFiles.isSafeName(name)
    }

    static func sha1(_ data: Data) -> String { Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// Scans the media folder for files added, changed or removed since the last scan.
    func registerChanges() throws {
        let dirMod = folderMtime()
        guard try db.scalar("select dirMod from meta") != dirMod else { return }
        var known: [String: Int] = [:]
        for row in try db.prepare("select fname, mtime from media where csum is not null").map({ ($0.text(0), $0.integer(1)) }) {
            known[row.0] = row.1
        }
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
        try db.transaction {
            let get = try db.prepare("select csum, dirty from media where fname = ?")
            let set = try db.prepare("insert or replace into media (fname, csum, mtime, dirty) values (?, ?, ?, ?)")
            for url in files {
                let name = url.lastPathComponent
                guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true, MediaSync.isSyncable(name) else { continue }
                let size = v.fileSize ?? 0
                guard size > 0, size <= MediaSync.maxFileBytes else { continue }
                let previous = known.removeValue(forKey: name)
                let mtime = Int(v.contentModificationDate?.timeIntervalSince1970 ?? 0)
                if previous == mtime { continue }
                guard let data = try? Data(contentsOf: url) else { continue }
                let sum = MediaSync.sha1(data)
                var dirty = true
                if previous != nil, try get.bind([name]).step(), get.string(0) == sum { dirty = get.integer(1) != 0 }
                try set.bind([name, sum, mtime, dirty]).run()
            }
            for name in known.keys { try set.bind([name, nil, 0, true]).run() }
            try db.run("update meta set dirMod = ?", dirMod)
        }
    }

    // MARK: Server → local

    private func fetchChanges(from start: Int, _ progress: inout Progress) async throws {
        var lastUSN = start
        while true {
            let batch = try await call("msync/mediaChanges", ["lastUsn": lastUSN]) as? [[Any]] ?? []
            guard let last = batch.last, last.count >= 3 else { break }
            lastUSN = Schema11.int(last[1])
            var download: [String] = [], delete: [String] = [], clean: [String] = []
            let get = try db.prepare("select csum, dirty from media where fname = ?")
            for change in batch where change.count >= 3 {
                let name = Schema11.string(change[0]), remote = Schema11.string(change[2])
                var local = "", inDB = false, pending = false
                if try get.bind([name]).step() {
                    inDB = true
                    local = get.string(0) ?? ""
                    pending = get.integer(1) != 0
                }
                switch (local.isEmpty, remote.isEmpty) {
                case (true, true): if inDB { delete.append(name) }
                case (true, false): download.append(name)
                case (false, true): if !pending { delete.append(name) }
                case (false, false):
                    if local == remote { if pending { clean.append(name) } } else { download.append(name) }
                }
            }
            for name in delete where MediaFiles.isSafeName(name) {
                try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
            }
            progress.removed += delete.count
            var added: [(String, String, Int)] = []
            var queue = download[...]
            while !queue.isEmpty {
                let names = Array(queue.prefix(MediaSync.maxFilesPerZip))
                let zipData = try await post("msync/downloadFiles", try Schema11.encode(["files": names]))
                let got = try extract(zipData)
                guard !got.isEmpty else { throw SyncError.serverMessage("AnkiWeb sent an empty media batch.") }
                added += got
                queue = queue.dropFirst(got.count)
                progress.downloaded += got.count
            }
            let dirMod = folderMtime()
            try db.transaction {
                let clear = try db.prepare("update media set dirty = 0 where fname = ?")
                for n in clean { try clear.bind([n]).run() }
                let del = try db.prepare("delete from media where fname = ?")
                for n in delete { try del.bind([n]).run() }
                let set = try db.prepare("insert or replace into media (fname, csum, mtime, dirty) values (?, ?, ?, 0)")
                for (n, sum, mtime) in added { try set.bind([n, sum, mtime]).run() }
                try db.run("update meta set lastUsn = ?, dirMod = ?", lastUSN, dirMod)
            }
        }
    }

    /// Writes files from a download zip (`_meta` maps entry names to real names).
    private func extract(_ zipData: Data) throws -> [(String, String, Int)] {
        let zip = try ZipReader(data: zipData)
        let map = (try? Schema11.decode(try zip.read("_meta"))) as? [String: String] ?? [:]
        var out: [(String, String, Int)] = []
        for (entry, name) in map.sorted(by: { (Int($0.key) ?? 0) < (Int($1.key) ?? 0) }) {
            guard MediaFiles.isSafeName(name), zip.contains(entry) else { continue }
            let data = try zip.read(entry)
            let url = folder.appendingPathComponent(name.precomposedStringWithCanonicalMapping)
            try data.write(to: url, options: .atomic)
            let mtime = Int(((try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()).timeIntervalSince1970)
            out.append((url.lastPathComponent, MediaSync.sha1(data), mtime))
        }
        return out
    }

    // MARK: Local → server

    private func sendChanges(_ progress: inout Progress) async throws {
        while true {
            let pending = try db.prepare("select fname, csum from media where dirty = 1 limit \(MediaSync.maxFilesPerZip)")
                .map { ($0.text(0), $0.string(1)) }
            if pending.isEmpty { break }
            var entries: [(name: String, data: Data?)] = [], invalid: [String] = [], size = 0
            for (name, sum) in pending {
                if size > MediaSync.targetZipBytes { break }
                guard sum != nil else { entries.append((name, nil)); continue }
                let data = MediaFiles.isSafeName(name) ? try? Data(contentsOf: folder.appendingPathComponent(name)) : nil
                guard let data, !data.isEmpty, data.count <= MediaSync.maxFileBytes, MediaSync.isSyncable(name) else {
                    invalid.append(name)
                    continue
                }
                size += data.count
                entries.append((name, data))
            }
            if !invalid.isEmpty {
                try db.transaction { for n in invalid { try db.run("delete from media where fname = ?", n) } }
                continue
            }
            let zip = try MediaSync.uploadZip(entries)
            let reply = try await call("msync/uploadChanges", zip) as? [Any] ?? []
            guard reply.count >= 2 else { throw SyncError.serverMessage("Unexpected media upload reply.") }
            let processed = min(Schema11.int(reply[0]), entries.count), currentUSN = Schema11.int(reply[1])
            let done = entries.prefix(processed)
            try db.transaction {
                let clear = try db.prepare("update media set dirty = 0 where fname = ?")
                for e in done { try clear.bind([e.name]).run() }
                let last = try db.scalar("select lastUsn from meta") ?? 0
                if last + done.count == currentUSN { try db.run("update meta set lastUsn = ?", currentUSN) }
            }
            progress.uploaded += done.filter { $0.data != nil }.count
            progress.removed += done.filter { $0.data == nil }.count
            if processed == 0 { break }
        }
    }

    /// Stored entries named "0", "1", … plus `_meta`: [[real name, entry name or null], …].
    static func uploadZip(_ entries: [(name: String, data: Data?)]) throws -> Data {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("inni-media-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let w = try ZipWriter(url: tmp)
        var meta: [[Any]] = []
        for (i, e) in entries.enumerated() {
            if let data = e.data {
                try w.add(String(i), data)
                meta.append([e.name, String(i)])
            } else {
                meta.append([e.name, NSNull()])
            }
        }
        try w.add("_meta", try Schema11.encode(meta))
        try w.finish()
        return try Data(contentsOf: tmp)
    }
}