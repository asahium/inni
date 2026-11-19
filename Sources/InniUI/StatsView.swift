import Charts
import InniCore
import SwiftUI

struct StatsView: View {
    @Environment(AppModel.self) private var model
    @State private var deck: DeckID? = nil
    @State private var days = 30

    var body: some View {
        let s = model.col?.stats(deckID: deck, days: days) ?? CollectionStats()
        NordForm {
            Section {
                Picker("Deck", selection: $deck) {
                    Text("Whole collection").tag(DeckID?.none)
                    ForEach(model.col?.sortedDecks ?? []) { Text($0.name.replacingOccurrences(of: "::", with: " › ")).tag(DeckID?.some($0.id)) }
                }
                Picker("Period", selection: $days) {
                    Text("1 month").tag(30)
                    Text("3 months").tag(90)
                    Text("1 year").tag(365)
                }
                .pickerStyle(.segmented)
            }
            Section("Today") {
                if s.today.reviews == 0 {
                    Text("No cards have been studied today.").foregroundStyle(.secondary)
                } else {
                    LabeledContent("Studied", value: "\(s.today.reviews) cards in \(minutes(s.today.seconds))")
                    LabeledContent("Again", value: "\(s.today.again) (\(percent(1 - Double(s.today.again) / Double(max(1, s.today.reviews)))) correct)")
                    LabeledContent("Learn · Review · Relearn", value: "\(s.today.learn) · \(s.today.review) · \(s.today.relearn)")
                }
            }
            Section("Forecast") {
                Chart(s.forecast) { d in
                    BarMark(x: .value("Day", d.day), y: .value("Learning", d.learn)).foregroundStyle(by: .value("Kind", "Learning"))
                    BarMark(x: .value("Day", d.day), y: .value("Young", d.young)).foregroundStyle(by: .value("Kind", "Young"))
                    BarMark(x: .value("Day", d.day), y: .value("Mature", d.mature)).foregroundStyle(by: .value("Kind", "Mature"))
                }
                .chartForegroundStyleScale(["Learning": Nord.learn, "Young": Nord.n14.opacity(0.6), "Mature": Nord.review])
                .frame(height: 160)
                LabeledContent("Due tomorrow", value: "\(s.forecast.dropFirst().first?.total ?? 0)")
                LabeledContent("Daily average", value: String(format: "%.1f", Double(s.forecast.map(\.total).reduce(0, +)) / Double(max(1, days))))
            }
            Section("Reviews") {
                Chart(s.history) { d in
                    BarMark(x: .value("Day", d.day), y: .value("Learn", d.learn)).foregroundStyle(by: .value("Kind", "Learn"))
                    BarMark(x: .value("Day", d.day), y: .value("Relearn", d.relearn)).foregroundStyle(by: .value("Kind", "Relearn"))
                    BarMark(x: .value("Day", d.day), y: .value("Young", d.young)).foregroundStyle(by: .value("Kind", "Young"))
                    BarMark(x: .value("Day", d.day), y: .value("Mature", d.mature)).foregroundStyle(by: .value("Kind", "Mature"))
                }
                .chartForegroundStyleScale(["Learn": Nord.new, "Relearn": Nord.n11, "Young": Nord.n14.opacity(0.6), "Mature": Nord.review])
                .frame(height: 160)
                LabeledContent("Days studied", value: "\(s.studyDays) of \(days)")
                LabeledContent("Total", value: "\(s.history.map(\.total).reduce(0, +)) reviews")
                if let y = s.youngRetention { LabeledContent("Young retention", value: percent(y)) }
                if let m = s.matureRetention { LabeledContent("Mature retention", value: percent(m)) }
            }
            Section("Cards") {
                Chart {
                    SectorMark(angle: .value("New", s.counts.new)).foregroundStyle(Nord.new)
                    SectorMark(angle: .value("Learning", s.counts.learning + s.counts.relearning)).foregroundStyle(Nord.learn)
                    SectorMark(angle: .value("Young", s.counts.young)).foregroundStyle(Nord.n14.opacity(0.6))
                    SectorMark(angle: .value("Mature", s.counts.mature)).foregroundStyle(Nord.review)
                    SectorMark(angle: .value("Suspended", s.counts.suspended + s.counts.buried)).foregroundStyle(Nord.n13)
                }
                .frame(height: 140)
                LabeledContent("New", value: "\(s.counts.new)")
                LabeledContent("Learning", value: "\(s.counts.learning + s.counts.relearning)")
                LabeledContent("Young", value: "\(s.counts.young)")
                LabeledContent("Mature", value: "\(s.counts.mature)")
                LabeledContent("Suspended · Buried", value: "\(s.counts.suspended) · \(s.counts.buried)")
                LabeledContent("Total", value: "\(s.counts.total)")
            }
        }
        .navigationTitle("Statistics")
    }

    private func minutes(_ secs: Int) -> String {
        secs < 60 ? "\(secs)s" : "\(secs / 60) min"
    }

    private func percent(_ v: Double) -> String {
        String(format: "%.1f%%", v * 100)
    }
}
