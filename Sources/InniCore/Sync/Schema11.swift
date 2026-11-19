import Foundation

typealias JSONObject = [String: Any]

/// Anki's legacy JSON shapes for notetypes, decks and presets ("schema 11"), used by the sync protocol
/// and old collections. Mirrors rslib's `schema11.rs` conversions, including unknown keys kept in field 255.
enum Schema11 {
    // MARK: Notetypes

    static let notetypeKeys: Set<String> = ["latexPost", "flds", "css", "originalStockKind", "originalId", "id", "usn", "mod",
                                            "req", "latexPre", "name", "did", "tmpls", "type", "sortf", "latexsvg"]
    static let fieldKeys: Set<String> = ["name", "ord", "sticky", "rtl", "plainText", "font", "size", "collapsed", "description",
                                         "excludeFromSearch", "id", "tag", "preventDeletion"]
    static let templateKeys: Set<String> = ["name", "ord", "did", "afmt", "bafmt", "qfmt", "bqfmt", "bfont", "bsize", "id"]

    static func json(_ nt: Notetype) -> JSONObject {
        let c = nt.config
        var o = other(c.bytes(255), reserved: notetypeKeys)
        o["id"] = nt.id
        o["name"] = nt.name
        o["type"] = c.uint(1) == 1 ? 1 : 0
        o["mod"] = nt.mtime
        o["usn"] = nt.usn
        o["sortf"] = Int(c.uint(2))
        o["did"] = c.int(4) == 0 ? NSNull() : c.int(4)
        o["tmpls"] = nt.templates.map(json)
        o["flds"] = nt.fields.map(json)
        o["css"] = c.string(3)
        o["latexPre"] = c.string(5)
        o["latexPost"] = c.string(6)
        o["latexsvg"] = c.bool(7)
        o["req"] = c.messages(8).map { r -> [Any] in
            [Int(r.uint(1)), ["none", "any", "all"][min(2, Int(r.uint(2)))], r.uints(3).map { Int($0) }]
        }
        if c.int(9) != 0 { o["originalStockKind"] = c.int(9) }
        if let id = c.optionalInt(10) { o["originalId"] = id }
        return o
    }

    static func json(_ f: Notetype.Field) -> JSONObject {
        let c = f.config
        var o = other(c.bytes(255), reserved: fieldKeys)
        o["name"] = f.name
        o["ord"] = f.ord
        o["sticky"] = c.bool(1)
        o["rtl"] = c.bool(2)
        o["font"] = c.string(3)
        o["size"] = Int(c.uint(4))
        o["description"] = c.string(5)
        o["plainText"] = c.bool(6)
        o["collapsed"] = c.bool(7)
        o["excludeFromSearch"] = c.bool(8)
        o["id"] = c.optionalInt(9) ?? NSNull()
        o["tag"] = c.optionalInt(10) ?? NSNull()
        o["preventDeletion"] = c.bool(11)
        return o
    }

    static func json(_ t: Notetype.Template) -> JSONObject {
        let c = t.config
        var o = other(c.bytes(255), reserved: templateKeys)
        o["name"] = t.name
        o["ord"] = t.ord
        o["qfmt"] = c.string(1)
        o["afmt"] = c.string(2)
        o["bqfmt"] = c.string(3)
        o["bafmt"] = c.string(4)
        o["did"] = c.int(5) > 0 ? c.int(5) : NSNull()
        o["bfont"] = c.string(6)
        o["bsize"] = Int(c.uint(7))
        o["id"] = c.optionalInt(8) ?? NSNull()
        return o
    }

