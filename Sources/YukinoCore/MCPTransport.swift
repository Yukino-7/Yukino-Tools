import Foundation
import Darwin

enum MCPTransportEvent: Sendable {
    case message(Data), diagnostic(String), failed(Int?, String), closed(String)
}

@MainActor protocol MCPTransport: AnyObject {
    var receive: ((MCPTransportEvent) -> Void)? { get set }
    var protocolVersion: String? { get set }
    func start() throws
    func send(_ data: Data, id: Int?)
    func notify(_ data: Data) async throws
    func cancel(_ id: Int)
    func close()
}

/// No shell or command expansion. stdout is newline-delimited JSON-RPC; stderr is diagnostic only.
@MainActor final class MCPStdioTransport: MCPTransport {
    var receive: ((MCPTransportEvent) -> Void)?
    var protocolVersion: String?
    private let configuration: MCPConnectionConfiguration
    private let process = Process()
    private let input = Pipe(), output = Pipe(), errorPipe = Pipe()
    private let writes = DispatchQueue(label: "com.yukino.mcp.stdin")
    private var reader: Task<Void, Never>?
    private var buffer = Data()
    private var active = false

    init(_ configuration: MCPConnectionConfiguration) { self.configuration = configuration }
    func start() throws {
        process.executableURL = URL(fileURLWithPath: configuration.executable)
        process.arguments = try configuration.parsedArguments()
        var environment = ProcessInfo.processInfo.environment
        // Finder-launched apps have a short PATH. Explicit executables still need child runtimes.
        environment["PATH"] = ["/opt/homebrew/bin", "/usr/local/bin", environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"].joined(separator: ":")
        environment.merge(try configuration.stringMap(configuration.environment, name: "环境变量"), uniquingKeysWith: { _, new in new })
        process.environment = environment
        if !configuration.directory.isEmpty { process.currentDirectoryURL = URL(fileURLWithPath: configuration.directory) }
        process.standardInput = input; process.standardOutput = output; process.standardError = errorPipe
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        let (stream, continuation) = AsyncStream<MCPTransportEvent>.makeStream(bufferingPolicy: .bufferingOldest(128))
        let enqueue: @Sendable (MCPTransportEvent) -> Void = { event in
            if case .dropped = continuation.yield(event) {
                continuation.finish()
            }
        }
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; enqueue(.closed("服务关闭了标准输出。")); continuation.finish() }
            else { enqueue(.message(data)) }
        }
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            else { enqueue(.diagnostic(String(decoding: data.prefix(16_384), as: UTF8.self))) }
        }
        do { try process.run(); active = true }
        catch { output.fileHandleForReading.readabilityHandler = nil; errorPipe.fileHandleForReading.readabilityHandler = nil; continuation.finish(); throw error }
        reader = Task { [weak self] in
            for await event in stream {
                guard let self, !Task.isCancelled, self.active else { break }
                if case .message(let bytes) = event { self.consume(bytes) }
                else { self.receive?(event) }
            }
            guard let self, self.active, !Task.isCancelled else { return }
            self.receive?(.closed("标准输出已结束或接收队列超出限制。"))
        }
    }
    private func consume(_ bytes: Data) {
        buffer.append(bytes)
        while let newline = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
            guard line.count <= MCPJSON.limit else { receive?(.closed("单条 MCP 消息超过 4 MiB。")); return }
            if !line.isEmpty { receive?(.message(line)) }
            if !active { return }
        }
        if buffer.count > MCPJSON.limit { receive?(.closed("单条 MCP 消息超过 4 MiB。")) }
    }
    func send(_ data: Data, id: Int?) {
        guard active else { receive?(.failed(id, "stdio 已断开。")); return }
        var line = data; line.append(10)
        let handle = input.fileHandleForWriting
        writes.async { [weak self] in
            do { try handle.write(contentsOf: line) }
            catch { Task { @MainActor in self?.receive?(.failed(id, "写入 MCP 进程失败：\(error.localizedDescription)")) } }
        }
    }
    func cancel(_ id: Int) {} // JSON-RPC cancellation is sent by the client over the same pipe.
    func close() {
        guard active else { return }
        active = false; reader?.cancel(); reader = nil
        output.fileHandleForReading.readabilityHandler = nil; errorPipe.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        try? output.fileHandleForReading.close(); try? errorPipe.fileHandleForReading.close()
        let child = process
        Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            if child.isRunning { child.terminate() }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if child.isRunning { Darwin.kill(child.processIdentifier, SIGKILL) }
        }
    }
}

private final class MCPNoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

