import Foundation

public struct SyncOutcome: Sendable {
    public enum Status: Sendable, Equatable {
        case noChanges
        case synced
        /// Only a one-way sync can continue; the caller asks the user which direction.
        case fullSyncRequired(uploadOK: Bool, downloadOK: Bool)
    }

    public var status: Status
    /// The credentials to store from now on (the endpoint may have moved).
    public var auth: SyncAuth
    public var serverMessage: String
    /// For media sync, which can skip its own handshake when nothing changed.
    public var serverMediaUSN: Int
}

/// AnkiWeb's collection sync (protocol 11), following rslib's normal and full sync.
extension Collection {
    static let syncChunkSize = 250
    static let maxUploadBytes = 250 * 1024 * 1024

    struct SyncMeta {
        var modified: Int, schema: Int, usn: Int, serverTime: Int, empty: Bool
        var message = "", shouldContinue = true, mediaUSN = 0
    }

    func localSyncMeta() throws -> SyncMeta {
        let s = try db.prepare("select mod, scm, usn from col")
        _ = try s.step()
        return SyncMeta(modified: s.integer(0), schema: s.integer(1), usn: s.integer(2), serverTime: Collection.nowSecs,
                        empty: try db.scalar("select exists(select 1 from cards)") == 0)
    }

    static func remoteSyncMeta(_ http: SyncHTTP) async throws -> SyncMeta {
        var redirects = 0
        while true {
            do {
                let o = try await http.json("sync/meta", ["v": SyncHTTP.protocolVersion, "cv": SyncHTTP.longClientVersion]) as? JSONObject ?? [:]
                return SyncMeta(modified: Schema11.int(o["mod"]), schema: Schema11.int(o["scm"]), usn: Schema11.int(o["usn"]),
                                serverTime: Schema11.int(o["ts"]), empty: Schema11.bool(o["empty"]),
                                message: Schema11.string(o["msg"]), shouldContinue: Schema11.bool(o["cont"], true),
                                mediaUSN: Schema11.int(o["media_usn"]))
            } catch let r as SyncHTTP.Redirect {
                redirects += 1
                guard redirects < 4 else { throw SyncError.http(308, "too many redirects") }
                http.endpoint = r.location
            }
        }
    }

    static func updatedAuth(_ auth: SyncAuth, _ http: SyncHTTP) -> SyncAuth {
        var a = auth
        if http.endpoint != (auth.endpoint ?? SyncHTTP.ankiWeb) { a.endpoint = http.endpoint }
        return a
    }

    /// A normal (two-way) sync. Reports when a full sync is needed instead of doing it.
    public func sync(auth: SyncAuth) async throws -> SyncOutcome {
        let http = SyncHTTP(auth: auth)
        let remote = try await Collection.remoteSyncMeta(http)
        let newAuth = Collection.updatedAuth(auth, http)
        guard remote.shouldContinue else { throw SyncError.serverMessage(remote.message) }
        if abs(remote.serverTime - Collection.nowSecs) > 300 { throw SyncError.clockIncorrect }
        let local = try localSyncMeta()
        var outcome = SyncOutcome(status: .noChanges, auth: newAuth, serverMessage: remote.message, serverMediaUSN: remote.mediaUSN)
        if local.modified == remote.modified { return outcome }
        if local.schema != remote.schema {
            outcome.status = .fullSyncRequired(uploadOK: !local.empty || remote.empty, downloadOK: !remote.empty || local.empty)
            return outcome
        }
        try await normalSync(http, local: local, remote: remote)
        outcome.status = .synced
        return outcome
    }