    /// Fields and templates get `ord` = position, and templates mtime/usn 0, as Anki does.
    static func notetype(_ o: JSONObject) -> Notetype {
        var c = Proto()
        c.setUInt(1, int(o["type"]) == 1 ? 1 : 0)
        c.setUInt(2, UInt64(max(0, int(o["sortf"]))))
        c.setString(3, string(o["css"]))
        c.setInt(4, int(o["did"]))
        c.setString(5, string(o["latexPre"]))
        c.setString(6, string(o["latexPost"]))
        c.setBool(7, bool(o["latexsvg"]))
        let reqs = (o["req"] as? [[Any]] ?? []).compactMap { r -> Proto? in
            guard r.count >= 3 else { return nil }
            var p = Proto()
            p.setUInt(1, UInt64(max(0, int(r[0]))))
            p.setUInt(2, ["none": 0, "any": 1, "all": 2][string(r[1])] ?? 0)
            p.setUInts(3, (r[2] as? [Any] ?? []).map { UInt64(max(0, int($0))) })
            return p
        }
        c.setMessages(8, reqs)
        c.setInt(9, int(o["originalStockKind"]))
        c.setOptionalInt(10, optionalInt(o["originalId"]))
        c.setBytes(255, otherBytes(o, reserved: notetypeKeys))

        let fields = (o["flds"] as? [JSONObject] ?? []).enumerated().map { i, f -> Notetype.Field in
            var fc = Proto()
            fc.setBool(1, bool(f["sticky"]))
            fc.setBool(2, bool(f["rtl"]))
            fc.setString(3, f["font"] as? String ?? "Arial")
            fc.setUInt(4, UInt64(max(0, int(f["size"], 20))))
            fc.setString(5, string(f["description"]))
            fc.setBool(6, bool(f["plainText"]))
            fc.setBool(7, bool(f["collapsed"]))
            fc.setBool(8, bool(f["excludeFromSearch"]))
            fc.setOptionalInt(9, optionalInt(f["id"]))
            fc.setOptionalInt(10, optionalInt(f["tag"]))
            fc.setBool(11, bool(f["preventDeletion"]))
            fc.setBytes(255, otherBytes(f, reserved: fieldKeys))
            return Notetype.Field(ord: i, name: string(f["name"]), config: fc)
        }
        let templates = (o["tmpls"] as? [JSONObject] ?? []).enumerated().map { i, t -> Notetype.Template in
            var tc = Proto()
            tc.setString(1, string(t["qfmt"]))
            tc.setString(2, string(t["afmt"]))
            tc.setString(3, string(t["bqfmt"]))
            tc.setString(4, string(t["bafmt"]))
            tc.setInt(5, int(t["did"]))
            tc.setString(6, string(t["bfont"]))
            tc.setUInt(7, UInt64(max(0, int(t["bsize"]))))
            tc.setOptionalInt(8, optionalInt(t["id"]))
            tc.setBytes(255, otherBytes(t, reserved: templateKeys))
            return Notetype.Template(ord: i, name: string(t["name"]), mtime: 0, usn: 0, config: tc)
        }
        return Notetype(id: int(o["id"]), name: string(o["name"]), mtime: int(o["mod"]), usn: int(o["usn"]), config: c,
                        fields: fields, templates: templates)
    }

    // MARK: Decks

    static let deckKeys: Set<String> = ["usn", "revToday", "newLimit", "dyn", "reviewLimit", "newToday", "timeToday",
                                        "reviewLimitToday", "extendNew", "mod", "newLimitToday", "desc", "name", "lrnToday",
                                        "conf", "browserCollapsed", "extendRev", "id", "collapsed", "desiredRetention"]
    /// Keys the serde structs consume besides the reserved ones, so they never land in `other`.
    static let deckStructKeys: Set<String> = deckKeys.union(["md", "resched", "terms", "separate", "delays", "previewDelay",
                                                             "previewAgainSecs", "previewHardSecs", "previewGoodSecs", "return"])

