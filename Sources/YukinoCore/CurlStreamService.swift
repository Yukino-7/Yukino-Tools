import Foundation
import Darwin

public struct CurlExecutionPlan: Sendable {
    public let configuration: Data
    public let url: String
    public let warnings: [String]

    public init(_ plan: CurlCommandPlan, connectTimeout: Int = 15, totalTimeout: Int = 0) throws {
        let values: Set<String> = ["--request", "--header", "--data", "--data-raw", "--data-binary", "--data-urlencode", "--json", "--form-string", "--user", "--oauth2-bearer", "--url", "--url-query", "--connect-timeout", "--max-time", "--user-agent", "--referer", "--cookie", "--proxy", "--resolve", "--range"]
        let flags: Set<String> = ["--globoff", "--location", "--head", "--compressed", "--insecure", "--get", "--http1.1", "--http2", "--path-as-is", "--basic", "--digest", "--anyauth"]
        let displayFlags: Set<String> = ["--disable", "--no-buffer", "--include", "--verbose", "--silent", "--show-error", "--fail", "--fail-with-body"]
        var lines = ["globoff", "no-buffer", "silent", "show-error", "proto = \"=http,https\"", "proto-redir = \"=http,https\"", "max-redirs = \"5\""]
        var notices = ["实际调用禁用 .curlrc；响应头、响应体与错误输出独立接收；不自动重试。"]
        var sensitiveRedirect = plan.containsCredentials
        for index in plan.arguments.indices where plan.arguments[index] == "--header" && index + 1 < plan.arguments.count {
            let name = plan.arguments[index + 1].split(separator: ":", maxSplits: 1).first.map(String.init)?.lowercased() ?? ""
            if !["accept", "content-type", "user-agent", "cache-control", "connection"].contains(name) { sensitiveRedirect = true }
        }
        var names = Set<String>(), i = 0
        while i < plan.arguments.count {
            let option = plan.arguments[i]; i += 1
            if values.contains(option) {
                guard i < plan.arguments.count else { throw ToolError.invalid("\(option) 缺少参数。") }
                let value = plan.arguments[i]; i += 1
                if ["--data", "--data-binary", "--json", "--header", "--cookie"].contains(option) && value.hasPrefix("@") || option == "--data-urlencode" && value.contains("@") || option == "--cookie" && !value.isEmpty && !value.contains("=") {
                    throw ToolError.invalid("调试调用不读取文件：\(option)。请直接粘贴文件内容。")
                }
                if ["--connect-timeout", "--max-time"].contains(option) {
                    guard let number = Double(value), number.isFinite, number >= 0, number <= 86400 else { throw ToolError.invalid("超时须为 0–86400 秒。") }
                }
                if option == "--url", let scheme = URLComponents(string: value)?.scheme?.lowercased(), !["http", "https"].contains(scheme) { throw ToolError.invalid("只支持 HTTP / HTTPS 请求。") }
                names.insert(option)
                lines.append(String(option.dropFirst(2)) + " = " + (try Self.quote(value)))
            } else if flags.contains(option) {
                if option == "--location" && sensitiveRedirect { throw ToolError.invalid("含认证信息的请求暂不自动跟随重定向。请移除 -L，检查响应头后使用最终地址。") }
                if option == "--insecure" { notices.append("当前请求包含 -k：TLS 证书验证已关闭。") }
                lines.append(String(option.dropFirst(2)))
            } else if ["--proto", "--proto-redir"].contains(option) {
                guard i < plan.arguments.count else { throw ToolError.invalid("\(option) 缺少参数。") }
                guard ["=http,https", "=https,http", "=https", "=http"].contains(plan.arguments[i]) else { throw ToolError.invalid("协议限制仅支持 HTTP / HTTPS。") }
                lines.append(String(option.dropFirst(2)) + " = " + (try Self.quote(plan.arguments[i]))); i += 1
            } else if displayFlags.contains(option) {
                if ["--include", "--verbose", "--fail", "--fail-with-body"].contains(option) { notices.append("\(option) 已规范化：完整保留错误响应体，并分离响应通道。") }
            } else { throw ToolError.invalid("暂不执行选项 \(option)。请移除此参数；原 cURL 转换功能仍可使用。") }
        }
        if !names.contains("--connect-timeout") { lines.append("connect-timeout = \"\(max(1, connectTimeout))\"") }
        if !names.contains("--max-time"), totalTimeout > 0 { lines.append("max-time = \"\(totalTimeout)\"") }
        self.configuration = Data((lines.joined(separator: "\n") + "\n").utf8)
        self.url = plan.url; self.warnings = notices
    }
    public static func quote(_ value: String) throws -> String {
        guard !value.contains("\0") else { throw ToolError.invalid("参数不能包含 NUL。") }
        return "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t").replacingOccurrences(of: "\u{0B}", with: "\\v") + "\""
    }
}

public enum CurlStreamUpdate: Sendable {
    case body(Data, TimeInterval)
    case headers(String)
    case diagnostic(String)
    case finished(Int32, TimeInterval, String?)
}

