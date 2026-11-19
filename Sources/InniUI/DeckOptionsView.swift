import InniCore
import SwiftUI

struct DeckOptionsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let deckID: DeckID
    @State private var deck: Deck?
    @State private var conf: DeckConfig?
    @State private var learn = ""
    @State private var relearn = ""
    @State private var fsrs = false
    @State private var newPresetName = ""
    @State private var naming = false
    @State private var stepsError: String?

    var body: some View {
        NordForm {
            if let deck, conf != nil {
                Section {
                    Picker("Preset", selection: Binding(get: { conf!.id }, set: switchPreset)) {
                        ForEach((model.col?.deckConfigs.values.sorted { $0.name < $1.name }) ?? []) { c in
                            Text("\(c.name) (\(usage(c.id)))").tag(c.id)
                        }
                    }
                    Button("New Preset…") { newPresetName = ""; naming = true }
                } footer: {
                    Text("Changes apply to every deck using “\(conf!.name)”.")
                }
                Section("Daily Limits") {
                    stepper("New cards/day", \.newPerDay, 0...9999)
                    stepper("Maximum reviews/day", \.reviewsPerDay, 0...99999)
                }
                Section {
                    LabeledContent("Learning steps") {
                        TextField("1m 10m", text: $learn).multilineTextAlignment(.trailing).autocorrectionDisabled()
                    }
                    LabeledContent("Relearning steps") {
                        TextField("10m", text: $relearn).multilineTextAlignment(.trailing).autocorrectionDisabled()
                    }
                    stepper("Graduating interval", \.graduatingInterval, 1...365, unit: "d")
                    stepper("Easy interval", \.easyInterval, 1...365, unit: "d")
                    if let stepsError { Text(stepsError).foregroundStyle(Nord.n11).font(.caption) }
                } header: {
                    Text("Steps")
                } footer: {
                    Text("Space separated, e.g. 1m 10m 1h 1d.")
                }
                Section("Lapses") {
                    stepper("Leech threshold", \.leechThreshold, 1...99)
                    Picker("Leech action", selection: binding(\.leechAction)) {
                        Text("Suspend Card").tag(DeckConfig.LeechAction.suspend)
                        Text("Tag Only").tag(DeckConfig.LeechAction.tagOnly)
                    }
                    stepper("Minimum interval", \.minimumLapseInterval, 1...365, unit: "d")
                }
                Section("Burying") {
                    Toggle("Bury new siblings", isOn: binding(\.buryNew))
                    Toggle("Bury review siblings", isOn: binding(\.buryReviews))
                    Toggle("Bury interday learning siblings", isOn: binding(\.buryInterdayLearning))
                }
                Section("Audio & Timer") {
                    Toggle("Don't play audio automatically", isOn: binding(\.disableAutoplay))
                    Toggle("Show answer timer", isOn: binding(\.showTimer))
                }
                Section {
                    Toggle("FSRS", isOn: $fsrs)
                    if fsrs {
                        LabeledContent("Desired retention") {
                            HStack {
                                Slider(value: binding(\.desiredRetention), in: 0.7...0.99, step: 0.01)
                                Text(String(format: "%.2f", conf!.desiredRetention)).monospacedDigit().frame(width: 40)
                            }
                        }
                        LabeledContent("Parameters", value: conf!.fsrsParams.isEmpty ? "default" : "\(conf!.fsrsParams.count) custom")
                    } else {
                        stepper("Maximum interval", \.maximumInterval, 1...36500, unit: "d")
                        decimal("Starting ease", \.initialEase, 1.31...5, step: 0.05)
                        decimal("Easy bonus", \.easyMultiplier, 1...5, step: 0.05)
                        decimal("Interval modifier", \.intervalMultiplier, 0.5...2, step: 0.05)
                        decimal("Hard interval", \.hardMultiplier, 0.5...1.3, step: 0.05)
                        decimal("New interval", \.lapseMultiplier, 0...1, step: 0.05)
                    }
                } header: {
                    Text("Scheduler")
                } footer: {
                    Text(fsrs ? "FSRS applies to the whole collection. Parameters trained in Anki are used as-is." :
                        "SM-2, Anki's classic algorithm. FSRS applies to the whole collection.")
                }
                if !deck.description.isEmpty {
                    Section("Description") { Text(deck.description).font(.caption) }
                }
            }
        }
        .navigationTitle(deck?.leafName ?? "Options")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("Save") { save() } }
        }
        .alert("New Preset", isPresented: $naming) {
            TextField("Name", text: $newPresetName)
            Button("Cancel", role: .cancel) {}
            Button("Create") { createPreset() }
        }
        .onAppear(perform: load)
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 560)
        #endif
    }

    private func usage(_ id: DeckConfigID) -> Int {
        model.col?.decks.values.filter { !$0.isFiltered && $0.configID == id }.count ?? 0
    }

    private func binding<T>(_ kp: WritableKeyPath<DeckConfig, T>) -> Binding<T> {
        Binding(get: { conf![keyPath: kp] }, set: { conf![keyPath: kp] = $0 })
    }

    private func stepper(_ title: String, _ kp: WritableKeyPath<DeckConfig, Int>, _ range: ClosedRange<Int>, unit: String = "") -> some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                TextField("", value: binding(kp), format: .number)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 70)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                if !unit.isEmpty { Text(unit).foregroundStyle(.secondary) }
                Stepper("", value: binding(kp), in: range).labelsHidden()
            }
        }
    }

    private func decimal(_ title: String, _ kp: WritableKeyPath<DeckConfig, Float>, _ range: ClosedRange<Float>, step: Float) -> some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                Text(String(format: "%.2f", conf![keyPath: kp])).monospacedDigit()
                Stepper("", value: binding(kp), in: range, step: step).labelsHidden()
            }
        }
    }

    private func load() {
        guard let col = model.col, let d = col.decks[deckID] else { return }
        deck = d
        let c = col.config(for: d)
        conf = c
        learn = Steps.format(c.learnSteps)
        relearn = Steps.format(c.relearnSteps)
        fsrs = col.fsrsEnabled
    }

    private func switchPreset(_ id: DeckConfigID) {
        guard let c = model.col?.deckConfigs[id] else { return }
        conf = c
        learn = Steps.format(c.learnSteps)
        relearn = Steps.format(c.relearnSteps)
    }

    private func createPreset() {
        guard var c = conf, !newPresetName.isEmpty else { return }
        c.id = 0
        c.name = newPresetName
        model.perform { col in conf = try col.save(c) }
    }

    private func save() {
        guard var c = conf, var d = deck else { return }
        guard let l = Steps.parse(learn), let r = Steps.parse(relearn) else {
            stepsError = "Steps must look like 1m 10m 1h 2d."
            return
        }
        c.learnSteps = l
        c.relearnSteps = r
        model.perform { col in
            let saved = try col.save(c)
            if d.configID != saved.id {
                d.configID = saved.id
                _ = try col.save(d)
            }
            if col.fsrsEnabled != fsrs { try col.setConfig("fsrs", fsrs) }
        }
        dismiss()
    }
}

/// Learning steps in minutes, written like Anki ("1m 10m 1d").
enum Steps {
    static func format(_ steps: [Float]) -> String {
        steps.map { m -> String in
            if m < 1 { return "\(Int((m * 60).rounded()))s" }
            if m >= 1440, m.truncatingRemainder(dividingBy: 1440) == 0 { return "\(Int(m / 1440))d" }
            if m >= 60, m.truncatingRemainder(dividingBy: 60) == 0 { return "\(Int(m / 60))h" }
            return m == m.rounded() ? "\(Int(m))m" : "\(m)m"
        }.joined(separator: " ")
    }

    static func parse(_ s: String) -> [Float]? {
        var out: [Float] = []
        for tok in s.split(whereSeparator: \.isWhitespace) {
            var t = tok.lowercased()
            var mult: Float = 1
            switch t.last {
            case "s": mult = 1 / 60; t.removeLast()
            case "m": t.removeLast()
            case "h": mult = 60; t.removeLast()
            case "d": mult = 1440; t.removeLast()
            default: break
            }
            guard let v = Float(t), v > 0 else { return nil }
            out.append(v * mult)
        }
        return out
    }
}
