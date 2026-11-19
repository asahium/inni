import Foundation

public struct CollectionStats: Sendable {
    public struct Today: Sendable {
        public var reviews = 0
        public var seconds = 0
        public var again = 0
        public var learn = 0
        public var review = 0
        public var relearn = 0
    }

    public struct CardCounts: Sendable {
        public var new = 0
        public var learning = 0
        public var relearning = 0
        public var young = 0
        public var mature = 0
        public var suspended = 0
        public var buried = 0
        public var total: Int { new + learning + relearning + young + mature + suspended + buried }
    }

    public struct Day: Identifiable, Sendable {
        public var day: Int
        public var learn = 0
        public var young = 0
        public var mature = 0
        public var relearn = 0
        public var id: Int { day }
        public var total: Int { learn + young + mature + relearn }
    }

    public var today = Today()
    public var counts = CardCounts()
    /// Due counts for the coming days (day 0 includes overdue).
    public var forecast: [Day] = []
    /// Reviews per day for the past days (negative offsets).
    public var history: [Day] = []
    /// Pass rate on mature (≥21d) and young reviews over the period.
    public var matureRetention: Double?
    public var youngRetention: Double?
    public var studyDays = 0
    public var period = 30

    public init() {}
}

extension Collection {
    /// Statistics for a deck and its children, or the whole collection.
    public func stats(deckID: DeckID?, days: Int = 30) -> CollectionStats {
        var s = CollectionStats()
        s.period = days
        let dids = deckID.map { deckAndChildren($0).map(\.id) } ?? Array(decks.keys)
        let didList = dids.map(String.init).joined(separator: ",")
        let cardFilter = deckID == nil ? "1" : "(did in (\(didList)) or odid in (\(didList)))"
        let revFilter = deckID == nil ? "1" : "cid in (select id from cards where \(cardFilter))"
        let today = self.today
        let dayStartMs = (timing.nextDayAt - 86400) * 1000

        if let st = try? db.prepare("""
            select count(), coalesce(sum(time), 0), coalesce(sum(ease = 1), 0), coalesce(sum(type = 0), 0),
                   coalesce(sum(type = 1), 0), coalesce(sum(type = 2), 0)
            from revlog where id > ? and type < 4 and \(revFilter)
            """).bind([dayStartMs]), (try? st.step()) == true {
            s.today = .init(reviews: st.integer(0), seconds: st.integer(1) / 1000, again: st.integer(2), learn: st.integer(3),
                            review: st.integer(4), relearn: st.integer(5))
        }

        if let st = try? db.prepare("select type, queue, ivl from cards where \(cardFilter)") {
            while (try? st.step()) == true {
                let type = st.integer(0), queue = st.integer(1), ivl = st.integer(2)
                if queue == -1 { s.counts.suspended += 1 }
                else if queue == -2 || queue == -3 { s.counts.buried += 1 }
                else if type == 0 { s.counts.new += 1 }
                else if type == 1 { s.counts.learning += 1 }
                else if type == 3 { s.counts.relearning += 1 }
                else if ivl >= 21 { s.counts.mature += 1 }
                else { s.counts.young += 1 }
            }
        }

        var forecast = (0..<days).map { CollectionStats.Day(day: $0) }
        if let st = try? db.prepare("""
            select queue, due, ivl, type from cards where \(cardFilter) and queue in (1, 2, 3)
            """) {
            let end = timing.nextDayAt
            while (try? st.step()) == true {
                let queue = st.integer(0), due = st.integer(1), ivl = st.integer(2), type = st.integer(3)
                let offset = queue == 1 ? max(0, (due - end) / 86400 + 1) : max(0, due - today)
                guard offset < days else { continue }
                if queue == 1 || type == 1 { forecast[offset].learn += 1 }
                else if type == 3 { forecast[offset].relearn += 1 }
                else if ivl >= 21 { forecast[offset].mature += 1 }
                else { forecast[offset].young += 1 }
            }
        }
        s.forecast = forecast

        var history = (0..<days).map { CollectionStats.Day(day: -(days - 1) + $0) }
        var young = (0, 0), mature = (0, 0)
        let fromMs = dayStartMs - (days - 1) * 86_400_000
        if let st = try? db.prepare("""
            select id, type, ease, lastIvl from revlog where id > ? and type < 4 and ease > 0 and \(revFilter)
            """).bind([fromMs]) {
            while (try? st.step()) == true {
                let idx = (st.integer(0) - fromMs) / 86_400_000
                guard history.indices.contains(idx) else { continue }
                let type = st.integer(1), ease = st.integer(2), last = st.integer(3)
                switch type {
                case 0: history[idx].learn += 1
                case 2: history[idx].relearn += 1
                default:
                    if last >= 21 {
                        history[idx].mature += 1
                        mature.0 += ease > 1 ? 1 : 0
                        mature.1 += 1
                    } else {
                        history[idx].young += 1
                        young.0 += ease > 1 ? 1 : 0
                        young.1 += 1
                    }
                }
            }
        }
        s.history = history
        s.studyDays = history.filter { $0.total > 0 }.count
        s.youngRetention = young.1 > 0 ? Double(young.0) / Double(young.1) : nil
        s.matureRetention = mature.1 > 0 ? Double(mature.0) / Double(mature.1) : nil
        return s
    }
}
