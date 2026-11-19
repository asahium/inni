import Foundation

/// Anki's search syntax, compiled to SQL over `cards c join notes n on n.id = c.nid`.
public struct SearchQuery {
    indirect enum Node {
        case term(String, negated: Bool)
        case and([Node], negated: Bool)
        case or([Node], negated: Bool)
    }

    let root: Node?

    public init(_ text: String) {
        var tokens = SearchQuery.tokenize(text)[...]
        root = SearchQuery.parseOr(&tokens)
    }

    // MARK: Tokens

    enum Token: Equatable { case word(String), open, close, or, not }

    static func tokenize(_ s: String) -> [Token] {
        var out: [Token] = []
        var cur = ""
        var inQuote = false
        var escape = false
        var negNext = false
        func push() {
            guard !cur.isEmpty else { return }
            if !inQuote, cur.lowercased() == "or" { out.append(.or) }
            else if !inQuote, cur.lowercased() == "and" {}
            else {
                if negNext { out.append(.not) }
                out.append(.word(cur))
            }
            negNext = false
            cur = ""
        }
        for ch in s {
            if escape {
                cur.append("\\")
                cur.append(ch)
                escape = false
                continue
            }
            if ch == "\\" { escape = true; continue }
            if ch == "\"" { inQuote.toggle(); continue }
            if inQuote { cur.append(ch); continue }
            switch ch {
            case " ", "\t", "\n": push()
            case "(":
                push()
                if negNext { out.append(.not); negNext = false }
                out.append(.open)
            case ")": push(); out.append(.close)
            case "-" where cur.isEmpty: negNext = true
            default: cur.append(ch)
            }
        }
        push()
        return out
    }

    static func parseOr(_ t: inout ArraySlice<Token>) -> Node? {
        var parts: [Node] = []
        if let first = parseAnd(&t) { parts.append(first) }
        while t.first == .or {
            t.removeFirst()
            if let n = parseAnd(&t) { parts.append(n) }
        }
        if parts.isEmpty { return nil }
        return parts.count == 1 ? parts[0] : .or(parts, negated: false)
    }

    static func parseAnd(_ t: inout ArraySlice<Token>) -> Node? {
        var parts: [Node] = []
        while let tok = t.first, tok != .or, tok != .close {
            var negated = false
            if tok == .not {
                negated = true
                t.removeFirst()
            }
            guard let next = t.popFirst() else { break }
            switch next {
            case .word(let w): parts.append(.term(w, negated: negated))
            case .open:
                if let inner = parseOr(&t) { parts.append(negated ? negate(inner) : inner) }
                if t.first == .close { t.removeFirst() }
            default: break
            }
        }
        if parts.isEmpty { return nil }
        return parts.count == 1 ? parts[0] : .and(parts, negated: false)
    }

    static func negate(_ n: Node) -> Node {
        switch n {
        case .term(let s, let neg): return .term(s, negated: !neg)
        case .and(let p, let neg): return .and(p, negated: !neg)
        case .or(let p, let neg): return .or(p, negated: !neg)
        }
    }

    // MARK: SQL

    func sql(_ col: Collection) -> (String, [Any?]) {
        guard let root else { return ("1", []) }
        var args: [Any?] = []
        let s = SearchQuery.sql(root, col, &args)
        return (s, args)
    }

    static func sql(_ n: Node, _ col: Collection, _ args: inout [Any?]) -> String {
        switch n {
        case .term(let t, let neg):
            let s = term(t, col, &args)
            return neg ? "not (\(s))" : "(\(s))"
        case .and(let parts, let neg):
            let s = parts.map { sql($0, col, &args) }.joined(separator: " and ")
            return neg ? "not (\(s))" : "(\(s))"
        case .or(let parts, let neg):
            let s = parts.map { sql($0, col, &args) }.joined(separator: " or ")
            return neg ? "not (\(s))" : "(\(s))"
        }
    }