    static func json(_ d: Deck) -> JSONObject {
        let c = d.common
        var o = other(c.bytes(255), reserved: deckKeys)
        let day = Int(c.uint(3))
        o["id"] = d.id
        o["mod"] = d.mtime
        o["name"] = d.name
        o["usn"] = d.usn
        o["lrnToday"] = [day, c.int(6)]
        o["revToday"] = [day, c.int(5)]
        o["newToday"] = [day, c.int(4)]
        o["timeToday"] = [day, c.int(7)]
        o["collapsed"] = c.bool(1)
        o["browserCollapsed"] = c.bool(2)
        if d.isFiltered {
            let f = d.kind.message(2)
            o["desc"] = ""
            o["dyn"] = 1
            o["resched"] = f.bool(1)
            o["terms"] = f.messages(2).map { t -> [Any] in [t.string(1), t.int(2), t.int(3)] }
            o["separate"] = true
            let delays = f.floats(3)
            o["delays"] = delays.isEmpty ? NSNull() : delays.map(num)
            o["previewDelay"] = Int(f.uint(4))
            o["previewAgainSecs"] = Int(f.uint(7))
            o["previewHardSecs"] = Int(f.uint(5))
            o["previewGoodSecs"] = Int(f.uint(6))
        } else {
            let n = d.kind.message(1)
            o["desc"] = n.string(4)
            if n.bool(5) { o["md"] = true }
            o["dyn"] = 0
            o["conf"] = n.int(1)
            o["extendNew"] = n.int(2)
            o["extendRev"] = n.int(3)
            o["reviewLimit"] = n.optionalInt(6) ?? NSNull()
            o["newLimit"] = n.optionalInt(7) ?? NSNull()
            o["reviewLimitToday"] = n.has(8) ? dayLimit(n.message(8)) : NSNull()
            o["newLimitToday"] = n.has(9) ? dayLimit(n.message(9)) : NSNull()
            o["desiredRetention"] = n.optionalFloat(10).map { Int($0 * 100) } ?? NSNull()
        }
        return o
    }

    private static func dayLimit(_ p: Proto) -> JSONObject { ["limit": Int(p.uint(1)), "today": Int(p.uint(2))] }

    private static func dayLimit(_ v: Any?) -> Proto? {
        guard let o = v as? JSONObject else { return nil }
        var p = Proto()
        p.setUInt(1, UInt64(max(0, int(o["limit"]))))
        p.setUInt(2, UInt64(max(0, int(o["today"]))))
        return p
    }

    static func deck(_ o: JSONObject) -> Deck {
        var c = Proto()
        func today(_ k: String) -> (day: Int, amount: Int) {
            let a = o[k] as? [Any] ?? []
            return (a.count >= 2 ? int(a[0]) : 0, a.count >= 1 ? int(a[a.count - 1]) : 0)
        }
        let lrn = today("lrnToday"), rev = today("revToday"), new = today("newToday"), time = today("timeToday")
        let maxDay = max(time.day, new.day, rev.day)
        c.setBool(1, bool(o["collapsed"]))
        c.setBool(2, bool(o["browserCollapsed"]))
        c.setUInt(3, UInt64(max(0, maxDay)))
        c.setInt(4, new.day == maxDay ? new.amount : 0)
        c.setInt(5, rev.day == maxDay ? rev.amount : 0)
        c.setInt(6, lrn.day == maxDay ? lrn.amount : 0)
        c.setInt(7, time.amount)
        c.setBytes(255, otherBytes(o, reserved: deckStructKeys))

        var kind = Proto()
        if bool(o["dyn"]) {
            var f = Proto()
            f.setBool(1, bool(o["resched"]))
            f.setMessages(2, (o["terms"] as? [[Any]] ?? []).compactMap { t -> Proto? in
                guard t.count >= 3 else { return nil }
                var p = Proto()
                p.setString(1, string(t[0]))
                p.setUInt(2, UInt64(max(0, int(t[1]))))
                p.setInt(3, int(t[2]))
                return p
            })
            f.setFloats(3, floats(o["delays"]) ?? [])
            f.setUInt(4, UInt64(max(0, int(o["previewDelay"]))))
            f.setUInt(5, UInt64(max(0, int(o["previewHardSecs"]))))
            f.setUInt(6, UInt64(max(0, int(o["previewGoodSecs"]))))
            f.setUInt(7, UInt64(max(0, int(o["previewAgainSecs"]))))
            kind.setMessage(2, f)
        } else {
            var n = Proto()
            n.setInt(1, int(o["conf"], 1))
            n.setUInt(2, UInt64(max(0, int(o["extendNew"]))))
            n.setUInt(3, UInt64(max(0, int(o["extendRev"]))))
            n.setString(4, string(o["desc"]))
            n.setBool(5, bool(o["md"]))
            n.setOptionalInt(6, optionalInt(o["reviewLimit"]))
            n.setOptionalInt(7, optionalInt(o["newLimit"]))
            n.setMessage(8, dayLimit(o["reviewLimitToday"]))
            n.setMessage(9, dayLimit(o["newLimitToday"]))
            n.setOptionalFloat(10, optionalInt(o["desiredRetention"]).map { Float($0) / 100 })
            kind.setMessage(1, n)
        }
        return Deck(id: int(o["id"]), name: Collection.normalizeDeckName(string(o["name"])), mtime: int(o["mod"]),
                    usn: int(o["usn"]), common: c, kind: kind)
    }

