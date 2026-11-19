import CryptoKit
import Foundation

public struct ImportResult: Sendable {
    public var notesAdded = 0
    public var notesUpdated = 0
    public var notesSkipped = 0
    public var cardsAdded = 0
    public var notetypesAdded = 0
    public var decksAdded = 0
    public var mediaAdded = 0

    public var summary: String {
        var parts = ["\(notesAdded) notes added"]
        if notesUpdated > 0 { parts.append("\(notesUpdated) updated") }
        if notesSkipped > 0 { parts.append("\(notesSkipped) already present") }
        if mediaAdded > 0 { parts.append("\(mediaAdded) media files") }
        return parts.joined(separator: ", ")
    }
}

/// `.apkg` (decks to merge) and `.colpkg` (a whole collection), in Anki's legacy and current formats.
public enum AnkiPackage {
    struct Opened {
        let zip: ZipReader
        let collectionURL: URL
        let media: [(name: String, entry: String, compressed: Bool)]
        let tempDir: URL
    }

    /// Unpacks the collection to a temp file and lists the media.
    static func open(_ url: URL) throws -> Opened {
        let zip = try ZipReader(url: url)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("inni-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let colURL = tmp.appendingPathComponent("collection.anki2")
        let latest = zip.contains("collection.anki21b")
        if latest {
            try Zstd.decompress(try zip.read("collection.anki21b")).write(to: colURL)
        } else if zip.contains("collection.anki21") {
            try zip.read("collection.anki21").write(to: colURL)
        } else if zip.contains("collection.anki2") {
            try zip.read("collection.anki2").write(to: colURL)
        } else {
            throw CollectionError("This file doesn't contain an Anki collection.")
        }

        var media: [(String, String, Bool)] = []
        if zip.contains("media") {
            let raw = try zip.read("media")
            if latest || Zstd.isCompressed(raw) {
                let entries = Proto(try Zstd.decompress(raw)).messages(1)
                for (i, e) in entries.enumerated() {
                    let entryName = e.has(255) ? String(e.uint(255)) : String(i)
                    media.append((e.string(1), entryName, true))
                }
            } else if let map = try? JSONSerialization.jsonObject(with: raw) as? [String: String] {
                for (k, v) in map { media.append((v, k, false)) }
            }
        }
        return Opened(zip: zip, collectionURL: colURL, media: media, tempDir: tmp)
    }

    static func mediaData(_ o: Opened, _ entry: String, compressed: Bool) throws -> Data {
        let d = try o.zip.read(entry)
        return compressed || Zstd.isCompressed(d) ? try Zstd.decompress(d) : d
    }

    /// Replaces the collection at `dest` with the one in a `.colpkg`. The previous file is kept as a backup.
    public static func replaceCollection(at dest: URL, with colpkg: URL) throws {
        let o = try open(colpkg)
        defer { try? FileManager.default.removeItem(at: o.tempDir) }
        // Validate (and upgrade legacy schemas) before touching the real collection.
        let check = try Collection(url: o.collectionURL)
        check.close()
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path) {
            let backup = dest.deletingPathExtension().appendingPathExtension("before-import-\(Collection.nowSecs).anki2")
            try fm.moveItem(at: dest, to: backup)
            for suffix in ["-wal", "-shm"] { try? fm.removeItem(atPath: dest.path + suffix) }
        }
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: o.collectionURL, to: dest)
        let mediaDir = dest.deletingPathExtension().appendingPathExtension("media")
        try fm.createDirectory(at: mediaDir, withIntermediateDirectories: true)
        for m in o.media where MediaFiles.isSafeName(m.name) {
            try autoreleasepool {
                try mediaData(o, m.entry, compressed: m.compressed).write(to: mediaDir.appendingPathComponent(m.name))
            }
        }
    }
}

