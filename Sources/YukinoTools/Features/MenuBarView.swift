import SwiftUI
import YukinoCore

// Shared by the popup and Appearance settings; the native option follows macOS's accent.
enum AppTheme: String, CaseIterable, Identifiable {
    case native, blue, cyan, purple, green
    var id: String { rawValue }
    var title: String {
        switch self {
        case .native: return "macOS 原生"
        case .blue: return "蓝色"
        case .cyan: return "青色"
        case .purple: return "紫色"
        case .green: return "绿色"
        }
    }
    var accent: Color {
        switch self {
        case .native: return Color(nsColor: .controlAccentColor)
        case .blue: return Color(red: 0.12, green: 0.45, blue: 1)
        case .cyan: return Color(red: 0, green: 0.65, blue: 0.8)
        case .purple: return Color(red: 0.57, green: 0.32, blue: 0.95)
        case .green: return Color(red: 0.12, green: 0.65, blue: 0.38)
        }
    }
    var companion: Color { self == .purple ? .cyan : .purple }
}

struct ThemeColorPicker: View {
    @Binding var selection: String
    var body: some View {
        HStack(spacing: 12) {
            ForEach(AppTheme.allCases) { theme in
                Button { selection = theme.rawValue } label: {
                    HStack(spacing: 5) {
                        ZStack {
                            Circle().fill(theme == .native ? Color(nsColor: .systemGray) : theme.accent)
                            if selection == theme.rawValue {
                                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                            }
                        }.frame(width: 20, height: 20)
                        if theme == .native { Text(theme.title).font(.system(size: 11)) }
                    }
                    .padding(4)
                    .overlay(Capsule().strokeBorder(selection == theme.rawValue ? theme.accent : .clear, lineWidth: 1.5))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(theme.title)
                .accessibilityLabel(theme.title)
                .accessibilityValue(selection == theme.rawValue ? "已选择" : "未选择")
            }
        }
    }
}

struct MenuBarView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var usage: CodexUsageStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var systemScheme
    @AppStorage("menuBarUsageStyle") private var style = MenuBarUsageStyle.doubleRing.rawValue
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("themeColor") private var themeColor = AppTheme.native.rawValue
    @State private var toolsExpanded = false

    private var theme: AppTheme { AppTheme(rawValue: themeColor) ?? .native }
    private var scheme: ColorScheme { appearance == "dark" ? .dark : appearance == "light" ? .light : systemScheme }
    private var dark: Bool { scheme == .dark }
    private var busy: Bool { usage.scanning || usage.accountRefreshing }
    private var border: Color { dark ? .white.opacity(0.1) : .black.opacity(0.07) }
    private var surface: Color { dark ? .white.opacity(0.045) : .white.opacity(0.8) }
    private var status: String {
        if busy { return "正在同步" }
        if usage.limits == nil { return "暂无数据" }
        return usage.limitIsRecorded ? "最近记录" : "实时同步"
    }
    private let tools: [Tool] = [.openrouterDaily, .json, .timestamp, .uuid, .nginx, .dockerTransfer, .process, .cron, .jwt, .regex, .aiDebug]

