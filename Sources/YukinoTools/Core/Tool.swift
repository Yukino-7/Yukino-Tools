import SwiftUI
import YukinoCore

enum AppVersion {
    static var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.7.0" }
}

enum Tool: String, CaseIterable, Identifiable, Codable {
    case overview, codex, token, json, base64, timestamp, uuid, port, http, dns, postgres, redis, dockerMirror, dockerTransfer, nginx, openrouterDaily, process, cron, jwt, regex, curl, localFeatures
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: "Overview"
        case .codex: "Codex Usage"
        case .token: "Token Calculator"
        case .json: "JSON Formatter"
        case .base64: "Base64 Converter"
        case .timestamp: "Timestamp Converter"
        case .uuid: "UUID Generator"
        case .port: "Port Check"
        case .http: "HTTP Client"
        case .dns: "DNS Lookup"
        case .postgres: "PostgreSQL"
        case .redis: "Redis"
        case .dockerMirror: "Docker Mirror"
        case .dockerTransfer: "Docker Transfer"
        case .nginx: "Nginx Formatter"
        case .openrouterDaily: "OpenRouter 日报"
        case .cron: "Cron 表达式助手"
        case .jwt: "JWT 查看器"
        case .regex: "正则表达式调试"
        case .process: "进程查找"
        case .curl: "cURL 生成与转换"
        case .localFeatures: LocalFeatureInfo.title
        }
    }
    var subtitle: String {
        switch self {
        case .overview: "Your personal developer toolbox."
        case .codex: "A little clarity for your AI workflow."
        case .token: "Estimate tokens and model costs."
        case .json: "Format, validate and inspect JSON data."
        case .base64: "Encode and decode UTF-8 text in a single step."
        case .timestamp: "Move between Unix timestamps and human time."
        case .uuid: "Unique identifiers, ready when you need them."
        case .port: "Check a TCP connection to any host and port."
        case .http: "Send requests and inspect responses."
        case .dns: "Explore the records behind a domain."
        case .postgres: "A home for your PostgreSQL connections."
        case .redis: "Inspect and manage your Redis data."
        case .dockerMirror: "Pull through a mirror and restore the original image tag."
        case .dockerTransfer: "Build image transfer commands for your private registry."
        case .nginx: "Format and inspect Nginx configurations on your Mac."
        case .openrouterDaily: "Free-model changes, weekly rankings and Markdown history."
        case .cron: "解释标准 Cron 与 Quartz，预览指定时区的执行时间。"
        case .jwt: "在本机查看 JWT 内容与时间声明，签名状态清晰可见。"
        case .regex: "实时匹配、捕获组与替换预览。"
        case .process: "按名称或 TCP 监听端口查找 Mac 进程，并结束当前用户的进程。"
        case .curl: "填写请求生成命令，检查并转换 Linux、CMD 与 PowerShell 版本。"
        case .localFeatures: LocalFeatureInfo.subtitle
        }
    }
    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .codex: "terminal"
        case .token: "text.word.spacing"
        case .json: "curlybraces"
        case .base64: "arrow.left.arrow.right"
        case .timestamp: "clock"
        case .uuid: "number"
        case .port: "network"
        case .http: "arrow.up.arrow.down"
        case .dns: "globe"
        case .postgres: "cylinder.split.1x2"
        case .redis: "externaldrive"
        case .dockerMirror: "shippingbox"
        case .dockerTransfer: "arrow.triangle.swap"
        case .nginx: "text.alignleft"
        case .openrouterDaily: "doc.richtext"
        case .cron: "calendar.badge.clock"
        case .jwt: "key.horizontal"
        case .regex: "text.magnifyingglass"
        case .process: "cpu"
        case .curl: "terminal.fill"
        case .localFeatures: LocalFeatureInfo.symbol
        }
    }
    var group: String {
        switch self {
        case .overview: "Workspace"
        case .codex, .token, .openrouterDaily: "AI"
        case .json, .base64, .timestamp, .uuid, .cron, .jwt, .regex: "Developer"
        case .port, .http, .dns, .process, .curl: "Network"
        case .postgres, .redis: "Database"
        case .dockerMirror, .dockerTransfer, .nginx: "DevOps"
        case .localFeatures: LocalFeatureInfo.group
        }
    }
    static var availableTools: [Tool] { allCases.filter(\.available) }
    var available: Bool {
        ![.token, .http, .dns, .postgres, .redis].contains(self)
            && (self != .localFeatures || LocalFeatureInfo.available)
    }
    static var sidebarGroups: [String] {
        var groups = ["AI", "Developer", "DevOps", "Network"]
        if LocalFeatureInfo.available && !groups.contains(LocalFeatureInfo.group) { groups.append(LocalFeatureInfo.group) }
        return groups
    }
    func matches(_ query: String) -> Bool {
        query.isEmpty || "\(title) \(subtitle) \(group) \(rawValue) \(aliases)".localizedCaseInsensitiveContains(query)
    }
    private var aliases: String {
        switch self {
        case .dockerMirror: "replaceDocker 镜像代理 替换"
        case .dockerTransfer: "pullAndPush 拉取 推送 私库"
        case .nginx: "nginxfmt 配置 格式化"
        case .openrouterDaily: "daily report 免费模型 榜单 markdown 日报"
        case .cron: "crontab quartz schedule 定时 调度 计划 表达式"
        case .jwt: "json web token bearer header payload 令牌 解码 有效期 过期"
        case .regex: "regexp regular expression 正则 匹配 捕获 替换"
        case .process: "process pid kill terminate 进程 服务 端口 占用 结束 node java redis nginx"
        case .curl: "curl cURL http request command cmd powershell linux bash 请求 命令 生成 转换 接口"
        case .localFeatures: LocalFeatureInfo.aliases
        default: ""
        }
    }
}

