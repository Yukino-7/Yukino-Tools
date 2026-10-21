import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var usage: CodexUsageStore
    @Environment(\.openWindow) private var openWindow
    @AppStorage("menuBarUsageStyle") private var style = MenuBarUsageStyle.doubleRing.rawValue
    var body: some View {
        Text("Yukino Tools").font(.headline)
        Text(usage.limits == nil ? "Codex 用量暂不可用" : usage.limitIsRecorded ? "Codex · 最近记录的用量" : "Codex · 账户实时用量")
        Divider()
        limitRow("5h", minutes: 300)
        limitRow("7d", minutes: 10080)
        Text("Last context    \(UsageFormat.percent(usage.latestSession?.contextFraction))")
        if let captured = usage.limits?.capturedAt {
            Text("Updated \(captured.formatted(date: .omitted, time: .shortened))")
        }
        Button("Refresh usage") { Task { await usage.refresh() } }.disabled(usage.scanning || usage.accountRefreshing)
        Picker("菜单栏样式", selection: $style) {
            ForEach(MenuBarUsageStyle.allCases) { style in Text(style.title).tag(style.rawValue) }
        }
        Divider()
        Button("Codex Usage") { open(.codex) }
        Button("OpenRouter 日报") { open(.openrouterDaily) }
        ForEach([Tool.json, .timestamp, .uuid, .nginx, .dockerTransfer, .process, .cron, .jwt, .regex]) { tool in
            Button { open(tool) } label: { Label(tool.title, systemImage: tool.symbol) }
        }
        Divider()
        Button("Open Yukino Tools") { open(state.selected) }
        SettingsLink { Text("Settings…") }
        Divider()
        Button("Quit Yukino Tools") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
    @ViewBuilder private func limitRow(_ title: String, minutes: Int) -> some View {
        let window = usage.limits?.window(minutes: minutes)
        Text("\(title) 已用    \(UsageFormat.percent(window?.fraction))")
        if let reset = window?.resetDate {
            Text("    重置 \(reset.formatted(date: .abbreviated, time: .shortened))")
        }
    }
    private func open(_ tool: Tool) {
        state.navigate(tool)
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}