    private func normalSync(_ http: SyncHTTP, local: SyncMeta, remote: SyncMeta) async throws {
        let serverUSN = remote.usn
        let localIsNewer = local.modified > remote.modified
        try db.exec("SAVEPOINT sync")
        do {
            let remoteGraves = try await http.json("sync/start", ["minUsn": local.usn, "lnewer": localIsNewer, "graves": NSNull()])
            var graves = try pendingGraves()
            try db.run("update graves set usn = ? where usn = -1", serverUSN)
            while let chunk = Collection.takeGraveChunk(&graves) {
                _ = try await http.json("sync/applyGraves", ["chunk": chunk])
            }
            try applyGraves(remoteGraves as? JSONObject ?? [:], usn: serverUSN)

            let changes = try localUnchunkedChanges(serverUSN: serverUSN, localIsNewer: localIsNewer)
            let remoteChanges = try await http.json("sync/applyChanges", ["changes": changes])
            try applyChanges(remoteChanges as? JSONObject ?? [:], usn: serverUSN)

            while true {
                let chunk = try await http.json("sync/chunk", JSONObject()) as? JSONObject ?? [:]
                try applyChunk(chunk)
                if Schema11.bool(chunk["done"]) { break }
            }
            var pending = try pendingChunkIDs()
            while true {
                let (chunk, done) = try takeChunk(&pending, serverUSN: serverUSN)
                _ = try await http.json("sync/applyChunk", ["chunk": chunk])
                if done { break }
            }

            let reply = try await http.json("sync/sanityCheck2", ["client": try sanityCounts()]) as? JSONObject ?? [:]
            guard Schema11.string(reply["status"]) == "ok" else { throw SyncError.sanityCheckFailed }

            let finished = Schema11.int(try await http.json("sync/finish", JSONObject()))
            try db.run("update col set ls = ?, usn = ?, mod = ?", finished, serverUSN + 1, finished)
            try db.exec("RELEASE sync")
        } catch {
            try? db.exec("ROLLBACK TO sync; RELEASE sync")
            _ = try? await http.json("sync/abort", JSONObject())
            switch error {
            case SyncError.sanityCheckFailed, SyncError.resyncRequired: try? markSchemaModified()
            default: break
            }
            try? reload()
            throw error
        }
        try reload()
    }

    // MARK: Graves

    private func pendingGraves() throws -> (cards: [Int], notes: [Int], decks: [Int]) {
        var g: (cards: [Int], notes: [Int], decks: [Int]) = ([], [], [])
        let s = try db.prepare("select oid, type from graves where usn = -1")
        while try s.step() {
            switch s.integer(1) {
            case 0: g.cards.append(s.integer(0))
            case 1: g.notes.append(s.integer(0))
            default: g.decks.append(s.integer(0))
            }
        }
        return g
    }

    private static func takeGraveChunk(_ g: inout (cards: [Int], notes: [Int], decks: [Int])) -> JSONObject? {
        var limit = syncChunkSize
        var out: (cards: [Int], notes: [Int], decks: [Int]) = ([], [], [])
        while limit > 0, let id = g.cards.popLast() { out.cards.append(id); limit -= 1 }
        while limit > 0, let id = g.notes.popLast() { out.notes.append(id); limit -= 1 }
        while limit > 0, let id = g.decks.popLast() { out.decks.append(id); limit -= 1 }
        return limit == syncChunkSize ? nil : ["cards": out.cards, "notes": out.notes, "decks": out.decks]
    }

    private func applyGraves(_ g: JSONObject, usn: Int) throws {
        let ids = { (k: String) in (g[k] as? [Any] ?? []).map { Schema11.int($0) } }
        let grave = try db.prepare("insert or ignore into graves (usn, oid, type) values (?, ?, ?)")
        for id in ids("notes") {
            try db.run("delete from notes where id = ?", id)
            try grave.bind([usn, id, 1]).run()
        }
        for id in ids("cards") {
            try db.run("delete from cards where id = ?", id)
            try grave.bind([usn, id, 0]).run()
        }
        for id in ids("decks") {
            try db.run("delete from decks where id = ?", id)
            try grave.bind([usn, id, 2]).run()
        }
    }

    // MARK: Notetypes, decks, presets, tags, config

    private func pendingIDs(_ table: String) throws -> [Int] {
        try db.prepare("select id from \(table) where usn = -1").map { $0.integer(0) }
    }

