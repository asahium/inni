import InniCore
import SwiftUI

/// Loads browser rows in pages as the table scrolls. Not observed: filling it never re-renders the view.
final class RowCache {
    private var rows: [CardID: BrowserRow] = [:]
    var ids: [CardID] = []
    weak var col: Collection?

    func reset(_ ids: [CardID]) {
        self.ids = ids
        rows.removeAll()
    }

    func row(_ id: CardID, at index: Int?) -> BrowserRow? {
        if let r = rows[id] { return r }
        guard let col else { return nil }
        var page = [id]
        if let index, index < ids.count {
            let start = max(0, index - 50)
            page = Array(ids[start..<min(ids.count, start + 200)])
        }
        for r in col.browserRows(page.contains(id) ? page : [id]) { rows[r.id] = r }
        return rows[id]
    }

    func invalidate(_ ids: some Sequence<CardID>) {
        for id in ids { rows[id] = nil }
    }
}

struct CardRef: Identifiable, Hashable {
    let id: CardID
    let index: Int
}

struct BrowserView: View {
    @Environment(AppModel.self) private var model
    @State private var query = UserDefaults.standard.string(forKey: "browserQuery") ?? "deck:current"
    @State private var sort: BrowserSort = .sortField
    @State private var reverse = false
    @State private var refs: [CardRef] = []
    @State private var selection = Set<CardID>()
    @State private var cache = RowCache()
    @State private var version = 0
    @State private var searchError: String?
    @State private var changingDeck = false
    @State private var tagEdit: TagEdit?
    @State private var dueDays = ""
    @State private var settingDue = false
    @State private var confirmDelete = false
    @State private var tagText = ""

    enum TagEdit { case add, remove }

    var body: some View {
        content
            .navigationTitle("Browse")
            .searchable(text: $query, placement: .toolbar, prompt: "deck:French tag:verb is:due")
            .onSubmit(of: .search) { search() }
            .toolbar { toolbar }
            .onAppear {
                cache.col = model.col
                if let q = model.browserRequest { query = q; model.browserRequest = nil }
                search()
            }
            .onChange(of: model.browserRequest) { _, q in
                guard let q else { return }
                query = q
                model.browserRequest = nil
                search()
            }
            .onChange(of: model.revision) { _, _ in
                cache.invalidate(selection)
                version += 1
            }
            .onChange(of: sort) { _, _ in search() }
            .onChange(of: reverse) { _, _ in search() }
            .sheet(isPresented: $changingDeck) { DeckPicker { did in act { try $0.setDeck(Array(selection), deckID: did) } } }
            .alert(tagEdit == .add ? "Add Tags" : "Remove Tags", isPresented: Binding(get: { tagEdit != nil }, set: { if !$0 { tagEdit = nil } })) {
                TextField("tags", text: $tagText)
                Button("Cancel", role: .cancel) {}
                Button("OK") {
                    let tags = Note.splitTags(tagText)
                    let notes = noteIDs
                    let adding = tagEdit == .add
                    act { adding ? try $0.addTags(tags, to: notes) : try $0.removeTags(tags, from: notes) }
                }
            }
            .alert("Set Due Date", isPresented: $settingDue) {
                TextField("days from today, e.g. 0 or 7", text: $dueDays)
                Button("Cancel", role: .cancel) {}
                Button("OK") { if let d = Int(dueDays) { act { try $0.setDueDate(Array(selection), days: d) } } }
            }
            .confirmationDialog("Delete \(noteIDs.count) note(s)?", isPresented: $confirmDelete) {
                Button("Delete", role: .destructive) {
                    let notes = noteIDs
                    act { try $0.remove(notes: notes) }
                    search()
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        #if os(macOS)
        HSplitView {
            BrowserSidebar(query: query) { q in
                query = q
                search()
            }
            .frame(minWidth: 180, idealWidth: 230, maxWidth: 360)
            VSplitView {
                VStack(spacing: 0) {
                    table
                    statusBar
                }
                .frame(minHeight: 200)
                detail.frame(minHeight: 220)
            }
        }
        .background(Nord.background)
        #else
        List(selection: $selection) {
            if let searchError { Text(searchError).foregroundStyle(Nord.n11) }
            ForEach(refs) { ref in
                let _ = version
                if let r = cache.row(ref.id, at: ref.index) {
                    NavigationLink {
                        EditorView(mode: .edit(r.noteID), embedded: true).environment(model)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                if r.flag > 0 { Image(systemName: "flag.fill").foregroundStyle(Nord.flag(r.flag)) }
                                Text(HTML.strip(r.sortField)).lineLimit(1)
                            }
                            Text("\(r.deck) · \(r.due)").font(.caption).foregroundStyle(Nord.secondary).lineLimit(1)
                        }
                        .opacity(r.suspended ? 0.5 : 1)
                    }
                    .listRowBackground(Nord.background)
                    .listRowSeparatorTint(Nord.separator)
                    .swipeActions {
                        Button("Delete", role: .destructive) { act { try $0.remove(notes: [r.noteID]) }; search() }
                        Button(r.suspended ? "Unsuspend" : "Suspend") { act { try $0.suspend([r.id], !r.suspended) } }.tint(Nord.n13)
                    }
                }
            }
        }
        .nordList()
        .safeAreaInset(edge: .bottom) { statusBar }
        #endif
    }

