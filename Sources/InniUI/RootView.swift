import InniCore
import SwiftUI
import UniformTypeIdentifiers

public struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var phase
    @State private var sheet: DeckSheet?
    @State private var importing = false
    @State private var path = NavigationPath()
    @State private var newDeck = false
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    @State private var columns = NavigationSplitViewVisibility.all
    #endif

    public init() {}

    typealias Page = AppModel.Page

    public var body: some View {
        main
            .sheet(item: $sheet) { s in
                NavigationStack {
                    switch s {
                    case .options(let d): DeckOptionsView(deckID: d)
                    case .add(let d): EditorView(mode: .add(d))
                    case .export(let d): ExportView(deckID: d)
                    }
                }
                .environment(model)
                .nordWindow()
            }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.apkg, .colpkg, .zip]) { result in
            if case .success(let url) = result { Task { await model.importFile(url) } }
        }
        .onOpenURL { url in
            guard ["apkg", "colpkg"].contains(url.pathExtension.lowercased()) else { return }
            Task { await model.importFile(url) }
        }
        .overlay { if let busy = model.busy { BusyOverlay(text: busy) } }
        .syncPrompts(model)
        .alert("Error", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") {}
        } message: {
            Text(model.error ?? "")
        }
        .alert("Inni", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("OK") {}
        } message: {
            Text(model.message ?? "")
        }
        .onChange(of: phase) { _, p in
            if p == .active { model.refresh() }
        }
        .onAppear(perform: openFromLaunchArgument)
        .nordWindow()
        .focusedSceneValue(\.rootActions, RootActions(add: { sheet = .add(model.selectedDeck) }, importFile: { importing = true },
                                                       export: { sheet = .export(nil) }, browse: { browse() },
                                                       stats: { show(.stats) }))
    }

    @ViewBuilder
    private var main: some View {
        @Bindable var model = model
        #if os(macOS)
        VStack(spacing: 0) {
            NavigationSplitView(columnVisibility: $columns) {
                DeckListView(sheet: $sheet, newDeckRequest: $newDeck)
                    .navigationSplitViewColumnWidth(min: 260, ideal: 360, max: 560)
            } detail: {
                detail
                    .toolbar { if model.study == nil { toolbar } }
                    .toolbarBackground(Nord.bar, for: .windowToolbar)
                    .frame(minWidth: 460)
            }
            StatusBar()
        }
        .background(Nord.background)
        #else
        NavigationStack(path: $path) {
            DeckListView(sheet: $sheet, newDeckRequest: $newDeck)
                .navigationTitle(model.collectionName)
                .toolbar { toolbar }
                .navigationDestination(for: Page.self) { page in
                    switch page {
                    case .browse: BrowserView()
                    case .stats: StatsView()
                    case .notetypes: NotetypesView()
                    case .settings: SettingsView()
                    }
                }
                .navigationDestination(item: $model.study) { did in
                    if let col = model.col { ReviewerView(session: ReviewSession(col: col, deckID: did)) }
                }
        }
        #endif
    }

    #if os(macOS)
    @ViewBuilder
    private var detail: some View {
        if let did = model.study, let col = model.col {
            ReviewerView(session: ReviewSession(col: col, deckID: did)).id(did)
        } else if let page = model.page {
            NavigationStack {
                switch page {
                case .stats: StatsView()
                case .notetypes: NotetypesView()
                case .browse, .settings: EmptyView()
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button { model.page = nil } label: { Label("Decks", systemImage: "chevron.backward") }
                        .keyboardShortcut(.escape, modifiers: [])
                }
            }
        } else if let node = model.node(model.selectedDeck) {
            DeckOverview(node: node, sheet: $sheet, browse: { browse($0) })
                .navigationTitle(model.collectionName)
        } else {
            ContentUnavailableView("No Decks", systemImage: "rectangle.stack",
                                   description: Text("Add notes, import an .apkg file or log in to AnkiWeb to sync."))
                .navigationTitle(model.collectionName)
        }
    }
    #endif

    private func show(_ page: Page) {
        #if os(macOS)
        model.study = nil
        model.page = page
        #else
        path.append(page)
        #endif
    }

    /// `-InniOpen study:<deck>|options:<deck>|browse|stats|add|notetypes|settings`, for screenshots and UI checks.
    private func openFromLaunchArgument() {
        #if DEBUG && os(macOS)
        DebugSnapshot.scheduleIfRequested()
        #endif
        #if DEBUG
        // `-InniSyncLogin user:pass@http://host:port/` logs in to a test server and syncs; `logout` undoes it.
        if UserDefaults.standard.string(forKey: "InniSyncLogin") == "logout" {
            model.logout()
            UserDefaults.standard.removeObject(forKey: "syncServer")
        } else if let login = UserDefaults.standard.string(forKey: "InniSyncLogin"), let at = login.firstIndex(of: "@"),
           let colon = login[..<at].firstIndex(of: ":") {
            UserDefaults.standard.set(String(login[login.index(after: at)...]), forKey: "syncServer")
            let user = String(login[..<colon]), pass = String(login[login.index(after: colon)..<at])
            Task { if await model.login(username: user, password: pass) { await model.sync() } }
        }
        #endif
        guard let arg = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)["InniOpen"] as? String else { return }
        let parts = arg.split(separator: ":", maxSplits: 1).map(String.init)
        let deck = parts.count > 1 ? model.col?.deck(named: parts[1])?.id : nil
        switch parts[0] {
        case "study":
            if let deck { model.selectedDeck = deck }
            model.study = deck
        case "options": if let deck { sheet = .options(deck) }
        case "browse": browse()
        case "stats": show(.stats)
        case "notetypes": show(.notetypes)
        case "settings": show(.settings)
        case "add": sheet = .add(deck)
        case "deck": if let deck { model.selectedDeck = deck }
        default: break
        }
    }

    private func browse(_ query: String? = nil) {
        if let query { model.browserRequest = query }
        #if os(macOS)
        openWindow(id: "browser")
        #else
        path.append(Page.browse)
        #endif
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { Task { await model.sync() } } label: {
                Label("Sync", systemImage: model.mediaSyncing ? "arrow.triangle.2.circlepath.icloud" : "arrow.triangle.2.circlepath")
            }
            .keyboardShortcut("y", modifiers: [])
            .disabled(model.syncing)
            .help(model.syncUsername.map { "Sync with AnkiWeb (\($0))" } ?? "Log in to AnkiWeb to sync")
            Button { sheet = .add(model.selectedDeck) } label: { Label("Add", systemImage: "plus") }
                .keyboardShortcut("a", modifiers: [])
            Button { browse() } label: { Label("Browse", systemImage: "magnifyingglass") }
                .keyboardShortcut("b", modifiers: [])
            #if os(macOS)
            Button { show(.stats) } label: { Label("Statistics", systemImage: "chart.bar") }
                .keyboardShortcut("t", modifiers: [])
            #endif
            Menu {
                Button { newDeck = true } label: { Label("New Deck…", systemImage: "folder.badge.plus") }
                Divider()
                Button { show(.stats) } label: { Label("Statistics", systemImage: "chart.bar") }
                Button { show(.notetypes) } label: { Label("Note Types", systemImage: "list.bullet.rectangle") }
                Divider()
                Button { importing = true } label: { Label("Import…", systemImage: "square.and.arrow.down") }
                Button { sheet = .export(nil) } label: { Label("Export…", systemImage: "square.and.arrow.up") }
                Divider()
                Button { model.checkDatabase() } label: { Label("Check Database", systemImage: "stethoscope") }
                Button { model.removeEmptyCards() } label: { Label("Delete Empty Cards", systemImage: "trash") }
                #if os(iOS)
                Divider()
                Button { show(.settings) } label: { Label("Settings", systemImage: "gear") }
                #endif
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
    }
}

