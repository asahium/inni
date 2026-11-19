import InniCore
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let apkg = UTType(filenameExtension: "apkg") ?? .data
    static let colpkg = UTType(filenameExtension: "colpkg") ?? .data
}

/// Things a deck row or menu can ask the root to present.
enum DeckSheet: Identifiable {
    case options(DeckID)
    case add(DeckID?)
    case export(DeckID?)

    var id: String {
        switch self {
        case .options(let d): "o\(d)"
        case .add(let d): "a\(d ?? 0)"
        case .export(let d): "e\(d ?? 0)"
        }
    }
}

/// The deck tree. On macOS it is the sidebar of the main window and selecting a deck shows its overview;
/// on iOS tapping a deck starts studying it.
struct DeckListView: View {
    @Environment(AppModel.self) private var model
    @Binding var sheet: DeckSheet?
    @Binding var newDeckRequest: Bool
    @State private var renaming: Deck?
    @State private var newName = ""
    @State private var creatingParent: String??
    @State private var deleting: Deck?

    var body: some View {
        list
            .onChange(of: newDeckRequest) { _, v in if v { newDeck(); newDeckRequest = false } }
            .alert(renaming == nil ? "New Deck" : "Rename Deck", isPresented: Binding(
                get: { renaming != nil || creatingParent != nil },
                set: { if !$0 { renaming = nil; creatingParent = nil } })) {
                TextField("Name", text: $newName)
                Button("Cancel", role: .cancel) {}
                Button("OK") { commitName() }
            } message: {
                Text("Use :: to nest decks, e.g. Languages::French.")
            }
            .confirmationDialog(deleting.map { "Delete “\($0.name)” and all its cards?" } ?? "",
                                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                                titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let d = deleting { model.perform { try $0.remove(deck: d.id) } }
                }
            }
    }

    @ViewBuilder
    private var list: some View {
        #if os(macOS)
        DeckSidebar(actions: actions)
        #else
        List {
            if model.tree.isEmpty {
                ContentUnavailableView("No Decks", systemImage: "rectangle.stack", description: Text("Add notes or import an .apkg file."))
                    .listRowBackground(Nord.background)
            }
            DeckRows(nodes: model.tree, actions: actions)
            Section {
                HStack {
                    Text("Due today").foregroundStyle(Nord.secondary)
                    Spacer()
                    CountsView(new: model.totals.new, learn: model.totals.learning, review: model.totals.review)
                }
                .listRowBackground(Nord.raised)
            }
        }
        .nordList()
        #endif
    }

    private var actions: DeckActions {
        DeckActions(
            study: { model.study = $0 },
            options: { sheet = .options($0) },
            add: { sheet = .add($0) },
            export: { sheet = .export($0) },
            rename: { d in newName = d.name; renaming = d },
            subdeck: { d in newName = d.name + "::"; creatingParent = .some(d.name) },
            delete: { deleting = $0 },
            toggle: { d in
                var d = d
                d.collapsed.toggle()
                model.perform { _ = try $0.save(d) }
            },
            emptyFiltered: { d in model.perform { try $0.emptyFiltered(d.id) } }
        )
    }

    func newDeck() {
        newName = ""
        creatingParent = .some(nil)
    }

    private func commitName() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        if var d = renaming {
            d.name = name
            model.perform { _ = try $0.save(d) }
        } else {
            model.perform { _ = try $0.deckID(named: name) }
        }
        renaming = nil
        creatingParent = nil
    }
}

struct DeckActions {
    var study: (DeckID) -> Void
    var options: (DeckID) -> Void
    var add: (DeckID) -> Void
    var export: (DeckID) -> Void
    var rename: (Deck) -> Void
    var subdeck: (Deck) -> Void
    var delete: (Deck) -> Void
    var toggle: (Deck) -> Void
    var emptyFiltered: (Deck) -> Void
}

extension DeckNode {
    var symbol: String {
        if deck.isFiltered { return "line.3.horizontal.decrease.circle" }
        return children.isEmpty ? "rectangle.on.rectangle" : "folder.fill"
    }

    var tint: Color {
        if deck.isFiltered { return Nord.filtered }
        return children.isEmpty ? Nord.n7 : Nord.folder
    }
}

@ViewBuilder
func deckMenu(_ node: DeckNode, _ actions: DeckActions) -> some View {
    Button("Study") { actions.study(node.id) }
    Button("Add Note…") { actions.add(node.id) }
    if node.deck.isFiltered {
        Button("Empty") { actions.emptyFiltered(node.deck) }
    } else {
        Button("Options…") { actions.options(node.id) }
        Button("Add Subdeck…") { actions.subdeck(node.deck) }
    }
    Button("Rename…") { actions.rename(node.deck) }
    Button("Export…") { actions.export(node.id) }
    Divider()
    Button("Delete", role: .destructive) { actions.delete(node.deck) }
}

#if os(iOS)
struct DeckRows: View {
    let nodes: [DeckNode]
    let actions: DeckActions

    var body: some View {
        ForEach(nodes) { node in
            if node.children.isEmpty {
                row(node)
            } else {
                DisclosureGroup(isExpanded: Binding(get: { !node.deck.collapsed }, set: { _ in actions.toggle(node.deck) })) {
                    DeckRows(nodes: node.children, actions: actions)
                } label: {
                    row(node)
                }
                .listRowBackground(Nord.background)
            }
        }
    }