    // MARK: Deck presets

    static let presetKeys: Set<String> = ["id", "newSortOrder", "replayq", "newPerDayMinimum", "usn", "autoplay", "dyn", "maxTaken",
                                          "reviewOrder", "buryInterdayLearning", "newMix", "mod", "timer", "name",
                                          "interdayLearningMix", "newGatherPriority", "fsrsWeights", "fsrsParams5", "fsrsParams6",
                                          "desiredRetention", "stopTimerOnAnswer", "secondsToShowQuestion", "secondsToShowAnswer",
                                          "questionAction", "answerAction", "waitForAudio", "sm2Retention", "weightSearch",
                                          "ignoreRevlogsBeforeDate", "easyDaysPercentages"]
    static let presetNewKeys: Set<String> = ["order", "delays", "bury", "perDay", "initialFactor", "ints"]
    static let presetRevKeys: Set<String> = ["maxIvl", "hardFactor", "ease4", "ivlFct", "perDay", "bury"]
    static let presetLapseKeys: Set<String> = ["leechFails", "mult", "leechAction", "delays", "minInt"]

    static func json(_ dc: DeckConfig) -> JSONObject {
        let c = dc.config
        var top = other(c.bytes(255), reserved: [])
        var newOther = (top.removeValue(forKey: "new") as? JSONObject) ?? [:]
        var revOther = (top.removeValue(forKey: "rev") as? JSONObject) ?? [:]
        var lapseOther = (top.removeValue(forKey: "lapse") as? JSONObject) ?? [:]
        for k in presetKeys { top[k] = nil }
        for k in presetNewKeys { newOther[k] = nil }
        for k in presetRevKeys { revOther[k] = nil }
        for k in presetLapseKeys { lapseOther[k] = nil }

        var new = newOther
        new["bury"] = c.bool(27)
        new["delays"] = c.floats(1).map(num)
        new["initialFactor"] = Int(c.float(11) * 1000)
        new["ints"] = [Int(c.uint(18)), Int(c.uint(19)), 0]
        new["order"] = c.uint(20) == 1 ? 0 : 1
        new["perDay"] = Int(c.uint(9))
        var rev = revOther
        rev["bury"] = c.bool(28)
        rev["ease4"] = num(c.float(12))
        rev["ivlFct"] = num(c.float(15))
        rev["maxIvl"] = Int(c.uint(16))
        rev["perDay"] = Int(c.uint(10))
        rev["hardFactor"] = num(c.float(13))
        var lapse = lapseOther
        lapse["delays"] = c.floats(2).map(num)
        lapse["leechAction"] = c.uint(21) == 1 ? 1 : 0
        lapse["leechFails"] = Int(c.uint(22))
        lapse["minInt"] = Int(c.uint(17))
        lapse["mult"] = num(c.float(14))

        var o = top
        o["id"] = dc.id
        o["mod"] = dc.mtime
        o["name"] = dc.name
        o["usn"] = dc.usn
        o["maxTaken"] = Int(c.uint(24))
        o["autoplay"] = !c.bool(23)
        o["timer"] = c.bool(25) ? 1 : 0
        o["replayq"] = !c.bool(26)
        o["new"] = new
        o["rev"] = rev
        o["lapse"] = lapse
        o["dyn"] = false
        o["newMix"] = c.int(30)
        o["newPerDayMinimum"] = Int(c.uint(35))
        o["interdayLearningMix"] = c.int(31)
        o["reviewOrder"] = c.int(33)
        o["newSortOrder"] = c.int(32)
        o["newGatherPriority"] = c.int(34)
        o["buryInterdayLearning"] = c.bool(29)
        o["fsrsWeights"] = c.floats(3).map(num)
        o["fsrsParams5"] = c.floats(5).map(num)
        o["fsrsParams6"] = c.floats(6).map(num)
        o["desiredRetention"] = num(c.float(37))
        o["ignoreRevlogsBeforeDate"] = c.string(46)
        o["easyDaysPercentages"] = c.floats(4).map(num)
        o["stopTimerOnAnswer"] = c.bool(38)
        o["secondsToShowQuestion"] = num(c.float(41))
        o["secondsToShowAnswer"] = num(c.float(42))
        o["questionAction"] = c.int(36) == 1 ? 1 : 0
        o["answerAction"] = (1...4).contains(c.int(43)) ? c.int(43) : 0
        o["waitForAudio"] = c.bool(44)
        o["sm2Retention"] = num(c.float(40))
        o["weightSearch"] = c.string(45)
        return o
    }