public struct RootActions {
    var add: () -> Void
    var importFile: () -> Void
    var export: () -> Void
    var browse: () -> Void
    var stats: () -> Void
}

struct RootActionsKey: FocusedValueKey {
    typealias Value = RootActions
}

extension FocusedValues {
    public var rootActions: RootActions? {
        get { self[RootActionsKey.self] }
        set { self[RootActionsKey.self] = newValue }
    }
}

struct BusyOverlay: View {
    let text: String
    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView().tint(Nord.accent)
                Text(text).font(Nord.mono).foregroundStyle(Nord.text)
            }
            .padding(24)
            .background(Nord.raised, in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

#if os(macOS)
/// Kveikur-style status line: where you are on the left, collection and sync state on the right.
struct StatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let _ = model.revision
        HStack(spacing: 14) {
            Text(location).foregroundStyle(Nord.n8).lineLimit(1).truncationMode(.head)
            Spacer()
            if let col = model.col {
                Text("\(col.noteCount()) notes").foregroundStyle(Nord.secondary)
            }
            HStack(spacing: 6) {
                Text("due").foregroundStyle(Nord.secondary)
                Text("\(model.totals.new)").foregroundStyle(Nord.new)
                Text("\(model.totals.learning)").foregroundStyle(Nord.learn)
                Text("\(model.totals.review)").foregroundStyle(Nord.review)
            }
            Button { Task { await model.sync() } } label: { Text(sync).foregroundStyle(syncColor) }
                .buttonStyle(.plain)
                .help(model.syncUsername.map { "Sync with AnkiWeb as \($0) (Y)" } ?? "Log in to AnkiWeb")
        }
        .font(.system(size: 11, design: .monospaced))
        .monospacedDigit()
        .padding(.horizontal, 12)
        .frame(height: 24)
        .background(Nord.bar)
        .overlay(alignment: .top) { Nord.separator.frame(height: 1) }
    }

    private var location: String {
        var parts = [model.collectionName]
        if let d = model.node(model.study ?? model.selectedDeck)?.deck { parts.append(d.name.replacingOccurrences(of: "::", with: " › ")) }
        if model.study != nil { parts.append("study") } else if let p = model.page { parts.append("\(p)") }
        return parts.joined(separator: " › ")
    }

    private var sync: String {
        if model.syncing { return "syncing…" }
        if model.mediaSyncing { return "syncing media…" }
        return model.syncUsername == nil ? "not synced" : "AnkiWeb"
    }

    private var syncColor: Color {
        model.syncing || model.mediaSyncing ? Nord.n13 : (model.syncUsername == nil ? Nord.secondary : Nord.n14)
    }
}
#endif