    /// Anki wildcards (`*`, `_`) to a LIKE pattern; `\*` and `\_` stay literal.
    static func like(_ s: String) -> String {
        var out = ""
        var esc = false
        for ch in s {
            if esc {
                if ch == "*" || ch == "_" || ch == "%" { out += "\\" + String(ch) } else { out.append(ch) }
                esc = false
                continue
            }
            switch ch {
            case "\\": esc = true
            case "*": out += "%"
            case "%": out += "\\%"
            default: out.append(ch)
            }
        }
        return out
    }

    static func unescape(_ s: String) -> String {
        var out = "", esc = false
        for ch in s {
            if esc { out.append(ch); esc = false } else if ch == "\\" { esc = true } else { out.append(ch) }
        }
        return out
    }

    /// Glob with `*` to a case-insensitive regex.
    static func globRegex(_ s: String) -> String {
        "(?i)^" + NSRegularExpression.escapedPattern(for: unescape(s)).replacingOccurrences(of: "\\*", with: ".*") + "$"
    }

    static func term(_ raw: String, _ col: Collection, _ args: inout [Any?]) -> String {
        guard let colon = raw.firstIndex(of: ":"), raw[..<colon].allSatisfy({ $0.isLetter || $0 == "-" }) else {
            return text(raw, &args)
        }
        let key = raw[..<colon].lowercased()
        let val = String(raw[raw.index(after: colon)...])
        let t = col.timing
        switch key {
        case "deck":
            if val == "*" { return "1" }
            if val.lowercased() == "filtered" { return "c.odid != 0" }
            var ids: [DeckID] = []
            if val.lowercased() == "current" {
                ids = col.deckAndChildren(col.currentDeckID).map(\.id)
            } else {
                let re = RegexCache.shared.regex(globRegex(val))
                for d in col.decks.values where re?.firstMatch(in: d.name, range: NSRange(d.name.startIndex..., in: d.name)) != nil {
                    ids += col.deckAndChildren(d.id).map(\.id)
                }
            }
            guard !ids.isEmpty else { return "0" }
            let list = Set(ids).map(String.init).joined(separator: ",")
            return "c.did in (\(list)) or c.odid in (\(list))"
        case "tag":
            if val.lowercased() == "none" { return "n.tags = ''" }
            let p = like(val)
            args += ["% \(p) %", "% \(p)::%"]
            return "n.tags like ? escape '\\' or n.tags like ? escape '\\'"
        case "is":
            switch val.lowercased() {
            case "new": return "c.type = 0"
            case "learn": return "c.queue in (1, 3) or (c.type in (1, 3) and c.queue in (-2, -3))"
            case "review": return "c.type in (2, 3)"
            case "due": return "(c.queue in (2, 3) and c.due <= \(t.daysElapsed)) or (c.queue = 1 and c.due <= \(t.nextDayAt))"
            case "suspended": return "c.queue = -1"
            case "buried": return "c.queue in (-2, -3)"
            case "marked": return "n.tags like '% marked %'"
            case "leech": return "n.tags like '% leech %'"
            default: return "0"
            }
        case "flag":
            guard let f = Int(val) else { return "0" }
            return "(c.flags & 7) = \(f)"
        case "card":
            if let n = Int(val) { return "c.ord = \(n - 1)" }
            let re = RegexCache.shared.regex(globRegex(val))
            var parts: [String] = []
            for nt in col.notetypes.values {
                for tm in nt.templates where re?.firstMatch(in: tm.name, range: NSRange(tm.name.startIndex..., in: tm.name)) != nil {
                    parts.append("(n.mid = \(nt.id) and c.ord = \(tm.ord))")
                }
            }
            return parts.isEmpty ? "0" : parts.joined(separator: " or ")
        case "note":
            let re = RegexCache.shared.regex(globRegex(val))
            let ids = col.notetypes.values.filter { re?.firstMatch(in: $0.name, range: NSRange($0.name.startIndex..., in: $0.name)) != nil }.map(\.id)
            return ids.isEmpty ? "0" : "n.mid in (\(ids.map(String.init).joined(separator: ",")))"
        case "mid": return "n.mid = \(Int(val) ?? 0)"
        case "nid": return "n.id in (\(val.split(separator: ",").compactMap { Int($0) }.map(String.init).joined(separator: ",")))"
        case "cid": return "c.id in (\(val.split(separator: ",").compactMap { Int($0) }.map(String.init).joined(separator: ",")))"
        case "prop": return prop(val, t)
        case "rated", "introduced":
            let parts = val.split(separator: ":")
            let days = min(36500, max(1, Int(parts.first ?? "1") ?? 1))
            let cutoff = (t.nextDayAt - days * 86400) * 1000
            if key == "introduced" {
                return "c.id in (select cid from revlog where type = 0 group by cid having min(id) > \(cutoff))"
            }
            let ease = parts.count > 1 ? Int(parts[1]).map { " and ease = \($0)" } ?? "" : " and ease > 0"
            return "c.id in (select cid from revlog where id > \(cutoff)\(ease))"
        case "added":
            let days = max(1, Int(val) ?? 1)
            return "c.id > \((t.nextDayAt - days * 86400) * 1000)"
        case "edited":
            let days = max(1, Int(val) ?? 1)
            return "n.mod > \(t.nextDayAt - days * 86400)"
        case "re":
            args.append("(?i)" + unescape(val))
            return "n.flds regexp ?"
        case "w":
            args.append("(?i)\\b" + NSRegularExpression.escapedPattern(for: unescape(val)).replacingOccurrences(of: "\\*", with: "\\w*") + "\\b")
            return "n.flds regexp ?"
        case "nc": return text(val, &args)
        default:
            return field(String(raw[..<colon]), val, col, &args) ?? text(raw, &args)
        }
    }