    static func deckConfig(_ o: JSONObject) -> DeckConfig {
        let new = o["new"] as? JSONObject ?? [:], rev = o["rev"] as? JSONObject ?? [:], lapse = o["lapse"] as? JSONObject ?? [:]
        var c = Proto()
        c.setFloats(1, floats(new["delays"]) ?? [1, 10])
        c.setFloats(2, floats(lapse["delays"]) ?? [10])
        c.setFloats(3, floats(o["fsrsWeights"]) ?? [])
        c.setFloats(4, floats(o["easyDaysPercentages"]) ?? Array(repeating: 1, count: 7))
        c.setFloats(5, floats(o["fsrsParams5"]) ?? [])
        c.setFloats(6, floats(o["fsrsParams6"]) ?? [])
        c.setUInt(9, UInt64(max(0, int(new["perDay"], 20))))
        c.setUInt(10, UInt64(max(0, int(rev["perDay"], 200))))
        c.setUInt(35, UInt64(max(0, int(o["newPerDayMinimum"]))))
        c.setFloat(11, Float(int(new["initialFactor"], 2500)) / 1000)
        c.setFloat(12, float(rev["ease4"], 1.3))
        c.setFloat(13, float(rev["hardFactor"], 1.2))
        c.setFloat(14, float(lapse["mult"], 0))
        c.setFloat(15, float(rev["ivlFct"], 1))
        c.setUInt(16, UInt64(max(0, int(rev["maxIvl"], 36500))))
        c.setUInt(17, UInt64(max(0, int(lapse["minInt"], 1))))
        let ints = new["ints"] as? [Any] ?? []
        c.setUInt(18, UInt64(max(0, ints.count >= 2 ? int(ints[0]) : 1)))
        c.setUInt(19, UInt64(max(0, ints.count >= 2 ? int(ints[1]) : 4)))
        c.setUInt(20, int(new["order"], 1) == 0 ? 1 : 0)
        c.setInt(30, int(o["newMix"]))
        c.setInt(31, int(o["interdayLearningMix"]))
        c.setInt(32, int(o["newSortOrder"]))
        c.setInt(33, int(o["reviewOrder"]))
        c.setInt(34, int(o["newGatherPriority"]))
        c.setUInt(21, UInt64(int(lapse["leechAction"], 1) == 0 ? 0 : 1))
        c.setUInt(22, UInt64(max(0, int(lapse["leechFails"], 8))))
        c.setBool(23, !bool(o["autoplay"], true))
        c.setUInt(24, UInt64(max(0, int(o["maxTaken"], 60))))
        c.setBool(25, int(o["timer"]) != 0)
        c.setBool(26, !bool(o["replayq"], true))
        c.setBool(38, bool(o["stopTimerOnAnswer"]))
        c.setFloat(41, float(o["secondsToShowQuestion"], 0))
        c.setFloat(42, float(o["secondsToShowAnswer"], 0))
        c.setInt(36, int(o["questionAction"]))
        c.setInt(43, int(o["answerAction"]))
        c.setBool(44, bool(o["waitForAudio"], true))
        c.setBool(27, bool(new["bury"]))
        c.setBool(28, bool(rev["bury"]))
        c.setBool(29, bool(o["buryInterdayLearning"]))
        c.setFloat(37, float(o["desiredRetention"], 0.9))
        c.setFloat(40, float(o["sm2Retention"], 0.9))
        c.setString(45, string(o["weightSearch"]))
        c.setString(46, string(o["ignoreRevlogsBeforeDate"]))

        var rest = o.filter { !presetKeys.contains($0.key) && !["new", "rev", "lapse"].contains($0.key) }
        let newOther = new.filter { !presetNewKeys.contains($0.key) }
        let revOther = rev.filter { !presetRevKeys.contains($0.key) }
        let lapseOther = lapse.filter { !presetLapseKeys.contains($0.key) }
        if !newOther.isEmpty { rest["new"] = newOther }
        if !revOther.isEmpty { rest["rev"] = revOther }
        if !lapseOther.isEmpty { rest["lapse"] = lapseOther }
        c.setBytes(255, otherBytes(rest, reserved: []))
        return DeckConfig(id: int(o["id"]), name: string(o["name"]), mtime: int(o["mod"]), usn: int(o["usn"]), config: c)
    }