struct RecentTool: Codable, Identifiable {
    let tool: Tool
    let date: Date
    var id: String { tool.rawValue }
}

@MainActor final class AppState: ObservableObject {
    @Published var selected: Tool = .overview
    @Published var paletteVisible = false
    @Published var favorites: [Tool] = []
    @Published var recent: [RecentTool] = []
    @Published var notice: String?
    @Published private var sidebarOrder = SidebarOrder()
    static let favoritesGroup = "Favorites"
    private var noticeTask: Task<Void, Never>?
    private let defaults = UserDefaults.standard
    init() {
        LocalFeatureInfo.preparePreferences()
        if let data = defaults.data(forKey: "favorites"), let values = try? JSONDecoder().decode([Tool].self, from: data) {
            favorites = values.filter(\.available)
        } else { favorites = [.json, .timestamp, .uuid] }
        if let data = defaults.data(forKey: "sidebarOrder"), let saved = try? JSONDecoder().decode(SidebarOrder.self, from: data) {
            sidebarOrder = saved
            favorites = sidebarTools(in: Self.favoritesGroup)
        }
        if let data = defaults.data(forKey: "recentTools"), let values = try? JSONDecoder().decode([RecentTool].self, from: data) { recent = values.filter { $0.tool.available } }
        if defaults.object(forKey: "rememberLastTool") == nil || defaults.bool(forKey: "rememberLastTool") {
            if let tool = Tool(rawValue: defaults.string(forKey: "lastTool") ?? "overview"), tool.available {
                selected = tool
            }
        }
    }
    func navigate(_ tool: Tool) {
        guard tool.available else { return }
        selected = tool
        paletteVisible = false
        defaults.set(tool.rawValue, forKey: "lastTool")
        if tool != .overview {
            recent.removeAll { $0.tool == tool }
            recent.insert(RecentTool(tool: tool, date: Date()), at: 0)
            recent = Array(recent.prefix(8))
            defaults.set(try? JSONEncoder().encode(recent), forKey: "recentTools")
        }
    }
    func toggleFavorite(_ tool: Tool) {
        guard tool.available else { return }
        if favorites.contains(tool) { favorites.removeAll { $0 == tool } } else { favorites.append(tool) }
        saveFavorites()
    }
    func saveFavorites() { defaults.set(try? JSONEncoder().encode(favorites), forKey: "favorites") }
    var sidebarGroups: [String] {
        sidebarOrder.orderedGroups((favorites.isEmpty ? [] : [Self.favoritesGroup]) + Tool.sidebarGroups)
    }
    func sidebarTools(in group: String) -> [Tool] {
        let tools = group == Self.favoritesGroup ? favorites : Tool.availableTools.filter { $0 != .overview && $0.group == group }
        return sidebarOrder.orderedItems(in: group, available: tools.map(\.rawValue)).compactMap(Tool.init(rawValue:))
    }
    func moveSidebarGroup(_ source: String, to target: String, after: Bool) {
        guard sidebarOrder.moveGroup(source, to: target, after: after, available: sidebarGroups) else { return }
        saveSidebarOrder()
    }
    func moveSidebarTool(_ tool: Tool, in group: String, to target: Tool, after: Bool) {
        let available = sidebarTools(in: group).map(\.rawValue)
        guard sidebarOrder.moveItem(tool.rawValue, in: group, to: target.rawValue, after: after, available: available) else { return }
        if group == Self.favoritesGroup { favorites = sidebarTools(in: group); saveFavorites() }
        saveSidebarOrder()
    }
    private func saveSidebarOrder() {
        defaults.set(try? JSONEncoder().encode(sidebarOrder), forKey: "sidebarOrder")
    }
    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        notify("Copied to clipboard")
    }
    func notify(_ message: String) {
        noticeTask?.cancel()
        notice = message
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }
}