extension Collection {
    /// Merges an `.apkg` (or the notes of a `.colpkg`) into this collection, matching notes by guid.
    @discardableResult
    public func importPackage(_ url: URL, keepScheduling: Bool = true) throws -> ImportResult {
        let o = try AnkiPackage.open(url)
        defer { try? FileManager.default.removeItem(at: o.tempDir) }
        let src = try Collection(url: o.collectionURL)
        defer { src.close() }
        var result = ImportResult()

        // Media first, so renamed files can be fixed up in note fields.
        var renames: [String: String] = [:]
        try FileManager.default.createDirectory(at: mediaFolder, withIntermediateDirectories: true)
        for m in o.media where MediaFiles.isSafeName(m.name) {
            try autoreleasepool {
                let data = try AnkiPackage.mediaData(o, m.entry, compressed: m.compressed)
                let target = mediaFolder.appendingPathComponent(m.name)
                if let existing = try? Data(contentsOf: target, options: .alwaysMapped) {
                    if existing == data { return }
                    let renamed = MediaFiles.uniqueName(for: m.name, data: data)
                    renames[m.name] = renamed
                    if !FileManager.default.fileExists(atPath: mediaFolder.appendingPathComponent(renamed).path) {
                        try data.write(to: mediaFolder.appendingPathComponent(renamed))
                        result.mediaAdded += 1
                    }
                } else {
                    try data.write(to: target)
                    result.mediaAdded += 1
                }
            }
        }

        try db.transaction {
            // Note types: reuse when the same id has the same fields, otherwise add a copy.
            var ntMap: [NotetypeID: NotetypeID] = [:]
            for snt in src.notetypes.values {
                if let mine = notetypes[snt.id], mine.fieldNames == snt.fieldNames, mine.templates.count == snt.templates.count {
                    ntMap[snt.id] = mine.id
                    if snt.mtime > mine.mtime, mine.templates.map(\.front) != snt.templates.map(\.front)
                        || mine.templates.map(\.back) != snt.templates.map(\.back) || mine.css != snt.css {
                        var updated = mine
                        updated.css = snt.css
                        for i in updated.templates.indices {
                            updated.templates[i].front = snt.templates[i].front
                            updated.templates[i].back = snt.templates[i].back
                        }
                        try save(updated)
                    }
                } else if let match = notetypes.values.first(where: { $0.name == snt.name && $0.fieldNames == snt.fieldNames
                    && $0.templates.count == snt.templates.count && $0.templates.map(\.front) == snt.templates.map(\.front) }) {
                    ntMap[snt.id] = match.id
                } else {
                    var copy = snt
                    if notetypes[snt.id] != nil { copy.id = 0 }
                    copy = try save(copy)
                    ntMap[snt.id] = copy.id
                    result.notetypesAdded += 1
                }
            }

            // Decks by name.
            var deckMap: [DeckID: DeckID] = [:]
            for sd in src.sortedDecks {
                if sd.isFiltered { continue }
                if let mine = deck(named: sd.name) {
                    deckMap[sd.id] = mine.id
                } else {
                    var d = Deck(name: sd.name)
                    d.description = sd.description
                    if decks[sd.id] == nil { d.id = sd.id }
                    d = try save(d)
                    deckMap[sd.id] = d.id
                    result.decksAdded += 1
                }
            }
            let fallbackDeck = currentDeckID

            // Notes by guid.
            var existing: [String: (NoteID, Int, NotetypeID)] = [:]
            let es = try db.prepare("select guid, id, mod, mid from notes")
            while try es.step() { existing[es.text(0)] = (es.integer(1), es.integer(2), es.integer(3)) }

            var noteMap: [NoteID: NoteID] = [:]
            let ns = try src.db.prepare("select id, guid, mid, mod, usn, tags, flds, flags, data from notes")
            while try ns.step() {
                var n = Collection.note(from: ns)
                guard let mid = ntMap[n.notetypeID], let nt = notetypes[mid] else { continue }
                if !renames.isEmpty {
                    n.fields = n.fields.map { f in renames.reduce(f) { $0.replacingOccurrences(of: $1.key, with: $1.value) } }
                }
                if let (eid, emod, emid) = existing[n.guid] {
                    if emid == mid, n.mtime > emod, var mine = note(eid) {
                        mine.fields = n.fields
                        mine.tags = n.tags
                        mine.mtime = Collection.nowSecs
                        mine.usn = -1
                        try writeNote(mine, nt)
                        try registerTags(mine.tags)
                        result.notesUpdated += 1
                    } else {
                        result.notesSkipped += 1
                    }
                    continue
                }
                let oldID = n.id
                n.notetypeID = mid
                if try db.scalar("select 1 from notes where id = ?", n.id) != nil { n.id = try uniqueTimestampID(table: "notes") }
                n.usn = -1
                n.mtime = Collection.nowSecs
                if !keepScheduling { n.tags.removeAll { ["leech", "marked"].contains($0.lowercased()) } }
                try writeNote(n, nt)
                try registerTags(n.tags)
                noteMap[oldID] = n.id
                existing[n.guid] = (n.id, n.mtime, mid)
                result.notesAdded += 1
            }

            // Cards (and history) of new notes.
            var cardMap: [CardID: CardID] = [:]
            var pos = configInt("nextPos") ?? 1
            let cs = try src.db.prepare("select \(Collection.cardColumns) from cards order by nid, ord")
            var positions: [NoteID: Int] = [:]
            while try cs.step() {
                var c = Collection.card(from: cs)
                guard let nid = noteMap[c.noteID] else { continue }
                let oldID = c.id
                c.noteID = nid
                let home = c.originalDeckID != 0 ? c.originalDeckID : c.deckID
                c.deckID = deckMap[home] ?? fallbackDeck
                if c.originalDue != 0, c.originalDeckID != 0 { c.due = c.originalDue }
                c.originalDeckID = 0
                c.originalDue = 0
                if try db.scalar("select 1 from cards where id = ?", c.id) != nil { c.id = try uniqueTimestampID(table: "cards") }
                if !keepScheduling || c.type == .new {
                    let p = positions[nid] ?? pos
                    if positions[nid] == nil {
                        positions[nid] = p
                        pos += 1
                    }
                    if !keepScheduling {
                        c = Card(id: c.id, noteID: c.noteID, deckID: c.deckID, ord: c.ord, due: p)
                    } else {
                        c.due = p
                        c.queue = c.queue == .suspended ? .suspended : .new
                    }
                }
                if c.queue == .learning || c.queue == .preview { c.queue = Collection.naturalQueue(c) }
                c.usn = -1
                c.mtime = Collection.nowSecs
                try writeCard(c)
                cardMap[oldID] = c.id
                result.cardsAdded += 1
            }
            try setConfig("nextPos", pos)

            if keepScheduling, !cardMap.isEmpty {
                let rs = try src.db.prepare("select id, cid, usn, ease, ivl, lastIvl, factor, time, type from revlog")
                let ins = try db.prepare("insert or ignore into revlog (id, cid, usn, ease, ivl, lastIvl, factor, time, type) values (?, ?, -1, ?, ?, ?, ?, ?, ?)")
                while try rs.step() {
                    guard let cid = cardMap[rs.integer(1)] else { continue }
                    try ins.bind([rs.integer(0), cid, rs.integer(3), rs.integer(4), rs.integer(5), rs.integer(6), rs.integer(7), rs.integer(8)]).run()
                }
            }
            // Notes whose type gained cards in this collection.
            for (_, nid) in noteMap { if let n = note(nid) { try generateCards(for: n, deckID: nil) } }
            try markModified()
        }
        return result
    }