    private func row(_ node: DeckNode) -> some View {
        Button { actions.study(node.id) } label: {
            HStack(spacing: 12) {
                Image(systemName: node.symbol).foregroundStyle(node.tint).frame(width: 22)
                Text(node.name).foregroundStyle(node.deck.isFiltered ? Nord.filtered : Nord.text).lineLimit(2)
                Spacer()
                CountsView(new: node.counts.new, learn: node.counts.learning, review: node.counts.review)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Nord.background)
        .listRowSeparatorTint(Nord.separator)
        .contextMenu { deckMenu(node, actions) }
    }
}
#endif

#if os(macOS)
/// Anki's deck list as a yazi-like column: monospaced rows, a pill cursor and vim keys.
struct DeckSidebar: View {
    @Environment(AppModel.self) private var model
    let actions: DeckActions
    @FocusState private var focused: Bool

    private struct Row: Identifiable {
        let node: DeckNode
        let depth: Int
        let parent: DeckID?
        var id: DeckID { node.id }
    }

    private var rows: [Row] {
        var out: [Row] = []
        func walk(_ nodes: [DeckNode], _ depth: Int, _ parent: DeckID?) {
            for n in nodes {
                out.append(Row(node: n, depth: depth, parent: parent))
                if !n.deck.collapsed { walk(n.children, depth + 1, n.id) }
            }
        }
        walk(model.tree, 0, nil)
        return out
    }

    var body: some View {
        let rows = rows
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("DECKS").foregroundStyle(Nord.secondary)
                Spacer()
                ForEach(["NEW", "LRN", "DUE"], id: \.self) { Text($0).frame(minWidth: 34, alignment: .trailing) }
                    .foregroundStyle(Nord.n3)
            }
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .padding(.leading, 14)
            .padding(.trailing, 16)
            .padding(.vertical, 8)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { row in
                            rowView(row)
                                .id(row.id)
                                .onTapGesture(count: 2) { actions.study(row.id) }
                                .simultaneousGesture(TapGesture().onEnded { select(row.id) })
                                .contextMenu { deckMenu(row.node, actions) }
                        }
                    }
                    .padding(.bottom, 8)
                }
                .onChange(of: model.selectedDeck) { _, id in
                    if let id { withAnimation(nil) { proxy.scrollTo(id) } }
                }
            }
            if model.tree.isEmpty {
                ContentUnavailableView("No Decks", systemImage: "rectangle.stack", description: Text("Add notes or import an .apkg file."))
            }
            Spacer(minLength: 0)
        }
        .background(Nord.bar)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true }
        .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow, .return, .space, "j", "k", "h", "l", "g", "G"]) { press in
            handle(press, rows)
        }
    }

    private func rowView(_ row: Row) -> some View {
        let node = row.node
        let selected = model.selectedDeck == node.id
        let fg: Color = selected ? Nord.selectionText : (node.deck.isFiltered ? Nord.filtered : Nord.text)
        return HStack(spacing: 6) {
            Group {
                if node.children.isEmpty {
                    Color.clear
                } else {
                    Image(systemName: node.deck.collapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(selected ? Nord.selectionText : Nord.secondary)
                        .contentShape(Rectangle())
                        .onTapGesture { actions.toggle(node.deck) }
                }
            }
            .frame(width: 10)
            Image(systemName: node.symbol)
                .font(.system(size: 11))
                .foregroundStyle(selected ? Nord.selectionText : node.tint)
                .frame(width: 14)
            Text(node.name).lineLimit(1).truncationMode(.tail).foregroundStyle(fg)
            Spacer(minLength: 4)
            if selected {
                HStack(spacing: 6) {
                    ForEach([node.counts.new, node.counts.learning, node.counts.review], id: \.self) {
                        Text("\($0)").frame(minWidth: 34, alignment: .trailing)
                    }
                }
                .foregroundStyle(Nord.selectionText)
            } else {
                CountsView(new: node.counts.new, learn: node.counts.learning, review: node.counts.review)
            }
        }
        .font(selected ? Nord.listBold : Nord.listFont)
        .monospacedDigit()
        .padding(.leading, 8 + CGFloat(row.depth) * 14)
        .padding(.trailing, 12)
        .frame(height: 22)
        .background(PillBackground(selected: selected, active: focused).padding(.horizontal, 4).padding(.vertical, 1))
        .contentShape(Rectangle())
    }

    private func select(_ id: DeckID) {
        model.selectedDeck = id
        model.page = nil
        model.study = nil
        focused = true
    }

    private func handle(_ press: KeyPress, _ rows: [Row]) -> KeyPress.Result {
        guard !rows.isEmpty else { return .ignored }
        let i = rows.firstIndex { $0.id == model.selectedDeck }
        let current = i.map { rows[$0] }
        switch press.key {
        case .downArrow, "j": select(rows[min(rows.count - 1, (i ?? -1) + 1)].id)
        case .upArrow, "k": select(rows[max(0, (i ?? 1) - 1)].id)
        case "g": select(rows[0].id)
        case "G": select(rows[rows.count - 1].id)
        case .rightArrow, "l":
            if let c = current, !c.node.children.isEmpty, c.node.deck.collapsed { actions.toggle(c.node.deck) }
        case .leftArrow, "h":
            if let c = current {
                if !c.node.children.isEmpty, !c.node.deck.collapsed { actions.toggle(c.node.deck) }
                else if let p = c.parent { select(p) }
            }
        case .return, .space:
            if let c = current { actions.study(c.id) }
        default: return .ignored
        }
        return .handled
    }
}
#endif
