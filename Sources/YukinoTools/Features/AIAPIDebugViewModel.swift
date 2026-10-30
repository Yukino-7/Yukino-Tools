import SwiftUI
import AppKit
import YukinoCore

@MainActor final class AIAPIDebugViewModel: ObservableObject {
    @Published var command = ""
    @Published var shell = CurlShell.bash
    @Published var automaticShell = true
    @Published var formattedJSON: String?
    @Published var responseEndpoint = ""
    @Published var mode = AIStreamMode.automatic
    @Published var fieldPath = ""
    @Published var cumulative = false
    @Published var apiKey = ""
    @Published var idleTimeout = 90
    @Published var totalTimeout = 0
    @Published var running = false
    @Published var status = "准备就绪"
    @Published var error: String?
    @Published var warnings = [String]()
    @Published var headers = ""
    @Published var diagnostics = ""
    @Published var events = [SSEEvent]()
    @Published var accumulator = AIStreamAccumulator()
    @Published var byteCount = 0
    @Published var elapsed: TimeInterval = 0
    @Published var firstEvent: TimeInterval?
    @Published var firstText: TimeInterval?
    @Published var firstByte: TimeInterval?
    @Published var isSSE = false
    @Published var demo = false
    @Published var renderedAnswers: [String: [MarkdownBlock]] = [:]
    private var renderedSources: [String: String] = [:]
    private var lastRender = 0.0
    @Published var revision = 0
    @Published var inputError: String?
    @Published var endpoint = ""
    private var parser = SSEParser()
    private var raw = Data()
    private var pendingEvents = [SSEEvent]()
    private var current = AIStreamAccumulator()
    private var runner: CurlStreamRunner?
    private var operation: Task<Void, Never>?
    private var validation: Task<Void, Never>?
    private var generation = UUID()
    private var lastPublish = 0.0
    private var stopped = false
    private var forcedSSE = false
    private var parsedBytes = 0
    private var clockTask: Task<Void, Never>?
    private var liveFirstEvent: TimeInterval?
    private var liveFirstText: TimeInterval?
    private var liveFirstByte: TimeInterval?
    private var liveElapsed = 0.0
    var rawText: String { String(decoding: raw, as: UTF8.self) }
    var responseText: String { formattedJSON ?? rawText }
    var responseFormat: String { isSSE ? "SSE" : formattedJSON != nil ? "JSON" : "响应体" }
    var hasResponse: Bool { byteCount > 0 || !headers.isEmpty }
    var canSend: Bool {
        !running && !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && inputError == nil
            && (!command.contains("{{API_KEY}}") || !apiKey.isEmpty)
    }
    var messageCount: Int { events.filter { !$0.isComment }.count }
    var httpStatus: String { headers.components(separatedBy: .newlines).filter { $0.hasPrefix("HTTP/") }.last ?? "" }
    var usage: String { accumulator.usage }
    static let example = """
    curl https://api.example.com/v1/chat/completions \\
      -H 'Authorization: Bearer {{API_KEY}}' \\
      -H 'Content-Type: application/json' \\
      -d '{
        "model": "your-model",
        "messages": [{"role": "user", "content": "你好，请用三句话介绍 SSE。"}],
        "stream": true
      }'
    """

