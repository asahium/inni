import Foundation
@testable import InniCore
import XCTest

final class CollectionTests: XCTestCase {
    func newCollection() throws -> Collection {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("inni-test-\(UUID().uuidString)/collection.anki2")
        return try Collection.create(at: url)
    }

    func testTemplates() {
        let t = Template.parse("{{#Back}}B: {{Back}}{{/Back}}{{^Extra}} no extra{{/Extra}} {{text:Front}} {{=<% %>=}}<%Front%>")
        let out = t.render(.init(fields: ["Front": "<b>F</b>", "Back": "x", "Extra": ""], cardOrdinal: 1, question: true))
        XCTAssertEqual(out, "B: x no extra F <b>F</b>")
        XCTAssertTrue(Template.parse("{{#Add Reverse}}{{Back}}{{/Add Reverse}}").rendersWith(["Back"]) == false)
        XCTAssertTrue(Template.parse("{{#Add Reverse}}{{Back}}{{/Add Reverse}}").rendersWith(["Back", "Add Reverse"]))
    }

    func testCloze() {
        let s = "{{c1::Paris::city}} is in {{c2::France}}, {{c1::nested {{c3::deep}}}}"
        XCTAssertEqual(Cloze.ordinals(in: s), [1, 2, 3])
        let q1 = Cloze.render(s, ordinal: 1, question: true)
        XCTAssertTrue(q1.contains(">[city]</span>"))
        XCTAssertTrue(q1.contains("<span class=\"cloze-inactive\" data-ordinal=\"2\">France</span>"))
        let a3 = Cloze.render(s, ordinal: 3, question: false)
        XCTAssertTrue(a3.contains("<span class=\"cloze\" data-ordinal=\"3\">deep</span>"))
        XCTAssertEqual(Cloze.activeText(s, ordinal: 1), "Paris, nested deep")
        XCTAssertEqual(Cloze.ordinals(in: "{{c1,2::both}}"), [1, 2])
    }

    func testSearch() throws {
        let col = try newCollection()
        let basic = try XCTUnwrap(col.notetype(named: "Basic"))
        let did = try XCTUnwrap(col.deckID(named: "Lang::French"))
        try col.add(Note(notetypeID: basic.id, tags: ["verb", "lang::fr"], fields: ["manger", "to eat"]), deckID: did)
        try col.add(Note(notetypeID: basic.id, tags: ["noun"], fields: ["pomme", "apple"]), deckID: did)
        try col.add(Note(notetypeID: basic.id, fields: ["Hund", "dog"]), deckID: 1)
        XCTAssertEqual(try col.findCards("deck:Lang").count, 2)
        XCTAssertEqual(try col.findCards("tag:verb").count, 1)
        XCTAssertEqual(try col.findCards("tag:lang").count, 1)
        XCTAssertEqual(try col.findCards("-tag:verb deck:Lang").count, 1)
        XCTAssertEqual(try col.findCards("back:apple").count, 1)
        XCTAssertEqual(try col.findCards("back:app*").count, 1)
        XCTAssertEqual(try col.findCards("dog or apple").count, 2)
        XCTAssertEqual(try col.findCards("(dog or apple) -deck:Lang").count, 1)
        XCTAssertEqual(try col.findCards("is:new").count, 3)
        XCTAssertEqual(try col.findCards("\"to eat\"").count, 1)
        XCTAssertEqual(try col.findCards("re:^pom").count, 1)
        XCTAssertEqual(try col.findCards("note:Basic card:1").count, 3)
    }

    func testStudyFlowAndUndo() throws {
        let col = try newCollection()
        let basic = try XCTUnwrap(col.notetype(named: "Basic (and reversed card)"))
        for i in 0..<5 { try col.add(Note(notetypeID: basic.id, fields: ["front \(i)", "back \(i)"]), deckID: 1) }
        XCTAssertEqual(col.cardCount(), 10)
        let tree = col.deckTree()
        XCTAssertEqual(tree.first?.counts.new, 10)

        let s = Scheduler(col: col, deckID: 1)
        XCTAssertEqual(s.counts.new, 10)
        let first = try XCTUnwrap(s.next())
        XCTAssertEqual(s.intervalLabels(for: first)[.again], "1m")
        XCTAssertEqual(s.intervalLabels(for: first)[.good], "10m")
        // Easy graduates at 4 days, fuzzed by Anki's rules to 3–5.
        XCTAssertTrue(["3d", "4d", "5d"].contains(s.intervalLabels(for: first)[.easy] ?? ""))
        let answered = try s.answer(first, rating: .good, millis: 3000)
        XCTAssertEqual(answered.type, .learning)
        XCTAssertEqual(answered.queue, .learning)
        XCTAssertEqual(col.revlog(for: first.id).count, 1)
        XCTAssertEqual(s.counts.learning, 1)
        XCTAssertEqual(col.decks[1]?.studied(today: col.today).new, 1)

        try s.undo()
        XCTAssertEqual(col.card(first.id)?.type, .new)
        XCTAssertEqual(col.revlog(for: first.id).count, 0)
        XCTAssertEqual(col.decks[1]?.studied(today: col.today).new, 0)

        let easy = try s.answer(try XCTUnwrap(s.next()), rating: .easy, millis: 1000)
        XCTAssertEqual(easy.type, .review)
        XCTAssertTrue((3...5).contains(easy.interval))
    }

