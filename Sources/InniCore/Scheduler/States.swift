import Foundation

public enum Rating: Int, CaseIterable, Sendable {
    case again = 1, hard = 2, good = 3, easy = 4

    public var label: String {
        switch self {
        case .again: return "Again"
        case .hard: return "Hard"
        case .good: return "Good"
        case .easy: return "Easy"
        }
    }
}

/// Scheduling state of a card, as in Anki's v3 scheduler.
public enum CardState: Equatable, Sendable {
    public struct Learning: Equatable, Sendable {
        public var remainingSteps: Int
        public var scheduledSecs: Int
        public var memory: MemoryState?
    }

    public struct Review: Equatable, Sendable {
        public var scheduledDays: Int
        public var elapsedDays: Int
        public var ease: Double
        public var lapses: Int
        public var leeched = false
        public var memory: MemoryState?
    }

    case new(position: Int)
    case learning(Learning)
    case review(Review)
    case relearning(Learning, Review)

    public var memory: MemoryState? {
        switch self {
        case .new: return nil
        case .learning(let l): return l.memory
        case .review(let r): return r.memory
        case .relearning(let l, _): return l.memory
        }
    }

    /// Delay until the card is due again, in seconds.
    public var delaySecs: Int {
        switch self {
        case .new: return 0
        case .learning(let l), .relearning(let l, _): return l.scheduledSecs
        case .review(let r): return r.scheduledDays * 86400
        }
    }
}

public struct NextStates: Equatable, Sendable {
    public var current: CardState
    public var again: CardState
    public var hard: CardState
    public var good: CardState
    public var easy: CardState

    public func state(for r: Rating) -> CardState {
        switch r {
        case .again: return again
        case .hard: return hard
        case .good: return good
        case .easy: return easy
        }
    }
}

/// Everything the state machine needs from deck options.
struct StateContext {
    var learnSteps: [Float]
    var relearnSteps: [Float]
    var graduatingInterval: Int
    var easyInterval: Int
    var initialEase: Double
    var hardMultiplier: Double
    var easyMultiplier: Double
    var intervalMultiplier: Double
    var lapseMultiplier: Double
    var maximumInterval: Int
    var minimumLapseInterval: Int
    var leechThreshold: Int
    var fsrs: FSRS?
    var desiredRetention: Double
    /// 0..<1, or nil for no fuzz.
    var fuzzFactor: Double?

    init(_ c: DeckConfig, fsrs: FSRS?, desiredRetention: Double, fuzzFactor: Double?) {
        learnSteps = c.learnSteps
        relearnSteps = c.relearnSteps
        graduatingInterval = max(1, c.graduatingInterval)
        easyInterval = max(1, c.easyInterval)
        initialEase = Double(c.initialEase > 0 ? c.initialEase : 2.5)
        hardMultiplier = Double(c.hardMultiplier > 0 ? c.hardMultiplier : 1.2)
        easyMultiplier = Double(c.easyMultiplier > 0 ? c.easyMultiplier : 1.3)
        intervalMultiplier = fsrs == nil ? Double(c.intervalMultiplier > 0 ? c.intervalMultiplier : 1) : 1
        lapseMultiplier = Double(c.lapseMultiplier)
        maximumInterval = max(1, c.maximumInterval > 0 ? c.maximumInterval : 36500)
        minimumLapseInterval = max(1, c.minimumLapseInterval)
        leechThreshold = c.leechThreshold
        self.fsrs = fsrs
        self.desiredRetention = desiredRetention
        self.fuzzFactor = fuzzFactor
    }
}

struct LearningSteps {
    let steps: [Float]

    private func secs(_ i: Int) -> Int? { i < steps.count ? Int((Double(steps[i]) * 60).rounded()) : nil }

    func index(_ remaining: Int) -> Int {
        let total = steps.count
        return min(max(0, total - remaining % 1000), max(0, total - 1))
    }