    private func localUnchunkedChanges(serverUSN: Int, localIsNewer: Bool) throws -> JSONObject {
        let ntIDs = try pendingIDs("notetypes"), deckIDs = try pendingIDs("decks"), confIDs = try pendingIDs("deck_config")
        let tags = try db.prepare("select tag from tags where usn = -1").map { $0.text(0) }
        for (table, ids) in [("notetypes", ntIDs), ("decks", deckIDs), ("deck_config", confIDs)] {
            let u = try db.prepare("update \(table) set usn = ? where id = ?")
            for id in ids { try u.bind([serverUSN, id]).run() }
        }
        let tu = try db.prepare("update tags set usn = ? where tag = ?")
        for t in tags { try tu.bind([serverUSN, t]).run() }

        var out: JSONObject = [
            "models": ntIDs.compactMap { notetypes[$0] }.map { nt -> JSONObject in
                var o = Schema11.json(nt); o["usn"] = serverUSN; return o
            },
            "decks": [
                deckIDs.compactMap { decks[$0] }.map { d -> JSONObject in var o = Schema11.json(d); o["usn"] = serverUSN; return o },
                confIDs.compactMap { deckConfigs[$0] }.map { c -> JSONObject in var o = Schema11.json(c); o["usn"] = serverUSN; return o },
            ],
            "tags": tags,
        ]
        if localIsNewer {
            var conf: JSONObject = [:]
            let s = try db.prepare("select key, val from config")
            while try s.step() {
                if let v = try? Schema11.decode(s.blob(1)) { conf[s.text(0)] = v }
            }
            try db.exec("update config set usn = 0 where usn != 0")
            out["conf"] = conf
            out["crt"] = creationSecs
        }
        return out
    }

    private func applyChanges(_ c: JSONObject, usn: Int) throws {
        for o in c["models"] as? [JSONObject] ?? [] {
            var nt = Schema11.notetype(o)
            if let existing = notetypes[nt.id] {
                guard existing.mtime <= nt.mtime else { continue }
                if existing.fields.count != nt.fields.count || existing.templates.count != nt.templates.count {
                    throw SyncError.resyncRequired("note type “\(nt.name)” changed its fields or templates")
                }
            }
            while let other = try db.scalar("select id from notetypes where name = ?", nt.name), other != nt.id {
                nt.name += "+"
                nt.mtime = Collection.nowSecs
                nt.usn = usn
            }
            try db.run("insert or replace into notetypes (id, name, mtime_secs, usn, config) values (?, ?, ?, ?, ?)",
                       nt.id, nt.name, nt.mtime, nt.usn, nt.config.encoded)
            try db.run("delete from fields where ntid = ?", nt.id)
            try db.run("delete from templates where ntid = ?", nt.id)
            for f in nt.fields {
                try db.run("insert into fields (ntid, ord, name, config) values (?, ?, ?, ?)", nt.id, f.ord, f.name, f.config.encoded)
            }
            for t in nt.templates {
                try db.run("insert into templates (ntid, ord, name, mtime_secs, usn, config) values (?, ?, ?, ?, ?, ?)",
                           nt.id, t.ord, t.name, t.mtime, t.usn, t.config.encoded)
            }
            notetypes[nt.id] = nt
        }
        let decksAndConf = c["decks"] as? [Any] ?? []
        for o in (decksAndConf.first as? [JSONObject]) ?? [] {
            var d = Schema11.deck(o)
            if let existing = decks[d.id], existing.mtime > d.mtime { continue }
            func native(_ name: String) -> String { name.replacingOccurrences(of: "::", with: "\u{1f}") }
            while let other = try db.scalar("select id from decks where name = ?", native(d.name)), other != d.id {
                d.name += "+"
                d.mtime = Collection.nowSecs
                d.usn = usn
            }
            try db.run("insert or replace into decks (id, name, mtime_secs, usn, common, kind) values (?, ?, ?, ?, ?, ?)",
                       d.id, native(d.name), d.mtime, d.usn, d.common.encoded, d.kind.encoded)
            decks[d.id] = d
        }
        for o in (decksAndConf.dropFirst().first as? [JSONObject]) ?? [] {
            let dc = Schema11.deckConfig(o)
            if let existing = deckConfigs[dc.id], existing.mtime > dc.mtime { continue }
            try db.run("insert or replace into deck_config (id, name, mtime_secs, usn, config) values (?, ?, ?, ?, ?)",
                       dc.id, dc.name, dc.mtime, dc.usn, dc.config.encoded)
            deckConfigs[dc.id] = dc
        }
        let tag = try db.prepare("insert or ignore into tags (tag, usn, collapsed) values (?, ?, 0)")
        for t in c["tags"] as? [String] ?? [] where !t.isEmpty { try tag.bind([t, usn]).run() }
        if let crt = c["crt"] { try db.run("update col set crt = ?", Schema11.int(crt)) }
        if let conf = c["conf"] as? JSONObject {
            try db.exec("delete from config")
            let ins = try db.prepare("insert into config (key, usn, mtime_secs, val) values (?, ?, ?, ?)")
            for (k, v) in conf { try ins.bind([k, usn, Collection.nowSecs, try Schema11.encode(v)]).run() }
        }
    }

