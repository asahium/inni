import Foundation

public struct DeckCounts: Equatable, Sendable {
    public var new = 0
    public var learning = 0
    public var review = 0
    public var total: Int { new + learning + review }
    public init(new: Int = 0, learning: Int = 0, review: Int = 0) {
        self.new = new
        self.learning = learning
        self.review = review
    }
}

public struct DeckNode: Identifiable, Sendable {
    public var deck: Deck
    public var counts: DeckCounts
    public var children: [DeckNode]
    public var id: DeckID { deck.id }
    public var name: String { deck.leafName }
    public var childrenOrNil: [DeckNode]? { children.isEmpty ? nil : children }
}

extension Collection {
    // MARK: Limits

    func newLimit(_ d: Deck, today: Int) -> Int {
        if d.isFiltered { return Int.max / 4 }
        let base = d.newLimitToday(today) ?? d.newLimit ?? config(for: d).newPerDay
        return max(0, base - d.studied(today: today).new)
    }

    func reviewLimit(_ d: Deck, today: Int) -> Int {
        if d.isFiltered { return Int.max / 4 }
        let base = d.reviewLimitToday(today) ?? d.reviewLimit ?? config(for: d).reviewsPerDay
        return max(0, base - d.studied(today: today).review)
    }

    /// Unburies cards left buried from a previous day.
    func unburyIfNewDay() throws {
        let today = self.today
        guard configInt("lastUnburied") != today else { return }
        try db.exec("update cards set queue = (case when type = 0 then 0 when type = 2 then 2 when due > 1000000000 then 1 else 3 end), mod = \(Collection.nowSecs), usn = -1 where queue in (-2, -3)")
        try setConfig("lastUnburied", today)
    }

    // MARK: Deck tree

    /// The deck list with due counts, honouring daily limits down the tree.
    public func deckTree() -> [DeckNode] {
        try? unburyIfNewDay()
        let t = timing
        var own: [DeckID: (new: Int, rev: Int, dayLearn: Int, learn: Int)] = [:]
        if let s = try? db.prepare("""
            select did, sum(queue = 0), sum(queue = 2 and due <= ?1), sum(queue = 3 and due <= ?1), sum(queue = 1 and due < ?2)
            from cards where queue between 0 and 4 group by did
            """).bind([t.daysElapsed, t.nextDayAt]) {
            while (try? s.step()) == true { own[s.integer(0)] = (s.integer(1), s.integer(2), s.integer(3), s.integer(4)) }
        }
        let sorted = sortedDecks
        var byParent: [String: [Deck]] = [:]
        var roots: [Deck] = []
        for d in sorted {
            if let p = d.parentName, deck(named: p) != nil { byParent[p, default: []].append(d) } else { roots.append(d) }
        }

        struct Built {
            var node: DeckNode
            /// Intraday learning (unlimited) and interday learning (counts against the review limit), kept apart.
            var intraday: Int
            var interday: Int
        }

        func build(_ d: Deck) -> Built {
            let kids = (byParent[d.name] ?? []).map(build)
            let o = own[d.id] ?? (0, 0, 0, 0)
            var revRaw = o.rev, dayRaw = o.dayLearn, newRaw = o.new, intraday = o.learn
            for k in kids {
                revRaw += k.node.counts.review
                dayRaw += k.interday
                newRaw += k.node.counts.new
                intraday += k.intraday
            }
            let revLimit = reviewLimit(d, today: t.daysElapsed)
            let rev = min(revRaw, revLimit)
            let interday = min(dayRaw, max(0, revLimit - rev))
            let new = min(newRaw, newLimit(d, today: t.daysElapsed), max(0, revLimit - rev - interday))
            let counts = DeckCounts(new: new, learning: intraday + interday, review: rev)
            return Built(node: DeckNode(deck: d, counts: counts, children: kids.map(\.node)), intraday: intraday, interday: interday)
        }

        let tree = roots.map { build($0).node }
        // Hide an empty, childless Default deck like Anki does.
        return tree.filter { !($0.deck.id == 1 && $0.children.isEmpty && tree.count > 1 && cardCount(inDeck: 1) == 0) }
    }

