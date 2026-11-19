import InniCore
import Observation
import SwiftUI

@MainActor @Observable
final class ReviewSession {
    let col: Collection
    let scheduler: Scheduler
    private(set) var card: Card?
    private(set) var rendered: RenderedCard?
    private(set) var answerShown = false
    private(set) var labels: [Rating: String] = [:]
    private(set) var counts = DeckCounts()
    private(set) var nextLearning: Date?
    private(set) var reviewedToday = 0
    var fontScale = Prefs.fontScale
    private var shownAt = Date()
    private var config: DeckConfig?

    init(col: Collection, deckID: DeckID) {
        self.col = col
        scheduler = Scheduler(col: col, deckID: deckID)
        if col.currentDeckID != deckID { col.currentDeckID = deckID }
        CardWeb.shared.onMessage = { [weak self] msg in self?.handle(msg) }
        AudioPlayer.shared.folder = col.mediaFolder
        advance()
    }

    var deckName: String { col.decks[scheduler.deckID]?.name ?? "" }

    /// Which count the current card belongs to: 0 new, 1 learning, 2 review.
    var currentKind: Int? {
        guard let card else { return nil }
        switch card.queue {
        case .new: return 0
        case .learning, .dayLearning, .preview: return 1
        default: return 2
        }
    }

    var usesTyping: Bool { rendered?.typeAnswer != nil && !answerShown }

    func advance() {
        AudioPlayer.shared.stop()
        card = scheduler.next()
        counts = scheduler.counts
        nextLearning = card == nil ? scheduler.nextLearningDue : nil
        guard let card, let note = col.note(card.noteID) else {
            rendered = nil
            return
        }
        config = col.decks[card.homeDeckID].map { col.config(for: $0) }
        rendered = CardRenderer.render(card, note: note, in: col)
        labels = scheduler.intervalLabels(for: card)
        answerShown = false
        showSide()
        shownAt = Date()
        if config?.disableAutoplay != true { AudioPlayer.shared.play(rendered?.questionAudio ?? []) }
    }

    private func showSide(typed: String = "") {
        guard let r = rendered else { return }
        let body = answerShown ? r.answer(typed: typed) : r.question
        let html = CardRenderer.page(body + (answerShown ? "<script>document.getElementById('answer')?.scrollIntoView();</script>" : ""),
                                     card: r, night: true, platform: Platform.css, fontScale: fontScale)
        CardWeb.shared.load(html, folder: col.mediaFolder)
    }

    func rerender() {
        guard card != nil else { return }
        Task { showSide(typed: answerShown ? await CardWeb.shared.typed() : "") }
    }

    /// Re-reads the note after an edit.
    func reloadCurrent() {
        guard let c = card, let fresh = col.card(c.id), let note = col.note(fresh.noteID) else { return advance() }
        card = fresh
        rendered = CardRenderer.render(fresh, note: note, in: col)
        showSide()
    }

    func showAnswer() {
        guard card != nil, !answerShown else { return }
        Task {
            let typed = rendered?.typeAnswer != nil ? await CardWeb.shared.typed() : ""
            answerShown = true
            showSide(typed: typed)
            if config?.disableAutoplay != true { AudioPlayer.shared.play(answerAudio(replay: false)) }
        }
    }

    /// Audio on the answer side, without the question's own sounds that came in through {{FrontSide}}.
    private func answerAudio(replay: Bool) -> [RenderedCard.Audio] {
        guard let r = rendered else { return [] }
        let q = r.questionAudio
        let includesQuestion = replay && config?.config.bool(26) != true
        if !includesQuestion, r.answerAudio.starts(with: q) { return Array(r.answerAudio.dropFirst(q.count)) }
        return r.answerAudio
    }

    func answer(_ rating: Rating) {
        guard let card, answerShown else { return }
        let cap = max(config?.capAnswerTimeSecs ?? 60, 1)
        let millis = min(Int(Date().timeIntervalSince(shownAt) * 1000), cap * 1000)
        do {
            _ = try scheduler.answer(card, rating: rating, millis: millis)
            reviewedToday += 1
        } catch {
            NSLog("answer failed: \(error)")
        }
        advance()
    }

