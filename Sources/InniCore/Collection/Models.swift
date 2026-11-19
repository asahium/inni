import Foundation

public typealias NoteID = Int
public typealias CardID = Int
public typealias DeckID = Int
public typealias NotetypeID = Int
public typealias DeckConfigID = Int

public struct Note: Identifiable, Equatable, Sendable {
    public var id: NoteID
    public var guid: String
    public var notetypeID: NotetypeID
    public var mtime: Int
    public var usn: Int
    public var tags: [String]
    public var fields: [String]
    public var flags: Int = 0
    public var data: String = ""

    public init(id: NoteID = 0, guid: String = Guid.make(), notetypeID: NotetypeID, mtime: Int = 0, usn: Int = -1,
                tags: [String] = [], fields: [String]) {
        self.id = id
        self.guid = guid
        self.notetypeID = notetypeID
        self.mtime = mtime
        self.usn = usn
        self.tags = tags
        self.fields = fields
    }

    public var joinedFields: String { fields.joined(separator: "\u{1f}") }
    public var joinedTags: String { tags.isEmpty ? "" : " " + tags.joined(separator: " ") + " " }

    public static func splitTags(_ s: String) -> [String] { s.split(whereSeparator: \.isWhitespace).map(String.init) }

    public func hasTag(_ t: String) -> Bool { tags.contains { $0.caseInsensitiveCompare(t) == .orderedSame } }
}

public enum CardType: Int, Sendable { case new = 0, learning = 1, review = 2, relearning = 3 }

public enum CardQueue: Int, Sendable {
    case manuallyBuried = -3, siblingBuried = -2, suspended = -1
    case new = 0, learning = 1, review = 2, dayLearning = 3, preview = 4
}

public struct Card: Identifiable, Equatable, Sendable {
    public var id: CardID
    public var noteID: NoteID
    public var deckID: DeckID
    public var ord: Int
    public var mtime: Int
    public var usn: Int
    public var type: CardType
    public var queue: CardQueue
    /// New: position. Review/day-learning: day number. Learning: epoch seconds.
    public var due: Int
    /// Days for review cards; negative seconds in some legacy rows.
    public var interval: Int
    /// Ease in permille (2500 = 250%).
    public var factor: Int
    public var reps: Int
    public var lapses: Int
    public var left: Int
    public var originalDue: Int
    public var originalDeckID: DeckID
    public var flags: Int
    public var data: CardData

    public init(id: CardID = 0, noteID: NoteID, deckID: DeckID, ord: Int, due: Int) {
        self.id = id
        self.noteID = noteID
        self.deckID = deckID
        self.ord = ord
        mtime = 0
        usn = -1
        type = .new
        queue = .new
        self.due = due
        interval = 0
        factor = 0
        reps = 0
        lapses = 0
        left = 0
        originalDue = 0
        originalDeckID = 0
        flags = 0
        data = CardData()
    }

    public var flag: Int { flags & 0b111 }
    public var isBuried: Bool { queue == .manuallyBuried || queue == .siblingBuried }
    public var isSuspended: Bool { queue == .suspended }
    public var isFiltered: Bool { originalDeckID != 0 }
    public var homeDeckID: DeckID { originalDeckID != 0 ? originalDeckID : deckID }
}

/// The JSON kept in `cards.data`: FSRS memory state and friends. Unknown keys are kept.
public struct CardData: Equatable, Sendable {
    public var stability: Double?
    public var difficulty: Double?
    public var desiredRetention: Double?
    public var decay: Double?
    /// Last review time, epoch seconds.
    public var lastReview: Int?
    public var originalPosition: Int?
    var extra: [String: JSONValue] = [:]

    public init() {}

    public init(json: String) {
        guard !json.isEmpty, let obj = try? JSONDecoder().decode([String: JSONValue].self, from: Data(json.utf8)) else { return }
        var rest = obj
        stability = rest.removeValue(forKey: "s")?.double
        difficulty = rest.removeValue(forKey: "d")?.double
        desiredRetention = rest.removeValue(forKey: "dr")?.double
        decay = rest.removeValue(forKey: "decay")?.double
        lastReview = rest.removeValue(forKey: "lrt")?.double.map { Int($0) }
        originalPosition = rest.removeValue(forKey: "pos")?.double.map { Int($0) }
        extra = rest
    }