    func cardCount(inDeck did: DeckID) -> Int { (try? db.scalar("select count() from cards where did = ?", did)) ?? 0 }
}

/// A study session for one deck and its subdecks.
public final class Scheduler {
    struct Undo {
        let card: Card
        let deck: Deck?
        let revlogID: Int
        let buried: [CardID]
    }

    public let col: Collection
    public let deckID: DeckID
    private var learning: [Card] = []
    private var main: [Card] = []
    private var undoStack: [Undo] = []
    private var dayBuilt = -1
    public private(set) var counts = DeckCounts()

    public init(col: Collection, deckID: DeckID) {
        self.col = col
        self.deckID = deckID
        rebuild()
    }

    public var canUndo: Bool { !undoStack.isEmpty }

    /// Re-reads the queues (after edits, a day change, or option changes).
    public func rebuild() {
        try? col.unburyIfNewDay()
        let t = col.timing
        dayBuilt = t.daysElapsed
        let today = t.daysElapsed
        let decks = col.deckAndChildren(deckID)
        guard let root = decks.first else {
            learning = []
            main = []
            counts = DeckCounts()
            return
        }
        let selectedIDs = decks.map(\.id)
        let idList = selectedIDs.map(String.init).joined(separator: ",")
        let conf = col.config(for: root)

        learning = (try? col.db.prepare("select \(Collection.cardColumns) from cards where did in (\(idList)) and queue = 1 and due < ? order by due")
            .bind([t.nextDayAt]).map(Collection.card)) ?? []

        // Remaining allowance per deck, applied through each deck's ancestors within the selection.
        var revLeft: [DeckID: Int] = [:], newLeft: [DeckID: Int] = [:]
        for d in decks {
            revLeft[d.id] = col.reviewLimit(d, today: today)
            newLeft[d.id] = col.newLimit(d, today: today)
        }
        func chain(_ d: Deck) -> [DeckID] {
            [d.id] + col.parents(of: d).filter { selectedIDs.contains($0.id) }.map(\.id)
        }

        var seenNotes = Set<NoteID>()
        var reviews: [Card] = []
        for d in decks {
            let ids = chain(d)
            let bury = col.config(for: d)
            guard let s = try? col.db.prepare("""
                select \(Collection.cardColumns) from cards where did = ? and queue in (2, 3) and due <= ? order by due, (id * 7919) % 104729
                """).bind([d.id, today]) else { continue }
            while (try? s.step()) == true {
                let c = Collection.card(from: s)
                let left = ids.map { revLeft[$0] ?? 0 }.min() ?? 0
                if left <= 0 { break }
                let buryIt = c.queue == .review ? bury.buryReviews : bury.buryInterdayLearning
                if buryIt, seenNotes.contains(c.noteID) { continue }
                seenNotes.insert(c.noteID)
                reviews.append(c)
                for id in ids { revLeft[id, default: 0] -= 1 }
            }
        }
        reviews.sort { $0.due < $1.due }

        var news: [Card] = []
        for d in decks {
            let ids = chain(d)
            let dc = col.config(for: d)
            let order = dc.newCardsRandom ? "(id * 7919) % 104729" : "due, ord"
            guard let s = try? col.db.prepare("select \(Collection.cardColumns) from cards where did = ? and queue = 0 order by \(order)")
                .bind([d.id]) else { continue }
            while (try? s.step()) == true {
                let left = ids.map { min(newLeft[$0] ?? 0, revLeft[$0] ?? 0) }.min() ?? 0
                if left <= 0 { break }
                let c = Collection.card(from: s)
                if dc.buryNew, seenNotes.contains(c.noteID) { continue }
                seenNotes.insert(c.noteID)
                news.append(c)
                for id in ids {
                    newLeft[id, default: 0] -= 1
                    revLeft[id, default: 0] -= 1
                }
            }
        }

        switch conf.newMix {
        case 1: main = reviews + news
        case 2: main = news + reviews
        default: main = Scheduler.spread(news, into: reviews)
        }
        recount()
    }