    func scheduleValidation() {
        validation?.cancel()
        let input = command, source = automaticShell ? CurlCommandParser.detectedShell(command) : shell
        validation = Task {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { inputError = nil; endpoint = ""; return }
            do {
                let plan = try CurlCommandParser.parse(input, shell: source)
                if shell != source { shell = source }
                let url = URLComponents(string: plan.url)
                endpoint = (url?.host ?? "") + (url?.path ?? "")
                _ = try CurlExecutionPlan(plan, totalTimeout: totalTimeout)
                inputError = nil
            } catch { inputError = error.localizedDescription; endpoint = "请求尚未就绪" }
        }
    }
    func loadExample() { guard !running else { return }; command = Self.example; shell = .bash; automaticShell = true; scheduleValidation() }
    func loadJSONExample() {
        guard !running else { return }
        command = "curl 'https://example.com/api/items' -H 'Accept: application/json'"
        shell = .bash; automaticShell = true; scheduleValidation()
    }
    func loadFavorite(_ favorite: CurlFavorite) {
        guard !running else { return }
        command = favorite.command; shell = favorite.sourceShell; automaticShell = false; apiKey = ""
        scheduleValidation()
    }
    func clear() { guard !running else { return }; command = ""; apiKey = ""; reset(); scheduleValidation() }
    private func reset() {
        parser = SSEParser(); raw = Data(); pendingEvents = []; current = AIStreamAccumulator()
        events = []; renderedAnswers = [:]; renderedSources = [:]; lastRender = 0; accumulator = current; headers = ""; diagnostics = ""; warnings = []; error = nil
        byteCount = 0; elapsed = 0; firstEvent = nil; firstText = nil; firstByte = nil
        liveFirstEvent = nil; liveFirstText = nil; liveFirstByte = nil; liveElapsed = 0
        clockTask?.cancel(); parsedBytes = 0
        formattedJSON = nil; responseEndpoint = ""
        isSSE = false; demo = false; forcedSSE = false; stopped = false; lastPublish = 0
        status = "准备就绪"; revision += 1
    }
    func send() {
        guard !running else { return }
        reset()
        do {
            // Resolve explicit variables after literal shell parsing, so substitutions cannot inject arguments.
            let parsed = try CurlCommandParser.parse(command, shell: automaticShell ? CurlCommandParser.detectedShell(command) : shell)
            let resolved = parsed.arguments.map { $0.replacingOccurrences(of: "{{API_KEY}}", with: apiKey) }
            if parsed.arguments.contains(where: { $0.contains("{{API_KEY}}") }) && apiKey.isEmpty { throw ToolError.invalid("请填写 API Key，或在 cURL 中使用实际认证值。") }
            if resolved.contains(where: { $0.contains("{{") && $0.contains("}}") }) { throw ToolError.invalid("首版只支持 {{API_KEY}} 变量；其他变量请替换为实际值。") }
            let plan = CurlCommandPlan(url: parsed.url, arguments: resolved, warnings: parsed.warnings, containsCredentials: parsed.containsCredentials)
            let execution = try CurlExecutionPlan(plan, totalTimeout: totalTimeout)
            warnings = execution.warnings
            let target = URLComponents(string: parsed.url)
            responseEndpoint = (target?.host ?? "") + (target?.path ?? "")
            guard (0...86400).contains(idleTimeout), (0...86400).contains(totalTimeout) else { throw ToolError.invalid("超时须为 0–86400 秒。") }
            running = true; status = "连接中"; let token = UUID(); generation = token
            let worker = CurlStreamRunner(); runner = worker
            let began = ProcessInfo.processInfo.systemUptime
            clockTask = Task {
                while !Task.isCancelled && running {
                    try? await Task.sleep(for: .milliseconds(200))
                    guard !Task.isCancelled && running else { return }
                    elapsed = ProcessInfo.processInfo.systemUptime - began
                    // Flush a throttled final fragment even when the server keeps the connection idle.
                    if raw.count != byteCount || accumulator.outputs.contains(where: { renderedSources[$0.id] != $0.answerText }) {
                        publish(force: true)
                    }
                }
            }
            operation = Task {
                do {
                    for try await update in worker.stream(execution, idleTimeout: idleTimeout) {
                        guard generation == token else { return }
                        switch update {
                        case let .headers(value):
                            headers = value
                            let stream = HTTPResponseService.isEventStream(headers: value, prefix: raw, forced: forcedSSE)
                            if isSSE && !stream {
                                parser = SSEParser(); parsedBytes = 0; pendingEvents = []; current = AIStreamAccumulator()
                            }
                            isSSE = stream
                            if isSSE { try parsePending(time: liveElapsed) }
                            publish(force: true)
                            if status == "连接中" { status = "等待返回" }
                        case let .body(data, time): try receive(data, time: time)
                        case let .diagnostic(value): diagnostics += value
                        case let .finished(code, time, reason):
                            liveElapsed = time; finish(code: code, reason: reason)
                        }
                    }
                } catch {
                    guard generation == token else { return }
                    self.error = error.localizedDescription; status = "失败"; worker.cancel(); publish(force: true)
                }
                guard generation == token else { return }
                if stopped { status = "已停止"; publish(force: true) }
                running = false; clockTask?.cancel(); runner = nil
            }
        } catch { self.error = error.localizedDescription; status = "请求未发送" }
    }
    private func receive(_ data: Data, time: TimeInterval) throws {
        if liveFirstByte == nil { liveFirstByte = time }
        raw.append(data); liveElapsed = time
        // Header polling can lag stdout; explicit non-SSE content types take precedence.
        isSSE = HTTPResponseService.isEventStream(headers: headers, prefix: raw, forced: forcedSSE)
        if isSSE { try parsePending(time: time) }
        if !stopped { status = "接收中" }
        publish()
    }
    private func parsePending(time: TimeInterval) throws {
        guard raw.count > parsedBytes else { return }
        let bytes = raw.subdata(in: parsedBytes..<raw.count); parsedBytes = raw.count
        for event in try parser.feed(bytes, time: time) {
            guard pendingEvents.count < 10_000 else { throw ToolError.invalid("已接收 10,000 条 SSE 记录，达到上限，已停止。") }
            pendingEvents.append(event)
            if !event.isHeartbeat && liveFirstEvent == nil { liveFirstEvent = time }
            current.consume(event, mode: mode, path: fieldPath, cumulative: cumulative)
            if liveFirstText == nil && !current.text.isEmpty { liveFirstText = time }
        }
    }
    private func finish(code: Int32, reason: String?) {
        parser.finish()
        if !isSSE { formattedJSON = HTTPResponseService.formattedJSON(raw) }
        if !parser.unfinished.isEmpty && isSSE { warnings.append(parser.unfinished) }
        if let reason { error = reason; status = "已中断" }
        else if stopped { status = "已停止" }
        else if let failure = current.error { error = failure; status = "流内错误" }
        else if code != 0 { error = "cURL 退出码 \(code)。" + (diagnostics.isEmpty ? "" : "\n" + diagnostics); status = "请求失败" }
        else if let code = Int(httpStatus.split(separator: " ").dropFirst().first ?? ""), code >= 400 { error = "服务器返回 HTTP \(code)，响应体已保留。"; status = "HTTP 错误" }
        else if current.completed { status = "已完成" }
        else if isSSE { status = "连接已结束"; warnings.append("未收到已知协议的完成标记；通用 SSE 的业务完成状态由服务端定义。") }
        else { status = "已完成" }
        publish(force: true)
    }
    private func publish(force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastPublish >= 0.045 else { return }
        lastPublish = now; events = isSSE ? pendingEvents : []; accumulator = isSSE ? current : AIStreamAccumulator()
        byteCount = raw.count; elapsed = running ? max(elapsed, liveElapsed) : liveElapsed; firstEvent = liveFirstEvent; firstText = liveFirstText; firstByte = liveFirstByte
        if force || now - lastRender >= 0.15 {
            lastRender = now
            for output in accumulator.outputs {
                let source = output.answerText
                if renderedSources[output.id] != source {
                    renderedSources[output.id] = source
                    renderedAnswers[output.id] = MarkdownDocument.parse(source)
                }
            }
        }
        revision += 1
    }
    func stop() { guard running else { return }; stopped = true; status = "正在停止"; runner?.cancel(); if demo { operation?.cancel(); running = false; status = "已停止"; publish(force: true) } }
    func leave() { stop(); validation?.cancel(); clockTask?.cancel() }
    func reparse() {
        guard !raw.isEmpty else { return }
        guard isSSE else { return }
        var rebuilt = AIStreamAccumulator()
        for event in pendingEvents { rebuilt.consume(event, mode: mode, path: fieldPath, cumulative: cumulative) }
        current = rebuilt; publish(force: true)
    }
    func playDemo() {
        guard !running else { return }; reset(); demo = true; running = true; forcedSSE = true; isSSE = true
        responseEndpoint = "本地流式演示"
        headers = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream; charset=utf-8\r\nX-Request-ID: local-demo\r\n\r\n"
        status = "演示接收中"; let token = UUID(); generation = token
        operation = Task {
            let fragments = ["## 流式回答\n\n", "这是 **Yukino Tools** 的实时 Markdown 结果。\n\n", "### 排查建议\n\n- 检查请求参数与响应状态\n", "- 切换「事件」查看每条数据\n- 中文与 emoji 🌊 正确拼接\n\n", "| 项目 | 状态 |\n| --- | --- |\n| SSE | 正常 |\n| Markdown | 已渲染 |\n\n", "```json\n{\n  \"stream\": true\n}\n```\n\n", "> 代码、表格和思考内容会分别展示。"]
            let started = ProcessInfo.processInfo.systemUptime
            do {
                try receive(Data(": connected\n\ndata: ping\n\ndata: {\"choices\":[{\"index\":0,\"delta\":{\"reasoning_content\":\"先检查响应协议，再整理回答中的标题、表格与代码。\"}}]}\n\n".utf8), time: 0)
                for (index, fragment) in fragments.enumerated() {
                    try await Task.sleep(for: .milliseconds(240))
                    try Task.checkCancellation(); guard generation == token else { return }
                    let json: [String: Any] = ["model": "local-demo", "choices": [["index": 0, "delta": ["content": fragment], "finish_reason": NSNull()]]]
                    let payload = "data: " + String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self) + "\n\n"
                    let bytes = Data(payload.utf8), split = min(39 + index, bytes.count)
                    try receive(bytes.prefix(split), time: ProcessInfo.processInfo.systemUptime - started)
                    try receive(bytes.dropFirst(split), time: ProcessInfo.processInfo.systemUptime - started)
                }
                let tool = #"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"name":"get_weather","arguments":"{\"city\":\"上海\"}"}}]},"finish_reason":"tool_calls"}]}"#
                try receive(Data(("data: " + tool + "\n\ndata: {\"choices\":[],\"usage\":{\"prompt_tokens\":24,\"completion_tokens\":68,\"total_tokens\":92}}\n\ndata: [DONE]\n\n").utf8), time: ProcessInfo.processInfo.systemUptime - started)
                finish(code: 0, reason: nil); status = "演示已完成"; running = false
            } catch { if generation == token { running = false; publish(force: true) } }
        }
    }
    func playJSONDemo() {
        guard !running else { return }
        reset(); demo = true; responseEndpoint = "本地 JSON 演示"
        headers = "HTTP/1.1 200 OK\r\nContent-Type: application/json; charset=utf-8\r\nX-Request-ID: local-json-demo\r\n\r\n"
        do {
            try receive(Data(#"{"code":0,"message":"success","data":{"id":9007199254740993,"items":[{"name":"雪乃","enabled":true}],"total":1}}"#.utf8), time: 0.018)
            finish(code: 0, reason: nil); status = "演示已完成"
        } catch { self.error = error.localizedDescription }
    }
    func importStream() {
        guard !running else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
            guard size <= 20 * 1_048_576 else { throw ToolError.invalid("导入文件最大 20 MiB。") }
            let bytes = try Data(contentsOf: url); reset(); forcedSSE = true; isSSE = true
            try receive(bytes, time: 0); finish(code: 0, reason: nil); status = "已导入 · 无到达时间"
        } catch { self.error = error.localizedDescription }
    }
    func export(_ kind: String) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = kind == "正文" ? (formattedJSON != nil ? "api-response.json" : "api-response.txt") : kind == "事件" ? "ai-events.json" : (isSSE ? "ai-stream.sse" : formattedJSON != nil ? "api-raw.json" : "api-raw.txt")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data: Data
            if kind == "正文" { data = Data((isSSE ? accumulator.text : responseText).utf8) }
            else if kind == "事件" {
                let records: [[String: Any]] = events.map { ["sequence": $0.id, "event": $0.name, "data": $0.data, "id": $0.eventID, "time": $0.time, "comment": $0.isComment] }
                data = try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys])
            } else { data = raw }
            try data.write(to: url, options: .atomic)
        } catch { self.error = error.localizedDescription }
    }
}