    // MARK: Cards, notes, revlog

    private func applyChunk(_ chunk: JSONObject) throws {
        let rev = try db.prepare("insert or ignore into revlog (id, cid, usn, ease, ivl, lastIvl, factor, time, type) values (?, ?, ?, ?, ?, ?, ?, ?, ?)")
        for e in chunk["revlog"] as? [Any] ?? [] {
            let v = Collection.row(e, keys: ["id", "cid", "usn", "ease", "ivl", "lastIvl", "factor", "time", "type"])
            try rev.bind(v.map { Schema11.int($0) }).run()
        }
        let cardMeta = try db.prepare("select usn, mod from cards where id = ?")
        let card = try db.prepare("insert or replace into cards (\(Collection.cardColumns)) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)")
        for e in chunk["cards"] as? [[Any]] ?? [] where e.count >= 18 {
            guard try isNewer(e, existing: cardMeta) else { continue }
            try card.bind(e[0..<17].map { Schema11.int($0) } + [Schema11.string(e[17])]).run()
        }
        let noteMeta = try db.prepare("select usn, mod from notes where id = ?")
        for e in chunk["notes"] as? [[Any]] ?? [] where e.count >= 7 {
            guard try isNewer(e, existing: noteMeta, mtimeIndex: 3, usnIndex: 4) else { continue }
            let mid = Schema11.int(e[2])
            guard let nt = notetypes[mid] else { throw CollectionError("A synced note uses a missing note type.") }
            var fields = Schema11.string(e[6]).components(separatedBy: "\u{1f}")
            if fields.count < nt.fields.count { fields += Array(repeating: "", count: nt.fields.count - fields.count) }
            var n = Note(id: Schema11.int(e[0]), guid: Schema11.string(e[1]), notetypeID: mid, mtime: Schema11.int(e[3]),
                         usn: Schema11.int(e[4]), tags: Note.splitTags(Schema11.string(e[5])), fields: fields)
            n.flags = 0
            n.data = ""
            try writeNote(n, nt)
        }
    }

    /// Remote objects win unless the local copy has unsynced changes and is at least as new.
    private func isNewer(_ e: [Any], existing: Statement, mtimeIndex: Int = 4, usnIndex: Int = 5) throws -> Bool {
        guard try existing.bind([Schema11.int(e[0])]).step() else { return true }
        return existing.integer(0) != -1 || existing.integer(1) < Schema11.int(e[mtimeIndex])
    }

    /// Entries arrive as arrays, but accept objects too.
    private static func row(_ e: Any, keys: [String]) -> [Any?] {
        if let a = e as? [Any] { return keys.indices.map { $0 < a.count ? a[$0] : nil } }
        let o = e as? JSONObject ?? [:]
        return keys.map { o[$0] }
    }

    private func pendingChunkIDs() throws -> (revlog: [Int], cards: [Int], notes: [Int]) {
        (try pendingIDs("revlog"), try pendingIDs("cards"), try pendingIDs("notes"))
    }

    private func takeChunk(_ ids: inout (revlog: [Int], cards: [Int], notes: [Int]), serverUSN: Int) throws -> (JSONObject, Bool) {
        var limit = Collection.syncChunkSize
        var revlogIDs: [Int] = [], cardIDs: [Int] = [], noteIDs: [Int] = []
        while limit > 0 {
            let before = limit
            if let id = ids.revlog.popLast() { revlogIDs.append(id); limit -= 1 }
            if let id = ids.notes.popLast() { noteIDs.append(id); limit -= 1 }
            if let id = ids.cards.popLast() { cardIDs.append(id); limit -= 1 }
            if limit == before { break }
        }
        let done = limit > 0
        for (table, list) in [("revlog", revlogIDs), ("cards", cardIDs), ("notes", noteIDs)] {
            let u = try db.prepare("update \(table) set usn = ? where id = ?")
            for id in list { try u.bind([serverUSN, id]).run() }
        }
        var chunk: JSONObject = ["done": done]
        if !revlogIDs.isEmpty {
            let s = try db.prepare("select id, cid, usn, ease, ivl, lastIvl, factor, time, type from revlog where id = ?")
            chunk["revlog"] = try revlogIDs.compactMap { id -> [Any]? in
                guard try s.bind([id]).step() else { return nil }
                return [s.integer(0), s.integer(1), serverUSN, s.integer(3), s.integer(4), s.integer(5), s.integer(6), s.integer(7), s.integer(8)]
            }
        }
        if !cardIDs.isEmpty {
            let s = try db.prepare("select \(Collection.cardColumns) from cards where id = ?")
            chunk["cards"] = try cardIDs.compactMap { id -> [Any]? in
                guard try s.bind([id]).step() else { return nil }
                var row: [Any] = (0..<17).map { s.integer(Int32($0)) }
                row[5] = serverUSN
                row.append(s.text(17))
                return row
            }
        }
        if !noteIDs.isEmpty {
            let s = try db.prepare("select id, guid, mid, mod, tags, flds from notes where id = ?")
            chunk["notes"] = try noteIDs.compactMap { id -> [Any]? in
                guard try s.bind([id]).step() else { return nil }
                let tags = Note.splitTags(s.text(4))
                return [s.integer(0), s.text(1), s.integer(2), s.integer(3), serverUSN,
                        tags.isEmpty ? "" : " \(tags.joined(separator: " ")) ", s.text(5), "", "", 0, ""]
            }
        }
        return (chunk, done)
    }