    static func spread(_ news: [Card], into reviews: [Card]) -> [Card] {
        guard !news.isEmpty, !reviews.isEmpty else { return reviews + news }
        var out: [Card] = []
        out.reserveCapacity(news.count + reviews.count)
        let step = Double(reviews.count + news.count) / Double(news.count)
        var ni = 0, ri = 0
        var nextNew = step / 2
        for i in 0..<(news.count + reviews.count) {
            if ni < news.count, Double(i) >= nextNew - 1 || ri >= reviews.count {
                out.append(news[ni])
                ni += 1
                nextNew += step
            } else if ri < reviews.count {
                out.append(reviews[ri])
                ri += 1
            }
        }
        return out
    }

    private func recount() {
        var c = DeckCounts()
        c.learning = learning.count
        for card in main {
            switch card.queue {
            case .new: c.new += 1
            case .dayLearning: c.learning += 1
            default: c.review += 1
            }
        }
        counts = c
    }

    private var learnAheadSecs: Int { col.configInt("collapseTime") ?? 1200 }

    /// The next card to show, or nil when done for now.
    public func next() -> Card? {
        if col.today != dayBuilt { rebuild() }
        let now = Collection.nowSecs
        if let l = learning.first, l.due <= now { return l }
        if let m = main.first { return m }
        if let l = learning.first, l.due <= now + learnAheadSecs { return l }
        return nil
    }

    /// When the next learning card becomes due, if any are waiting.
    public var nextLearningDue: Date? { learning.first.map { Date(timeIntervalSince1970: TimeInterval($0.due)) } }

    // MARK: Answering

    func context(for card: Card) -> StateContext {
        let deck = col.decks[card.homeDeckID] ?? col.decks[card.deckID] ?? Deck(id: 1, name: "Default")
        let conf = col.config(for: deck)
        let fsrs = col.fsrsEnabled ? FSRS(params: conf.fsrsParams) : nil
        let retention = Double(deck.desiredRetention ?? conf.desiredRetention)
        var rng = SplitMix64(seed: UInt64(bitPattern: Int64(card.id &+ card.reps)))
        return StateContext(conf, fsrs: fsrs, desiredRetention: retention, fuzzFactor: rng.unit())
    }

    func dayOf(_ secs: Int) -> Int {
        let co = col.configInt("creationOffset") ?? SchedTiming.localMinutesWest()
        return SchedTiming(createdSecs: col.creationSecs, createdMinsWest: co, nowSecs: secs,
                           nowMinsWest: SchedTiming.localMinutesWest(Date(timeIntervalSince1970: TimeInterval(secs))),
                           rolloverHour: col.configInt("rollover") ?? 4).daysElapsed
    }

    /// Days since the card was last answered.
    func elapsedDays(_ card: Card) -> Int {
        let today = col.today
        if let lrt = card.data.lastReview { return max(0, today - dayOf(lrt)) }
        if card.type == .review { return max(0, today - (card.due - card.interval)) }
        if let last = col.revlog(for: card.id).last(where: { $0.ease > 0 }) { return max(0, today - dayOf(last.id / 1000)) }
        return 0
    }

    /// Days since the last recorded review, for FSRS. Unknown history counts as 0, as in Anki.
    func fsrsElapsedDays(_ card: Card) -> Int {
        let today = col.today
        if let lrt = card.data.lastReview { return max(0, today - dayOf(lrt)) }
        if let last = col.revlog(for: card.id).last(where: { (1...4).contains($0.ease) && $0.kind != .manual }) {
            return max(0, today - dayOf(last.id / 1000))
        }
        return 0
    }

    func currentState(_ card: Card, fsrs: FSRS?) -> CardState {
        var memory = card.data.memory
        if let fsrs, memory == nil, card.type != .new {
            memory = fsrs.memory(from: col.revlog(for: card.id)) { self.dayOf($0.id / 1000) }
            if memory == nil, card.type == .review || card.type == .relearning {
                memory = fsrs.memoryFromSM2(ease: Double(max(1300, card.factor)) / 1000, interval: Double(max(1, card.interval)))
            }
        }
        if fsrs == nil { memory = nil }
        let review = CardState.Review(scheduledDays: max(0, card.interval), elapsedDays: elapsedDays(card),
                                      ease: Double(card.factor > 0 ? card.factor : 2500) / 1000, lapses: card.lapses, memory: memory)
        let learn = CardState.Learning(remainingSteps: card.left % 1000, scheduledSecs: 0, memory: memory)
        switch card.type {
        case .new: return .new(position: card.due)
        case .learning: return .learning(learn)
        case .review: return .review(review)
        case .relearning: return .relearning(learn, review)
        }
    }

