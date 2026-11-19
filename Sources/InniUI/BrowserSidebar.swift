#if os(macOS)
import InniCore
import SwiftUI

/// Anki's browser sidebar: one click turns a deck, note type, tag, flag or card state into a search.
struct BrowserSidebar: View {
    @Environment(AppModel.self) private var model
    let query: String
    let pick: (String) -> Void
    @State private var collapsed: Set<String> = ["Note Types", "Tags"]

    private struct Item: Identifiable {
        let title: String
        let icon: String
        let tint: Color
        let query: String
        var depth = 0
        var id: String { query }
    }

    var body: some View {
        let _ = model.revision
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                section("Collection", [
                    Item(title: "Whole Collection", icon: "tray.full", tint: Nord.n8, query: "deck:*"),
                    Item(title: "Current Deck", icon: "scope", tint: Nord.n8, query: "deck:current"),
                ])
                section("Today", [
                    Item(title: "Due", icon: "clock", tint: Nord.review, query: "is:due"),
                    Item(title: "Studied", icon: "checkmark.circle", tint: Nord.n14, query: "rated:1"),
                    Item(title: "Again", icon: "arrow.counterclockwise", tint: Nord.n11, query: "rated:1:1"),
                    Item(title: "Added", icon: "plus.circle", tint: Nord.n9, query: "added:1"),
                    Item(title: "Edited", icon: "pencil.circle", tint: Nord.n9, query: "edited:1"),
                ])
                section("Card State", [
                    Item(title: "New", icon: "sparkle", tint: Nord.new, query: "is:new"),
                    Item(title: "Learning", icon: "graduationcap", tint: Nord.learn, query: "is:learn"),
                    Item(title: "Review", icon: "arrow.triangle.2.circlepath", tint: Nord.review, query: "is:review"),
                    Item(title: "Suspended", icon: "pause.circle", tint: Nord.n13, query: "is:suspended"),
                    Item(title: "Buried", icon: "eye.slash", tint: Nord.n13, query: "is:buried"),
                    Item(title: "Marked", icon: "star", tint: Nord.n15, query: "tag:marked"),
                    Item(title: "Leeches", icon: "ant", tint: Nord.n11, query: "tag:leech"),
                ])
                section("Flags", (1...7).map { Item(title: flagName($0), icon: "flag.fill", tint: Nord.flag($0), query: "flag:\($0)") })
                section("Decks", decks)
                section("Note Types", (model.col?.sortedNotetypes ?? []).map {
                    Item(title: $0.name, icon: "list.bullet.rectangle", tint: Nord.n7, query: "note:\(quoted($0.name))")
                })
                section("Tags", tags)
            }
            .padding(.vertical, 6)
        }
        .background(Nord.bar)
    }

    private var decks: [Item] {
        var out: [Item] = []
        func walk(_ nodes: [DeckNode], _ depth: Int) {
            for n in nodes {
                out.append(Item(title: n.name, icon: n.symbol, tint: n.tint, query: "deck:\(quoted(n.deck.name))", depth: depth))
                walk(n.children, depth + 1)
            }
        }
        walk(model.tree, 0)
        return out
    }

    private var tags: [Item] {
        (model.col?.allTags() ?? []).map { tag in
            let parts = tag.components(separatedBy: "::")
            return Item(title: parts.last ?? tag, icon: "tag", tint: Nord.n13, query: "tag:\(quoted(tag))", depth: parts.count - 1)
        }
    }

    private func quoted(_ s: String) -> String {
        s.contains(where: { $0 == " " || $0 == "(" || $0 == ")" }) ? "\"\(s)\"" : s
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [Item]) -> some View {
        if !items.isEmpty {
            let open = !collapsed.contains(title)
            Button {
                if open { collapsed.insert(title) } else { collapsed.remove(title) }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 8, weight: .bold))
                    Text(title.uppercased())
                    Spacer()
                }
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(Nord.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                ForEach(items) { row($0) }
            }
        }
    }

    private func row(_ item: Item) -> some View {
        let selected = item.query == query
        return HStack(spacing: 7) {
            Image(systemName: item.icon).font(.system(size: 11)).foregroundStyle(selected ? Nord.selectionText : item.tint).frame(width: 14)
            Text(item.title).lineLimit(1).foregroundStyle(selected ? Nord.selectionText : Nord.text)
            Spacer(minLength: 0)
        }
        .font(selected ? Nord.listBold : Nord.listFont)
        .padding(.leading, 12 + CGFloat(item.depth) * 12)
        .padding(.trailing, 10)
        .frame(height: 22)
        .background(PillBackground(selected: selected).padding(.horizontal, 4).padding(.vertical, 1))
        .contentShape(Rectangle())
        .onTapGesture { pick(item.query) }
        .help(item.query)
    }
}
#endif