/// A fixed curl executable, stdin config and separately drained pipes; no shell or credential argv.
public final class CurlStreamRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var lastData = ProcessInfo.processInfo.systemUptime
    private var failure: String?
    public init() {}
    public func cancel() {
        lock.lock(); cancelled = true; let current = process; lock.unlock()
        if let current, current.isRunning { current.terminate() }
    }
    private func stop(_ reason: String) {
        lock.lock(); if failure == nil { failure = reason }; lock.unlock(); cancel()
    }
    public func stream(_ plan: CurlExecutionPlan, idleTimeout: Int = 90) -> AsyncThrowingStream<CurlStreamUpdate, Error> {
        AsyncThrowingStream { continuation in
            continuation.onTermination = { [weak self] reason in if case .cancelled = reason { self?.cancel() } }
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                let started = ProcessInfo.processInfo.systemUptime
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("YukinoStream-" + UUID().uuidString)
                let headerURL = folder.appendingPathComponent("headers")
                let task = Process(), output = Pipe(), diagnostic = Pipe(), input = Pipe()
                defer { try? FileManager.default.removeItem(at: folder) }
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    task.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
                    task.arguments = ["--disable", "--config", "-", "--dump-header", headerURL.path]
                    task.standardInput = input; task.standardOutput = output; task.standardError = diagnostic
                    // Keep proxy configuration but do not inherit provider keys or arbitrary runtime injection.
                    let environment = ProcessInfo.processInfo.environment
                    task.environment = environment.filter { ["HOME", "PATH", "TMPDIR", "LANG", "LC_ALL", "http_proxy", "https_proxy", "all_proxy", "no_proxy", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY"].contains($0.key) }
                    lock.lock()
                    if cancelled { lock.unlock(); continuation.finish(); return }
                    process = task; lastData = started
                    do { try task.run() } catch { lock.unlock(); throw error }
                    lock.unlock()
                    try? input.fileHandleForReading.close()
                    try? output.fileHandleForWriting.close()
                    try? diagnostic.fileHandleForWriting.close()
                    let readers = DispatchGroup()
                    readers.enter()
                    DispatchQueue.global(qos: .userInitiated).async {
                        var size = 0
                        while true {
                            let data = output.fileHandleForReading.availableData
                            if data.isEmpty { break }
                            size += data.count
                            if size > 20 * 1_048_576 { self.stop("响应体超过 20 MiB，已停止接收。"); break }
                            self.lock.lock(); self.lastData = ProcessInfo.processInfo.systemUptime; self.lock.unlock()
                            continuation.yield(.body(data, ProcessInfo.processInfo.systemUptime - started))
                        }
                        try? output.fileHandleForReading.close(); readers.leave()
                    }
                    readers.enter()
                    DispatchQueue.global(qos: .utility).async {
                        var size = 0
                        while true {
                            let data = diagnostic.fileHandleForReading.availableData
                            if data.isEmpty { break }
                            size += data.count
                            if size > 1_048_576 { self.stop("cURL 诊断超过 1 MiB，已停止接收。"); break }
                            continuation.yield(.diagnostic(String(decoding: data, as: UTF8.self)))
                        }
                        try? diagnostic.fileHandleForReading.close(); readers.leave()
                    }
                    readers.enter()
                    DispatchQueue.global(qos: .utility).async {
                        // Ignore SIGPIPE on this writer thread if curl exits before consuming its config.
                        var signals = sigset_t(); sigemptyset(&signals); sigaddset(&signals, SIGPIPE); pthread_sigmask(SIG_BLOCK, &signals, nil)
                        try? input.fileHandleForWriting.write(contentsOf: plan.configuration)
                        try? input.fileHandleForWriting.close(); readers.leave()
                    }
                    var oldHeaders = ""
                    var cancellationBegan: TimeInterval?
                    func readHeaders() {
                        if let attributes = try? FileManager.default.attributesOfItem(atPath: headerURL.path), (attributes[.size] as? NSNumber)?.intValue ?? 0 > 1_048_576 { self.stop("响应头超过 1 MiB，已停止接收。"); return }
                        if let data = try? Data(contentsOf: headerURL), !data.isEmpty {
                            let text = String(decoding: data, as: UTF8.self)
                            if text != oldHeaders { oldHeaders = text; continuation.yield(.headers(text)) }
                        }
                    }
                    while task.isRunning {
                        readHeaders()
                        lock.lock(); let stopped = cancelled, idle = ProcessInfo.processInfo.systemUptime - lastData; lock.unlock()
                        if stopped {
                            if cancellationBegan == nil { cancellationBegan = ProcessInfo.processInfo.systemUptime }
                            if task.isRunning {
                                if ProcessInfo.processInfo.systemUptime - (cancellationBegan ?? 0) > 1 { kill(task.processIdentifier, SIGKILL) }
                                else { task.terminate() }
                            }
                        }
                        else if idleTimeout > 0 && idle > Double(idleTimeout) { stop("超过 \(idleTimeout) 秒未收到响应体数据，已停止。") }
                        Thread.sleep(forTimeInterval: 0.05)
                    }
                    task.waitUntilExit(); readers.wait(); readHeaders()
                    lock.lock(); let reason = failure; process = nil; lock.unlock()
                    continuation.yield(.finished(task.terminationStatus, ProcessInfo.processInfo.systemUptime - started, reason))
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
        }
    }
}
