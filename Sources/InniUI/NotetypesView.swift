import InniCore
import SwiftUI

struct NotetypesView: View {
    @Environment(AppModel.self) private var model
    @State private var cloning: Notetype?
    @State private var name = ""
    @State private var deleting: Notetype?

    var body: some View {
        List {
            ForEach(model.col?.sortedNotetypes ?? []) { nt in
                NavigationLink {
                    NotetypeEditor(id: nt.id)
                } label: {
                    HStack {
                        Image(systemName: "list.bullet.rectangle").foregroundStyle(Nord.n7)
                        Text(nt.name).foregroundStyle(Nord.text)
                        Spacer()
                        Text("\(noteCount(nt.id)) notes").foregroundStyle(Nord.secondary)
                    }
                    .font(Nord.listFont)
                }
                .listRowBackground(Nord.background)
                .contextMenu {
                    Button("Clone…") { name = nt.name + " copy"; cloning = nt }
                    Button("Delete", role: .destructive) { deleting = nt }
                }
            }
        }
        .nordList()
        .navigationTitle("Note Types")
        .alert("Clone Note Type", isPresented: Binding(get: { cloning != nil }, set: { if !$0 { cloning = nil } })) {
            TextField("Name", text: $name)
            Button("Cancel", role: .cancel) {}
            Button("Clone") {
                guard var nt = cloning else { return }
                nt.id = 0
                nt.name = name
                model.perform { _ = try $0.save(nt) }
            }
        }
        .confirmationDialog(deleting.map { "Delete “\($0.name)” and its \(noteCount($0.id)) notes?" } ?? "",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) { if let nt = deleting { model.perform { try $0.remove(notetype: nt.id) } } }
        }
    }

    private func noteCount(_ id: NotetypeID) -> Int {
        let _ = model.revision
        return (try? model.col?.findNotes("mid:\(id)").count) ?? 0
    }
}

struct NotetypeEditor: View {
    @Environment(AppModel.self) private var model
    let id: NotetypeID
    @State private var nt: Notetype?
    @State private var template = 0
    @State private var side = 0
    @State private var newField = ""
    @State private var status: String?

    var body: some View {
        NordForm {
            if nt != nil {
                Section("Name") { TextField("Name", text: Binding(get: { nt!.name }, set: { nt!.name = $0 })) }
                Section {
                    ForEach(Array(nt!.fields.enumerated()), id: \.offset) { i, _ in
                        HStack {
                            TextField("Field", text: Binding(get: { nt!.fields[i].name }, set: { nt!.fields[i].name = $0 }))
                            if nt!.sortFieldIndex == i { Text("sort").font(.caption).foregroundStyle(.secondary) }
                        }
                        .contextMenu {
                            Button("Sort by This Field") { nt!.sortFieldIndex = i }
                            if i > 0 { Button("Move Up") { nt!.fields.swapAt(i, i - 1) } }
                            if nt!.fields.count > 1 { Button("Remove", role: .destructive) { nt!.fields.remove(at: i) } }
                        }
                    }
                    .onMove { nt!.fields.move(fromOffsets: $0, toOffset: $1) }
                    .onDelete { if nt!.fields.count > $0.count { nt!.fields.remove(atOffsets: $0) } }
                    HStack {
                        TextField("New field", text: $newField)
                        Button("Add") {
                            nt!.fields.append(Notetype.Field(ord: -1, name: newField))
                            newField = ""
                        }
                        .disabled(newField.isEmpty || nt!.fieldIndex(newField) != nil)
                    }
                } header: {
                    Text("Fields")
                } footer: {
                    Text("Renaming a field here doesn't rewrite templates that use the old name.")
                }
                Section("Cards") {
                    if !nt!.isCloze {
                        Picker("Card type", selection: $template) {
                            ForEach(Array(nt!.templates.enumerated()), id: \.offset) { i, t in Text(t.name).tag(i) }
                        }
                    }
                    Picker("", selection: $side) {
                        Text("Front").tag(0)
                        Text("Back").tag(1)
                        Text("Styling").tag(2)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    TextEditor(text: templateText)
                        .font(.system(.callout, design: .monospaced))
                        .frame(minHeight: 180)
                        .autocorrectionDisabled()
                    if !nt!.isCloze {
                        HStack {
                            Button("Add Card Type") {
                                let n = nt!.templates.count + 1
                                let first = nt!.fields.first?.name ?? "Front"
                                nt!.templates.append(Notetype.Template(ord: -1, name: "Card \(n)", front: "{{\(first)}}",
                                                                       back: "{{FrontSide}}\n\n<hr id=answer>\n\n"))
                                template = n - 1
                            }
                            if nt!.templates.count > 1 {
                                Button("Remove", role: .destructive) {
                                    nt!.templates.remove(at: template)
                                    template = 0
                                }
                            }
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Section("Preview") {
                    PreviewWebView(html: previewHTML, folder: model.col?.mediaFolder).frame(height: 220)
                }
                if let status { Text(status).foregroundStyle(Nord.n11).font(.caption) }
            }
        }
        .navigationTitle(nt?.name ?? "")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.keyboardShortcut("s", modifiers: .command) }
        }
        .onAppear { nt = model.col?.notetypes[id] }
    }

    private var templateText: Binding<String> {
        Binding(get: {
            guard let nt, template < nt.templates.count else { return "" }
            switch side {
            case 0: return nt.templates[template].front
            case 1: return nt.templates[template].back
            default: return nt.css
            }
        }, set: { v in
            guard nt != nil, template < nt!.templates.count else { return }
            switch side {
            case 0: nt!.templates[template].front = v
            case 1: nt!.templates[template].back = v
            default: nt!.css = v
            }
        })
    }

    private var previewHTML: String {
        guard let nt, let col = model.col, template < nt.templates.count else { return "" }
        // Render a sample note whose fields show their own names.
        var note = Note(notetypeID: nt.id, fields: nt.fields.map { "(\($0.name))" })
        if nt.isCloze, !note.fields.isEmpty { note.fields[0] = "{{c1::(\(nt.fields[0].name))}}" }
        note.id = -1
        let card = Card(id: -1, noteID: -1, deckID: 1, ord: nt.isCloze ? 0 : template, due: 0)
        let r = CardRenderer.render(card, note: note, in: col, notetype: nt)
        return CardRenderer.page(side == 1 ? r.answer : r.question, card: r, night: true, platform: Platform.css)
    }

    private func save() {
        guard var nt else { return }
        for i in nt.fields.indices { nt.fields[i].ord = i }
        for i in nt.templates.indices { nt.templates[i].ord = i }
        model.perform { self.nt = try $0.save(nt) }
        status = nil
    }
}