struct ExportView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var deckID: DeckID?
    @State private var whole = false
    @State private var scheduling = true
    @State private var file: URL?

    var body: some View {
        NordForm {
            Picker("Export", selection: $whole) {
                Text("Deck package (.apkg)").tag(false)
                Text("Whole collection (.colpkg)").tag(true)
            }
            .pickerStyle(.inline)
            if !whole {
                Picker("Deck", selection: $deckID) {
                    Text("All Decks").tag(DeckID?.none)
                    ForEach(model.col?.sortedDecks ?? []) { Text($0.name.replacingOccurrences(of: "::", with: " › ")).tag(DeckID?.some($0.id)) }
                }
                Toggle("Include scheduling", isOn: $scheduling)
            } else {
                Text("A .colpkg replaces the whole collection when imported into Anki or Inni.").font(.caption).foregroundStyle(.secondary)
            }
            if let file {
                #if os(iOS)
                ShareLink(item: file) { Label("Share \(file.lastPathComponent)", systemImage: "square.and.arrow.up") }
                #else
                Text("Saved \(file.lastPathComponent)").foregroundStyle(.secondary)
                #endif
            }
        }
        .navigationTitle("Export")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Export") { Task { await run() } }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 300)
        #endif
    }

    private func run() async {
        guard let url = await model.export(whole ? .collection : .deck(deckID, scheduling: scheduling)) else { return }
        #if os(macOS)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = url.lastPathComponent
        panel.allowedContentTypes = [whole ? .colpkg : .apkg]
        if panel.runModal() == .OK, let dest = panel.url {
            try? FileManager.default.removeItem(at: dest)
            do {
                try FileManager.default.moveItem(at: url, to: dest)
                file = dest
                dismiss()
            } catch {
                model.error = error.localizedDescription
            }
        }
        #else
        file = url
        #endif
    }
}
