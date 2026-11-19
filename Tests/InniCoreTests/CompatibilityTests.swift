import Foundation
@testable import InniCore
import XCTest

/// Compares InniCore with the official Anki backend. Fixtures come from `scripts/oracle.py`;
/// set INNI_ORACLE to their folder (default /tmp/inni-ref/oracle). Skipped when absent.
final class CompatibilityTests: XCTestCase {
    struct Oracle: Decodable {
        struct Rendered: Decodable { let cid: Int; let q: String; let a: String }
        struct Memory: Decodable { let cid: Int; let s: Double; let d: Double }
        struct States: Decodable { let cid: Int; let again: Int; let hard: Int; let good: Int; let easy: Int }
        let counts: [String: [Int]]
        let rendered: [Rendered]
        let memory: [Memory]
        let states: [States]
        let today: Int
        let fsrs: Bool
    }

    var dir: URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["INNI_ORACLE"] ?? "/tmp/inni-ref/oracle") }

    func load() throws -> (Oracle, Collection) {
        let json = dir.appendingPathComponent("oracle.json")
        guard FileManager.default.fileExists(atPath: json.path) else { throw XCTSkip("no oracle fixtures") }
        let oracle = try JSONDecoder().decode(Oracle.self, from: Data(contentsOf: json))
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("inni-compat-\(UUID().uuidString).anki2")
        try FileManager.default.copyItem(at: dir.appendingPathComponent("inni.anki2"), to: tmp)
        return (oracle, try Collection(url: tmp))
    }

    func testDeckCounts() throws {
        let (oracle, col) = try load()
        defer { col.close() }
        XCTAssertEqual(col.today, oracle.today)
        var mine: [String: [Int]] = [:]
        func walk(_ nodes: [DeckNode]) {
            for n in nodes {
                mine[String(n.id)] = [n.counts.new, n.counts.learning, n.counts.review]
                walk(n.children)
            }
        }
        walk(col.deckTree())
        for (id, expected) in oracle.counts where mine[id] != nil {
            XCTAssertEqual(mine[id], expected, "deck \(col.decks[Int(id)!]?.name ?? id)")
        }
    }

    private func normalize(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "\\[anki:play:[qa]:\\d+\\]", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\[\\[type:[^\\]]+\\]\\]", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "<a class=\"replay-button.*?</a>", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "<center><input type=\"text\" id=\"typeans\".*?</center>", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: CardRenderer.typeMarker, with: "")
        return HTML.strip(t).components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    func testRendering() throws {
        let (oracle, col) = try load()
        defer { col.close() }
        var exact = 0, mismatches: [String] = []
        for r in oracle.rendered {
            guard let card = col.card(r.cid), let note = col.note(card.noteID) else { continue }
            let out = CardRenderer.render(card, note: note, in: col)
            if out.question == r.q { exact += 1 }
            if normalize(out.question) != normalize(r.q) { mismatches.append("Q \(r.cid):\n  anki: \(normalize(r.q).prefix(160))\n  inni: \(normalize(out.question).prefix(160))") }
            if normalize(out.answer) != normalize(r.a) { mismatches.append("A \(r.cid):\n  anki: \(normalize(r.a).prefix(160))\n  inni: \(normalize(out.answer).prefix(160))") }
        }
        print("rendering: \(exact)/\(oracle.rendered.count) questions byte-identical, \(mismatches.count) text mismatches")
        XCTAssertTrue(mismatches.isEmpty, mismatches.prefix(8).joined(separator: "\n"))
    }

    func testFSRSMemory() throws {
        let (oracle, col) = try load()
        defer { col.close() }
        let sched = Scheduler(col: col, deckID: 1)
        var worstS = 0.0, worstD = 0.0
        for m in oracle.memory {
            guard let card = col.card(m.cid), let deck = col.decks[card.homeDeckID] else { continue }
            let fsrs = FSRS(params: col.config(for: deck).fsrsParams)
            guard let mine = fsrs.memory(from: col.revlog(for: m.cid), day: { sched.dayOf($0.id / 1000) }) else {
                XCTFail("no memory for \(m.cid)")
                continue
            }
            worstS = max(worstS, abs(mine.stability - m.s) / m.s)
            worstD = max(worstD, abs(mine.difficulty - m.d))
            XCTAssertEqual(mine.stability, m.s, accuracy: m.s * 0.01, "stability of \(m.cid)")
            XCTAssertEqual(mine.difficulty, m.d, accuracy: 0.02, "difficulty of \(m.cid)")
        }
        print("fsrs: \(oracle.memory.count) cards, worst stability error \(String(format: "%.4f", worstS * 100))%, worst difficulty error \(String(format: "%.4f", worstD))")
    }

    func testSchedulingStates() throws {
        let (oracle, col) = try load()
        defer { col.close() }
        let sched = Scheduler(col: col, deckID: 1)
        var checked = 0
        for s in oracle.states {
            guard let card = col.card(s.cid) else { continue }
            let n = sched.nextStates(for: card)
            for (r, expected) in [(Rating.again, s.again), (.hard, s.hard), (.good, s.good), (.easy, s.easy)] {
                let mine = n.state(for: r).delaySecs
                if expected >= 86400, mine >= 86400 {
                    let days = Double(expected / 86400)
                    let (lo, hi) = StateContext.fuzzBounds(days)
                    let slack = max(1, hi - lo)
                    XCTAssertLessThanOrEqual(abs(mine / 86400 - expected / 86400), slack, "\(r) of card \(s.cid) (type \(card.type))")
                } else {
                    XCTAssertEqual(mine, expected, "\(r) of card \(s.cid) (type \(card.type), left \(card.left))")
                }
            }
            checked += 1
        }
        print("scheduling: checked \(checked) cards")
    }

    /// Cards in every state (review, lapse, relearning, learning) under SM-2 and FSRS.
    func testSyntheticSchedulingStates() throws {
        for name in ["synthetic-sm2.anki2", "synthetic-fsrs.anki2"] {
            let src = dir.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: src.path) else { throw XCTSkip("no \(name)") }
            struct File: Decodable { let states: [Oracle.States] }
            let expected = try JSONDecoder().decode(File.self, from: Data(contentsOf: URL(fileURLWithPath: src.path + ".json")))
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("inni-syn-\(UUID().uuidString).anki2")
            try FileManager.default.copyItem(at: src, to: tmp)
            let col = try Collection(url: tmp)
            defer { col.close() }
            let sched = Scheduler(col: col, deckID: 1)
            var exactDays = 0, total = 0, failures: [String] = []
            for s in expected.states {
                let card = try XCTUnwrap(col.card(s.cid))
                let n = sched.nextStates(for: card)
                for (r, want) in [(Rating.again, s.again), (.hard, s.hard), (.good, s.good), (.easy, s.easy)] {
                    let got = n.state(for: r).delaySecs
                    total += 1
                    if want >= 86400 || got >= 86400 {
                        let (lo, hi) = StateContext.fuzzBounds(Double(want / 86400))
                        if got == want { exactDays += 1 }
                        // Different fuzz picks cascade (good must exceed hard), so allow the range plus that shift.
                        if abs(got / 86400 - want / 86400) > max(1, hi - lo) + (r == .again ? 0 : 2) {
                            failures.append("\(r) type=\(card.type) ivl=\(card.interval) factor=\(card.factor) due=\(card.due) left=\(card.left): anki \(want / 86400)d inni \(got / 86400)d")
                        }
                    } else if got != want {
                        failures.append("\(r) type=\(card.type) left=\(card.left): anki \(want)s inni \(got)s")
                    }
                }
            }
            print("\(name): \(total - failures.count)/\(total) within fuzz, \(exactDays) exact day matches")
            // Anki's load balancer moves FSRS picks by due-day workload, which Inni doesn't model yet.
            let allowed = name.contains("fsrs") ? total / 100 : 0
            XCTAssertLessThanOrEqual(failures.count, allowed, "\(name):\n" + failures.prefix(12).joined(separator: "\n"))
        }
    }

    func testImportsAnkiPackages() throws {
        for name in ["latest.apkg", "legacy.apkg"] {
            let pkg = dir.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: pkg.path) else { throw XCTSkip("no \(name)") }
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("inni-import-\(UUID().uuidString)/collection.anki2")
            let col = try Collection.create(at: tmp)
            let before = col.noteCount()
            let started = Date()
            let result = try col.importPackage(pkg)
            print("\(name): import took \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
            XCTAssertGreaterThan(result.notesAdded, 0, name)
            XCTAssertEqual(col.noteCount(), before + result.notesAdded)
            // Every imported card renders and belongs to an existing deck.
            for id in try col.findCards("") {
                let c = try XCTUnwrap(col.card(id))
                XCTAssertNotNil(col.decks[c.deckID])
                let r = CardRenderer.render(c, note: try XCTUnwrap(col.note(c.noteID)), in: col)
                XCTAssertFalse(r.question.contains("inni-error"), "\(name) card \(id): \(r.question.prefix(200))")
            }
            let again = try col.importPackage(pkg)
            XCTAssertEqual(again.notesAdded, 0, "re-import of \(name) should add nothing")
            print("\(name): \(result.summary)")
            col.close()
        }
    }
}
