import InniCore
import SwiftUI

struct SyncLoginView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var username = ""
    @State private var password = ""
    @AppStorage("syncServer") private var server = ""
    @State private var showServer = false

    var body: some View {
        NordForm {
            Section {
                TextField("Email", text: $username)
                    .textContentType(.username)
                    #if os(iOS)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .onSubmit(logIn)
            } footer: {
                Text("Your AnkiWeb account. Inni keeps only the sign-in token, not the password.")
            }
            Section {
                DisclosureGroup("Self-hosted server", isExpanded: $showServer) {
                    TextField("https://example.com/", text: $server)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                    Text("Leave empty for AnkiWeb. Works with Anki's sync server (`python -m anki.syncserver`).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Log In to AnkiWeb")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Log In", action: logIn).disabled(username.isEmpty || password.isEmpty)
            }
        }
        .onAppear { showServer = !server.isEmpty }
        #if os(macOS)
        .frame(minWidth: 400, minHeight: 300)
        #endif
    }

    private func logIn() {
        guard !username.isEmpty, !password.isEmpty else { return }
        Task {
            if await model.login(username: username.trimmingCharacters(in: .whitespaces), password: password) {
                dismiss()
                await model.sync()
            }
        }
    }
}

/// Settings section for the AnkiWeb account.
struct SyncSettingsSection: View {
    @Environment(AppModel.self) private var model
    @AppStorage("syncOnOpen") private var syncOnOpen = true
    @AppStorage("syncMedia") private var syncMedia = true
    @State private var confirmLogout = false
    @State private var loggingIn = false

    var body: some View {
        Section {
            if let user = model.syncUsername {
                LabeledContent("Account", value: user)
                Button("Sync Now") { Task { await model.sync() } }.disabled(model.syncing)
                Toggle("Sync when Inni opens", isOn: $syncOnOpen)
                Toggle("Sync media", isOn: $syncMedia)
                Button("Force One-Way Sync") { model.requireFullSync() }
                Button("Log Out", role: .destructive) { confirmLogout = true }
            } else {
                Button("Log In…") { loggingIn = true }
            }
        } header: {
            Text("Sync")
        } footer: {
            Text("Syncs with AnkiWeb, so reviews and edits reach Anki, AnkiDroid and AnkiMobile.")
        }
        .confirmationDialog("Log out of AnkiWeb?", isPresented: $confirmLogout, titleVisibility: .visible) {
            Button("Log Out", role: .destructive) { model.logout() }
        }
        .sheet(isPresented: $loggingIn) {
            NavigationStack { SyncLoginView() }.environment(model)
        }
    }
}

extension View {
    /// The login sheet and the one-way sync question, shared by the main window and settings.
    func syncPrompts(_ model: AppModel) -> some View {
        @Bindable var model = model
        return sheet(isPresented: $model.loginShown) {
            NavigationStack { SyncLoginView() }.environment(model)
        }
        .confirmationDialog("Choose which collection to keep", isPresented: Binding(
            get: { model.fullSyncChoice != nil }, set: { if !$0 { model.fullSyncChoice = nil } }),
                            titleVisibility: .visible, presenting: model.fullSyncChoice) { choice in
            if choice.downloadOK {
                Button("Download: replace this device with AnkiWeb") { Task { await model.fullSync(upload: false) } }
            }
            if choice.uploadOK {
                Button("Upload: replace AnkiWeb with this device", role: .destructive) { Task { await model.fullSync(upload: true) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The changes here and on AnkiWeb can't be merged (for example, a note type's fields changed), so one side replaces the other. Changes on the replaced side since the last sync are lost.")
        }
    }
}
