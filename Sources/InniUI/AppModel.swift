import Foundation
import InniCore
import Observation
import SwiftUI

/// App-wide state: the open collection, the deck tree and long-running jobs.
@MainActor @Observable
public final class AppModel {
    public private(set) var col: Collection?
    public private(set) var tree: [DeckNode] = []
    /// Bumped after every change so views re-read the collection.
    public private(set) var revision = 0
    public var error: String?
    public var message: String?
    public private(set) var busy: String?
    public var study: DeckID?
    public var editing: NoteID?
    public var adding = false
    /// The deck whose overview the main window shows (macOS).
    public var selectedDeck: DeckID?
    /// A page shown instead of the deck overview (macOS), or pushed (iOS).
    public var page: Page?
    /// A search the browser should run next, e.g. from a deck's "Browse".
    public var browserRequest: String?

    public enum Page: Hashable {
        case browse
        case stats
        case notetypes
        case settings
    }

    public var totals: DeckCounts {
        tree.reduce(DeckCounts()) { acc, n in
            DeckCounts(new: acc.new + n.counts.new, learning: acc.learning + n.counts.learning, review: acc.review + n.counts.review)
        }
    }

    public func node(_ id: DeckID?) -> DeckNode? {
        guard let id else { return nil }
        func find(_ nodes: [DeckNode]) -> DeckNode? {
            for n in nodes {
                if n.id == id { return n }
                if let f = find(n.children) { return f }
            }
            return nil
        }
        return find(tree)
    }

    // Sync
    var account: SyncAccount?
    public var syncUsername: String? { account?.username }
    public private(set) var syncing = false
    public private(set) var mediaSyncing = false
    /// Media sync stopped on a network error; it continues the next time the app becomes active.
    private var mediaSyncPending = false
    public var loginShown = false
    public var fullSyncChoice: FullSyncChoice?

    public struct FullSyncChoice: Identifiable {
        public let uploadOK: Bool, downloadOK: Bool
        public var id: String { "\(uploadOK)\(downloadOK)" }
    }