    static func text(_ s: String, _ args: inout [Any?]) -> String {
        let p = "%" + like(s) + "%"
        args += [p, p]
        return "n.sfld like ? escape '\\' or n.flds like ? escape '\\'"
    }

    static func field(_ name: String, _ val: String, _ col: Collection, _ args: inout [Any?]) -> String? {
        let re = RegexCache.shared.regex(globRegex(name))
        var parts: [String] = []
        let pattern = like(val)
        for nt in col.notetypes.values {
            for (i, f) in nt.fields.enumerated() where re?.firstMatch(in: f.name, range: NSRange(f.name.startIndex..., in: f.name)) != nil {
                parts.append("(n.mid = \(nt.id) and field_at_index(n.flds, \(i)) like ? escape '\\')")
                args.append(pattern)
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " or ")
    }

    static func prop(_ s: String, _ t: SchedTiming) -> String {
        let ops = [">=", "<=", "!=", "=", ">", "<"]
        guard let op = ops.first(where: { s.contains($0) }), let r = s.range(of: op) else { return "0" }
        let key = s[..<r.lowerBound].lowercased()
        guard let v = Double(s[r.upperBound...]) else { return "0" }
        let sqlOp = op == "!=" ? "!=" : op
        switch key {
        case "ivl": return "c.ivl \(sqlOp) \(Int(v))"
        case "reps": return "c.reps \(sqlOp) \(Int(v))"
        case "lapses": return "c.lapses \(sqlOp) \(Int(v))"
        case "ease": return "c.factor \(sqlOp) \(Int(v * 1000))"
        case "pos": return "c.type = 0 and c.due \(sqlOp) \(Int(v))"
        case "due": return "c.queue in (2, 3) and c.due - \(t.daysElapsed) \(sqlOp) \(Int(v))"
        default: return "0"
        }
    }
}

public enum BrowserSort: String, CaseIterable, Sendable {
    case sortField, created, due, interval, ease, reps, lapses, modified, deck

