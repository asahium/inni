import Charts
import InniCore
import SwiftUI

/// Anki's deck overview, with what you'd otherwise open Statistics for: today, the coming week and the card mix.
struct DeckOverview: View {
    @Environment(AppModel.self) private var model
    let node: DeckNode
    @Binding var sheet: DeckSheet?
    var browse: (String) -> Void

    var body: some View {
        let _ = model.revision
        let s = model.col?.stats(deckID: node.id, days: 7) ?? CollectionStats()
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                counts
                actions
                HStack(alignment: .top, spacing: 16) {
                    panel("TODAY") { today(s) }
                    panel("NEXT 7 DAYS") { forecast(s) }
                }
                panel("CARDS") { mix(s.counts) }
                if !description.isEmpty {
                    panel("DESCRIPTION") {
                        Text(description).font(.callout).foregroundStyle(Nord.text).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Nord.background)
    }

    private var description: String {
        HTML.strip(node.deck.description).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            let parts = node.deck.name.components(separatedBy: "::")
            if parts.count > 1 {
                Text(parts.dropLast().joined(separator: " › ")).font(Nord.mono).foregroundStyle(Nord.secondary)
            }
            HStack(spacing: 10) {
                Image(systemName: node.symbol).foregroundStyle(node.tint)
                Text(node.name).foregroundStyle(Nord.n6)
            }
            .font(.system(size: 26, weight: .semibold))
        }
    }

    private var counts: some View {
        HStack(spacing: 0) {
            bigCount(node.counts.new, "New", Nord.new)
            bigCount(node.counts.learning, "Learning", Nord.learn)
            bigCount(node.counts.review, "To Review", Nord.review)
        }
        .padding(.vertical, 14)
        .background(Nord.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func bigCount(_ n: Int, _ label: String, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text("\(n)").font(.system(size: 34, weight: .medium, design: .monospaced)).foregroundStyle(n == 0 ? Nord.n3 : color)
            Text(label.uppercased()).font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(Nord.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button { model.study = node.id } label: {
                Label(node.counts.total > 0 ? "Study Now" : "Nothing Due", systemImage: "play.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize()
                    .frame(maxWidth: .infinity, minHeight: 38)
            }
            .buttonStyle(NordButtonStyle(color: Nord.accent, prominent: node.counts.total > 0))
            .keyboardShortcut(.defaultAction)
            .help("Study (Return, Space or double-click the deck)")
            secondary("plus", "Add") { sheet = .add(node.id) }.keyboardShortcut("a", modifiers: [])
            secondary("magnifyingglass", "Browse") { browse("deck:\"\(node.deck.name)\"") }
            if node.deck.isFiltered {
                secondary("arrow.uturn.backward", "Empty") { model.perform { try $0.emptyFiltered(node.id) } }
            } else {
                secondary("slider.horizontal.3", "Options") { sheet = .options(node.id) }
            }
        }
    }

    private func secondary(_ icon: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ViewThatFits {
                Label(title, systemImage: icon).lineLimit(1).fixedSize()
                Image(systemName: icon)
            }
            .font(.system(size: 13))
            .padding(.horizontal, 14)
            .frame(minHeight: 38)
        }
        .buttonStyle(NordButtonStyle(color: Nord.n4))
        .help(title)
    }

    private func panel(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(Nord.secondary)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Nord.raised.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func today(_ s: CollectionStats) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if s.today.reviews == 0 {
                Text("Nothing studied yet").foregroundStyle(Nord.secondary)
            } else {
                stat("Studied", "\(s.today.reviews) cards")
                stat("Time", s.today.seconds < 60 ? "\(s.today.seconds) s" : "\(s.today.seconds / 60) min")
                stat("Correct", "\(Int((1 - Double(s.today.again) / Double(max(1, s.today.reviews))) * 100))%")
            }
            if let next = s.forecast.dropFirst().first?.total { stat("Due tomorrow", "\(next)") }
        }
        .font(.system(size: 12, design: .monospaced))
    }

    private func stat(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).foregroundStyle(Nord.secondary)
            Spacer()
            Text(v).foregroundStyle(Nord.text)
        }
    }

    private func forecast(_ s: CollectionStats) -> some View {
        Chart(s.forecast) { d in
            BarMark(x: .value("Day", weekday(d.day)), y: .value("Due", d.total))
                .foregroundStyle(d.day == 0 ? Nord.accent : Nord.n9.opacity(0.6))
                .cornerRadius(3)
        }
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine().foregroundStyle(Nord.separator)
                AxisValueLabel().foregroundStyle(Nord.secondary)
            }
        }
        .chartXAxis {
            AxisMarks { _ in AxisValueLabel().foregroundStyle(Nord.secondary).font(.system(size: 9, design: .monospaced)) }
        }
        .frame(height: 96)
    }

    private func weekday(_ offset: Int) -> String {
        let date = Calendar.current.date(byAdding: .day, value: offset, to: Date()) ?? Date()
        return Calendar.current.shortWeekdaySymbols[Calendar.current.component(.weekday, from: date) - 1]
    }

    private func mix(_ c: CollectionStats.CardCounts) -> some View {
        let parts: [(String, Int, Color)] = [
            ("New", c.new, Nord.new), ("Learning", c.learning + c.relearning, Nord.learn),
            ("Young", c.young, Nord.n14.opacity(0.55)), ("Mature", c.mature, Nord.review),
            ("Suspended", c.suspended + c.buried, Nord.n13),
        ]
        let total = max(1, c.total)
        return VStack(alignment: .leading, spacing: 10) {
            GeometryReader { g in
                HStack(spacing: 2) {
                    ForEach(parts.filter { $0.1 > 0 }, id: \.0) { p in
                        p.2.frame(width: max(3, (g.size.width - 8) * CGFloat(p.1) / CGFloat(total)))
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 8)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), alignment: .leading)], alignment: .leading, spacing: 6) {
                ForEach(parts, id: \.0) { p in
                    HStack(spacing: 5) {
                        Circle().fill(p.2).frame(width: 7, height: 7)
                        Text(p.0).foregroundStyle(Nord.secondary)
                        Text("\(p.1)").foregroundStyle(Nord.text)
                    }
                    .lineLimit(1)
                }
                Text("\(c.total) total").foregroundStyle(Nord.secondary)
            }
            .font(.system(size: 11, design: .monospaced))
        }
    }
}