    public var json: String {
        var obj = extra
        if let v = stability { obj["s"] = .number((v * 1000).rounded() / 1000) }
        if let v = difficulty { obj["d"] = .number((v * 1000).rounded() / 1000) }
        if let v = desiredRetention { obj["dr"] = .number((v * 100).rounded() / 100) }
        if let v = decay { obj["decay"] = .number((v * 10000).rounded() / 10000) }
        if let v = lastReview { obj["lrt"] = .number(Double(v)) }
        if let v = originalPosition { obj["pos"] = .number(Double(v)) }
        guard !obj.isEmpty else { return "" }
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        return (try? enc.encode(obj)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    public var memory: MemoryState? {
        guard let s = stability, let d = difficulty else { return nil }
        return MemoryState(stability: s, difficulty: d)
    }
}

public struct MemoryState: Equatable, Sendable {
    public var stability: Double
    public var difficulty: Double

    public init(stability: Double, difficulty: Double) {
        self.stability = stability
        self.difficulty = difficulty
    }
}

public struct RevlogEntry: Equatable, Sendable {
    public enum Kind: Int, Sendable { case learning = 0, review = 1, relearning = 2, filtered = 3, manual = 4, rescheduled = 5 }
    public var id: Int
    public var cardID: CardID
    public var usn: Int
    public var ease: Int
    /// Positive days or negative seconds.
    public var interval: Int
    public var lastInterval: Int
    public var factor: Int
    /// Milliseconds spent answering.
    public var time: Int
    public var kind: Kind
}

// MARK: Notetypes

public struct Notetype: Identifiable, Equatable, Sendable {
    public struct Field: Equatable, Sendable {
        public var ord: Int
        public var name: String
        public var config = Proto()

        public init(ord: Int, name: String) {
            self.ord = ord
            self.name = name
            config.setString(3, "Arial")
            config.setUInt(4, 20)
        }

        init(ord: Int, name: String, config: Proto) {
            self.ord = ord
            self.name = name
            self.config = config
        }

        public var sticky: Bool { get { config.bool(1) } set { config.setBool(1, newValue) } }
        public var rtl: Bool { get { config.bool(2) } set { config.setBool(2, newValue) } }
        public var fontName: String { get { config.string(3) } set { config.setString(3, newValue) } }
        public var fontSize: Int { get { Int(config.uint(4)) } set { config.setUInt(4, UInt64(newValue)) } }
        public var description: String { get { config.string(5) } set { config.setString(5, newValue) } }
        public var plainText: Bool { get { config.bool(6) } set { config.setBool(6, newValue) } }
        public var excludeFromSearch: Bool { config.bool(8) }
    }

    public struct Template: Equatable, Sendable {
        public var ord: Int
        public var name: String
        public var mtime: Int = 0
        public var usn: Int = -1
        public var config = Proto()

        public init(ord: Int, name: String, front: String, back: String) {
            self.ord = ord
            self.name = name
            self.front = front
            self.back = back
        }

        init(ord: Int, name: String, mtime: Int, usn: Int, config: Proto) {
            self.ord = ord
            self.name = name
            self.mtime = mtime
            self.usn = usn
            self.config = config
        }

        public var front: String { get { config.string(1) } set { config.setString(1, newValue) } }
        public var back: String { get { config.string(2) } set { config.setString(2, newValue) } }
        public var browserFront: String { config.string(3) }
        public var browserBack: String { config.string(4) }
        /// Deck override for new cards of this template (0 = none).
        public var targetDeckID: DeckID { get { config.int(5) } set { config.setInt(5, newValue) } }
    }

    public enum Kind: Int, Sendable { case normal = 0, cloze = 1 }

    public var id: NotetypeID
    public var name: String
    public var mtime: Int = 0
    public var usn: Int = -1
    public var fields: [Field]
    public var templates: [Template]
    public var config = Proto()

    public init(id: NotetypeID = 0, name: String, kind: Kind = .normal, fields: [Field], templates: [Template], css: String) {
        self.id = id
        self.name = name
        self.fields = fields
        self.templates = templates
        self.kind = kind
        self.css = css
        latexPre = Notetype.defaultLatexPre
        latexPost = "\\end{document}"
    }

    init(id: NotetypeID, name: String, mtime: Int, usn: Int, config: Proto, fields: [Field], templates: [Template]) {
        self.id = id
        self.name = name
        self.mtime = mtime
        self.usn = usn
        self.config = config
        self.fields = fields
        self.templates = templates
    }

    public var kind: Kind { get { Kind(rawValue: Int(config.uint(1))) ?? .normal } set { config.setUInt(1, UInt64(newValue.rawValue)) } }
    public var isCloze: Bool { kind == .cloze }
    public var sortFieldIndex: Int { get { Int(config.uint(2)) } set { config.setUInt(2, UInt64(newValue)) } }
    public var css: String { get { config.string(3) } set { config.setString(3, newValue) } }
    public var latexPre: String { get { config.string(5) } set { config.setString(5, newValue) } }
    public var latexPost: String { get { config.string(6) } set { config.setString(6, newValue) } }

    public var fieldNames: [String] { fields.map(\.name) }
    public func fieldIndex(_ name: String) -> Int? {
        fields.firstIndex { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    static let defaultLatexPre = """
    \\documentclass[12pt]{article}
    \\special{papersize=3in,5in}
    \\usepackage[utf8]{inputenc}
    \\usepackage{amssymb,amsmath}
    \\pagestyle{empty}
    \\setlength{\\parindent}{0in}
    \\begin{document}

    """
}

// MARK: Decks

public struct Deck: Identifiable, Equatable, Sendable {
    public var id: DeckID
    /// Full name with "::" between levels.
    public var name: String
    public var mtime: Int = 0
    public var usn: Int = -1
    public var common = Proto()
    public var kind = Proto()

    public init(id: DeckID = 0, name: String) {
        self.id = id
        self.name = name
        var normal = Proto()
        normal.setInt(1, 1)
        kind.setMessage(1, normal)
    }

    init(id: DeckID, name: String, mtime: Int, usn: Int, common: Proto, kind: Proto) {
        self.id = id
        self.name = name
        self.mtime = mtime
        self.usn = usn
        self.common = common
        self.kind = kind
    }

    public var isFiltered: Bool { kind.has(2) }
    var normal: Proto { get { kind.message(1) } set { kind.setMessage(1, newValue) } }
    public var filtered: Proto { get { kind.message(2) } set { kind.setMessage(2, newValue) } }

    public var configID: DeckConfigID {
        get { isFiltered ? 1 : max(1, normal.int(1)) }
        set { var n = normal; n.setInt(1, newValue); normal = n }
    }

    public var description: String {
        get { isFiltered ? "" : normal.string(4) }
        set { var n = normal; n.setString(4, newValue); normal = n }
    }

    public var components: [String] { name.components(separatedBy: "::") }
    public var leafName: String { components.last ?? name }
    public var depth: Int { components.count - 1 }
    public var parentName: String? { components.count > 1 ? components.dropLast().joined(separator: "::") : nil }

    public var collapsed: Bool { get { common.bool(1) } set { common.setBool(1, newValue) } }
    public var browserCollapsed: Bool { common.bool(2) }
    public var lastDayStudied: Int { Int(common.uint(3)) }

    /// New/review counts already studied today (signed, Anki stores int32).
    public func studied(today: Int) -> (new: Int, review: Int) {
        guard lastDayStudied == today else { return (0, 0) }
        return (Int(Int32(truncatingIfNeeded: common.uint(4))), Int(Int32(truncatingIfNeeded: common.uint(5))))
    }

    mutating func addStudied(today: Int, new: Int, review: Int, millis: Int) {
        let (n, r) = studied(today: today)
        let ms = lastDayStudied == today ? Int(Int32(truncatingIfNeeded: common.uint(7))) : 0
        common.setUInt(3, UInt64(today))
        common.setInt(4, n + new)
        common.setInt(5, r + review)
        common.setInt(7, ms + millis)
    }

    /// Per-deck limit overrides (Anki 2.1.55+).
    public var reviewLimit: Int? { isFiltered ? nil : normal.optionalInt(6) }
    public var newLimit: Int? { isFiltered ? nil : normal.optionalInt(7) }
    public func reviewLimitToday(_ today: Int) -> Int? {
        let m = normal.message(8)
        return normal.has(8) && Int(m.uint(2)) == today ? Int(m.uint(1)) : nil
    }
    public func newLimitToday(_ today: Int) -> Int? {
        let m = normal.message(9)
        return normal.has(9) && Int(m.uint(2)) == today ? Int(m.uint(1)) : nil
    }
    public var desiredRetention: Float? { isFiltered ? nil : normal.optionalFloat(10) }
}

// MARK: Deck options

public struct DeckConfig: Identifiable, Equatable, Sendable {
    public enum LeechAction: Int, Sendable { case suspend = 0, tagOnly = 1 }

    public var id: DeckConfigID
    public var name: String
    public var mtime: Int = 0
    public var usn: Int = -1
    public var config: Proto

    init(id: DeckConfigID, name: String, mtime: Int, usn: Int, config: Proto) {
        self.id = id
        self.name = name
        self.mtime = mtime
        self.usn = usn
        self.config = config
    }

    /// Anki's defaults for a new preset.
    public init(id: DeckConfigID = 0, name: String) {
        self.id = id
        self.name = name
        var c = Proto()
        c.setFloats(1, [1, 10])
        c.setFloats(2, [10])
        c.setUInt(9, 20)
        c.setUInt(10, 200)
        c.setFloat(11, 2.5)
        c.setFloat(12, 1.3)
        c.setFloat(13, 1.2)
        c.setFloat(14, 0)
        c.setFloat(15, 1)
        c.setUInt(16, 36500)
        c.setUInt(17, 1)
        c.setUInt(18, 1)
        c.setUInt(19, 4)
        c.setUInt(20, 0)
        c.setUInt(21, 1)
        c.setUInt(22, 8)
        c.setUInt(24, 60)
        c.setFloat(37, 0.9)
        c.setFloat(41, 0)
        c.setFloat(42, 0)
        c.setFloat(40, 0.9)
        c.setFloats(4, [1, 1, 1, 1, 1, 1, 1])
        config = c
    }

    public var learnSteps: [Float] { get { config.floats(1) } set { config.setFloats(1, newValue) } }
    public var relearnSteps: [Float] { get { config.floats(2) } set { config.setFloats(2, newValue) } }
    public var fsrsParams: [Float] {
        let p6 = config.floats(6)
        if !p6.isEmpty { return p6 }
        let p5 = config.floats(5)
        return p5.isEmpty ? config.floats(3) : p5
    }
    public var newPerDay: Int { get { Int(config.uint(9)) } set { config.setUInt(9, UInt64(newValue)) } }
    public var reviewsPerDay: Int { get { Int(config.uint(10)) } set { config.setUInt(10, UInt64(newValue)) } }
    public var initialEase: Float { get { config.float(11) } set { config.setFloat(11, newValue) } }
    public var easyMultiplier: Float { get { config.float(12) } set { config.setFloat(12, newValue) } }
    public var hardMultiplier: Float { get { config.float(13) } set { config.setFloat(13, newValue) } }
    public var lapseMultiplier: Float { get { config.float(14) } set { config.setFloat(14, newValue) } }
    public var intervalMultiplier: Float { get { config.float(15) } set { config.setFloat(15, newValue) } }
    public var maximumInterval: Int { get { Int(config.uint(16)) } set { config.setUInt(16, UInt64(newValue)) } }
    public var minimumLapseInterval: Int { get { Int(config.uint(17)) } set { config.setUInt(17, UInt64(newValue)) } }
    public var graduatingInterval: Int { get { Int(config.uint(18)) } set { config.setUInt(18, UInt64(newValue)) } }
    public var easyInterval: Int { get { Int(config.uint(19)) } set { config.setUInt(19, UInt64(newValue)) } }
    public var newCardsRandom: Bool { config.uint(20) == 1 }
    public var leechAction: LeechAction {
        get { LeechAction(rawValue: Int(config.uint(21))) ?? .suspend }
        set { config.setUInt(21, UInt64(newValue.rawValue)) }
    }
    public var leechThreshold: Int { get { Int(config.uint(22)) } set { config.setUInt(22, UInt64(newValue)) } }
    public var disableAutoplay: Bool { get { config.bool(23) } set { config.setBool(23, newValue) } }
    public var capAnswerTimeSecs: Int { Int(config.uint(24)) }
    public var showTimer: Bool { get { config.bool(25) } set { config.setBool(25, newValue) } }
    public var buryNew: Bool { get { config.bool(27) } set { config.setBool(27, newValue) } }
    public var buryReviews: Bool { get { config.bool(28) } set { config.setBool(28, newValue) } }
    public var buryInterdayLearning: Bool { get { config.bool(29) } set { config.setBool(29, newValue) } }
    /// 0 mix with reviews, 1 after reviews, 2 before reviews.
    public var newMix: Int { Int(config.uint(30)) }
    public var interdayLearningMix: Int { Int(config.uint(31)) }
    public var reviewOrder: Int { Int(config.uint(33)) }
    public var newGatherPriority: Int { Int(config.uint(34)) }
    public var newSortOrder: Int { Int(config.uint(32)) }
    public var desiredRetention: Float {
        get { let r = config.float(37); return r > 0 ? r : 0.9 }
        set { config.setFloat(37, newValue) }
    }
}

// MARK: JSON helper

enum JSONValue: Codable, Equatable, Sendable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n):
            if n == n.rounded(), abs(n) < 1e15 { try c.encode(Int64(n)) } else { try c.encode(n) }
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    var double: Double? {
        switch self {
        case .number(let n): return n
        case .bool(let b): return b ? 1 : 0
        case .string(let s): return Double(s)
        default: return nil
        }
    }
}

public enum Guid {
    private static let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$%&()*+,-./:;<=>?@[]^_`{|}~")

    /// Anki's base91 note guid.
    public static func make() -> String {
        var n = UInt64.random(in: 0...UInt64.max)
        var out = ""
        repeat {
            out.append(alphabet[Int(n % 91)])
            n /= 91
        } while n > 0
        return String(out.reversed())
    }
}
