import SwiftUI
import AppKit
import YukinoCore

@MainActor final class MCPDebuggerModel: ObservableObject {
    @Published var configuration = MCPConnectionConfiguration()
    @Published var bearer = ""
    @Published var category = MCPEntry.Kind.tool
    @Published var selectedID: String?
    @Published var arguments = "{}"
    @Published var resourceURI = ""
    @Published var filter = ""
    @Published private(set) var connected = false
    @Published private(set) var busy = false
    @Published private(set) var action = ""
    @Published private(set) var serverName = ""
    @Published private(set) var version = ""
    @Published private(set) var serverDetails = ""
    @Published private(set) var entries = [MCPEntry.Kind: [MCPEntry]]()
    @Published private(set) var loaded = Set<MCPEntry.Kind>()
    @Published private(set) var logs = [MCPLogEntry]()
    @Published private(set) var result: MCPResult?
    @Published private(set) var error: String?
    @Published private(set) var notice: String?
    @Published private(set) var demo = false
    private let client = MCPClient()
    private var operation: Task<Void, Never>?
    private var operationID = UUID()
    var selected: MCPEntry? { entries[category]?.first { $0.id == selectedID } }
    var visibleEntries: [MCPEntry] {
        (entries[category] ?? []).filter { filter.isEmpty || "\($0.name) \($0.title) \($0.detail) \($0.uri)".localizedCaseInsensitiveContains(filter) }
    }
    var supportsCategory: Bool {
        client.capabilities.contains(category == .tool ? "tools" : category == .prompt ? "prompts" : "resources")
    }
    init() {
        client.onChange = { [weak self] in
            guard let self else { return }
            let wasConnected = self.connected
            self.connected = self.client.connected; self.logs = self.client.logs
            self.serverName = self.client.serverName; self.version = self.client.protocolVersion
            self.serverDetails = self.client.serverDetails
            if wasConnected && !self.connected { self.notice = "连接已关闭，详情见协议日志；可重新连接。" }
        }
    }
    func connect(demo: Bool = false) {
        guard !busy else { return }
        self.demo = demo; entries.removeAll(); loaded.removeAll(); selectedID = nil; result = nil
        run("连接中…") {
            if demo { try await self.client.connectDemo() }
            else {
                var config = self.configuration
                if config.kind == .http, !self.bearer.isEmpty {
                    var headers = try config.stringMap(config.headers, name: "请求头")
                    guard !headers.keys.contains(where: { $0.lowercased() == "authorization" }) else {
                        throw ToolError.invalid("Bearer Token 与自定义 Authorization 请求头只能填写一个。")
                    }
                    headers["Authorization"] = "Bearer " + self.bearer; config.headers = MCPJSON.text(headers)
                }
                try await self.client.connect(config)
            }
            self.notice = demo ? "本地演示已连接，不联网、不调用模型。" : "已连接。选择条目查看详情，操作仅在点击按钮后发送。"
            try await self.loadCategory()
        }
    }
    func select(_ entry: MCPEntry) {
        guard !busy else { return }
        selectedID = entry.id; arguments = entry.exampleArguments; resourceURI = entry.uri; result = nil; error = nil
    }
    func changeCategory() {
        guard !busy else { return }
        selectedID = nil; result = nil
        if connected {
            if loaded.contains(category) { if let first = entries[category]?.first { select(first) } }
            else { refresh() }
        }
    }
    func refresh() { guard connected, !busy else { return }; run("加载列表…") { try await self.loadCategory() } }
    private func loadCategory() async throws {
        let category = self.category
        let values = try await client.list(category)
        try Task.checkCancellation()
        entries[category] = values; loaded.insert(category)
        if let current = selectedID, values.contains(where: { $0.id == current }) {} else {
            selectedID = values.first?.id; result = nil
            if let first = values.first { arguments = first.exampleArguments; resourceURI = first.uri }
        }
    }
    func validateOperation() -> Bool {
        guard let entry = selected else { return false }
        do {
            if entry.kind == .tool || entry.kind == .prompt { _ = try MCPJSON.object(arguments) }
            error = nil; return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func perform() {
        guard connected, !busy, let entry = selected, validateOperation() else { return }
        let arguments = self.arguments, uri = self.resourceURI
        result = nil
        run(entry.kind == .tool ? "调用工具…" : entry.kind == .prompt ? "获取 Prompt…" : "读取资源…") {
            let value = try await self.client.perform(entry, arguments: arguments, uri: uri)
            try Task.checkCancellation()
            self.result = value
            self.notice = value.isError ? "工具返回业务错误，连接仍然可用。" : "已收到返回，用时 \(String(format: "%.0f", value.elapsed * 1000)) ms。"
        }
    }
    private func run(_ title: String, body: @escaping @MainActor () async throws -> Void) {
        busy = true; action = title; error = nil; notice = nil
        let id = UUID(); operationID = id
        operation = Task {
            defer { if self.operationID == id { self.busy = false; self.operation = nil; self.action = "" } }
            do { try await body() }
            catch is CancellationError { if self.operationID == id { self.notice = "已停止等待；服务端操作可能仍在继续。" } }
            catch { if self.operationID == id { self.error = error.localizedDescription } }
        }
    }
    func stop() { operation?.cancel() }
    func disconnect() {
        operationID = UUID(); operation?.cancel(); operation = nil; busy = false; action = ""
        client.disconnect(); notice = "已断开连接。"
    }
    func clearLogs() { client.clearLogs() }
    func chooseExecutable() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = "选择 MCP 服务或运行时可执行文件（例如 node、uvx、python3）"
        if panel.runModal() == .OK, let url = panel.url { configuration.executable = url.path }
    }
    func exportResult() {
        guard let result else { return }
        save(result.raw, name: "mcp-result.json")
    }
    func exportLogs() {
        let entries: [[String: Any]] = logs.map { ["time": ISO8601DateFormatter().string(from: $0.date), "direction": $0.direction, "preview": $0.text] }
        save(MCPJSON.text(entries), name: "mcp-session-log.json")
    }
    private func save(_ text: String, name: String) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = name
        panel.message = "导出可能包含请求参数、服务返回和敏感数据，请按需保存。"
        if panel.runModal() == .OK, let url = panel.url {
            do { try text.write(to: url, atomically: true, encoding: .utf8) } catch { self.error = error.localizedDescription }
        }
    }
}
