import CryptoKit
import Foundation

public struct CollectionError: Error, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// An Anki collection (`collection.anki2`, schema 18) opened in place.
/// Writes follow Anki's rules (usn -1, mtime, col.mod) so Anki and AnkiWeb sync see them as local changes.
/// Not thread-safe: use from one thread.
public final class Collection {
    public let url: URL
    let db: SQLiteDB
    public internal(set) var notetypes: [NotetypeID: Notetype] = [:]
    public internal(set) var decks: [DeckID: Deck] = [:]
    public internal(set) var deckConfigs: [DeckConfigID: DeckConfig] = [:]
    public private(set) var creationSecs: Int = 0
    /// Bumped on every write so views can refresh.
    public private(set) var revision = 0

    public var mediaFolder: URL { url.deletingPathExtension().appendingPathExtension("media") }

    public init(url: URL, readOnly: Bool = false) throws {
        self.url = url
        db = try SQLiteDB(path: url.path, readOnly: readOnly)
        if !readOnly {
            do {
                try db.exec("PRAGMA locking_mode = exclusive; PRAGMA journal_mode = wal; PRAGMA foreign_keys = off")
                // Taking the write lock now fails fast if Anki has the collection open.
                try db.exec("BEGIN IMMEDIATE; COMMIT")
            } catch let e as SQLiteError where e.isBusy {
                throw CollectionError("The collection is open in another program (close Anki first).")
            }
        }
        let ver = try db.scalar("select ver from col") ?? 0
        if ver == 11 {
            guard !readOnly else { throw LegacySchema() }
            try SchemaUpgrade.upgrade(db)
        } else if ver < 11 || ver > 18 {
            throw CollectionError("Unsupported collection version \(ver).")
        }
        try reload()
        if !readOnly { try? FileManager.default.createDirectory(at: mediaFolder, withIntermediateDirectories: true) }
    }

    struct LegacySchema: Error {}

    public static func create(at url: URL) throws -> Collection {
        guard !FileManager.default.fileExists(atPath: url.path) else { throw CollectionError("\(url.lastPathComponent) already exists.") }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let db = try SQLiteDB(path: url.path)
        try Schema.create(db)
        db.close()
        return try Collection(url: url)
    }

    public func close() {
        checkpoint()
        db.close()
    }

    /// Folds the WAL back into the main file so a plain copy of it is complete.
    public func checkpoint() {
        try? db.exec("PRAGMA wal_checkpoint(TRUNCATE)")
    }

    public func reload() throws {
        creationSecs = try db.scalar("select crt from col") ?? 0
        try loadNotetypes()
        try loadDecks()
        try loadDeckConfigs()
        revision += 1
    }

    // MARK: Time & usn

    static var nowMillis: Int { Int(Date().timeIntervalSince1970 * 1000) }
    static var nowSecs: Int { Int(Date().timeIntervalSince1970) }

    func markModified() throws {
        try db.run("update col set mod = ?", Collection.nowMillis)
        revision += 1
    }

    /// Changes that require a one-way (full) sync, like editing a notetype's fields.
    func markSchemaModified() throws {
        try db.run("update col set scm = ?", Collection.nowMillis)
    }

    /// Makes the next sync one-way, for when the two sides got out of step.
    public func requireFullSync() throws {
        try markSchemaModified()
        try markModified()
    }

    /// The scheduler day boundary.
    public var timing: SchedTiming {
        let creationOffset = configInt("creationOffset") ?? SchedTiming.localMinutesWest()
        return SchedTiming(createdSecs: creationSecs, createdMinsWest: creationOffset, nowSecs: Collection.nowSecs,
                           nowMinsWest: SchedTiming.localMinutesWest(), rolloverHour: configInt("rollover") ?? 4)
    }

    public var today: Int { timing.daysElapsed }

    // MARK: Config (JSON values in the config table)

    public func configData(_ key: String) -> Data? {
        guard let s = try? db.prepare("select val from config where key = ?").bind([key]), (try? s.step()) == true else { return nil }
        return s.blob(0)
    }

