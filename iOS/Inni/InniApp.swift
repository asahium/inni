import InniUI
import SwiftUI

@main
struct InniApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
        .onChange(of: phase) { _, p in
            // Keeps Documents/collection.anki2 complete for Files-app copies and device backups.
            if p == .background { model.col?.checkpoint() }
        }
    }
}
