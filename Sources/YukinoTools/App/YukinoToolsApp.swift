import SwiftUI

@main
struct YukinoToolsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state = AppState()
    @StateObject private var usage = CodexUsageStore()
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("showMenuBar") private var showMenuBar = true
    private var scheme: ColorScheme? { appearance == "dark" ? .dark : appearance == "light" ? .light : nil }

    var body: some Scene {
        Window("Yukino Tools", id: "main") {
            MainWindow().environmentObject(state).environmentObject(usage).preferredColorScheme(scheme)
                .frame(minWidth: 1000, minHeight: 650)
                .background(WindowRestorer())
                .task { usage.start() }
        }
        .defaultSize(width: 1280, height: 800)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Search Tools…") { state.paletteVisible = true }.keyboardShortcut("k")
                Divider()
                Button("Overview") { state.navigate(.overview) }.keyboardShortcut("1")
                Button("Codex Usage") { state.navigate(.codex) }.keyboardShortcut("2")
            }
            CommandGroup(after: .textEditing) {
                Button("Find…") { findInCurrentTool() }.keyboardShortcut("f")
            }
        }
        Settings {
            SettingsView().environmentObject(state).environmentObject(usage).preferredColorScheme(scheme)
        }
        MenuBarExtra("Yukino Tools", systemImage: "square.stack.3d.up", isInserted: $showMenuBar) {
            MenuBarView().environmentObject(state).environmentObject(usage)
        }
    }

    private func findInCurrentTool() {
        guard [.json, .base64, .uuid, .nginx, .dockerMirror, .dockerTransfer].contains(state.selected), let window = NSApp.keyWindow else {
            state.paletteVisible = true
            return
        }
        func editors(in view: NSView) -> [NSTextView] {
            if let editor = view as? NSTextView, !editor.isFieldEditor { return [editor] }
            return view.subviews.flatMap { editors(in: $0) }
        }
        let candidates = window.contentView.map { editors(in: $0) } ?? []
        let focused = window.firstResponder as? NSTextView
        guard let editor = (focused?.isFieldEditor == false ? focused : nil)
            ?? candidates.first(where: { $0.isEditable }) ?? candidates.first else { return }
        window.makeFirstResponder(editor)
        let item = NSMenuItem()
        item.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        editor.performFindPanelAction(item)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { sender.windows.first { $0.identifier?.rawValue == "main" }?.makeKeyAndOrderFront(nil) }
        return true
    }
}

struct WindowRestorer: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.setFrameAutosaveName("YukinoToolsMainWindow")
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
