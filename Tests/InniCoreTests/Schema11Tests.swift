import Foundation
import XCTest
@testable import InniCore

/// Every notetype, deck and preset Anki wrote must survive schema-18 → sync JSON → schema-18 unchanged.
final class Schema11Tests: XCTestCase {
    var collections: [URL] {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["INNI_ORACLE"] ?? "/tmp/inni-ref/oracle")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "anki2" }
    }

    /// Field 255 holds JSON whose key order is arbitrary, so compare it by content.
    func canonical(_ p: Proto) -> [String] {
        p.fields.map { f in
            if f.number == 255, case .bytes(let d) = f.value,
               let o = try? JSONSerialization.jsonObject(with: d),
               let sorted = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) {
                return "255:" + String(decoding: sorted, as: UTF8.self)
            }
            return "\(f.number):\(f.value)"
        }
    }

    /// Simulates the wire: through JSON text and back.
    func wire(_ o: [String: Any]) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: o)) as? [String: Any])
    }

    func testRoundTripsAnkiObjects() throws {
        let urls = collections
        guard !urls.isEmpty else { throw XCTSkip("no oracle collections") }
        var checked = 0
        for url in urls {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("s11-\(UUID().uuidString).anki2")
            for suffix in ["", "-wal"] where FileManager.default.fileExists(atPath: url.path + suffix) {
                try FileManager.default.copyItem(atPath: url.path + suffix, toPath: tmp.path + suffix)
            }
            defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: tmp.path + suffix) } }
            let col = try Collection(url: tmp)
            defer { col.close() }

            for nt in col.notetypes.values {
                let back = Schema11.notetype(try wire(Schema11.json(nt)))
                XCTAssertEqual(back.id, nt.id)
                XCTAssertEqual(back.name, nt.name)
                XCTAssertEqual(back.mtime, nt.mtime)
                XCTAssertEqual(canonical(back.config), canonical(nt.config), "notetype \(nt.name) in \(url.lastPathComponent)")
                XCTAssertEqual(back.fields.map(\.name), nt.fields.map(\.name))
                XCTAssertEqual(back.fields.map(\.ord), nt.fields.map(\.ord))
                for (a, b) in zip(back.fields, nt.fields) { XCTAssertEqual(canonical(a.config), canonical(b.config), "field \(b.name)") }
                XCTAssertEqual(back.templates.map(\.name), nt.templates.map(\.name))
                for (a, b) in zip(back.templates, nt.templates) { XCTAssertEqual(canonical(a.config), canonical(b.config), "template \(b.name)") }
                checked += 1
            }
            for d in col.decks.values {
                let back = Schema11.deck(try wire(Schema11.json(d)))
                XCTAssertEqual(back.id, d.id)
                XCTAssertEqual(back.name, d.name)
                XCTAssertEqual(back.mtime, d.mtime)
                XCTAssertEqual(canonical(back.common), canonical(d.common), "deck \(d.name) common")
                XCTAssertEqual(back.isFiltered, d.isFiltered)
                let n = d.isFiltered ? 2 : 1
                XCTAssertEqual(canonical(back.kind.message(n)), canonical(d.kind.message(n)), "deck \(d.name) kind")
                checked += 1
            }
            for c in col.deckConfigs.values {
                let back = Schema11.deckConfig(try wire(Schema11.json(c)))
                XCTAssertEqual(back.id, c.id)
                XCTAssertEqual(back.name, c.name)
                XCTAssertEqual(canonical(back.config), canonical(c.config), "preset \(c.name) in \(url.lastPathComponent)")
                checked += 1
            }
        }
        print("schema11 round trip: \(checked) objects from \(urls.count) collections")
    }
}
