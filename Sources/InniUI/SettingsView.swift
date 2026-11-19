import InniCore
import SwiftUI

public struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("fontScale") private var fontScale = 1.0
    @State private var backups: [URL] = []
    @State private var restoring: URL?

    public init() {}

    public var body: some View {
        NordForm {
            Section("Review") {
                LabeledContent("Card text size") {
                    HStack {
                        Slider(value: $fontScale, in: 0.7...2, step: 0.05)
                        Text("\(Int(fontScale * 100))%").monospacedDigit().frame(width: 48)
                    }
                }
            }
            SyncSettingsSection()
            if let col = model.col {
                Section("Scheduling") {
                    Picker("Next day starts at", selection: Binding(
                        get: { col.configInt("rollover") ?? 4 },
                        set: { v in model.perform { try $0.setConfig("rollover", v) } })) {
                        ForEach(0..<24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) }
                    }
                    Picker("Learn ahead limit", selection: Binding(
                        get: { (col.configInt("collapseTime") ?? 1200) / 60 },
                        set: { v in model.perform { try $0.setConfig("collapseTime", v * 60) } })) {
                        ForEach([0, 5, 10, 20, 30, 60], id: \.self) { Text("\($0) min").tag($0) }
                    }
                }
                Section {
                    LabeledContent("Notes", value: "\(col.noteCount())")
                    LabeledContent("Cards", value: "\(col.cardCount())")
                    LabeledContent("File", value: col.url.path).font(.caption).textSelection(.enabled)
                    #if os(macOS)
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([col.url]) }
                    #endif
                } header: {
                    Text("Collection")
                } footer: {
                    Text("Inni reads and writes Anki's collection format directly, so this file also opens in Anki.")
                }
                #if os(macOS)
                if !AppModel.ankiProfiles.isEmpty {
                    Section {
                        ForEach(AppModel.ankiProfiles, id: \.self) { url in
                            Button("Open Anki profile “\(url.deletingLastPathComponent().lastPathComponent)”") { model.open(url) }
                        }
                        Button("Open Inni collection") { model.open(AppModel.defaultURL, create: true) }
                    } header: {
                        Text("Anki")
                    } footer: {
                        Text("Quit Anki first: only one app can have a collection open.")
                    }
                }
                #endif
                if !backups.isEmpty {
                    Section("Backups") {
                        ForEach(backups, id: \.self) { b in
                            HStack {
                                Text(b.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "backup-", with: ""))
                                Spacer()
                                Button("Restore…") { restoring = b }.buttonStyle(.borderless)
                            }
                        }
                    }
                }
            }
            Section("About") {
                LabeledContent("Inni", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
                Text("An Anki-compatible flashcard app: SM-2 and FSRS scheduling, .apkg/.colpkg import and export.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
        .onAppear(perform: loadBackups)
        .onChange(of: model.revision) { _, _ in loadBackups() }
        .confirmationDialog("Replace the collection with this backup? The current one is kept as a backup too.",
                            isPresented: Binding(get: { restoring != nil }, set: { if !$0 { restoring = nil } }),
                            titleVisibility: .visible) {
            Button("Restore", role: .destructive) { if let b = restoring { restore(b) } }
        }
    }

    private func loadBackups() {
        guard let folder = model.backupFolder else { return }
        backups = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("backup-") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    private func restore(_ backup: URL) {
        guard let url = model.col?.url else { return }
        let fm = FileManager.default
        model.close()
        do {
            let keep = url.deletingPathExtension().appendingPathExtension("before-restore-\(Int(Date().timeIntervalSince1970)).anki2")
            try fm.moveItem(at: url, to: keep)
            for s in ["-wal", "-shm"] { try? fm.removeItem(atPath: url.path + s) }
            try fm.copyItem(at: backup, to: url)
        } catch {
            model.error = error.localizedDescription
        }
        model.open(url)
    }
}