    private func sanityCounts() throws -> [Any] {
        for t in ["cards", "notes", "revlog", "graves", "decks", "deck_config", "tags", "notetypes"] {
            if try db.scalar("select 1 from \(t) where usn = -1 limit 1") != nil {
                throw SyncError.resyncRequired("\(t) still had unsynced rows")
            }
        }
        func count(_ t: String) throws -> Int { try db.scalar("select count() from \(t)") ?? 0 }
        return [[0, 0, 0], try count("cards"), try count("notes"), try count("revlog"), try count("graves"),
                try count("notetypes"), try count("decks"), try count("deck_config")]
    }

    // MARK: Full sync

    /// Replaces the server's collection with this one.
    public func fullUpload(auth: SyncAuth) async throws -> SyncAuth {
        let http = SyncHTTP(auth: auth)
        _ = try await Collection.remoteSyncMeta(http)
        try db.transaction {
            try db.exec("""
                delete from graves;
                update notes set usn = 0 where usn = -1;
                update cards set usn = 0 where usn = -1;
                update revlog set usn = 0 where usn = -1;
                update tags set usn = 0 where usn != 0;
                update deck_config set usn = 0 where usn != 0;
                update decks set usn = 0 where usn != 0;
                update notetypes set usn = 0 where usn != 0;
                update col set usn = usn + 1;
                """)
            try markSchemaModified()
            try db.exec("update col set ls = scm")
        }
        try reload()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("inni-upload-\(UUID().uuidString).anki2")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try snapshot(to: tmp)
        do {
            let copy = try SQLiteDB(path: tmp.path)
            try copy.exec("PRAGMA journal_mode = delete")
            copy.close()
        }
        let data = try Data(contentsOf: tmp)
        if http.endpoint.host?.contains("ankiweb") == true, data.count >= Collection.maxUploadBytes {
            throw SyncError.uploadTooLarge(String(format: "%.1f MB", Double(data.count) / 1_048_576))
        }
        let reply = String(decoding: try await http.post("sync/upload", data), as: UTF8.self)
        guard reply == "OK" else { throw SyncError.serverMessage(reply) }
        return Collection.updatedAuth(auth, http)
    }

    /// Replaces the collection file at `url` with the server's. The collection must be closed.
    public static func fullDownload(auth: SyncAuth, replacing url: URL) async throws -> SyncAuth {
        let http = SyncHTTP(auth: auth)
        _ = try await remoteSyncMeta(http)
        let data = try await http.post("sync/download", try Schema11.encode(JSONObject()))
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".inni-download-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try data.write(to: tmp)
        do {
            let db = try SQLiteDB(path: tmp.path)
            defer { db.close() }
            let check = try db.prepare("PRAGMA integrity_check")
            guard try check.step(), check.text(0) == "ok" else { throw CollectionError("The downloaded collection is damaged.") }
            guard try db.scalar("select count() from col") == 1 else { throw CollectionError("The downloaded file is not a collection.") }
            try db.exec("update col set ls = mod")
        }
        let fm = FileManager.default
        for suffix in ["-wal", "-shm"] { try? fm.removeItem(atPath: url.path + suffix) }
        if fm.fileExists(atPath: url.path) {
            _ = try fm.replaceItemAt(url, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: url)
        }
        return updatedAuth(auth, http)
    }
}
