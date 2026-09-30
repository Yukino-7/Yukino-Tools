import SwiftUI
import UniformTypeIdentifiers

struct MainWindow: View {
    @EnvironmentObject private var state: AppState
    @State private var search = ""
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar.navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 260)
        } detail: {
            Group {
                switch state.selected {
                case .overview: OverviewView()
                case .codex: CodexUsageView()
                case .json: JSONFormatterView()
                case .base64: Base64View()
                case .timestamp: TimestampView()
                case .uuid: UUIDView()
                case .port: PortCheckView()
                case .dockerMirror: DockerCommandsView(mirror: true).id(Tool.dockerMirror)
                case .dockerTransfer: DockerCommandsView(mirror: false).id(Tool.dockerTransfer)
                case .nginx: NginxFormatterView()
                default: PlannedToolView(tool: state.selected)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(state.selected.title)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { state.paletteVisible = true } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "magnifyingglass")
                            Text("Search tools").foregroundStyle(.secondary)
                            Text("⌘ K").font(.system(size: 11)).foregroundStyle(.tertiary)
                        }.padding(.horizontal, 4)
                    }.help("Search tools (⌘K)")
                }
                ToolbarItem(placement: .primaryAction) {
                    SettingsLink { Image(systemName: "gearshape") }.help("Settings (⌘,)")
                }
            }
        }
        .sheet(isPresented: $state.paletteVisible) { CommandPalette() }
        .overlay(alignment: .bottom) {
            if let notice = state.notice {
                Label(notice, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .medium)).padding(.horizontal, 18).padding(.vertical, 12)
                    .background(.regularMaterial, in: Capsule()).padding(.bottom, 20)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.18), value: state.notice)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                SymbolTile(symbol: "square.stack.3d.up.fill", size: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Yukino Tools").font(.system(size: 15, weight: .semibold))
                    Text("A little more productive.").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(.horizontal, 18).padding(.top, 22).padding(.bottom, 20)
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter tools", text: $search).textFieldStyle(.plain)
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Clear tool filter")
                }
            }.padding(8).background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 16).padding(.bottom, 12)
            List(selection: Binding<Tool?>(get: { state.selected }, set: { if let tool = $0 { state.navigate(tool) } })) {
                if Tool.overview.matches(search) { toolRow(.overview) }
                if !state.favorites.isEmpty && search.isEmpty {
                    Section("Favorites") {
                        ForEach(state.favorites) { tool in toolRow(tool) }
                            .onMove { indices, offset in
                                state.favorites.move(fromOffsets: indices, toOffset: offset)
                                state.saveFavorites()
                            }
                    }
                }
                ForEach(["AI", "Developer", "DevOps", "Network", "Database"], id: \.self) { group in
                    let tools = Tool.allCases.filter { $0.group == group && $0.matches(search) }
                    if !tools.isEmpty {
                        Section(group) { ForEach(tools) { tool in toolRow(tool) } }
                    }
                }
                if !Tool.allCases.contains(where: { $0.matches(search) }) {
                    Text("No matching tools").foregroundStyle(.secondary)
                }
            }.listStyle(.sidebar)
            Divider().padding(.horizontal, 16)
            HStack {
                SettingsLink { Label("Settings", systemImage: "gearshape") }.buttonStyle(.plain)
                Spacer()
                Text("v0.3").font(.system(size: 10)).foregroundStyle(.tertiary)
            }.font(.system(size: 12)).padding(20)
        }
    }
    private func toolRow(_ tool: Tool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: tool.symbol).frame(width: 18)
            Text(tool.title).font(.system(size: 12))
            Spacer(minLength: 0)
            if !tool.available { Image(systemName: "circle.dotted").font(.system(size: 10)).foregroundStyle(.tertiary) }
        }.padding(.vertical, 4).tag(tool)
            .contextMenu { if tool != .overview { FavoriteMenu(tool: tool) } }
    }
}

struct PlannedToolView: View {
    @EnvironmentObject private var state: AppState
    let tool: Tool
    var body: some View {
        ToolPage(tool: tool) {
            Panel {
                VStack(spacing: 18) {
                    SymbolTile(symbol: tool.symbol, size: 64)
                    Text("On the workbench").font(.system(size: 20, weight: .semibold))
                    Text("\(tool.title) is planned for a future version.\nYour everyday developer tools are ready to use now.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Open JSON Formatter") { state.navigate(.json) }.buttonStyle(.borderedProminent)
                }.frame(maxWidth: .infinity).padding(.vertical, 64)
            }
        }
    }
}
