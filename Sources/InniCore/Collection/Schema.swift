import Foundation

/// Anki's schema 18, as Anki 2.1.50+ creates it.
enum Schema {
    static let tables = """
    CREATE TABLE col (
      id integer PRIMARY KEY, crt integer NOT NULL, mod integer NOT NULL, scm integer NOT NULL, ver integer NOT NULL,
      dty integer NOT NULL, usn integer NOT NULL, ls integer NOT NULL, conf text NOT NULL, models text NOT NULL,
      decks text NOT NULL, dconf text NOT NULL, tags text NOT NULL
    );
    CREATE TABLE notes (
      id integer PRIMARY KEY, guid text NOT NULL, mid integer NOT NULL, mod integer NOT NULL, usn integer NOT NULL,
      tags text NOT NULL, flds text NOT NULL, sfld integer NOT NULL, csum integer NOT NULL, flags integer NOT NULL,
      data text NOT NULL
    );
    CREATE TABLE cards (
      id integer PRIMARY KEY, nid integer NOT NULL, did integer NOT NULL, ord integer NOT NULL, mod integer NOT NULL,
      usn integer NOT NULL, type integer NOT NULL, queue integer NOT NULL, due integer NOT NULL, ivl integer NOT NULL,
      factor integer NOT NULL, reps integer NOT NULL, lapses integer NOT NULL, left integer NOT NULL,
      odue integer NOT NULL, odid integer NOT NULL, flags integer NOT NULL, data text NOT NULL
    );
    CREATE TABLE revlog (
      id integer PRIMARY KEY, cid integer NOT NULL, usn integer NOT NULL, ease integer NOT NULL, ivl integer NOT NULL,
      lastIvl integer NOT NULL, factor integer NOT NULL, time integer NOT NULL, type integer NOT NULL
    );
    CREATE TABLE graves (oid integer NOT NULL, type integer NOT NULL, usn integer NOT NULL, PRIMARY KEY (oid, type)) WITHOUT ROWID;
    """

    static let modernTables = """
    CREATE TABLE IF NOT EXISTS deck_config (
      id integer PRIMARY KEY NOT NULL, name text NOT NULL COLLATE unicase, mtime_secs integer NOT NULL,
      usn integer NOT NULL, config blob NOT NULL
    );
    CREATE TABLE IF NOT EXISTS config (
      KEY text NOT NULL PRIMARY KEY, usn integer NOT NULL, mtime_secs integer NOT NULL, val blob NOT NULL
    ) without rowid;
    CREATE TABLE IF NOT EXISTS fields (
      ntid integer NOT NULL, ord integer NOT NULL, name text NOT NULL COLLATE unicase, config blob NOT NULL,
      PRIMARY KEY (ntid, ord)
    ) without rowid;
    CREATE TABLE IF NOT EXISTS templates (
      ntid integer NOT NULL, ord integer NOT NULL, name text NOT NULL COLLATE unicase, mtime_secs integer NOT NULL,
      usn integer NOT NULL, config blob NOT NULL, PRIMARY KEY (ntid, ord)
    ) without rowid;
    CREATE TABLE IF NOT EXISTS notetypes (
      id integer NOT NULL PRIMARY KEY, name text NOT NULL COLLATE unicase, mtime_secs integer NOT NULL,
      usn integer NOT NULL, config blob NOT NULL
    );
    CREATE TABLE IF NOT EXISTS decks (
      id integer PRIMARY KEY NOT NULL, name text NOT NULL COLLATE unicase, mtime_secs integer NOT NULL,
      usn integer NOT NULL, common blob NOT NULL, kind blob NOT NULL
    );
    CREATE TABLE IF NOT EXISTS tags (
      tag text NOT NULL PRIMARY KEY COLLATE unicase, usn integer NOT NULL, collapsed boolean NOT NULL, config blob NULL
    ) without rowid;
    """