    var sql: String {
        switch self {
        case .sortField: return "n.sfld collate nocase, c.ord"
        case .created: return "c.id"
        case .due: return "c.type = 0, case when c.queue = 1 then 0 else 1 end, c.due"
        case .interval: return "c.ivl"
        case .ease: return "c.factor"
        case .reps: return "c.reps"
        case .lapses: return "c.lapses"
        case .modified: return "c.mod"
        case .deck: return "c.did"
        }
    }
}

public struct BrowserRow: Identifiable, Sendable {
    public var id: CardID
    public var noteID: NoteID
    public var sortField: String
    public var question: String
    public var deck: String
    public var notetype: String
    public var cardName: String
    public var due: String
    public var interval: String
    public var ease: String
    public var reps: Int
    public var lapses: Int
    public var tags: String
    public var flag: Int
    public var suspended: Bool
    public var buried: Bool
}

extension Collection {
    public func findCards(_ query: String, sort: BrowserSort = .sortField, reverse: Bool = false, limit: Int? = nil) throws -> [CardID] {
        let (w, args) = SearchQuery(query).sql(self)
        let sql = "select c.id from cards c join notes n on n.id = c.nid where \(w) order by \(sort.sql.split(separator: ",").map { $0 + (reverse ? " desc" : "") }.joined(separator: ","))"
            + (limit.map { " limit \($0)" } ?? "")
        return try db.prepare(sql).bind(args).map { $0.integer(0) }
    }

    public func findNotes(_ query: String) throws -> [NoteID] {
        let (w, args) = SearchQuery(query).sql(self)
        return try db.prepare("select distinct n.id from cards c join notes n on n.id = c.nid where \(w) order by n.id").bind(args).map { $0.integer(0) }
    }

    /// Table rows for the browser.
    public func browserRows(_ ids: [CardID]) -> [BrowserRow] {
        let today = self.today
        var out: [BrowserRow] = []
        for chunk in ids.chunked(400) {
            let list = chunk.map(String.init).joined(separator: ",")
            guard let s = try? db.prepare("""
                select c.id, c.nid, n.sfld, c.did, c.odid, n.mid, c.ord, c.type, c.queue, c.due, c.ivl, c.factor, c.reps, c.lapses, n.tags, c.flags
                from cards c join notes n on n.id = c.nid where c.id in (\(list))
                """) else { continue }
            var rows: [CardID: BrowserRow] = [:]
            while (try? s.step()) == true {
                let nt = notetypes[s.integer(5)]
                let ord = s.integer(6)
                let type = s.integer(7), queue = s.integer(8), due = s.integer(9)
                let dueText: String
                if s.integer(4) != 0 { dueText = "(filtered)" }
                else if type == 0 { dueText = "New #\(due)" }
                else if queue == 1 { dueText = Collection.dateString(Date(timeIntervalSince1970: TimeInterval(due))) }
                else { dueText = Collection.dateString(Date().addingTimeInterval(TimeInterval((due - today) * 86400))) }
                let ivl = s.integer(10)
                let did = s.integer(4) != 0 ? s.integer(4) : s.integer(3)
                let row = BrowserRow(
                    id: s.integer(0), noteID: s.integer(1), sortField: String(s.text(2).prefix(200)), question: "",
                    deck: decks[did]?.name ?? "?", notetype: nt?.name ?? "?",
                    cardName: nt.map { $0.isCloze ? "Cloze \(ord + 1)" : (ord < $0.templates.count ? $0.templates[ord].name : "?") } ?? "?",
                    due: dueText, interval: type == 2 || type == 3 ? IntervalFormat.days(ivl) : (type == 0 ? "(new)" : "(learning)"),
                    ease: type == 0 ? "(new)" : "\(s.integer(11) / 10)%", reps: s.integer(12), lapses: s.integer(13),
                    tags: s.text(14).trimmingCharacters(in: .whitespaces), flag: s.integer(15) & 7, suspended: queue == -1,
                    buried: queue == -2 || queue == -3)
                rows[row.id] = row
            }
            out += chunk.compactMap { rows[$0] }
        }
        return out
    }

    static func dateString(_ d: Date) -> String {
        d.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits))
    }
}