    var body: some View {
        VStack(spacing: 0) {
            header.padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 12)
            ScrollView {
                VStack(spacing: 12) {
                    usageCard
                    quickTools
                    stylePicker
                }.padding(.horizontal, 18).padding(.bottom, 12)
            }.scrollIndicators(.automatic)
            VStack(spacing: 10) {
                appearanceControls
                footer
            }.padding(.horizontal, 18).padding(.bottom, 14).padding(.top, 10)
                .background(.ultraThinMaterial)
        }
        .frame(width: 420, height: min(toolsExpanded ? 790 : 570,
                                      max(400, (NSScreen.main?.visibleFrame.height ?? 900) - 64)))
        .background {
            ZStack(alignment: .topLeading) {
                Rectangle().fill(.regularMaterial)
                if theme != .native {
                    (dark ? Color(red: 0.025, green: 0.045, blue: 0.09) : Color.white).opacity(0.7)
                    RadialGradient(colors: [theme.accent.opacity(dark ? 0.2 : 0.09), .clear], center: .topLeading,
                                   startRadius: 0, endRadius: 500)
                }
            }
        }
        .environment(\.colorScheme, scheme)
        .tint(theme.accent)
        .accentColor(theme.accent)
        .background(PopupInitialFocus())
        .onAppear { toolsExpanded = false }
    }

    private var quickTools: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { toolsExpanded.toggle() } label: {
                HStack(spacing: 9) {
                    Image(systemName: toolsExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold)).frame(width: 10)
                    Text("快捷工具").font(.system(size: 11, weight: .semibold))
                    Rectangle().fill(border).frame(height: 1)
                    Text(toolsExpanded ? "收起" : "展开").font(.system(size: 10)).foregroundStyle(.secondary)
                }.frame(height: 26).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityLabel("快捷工具")
                .accessibilityValue(toolsExpanded ? "已展开" : "已折叠")
                .accessibilityHint(toolsExpanded ? "收起工具入口" : "展开工具入口")
            if toolsExpanded {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible())], spacing: 7) {
                    ForEach(tools) { tool in toolButton(tool, title: shortTitle(tool)) }
                    LocalFeatureMenu()
                }.buttonStyle(PopupTileStyle(accent: theme.accent, surface: surface, border: border))
            }
        }
    }

    private var appearanceControls: some View {
        VStack(spacing: 8) {
            HStack {
                Text("外观").font(.system(size: 11, weight: .medium)).frame(width: 50, alignment: .leading)
                Picker("外观", selection: $appearance) {
                    Label("跟随系统", systemImage: "desktopcomputer").tag("system")
                    Label("浅色", systemImage: "sun.max").tag("light")
                    Label("深色", systemImage: "moon").tag("dark")
                }.labelsHidden().pickerStyle(.segmented)
            }
            HStack {
                Text("主题色").font(.system(size: 11, weight: .medium)).frame(width: 50, alignment: .leading)
                ThemeColorPicker(selection: $themeColor)
                Spacer(minLength: 0)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 11) {
            Image(systemName: "snowflake")
                .font(.system(size: 24, weight: .medium)).foregroundStyle(.white)
                .frame(width: 43, height: 43)
                .background(LinearGradient(colors: [theme.accent, theme == .native ? theme.accent : theme.companion],
                                           startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 3) {
                Text("Yukino Tools").font(.system(size: 19, weight: .bold))
                Text("开发者效率工具箱").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { Task { await usage.refresh() } } label: {
                Group {
                    if busy { ProgressView().controlSize(.small) }
                    else { Image(systemName: "arrow.clockwise").font(.system(size: 15)) }
                }.frame(width: 32, height: 32)
            }.buttonStyle(.plain).background(surface, in: RoundedRectangle(cornerRadius: 9))
                .disabled(busy).help("刷新用量").accessibilityLabel("刷新用量")
        }
    }

    private var usageCard: some View {
        VStack(spacing: 12) {
            HStack {
                Label("Codex 用量", systemImage: "terminal").font(.system(size: 12, weight: .semibold))
                Spacer()
                Circle().fill(usage.limits == nil || usage.limitIsRecorded ? Color.secondary : theme.accent).frame(width: 5, height: 5)
                Text(status).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            HStack(spacing: 20) {
                gauge("5h", minutes: 300, color: theme.accent)
                gauge("7d", minutes: 10080, color: theme == .native ? theme.accent.opacity(0.75) : theme.companion)
            }
            Divider().overlay(border)
            HStack(spacing: 10) {
                Text("上下文").font(.system(size: 10)).foregroundStyle(.secondary)
                GeometryReader { geometry in
                    Capsule().fill(border)
                        .overlay(alignment: .leading) {
                            Capsule().fill(theme.accent.gradient)
                                .frame(width: geometry.size.width * safeFraction(usage.latestSession?.contextFraction))
                        }
                }.frame(height: 5)
                Text(UsageFormat.percent(usage.latestSession?.contextFraction)).font(.system(size: 10, design: .monospaced))
            }
            Button { open(.codex) } label: {
                HStack {
                    if let captured = usage.limits?.capturedAt {
                        Text("更新于 \(captured.formatted(date: .omitted, time: .shortened))\(usage.limitIsRecorded ? " · 历史记录" : "")")
                    } else { Text("用量暂不可用，点击查看详情") }
                    Spacer()
                    Image(systemName: "chevron.right")
                }.font(.system(size: 10)).foregroundStyle(.secondary).contentShape(Rectangle())
            }.buttonStyle(.plain).help(usage.accountError ?? "查看 Codex 用量详情")
        }.padding(14).background(surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(border))
    }

    private func gauge(_ title: String, minutes: Int, color: Color) -> some View {
        let window = usage.limits?.window(minutes: minutes)
        return VStack(spacing: 6) {
            ZStack {
                Circle().strokeBorder(color.opacity(dark ? 0.13 : 0.1), lineWidth: 6)
                if let fraction = window?.fraction {
                    Circle().trim(from: 0, to: safeFraction(fraction)).stroke(color.gradient, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(-90)).padding(3)
                } else {
                    Circle().strokeBorder(color.opacity(0.3), style: StrokeStyle(lineWidth: 2, dash: [2, 5]))
                }
                VStack(spacing: 3) {
                    Text(window.map { "\(Int(($0.fraction * 100).rounded()))%" } ?? "—")
                        .font(.system(size: 23, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text("\(title) 已用").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }.frame(width: 88, height: 88)
            if let reset = window?.resetDate {
                Text("\(reset.formatted(.dateTime.month().day().hour().minute())) 重置")
                    .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
            } else {
                Text("重置时间暂无").font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(title) 已用 \(UsageFormat.percent(window?.fraction))")
            .accessibilityValue(window?.resetDate.map { "重置 \($0.formatted())" } ?? "重置时间暂无")
    }

    private func toolButton(_ tool: Tool, title: String) -> some View {
        Button { open(tool) } label: {
            MenuBarToolLabel(title: title, symbol: tool.symbol)
        }
    }

    private var stylePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("菜单栏样式")
            HStack(spacing: 4) {
                ForEach(MenuBarUsageStyle.allCases) { option in
                    Button { style = option.rawValue } label: {
                        VStack(spacing: 4) {
                            Image(systemName: styleSymbol(option)).font(.system(size: 15))
                            Text(option.title).font(.system(size: 9))
                        }.frame(maxWidth: .infinity).frame(height: 42)
                            .foregroundStyle(style == option.rawValue ? theme.accent : .secondary)
                            .background(style == option.rawValue ? theme.accent.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(style == option.rawValue ? theme.accent.opacity(0.7) : .clear))
                    }.buttonStyle(.plain).help(option.detail)
                        .accessibilityLabel(option.title).accessibilityValue(style == option.rawValue ? "已选择" : "未选择")
                }
            }.padding(3).background(surface, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var footer: some View {
        HStack(spacing: 9) {
            Button { open(state.selected) } label: {
                Label("打开主窗口", systemImage: "arrow.up.forward.square")
                    .font(.system(size: 12, weight: .semibold)).frame(maxWidth: .infinity).frame(height: 34)
                    .foregroundStyle(.white).background(theme.accent.gradient, in: RoundedRectangle(cornerRadius: 9))
            }.buttonStyle(.plain)
            Button {
                dismiss()
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            } label: {
                Image(systemName: "gearshape").frame(width: 34, height: 34)
            }.buttonStyle(.plain).help("设置").accessibilityLabel("设置")
            Button { NSApp.terminate(nil) } label: {
                Image(systemName: "power").frame(width: 34, height: 34)
            }.buttonStyle(.plain).keyboardShortcut("q").help("退出 Yukino Tools").accessibilityLabel("退出 Yukino Tools")
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        HStack(spacing: 9) {
            Text(title).font(.system(size: 11, weight: .semibold))
            Rectangle().fill(border).frame(height: 1)
        }
    }
    private func safeFraction(_ value: Double?) -> Double {
        guard let value, value.isFinite else { return 0 }
        return min(1, max(0, value))
    }
    private func styleSymbol(_ style: MenuBarUsageStyle) -> String {
        switch style {
        case .doubleRing: return "circle.circle"
        case .singleRing: return "circle.lefthalf.filled"
        case .bars: return "line.3.horizontal"
        case .numbers: return "textformat.123"
        }
    }
    private func shortTitle(_ tool: Tool) -> String {
        switch tool {
        case .json: return "JSON 格式化"
        case .timestamp: return "时间戳转换"
        case .uuid: return "UUID 生成"
        case .nginx: return "Nginx 格式化"
        case .dockerTransfer: return "Docker 迁移"
        case .process: return "进程查找"
        case .cron: return "Cron 助手"
        case .jwt: return "JWT 查看"
        case .regex: return "正则调试"
        case .curl: return "cURL 工具"
        default: return tool.title
        }
    }
    private func open(_ tool: Tool) {
        dismiss()
        state.navigate(tool)
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct MenuBarToolLabel: View {
    let title: String
    let symbol: String
    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: symbol).font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.accentColor).frame(width: 27, height: 27)
                .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
            Text(title).font(.system(size: 11, weight: .medium)).lineLimit(1)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.system(size: 9, weight: .medium)).foregroundStyle(.tertiary)
        }.padding(.horizontal, 8).padding(.vertical, 6).contentShape(RoundedRectangle(cornerRadius: 10))
    }
}

// Give the popup a neutral initial responder. Buttons remain reachable with Tab,
// but opening the panel never focuses or activates an arbitrary tool action.
private struct PopupInitialFocus: NSViewRepresentable {
    func makeNSView(context: Context) -> FocusAnchor { FocusAnchor() }
    func updateNSView(_ nsView: FocusAnchor, context: Context) {}

    final class FocusAnchor: NSView {
        private var keyObserver: NSObjectProtocol?
        override var acceptsFirstResponder: Bool { true }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
            keyObserver = nil
            guard let window else { return }
            focusRingType = .none
            setAccessibilityElement(false)
            window.initialFirstResponder = self
            keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification,
                                                                 object: window, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.window?.makeFirstResponder(self)
            }
            if window.isKeyWindow { window.makeFirstResponder(self) }
        }
        deinit {
            if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        }
    }
}

private struct PopupTileStyle: ButtonStyle {
    let accent: Color
    let surface: Color
    let border: Color
    func makeBody(configuration: Configuration) -> some View {
        Tile(configuration: configuration, accent: accent, surface: surface, border: border)
    }
    private struct Tile: View {
        let configuration: ButtonStyleConfiguration
        let accent: Color
        let surface: Color
        let border: Color
        @State private var hovered = false
        var body: some View {
            configuration.label
                .background(configuration.isPressed ? accent.opacity(0.16) : hovered ? accent.opacity(0.08) : surface,
                            in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(hovered ? accent.opacity(0.65) : border))
                .onHover { hovered = $0 }
        }
    }
}