    static let indexes = """
    CREATE INDEX IF NOT EXISTS ix_notes_usn ON notes (usn);
    CREATE INDEX IF NOT EXISTS ix_cards_usn ON cards (usn);
    CREATE INDEX IF NOT EXISTS ix_revlog_usn ON revlog (usn);
    CREATE INDEX IF NOT EXISTS ix_cards_nid ON cards (nid);
    CREATE INDEX IF NOT EXISTS ix_cards_sched ON cards (did, queue, due);
    CREATE INDEX IF NOT EXISTS ix_revlog_cid ON revlog (cid);
    CREATE INDEX IF NOT EXISTS ix_notes_csum ON notes (csum);
    CREATE UNIQUE INDEX IF NOT EXISTS idx_fields_name_ntid ON fields (name, ntid);
    CREATE UNIQUE INDEX IF NOT EXISTS idx_templates_name_ntid ON templates (name, ntid);
    CREATE INDEX IF NOT EXISTS idx_templates_usn ON templates (usn);
    CREATE UNIQUE INDEX IF NOT EXISTS idx_notetypes_name ON notetypes (name);
    CREATE INDEX IF NOT EXISTS idx_notetypes_usn ON notetypes (usn);
    CREATE UNIQUE INDEX IF NOT EXISTS idx_decks_name ON decks (name);
    CREATE INDEX IF NOT EXISTS idx_notes_mid ON notes (mid);
    CREATE INDEX IF NOT EXISTS idx_cards_odid ON cards (odid) WHERE odid != 0;
    CREATE INDEX IF NOT EXISTS idx_graves_pending ON graves (usn);
    """

    static func create(_ db: SQLiteDB) throws {
        try db.exec("PRAGMA page_size = 4096; PRAGMA journal_mode = wal")
        try db.transaction {
            try db.exec(tables)
            try db.exec(modernTables)
            try db.exec(indexes)
            let now = Collection.nowMillis
            let timing = SchedTiming(createdSecs: Collection.nowSecs, createdMinsWest: SchedTiming.localMinutesWest(),
                                     nowSecs: Collection.nowSecs, nowMinsWest: SchedTiming.localMinutesWest(), rolloverHour: 4)
            try db.run("insert into col values (1, ?, ?, ?, 18, 0, 0, 0, '', '', '', '', '')", timing.nextDayAt - 86400, now, now)

            let conf = DeckConfig(id: 1, name: "Default")
            try db.run("insert into deck_config values (1, 'Default', ?, 0, ?)", Collection.nowSecs, conf.config.encoded)
            let deck = Deck(id: 1, name: "Default")
            try db.run("insert into decks values (1, 'Default', ?, 0, ?, ?)", Collection.nowSecs, deck.common.encoded, deck.kind.encoded)

            var firstID = 0
            for (i, var nt) in StockNotetypes.all.enumerated() {
                nt.id = now + i
                if i == 0 { firstID = nt.id }
                try db.run("insert into notetypes values (?, ?, ?, 0, ?)", nt.id, nt.name, Collection.nowSecs, nt.config.encoded)
                for (o, f) in nt.fields.enumerated() {
                    try db.run("insert into fields values (?, ?, ?, ?)", nt.id, o, f.name, f.config.encoded)
                }
                for (o, t) in nt.templates.enumerated() {
                    try db.run("insert into templates values (?, ?, ?, ?, 0, ?)", nt.id, o, t.name, Collection.nowSecs, t.config.encoded)
                }
            }
            let defaults: [(String, String)] = [
                ("activeDecks", "[1]"), ("addToCur", "true"), ("collapseTime", "1200"),
                ("creationOffset", String(SchedTiming.localMinutesWest())), ("curDeck", "1"), ("curModel", String(firstID)),
                ("dayLearnFirst", "false"), ("dueCounts", "true"), ("estTimes", "true"), ("newSpread", "0"), ("nextPos", "1"),
                ("sched2021", "true"), ("schedVer", "2"), ("sortBackwards", "false"), ("sortType", "\"noteFld\""), ("timeLim", "0"),
                ("rollover", "4"),
            ]
            for (k, v) in defaults {
                try db.run("insert into config values (?, 0, ?, ?)", k, Collection.nowSecs, Data(v.utf8))
            }
        }
    }
}