    /// Writes the whole collection as a `.colpkg` (current format, readable by Anki 2.1.50+ and AnkiDroid).
    public func exportCollectionPackage(to url: URL, includeMedia: Bool = true) throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("inni-export-\(UUID().uuidString).anki2")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try snapshot(to: tmp)
        let files = includeMedia ? MediaFiles.list(mediaFolder) : []
        try AnkiPackage.write(to: url, collection: tmp, media: files.map { mediaFolder.appendingPathComponent($0) })
    }

    /// Writes one deck (with subdecks) as an `.apkg`.
    public func exportDeckPackage(_ deckID: DeckID?, to url: URL, includeScheduling: Bool, includeMedia: Bool = true) throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("inni-export-\(UUID().uuidString).anki2")
        defer {
            for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: tmp.path + s) }
        }
        try snapshot(to: tmp)
        let out = try Collection(url: tmp)
        var mediaNames = Set<String>()
        try out.db.transaction {
            if let deckID {
                let keep = deckAndChildren(deckID).map(\.id)
                let list = keep.map(String.init).joined(separator: ",")
                try out.db.exec("delete from cards where did not in (\(list)) and odid not in (\(list))")
                try out.db.exec("delete from notes where id not in (select nid from cards)")
                try out.db.exec("delete from decks where id not in (\(list)) and id != 1")
            }
            try out.db.exec("update cards set did = odid, due = odue where odid != 0")
            try out.db.exec("update cards set odid = 0, odue = 0")
            try out.db.exec("delete from decks where substr(kind, 1, 1) = x'12'")
            if includeScheduling {
                try out.db.exec("delete from revlog where cid not in (select id from cards)")
            } else {
                try out.db.exec("delete from revlog")
                try out.db.exec("update cards set type = 0, queue = 0, ivl = 0, factor = 0, reps = 0, lapses = 0, left = 0, flags = 0, data = '', due = (select count() from notes n2 where n2.id <= cards.nid)")
                try out.db.exec("update notes set tags = trim(replace(replace(' ' || tags || ' ', ' leech ', ' '), ' marked ', ' '))")
                try out.db.exec("update notes set tags = case when tags = '' then '' else ' ' || tags || ' ' end")
            }
            try out.db.exec("delete from notetypes where id not in (select distinct mid from notes)")
            try out.db.exec("delete from fields where ntid not in (select id from notetypes)")
            try out.db.exec("delete from templates where ntid not in (select id from notetypes)")
            try out.db.exec("delete from graves")
            try out.db.exec("update cards set usn = 0; update notes set usn = 0; update revlog set usn = 0")
            if includeMedia {
                let s = try out.db.prepare("select flds from notes")
                while try s.step() { mediaNames.formUnion(HTML.mediaReferences(s.text(0))) }
                let tmpl = try out.db.prepare("select config from templates union all select config from notetypes")
                var text = ""
                while try tmpl.step() { text += String(decoding: tmpl.blob(0), as: UTF8.self) }
                for f in MediaFiles.list(mediaFolder) where f.hasPrefix("_") && text.contains(f) { mediaNames.insert(f) }
            }
        }
        if try out.db.scalar("select count() from notetypes") == 0 {
            throw CollectionError("Nothing to export.")
        }
        try out.db.exec("VACUUM")
        out.close()
        let files = mediaNames.sorted().map { mediaFolder.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        try AnkiPackage.write(to: url, collection: tmp, media: files)
    }
}