    func undo() {
        guard scheduler.canUndo else { return }
        _ = try? scheduler.undo()
        reviewedToday = max(0, reviewedToday - 1)
        advance()
    }

    func replay() {
        guard rendered != nil else { return }
        AudioPlayer.shared.play(answerShown ? answerAudio(replay: true) : rendered?.questionAudio ?? [])
    }

    func act(_ body: (Collection, Card) throws -> Void) {
        guard let card else { return }
        try? body(col, card)
        scheduler.drop(card.id)
        scheduler.rebuild()
        advance()
    }

    func setFlag(_ f: Int) {
        guard let c = card else { return }
        try? col.setFlag([c.id], flag: c.flag == f ? 0 : f)
        card = col.card(c.id)
    }

    private func handle(_ msg: [String: Any]) {
        switch msg["action"] as? String {
        case "showAnswer": showAnswer()
        case "play":
            guard let r = rendered, let i = msg["index"] as? Int else { return }
            let list = (msg["side"] as? String) == "a" ? r.answerAudio : r.questionAudio
            if list.indices.contains(i) { AudioPlayer.shared.play([list[i]]) }
        case "pycmd":
            if (msg["cmd"] as? String) == "ans" { showAnswer() }
        default: break
        }
    }
}

struct ReviewerView: View {
    @Environment(AppModel.self) private var model
    @State var session: ReviewSession
    @State private var editing: NoteID?
    @State private var confirmDelete = false

    var body: some View {
        VStack(spacing: 0) {
            if session.card != nil {
                CardWebView()
                bottomBar
            } else {
                finished
            }
        }
        .background(Nord.background)
        .background { Button("") { model.study = nil }.keyboardShortcut(.escape, modifiers: []).hidden() }
        .navigationTitle(session.deckName.components(separatedBy: "::").last ?? "")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Nord.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        #endif
        .toolbar { toolbar }
        .onAppear {
            session.rerender()
            if UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)["InniShowAnswer"] != nil {
                Task { try? await Task.sleep(for: .seconds(1)); session.showAnswer() }
            }
        }
        .onDisappear {
            AudioPlayer.shared.stop()
            model.refresh()
        }
        .sheet(item: $editing) { nid in
            NavigationStack { EditorView(mode: .edit(nid)) { session.reloadCurrent() } }
                .environment(model)
        }
        .confirmationDialog("Delete this note and all its cards?", isPresented: $confirmDelete) {
            Button("Delete Note", role: .destructive) { session.act { col, c in try col.remove(notes: [c.noteID]) } }
        }
        .task(id: session.nextLearning) {
            guard let due = session.nextLearning else { return }
            try? await Task.sleep(for: .seconds(max(1, due.timeIntervalSinceNow + 1)))
            session.scheduler.rebuild()
            session.advance()
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            HStack {
                CountsView(new: session.counts.new, learn: session.counts.learning, review: session.counts.review,
                           highlight: session.currentKind)
                Spacer()
                if session.reviewedToday > 0 {
                    Text("\(session.reviewedToday) done").font(Nord.mono).foregroundStyle(Nord.secondary)
                }
                if let f = session.card?.flag, f > 0 { Image(systemName: "flag.fill").foregroundStyle(Nord.flag(f)) }
            }
            if session.answerShown {
                HStack(spacing: 8) {
                    rateButton(.again, "Again", "1")
                    rateButton(.hard, "Hard", "2")
                    rateButton(.good, "Good", "3")
                    rateButton(.easy, "Easy", "4")
                }
                .background { Button("") { session.answer(.good) }.keyboardShortcut(.space, modifiers: []).hidden() }
            } else {
                Button { session.showAnswer() } label: {
                    HStack {
                        Text("Show Answer").font(.system(size: 14, weight: .semibold))
                        #if os(macOS)
                        Text(session.usesTyping ? "↩" : "space").font(Nord.mono).opacity(0.6)
                        #endif
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(NordButtonStyle(color: Nord.n6))
                .keyboardShortcut(session.usesTyping ? .return : .space, modifiers: [])
                .background { Button("") { session.showAnswer() }.keyboardShortcut(.return, modifiers: []).hidden() }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: 680)
        .frame(maxWidth: .infinity)
        .background(Nord.bar)
        .overlay(alignment: .top) { Nord.separator.frame(height: 1) }
    }

    private func rateButton(_ r: Rating, _ title: String, _ key: Character) -> some View {
        Button { session.answer(r) } label: {
            VStack(spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold))
                HStack(spacing: 5) {
                    Text(session.labels[r] ?? "")
                    #if os(macOS)
                    Text(String(key)).opacity(0.5)
                    #endif
                }
                .font(Nord.mono)
                .opacity(0.85)
            }
            .frame(maxWidth: .infinity, minHeight: 48)
        }
        .buttonStyle(NordButtonStyle(color: Nord.rating(r.rawValue)))
        .keyboardShortcut(KeyEquivalent(key), modifiers: [])
    }

