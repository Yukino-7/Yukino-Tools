import SwiftUI
import ServiceManagement

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            AppearanceSettings().tabItem { Label("Appearance", systemImage: "paintpalette") }
            CodexSettings().tabItem { Label("Codex", systemImage: "terminal") }
            NetworkSettings().tabItem { Label("Network", systemImage: "network") }
            AboutSettings().tabItem { Label("About", systemImage: "info.circle") }
        }.padding(20).frame(width: 550, height: 340)
    }
}

struct GeneralSettings: View {
    @AppStorage("showMenuBar") private var showMenuBar = true
    @AppStorage("rememberLastTool") private var rememberLastTool = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    var body: some View {
        Form {
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in
                    guard enabled != (SMAppService.mainApp.status == .enabled) else { return }
                    do {
                        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        loginError = nil
                    } catch {
                        loginError = "Could not update login item: \(error.localizedDescription)"
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
            Toggle("Show menu bar icon", isOn: $showMenuBar)
            Toggle("Remember last opened tool", isOn: $rememberLastTool)
            Text("Favorites, recent tools and window position are saved automatically.").font(.system(size: 11)).foregroundStyle(.secondary)
            if let loginError { InlineMessage(message: loginError, error: true) }
        }.formStyle(.grouped)
    }
}

struct AppearanceSettings: View {
    @AppStorage("appearance") private var appearance = "system"
    var body: some View {
        Form {
            Picker("Appearance", selection: $appearance) {
                Text("System").tag("system")
                Text("Light").tag("light")
                Text("Dark").tag("dark")
            }.pickerStyle(.segmented)
            LabeledContent("Accent color") { Text("Follow macOS").foregroundStyle(.secondary) }
            Text("Yukino uses your Mac’s accent color and native system typography.").font(.system(size: 11)).foregroundStyle(.secondary)
        }.formStyle(.grouped)
    }
}

struct CodexSettings: View {
    @EnvironmentObject private var usage: CodexUsageStore
    @AppStorage("codexAutoRefresh") private var autoRefresh = true
    @AppStorage("codexRefreshInterval") private var interval = 60
    @State private var dataPath = ""
    @State private var cliPath = ""
    var body: some View {
        Form {
            Section("Data sources") {
                TextField("Codex data folder", text: $dataPath, prompt: Text("~/.codex"))
                HStack {
                    Button("Choose folder…") { choose(folder: true) }
                    Spacer()
                    Text("Session token counters").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                TextField("Codex CLI", text: $cliPath, prompt: Text("Auto-detect installed Codex"))
                HStack {
                    Button("Choose CLI…") { choose(folder: false) }
                    Spacer()
                    Button("Save & refresh") {
                        UserDefaults.standard.set(dataPath, forKey: "codexDataPath")
                        UserDefaults.standard.set(cliPath, forKey: "codexCLIPath")
                        Task { await usage.refresh() }
                    }.disabled(usage.scanning || usage.accountRefreshing)
                }
                Text("Token statistics use local logs. Account allowance uses the CLI’s current ChatGPT sign-in; credentials stay inside Codex.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Section("Refresh") {
                Toggle("Auto refresh", isOn: $autoRefresh)
                Picker("Refresh interval", selection: $interval) {
                    Text("15 seconds").tag(15)
                    Text("30 seconds").tag(30)
                    Text("1 minute").tag(60)
                    Text("2 minutes").tag(120)
                    Text("5 minutes").tag(300)
                }.disabled(!autoRefresh)
            }
        }.formStyle(.grouped)
            .onAppear {
                dataPath = UserDefaults.standard.string(forKey: "codexDataPath") ?? ""
                cliPath = UserDefaults.standard.string(forKey: "codexCLIPath") ?? ""
            }
            .onChange(of: autoRefresh) { _, _ in usage.restartPolling() }
            .onChange(of: interval) { _, _ in usage.restartPolling() }
    }
    private func choose(folder: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = folder
        panel.canChooseFiles = !folder
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        if folder { panel.directoryURL = URL(fileURLWithPath: usage.dataPath) }
        if panel.runModal() == .OK, let url = panel.url {
            if folder { dataPath = url.path } else { cliPath = url.path }
        }
    }
}

struct NetworkSettings: View {
    @AppStorage("networkTimeout") private var timeout = 5
    var body: some View {
        Form {
            Stepper("Connection timeout: \(timeout)s", value: $timeout, in: 1...30)
            Text("Port Check opens a TCP connection to the endpoint you enter and closes it after checking. No application data is sent.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }.formStyle(.grouped)
    }
}

struct AboutSettings: View {
    var body: some View {
        VStack(spacing: 14) {
            SymbolTile(symbol: "square.stack.3d.up.fill", size: 64)
            Text("Yukino Tools").font(.system(size: 22, weight: .semibold))
            Text("Version 0.2.0 · Personal developer toolbox").font(.system(size: 12)).foregroundStyle(.secondary)
            Text("A quiet place for your everyday tools.").font(.system(size: 12)).foregroundStyle(.secondary)
            Text("Built with SwiftUI. Made for macOS.").font(.system(size: 10)).foregroundStyle(.tertiary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