    public func config<T: Decodable>(_ key: String, as: T.Type = T.self) -> T? {
        configData(key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    public func configInt(_ key: String) -> Int? {
        configData(key).flatMap { Int(String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespaces)) }
    }

    public func configBool(_ key: String) -> Bool? { config(key, as: Bool.self) }

    public func setConfig<T: Encodable>(_ key: String, _ value: T) throws {
        let data = try JSONEncoder().encode(value)
        try db.run("insert or replace into config (key, usn, mtime_secs, val) values (?, -1, ?, ?)", key, Collection.nowSecs, data)
        try markModified()
    }

    public var fsrsEnabled: Bool { configBool("fsrs") ?? false }

    public var currentDeckID: DeckID {
        get { configInt("curDeck").flatMap { decks[$0] != nil ? $0 : nil } ?? 1 }
        set { try? setConfig("curDeck", newValue) }
    }

    // MARK: Notetypes

    private func loadNotetypes() throws {
        var fields: [NotetypeID: [Notetype.Field]] = [:]
        let fs = try db.prepare("select ntid, ord, name, config from fields order by ntid, ord")
        while try fs.step() {
            fields[fs.integer(0), default: []].append(Notetype.Field(ord: fs.integer(1), name: fs.text(2), config: Proto(fs.blob(3))))
        }
        var templates: [NotetypeID: [Notetype.Template]] = [:]
        let ts = try db.prepare("select ntid, ord, name, mtime_secs, usn, config from templates order by ntid, ord")
        while try ts.step() {
            templates[ts.integer(0), default: []].append(
                Notetype.Template(ord: ts.integer(1), name: ts.text(2), mtime: ts.integer(3), usn: ts.integer(4), config: Proto(ts.blob(5))))
        }
        var out: [NotetypeID: Notetype] = [:]
        let s = try db.prepare("select id, name, mtime_secs, usn, config from notetypes")
        while try s.step() {
            let id = s.integer(0)
            out[id] = Notetype(id: id, name: s.text(1), mtime: s.integer(2), usn: s.integer(3), config: Proto(s.blob(4)),
                               fields: fields[id] ?? [], templates: templates[id] ?? [])
        }
        notetypes = out
    }

    public var sortedNotetypes: [Notetype] {
        notetypes.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func notetype(named name: String) -> Notetype? {
        notetypes.values.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Adds or replaces a notetype. Changing fields or templates of an existing one rewrites notes and cards to match.
    /// Fields and templates keep their original `ord` until saved, which is how existing note content follows them
    /// through renames and reordering; new ones use -1.
    @discardableResult
    public func save(_ nt: Notetype) throws -> Notetype {
        var nt = nt
        let existing = notetypes[nt.id]
        try db.transaction {
            if nt.id == 0 { nt.id = try uniqueID(table: "notetypes") }
            nt.name = uniqueNotetypeName(nt.name, excluding: nt.id)
            nt.mtime = Collection.nowSecs
            nt.usn = -1
            let oldFields = existing?.fields.count ?? 0, oldTemplates = existing?.templates.count ?? 0
            let fieldMap = nt.fields.map { $0.ord >= 0 && $0.ord < oldFields ? $0.ord : nil }
            let templateMap = nt.templates.map { $0.ord >= 0 && $0.ord < oldTemplates ? $0.ord : nil }
            let oldTemplateConfigs = existing?.templates.map(\.config) ?? []
            for i in nt.fields.indices { nt.fields[i].ord = i }
            for i in nt.templates.indices { nt.templates[i].ord = i }
            if nt.sortFieldIndex >= nt.fields.count { nt.sortFieldIndex = 0 }
            let fieldsChanged = existing != nil && fieldMap != Array(0..<oldFields).map(Optional.some)
            let templatesChanged = existing != nil && templateMap != Array(0..<oldTemplates).map(Optional.some)
            if let old = existing, fieldsChanged || templatesChanged || old.fields.map(\.name) != nt.fields.map(\.name) {
                try markSchemaModified()
            }
            try db.run("insert or replace into notetypes (id, name, mtime_secs, usn, config) values (?, ?, ?, ?, ?)",
                       nt.id, nt.name, nt.mtime, nt.usn, nt.config.encoded)
            try db.run("delete from fields where ntid = ?", nt.id)
            for f in nt.fields {
                try db.run("insert into fields (ntid, ord, name, config) values (?, ?, ?, ?)", nt.id, f.ord, f.name, f.config.encoded)
            }
            try db.run("delete from templates where ntid = ?", nt.id)
            for (i, var t) in nt.templates.enumerated() {
                if templateMap[i].map({ oldTemplateConfigs[$0] }) != t.config || t.mtime == 0 {
                    t.mtime = Collection.nowSecs
                    t.usn = -1
                }
                try db.run("insert into templates (ntid, ord, name, mtime_secs, usn, config) values (?, ?, ?, ?, ?, ?)",
                           nt.id, t.ord, t.name, t.mtime, t.usn, t.config.encoded)
            }
            notetypes[nt.id] = nt
            if existing != nil {
                try reconcileNotes(of: nt, fieldMap: fieldsChanged ? fieldMap : nil, templateMap: templatesChanged ? templateMap : nil)
            }
            try markModified()
        }
        return nt
    }

    public func remove(notetype id: NotetypeID) throws {
        guard notetypes.count > 1 else { throw CollectionError("A collection needs at least one note type.") }
        try db.transaction {
            let nids = try db.prepare("select id from notes where mid = ?").bind([id]).map { $0.integer(0) }
            try remove(notes: nids)
            try db.run("delete from notetypes where id = ?", id)
            try db.run("delete from fields where ntid = ?", id)
            try db.run("delete from templates where ntid = ?", id)
            try markSchemaModified()
            try markModified()
        }
        notetypes[id] = nil
    }

    private func uniqueNotetypeName(_ name: String, excluding id: NotetypeID) -> String {
        var candidate = name.isEmpty ? "Note Type" : name
        var n = 1
        while notetypes.values.contains(where: { $0.id != id && $0.name.caseInsensitiveCompare(candidate) == .orderedSame }) {
            n += 1
            candidate = "\(name)-\(n)"
        }
        return candidate
    }

    /// Fields renamed/added/removed by name; templates by position.
    private func reconcileNotes(of nt: Notetype, fieldMap: [Int?]?, templateMap: [Int?]?) throws {
        if let mapping = fieldMap {
            let s = try db.prepare("select id, flds from notes where mid = ?").bind([nt.id])
            var updates: [(Int, String)] = []
            while try s.step() {
                let fields = s.text(1).components(separatedBy: "\u{1f}")
                let mapped = mapping.map { $0.flatMap { $0 < fields.count ? fields[$0] : nil } ?? "" }
                updates.append((s.integer(0), mapped.joined(separator: "\u{1f}")))
            }
            let u = try db.prepare("update notes set flds = ?, sfld = ?, csum = ?, mod = ?, usn = -1 where id = ?")
            for (id, flds) in updates {
                let fields = flds.components(separatedBy: "\u{1f}")
                try u.bind([flds, Collection.sortField(fields, nt), Collection.checksum(fields.first ?? ""), Collection.nowSecs, id]).run()
            }
        }
        if let mapping = templateMap, !nt.isCloze {
            let kept = Set(mapping.compactMap { $0 })
            let s = try db.prepare("select id, ord from cards where nid in (select id from notes where mid = ?)").bind([nt.id])
            var removed: [CardID] = [], moved: [(CardID, Int)] = []
            while try s.step() {
                let ord = s.integer(1)
                if !kept.contains(ord) { removed.append(s.integer(0)) }
                else if let to = mapping.firstIndex(of: ord), to != ord { moved.append((s.integer(0), to)) }
            }
            try remove(cards: removed, removeOrphanNotes: false)
            let u = try db.prepare("update cards set ord = ?, mod = ?, usn = -1 where id = ?")
            for (id, ord) in moved { try u.bind([ord, Collection.nowSecs, id]).run() }
        }
        let nids = try db.prepare("select id from notes where mid = ?").bind([nt.id]).map { $0.integer(0) }
        for nid in nids { if let n = note(nid) { try generateCards(for: n, deckID: nil) } }
    }

    // MARK: Decks

    private func loadDecks() throws {
        var out: [DeckID: Deck] = [:]
        let s = try db.prepare("select id, name, mtime_secs, usn, common, kind from decks")
        while try s.step() {
            let id = s.integer(0)
            out[id] = Deck(id: id, name: s.text(1).replacingOccurrences(of: "\u{1f}", with: "::"), mtime: s.integer(2),
                           usn: s.integer(3), common: Proto(s.blob(4)), kind: Proto(s.blob(5)))
        }
        decks = out
    }

    public var sortedDecks: [Deck] {
        decks.values.sorted { a, b in
            a.components.lexicographicallyPrecedes(b.components) { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        }
    }

    public func deck(named name: String) -> Deck? {
        decks.values.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// The deck and all decks below it.
    public func deckAndChildren(_ id: DeckID) -> [Deck] {
        guard let d = decks[id] else { return [] }
        let prefix = d.name + "::"
        return [d] + decks.values.filter { $0.name.hasPrefix(prefix) }.sorted { $0.name < $1.name }
    }

    public func parents(of deck: Deck) -> [Deck] {
        var out: [Deck] = []
        var comps = deck.components
        while comps.count > 1 {
            comps.removeLast()
            if let p = self.deck(named: comps.joined(separator: "::")) { out.insert(p, at: 0) }
        }
        return out
    }

    /// Returns the id of the deck with this name, creating it (and missing parents).
    public func deckID(named rawName: String, create: Bool = true) throws -> DeckID? {
        let name = Collection.normalizeDeckName(rawName)
        if let d = deck(named: name) { return d.id }
        guard create else { return nil }
        let comps = name.components(separatedBy: "::")
        var id: DeckID = 1
        for i in comps.indices {
            let sub = comps[...i].joined(separator: "::")
            if let d = deck(named: sub) {
                id = d.id
            } else {
                id = try save(Deck(name: sub)).id
            }
        }
        return id
    }

    static func normalizeDeckName(_ s: String) -> String {
        let parts = s.components(separatedBy: "::").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return parts.isEmpty ? "Default" : parts.joined(separator: "::")
    }

    @discardableResult
    public func save(_ deck: Deck) throws -> Deck {
        var d = deck
        d.name = Collection.normalizeDeckName(d.name)
        if d.id == 0 {
            d.id = try uniqueID(table: "decks")
        }
        if let clash = self.deck(named: d.name), clash.id != d.id { throw CollectionError("A deck named “\(d.name)” already exists.") }
        let old = decks[d.id]
        d.mtime = Collection.nowSecs
        d.usn = -1
        try db.transaction {
            try db.run("insert or replace into decks (id, name, mtime_secs, usn, common, kind) values (?, ?, ?, ?, ?, ?)",
                       d.id, d.name.replacingOccurrences(of: "::", with: "\u{1f}"), d.mtime, d.usn, d.common.encoded, d.kind.encoded)
            decks[d.id] = d
            if let old, old.name != d.name {
                // Renaming moves children along.
                for child in decks.values where child.name.hasPrefix(old.name + "::") {
                    var c = child
                    c.name = d.name + child.name.dropFirst(old.name.count)
                    try save(c)
                }
            }
            if let parent = d.parentName, self.deck(named: parent) == nil { _ = try deckID(named: parent) }
            try markModified()
        }
        return d
    }

    /// Removes decks with their children and cards (cards of filtered decks go home instead).
    public func remove(deck id: DeckID) throws {
        let all = deckAndChildren(id)
        try db.transaction {
            for d in all {
                if d.isFiltered {
                    try emptyFiltered(d.id)
                } else {
                    let cids = try db.prepare("select id from cards where did = ? or odid = ?").bind([d.id, d.id]).map { $0.integer(0) }
                    try remove(cards: cids)
                }
                try db.run("delete from decks where id = ?", d.id)
                try addGrave(d.id, type: 2)
                decks[d.id] = nil
            }
            if decks.isEmpty || decks[1] == nil {
                var def = Deck(id: 1, name: "Default")
                if self.deck(named: "Default") != nil { def.name = "Default-\(Collection.nowSecs)" }
                try save(def)
            }
            try markModified()
        }
    }

    // MARK: Deck options

    private func loadDeckConfigs() throws {
        var out: [DeckConfigID: DeckConfig] = [:]
        let s = try db.prepare("select id, name, mtime_secs, usn, config from deck_config")
        while try s.step() {
            let id = s.integer(0)
            out[id] = DeckConfig(id: id, name: s.text(1), mtime: s.integer(2), usn: s.integer(3), config: Proto(s.blob(4)))
        }
        deckConfigs = out
    }

    public func config(for deck: Deck) -> DeckConfig {
        deckConfigs[deck.configID] ?? deckConfigs[1] ?? DeckConfig(id: 1, name: "Default")
    }

    @discardableResult
    public func save(_ conf: DeckConfig) throws -> DeckConfig {
        var c = conf
        if c.id == 0 { c.id = try uniqueID(table: "deck_config") }
        c.mtime = Collection.nowSecs
        c.usn = -1
        try db.run("insert or replace into deck_config (id, name, mtime_secs, usn, config) values (?, ?, ?, ?, ?)",
                   c.id, c.name, c.mtime, c.usn, c.config.encoded)
        deckConfigs[c.id] = c
        try markModified()
        return c
    }

    // MARK: Notes

    public func note(_ id: NoteID) -> Note? {
        guard let s = try? db.prepare("select id, guid, mid, mod, usn, tags, flds, flags, data from notes where id = ?").bind([id]),
              (try? s.step()) == true else { return nil }
        return Collection.note(from: s)
    }

    static func note(from s: Statement) -> Note {
        var n = Note(id: s.integer(0), guid: s.text(1), notetypeID: s.integer(2), mtime: s.integer(3), usn: s.integer(4),
                     tags: Note.splitTags(s.text(5)), fields: s.text(6).components(separatedBy: "\u{1f}"))
        n.flags = s.integer(7)
        n.data = s.text(8)
        return n
    }

    public func noteCount() -> Int { (try? db.scalar("select count() from notes")) ?? 0 }
    public func cardCount() -> Int { (try? db.scalar("select count() from cards")) ?? 0 }

    /// Adds a note and its cards. Fields are padded/truncated to the notetype.
    @discardableResult
    public func add(_ note: Note, deckID: DeckID) throws -> Note {
        guard let nt = notetypes[note.notetypeID] else { throw CollectionError("Unknown note type.") }
        var n = note
        n.fields = Array((n.fields + Array(repeating: "", count: max(0, nt.fields.count - n.fields.count))).prefix(nt.fields.count))
        let ords = cardOrdinals(for: n, nt)
        guard !ords.isEmpty else {
            throw CollectionError(nt.isCloze ? "This note has no cloze deletions ({{c1::…}})." : "The first field is empty, so no cards would be made.")
        }
        try db.transaction {
            n.id = try uniqueTimestampID(table: "notes")
            n.mtime = Collection.nowSecs
            n.usn = -1
            try writeNote(n, nt)
            try registerTags(n.tags)
            try generateCards(for: n, deckID: deckID, ords: ords)
            try markModified()
        }
        return n
    }

    public func update(_ note: Note) throws {
        guard let nt = notetypes[note.notetypeID] else { throw CollectionError("Unknown note type.") }
        var n = note
        if let old = self.note(n.id), old.fields == n.fields, old.tags == n.tags { return }
        try db.transaction {
            n.mtime = Collection.nowSecs
            n.usn = -1
            try writeNote(n, nt)
            try registerTags(n.tags)
            try generateCards(for: n, deckID: nil)
            try markModified()
        }
    }

    func writeNote(_ n: Note, _ nt: Notetype) throws {
        try db.run("""
            insert or replace into notes (id, guid, mid, mod, usn, tags, flds, sfld, csum, flags, data)
            values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, n.id, n.guid, n.notetypeID, n.mtime, n.usn, n.joinedTags, n.joinedFields, Collection.sortField(n.fields, nt),
                   Collection.checksum(n.fields.first ?? ""), n.flags, n.data)
    }

    public func remove(notes ids: [NoteID]) throws {
        guard !ids.isEmpty else { return }
        try db.transaction {
            for chunk in ids.chunked(500) {
                let list = chunk.map(String.init).joined(separator: ",")
                let cids = try db.prepare("select id from cards where nid in (\(list))").map { $0.integer(0) }
                try remove(cards: cids, removeOrphanNotes: false)
                try db.exec("delete from notes where id in (\(list))")
                for id in chunk { try addGrave(id, type: 1) }
            }
            try markModified()
        }
    }

    static func sortField(_ fields: [String], _ nt: Notetype) -> String {
        let i = nt.sortFieldIndex < fields.count ? nt.sortFieldIndex : 0
        return HTML.strip(fields.isEmpty ? "" : fields[i], keepMediaNames: true)
    }

    /// First 4 bytes of the SHA-1 of the stripped first field, like Anki's duplicate check.
    public static func checksum(_ field: String) -> Int {
        let digest = Insecure.SHA1.hash(data: Data(HTML.strip(field, keepMediaNames: true).utf8))
        return digest.prefix(4).reduce(0) { $0 << 8 | Int($1) }
    }

    /// Notes of the same type whose first field matches.
    public func duplicates(of note: Note) -> [NoteID] {
        let first = HTML.strip(note.fields.first ?? "", keepMediaNames: true)
        guard !first.isEmpty, let s = try? db.prepare("select id, flds from notes where mid = ? and csum = ? and id != ?")
            .bind([note.notetypeID, Collection.checksum(note.fields.first ?? ""), note.id]) else { return [] }
        var out: [NoteID] = []
        while (try? s.step()) == true {
            let f = s.text(1).components(separatedBy: "\u{1f}").first ?? ""
            if HTML.strip(f, keepMediaNames: true) == first { out.append(s.integer(0)) }
        }
        return out
    }

    // MARK: Tags

    func registerTags(_ tags: [String]) throws {
        let s = try db.prepare("insert or ignore into tags (tag, usn, collapsed) values (?, -1, 0)")
        for t in tags where !t.isEmpty { try s.bind([t]).run() }
    }

    public func allTags() -> [String] {
        (try? db.prepare("select tag from tags order by tag collate unicase").map { $0.text(0) }) ?? []
    }

    public func addTags(_ tags: [String], to noteIDs: [NoteID]) throws {
        try db.transaction {
            for id in noteIDs {
                guard var n = note(id) else { continue }
                let missing = tags.filter { !n.hasTag($0) }
                guard !missing.isEmpty else { continue }
                n.tags += missing
                try update(n)
            }
        }
    }

    public func removeTags(_ tags: [String], from noteIDs: [NoteID]) throws {
        try db.transaction {
            for id in noteIDs {
                guard var n = note(id) else { continue }
                let before = n.tags.count
                n.tags.removeAll { t in tags.contains { $0.caseInsensitiveCompare(t) == .orderedSame } }
                if n.tags.count != before { try update(n) }
            }
        }
    }

    // MARK: Cards

    static let cardColumns = "id, nid, did, ord, mod, usn, type, queue, due, ivl, factor, reps, lapses, left, odue, odid, flags, data"

    static func card(from s: Statement) -> Card {
        var c = Card(id: s.integer(0), noteID: s.integer(1), deckID: s.integer(2), ord: s.integer(3), due: s.integer(8))
        c.mtime = s.integer(4)
        c.usn = s.integer(5)
        c.type = CardType(rawValue: s.integer(6)) ?? .new
        c.queue = CardQueue(rawValue: s.integer(7)) ?? .new
        c.interval = s.integer(9)
        c.factor = s.integer(10)
        c.reps = s.integer(11)
        c.lapses = s.integer(12)
        c.left = s.integer(13)
        c.originalDue = s.integer(14)
        c.originalDeckID = s.integer(15)
        c.flags = s.integer(16)
        c.data = CardData(json: s.text(17))
        return c
    }

    public func card(_ id: CardID) -> Card? {
        guard let s = try? db.prepare("select \(Collection.cardColumns) from cards where id = ?").bind([id]),
              (try? s.step()) == true else { return nil }
        return Collection.card(from: s)
    }

    public func cards(ofNote nid: NoteID) -> [Card] {
        (try? db.prepare("select \(Collection.cardColumns) from cards where nid = ? order by ord").bind([nid]).map(Collection.card)) ?? []
    }

    public func cards(_ ids: [CardID]) -> [Card] {
        var out: [Card] = []
        for chunk in ids.chunked(500) {
            let list = chunk.map(String.init).joined(separator: ",")
            out += (try? db.prepare("select \(Collection.cardColumns) from cards where id in (\(list))").map(Collection.card)) ?? []
        }
        return out
    }

    /// Writes a card as a local change.
    public func update(_ card: Card) throws {
        var c = card
        c.mtime = Collection.nowSecs
        c.usn = -1
        try writeCard(c)
        try markModified()
    }

    func writeCard(_ c: Card) throws {
        try db.run("""
            insert or replace into cards (\(Collection.cardColumns))
            values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, c.id, c.noteID, c.deckID, c.ord, c.mtime, c.usn, c.type.rawValue, c.queue.rawValue, c.due, c.interval,
                   c.factor, c.reps, c.lapses, c.left, c.originalDue, c.originalDeckID, c.flags, c.data.json)
    }

    public func remove(cards ids: [CardID], removeOrphanNotes: Bool = true) throws {
        guard !ids.isEmpty else { return }
        try db.transaction {
            var nids = Set<Int>()
            for chunk in ids.chunked(500) {
                let list = chunk.map(String.init).joined(separator: ",")
                if removeOrphanNotes { nids.formUnion(try db.prepare("select distinct nid from cards where id in (\(list))").map { $0.integer(0) }) }
                try db.exec("delete from cards where id in (\(list))")
                for id in chunk { try addGrave(id, type: 0) }
            }
            if removeOrphanNotes {
                let orphans = try nids.filter { try db.scalar("select count() from cards where nid = ?", $0) == 0 }
                for chunk in Array(orphans).chunked(500) {
                    try db.exec("delete from notes where id in (\(chunk.map(String.init).joined(separator: ",")))")
                    for id in chunk { try addGrave(id, type: 1) }
                }
            }
            try markModified()
        }
    }

    /// Which card ordinals a note should have.
    public func cardOrdinals(for note: Note, _ nt: Notetype) -> [Int] {
        if nt.isCloze {
            guard let front = nt.templates.first?.front else { return [] }
            let clozeFields = Template.parse(front).clozeFields()
            var ords = Set<Int>()
            for name in clozeFields {
                if let i = nt.fieldIndex(name), i < note.fields.count { ords.formUnion(Cloze.ordinals(in: note.fields[i])) }
            }
            return ords.filter { $0 > 0 }.map { $0 - 1 }.sorted()
        }
        let nonempty = Set(nt.fields.indices.filter { $0 < note.fields.count && !HTML.isEmptyField(note.fields[$0]) }.map { nt.fields[$0].name })
        return nt.templates.filter { Template.parse($0.front).rendersWith(nonempty) }.map(\.ord)
    }

    /// Adds missing cards for a note. New cards go to `deckID`, the template's deck, or the deck of an existing sibling.
    func generateCards(for note: Note, deckID: DeckID?, ords: [Int]? = nil) throws {
        guard let nt = notetypes[note.notetypeID] else { return }
        let want = ords ?? cardOrdinals(for: note, nt)
        let have = cards(ofNote: note.id)
        let missing = want.filter { o in !have.contains { $0.ord == o } }
        guard !missing.isEmpty else { return }
        let fallbackDeck = deckID ?? have.first?.homeDeckID ?? currentDeckID
        var pos = configInt("nextPos") ?? 1
        if let existingPos = have.first(where: { $0.type == .new })?.due { pos = existingPos }
        else { try setConfig("nextPos", pos + 1) }
        for ord in missing {
            var did = fallbackDeck
            if !nt.isCloze, ord < nt.templates.count {
                let t = nt.templates[ord].targetDeckID
                if t != 0, let d = decks[t], !d.isFiltered { did = t }
            }
            if decks[did]?.isFiltered ?? true { did = decks[1] != nil ? 1 : (decks.keys.first ?? 1) }
            var c = Card(noteID: note.id, deckID: did, ord: ord, due: pos)
            c.id = try uniqueTimestampID(table: "cards")
            c.mtime = Collection.nowSecs
            try writeCard(c)
        }
    }

    /// Card ordinals with no content (for "Empty Cards").
    public func emptyCards() -> [CardID] {
        var out: [CardID] = []
        guard let s = try? db.prepare("select id, guid, mid, mod, usn, tags, flds, flags, data from notes") else { return [] }
        while (try? s.step()) == true {
            let n = Collection.note(from: s)
            guard let nt = notetypes[n.notetypeID] else { continue }
            let ords = Set(cardOrdinals(for: n, nt))
            out += cards(ofNote: n.id).filter { !ords.contains($0.ord) }.map(\.id)
        }
        return out
    }

    // MARK: Card actions

    public func setDeck(_ cardIDs: [CardID], deckID: DeckID) throws {
        try db.transaction {
            for var c in cards(cardIDs) where !c.isFiltered {
                c.deckID = deckID
                try update(c)
            }
        }
    }

    public func setFlag(_ cardIDs: [CardID], flag: Int) throws {
        try db.transaction {
            for var c in cards(cardIDs) {
                c.flags = (c.flags & ~0b111) | (flag & 0b111)
                try update(c)
            }
        }
    }

    public func suspend(_ cardIDs: [CardID], _ on: Bool = true) throws {
        try db.transaction {
            for var c in cards(cardIDs) {
                if on { c.queue = .suspended } else if c.queue == .suspended { c.queue = Collection.naturalQueue(c) }
                try update(c)
            }
        }
    }

    public func bury(_ cardIDs: [CardID], _ on: Bool = true) throws {
        try db.transaction {
            for var c in cards(cardIDs) {
                if on { c.queue = .manuallyBuried } else if c.isBuried { c.queue = Collection.naturalQueue(c) }
                try update(c)
            }
        }
    }

    /// The queue a card belongs in when not suspended or buried.
    static func naturalQueue(_ c: Card) -> CardQueue {
        switch c.type {
        case .new: return .new
        case .review: return .review
        case .learning, .relearning: return c.due > 1_000_000_000 ? .learning : .dayLearning
        }
    }

    /// Forget: back to new at the end of the new queue.
    public func forget(_ cardIDs: [CardID], resetCounts: Bool = false) throws {
        try db.transaction {
            var pos = configInt("nextPos") ?? 1
            for var c in cards(cardIDs) {
                c.type = .new
                c.queue = .new
                c.due = pos
                pos += 1
                c.interval = 0
                c.factor = 0
                c.left = 0
                c.originalDue = 0
                c.originalDeckID = 0
                c.data.stability = nil
                c.data.difficulty = nil
                c.data.lastReview = nil
                if resetCounts {
                    c.reps = 0
                    c.lapses = 0
                }
                try update(c)
                try db.run("insert into revlog (id, cid, usn, ease, ivl, lastIvl, factor, time, type) values (?, ?, -1, 0, 0, 0, 0, 0, 4)",
                           try uniqueTimestampID(table: "revlog"), c.id)
            }
            try setConfig("nextPos", pos)
        }
    }

    /// Sets review cards due in a number of days.
    public func setDueDate(_ cardIDs: [CardID], days: Int) throws {
        let today = self.today
        try db.transaction {
            for var c in cards(cardIDs) {
                if c.type == .new || c.type == .learning { c.factor = Int((config(for: decks[c.homeDeckID] ?? Deck(name: "")).initialEase * 1000)) }
                c.type = .review
                c.queue = .review
                c.due = today + days
                c.interval = max(c.interval, max(1, days))
                c.originalDue = 0
                c.originalDeckID = 0
                try update(c)
            }
        }
    }

    public func revlog(for cardID: CardID) -> [RevlogEntry] {
        (try? db.prepare("select id, cid, usn, ease, ivl, lastIvl, factor, time, type from revlog where cid = ? order by id")
            .bind([cardID]).map(Collection.revlog)) ?? []
    }

    static func revlog(from s: Statement) -> RevlogEntry {
        RevlogEntry(id: s.integer(0), cardID: s.integer(1), usn: s.integer(2), ease: s.integer(3), interval: s.integer(4),
                    lastInterval: s.integer(5), factor: s.integer(6), time: s.integer(7),
                    kind: RevlogEntry.Kind(rawValue: s.integer(8)) ?? .manual)
    }

    func insert(_ r: RevlogEntry) throws {
        try db.run("insert into revlog (id, cid, usn, ease, ivl, lastIvl, factor, time, type) values (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                   r.id, r.cardID, r.usn, r.ease, r.interval, r.lastInterval, r.factor, r.time, r.kind.rawValue)
    }

    // MARK: Filtered decks

    /// Returns cards of a filtered deck to their home decks.
    public func emptyFiltered(_ did: DeckID) throws {
        try db.transaction {
            let ids = try db.prepare("select id from cards where did = ? and odid != 0").bind([did]).map { $0.integer(0) }
            for var c in cards(ids) {
                c.deckID = c.originalDeckID
                c.originalDeckID = 0
                if c.originalDue != 0 { c.due = c.originalDue }
                c.originalDue = 0
                if c.queue == .preview { c.queue = Collection.naturalQueue(c) }
                try update(c)
            }
        }
    }

    // MARK: Ids & graves

    func uniqueID(table: String) throws -> Int {
        var id = Collection.nowMillis
        while try db.scalar("select 1 from \(table) where id = ?", id) != nil { id += 1 }
        return id
    }

    private var lastTimestampID: [String: Int] = [:]

    /// Millisecond ids that stay unique within a burst of inserts.
    func uniqueTimestampID(table: String) throws -> Int {
        var id = max(Collection.nowMillis, (lastTimestampID[table] ?? 0) + 1)
        while try db.scalar("select 1 from \(table) where id = ?", id) != nil { id += 1 }
        lastTimestampID[table] = id
        return id
    }

    func addGrave(_ oid: Int, type: Int) throws {
        try db.run("insert or ignore into graves (oid, type, usn) values (?, ?, -1)", oid, type)
    }

    // MARK: Maintenance

    /// Fixes the common problems Anki's Check Database fixes.
    @discardableResult
    public func checkDatabase() throws -> [String] {
        var report: [String] = []
        try db.transaction {
            let badNotes = try db.prepare("select id from notes where mid not in (select id from notetypes)").map { $0.integer(0) }
            if !badNotes.isEmpty {
                try remove(notes: badNotes)
                report.append("Removed \(badNotes.count) notes with a missing note type.")
            }
            let orphanCards = try db.prepare("select id from cards where nid not in (select id from notes)").map { $0.integer(0) }
            if !orphanCards.isEmpty {
                try remove(cards: orphanCards, removeOrphanNotes: false)
                report.append("Removed \(orphanCards.count) cards without a note.")
            }
            let homeless = try db.prepare("select id from cards where did not in (select id from decks)").map { $0.integer(0) }
            if !homeless.isEmpty {
                try db.exec("update cards set did = 1, usn = -1 where id in (\(homeless.map(String.init).joined(separator: ",")))")
                report.append("Moved \(homeless.count) cards with a missing deck to Default.")
            }
            let noCards = try db.prepare("select id from notes where id not in (select distinct nid from cards)").map { $0.integer(0) }
            for nid in noCards { if let n = note(nid) { try generateCards(for: n, deckID: nil) } }
            try db.exec("update cards set due = 1000000 where type = 0 and due > 1000000")
            try db.exec("update cards set odue = 0 where odid = 0 and odue != 0")
            try markModified()
        }
        try db.exec("PRAGMA optimize; ANALYZE")
        if report.isEmpty { report.append("No problems found.") }
        return report
    }

    /// Copies the collection file consistently (for backups and export) while it stays open.
    public func snapshot(to dest: URL) throws {
        try? FileManager.default.removeItem(at: dest)
        try db.run("VACUUM INTO ?", dest.path)
    }
}

extension Array {
    func chunked(_ n: Int) -> [ArraySlice<Element>] {
        stride(from: 0, to: count, by: n).map { self[$0..<Swift.min($0 + n, count)] }
    }
}
