import SwiftUI

struct MainWindow: View {
    @EnvironmentObject private var state: AppState
    @State private var search = ""
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragSession: SidebarDragSession?
    @State private var landingTask: Task<Void, Never>?
    @State private var collapsedGroups: Set<String> = []
    @State private var sidebarFrames: [SidebarDrag: CGRect] = [:]
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
                case .curl: CurlView()
                case .process: ProcessFinderView()
                case .cron: CronView()
                case .jwt: JWTView()
                case .regex: RegexView()
                case .dockerMirror: DockerCommandsView(mirror: true).id(Tool.dockerMirror)
                case .dockerTransfer: DockerCommandsView(mirror: false).id(Tool.dockerTransfer)
                case .nginx: NginxFormatterView()
                case .openrouterDaily: OpenRouterDailyView()
                case .localFeatures: LocalFeatureView()
                default: OverviewView()
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
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if Tool.overview.matches(search) { toolRow(.overview) }
                    ForEach(state.sidebarGroups, id: \.self) { group in
                        let tools = state.sidebarTools(in: group).filter { $0.matches(search) }
                        if !tools.isEmpty && (group != AppState.favoritesGroup || search.isEmpty) {
                            VStack(alignment: .leading, spacing: 2) {
                                groupHeader(group).padding(.top, 14)
                                if !collapsedGroups.contains(group) || !search.isEmpty {
                                    ForEach(tools) { tool in sortableToolRow(tool, in: group) }
                                }
                            }
                            .background { frameReader(for: .group(group)) }
                            .opacity(dragSession?.source == .group(group) ? 0 : 1)
                            .offset(y: displacement(for: .group(group)))
                            .animation(reorderAnimation, value: dragSession?.destinationIndex)
                        }
                    }
                    if !Tool.availableTools.contains(where: { $0.matches(search) }) {
                        Text("No matching tools").foregroundStyle(.secondary)
                    }
                }.padding(.horizontal, 10).padding(.bottom, 12)
            }
                .coordinateSpace(name: "sidebar")
                .onPreferenceChange(SidebarFramesKey.self) { sidebarFrames = $0 }
                .overlay(alignment: .topLeading) { dragOverlay.allowsHitTesting(false) }
                .clipped()
                .onChange(of: search) { _, _ in cancelDrag() }
                .onDisappear { cancelDrag() }
            Divider().padding(.horizontal, 16)
            HStack {
                SettingsLink { Label("Settings", systemImage: "gearshape") }.buttonStyle(.plain)
                Spacer()
                Text("v\(AppVersion.current)").font(.system(size: 10)).foregroundStyle(.tertiary)
            }.font(.system(size: 12)).padding(20)
        }
    }
    private func toolLabel(_ tool: Tool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: tool.symbol).frame(width: 18)
            Text(tool.title).font(.system(size: 12))
            Spacer(minLength: 0)
        }.padding(.horizontal, 8).frame(height: 32).contentShape(Rectangle())
    }

    private func toolRow(_ tool: Tool) -> some View {
        Button { state.navigate(tool) } label: { toolLabel(tool) }
            .buttonStyle(.plain)
            .background(state.selected == tool ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .accessibilityValue(state.selected == tool ? "Selected" : "")
            .contextMenu { if tool != .overview { FavoriteMenu(tool: tool) } }
    }

    @ViewBuilder private func sortableToolRow(_ tool: Tool, in group: String) -> some View {
        if search.isEmpty {
            let target = SidebarDrag.tool(tool, group: group)
            toolRow(tool)
                .contentShape(Rectangle())
                .background { frameReader(for: target) }
                .highPriorityGesture(reorderGesture(for: target))
                .opacity(dragSession?.source == target ? 0 : 1)
                .offset(y: displacement(for: target))
                .animation(reorderAnimation, value: dragSession?.destinationIndex)
                .help("拖动以调整本板块内的顺序")
        } else {
            toolRow(tool)
        }
    }

    @ViewBuilder private func groupHeader(_ group: String) -> some View {
        if search.isEmpty {
            let target = SidebarDrag.group(group)
            Button {
                if collapsedGroups.contains(group) { collapsedGroups.remove(group) }
                else { collapsedGroups.insert(group) }
            } label: {
                groupLabel(group)
            }.buttonStyle(.plain)
            .frame(height: 24)
            .contentShape(Rectangle())
            .highPriorityGesture(reorderGesture(for: target))
            .help("拖动标题以移动整个板块")
            .accessibilityLabel("\(group)，\(collapsedGroups.contains(group) ? "展开" : "折叠")板块")
        } else {
            Text(group)
        }
    }

    private func groupLabel(_ group: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: collapsedGroups.contains(group) ? "chevron.right" : "chevron.down")
                .font(.system(size: 9, weight: .semibold))
            Text(group).font(.system(size: 11, weight: .semibold))
            Spacer(minLength: 8)
            Image(systemName: "line.3.horizontal").font(.system(size: 10)).foregroundStyle(.tertiary)
        }.foregroundStyle(.secondary).padding(.horizontal, 6).frame(maxWidth: .infinity)
    }

    private var reorderAnimation: Animation? {
        reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.86)
    }

    private func frameReader(for target: SidebarDrag) -> some View {
        GeometryReader { proxy in
            Color.clear.preference(key: SidebarFramesKey.self, value: [target: proxy.frame(in: .named("sidebar"))])
        }
    }

    private func reorderGesture(for source: SidebarDrag) -> some Gesture {
        DragGesture(minimumDistance: 5, coordinateSpace: .named("sidebar"))
            .onChanged { value in
                guard search.isEmpty, dragSession?.settling != true else { return }
                if dragSession == nil {
                    let siblings: [SidebarDrag]
                    switch source {
                    case .group: siblings = state.sidebarGroups.map(SidebarDrag.group)
                    case let .tool(_, group): siblings = state.sidebarTools(in: group).map { .tool($0, group: group) }
                    }
                    guard let frame = sidebarFrames[source], let index = siblings.firstIndex(of: source) else { return }
                    dragSession = SidebarDragSession(source: source, siblings: siblings, frames: sidebarFrames,
                                                     sourceFrame: frame, sourceIndex: index, destinationIndex: index)
                }
                updateDrag(translation: value.translation, point: value.location)
            }
            .onEnded { value in
                guard dragSession?.settling == false else { return }
                updateDrag(translation: value.translation, point: value.location)
                finishDrag()
            }
    }

    private func updateDrag(translation: CGSize, point: CGPoint) {
        guard var session = dragSession else { return }
        session.translation = translation
        let bounds: CGRect
        switch session.source {
        case let .tool(_, group): bounds = session.frames[.group(group)] ?? session.sourceFrame
        case .group: bounds = session.frames.filter { if case .group = $0.key { return true }; return false }
                .values.reduce(CGRect.null) { $0.union($1) }
        }
        if bounds.insetBy(dx: -12, dy: 0).contains(point) {
            let center = session.sourceFrame.midY + translation.height
            session.destinationIndex = session.siblings.filter { $0 != session.source }
                .filter { (session.frames[$0]?.midY ?? .greatestFiniteMagnitude) < center }.count
        } else {
            session.destinationIndex = session.sourceIndex
        }
        dragSession = session
    }

    private func displacement(for item: SidebarDrag) -> CGFloat {
        guard let session = dragSession, !session.settling,
              let index = session.siblings.firstIndex(of: item), item != session.source else { return 0 }
        let distance = session.sourceFrame.height + 2
        if session.destinationIndex > session.sourceIndex && index > session.sourceIndex && index <= session.destinationIndex { return -distance }
        if session.destinationIndex < session.sourceIndex && index >= session.destinationIndex && index < session.sourceIndex { return distance }
        return 0
    }

    private func finishDrag() {
        guard var session = dragSession else { return }
        let target = session.siblings[session.destinationIndex]
        let after = session.destinationIndex > session.sourceIndex
        session.translation = CGSize(width: 0, height: session.landingY - session.sourceFrame.minY)
        session.settling = true
        withAnimation(reorderAnimation) {
            dragSession = session
            switch (session.source, target) {
            case let (.group(source), .group(destination)):
                state.moveSidebarGroup(source, to: destination, after: after)
            case let (.tool(source, group), .tool(destination, _)):
                state.moveSidebarTool(source, in: group, to: destination, after: after)
            default: break
            }
        }
        landingTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 0 : 240))
            guard !Task.isCancelled else { return }
            dragSession = nil
        }
    }

    private func cancelDrag() {
        landingTask?.cancel()
        dragSession = nil
    }

    @ViewBuilder private var dragOverlay: some View {
        if let session = dragSession {
            let frame = session.sourceFrame
            RoundedRectangle(cornerRadius: 9)
                .fill(Color.accentColor.opacity(0.05))
                .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(Color.accentColor.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [4, 4])) }
                .frame(width: frame.width, height: frame.height)
                .offset(x: frame.minX, y: session.landingY)
                .animation(reorderAnimation, value: session.destinationIndex)
            dragContent(session.source)
                .frame(width: frame.width, height: frame.height, alignment: .topLeading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
                .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(Color.primary.opacity(0.12)) }
                .shadow(color: .black.opacity(0.18), radius: 12, x: 0, y: 5)
                .scaleEffect(session.settling || reduceMotion ? 1 : 1.025)
                .offset(x: frame.minX + session.translation.width, y: frame.minY + session.translation.height)
                .transaction { if !session.settling { $0.animation = nil } }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder private func dragContent(_ source: SidebarDrag) -> some View {
        switch source {
        case let .tool(tool, _): toolLabel(tool)
        case let .group(group):
            VStack(alignment: .leading, spacing: 2) {
                groupLabel(group).frame(height: 24).padding(.top, 14)
                if !collapsedGroups.contains(group) {
                    ForEach(state.sidebarTools(in: group)) { tool in toolLabel(tool) }
                }
            }
        }
    }

}

private enum SidebarDrag: Hashable {
    case group(String)
    case tool(Tool, group: String)
}

private struct SidebarDragSession {
    let source: SidebarDrag
    let siblings: [SidebarDrag]
    let frames: [SidebarDrag: CGRect]
    let sourceFrame: CGRect
    let sourceIndex: Int
    var destinationIndex: Int
    var translation: CGSize = .zero
    var settling = false

    var landingY: CGFloat {
        guard let target = frames[siblings[destinationIndex]] else { return sourceFrame.minY }
        return destinationIndex > sourceIndex ? target.maxY - sourceFrame.height : target.minY
    }
}

private struct SidebarFramesKey: PreferenceKey {
    static let defaultValue: [SidebarDrag: CGRect] = [:]
    static func reduce(value: inout [SidebarDrag: CGRect], nextValue: () -> [SidebarDrag: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