/// POST responses may be JSON or SSE. GET notification streams and legacy HTTP+SSE are not opened.
@MainActor final class MCPHTTPTransport: MCPTransport {
    var receive: ((MCPTransportEvent) -> Void)?
    var protocolVersion: String?
    private var sessionID: String?
    private let configuration: MCPConnectionConfiguration
    private var operations = [UUID: Task<Void, Never>]()
    private var requestKeys = [Int: UUID]()
    private var active = false
    private let session: URLSession
    init(_ configuration: MCPConnectionConfiguration, session: URLSession? = nil) {
        self.configuration = configuration
        if let session { self.session = session }
        else {
            let settings = URLSessionConfiguration.ephemeral
            settings.httpCookieStorage = nil; settings.urlCache = nil; settings.urlCredentialStorage = nil
            settings.timeoutIntervalForRequest = configuration.timeout
            settings.timeoutIntervalForResource = configuration.timeout
            self.session = URLSession(configuration: settings, delegate: MCPNoRedirectDelegate(), delegateQueue: nil)
        }
    }
    func start() throws { active = true }
    private func request(_ method: String, data: Data? = nil) throws -> URLRequest {
        var request = URLRequest(url: URL(string: configuration.endpoint)!)
        request.httpMethod = method; request.httpBody = data; request.timeoutInterval = configuration.timeout
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (name, value) in try configuration.stringMap(configuration.headers, name: "请求头") { request.setValue(value, forHTTPHeaderField: name) }
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "MCP-Session-Id") }
        if let protocolVersion { request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version") }
        return request
    }
    func send(_ data: Data, id: Int?) {
        guard active else { receive?(.failed(id, "HTTP 会话已断开。")); return }
        let key = UUID()
        if let id { requestKeys[id] = key }
        operations[key] = Task { [weak self] in
            guard let self else { return }
            defer { self.operations[key] = nil; if let id, self.requestKeys[id] == key { self.requestKeys[id] = nil } }
            do {
                let request = try self.request("POST", data: data)
                let (bytes, response) = try await self.session.bytes(for: request)
                defer { bytes.task.cancel() }
                guard !Task.isCancelled, self.active else { return }
                guard let http = response as? HTTPURLResponse else { throw ToolError.invalid("服务未返回 HTTP 响应。") }
                guard (200...299).contains(http.statusCode) else {
                    throw ToolError.invalid(http.statusCode == 404 && self.sessionID != nil ? "HTTP 404：MCP 会话可能已失效，请重新连接。" : "HTTP \(http.statusCode)：检查 MCP 地址与认证。重定向不会自动跟随。")
                }
                if let value = http.value(forHTTPHeaderField: "MCP-Session-Id"), self.protocolVersion == nil {
                    guard !value.isEmpty, value.utf8.allSatisfy({ (33...126).contains($0) }) else { throw ToolError.invalid("服务返回了无效的 MCP-Session-Id。") }
                    self.sessionID = value
                }
                if id == nil {
                    guard http.statusCode == 202 else { throw ToolError.invalid("通知或响应应返回 HTTP 202，实际为 \(http.statusCode)。") }
                    return
                }
                let type = http.value(forHTTPHeaderField: "Content-Type")?.lowercased().split(separator: ";").first?.trimmingCharacters(in: .whitespaces) ?? ""
                guard type == "text/event-stream" || type == "application/json" else { throw ToolError.invalid("响应 Content-Type 不是 application/json 或 text/event-stream。") }
                var buffer = Data(), parser = SSEParser(), count = 0
                for try await byte in bytes {
                    try Task.checkCancellation()
                    count += 1
                    guard count <= MCPJSON.limit else { throw ToolError.invalid("本次 HTTP 响应超过 4 MiB，已停止。") }
                    buffer.append(byte)
                    if type == "text/event-stream", byte == 10 || byte == 13 || buffer.count >= 4096 {
                        let events = try parser.feed(buffer); buffer.removeAll(keepingCapacity: true)
                        for event in events where !event.isComment && !event.data.isEmpty {
                            let message = Data(event.data.utf8)
                            self.receive?(.message(message))
                            if Self.matches(message, id: id!) { return }
                        }
                    }
                }
                if type == "application/json" {
                    self.receive?(.message(buffer))
                    guard Self.matches(buffer, id: id!) else { throw ToolError.invalid("HTTP JSON 响应 ID 与请求不匹配。") }
                } else { throw ToolError.invalid("SSE 已结束，未收到本次请求的 JSON-RPC 响应；请手动重试。") }
            } catch {
                if !Task.isCancelled, self.active { self.receive?(.failed(id, error.localizedDescription)) }
            }
        }
    }
    private static func matches(_ data: Data, id: Int) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return object["id"] as? Int == id && (object["result"] != nil || object["error"] != nil)
    }
    func notify(_ data: Data) async throws {
        let request = try request("POST", data: data)
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse, http.statusCode == 202 else {
            throw ToolError.invalid("MCP 初始化通知未被接受（需要 HTTP 202）。")
        }
    }
    func cancel(_ id: Int) {
        if let key = requestKeys.removeValue(forKey: id) { operations.removeValue(forKey: key)?.cancel() }
    }
    func close() {
        guard active else { return }
        active = false
        for task in operations.values { task.cancel() }
        operations.removeAll(); requestKeys.removeAll()
        let cleanup = sessionID != nil ? try? request("DELETE") : nil
        sessionID = nil
        let session = session
        Task {
            if var request = cleanup { request.timeoutInterval = 3; _ = try? await session.data(for: request) }
            session.invalidateAndCancel()
        }
    }
}
