import Foundation
import XCTest
@testable import InniCore

/// End-to-end sync against Anki's own sync server, with Anki's backend as the other device.
/// Needs `python -m anki.syncserver` running (SYNC_USER1=test:pass) and:
///   INNI_SYNC_SERVER=http://127.0.0.1:27701/  ANKI_PY=/path/to/python-with-anki
final class SyncTests: XCTestCase {
    var server: URL!
    var python = ""
    var dir: URL!

    override func setUpWithError() throws {
        guard let s = ProcessInfo.processInfo.environment["INNI_SYNC_SERVER"], let url = URL(string: s) else {
            throw XCTSkip("set INNI_SYNC_SERVER to run sync tests")
        }
        server = url
        python = ProcessInfo.processInfo.environment["ANKI_PY"] ?? "python3"
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("inni-sync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("peer"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("inni"), withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    /// Runs a step of scripts/sync_peer.py and returns the state it prints.
    func peer(_ step: String) throws -> [String: Any] {
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("scripts/sync_peer.py")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = [python, script.path, step, dir.appendingPathComponent("peer/collection.anki2").path]
        p.environment = ProcessInfo.processInfo.environment.merging(["INNI_SYNC_SERVER": server.absoluteString]) { $1 }
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errText = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw CollectionError("peer \(step) failed: \(errText)") }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func fronts(_ col: Collection) throws -> [String] {
        let basic = try XCTUnwrap(col.notetype(named: "Basic"))
        return try col.db.prepare("select flds from notes where mid = ?").bind([basic.id])
            .map { $0.text(0).components(separatedBy: "\u{1f}")[0] }.sorted()
    }

    /// INNI_SYNC_LARGE=/path/collection.anki2: full upload of a big collection, Anki downloads it,
    /// then a normal sync carrying over a thousand changed objects each way.
    func testLargeCollection() async throws {
        guard let src = ProcessInfo.processInfo.environment["INNI_SYNC_LARGE"], !src.isEmpty else { throw XCTSkip("set INNI_SYNC_LARGE") }
        let url = dir.appendingPathComponent("inni/collection.anki2")
        for suffix in ["", "-wal"] where FileManager.default.fileExists(atPath: src + suffix) {
            try FileManager.default.copyItem(atPath: src + suffix, toPath: url.path + suffix)
        }
        let col = try Collection(url: url)
        defer { col.close() }
        var auth = try await AnkiWeb.login(username: "test", password: "pass", endpoint: server)
        var t = Date()
        auth = try await col.fullUpload(auth: auth)
        print("full upload of \(col.noteCount()) notes: \(String(format: "%.2f", Date().timeIntervalSince(t))) s")
        let downloaded = try peer("check")
        XCTAssertEqual(downloaded["synced"] as? String, "download")
        XCTAssertEqual(downloaded["notes"] as? Int, col.noteCount())
        XCTAssertEqual(downloaded["cards"] as? Int, col.cardCount())
        // Cards reviewed before Anki tracked last review times get one added by Check Database; that's in the source too.
        let ignorable = { (p: Any?) in (p as? [String] ?? []).filter { !$0.contains("last review time") } }
        XCTAssertEqual(ignorable(downloaded["problems"]), [])

        let ids = try col.db.prepare("select id from cards order by id limit 1200").map { $0.integer(0) }
        try col.suspend(ids)
        let nids = try col.db.prepare("select id from notes order by id limit 300").map { $0.integer(0) }
        try col.addTags(["synced-in-bulk"], to: nids)
        t = Date()
        let out = try await col.sync(auth: auth)
        XCTAssertEqual(out.status, .synced)
        print("normal sync of 1500 changes: \(String(format: "%.2f", Date().timeIntervalSince(t))) s")
        let checked = try peer("check")
        XCTAssertTrue((checked["tags"] as? [String] ?? []).contains("synced-in-bulk"))
        XCTAssertEqual(ignorable(checked["problems"]), [])
    }

    func testSyncWithAnki() async throws {
        let seeded = try peer("seed")
        XCTAssertEqual(seeded["synced"] as? String, "upload")

        // A fresh Inni collection: only a download makes sense.
        let url = dir.appendingPathComponent("inni/collection.anki2")
        var auth = try await AnkiWeb.login(username: "test", password: "pass", endpoint: server)
        var col = try Collection.create(at: url)
        let first = try await col.sync(auth: auth)
        XCTAssertEqual(first.status, .fullSyncRequired(uploadOK: false, downloadOK: true))
        col.close()
        auth = try await Collection.fullDownload(auth: auth, replacing: url)
        col = try Collection(url: url)
        XCTAssertEqual(col.noteCount(), 4)
        XCTAssertEqual(col.cardCount(), 5)
        XCTAssertNotNil(col.deck(named: "Peer::Sub"))
        XCTAssertEqual(col.config(for: col.decks[1]!).config.floats(6).count, 21)
        try await MediaSync(collectionURL: url, auth: auth).sync()
        XCTAssertTrue(FileManager.default.fileExists(atPath: col.mediaFolder.appendingPathComponent("peer.png").path))
        let none = try await col.sync(auth: auth)
        XCTAssertEqual(none.status, .noChanges)

        // Local changes of every kind, then a normal sync.
        let basic = try XCTUnwrap(col.notetype(named: "Basic"))
        var n = Note(notetypeID: basic.id, fields: ["from inni", "back"])
        n.tags = ["inni"]
        try col.add(n, deckID: try XCTUnwrap(col.deckID(named: "Inni Deck")))
        let s = Scheduler(col: col, deckID: try XCTUnwrap(col.deck(named: "Peer"))?.id ?? 1)
        if let c = s.next() { _ = try s.answer(c, rating: .good, millis: 2000) }
        let p0 = try col.db.scalar("select id from notes where flds like 'peer 0%'")
        try col.remove(notes: [try XCTUnwrap(p0)])
        var styled = try XCTUnwrap(col.notetype(named: "Basic"))
        styled.css += "\n.inni { color: red; }"
        try col.save(styled)
        try Data("inni media".utf8).write(to: col.mediaFolder.appendingPathComponent("inni.txt"))
        let second = try await col.sync(auth: auth)
        XCTAssertEqual(second.status, .synced)
        try await MediaSync(collectionURL: url, auth: auth).sync()

        let checked = try peer("check")
        XCTAssertEqual(checked["synced"] as? String, "NO_CHANGES", "a finished normal sync leaves nothing required")
        XCTAssertEqual(checked["notes"] as? Int, 4)
        XCTAssertEqual(checked["fronts"] as? [String], ["from inni", "peer 1", "peer 2"])
        XCTAssertEqual(checked["revlog"] as? Int, 2)
        XCTAssertTrue((checked["decks"] as? [String] ?? []).contains("Inni Deck"))
        XCTAssertTrue((checked["tags"] as? [String] ?? []).contains("inni"))
        XCTAssertTrue((checked["basicCss"] as? String ?? "").contains(".inni { color: red; }"))
        XCTAssertTrue((checked["media"] as? [String] ?? []).contains("inni.txt"))
        XCTAssertEqual(checked["problems"] as? [String], [])

        // Changes made in Anki come back.
        let modified = try peer("modify")
        XCTAssertEqual(modified["synced"] as? String, "NO_CHANGES")
        let third = try await col.sync(auth: auth)
        XCTAssertEqual(third.status, .synced)
        try await MediaSync(collectionURL: url, auth: auth).sync()
        XCTAssertEqual(try fronts(col), ["from anki", "from inni", "peer 1 edited"])
        XCTAssertNotNil(col.deck(named: "Peer::Renamed"))
        XCTAssertNil(col.deck(named: "Peer::Sub"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: col.mediaFolder.appendingPathComponent("anki.txt").path))
        let settled = try await col.sync(auth: auth)
        XCTAssertEqual(settled.status, .noChanges)

        // A schema change forces a one-way sync; upload it and Anki downloads.
        var widened = try XCTUnwrap(col.notetype(named: "Basic"))
        widened.fields.append(Notetype.Field(ord: -1, name: "Extra"))
        try col.save(widened)
        let fourth = try await col.sync(auth: auth)
        XCTAssertEqual(fourth.status, .fullSyncRequired(uploadOK: true, downloadOK: true))
        auth = try await col.fullUpload(auth: auth)
        let afterUpload = try await col.sync(auth: auth)
        XCTAssertEqual(afterUpload.status, .noChanges)
        let downloaded = try peer("check")
        XCTAssertEqual(downloaded["synced"] as? String, "download")
        XCTAssertEqual(downloaded["basicFields"] as? [String], ["Front", "Back", "Extra"])
        XCTAssertEqual(downloaded["notes"] as? Int, 4)
        XCTAssertEqual(downloaded["problems"] as? [String], [])
        col.close()
    }
}

/// The HTTP client on its own, against a throwaway Python server.
final class SyncHTTPTests: XCTestCase {
    func testClientThatSentNothingIsReleasedSafely() async throws {
        for _ in 0..<20 { _ = SyncHTTP(auth: SyncAuth(hostKey: "k")) }
        try await Task.sleep(for: .milliseconds(300))
    }

    func testRedirectMovesTheEndpoint() async throws {
        let port = Int.random(in: 30000...39999)
        let script = """
            import http.server, json, time
            class H(http.server.BaseHTTPRequestHandler):
                def do_POST(self):
                    self.rfile.read(int(self.headers.get("content-length") or 0))
                    if not self.path.startswith("/shard/"):
                        self.send_response(308); self.send_header("Location", "http://127.0.0.1:\(port)/shard/"); self.end_headers(); return
                    body = json.dumps({"mod": 5, "scm": 1, "usn": 2, "ts": int(time.time()), "empty": False, "cont": True}).encode()
                    self.send_response(200); self.end_headers(); self.wfile.write(body)
                def log_message(self, *a): pass
            http.server.HTTPServer(("127.0.0.1", \(port)), H).serve_forever()
            """
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        server.arguments = ["python3", "-c", script]
        try server.run()
        defer { server.terminate() }
        try await Task.sleep(for: .milliseconds(800))

        let http = SyncHTTP(auth: SyncAuth(hostKey: "k", endpoint: URL(string: "http://127.0.0.1:\(port)/")!))
        let meta = try await Collection.remoteSyncMeta(http)
        XCTAssertEqual(meta.modified, 5)
        XCTAssertEqual(http.endpoint.absoluteString, "http://127.0.0.1:\(port)/shard/")
    }
}
