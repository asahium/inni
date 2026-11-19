import Foundation

/// Upgrades a schema 11 collection (JSON in the `col` row, as in older `.apkg` files) to schema 18.
enum SchemaUpgrade {
    static func upgrade(_ db: SQLiteDB) throws {
        let s = try db.prepare("select conf, models, decks, dconf, tags from col")
        guard try s.step() else { throw CollectionError("Empty col table.") }
        func json(_ i: Int32) -> JSONObject {
            (try? JSONSerialization.jsonObject(with: Data(s.text(i).utf8))) as? JSONObject ?? [:]
        }
        let conf = json(0), models = json(1), decks = json(2), dconf = json(3), tags = json(4)
        let now = Collection.nowSecs

        try db.transaction {
            try db.exec(Schema.modernTables)
            for case let m as JSONObject in models.values {
                var nt = Schema11.notetype(m)
                nt.name = try uniqueName(nt.name.isEmpty ? "Note Type" : nt.name, table: "notetypes", db)
                try db.run("insert or replace into notetypes values (?, ?, ?, ?, ?)", nt.id, nt.name, nt.mtime, nt.usn, nt.config.encoded)
                for f in nt.fields {
                    try db.run("insert or replace into fields values (?, ?, ?, ?)", nt.id, f.ord, f.name, f.config.encoded)
                }
                for t in nt.templates {
                    try db.run("insert or replace into templates values (?, ?, ?, ?, ?, ?)", nt.id, t.ord, t.name, nt.mtime, nt.usn, t.config.encoded)
                }
            }
            for case let o as JSONObject in decks.values {
                var d = Schema11.deck(o)
                if d.mtime == 0 { d.mtime = now }
                let name = try uniqueName(d.name.replacingOccurrences(of: "::", with: "\u{1f}"), table: "decks", db)
                try db.run("insert or replace into decks values (?, ?, ?, ?, ?, ?)", d.id, name, d.mtime, d.usn, d.common.encoded, d.kind.encoded)
            }
            for case let o as JSONObject in dconf.values {
                var c = Schema11.deckConfig(o)
                if c.mtime == 0 { c.mtime = now }
                try db.run("insert or replace into deck_config values (?, ?, ?, ?, ?)", c.id, c.name.isEmpty ? "Default" : c.name, c.mtime, c.usn, c.config.encoded)
            }
            if try db.scalar("select count() from deck_config") == 0 {
                try db.run("insert into deck_config values (1, 'Default', ?, 0, ?)", now, DeckConfig(id: 1, name: "Default").config.encoded)
            }

            for (k, v) in conf {
                let data = (try? JSONSerialization.data(withJSONObject: v, options: [.fragmentsAllowed])) ?? Data("null".utf8)
                try db.run("insert or replace into config values (?, 0, ?, ?)", k, now, data)
            }
            for (t, usn) in tags {
                try db.run("insert or replace into tags values (?, ?, 0, null)", t, Schema11.int(usn))
            }
            try db.exec("update col set ver = 18, conf = '', models = '', decks = '', dconf = '', tags = ''")
            try db.exec(Schema.indexes)
        }
    }

    private static func uniqueName(_ name: String, table: String, _ db: SQLiteDB) throws -> String {
        var candidate = name
        while try db.scalar("select 1 from \(table) where name = ?", candidate) != nil { candidate += "+" }
        return candidate
    }
}