    private var finished: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.seal.fill").font(.system(size: 48)).foregroundStyle(Nord.n14)
            Text("Congratulations! You have finished this deck for now.").font(.title3).foregroundStyle(Nord.n6)
                .multilineTextAlignment(.center)
            if let due = session.nextLearning {
                Text("The next learning card will be ready \(due, style: .relative).").foregroundStyle(Nord.secondary)
            }
            if session.reviewedToday > 0 {
                Text("\(session.reviewedToday) cards studied in this session.").foregroundStyle(Nord.secondary)
            }
            HStack(spacing: 10) {
                if session.scheduler.canUndo {
                    Button { session.undo() } label: { Text("Undo").padding(.horizontal, 16).frame(minHeight: 36) }
                        .buttonStyle(NordButtonStyle(color: Nord.n4))
                        .keyboardShortcut("z", modifiers: .command)
                }
                Button { model.study = nil } label: { Text("Back to Decks").padding(.horizontal, 16).frame(minHeight: 36) }
                    .buttonStyle(NordButtonStyle(color: Nord.accent, prominent: true))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 6)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        #if os(macOS)
        ToolbarItem(placement: .navigation) {
            Button { model.study = nil } label: { Label("Decks", systemImage: "chevron.backward") }
                .help("Back to decks (Esc)")
        }
        #endif
        ToolbarItemGroup(placement: .primaryAction) {
            Button { session.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!session.scheduler.canUndo)
            Button { editing = session.card?.noteID } label: { Label("Edit", systemImage: "pencil") }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(session.card == nil)
            Menu {
                Button("Replay Audio") { session.replay() }.keyboardShortcut("r", modifiers: .command)
                Menu("Flag") {
                    ForEach(1...7, id: \.self) { f in
                        Button { session.setFlag(f) } label: {
                            Label(flagName(f), systemImage: session.card?.flag == f ? "flag.fill" : "flag")
                        }
                        .keyboardShortcut(KeyEquivalent(Character("\(f)")), modifiers: .control)
                    }
                }
                Divider()
                Button("Bury Card") { session.act { col, c in try col.bury([c.id]) } }
                    .keyboardShortcut("-", modifiers: [])
                Button("Bury Note") { session.act { col, c in try col.bury(col.cards(ofNote: c.noteID).map(\.id)) } }
                    .keyboardShortcut("=", modifiers: [])
                Button("Suspend Card") { session.act { col, c in try col.suspend([c.id]) } }
                    .keyboardShortcut("@", modifiers: [.shift])
                Button("Suspend Note") { session.act { col, c in try col.suspend(col.cards(ofNote: c.noteID).map(\.id)) } }
                Button("Forget Card") { session.act { col, c in try col.forget([c.id]) } }
                Divider()
                Button("Delete Note", role: .destructive) { confirmDelete = true }
                    .keyboardShortcut(.delete, modifiers: .command)
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .disabled(session.card == nil)
        }
    }
}

func flagName(_ f: Int) -> String {
    ["", "Red", "Orange", "Green", "Blue", "Pink", "Turquoise", "Purple"][max(0, min(7, f))]
}

extension Int: @retroactive Identifiable {
    public var id: Int { self }
}
