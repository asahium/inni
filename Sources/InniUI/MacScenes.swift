#if os(macOS)
import AppKit
import InniCore
import SwiftUI
import UniformTypeIdentifiers

public struct BrowseWindow: View {
    @Environment(AppModel.self) private var model
    public init() {}
    public var body: some View {
        NavigationStack { BrowserView().toolbarBackground(Nord.bar, for: .windowToolbar) }
            .frame(minWidth: 900, minHeight: 520)
            .nordWindow()
    }
}

public struct InniCommands: Commands {
    let model: AppModel
    @FocusedValue(\.rootActions) private var actions
    @Environment(\.openWindow) private var openWindow

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Add Note…") { actions?.add() }.keyboardShortcut("n")
            Divider()
            Button("Open Collection…") { openCollection() }.keyboardShortcut("o")
            Menu("Open Anki Profile") {
                ForEach(AppModel.ankiProfiles, id: \.self) { url in
                    Button(url.deletingLastPathComponent().lastPathComponent) { model.open(url) }
                }
            }
            Button("Open Inni Collection") { model.open(AppModel.defaultURL, create: true) }
        }
        CommandGroup(replacing: .importExport) {
            Button("Import…") { actions?.importFile() }.keyboardShortcut("i", modifiers: [.command, .shift])
            Button("Export…") { actions?.export() }.keyboardShortcut("e", modifiers: [.command, .shift])
        }
        CommandMenu("Tools") {
            Button("Sync") { Task { await model.sync() } }.keyboardShortcut("y", modifiers: [.command])
            Divider()
            Button("Browse") { openWindow(id: "browser") }.keyboardShortcut("b", modifiers: [.command, .shift])
            Button("Statistics") { actions?.stats() }.keyboardShortcut("s", modifiers: [.command, .shift])
            Divider()
            Button("Check Database") { model.checkDatabase() }
            Button("Delete Empty Cards") { model.removeEmptyCards() }
        }
    }

    private func openCollection() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "anki2") ?? .data]
        panel.message = "Choose a collection.anki2 (quit Anki first if it's one of its profiles)"
        if panel.runModal() == .OK, let url = panel.url { model.open(url) }
    }
}

#if DEBUG
/// `-InniSnapshot out.png [-InniSnapshotWindow Browse] [-InniSnapshotDelay 3]` draws a window into a PNG and quits.
/// Web views are out of process and come out blank.
@MainActor
enum DebugSnapshot {
    static func scheduleIfRequested() {
        let d = UserDefaults.standard
        guard let path = d.string(forKey: "InniSnapshot") else { return }
        let delay = d.double(forKey: "InniSnapshotDelay")
        DispatchQueue.main.asyncAfter(deadline: .now() + (delay > 0 ? delay : 3)) {
            let title = d.string(forKey: "InniSnapshotWindow")
            let windows = NSApp.windows.filter { $0.isVisible && $0.contentView != nil }
            let target = title.flatMap { t in windows.first { $0.title == t } }
                ?? windows.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
            if let view = target?.contentView?.superview ?? target?.contentView,
               let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
            NSApp.terminate(nil)
        }
    }
}
#endif

/// Closes the collection cleanly so Anki can open it right after Inni quits.
public final class InniAppDelegate: NSObject, NSApplicationDelegate {
    @MainActor public static var model: AppModel?

    public func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { Self.model?.close() }
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
#endif
