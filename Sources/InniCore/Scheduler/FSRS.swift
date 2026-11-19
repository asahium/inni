import Foundation

/// FSRS-6, matching fsrs-rs as used by Anki. Older 17/19-parameter sets are padded to FSRS-6.
public struct FSRS: Sendable {
    public static let defaultParams: [Double] = [
        0.212, 1.2931, 2.3065, 8.2956, 6.4133, 0.8334, 3.0194, 0.001, 1.8722, 0.1666, 0.796, 1.4835,
        0.0614, 0.2629, 1.6483, 0.6014, 1.8729, 0.5425, 0.0912, 0.0658, 0.1542,
    ]
    static let sMin = 0.001, sMax = 36500.0

    public let w: [Double]

    public init(params: [Float]) {
        var p = params.map(Double.init)
        switch p.count {
        case 21: break
        case 19: p += [0.0, 0.5]
        case 17: p += [0.0, 0.0, 0.0, 0.5]
        default: p = FSRS.defaultParams
        }
        w = p
    }

    public var decay: Double { -w[20] }
    var factor: Double { pow(0.9, 1 / decay) - 1 }

    public func retrievability(days t: Double, stability s: Double) -> Double {
        pow(1 + factor * max(0, t) / s, decay)
    }

    func initStability(_ rating: Int) -> Double { max(FSRS.sMin, w[rating - 1]) }

    func rawInitDifficulty(_ rating: Int) -> Double { w[4] - exp(w[5] * Double(rating - 1)) + 1 }

    func initDifficulty(_ rating: Int) -> Double { clampD(rawInitDifficulty(rating)) }

    func clampD(_ d: Double) -> Double { min(10, max(1, d)) }

    func nextDifficulty(_ d: Double, _ rating: Int) -> Double {
        let delta = -w[6] * Double(rating - 3)
        let damped = d + delta * (10 - d) / 9
        return clampD(w[7] * rawInitDifficulty(4) + (1 - w[7]) * damped)
    }

    func stabilityAfterSuccess(_ s: Double, _ d: Double, _ r: Double, _ rating: Int) -> Double {
        let hard = rating == 2 ? w[15] : 1
        let easy = rating == 4 ? w[16] : 1
        return s * (exp(w[8]) * (11 - d) * pow(s, -w[9]) * (exp((1 - r) * w[10]) - 1) * hard * easy + 1)
    }

    func stabilityAfterFailure(_ s: Double, _ d: Double, _ r: Double) -> Double {
        let newS = w[11] * pow(d, -w[12]) * (pow(s + 1, w[13]) - 1) * exp((1 - r) * w[14])
        return min(newS, s / exp(w[17] * w[18]))
    }

    func stabilityShortTerm(_ s: Double, _ rating: Int) -> Double {
        var inc = exp(w[17] * (Double(rating - 3) + w[18])) * pow(s, -w[19])
        if rating >= 2 { inc = max(inc, 1) }
        return s * inc
    }

    /// Memory after answering `rating` (1–4) `days` after the previous review.
    public func next(_ memory: MemoryState?, days: Double, rating: Int) -> MemoryState {
        guard let m = memory else {
            return MemoryState(stability: initStability(rating), difficulty: initDifficulty(rating))
        }
        let s: Double
        if days <= 0 {
            s = stabilityShortTerm(m.stability, rating)
        } else {
            let r = retrievability(days: days, stability: m.stability)
            s = rating == 1 ? stabilityAfterFailure(m.stability, m.difficulty, r) : stabilityAfterSuccess(m.stability, m.difficulty, r, rating)
        }
        return MemoryState(stability: min(FSRS.sMax, max(FSRS.sMin, s)), difficulty: nextDifficulty(m.difficulty, rating))
    }

    /// Days until retrievability falls to `retention`, unrounded.
    public func interval(stability s: Double, retention: Double) -> Double {
        s / factor * (pow(retention, 1 / decay) - 1)
    }

    /// Estimates memory for a card reviewed only with SM-2 (no usable history).
    public func memoryFromSM2(ease: Double, interval: Double, retention sm2Retention: Double = 0.9) -> MemoryState {
        let s = max(FSRS.sMin, interval) * factor / (pow(sm2Retention, 1 / decay) - 1)
        let d = 11 - (ease - 1) / (exp(w[8]) * pow(s, -w[9]) * (exp((1 - sm2Retention) * w[10]) - 1))
        return MemoryState(stability: min(FSRS.sMax, max(FSRS.sMin, s)), difficulty: clampD(d))
    }

    /// Replays a card's review history. `days` gives the scheduler day of each review.
    public func memory(from revlog: [RevlogEntry], day: (RevlogEntry) -> Int) -> MemoryState? {
        var m: MemoryState?
        var lastDay: Int?
        // History before the last "Forget" doesn't count.
        let start = revlog.lastIndex { $0.kind == .manual && $0.ease == 0 && $0.interval == 0 }.map { $0 + 1 } ?? 0
        for e in revlog[start...] where (1...4).contains(e.ease) && e.kind != .manual && e.kind != .rescheduled {
            if e.kind == .filtered && e.interval == 0 { continue }
            let d = day(e)
            m = next(m, days: lastDay.map { Double(d - $0) } ?? 0, rating: e.ease)
            lastDay = d
        }
        return m
    }
}