extension AnkiPackage {
    static func write(to url: URL, collection: URL, media: [URL]) throws {
        try? FileManager.default.removeItem(at: url)
        let zip = try ZipWriter(url: url)
        // Inni's zstd frames are stored blocks, so the zip layer does the compressing.
        try zip.add("collection.anki21b", Zstd.frame(try Data(contentsOf: collection, options: .alwaysMapped)), deflate: true)
        let packed: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "heic", "avif", "mp3", "m4a", "aac", "ogg", "oga", "opus",
                                   "mp4", "m4v", "webm", "mov", "zip", "gz", "woff", "woff2"]
        var entries: [Proto] = []
        for (i, file) in media.enumerated() {
            try autoreleasepool {
                let data = try Data(contentsOf: file, options: .alwaysMapped)
                try zip.add(String(i), Zstd.frame(data), deflate: !packed.contains(file.pathExtension.lowercased()))
                var e = Proto()
                e.setString(1, file.lastPathComponent)
                e.setUInt(2, UInt64(data.count))
                e.setBytes(3, Data(Insecure.SHA1.hash(data: data)))
                entries.append(e)
            }
        }
        var list = Proto()
        list.setMessages(1, entries)
        try zip.add("media", Zstd.frame(list.encoded), deflate: true)
        var meta = Proto()
        meta.setUInt(1, 3)
        try zip.add("meta", meta.encoded)
        try zip.finish()
    }
}

public enum MediaFiles {
    public static func list(_ folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { !$0.hasPrefix(".") && isSafeName($0) }
            .filter { var dir: ObjCBool = false; return FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path, isDirectory: &dir) && !dir.boolValue }
            .sorted()
    }

    public static func isSafeName(_ n: String) -> Bool {
        !n.isEmpty && !n.contains("/") && !n.contains("\\") && n != "." && n != ".." && !n.hasPrefix("..")
    }

    static func uniqueName(for name: String, data: Data) -> String {
        let hash = Insecure.SHA1.hash(data: data).prefix(4).map { String(format: "%02x", $0) }.joined()
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        return ext.isEmpty ? "\(stem)-\(hash)" : "\(stem)-\(hash).\(ext)"
    }

    /// Stores data in the media folder under a name that doesn't clash; returns the name used.
    public static func add(_ data: Data, preferredName: String, to folder: URL) throws -> String {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var name = preferredName.replacingOccurrences(of: "/", with: "_")
        if name.isEmpty { name = "pasted" }
        let target = folder.appendingPathComponent(name)
        if let existing = try? Data(contentsOf: target, options: .alwaysMapped) {
            if existing == data { return name }
            name = uniqueName(for: name, data: data)
        }
        try data.write(to: folder.appendingPathComponent(name))
        return name
    }
}