    func testFSRSAnswer() throws {
        let col = try newCollection()
        try col.setConfig("fsrs", true)
        let basic = try XCTUnwrap(col.notetype(named: "Basic"))
        try col.add(Note(notetypeID: basic.id, fields: ["q", "a"]), deckID: 1)
        let s = Scheduler(col: col, deckID: 1)
        let c = try s.answer(try XCTUnwrap(s.next()), rating: .easy, millis: 1000)
        XCTAssertEqual(c.type, .review)
        XCTAssertEqual(c.data.stability ?? 0, FSRS.defaultParams[3], accuracy: 0.001)
        XCTAssertNotNil(c.data.difficulty)
        XCTAssertTrue(c.data.json.contains("\"s\""))
    }

    func testNotetypeEditKeepsNotes() throws {
        let col = try newCollection()
        var nt = try XCTUnwrap(col.notetype(named: "Basic"))
        let n = try col.add(Note(notetypeID: nt.id, fields: ["one", "two"]), deckID: 1)
        nt.fields.insert(Notetype.Field(ord: -1, name: "Extra"), at: 1)
        nt.templates.append(Notetype.Template(ord: -1, name: "Card 2", front: "{{Back}}", back: "{{Front}}"))
        nt = try col.save(nt)
        XCTAssertEqual(col.note(n.id)?.fields, ["one", "", "two"])
        XCTAssertEqual(col.cards(ofNote: n.id).count, 2)

        // Rename and reorder: content follows the field, not the name.
        nt.fields[0].name = "Question"
        nt.fields.swapAt(1, 2)
        nt.templates[0].front = "{{Question}}"
        nt = try col.save(nt)
        XCTAssertEqual(col.note(n.id)?.fields, ["one", "two", ""])

        // Removing the first card type keeps the second one's cards, renumbered.
        let second = try XCTUnwrap(col.cards(ofNote: n.id).first { $0.ord == 1 })
        nt.templates.remove(at: 0)
        try col.save(nt)
        let left = col.cards(ofNote: n.id)
        XCTAssertEqual(left.map(\.id), [second.id])
        XCTAssertEqual(left.first?.ord, 0)
    }

    /// Writes files for scripts/verify_with_anki.py.
    func testWriteForAnki() throws {
        let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["INNI_OUT"] ?? "/tmp/inni-ref/out")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let col = try Collection.create(at: out.appendingPathComponent("collection.anki2"))
        let did = try XCTUnwrap(col.deckID(named: "Inni::Sub deck"))
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: col.mediaFolder.appendingPathComponent("pic.png"))
        for nt in col.sortedNotetypes {
            var fields = nt.fields.map { "\(nt.name) \($0.name)" }
            if nt.isCloze { fields[0] = "{{c1::Paris}} is in {{c2::France}} <img src=\"pic.png\">" }
            if nt.name.contains("optional") { fields[2] = "y" }
            try col.add(Note(notetypeID: nt.id, tags: ["inni", "test::nested"], fields: fields), deckID: did)
        }
        let s = Scheduler(col: col, deckID: did)
        var ratings: [Rating] = [.good, .easy, .again, .hard, .good]
        while let c = s.next(), !ratings.isEmpty { try s.answer(c, rating: ratings.removeFirst(), millis: 2500) }
        var renamed = try XCTUnwrap(col.decks[did])
        renamed.name = "Inni::Renamed"
        try col.save(renamed)
        try col.exportCollectionPackage(to: out.appendingPathComponent("inni.colpkg"))
        try col.exportDeckPackage(col.deck(named: "Inni")?.id, to: out.appendingPathComponent("inni.apkg"), includeScheduling: false)
        try col.exportDeckPackage(col.deck(named: "Inni")?.id, to: out.appendingPathComponent("inni-sched.apkg"), includeScheduling: true)
        let info: [String: Int] = ["notes": col.noteCount(), "cards": col.cardCount(), "revlog": try col.db.scalar("select count() from revlog") ?? 0]
        try JSONSerialization.data(withJSONObject: info).write(to: out.appendingPathComponent("expected.json"))
        col.close()
    }
}
