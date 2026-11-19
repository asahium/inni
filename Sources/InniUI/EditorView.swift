import InniCore
import SwiftUI
import UniformTypeIdentifiers

struct EditorView: View {
    enum Mode: Equatable {
        case add(DeckID?)
        case edit(NoteID)
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let mode: Mode
    var embedded = false
    var onSave: () -> Void = {}

    @State private var notetypeID: NotetypeID = 0
    @State private var deckID: DeckID = 1
    @State private var fields: [String] = []
    @State private var selections: [TextSelection?] = []
    @State private var tags = ""
    @State private var note: Note?
    @State private var status: String?
    @State private var importing: UTType?
    @FocusState private var focused: Int?

    init(mode: Mode, embedded: Bool = false, onSave: @escaping () -> Void = {}) {
        self.mode = mode
        self.embedded = embedded
        self.onSave = onSave
    }

    private var isDirty: Bool {
        guard let note else { return false }
        return note.fields != fields || note.tags != Note.splitTags(tags)
    }

    private var col: Collection? { model.col }
    private var notetype: Notetype? { col?.notetypes[notetypeID] }
    private var isAdd: Bool { if case .add = mode { true } else { false } }

    var body: some View {
        NordForm {
            if isAdd {
                Section {
                    Picker("Type", selection: $notetypeID) {
                        ForEach(col?.sortedNotetypes ?? []) { Text($0.name).tag($0.id) }
                    }
                    Picker("Deck", selection: $deckID) {
                        ForEach((col?.sortedDecks ?? []).filter { !$0.isFiltered }) { Text($0.name.replacingOccurrences(of: "::", with: " › ")).tag($0.id) }
                    }
                }
            }
            if let nt = notetype {
                Section {
                    ForEach(Array(nt.fields.enumerated()), id: \.offset) { i, f in
                        if i < fields.count { fieldEditor(i, f) }
                    }
                    if let dup = duplicateNote {
                        Label("Duplicate of an existing note (\(dup))", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(Nord.n12).font(.caption)
                    }
                } footer: {
                    HStack {
                        if nt.isCloze {
                            Button("Cloze") { insertCloze(same: false) }.keyboardShortcut("c", modifiers: [.command, .shift])
                            Button("Same Cloze") { insertCloze(same: true) }.keyboardShortcut("c", modifiers: [.command, .shift, .option])
                        }
                        Button("Image…") { importing = .image }
                        Button("Audio…") { importing = .audio }
                    }
                    .buttonStyle(.borderless)
                }
                Section("Tags") {
                    TextField("space separated", text: $tags)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                }
            }
            if let status {
                Text(status).foregroundStyle(.secondary).font(.caption)
            }
            if embedded {
                Button("Save") { save() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!isDirty)
            }
        }
        .navigationTitle(isAdd ? "Add" : "Edit Note")
        .toolbar {
            if !embedded {
                ToolbarItem(placement: .cancellationAction) { Button(isAdd ? "Close" : "Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isAdd ? "Add" : "Save") { save() }
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(fields.first?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                }
            }
        }
        .onAppear(perform: load)
        .onDisappear { if embedded, isDirty { save() } }
        .onChange(of: notetypeID) { old, new in
            guard old != 0, old != new, let nt = col?.notetypes[new] else { return }
            // Keep fields by position when switching type while adding.
            fields = (0..<nt.fields.count).map { $0 < fields.count ? fields[$0] : "" }
            selections = Array(repeating: nil, count: nt.fields.count)
        }
        .fileImporter(isPresented: Binding(get: { importing != nil }, set: { if !$0 { importing = nil } }),
                      allowedContentTypes: [importing ?? .item]) { result in
            if case .success(let url) = result { attach(url) }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 420)
        #endif
    }

    private func fieldEditor(_ i: Int, _ f: Notetype.Field) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(f.name).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if isAdd {
                    Button { toggleSticky(i) } label: {
                        Image(systemName: f.sticky ? "pin.fill" : "pin").font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .help("Keep this field's text after adding")
                }
            }
            TextEditor(text: $fields[i], selection: $selections[i])
                .font(.system(size: 15))
                .frame(minHeight: f.name == notetype?.fields.first?.name ? 60 : 44)
                .scrollContentBackground(.hidden)
                .focused($focused, equals: i)
                .autocorrectionDisabled()
        }
    }

    private var duplicateNote: NoteID? {
        guard let col, let nt = notetype, !(fields.first ?? "").isEmpty else { return nil }
        var probe = Note(notetypeID: nt.id, fields: fields)
        if let note { probe.id = note.id }
        return col.duplicates(of: probe).first { $0 != note?.id }
    }

    private func load() {
        guard let col else { return }
        switch mode {
        case .add(let did):
            let last = col.configInt("curModel").flatMap { col.notetypes[$0] } ?? col.sortedNotetypes.first
            notetypeID = last?.id ?? 0
            let d = did ?? col.currentDeckID
            deckID = col.decks[d].map { $0.isFiltered ? 1 : $0.id } ?? 1
            fields = Array(repeating: "", count: last?.fields.count ?? 0)
            tags = UserDefaults.standard.string(forKey: "lastTags") ?? ""
        case .edit(let nid):
            guard let n = col.note(nid) else { return }
            note = n
            notetypeID = n.notetypeID
            let count = col.notetypes[n.notetypeID]?.fields.count ?? n.fields.count
            fields = (0..<count).map { $0 < n.fields.count ? n.fields[$0] : "" }
            tags = n.tags.joined(separator: " ")
        }
        selections = Array(repeating: nil, count: fields.count)
        focused = 0
    }

    private func save() {
        guard let col, let nt = notetype else { return }
        let tagList = Note.splitTags(tags)
        do {
            if var n = note {
                n.fields = fields
                n.tags = tagList
                try col.update(n)
                note = n
                onSave()
                model.refresh()
                if !embedded { dismiss() }
                return
            }
            if nt.isCloze, Cloze.ordinals(in: fields.joined(separator: " ")).isEmpty {
                status = "Cloze notes need at least one {{c1::…}} deletion."
                return
            }
            let added = try col.add(Note(notetypeID: nt.id, tags: tagList, fields: fields), deckID: deckID)
            let cards = col.cards(ofNote: added.id).count
            try col.setConfig("curModel", nt.id)
            try col.setConfig("curDeck", deckID)
            UserDefaults.standard.set(tags, forKey: "lastTags")
            status = cards == 0 ? "Added, but no cards were generated — check the templates." : "Added (\(cards) card\(cards == 1 ? "" : "s"))."
            for (i, f) in nt.fields.enumerated() where !f.sticky && i < fields.count { fields[i] = "" }
            focused = 0
            onSave()
            model.refresh()
        } catch {
            status = error.localizedDescription
        }
    }

    private func toggleSticky(_ i: Int) {
        guard var nt = notetype, i < nt.fields.count else { return }
        nt.fields[i].sticky.toggle()
        model.perform { _ = try $0.save(nt) }
    }

    private func insertCloze(same: Bool) {
        let i = focused ?? 0
        guard i < fields.count else { return }
        let existing = Cloze.ordinals(in: fields.joined(separator: " ")).max() ?? 0
        let n = same ? max(existing, 1) : existing + 1
        wrap(i, "{{c\(n)::", "}}")
    }

    /// Wraps the selection (or inserts at the cursor) in field `i`.
    private func wrap(_ i: Int, _ before: String, _ after: String) {
        var text = fields[i]
        if case .selection(let range)? = selections[i]?.indices, range.lowerBound >= text.startIndex, range.upperBound <= text.endIndex {
            let inner = String(text[range])
            text.replaceSubrange(range, with: before + inner + after)
        } else if case .multiSelection(let set)? = selections[i]?.indices, let range = set.ranges.first {
            text.replaceSubrange(range, with: before + String(text[range]) + after)
        } else {
            text += before + after
        }
        fields[i] = text
        selections[i] = nil
    }

    private func attach(_ url: URL) {
        guard let col else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let name = try MediaFiles.add(Data(contentsOf: url), preferredName: url.lastPathComponent, to: col.mediaFolder)
            let isImage = UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
            let tag = isImage ? "<img src=\"\(HTML.escape(name))\">" : "[sound:\(name)]"
            let i = focused ?? 0
            if i < fields.count { wrap(i, tag, "") }
        } catch {
            status = error.localizedDescription
        }
    }
}