    public func nextStates(for card: Card) -> NextStates {
        let ctx = context(for: card)
        return ctx.nextStates(currentState(card, fsrs: ctx.fsrs), elapsedDays: elapsedDays(card), fsrsDays: fsrsElapsedDays(card))
    }

    /// Button labels ("10m", "4d") for each rating.
    public func intervalLabels(for card: Card) -> [Rating: String] {
        let n = nextStates(for: card)
        var out: [Rating: String] = [:]
        for r in Rating.allCases { out[r] = IntervalFormat.short(secs: n.state(for: r).delaySecs) }
        return out
    }

    @discardableResult
    public func answer(_ card: Card, rating: Rating, millis: Int) throws -> Card {
        let ctx = context(for: card)
        let states = ctx.nextStates(currentState(card, fsrs: ctx.fsrs), elapsedDays: elapsedDays(card), fsrsDays: fsrsElapsedDays(card))
        let next = states.state(for: rating)
        let now = Collection.nowSecs, today = col.today
        let deck = col.decks[card.homeDeckID]
        let conf = deck.map { col.config(for: $0) }
        var c = card
        let before = card

        func learningDue(_ secs: Int) -> (CardQueue, Int) {
            if secs < 86400 {
                let fuzz = min(Double(secs) * 0.25, 300)
                return (.learning, now + secs + (fuzz > 0 ? Int.random(in: 0...Int(fuzz)) : 0))
            }
            return (.dayLearning, today + max(1, Int((Double(secs) / 86400).rounded())))
        }

        var revIvl = 0
        switch next {
        case .new: break
        case .learning(let l):
            c.type = .learning
            (c.queue, c.due) = learningDue(l.scheduledSecs)
            c.left = l.remainingSteps
            revIvl = -l.scheduledSecs
            if c.factor == 0 { c.factor = Int(ctx.initialEase * 1000) }
        case .review(let r):
            c.type = .review
            c.queue = .review
            c.due = today + r.scheduledDays
            c.interval = r.scheduledDays
            c.factor = Int((r.ease * 1000).rounded())
            c.lapses = r.lapses
            c.left = 0
            revIvl = r.scheduledDays
            if r.leeched { try leech(&c, conf) }
        case .relearning(let l, let r):
            c.type = .relearning
            (c.queue, c.due) = learningDue(l.scheduledSecs)
            c.interval = r.scheduledDays
            c.factor = Int((r.ease * 1000).rounded())
            c.lapses = r.lapses
            c.left = l.remainingSteps
            revIvl = -l.scheduledSecs
            if r.leeched { try leech(&c, conf) }
        }
        c.reps += 1
        if let m = next.memory, ctx.fsrs != nil {
            c.data.stability = m.stability
            c.data.difficulty = m.difficulty
            c.data.desiredRetention = ctx.desiredRetention
            c.data.decay = ctx.fsrs?.decay.magnitude
        }
        c.data.lastReview = now
        if c.isFiltered, c.queue == .review || c.queue == .dayLearning {
            // Answered cards in a filtered deck go home once they leave learning.
            if c.queue == .review {
                c.deckID = c.originalDeckID
                c.originalDeckID = 0
                c.originalDue = 0
            }
        }

        let cap = (conf?.capAnswerTimeSecs ?? 60) * 1000
        let lastIvl: Int = {
            switch before.type {
            case .new: return 0
            case .learning: return -(LearningSteps(steps: ctx.learnSteps).goodDelay(max(0, before.left % 1000 + 1)) ?? 60)
            case .review, .relearning: return before.interval
            }
        }()
        let kind: RevlogEntry.Kind = {
            switch before.type {
            case .new, .learning: return .learning
            case .review: return .review
            case .relearning: return .relearning
            }
        }()
        let revID = try col.uniqueTimestampID(table: "revlog")
        var buried: [CardID] = []
        var deckBefore: Deck?

        try col.db.transaction {
            try col.update(c)
            try col.insert(RevlogEntry(id: revID, cardID: c.id, usn: -1, ease: rating.rawValue, interval: revIvl, lastInterval: lastIvl,
                                       factor: c.type == .review || c.type == .relearning ? c.factor : before.factor,
                                       time: min(max(0, millis), cap > 0 ? cap : 60000), kind: kind))
            if let deck {
                deckBefore = deck
                let newDelta = before.queue == .new ? 1 : 0
                let revDelta = before.queue == .review || before.queue == .dayLearning ? 1 : 0
                for d in [deck] + col.parents(of: deck) {
                    var dd = d
                    dd.addStudied(today: today, new: newDelta, review: revDelta, millis: millis)
                    try col.save(dd)
                }
            }
            if let conf { buried = try burySiblings(of: c, conf) }
        }
        undoStack.append(Undo(card: before, deck: deckBefore, revlogID: revID, buried: buried))
        if undoStack.count > 30 { undoStack.removeFirst() }

        learning.removeAll { $0.id == c.id }
        main.removeAll { $0.id == c.id || buried.contains($0.id) }
        if c.queue == .learning, c.due < col.timing.nextDayAt {
            learning.append(c)
            learning.sort { $0.due < $1.due }
        }
        recount()
        return c
    }