    var againDelay: Int? { secs(0) }

    func hardDelay(_ remaining: Int) -> Int? {
        let i = index(remaining)
        guard let current = secs(i) else { return nil }
        guard i == 0 else { return current }
        if let next = secs(1) { return (current + next) / 2 }
        return min(Int(Double(current) * 1.5), current + 86400)
    }

    func goodDelay(_ remaining: Int) -> Int? { secs(index(remaining) + 1) }
    func remainingForGood(_ remaining: Int) -> Int { max(0, steps.count - (index(remaining) + 1)) }
    var remainingForFailed: Int { steps.count }
}

extension StateContext {
    /// `elapsedDays` drives SM-2 lateness; `fsrsDays` (days since the last recorded review, 0 if unknown) drives memory.
    func nextStates(_ current: CardState, elapsedDays: Int, fsrsDays: Int) -> NextStates {
        switch current {
        case .new:
            let l = CardState.Learning(remainingSteps: LearningSteps(steps: learnSteps).remainingForFailed, scheduledSecs: 0, memory: nil)
            var n = learningStates(l, fsrsDays: 0)
            n.current = current
            return n
        case .learning(let l):
            return learningStates(l, fsrsDays: fsrsDays)
        case .review(let r):
            return reviewStates(r, elapsedDays: elapsedDays, fsrsDays: fsrsDays)
        case .relearning(let l, let r):
            return relearningStates(l, r, fsrsDays: fsrsDays)
        }
    }

    private func memory(_ m: MemoryState?, _ rating: Rating, _ days: Int) -> MemoryState? {
        fsrs?.next(m, days: Double(days), rating: rating.rawValue)
    }

    // MARK: Learning

    private func learningStates(_ l: CardState.Learning, fsrsDays: Int) -> NextStates {
        let steps = LearningSteps(steps: learnSteps)
        let m = { (r: Rating) in self.memory(l.memory, r, fsrsDays) }

        func graduate(_ rating: Rating, days: Int) -> CardState {
            .review(.init(scheduledDays: days, elapsedDays: 0, ease: initialEase, lapses: 0, memory: m(rating)))
        }

        let goodDays: Int = {
            if let fsrs, let mem = m(.good) { return fuzzed(fsrs.interval(stability: mem.stability, retention: desiredRetention), min: 1) }
            return fuzzed(Double(graduatingInterval), min: 1)
        }()

        let again: CardState = steps.againDelay.map {
            .learning(.init(remainingSteps: steps.remainingForFailed, scheduledSecs: $0, memory: m(.again)))
        } ?? graduate(.again, days: goodDays)

        let hard: CardState = steps.hardDelay(l.remainingSteps).map {
            .learning(.init(remainingSteps: l.remainingSteps, scheduledSecs: $0, memory: m(.hard)))
        } ?? graduate(.hard, days: goodDays)

        let good: CardState = steps.goodDelay(l.remainingSteps).map {
            .learning(.init(remainingSteps: steps.remainingForGood(l.remainingSteps), scheduledSecs: $0, memory: m(.good)))
        } ?? graduate(.good, days: goodDays)

        var easyDays: Int
        if let fsrs, let mem = m(.easy) {
            easyDays = fuzzed(fsrs.interval(stability: mem.stability, retention: desiredRetention), min: 1)
        } else {
            easyDays = fuzzed(Double(easyInterval), min: 1)
        }
        if case .review(let g) = good { easyDays = max(easyDays, min(maximumInterval, g.scheduledDays + 1)) }
        let easy = graduate(.easy, days: easyDays)
        return NextStates(current: .learning(l), again: again, hard: hard, good: good, easy: easy)
    }

    // MARK: Review

