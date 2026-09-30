import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var usage: CodexUsageStore
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text("Yukino Tools").font(.headline)
        Text(usage.limitIsRecorded ? "Last recorded usage" : "Codex account connected")
        Divider()
        Text("Codex usage    \(UsageFormat.percent(usage.limits?.primary?.fraction))")
        Text("Weekly usage  \(UsageFormat.percent(usage.limits?.secondary?.fraction))")
        Text("Last context    \(UsageFormat.percent(usage.latestSession?.contextFraction))")
        if let captured = usage.limits?.capturedAt {
            Text("Updated \(captured.formatted(date: .omitted, time: .shortened))")
        }
        Button("Refresh usage") { Task { await usage.refresh() } }.disabled(usage.scanning || usage.accountRefreshing)
        Divider()
        Button("Codex Usage") { open(.codex) }
        ForEach([Tool.json, .timestamp, .uuid]) { tool in
            Button { open(tool) } label: { Label(tool.title, systemImage: tool.symbol) }
        }
        Divider()
        Button("Open Yukino Tools") { open(state.selected) }
        SettingsLink { Text("Settings…") }
        Divider()
        Button("Quit Yukino Tools") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
    private func open(_ tool: Tool) {
        state.navigate(tool)
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}