    public init() {
        account = SyncAccount.load()
        let last = UserDefaults.standard.string(forKey: "collectionPath").map { URL(fileURLWithPath: $0) }
        let url = last.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } ?? Self.defaultURL
        open(url, create: true)
        if account != nil, UserDefaults.standard.object(forKey: "syncOnOpen") as? Bool ?? true, !Self.isScreenshotRun {
            Task { await sync(quiet: true) }
        }
    }

    static var isScreenshotRun: Bool { UserDefaults.standard.string(forKey: "InniOpen") != nil }

    public static var defaultURL: URL {
        #if os(iOS)
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        #else
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Inni")
        #endif
        return base.appendingPathComponent("collection.anki2")
    }

    /// Anki's desktop profiles, which Inni can open directly while Anki is closed.
    public static var ankiProfiles: [URL] {
        #if os(macOS)
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Anki2")
        let dirs = (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? []
        return dirs.map { $0.appendingPathComponent("collection.anki2") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .sorted { $0.path < $1.path }
        #else
        return []
        #endif
    }

    public var collectionName: String {
        guard let url = col?.url else { return "Inni" }
        let parent = url.deletingLastPathComponent().lastPathComponent
        return url.path.contains("/Anki2/") ? "Anki · \(parent)" : "Inni"
    }

    // MARK: Collection lifecycle

    public func open(_ url: URL, create: Bool = false) {
        col?.close()
        col = nil
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: url.path) {
                col = try Collection(url: url)
            } else if create {
                col = try Collection.create(at: url)
            } else {
                throw CollectionError("No collection at \(url.path)")
            }
            UserDefaults.standard.set(url.path, forKey: "collectionPath")
            backupIfDue()
        } catch {
            self.error = error.localizedDescription
        }
        refresh()
    }

    public func close() {
        col?.close()
        col = nil
    }

    /// Re-reads after another process may have changed things (e.g. returning from background).
    public func reopen() {
        guard let url = col?.url else { return }
        open(url)
    }

    public func refresh() {
        tree = col?.deckTree() ?? []
        if node(selectedDeck) == nil {
            selectedDeck = col?.currentDeckID
            if node(selectedDeck) == nil { selectedDeck = tree.first?.id }
        }
        revision += 1
    }

    /// Runs a change and refreshes; errors become an alert.
    public func perform(_ body: (Collection) throws -> Void) {
        guard let col else { return }
        do { try body(col) } catch { self.error = error.localizedDescription }
        refresh()
    }

    // MARK: Backups

    var backupFolder: URL? { col?.url.deletingLastPathComponent().appendingPathComponent("backups") }

    /// One snapshot a day, keeping the last 14. Anki's own profiles are already backed up by Anki.
    func backupIfDue() {
        guard let col, let folder = backupFolder, !col.url.path.contains("/Anki2/") else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
        let dest = folder.appendingPathComponent("backup-\(stamp).anki2")
        guard !fm.fileExists(atPath: dest.path), col.noteCount() > 0 else { return }
        try? col.snapshot(to: dest)
        let old = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasPrefix("backup-") }.sorted().dropLast(14)
        for f in old { try? fm.removeItem(at: folder.appendingPathComponent(f)) }
    }

    // MARK: Import / export

    /// Imports `.apkg` (merge) or `.colpkg` (replace the whole collection).
    public func importFile(_ url: URL) async {
        guard let col else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        // Copy first: Files-app URLs can disappear while we read.
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
        do {
            try FileManager.default.copyItem(at: url, to: tmp)
        } catch {
            self.error = error.localizedDescription
            return
        }
        defer { try? FileManager.default.removeItem(at: tmp) }

        if url.pathExtension.lowercased() == "colpkg" {
            busy = "Restoring collection…"
            let dest = col.url
            close()
            let result = await Task.detached { Result { try AnkiPackage.replaceCollection(at: dest, with: tmp) } }.value
            busy = nil
            if case .failure(let e) = result { error = e.localizedDescription }
            open(dest)
            if case .success = result { message = "Collection restored from \(url.lastPathComponent)." }
            return
        }
        busy = "Importing \(url.lastPathComponent)…"
        // The UI shows a modal overlay and doesn't touch the collection until this returns.
        nonisolated(unsafe) let c = col
        let result = await Task.detached { Result { try c.importPackage(tmp) } }.value
        busy = nil
        switch result {
        case .success(let r): message = r.summary
        case .failure(let e): error = e.localizedDescription
        }
        try? col.reload()
        refresh()
    }

    public enum ExportKind: Hashable {
        case collection
        case deck(DeckID?, scheduling: Bool)
    }

    /// Writes a package to a temp file and returns its URL, for a save panel or share sheet.
    public func export(_ kind: ExportKind) async -> URL? {
        guard let col else { return nil }
        let name: String
        switch kind {
        case .collection: name = "collection-\(Self.stamp()).colpkg"
        case .deck(let id, _):
            let deck = id.flatMap { col.decks[$0]?.name } ?? "All Decks"
            name = deck.replacingOccurrences(of: "::", with: " - ").replacingOccurrences(of: "/", with: "-") + ".apkg"
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("inni-export-\(UUID().uuidString)")
        let url = dir.appendingPathComponent(name)
        busy = "Exporting…"
        defer { busy = nil }
        nonisolated(unsafe) let c = col
        let result = await Task.detached {
            Result {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                switch kind {
                case .collection: try c.exportCollectionPackage(to: url)
                case .deck(let id, let sched): try c.exportDeckPackage(id, to: url, includeScheduling: sched)
                }
            }
        }.value
        if case .failure(let e) = result {
            error = e.localizedDescription
            return nil
        }
        return url
    }

    static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd@HH-mm"
        return f.string(from: Date())
    }

    // MARK: Maintenance

    public func checkDatabase() {
        guard let col else { return }
        do {
            let problems = try col.checkDatabase()
            message = problems.isEmpty ? "No problems found." : problems.joined(separator: "\n")
        } catch {
            self.error = error.localizedDescription
        }
        refresh()
    }

    public func removeEmptyCards() {
        guard let col else { return }
        let ids = col.emptyCards()
        perform { try $0.remove(cards: ids) }
        message = ids.isEmpty ? "No empty cards." : "Deleted \(ids.count) empty cards."
    }

    // MARK: Sync

    /// Empty means AnkiWeb.
    public static var customSyncServer: URL? {
        let s = UserDefaults.standard.string(forKey: "syncServer")?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !s.isEmpty, var url = URL(string: s), url.scheme != nil else { return nil }
        if !url.absoluteString.hasSuffix("/") { url = URL(string: url.absoluteString + "/") ?? url }
        return url
    }

    public func login(username: String, password: String) async -> Bool {
        busy = "Logging in…"
        defer { busy = nil }
        do {
            let auth = try await AnkiWeb.login(username: username, password: password, endpoint: Self.customSyncServer)
            account = SyncAccount(username: username, auth: auth)
            account?.save()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    public func logout() {
        account = nil
        SyncAccount.delete()
    }

    private func store(_ auth: SyncAuth) {
        guard var a = account, a.auth != auth else { return }
        a.auth = auth
        account = a
        a.save()
    }

    /// A normal sync; asks which way to go when only a one-way sync can continue.
    /// `quiet` is for syncs the user didn't start: network failures are not reported.
    public func sync(quiet: Bool = false) async {
        guard let col, !syncing, busy == nil else { return }
        guard let auth = account?.auth else {
            loginShown = true
            return
        }
        syncing = true
        busy = "Syncing…"
        defer {
            syncing = false
            busy = nil
        }
        // The overlay keeps the UI off the collection until this returns.
        nonisolated(unsafe) let c = col
        let background = BackgroundTime("Sync")
        defer { background.end() }
        do {
            let out = try await c.sync(auth: auth)
            store(out.auth)
            refresh()
            if case .fullSyncRequired(let up, let down) = out.status {
                fullSyncChoice = FullSyncChoice(uploadOK: up, downloadOK: down)
                return
            }
            if !out.serverMessage.isEmpty { message = out.serverMessage }
            syncMedia(serverUSN: out.serverMediaUSN)
        } catch {
            handle(error, quiet: quiet)
        }
    }

    /// Picks up work a suspended app couldn't finish.
    public func becameActive() {
        refresh()
        if mediaSyncPending {
            mediaSyncPending = false
            syncMedia(serverUSN: nil)
        }
    }

    /// Replaces one side with the other. The local collection is backed up before a download.
    public func fullSync(upload: Bool) async {
        guard let col, let auth = account?.auth, busy == nil else { return }
        let url = col.url
        syncing = true
        busy = upload ? "Uploading to AnkiWeb…" : "Downloading from AnkiWeb…"
        defer {
            syncing = false
            busy = nil
        }
        nonisolated(unsafe) let c = col
        let background = BackgroundTime("Full sync")
        defer { background.end() }
        do {
            if upload {
                store(try await c.fullUpload(auth: auth))
                try? col.reload()
                refresh()
            } else {
                let folder = Self.defaultURL.deletingLastPathComponent().appendingPathComponent("backups")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try col.snapshot(to: folder.appendingPathComponent("before-download-\(Self.stamp()).anki2"))
                close()
                defer { open(url) }
                store(try await Collection.fullDownload(auth: auth, replacing: url))
            }
            syncMedia(serverUSN: nil)
        } catch {
            handle(error)
        }
    }

    private func syncMedia(serverUSN: Int?) {
        guard let url = col?.url, let auth = account?.auth, !mediaSyncing,
              UserDefaults.standard.object(forKey: "syncMedia") as? Bool ?? true else { return }
        mediaSyncing = true
        Task {
            let background = BackgroundTime("Media sync")
            defer {
                background.end()
                mediaSyncing = false
            }
            do {
                let media = try MediaSync(collectionURL: url, auth: auth)
                try await media.sync(serverUSN: serverUSN)
                revision += 1
            } catch {
                if SyncError.isNetwork(error) { mediaSyncPending = true }
                handle(error, quiet: true)
            }
        }
    }

    private func handle(_ error: Error, quiet: Bool = false) {
        if case SyncError.authFailed = error {
            logout()
            loginShown = true
        }
        if SyncError.isNetwork(error) {
            if !quiet { self.error = "Couldn't reach AnkiWeb: \(error.localizedDescription) Check the connection and sync again." }
            return
        }
        self.error = error.localizedDescription
    }

    public func requireFullSync() {
        perform { try $0.requireFullSync() }
        message = "The next sync will ask whether to upload or download the whole collection."
    }
}

/// Asks iOS to keep the app running for a while if it is sent to the background mid-sync. Does nothing on macOS.
@MainActor
final class BackgroundTime {
    #if os(iOS)
    private var id = UIBackgroundTaskIdentifier.invalid
    #endif

    init(_ name: String) {
        #if os(iOS)
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in self?.end() }
        #endif
    }

    func end() {
        #if os(iOS)
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
        #endif
    }
}