    // MARK: JSON helpers

    static func int(_ v: Any?, _ def: Int = 0) -> Int {
        switch v {
        case let n as NSNumber: return n.intValue
        case let s as String: return Int(s) ?? def
        default: return def
        }
    }

    static func optionalInt(_ v: Any?) -> Int? {
        switch v {
        case let n as NSNumber: return n.intValue
        case let s as String: return Int(s)
        default: return nil
        }
    }

    static func bool(_ v: Any?, _ def: Bool = false) -> Bool {
        switch v {
        case let n as NSNumber: return n.intValue != 0
        case let s as String: return s == "true" || s == "1"
        default: return def
        }
    }

    static func float(_ v: Any?, _ def: Float) -> Float { (v as? NSNumber)?.floatValue ?? def }

    static func string(_ v: Any?, _ def: String = "") -> String { v as? String ?? def }

    static func floats(_ v: Any?) -> [Float]? { (v as? [Any])?.compactMap { ($0 as? NSNumber)?.floatValue } }

    /// The shortest decimal for a Float, like serde writes f32, so 0.9 stays 0.9 rather than 0.8999999761581421.
    static func num(_ f: Float) -> Double { Double("\(f)") ?? Double(f) }

    static func other(_ data: Data, reserved: Set<String>) -> JSONObject {
        guard !data.isEmpty, let o = (try? JSONSerialization.jsonObject(with: data)) as? JSONObject else { return [:] }
        return o.filter { !reserved.contains($0.key) }
    }

    static func otherBytes(_ o: JSONObject, reserved: Set<String>) -> Data {
        let rest = o.filter { !reserved.contains($0.key) }
        guard !rest.isEmpty else { return Data() }
        return (try? JSONSerialization.data(withJSONObject: rest, options: [.sortedKeys])) ?? Data()
    }

    static func encode(_ v: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: v, options: [.fragmentsAllowed, .withoutEscapingSlashes])
    }

    static func decode(_ d: Data) throws -> Any {
        try JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed])
    }
}