    private func leech(_ c: inout Card, _ conf: DeckConfig?) throws {
        if var n = col.note(c.noteID), !n.hasTag("leech") {
            n.tags.append("leech")
            try col.update(n)
        }
        if (conf?.leechAction ?? .tagOnly) == .suspend { c.queue = .suspended }
    }

    private func burySiblings(of card: Card, _ conf: DeckConfig) throws -> [CardID] {
        guard conf.buryNew || conf.buryReviews || conf.buryInterdayLearning else { return [] }
        let today = col.today
        var ids: [CardID] = []
        for s in col.cards(ofNote: card.noteID) where s.id != card.id {
            let hit = (s.queue == .new && conf.buryNew)
                || (s.queue == .review && s.due <= today && conf.buryReviews)
                || (s.queue == .dayLearning && s.due <= today && conf.buryInterdayLearning)
            if hit {
                var b = s
                b.queue = .siblingBuried
                try col.update(b)
                ids.append(s.id)
            }
        }
        return ids
    }

    /// Reverts the last answer. Returns the card to show again.
    @discardableResult
    public func undo() throws -> Card? {
        guard let u = undoStack.popLast() else { return nil }
        try col.db.transaction {
            var c = u.card
            c.usn = -1
            try col.writeCard(c)
            try col.db.run("delete from revlog where id = ?", u.revlogID)
            if let d = u.deck {
                for x in [d] + col.parents(of: d) {
                    if let saved = col.decks[x.id] {
                        var restored = saved
                        let today = col.today
                        let wasNew = u.card.queue == .new ? 1 : 0
                        let wasRev = u.card.queue == .review || u.card.queue == .dayLearning ? 1 : 0
                        restored.addStudied(today: today, new: -wasNew, review: -wasRev, millis: 0)
                        try col.save(restored)
                    }
                }
            }
            for id in u.buried {
                if var s = col.card(id), s.queue == .siblingBuried {
                    s.queue = Collection.naturalQueue(s)
                    try col.update(s)
                }
            }
            try col.markModified()
        }
        rebuild()
        learning.removeAll { $0.id == u.card.id }
        main.removeAll { $0.id == u.card.id }
        main.insert(u.card, at: 0)
        recount()
        return u.card
    }

    /// Takes a card out of today's session (bury/suspend from the reviewer).
    public func drop(_ cardID: CardID) {
        learning.removeAll { $0.id == cardID }
        main.removeAll { $0.id == cardID }
        recount()
    }
}
