import InniUI
import SwiftUI

@main
struct InniApp: App {
    @NSApplicationDelegateAdaptor(InniAppDelegate.self) private var delegate
    @State private var model: AppModel

    init() {
        let m = AppModel()
        _model = State(initialValue: m)
        InniAppDelegate.model = m
    }

    var body: some Scene {
        Window("Inni", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 760, minHeight: 520)
        }
        .defaultSize(width: 1120, height: 760)
        .commands { InniCommands(model: model) }

        Window("Browse", id: "browser") {
            BrowseWindow().environment(model)
        }
        .defaultSize(width: 1100, height: 760)

        Settings {
            SettingsView()
                .environment(model)
                .frame(width: 500, height: 600)
                .nordWindow()
        }
    }
}