    private func reviewStates(_ r: CardState.Review, elapsedDays: Int, fsrsDays: Int) -> NextStates {
        let daysLate = max(0, elapsedDays - r.scheduledDays)
        let mem = { (rating: Rating) in self.memory(r.memory, rating, fsrsDays) }

        // Lapse
        let lapses = r.lapses + 1
        let againMem = mem(.again)
        let failingDays: Int = {
            if let fsrs, let am = againMem {
                return clampInterval(fsrs.interval(stability: am.stability, retention: desiredRetention).rounded(), min: minimumLapseInterval)
            }
            return clampInterval((Double(r.scheduledDays) * lapseMultiplier).rounded(), min: minimumLapseInterval)
        }()
        var lapsed = CardState.Review(scheduledDays: failingDays, elapsedDays: 0, ease: max(1.3, r.ease - 0.2), lapses: lapses,
                                      leeched: isLeech(lapses), memory: againMem)
        let again: CardState
        if let delay = LearningSteps(steps: relearnSteps).againDelay {
            again = .relearning(.init(remainingSteps: relearnSteps.count, scheduledSecs: delay, memory: againMem), lapsed)
        } else {
            lapsed.elapsedDays = 0
            again = .review(lapsed)
        }

        // Passing
        var hardDays: Int, goodDays: Int, easyDays: Int
        if let fsrs {
            let hm = mem(.hard)!, gm = mem(.good)!, em = mem(.easy)!
            hardDays = fuzzed(fsrs.interval(stability: hm.stability, retention: desiredRetention), min: 1)
            goodDays = fuzzed(fsrs.interval(stability: gm.stability, retention: desiredRetention), min: hardDays + 1)
            easyDays = fuzzed(fsrs.interval(stability: em.stability, retention: desiredRetention), min: goodDays + 1)
        } else {
            let cur = Double(r.scheduledDays)
            let hardMin = hardMultiplier <= 1 ? 0 : r.scheduledDays + 1
            hardDays = fuzzed(cur * hardMultiplier * intervalMultiplier, min: hardMin)
            let goodMin = hardMultiplier <= 1 ? r.scheduledDays + 1 : hardDays + 1
            goodDays = fuzzed((cur + Double(daysLate) / 2) * r.ease * intervalMultiplier, min: goodMin)
            easyDays = fuzzed((cur + Double(daysLate)) * r.ease * easyMultiplier * intervalMultiplier, min: goodDays + 1)
        }
        func passed(_ days: Int, _ easeDelta: Double, _ rating: Rating) -> CardState {
            .review(.init(scheduledDays: days, elapsedDays: 0, ease: max(1.3, r.ease + easeDelta), lapses: r.lapses, memory: mem(rating)))
        }
        return NextStates(current: .review(r), again: again, hard: passed(hardDays, -0.15, .hard),
                          good: passed(goodDays, 0, .good), easy: passed(easyDays, 0.15, .easy))
    }

    private func isLeech(_ lapses: Int) -> Bool {
        guard leechThreshold > 0, lapses >= leechThreshold else { return false }
        let half = max(1, Int((Double(leechThreshold) / 2).rounded(.up)))
        return (lapses - leechThreshold) % half == 0
    }

    // MARK: Relearning

