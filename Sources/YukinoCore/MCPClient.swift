import Foundation
import CoreFoundation

/// One explicitly connected session. No automatic reconnects or tool execution.
@MainActor public final class MCPClient {
    public private(set) var connected = false
    public private(set) var serverName = ""
    public private(set) var protocolVersion = ""
    public private(set) var serverDetails = ""
    public private(set) var capabilities = Set<String>()
    public private(set) var logs = [MCPLogEntry]()
    public var onChange: (() -> Void)?
    private var transport: MCPTransport?
    private var generation = UUID()
    private var sequence = 0
    private var timeout: TimeInterval = 30
    private struct Pending {
        let continuation: CheckedContinuation<[String: Any], Error>
        let timer: Task<Void, Never>
        let method: String
    }
    private var pending = [Int: Pending]()
    public init() {}

    public func connect(_ configuration: MCPConnectionConfiguration) async throws {
        try configuration.validate()
        let transport: MCPTransport = configuration.kind == .stdio ? MCPStdioTransport(configuration) : MCPHTTPTransport(configuration)
        try await connect(using: transport, timeout: configuration.timeout, http: configuration.kind == .http)
    }
    public func connectDemo() async throws { try await connect(using: MCPDemoTransport(), timeout: 10) }
    func connect(using transport: MCPTransport, timeout: TimeInterval = 30, http: Bool = false) async throws {
        disconnect(); clearLogs()
        let generation = self.generation
        self.transport = transport; self.timeout = timeout
        transport.receive = { [weak self] event in
            guard let self, self.generation == generation else { return }
            self.receive(event)
        }
        do {
            try transport.start()
            let result = try await request("initialize", params: "{\"protocolVersion\":\"2025-11-25\",\"capabilities\":{},\"clientInfo\":{\"name\":\"yukino-tools\",\"version\":\"1.0\"}}")
            let accepted = http ? ["2025-11-25", "2025-06-18", "2025-03-26"] : ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
            guard let version = result["protocolVersion"] as? String, accepted.contains(version),
                  let info = result["serverInfo"] as? [String: Any], let name = info["name"] as? String,
                  let caps = result["capabilities"] as? [String: Any] else { throw ToolError.invalid("初始化返回不完整，或服务协商了本工具尚不支持的协议版本。") }
            guard self.generation == generation else { throw CancellationError() }
            guard caps.values.allSatisfy({ $0 is [String: Any] }) else { throw ToolError.invalid("服务能力声明必须是 JSON 对象。") }
            protocolVersion = version; transport.protocolVersion = version
            serverName = name + ((info["version"] as? String).map { " · " + $0 } ?? "")
            serverDetails = MCPJSON.text(result)
            capabilities = Set(caps.keys)
            try await notification("notifications/initialized")
            try Task.checkCancellation()
            guard self.generation == generation else { throw CancellationError() }
            connected = true; onChange?()
        } catch {
            if self.generation == generation { disconnect(reason: error.localizedDescription) }
            throw error
        }
    }
    public func disconnect(reason: String? = nil) {
        generation = UUID(); connected = false
        transport?.receive = nil; transport?.close(); transport = nil
        let previous = pending; pending.removeAll()
        for value in previous.values {
            value.timer.cancel()
            if let reason { value.continuation.resume(throwing: ToolError.invalid(reason)) }
            else { value.continuation.resume(throwing: CancellationError()) }
        }
        serverName = ""; protocolVersion = ""; serverDetails = ""; capabilities.removeAll()
        if let reason { log("连接", reason) } else { onChange?() }
    }
    public func clearLogs() { logs.removeAll(); onChange?() }
    private func log(_ direction: String, _ text: String) {
        logs.append(MCPLogEntry(direction: direction, text: text))
        if logs.count > 200 { logs.removeFirst(logs.count - 200) }
        onChange?()
    }
    public func list(_ kind: MCPEntry.Kind) async throws -> [MCPEntry] {
        try requireConnected()
        let capability: String, method: String, key: String
        switch kind {
        case .tool: (capability, method, key) = ("tools", "tools/list", "tools")
        case .resource: (capability, method, key) = ("resources", "resources/list", "resources")
        case .template: (capability, method, key) = ("resources", "resources/templates/list", "resourceTemplates")
        case .prompt: (capability, method, key) = ("prompts", "prompts/list", "prompts")
        }
        guard capabilities.contains(capability) else { return [] }
        var entries = [MCPEntry](), cursor: String?, visited = Set<String>(), identifiers = Set<String>(), totalBytes = 0
        for _ in 0..<100 {
            let result = try await request(method, params: cursor.map { "{\"cursor\":\(MCPJSON.quote($0))}" } ?? "{}")
            guard let objects = result[key] as? [[String: Any]] else { throw ToolError.invalid("\(method) 响应缺少有效的 \(key) 列表。") }
            for object in objects {
                let entry = try MCPEntry(kind: kind, object: object)
                totalBytes += entry.metadata.utf8.count
                guard totalBytes <= 16 * 1_024 * 1_024 else { throw ToolError.invalid("目录定义累计超过 16 MiB，已停止加载。") }
                guard identifiers.insert(entry.id).inserted else { throw ToolError.invalid("服务返回了重复条目：\(entry.name)。") }
                entries.append(entry)
                guard entries.count <= 2_000 else { throw ToolError.invalid("列表超过 2,000 项，已停止加载。") }
            }
            if result["nextCursor"] == nil { return entries }
            guard let next = result["nextCursor"] as? String, !next.isEmpty, visited.insert(next).inserted else {
                throw ToolError.invalid("分页游标无效或重复，已停止加载。")
            }
            cursor = next
        }
        throw ToolError.invalid("分页超过 100 页，已停止加载。")
    }
    public func perform(_ entry: MCPEntry, arguments: String, uri: String = "") async throws -> MCPResult {
        try requireConnected()
        let start = ProcessInfo.processInfo.systemUptime
        let method: String, params: String
        switch entry.kind {
        case .tool:
            _ = try MCPJSON.object(arguments)
            let metadata = try MCPJSON.object(entry.metadata)
            if (metadata["execution"] as? [String: Any])?["taskSupport"] as? String == "required" {
                throw ToolError.invalid("此工具要求异步任务协议，首版尚不支持。")
            }
            method = "tools/call"; params = "{\"name\":\(MCPJSON.quote(entry.name)),\"arguments\":\(try JSONService.transform(arguments, minify: true))}"
        case .prompt:
            let values = try MCPJSON.object(arguments)
            guard values.values.allSatisfy({ $0 is String }) else { throw ToolError.invalid("Prompt 参数的值必须都是字符串。") }
            let metadata = try MCPJSON.object(entry.metadata)
            for argument in metadata["arguments"] as? [[String: Any]] ?? [] {
                if argument["required"] as? Bool == true, let name = argument["name"] as? String, values[name] == nil {
                    throw ToolError.invalid("缺少必填 Prompt 参数：\(name)。")
                }
            }
            method = "prompts/get"; params = "{\"name\":\(MCPJSON.quote(entry.name)),\"arguments\":\(try JSONService.transform(arguments, minify: true))}"
        case .resource, .template:
            let target = uri.isEmpty ? entry.uri : uri
            guard !target.isEmpty, !target.contains("{"), !target.contains("}"), target.utf8.count <= 16_384 else { throw ToolError.invalid("请先填写完整的资源 URI，替换模板中的 {参数}。") }
            method = "resources/read"; params = "{\"uri\":\(MCPJSON.quote(target))}"
        }
        let result = try await request(method, params: params)
        return MCPResult(object: result, elapsed: ProcessInfo.processInfo.systemUptime - start)
    }
    private func requireConnected() throws {
        guard connected else { throw ToolError.invalid("请先连接 MCP 服务。") }
    }
    private func notification(_ method: String) async throws {
        guard let transport else { throw CancellationError() }
        let data = Data("{\"jsonrpc\":\"2.0\",\"method\":\(MCPJSON.quote(method))}".utf8)
        log("发送", String(decoding: data, as: UTF8.self))
        try await transport.notify(data)
    }
    func request(_ method: String, params: String = "{}") async throws -> [String: Any] {
        try Task.checkCancellation()
        guard let transport else { throw ToolError.invalid("MCP 连接已关闭。") }
        _ = try MCPJSON.object(params)
        sequence += 1; let id = sequence; let generation = self.generation
        let data = Data("{\"jsonrpc\":\"2.0\",\"id\":\(id),\"method\":\(MCPJSON.quote(method)),\"params\":\(params)}".utf8)
        guard data.count <= MCPJSON.limit else { throw ToolError.invalid("请求超过 4 MiB。") }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timer = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: UInt64((self?.timeout ?? 30) * 1_000_000_000)) } catch { return }
                    guard let self, self.generation == generation else { return }
                    self.cancel(id, error: ToolError.invalid("请求超时，已停止等待。取消通知不保证服务端操作已停止。"))
                }
                pending[id] = Pending(continuation: continuation, timer: timer, method: method)
                log("发送", String(decoding: data, as: UTF8.self)); transport.send(data, id: id)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                self.cancel(id, error: CancellationError())
            }
        }
    }
    private func cancel(_ id: Int, error: Error) {
        guard let value = pending.removeValue(forKey: id) else { return }
        value.timer.cancel()
        if value.method != "initialize" {
            let data = Data("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{\"requestId\":\(id),\"reason\":\"Client stopped waiting\"}}".utf8)
            log("发送", String(decoding: data, as: UTF8.self)); transport?.send(data, id: nil)
        }
        transport?.cancel(id)
        log("取消", error is CancellationError ? "已停止等待；服务端操作可能仍在继续。" : error.localizedDescription)
        value.continuation.resume(throwing: error)
    }
    private func receive(_ event: MCPTransportEvent) {
        switch event {
        case .diagnostic(let text): log("stderr", text)
        case .closed(let reason): disconnect(reason: reason)
        case .failed(let id, let reason):
            log("传输错误", reason)
            if let id, let value = pending.removeValue(forKey: id) { value.timer.cancel(); value.continuation.resume(throwing: ToolError.invalid(reason)) }
            else if id == nil { disconnect(reason: reason) }
        case .message(let data):
            do {
                guard let text = String(data: data, encoding: .utf8) else { throw ToolError.invalid("消息不是有效 UTF-8。") }
                let object = try MCPJSON.object(text)
                guard object["jsonrpc"] as? String == "2.0" else { throw ToolError.invalid("消息缺少 jsonrpc: 2.0。") }
                log("接收", String(decoding: data, as: UTF8.self))
                if let method = object["method"] as? String {
                    if let id = object["id"], id is String || Self.numericID(id) != nil {
                        var response: [String: Any] = ["jsonrpc": "2.0", "id": id]
                        if method == "ping" { response["result"] = [String: Any]() }
                        else { response["error"] = ["code": -32601, "message": "Client capability not supported"] }
                        let text = MCPJSON.text(response); log("发送", text)
                        transport?.send(try JSONSerialization.data(withJSONObject: response), id: nil)
                    }
                    return
                }
                guard let id = Self.numericID(object["id"]), let value = pending.removeValue(forKey: id) else {
                    log("诊断", "忽略未知或已经取消的响应 ID。"); return
                }
                value.timer.cancel()
                if let error = object["error"] as? [String: Any], object["result"] == nil {
                    value.continuation.resume(throwing: ToolError.invalid("JSON-RPC \(error["code"] ?? "?")：\(error["message"] as? String ?? MCPJSON.text(error))"))
                } else if let result = object["result"] as? [String: Any], object["error"] == nil { value.continuation.resume(returning: result) }
                else { value.continuation.resume(throwing: ToolError.invalid("JSON-RPC 响应必须恰有一个 result 对象或 error 对象。")) }
            } catch { disconnect(reason: "无效 MCP 消息：\(error.localizedDescription)") }
        }
    }
    private static func numericID(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue == Double(number.intValue) else { return nil }
        return number.intValue
    }
}

extension MCPTransport {
    func notify(_ data: Data) async throws { send(data, id: nil) }
}