    #if os(macOS)
    private var table: some View {
        Table(refs, selection: $selection) {
            TableColumn("Sort Field") { ref in cell(ref) { r in
                HStack(spacing: 4) {
                    if r.flag > 0 { Image(systemName: "flag.fill").foregroundStyle(Nord.flag(r.flag)) }
                    Text(HTML.strip(r.sortField)).lineLimit(1)
                }
            } }
            .width(min: 160, ideal: 280)
            TableColumn("Card") { ref in cell(ref) { Text($0.cardName) } }.width(ideal: 90)
            TableColumn("Deck") { ref in cell(ref) { Text($0.deck) } }.width(ideal: 140)
            TableColumn("Due") { ref in cell(ref) { Text($0.due).monospacedDigit() } }.width(ideal: 90)
            TableColumn("Interval") { ref in cell(ref) { Text($0.interval) } }.width(ideal: 60)
            TableColumn("Ease") { ref in cell(ref) { Text($0.ease) } }.width(ideal: 50)
            TableColumn("Reviews") { ref in cell(ref) { Text("\($0.reps)") } }.width(ideal: 50)
            TableColumn("Tags") { ref in cell(ref) { Text($0.tags) } }.width(ideal: 120)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .font(Nord.listFont)
        .nordList()
        .contextMenu(forSelectionType: CardID.self) { _ in actionsMenu }
    }

    private func cell(_ ref: CardRef, @ViewBuilder _ content: (BrowserRow) -> some View) -> some View {
        let _ = version
        return Group {
            if let r = cache.row(ref.id, at: ref.index) {
                content(r).opacity(r.suspended ? 0.45 : 1).foregroundStyle(r.buried ? Nord.n13 : Nord.text)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if selection.count == 1, let id = selection.first, let card = model.col?.card(id) {
            HSplitView {
                EditorView(mode: .edit(card.noteID), embedded: true)
                    .id("\(card.noteID)-\(version)")
                    .frame(minWidth: 320)
                CardPreview(cardID: id).frame(minWidth: 240)
            }
        } else {
            Text(selection.isEmpty ? "No selection" : "\(selection.count) cards selected")
                .font(Nord.mono).foregroundStyle(Nord.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Nord.background)
        }
    }
    #endif

    private var statusBar: some View {
        HStack {
            if let searchError { Text(searchError).foregroundStyle(Nord.n11) } else {
                Text(query).foregroundStyle(Nord.n8).lineLimit(1).truncationMode(.head)
                Text("\(refs.count) cards" + (selection.count > 1 ? ", \(selection.count) selected" : "")).foregroundStyle(Nord.secondary)
            }
            Spacer()
            Picker("Sort", selection: $sort) {
                ForEach(BrowserSort.allCases, id: \.self) { Text(sortName($0)).tag($0) }
            }
            .fixedSize()
            Toggle(isOn: $reverse) { Image(systemName: "arrow.up.arrow.down") }.toggleStyle(.button)
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Nord.bar)
    }

    private func sortName(_ s: BrowserSort) -> String {
        switch s {
        case .sortField: "Sort Field"
        case .created: "Created"
        case .due: "Due"
        case .interval: "Interval"
        case .ease: "Ease"
        case .reps: "Reviews"
        case .lapses: "Lapses"
        case .modified: "Modified"
        case .deck: "Deck"
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu { actionsMenu } label: { Label("Actions", systemImage: "ellipsis.circle") }
                .disabled(selection.isEmpty)
        }
        #if os(iOS)
        ToolbarItem(placement: .topBarTrailing) { EditButton() }
        #endif
    }

    @ViewBuilder
    private var actionsMenu: some View {
        Button("Change Deck…") { changingDeck = true }.keyboardShortcut("d", modifiers: .command)
        Menu("Flag") {
            ForEach(0...7, id: \.self) { f in
                Button(f == 0 ? "No Flag" : flagName(f)) { act { try $0.setFlag(Array(selection), flag: f) } }
            }
        }
        Button("Toggle Suspend") {
            let ids = Array(selection)
            let allSuspended = model.col?.cards(ids).allSatisfy(\.isSuspended) ?? false
            act { try $0.suspend(ids, !allSuspended) }
        }
        .keyboardShortcut("j", modifiers: .command)
        Button("Add Tags…") { tagText = ""; tagEdit = .add }.keyboardShortcut("t", modifiers: [.command, .shift])
        Button("Remove Tags…") { tagText = ""; tagEdit = .remove }
        Divider()
        Button("Forget (Reset to New)") { act { try $0.forget(Array(selection)) } }
        Button("Set Due Date…") { dueDays = "0"; settingDue = true }
        Divider()
        Button("Delete Notes", role: .destructive) { confirmDelete = true }.keyboardShortcut(.delete, modifiers: .command)
    }

    private var noteIDs: [NoteID] {
        Array(Set(model.col?.cards(Array(selection)).map(\.noteID) ?? []))
    }

    private func search() {
        guard let col = model.col else { return }
        cache.col = col
        UserDefaults.standard.set(query, forKey: "browserQuery")
        do {
            let ids = try col.findCards(query, sort: sort, reverse: reverse)
            cache.reset(ids)
            refs = ids.enumerated().map { CardRef(id: $1, index: $0) }
            searchError = nil
            selection = selection.intersection(ids)
        } catch {
            searchError = "Invalid search: \(error.localizedDescription)"
        }
        version += 1
    }

    private func act(_ body: @escaping (Collection) throws -> Void) {
        model.perform(body)
        cache.invalidate(selection)
        version += 1
    }
}

struct DeckPicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let pick: (DeckID) -> Void
    @State private var deck: DeckID = 1

    var body: some View {
        NavigationStack {
            NordForm {
                Picker("Deck", selection: $deck) {
                    ForEach((model.col?.sortedDecks ?? []).filter { !$0.isFiltered }) { Text($0.name.replacingOccurrences(of: "::", with: " › ")).tag($0.id) }
                }
                .pickerStyle(.inline)
            }
            .navigationTitle("Change Deck")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Move") { pick(deck); dismiss() } }
            }
        }
        #if os(macOS)
        .frame(minWidth: 360, minHeight: 400)
        #endif
    }
}

/// Question and answer of one card, as the reviewer would show them.
struct CardPreview: View {
    @Environment(AppModel.self) private var model
    let cardID: CardID
    @State private var answer = false

    var body: some View {
        VStack(spacing: 0) {
            PreviewWebView(html: html, folder: model.col?.mediaFolder)
            Picker("", selection: $answer) {
                Text("Question").tag(false)
                Text("Answer").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(6)
        }
    }

    private var html: String {
        let _ = model.revision
        guard let col = model.col, let card = col.card(cardID), let note = col.note(card.noteID) else { return "" }
        let r = CardRenderer.render(card, note: note, in: col, browser: false)
        return CardRenderer.page(answer ? r.answer : r.question, card: r, night: true, platform: Platform.css)
    }
}