    private func relearningStates(_ l: CardState.Learning, _ r: CardState.Review, fsrsDays: Int) -> NextStates {
        let steps = LearningSteps(steps: relearnSteps)
        let mem = { (rating: Rating) in self.memory(l.memory ?? r.memory, rating, fsrsDays) }

        func back(_ rating: Rating, days: Int) -> CardState {
            var rr = r
            rr.scheduledDays = days
            rr.elapsedDays = 0
            rr.memory = mem(rating)
            rr.leeched = false
            return .review(rr)
        }

        var goodDays = r.scheduledDays
        if let fsrs, let gm = mem(.good) {
            goodDays = fuzzed(fsrs.interval(stability: gm.stability, retention: desiredRetention), min: 1)
        }

        let again: CardState = steps.againDelay.map {
            var rr = r
            rr.leeched = false
            rr.memory = mem(.again)
            return .relearning(.init(remainingSteps: steps.remainingForFailed, scheduledSecs: $0, memory: mem(.again)), rr)
        } ?? back(.again, days: r.scheduledDays)

        let hard: CardState = steps.hardDelay(l.remainingSteps).map {
            .relearning(.init(remainingSteps: l.remainingSteps, scheduledSecs: $0, memory: mem(.hard)), r)
        } ?? back(.hard, days: goodDays)

        let good: CardState = steps.goodDelay(l.remainingSteps).map {
            .relearning(.init(remainingSteps: steps.remainingForGood(l.remainingSteps), scheduledSecs: $0, memory: mem(.good)), r)
        } ?? back(.good, days: goodDays)

        var easyDays = r.scheduledDays + 1
        if let fsrs, let em = mem(.easy) {
            easyDays = fuzzed(fsrs.interval(stability: em.stability, retention: desiredRetention), min: goodDays + 1)
        }
        return NextStates(current: .relearning(l, r), again: again, hard: hard, good: good, easy: back(.easy, days: easyDays))
    }

    // MARK: Intervals

    func clampInterval(_ days: Double, min lower: Int) -> Int {
        let maximum = maximumInterval
        let minimum = Swift.min(Swift.max(1, lower), maximum)
        return Swift.min(maximum, Swift.max(minimum, Int(days.isFinite ? days : 1)))
    }

    /// Anki's review fuzz: a deterministic pick within ±5–15% of the interval.
    func fuzzed(_ interval: Double, min lower: Int) -> Int {
        let maximum = maximumInterval
        let minimum = Swift.min(Swift.max(1, lower), maximum)
        let ivl = Swift.min(Double(maximum), Swift.max(Double(minimum), interval.isFinite ? interval : 1))
        guard let f = fuzzFactor else { return Swift.min(maximum, Swift.max(minimum, Int(ivl.rounded()))) }
        var (lo, hi) = StateContext.fuzzBounds(ivl)
        lo = Swift.min(maximum, Swift.max(minimum, lo))
        hi = Swift.min(maximum, Swift.max(minimum, hi))
        if hi == lo, hi > 2, hi < maximum { hi = lo + 1 }
        return Int((Double(lo) + f * Double(1 + hi - lo)).rounded(.down))
    }

    static func fuzzBounds(_ interval: Double) -> (Int, Int) {
        guard interval >= 2.5 else { return (Int(interval.rounded()), Int(interval.rounded())) }
        var delta = 1.0
        for (start, end, factor) in [(2.5, 7.0, 0.15), (7.0, 20.0, 0.1), (20.0, Double.greatestFiniteMagnitude, 0.05)] {
            delta += factor * Swift.max(0, Swift.min(interval, end) - start)
        }
        return (Int((interval - delta).rounded()), Int((interval + delta).rounded()))
    }
}

/// Deterministic per-card randomness (seeded by card id and reps, like Anki).
struct SplitMix64 {
    var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}

public enum IntervalFormat {
    /// Short labels like Anki's answer buttons: "<1m", "10m", "4d", "1.5mo", "2.1y".
    public static func short(secs: Int) -> String {
        let s = Double(secs)
        if secs < 60 { return "<1m" }
        if s < 3600 { return "\(Int((s / 60).rounded()))m" }
        if s < 86400 { return trim(s / 3600) + "h" }
        if s < 86400 * 30 { return "\(Int((s / 86400).rounded()))d" }
        if s < 86400 * 365 { return trim(s / 86400 / 30) + "mo" }
        return trim(s / 86400 / 365) + "y"
    }

    public static func days(_ d: Int) -> String { short(secs: d * 86400) }

    private static func trim(_ v: Double) -> String {
        let r = (v * 10).rounded() / 10
        return r == r.rounded() ? String(Int(r)) : String(format: "%.1f", r)
    }
}