public enum StockNotetypes {
    static let css = """
    .card {
        font-family: arial;
        font-size: 20px;
        line-height: 1.5;
        text-align: center;
        color: black;
        background-color: white;
    }

    """

    static let clozeCSS = css + """
    .cloze {
        font-weight: bold;
        color: blue;
    }
    .nightMode .cloze {
        color: lightblue;
    }

    """

    static let back = "{{FrontSide}}\n\n<hr id=answer>\n\n{{Back}}"

    private static func make(_ name: String, kind: Notetype.Kind = .normal, stock: Int, fields: [String],
                             templates: [(String, String, String)], css: String = css) -> Notetype {
        var nt = Notetype(name: name, kind: kind, fields: fields.enumerated().map { Notetype.Field(ord: $0, name: $1) },
                          templates: templates.enumerated().map { Notetype.Template(ord: $0, name: $1.0, front: $1.1, back: $1.2) },
                          css: css)
        nt.config.setUInt(9, UInt64(stock))
        return nt
    }

    public static var basic: Notetype {
        make("Basic", stock: 1, fields: ["Front", "Back"], templates: [("Card 1", "{{Front}}", back)])
    }

    public static var basicAndReversed: Notetype {
        make("Basic (and reversed card)", stock: 2, fields: ["Front", "Back"], templates: [
            ("Card 1", "{{Front}}", back),
            ("Card 2", "{{Back}}", "{{FrontSide}}\n\n<hr id=answer>\n\n{{Front}}"),
        ])
    }

    public static var basicOptionalReversed: Notetype {
        make("Basic (optional reversed card)", stock: 3, fields: ["Front", "Back", "Add Reverse"], templates: [
            ("Card 1", "{{Front}}", back),
            ("Card 2", "{{#Add Reverse}}{{Back}}{{/Add Reverse}}", "{{FrontSide}}\n\n<hr id=answer>\n\n{{Front}}"),
        ])
    }

    public static var basicTyping: Notetype {
        make("Basic (type in the answer)", stock: 4, fields: ["Front", "Back"], templates: [
            ("Card 1", "{{Front}}\n\n{{type:Back}}", "{{Front}}\n\n<hr id=answer>\n\n{{type:Back}}"),
        ])
    }

    public static var cloze: Notetype {
        make("Cloze", kind: .cloze, stock: 5, fields: ["Text", "Back Extra"],
             templates: [("Cloze", "{{cloze:Text}}", "{{cloze:Text}}<br>\n{{Back Extra}}")], css: clozeCSS)
    }

    public static var all: [Notetype] { [basic, basicAndReversed, basicOptionalReversed, basicTyping, cloze] }
}

/// When the scheduler day starts and how many days have passed since the collection was created.
public struct SchedTiming: Equatable, Sendable {
    public let daysElapsed: Int
    public let nextDayAt: Int

    public init(createdSecs: Int, createdMinsWest: Int, nowSecs: Int, nowMinsWest: Int, rolloverHour: Int) {
        let roll = max(0, min(23, rolloverHour)) * 3600
        func day(_ secs: Int, _ minsWest: Int) -> Int {
            let local = secs - minsWest * 60 - roll
            return Int((Double(local) / 86400).rounded(.down))
        }
        daysElapsed = max(0, day(nowSecs, nowMinsWest) - day(createdSecs, createdMinsWest))
        nextDayAt = (day(nowSecs, nowMinsWest) + 1) * 86400 + roll + nowMinsWest * 60
    }

    public static func localMinutesWest(_ date: Date = Date()) -> Int {
        -TimeZone.current.secondsFromGMT(for: date) / 60
    }
}
