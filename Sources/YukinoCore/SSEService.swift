import Foundation

public struct SSEEvent: Identifiable, Equatable, Sendable {
    public let id: Int
    public let name: String
    public let data: String
    public let eventID: String
    public let retry: Int?
    public let time: TimeInterval
    public let isComment: Bool
    public var isHeartbeat: Bool {
        if isComment || ["ping", "heartbeat", "keepalive"].contains(name.lowercased()) { return true }
        let value = data.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ["ping", "pong", "heartbeat", "keepalive"].contains(value) { return true }
        guard let json = (try? JSONSerialization.jsonObject(with: Data(data.utf8))) as? [String: Any] else { return false }
        let type = (json["event"] as? String ?? json["type"] as? String ?? "").lowercased()
        return ["ping", "heartbeat", "keepalive"].contains(type)
    }
}

/// Incremental byte parser: transport chunks may end anywhere, including inside UTF-8 and CRLF.
public struct SSEParser: Sendable {
    private var line = Data()
    private var previousCR = false
    private var firstLine = true
    private var dataLines = [String]()
    private var name = ""
    private var eventID = ""
    private var retry: Int?
    private var sequence = 0
    private var pendingSize = 0
    public private(set) var unfinished = ""
    public init() {}

    public mutating func feed(_ bytes: Data, time: TimeInterval = 0) throws -> [SSEEvent] {
        var events = [SSEEvent]()
        for byte in bytes {
            if byte == 10 && previousCR { previousCR = false; continue }
            previousCR = false
            if byte == 10 || byte == 13 {
                try consumeLine(time: time, events: &events)
                previousCR = byte == 13
            } else {
                line.append(byte)
                if line.count + pendingSize > 1_048_576 { throw ToolError.invalid("单个 SSE 事件超过 1 MiB，已停止接收。") }
            }
        }
        return events
    }

    public mutating func finish() {
        let tail = String(decoding: line, as: UTF8.self)
        unfinished = (dataLines.isEmpty && name.isEmpty && tail.isEmpty) ? "" : "流末尾存在未以空行结束的 SSE 数据，未作为完整事件派发。"
    }

    private mutating func consumeLine(time: TimeInterval, events: inout [SSEEvent]) throws {
        var text = String(decoding: line, as: UTF8.self)
        line.removeAll(keepingCapacity: true)
        if firstLine { firstLine = false; if text.hasPrefix("\u{FEFF}") { text.removeFirst() } }
        if text.isEmpty {
            if !dataLines.isEmpty {
                sequence += 1
                events.append(SSEEvent(id: sequence, name: name.isEmpty ? "message" : name,
                                       data: dataLines.joined(separator: "\n"), eventID: eventID, retry: retry, time: time, isComment: false))
            }
            dataLines.removeAll(keepingCapacity: true); name = ""; pendingSize = 0
            return
        }
        if text.hasPrefix(":") {
            sequence += 1
            events.append(SSEEvent(id: sequence, name: "heartbeat", data: String(text.dropFirst()), eventID: eventID, retry: retry, time: time, isComment: true))
            return
        }
        let pieces = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let field = String(pieces[0])
        var value = pieces.count == 2 ? String(pieces[1]) : ""
        if value.hasPrefix(" ") { value.removeFirst() }
        switch field {
        case "data": dataLines.append(value); pendingSize += value.utf8.count + 1
        case "event": name = value
        case "id": if !value.contains("\0") { eventID = value }
        case "retry": if !value.isEmpty && value.utf8.allSatisfy({ (48...57).contains($0) }) { retry = Int(value) }
        default: break
        }
        if pendingSize > 1_048_576 { throw ToolError.invalid("单个 SSE 事件超过 1 MiB，已停止接收。") }
    }
}

public enum AIStreamMode: String, CaseIterable, Sendable {
    case automatic = "自动识别", generic = "通用 SSE", dify = "Dify", chat = "Chat Completions", responses = "Responses", anthropic = "Anthropic"
}

public struct AIStreamOutput: Identifiable, Sendable {
    public let id: String
    public var text = ""
    public var reasoning = ""
    public var tools: [String: String] = [:]
    public var toolNames: [String: String] = [:]
    public var finishReason = ""
    public var answerText: String { presentation.answer }
    public var thinkingText: String { [reasoning, presentation.thinking].filter { !$0.isEmpty }.joined(separator: "\n") }
    // Parse the accumulated text so tags split across transport events stay out of the answer.
    private var presentation: (answer: String, thinking: String) {
        var rest = text[...], answer = "", thinking = "", inside = false
        while !rest.isEmpty {
            let marker = inside ? "</think>" : "<think>"
            if let range = rest.range(of: marker) {
                if inside { thinking += rest[..<range.lowerBound] } else { answer += rest[..<range.lowerBound] }
                rest = rest[range.upperBound...]; inside.toggle()
            } else {
                var tail = String(rest)
                // Hide an unfinished opening/closing marker until its remaining bytes arrive.
                for length in stride(from: min(marker.count - 1, tail.count), through: 1, by: -1) {
                    if tail.hasSuffix(String(marker.prefix(length))) { tail.removeLast(length); break }
                }
                if inside { thinking += tail } else { answer += tail }
                break
            }
        }
        return (answer, thinking)
    }
}

/// Protocol aggregation is independent from SSE framing. Unknown data stays available in the event viewer.
public struct AIStreamAccumulator: Sendable {
    public private(set) var detected = AIStreamMode.generic
    public private(set) var outputs = [AIStreamOutput]()
    public private(set) var model = ""
    public private(set) var usage = ""
    public private(set) var completed = false
    public private(set) var error: String?
    public private(set) var malformedCount = 0
    private var difyTextChunks = false
    public init() {}
    public var text: String { outputs.map(\.answerText).filter { !$0.isEmpty }.joined(separator: "\n\n") }

    public mutating func consume(_ event: SSEEvent, mode: AIStreamMode = .automatic, path: String = "", cumulative: Bool = false) {
        guard !event.isHeartbeat else { return }
        if event.name == "error" { error = event.data }
        if event.data.trimmingCharacters(in: .whitespacesAndNewlines) == "[DONE]" {
            if mode == .chat || mode == .automatic { detected = .chat; completed = true }
            return
        }
        guard let object = try? JSONSerialization.jsonObject(with: Data(event.data.utf8)), let json = object as? [String: Any] else {
            if event.data.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") { malformedCount += 1 }
            if mode == .generic || mode == .automatic && detected == .generic, path.isEmpty {
                update("main") { $0.text += event.data + "\n" }
            }
            return
        }
        let type = json["event"] as? String ?? json["type"] as? String ?? event.name
        if let value = json["model"] as? String { model = value }
        if mode != .automatic { detected = mode }
        else if Self.difyEvents.contains(type) && (json["event"] != nil || event.name != "message") { detected = .dify }
        else if json["choices"] != nil { detected = .chat }
        else if type.hasPrefix("response.") { detected = .responses }
        else if type.hasPrefix("content_block_") || type.hasPrefix("message_") { detected = .anthropic }
        if type == "error" || json["error"] != nil {
            let detail = json["error"] as? [String: Any]
            error = detail?["message"] as? String ?? json["message"] as? String ?? event.data
        }
        if let value = json["usage"], detected != .anthropic { usage = Self.pretty(value) }
        switch detected {
        case .dify:
            let key = "main"
            switch type {
            case "message", "agent_message":
                if let answer = json["answer"] as? String {
                    let replace = type == "message" && difyTextChunks
                    update(key) { if replace { $0.text = answer } else { $0.text += answer } }
                }
            case "text_chunk":
                difyTextChunks = true
                if let text = Self.extract(json, path: "data.text") as? String { update(key) { $0.text += text } }
            case "message_replace":
                if let answer = json["answer"] as? String { update(key) { $0.text = answer } }
            case "agent_thought":
                if let thought = json["thought"] as? String, !thought.isEmpty { update(key) { $0.reasoning += thought + "\n" } }
            case "message_end":
                completed = true
                mergeUsage(Self.extract(json, path: "metadata.usage"))
            case "workflow_finished":
                let data = json["data"] as? [String: Any] ?? [:]
                if text.isEmpty, let answer = Self.answer(data["outputs"] as? [String: Any] ?? [:]) { update(key) { $0.text = answer } }
                if data["status"] as? String == "failed" { error = data["error"] as? String ?? "工作流执行失败" }
                completed = true
            default: break
            }
        case .chat:
            for choice in json["choices"] as? [[String: Any]] ?? [] {
                let key = "choice \(choice["index"] as? Int ?? 0)"
                let delta = choice["delta"] as? [String: Any] ?? choice["message"] as? [String: Any] ?? [:]
                update(key) { output in
                    output.text += delta["content"] as? String ?? ""
                    output.reasoning += delta["reasoning_content"] as? String ?? delta["reasoning"] as? String ?? ""
                    if let reason = choice["finish_reason"] as? String { output.finishReason = reason }
                    for tool in delta["tool_calls"] as? [[String: Any]] ?? [] {
                        let index = String(tool["index"] as? Int ?? 0), function = tool["function"] as? [String: Any] ?? [:]
                        if let name = function["name"] as? String { output.toolNames[index, default: ""] += name }
                        output.tools[index, default: ""] += function["arguments"] as? String ?? ""
                    }
                }
            }
        case .responses:
            let key = "output \(json["output_index"] as? Int ?? 0)"
            if type == "response.output_text.delta" { update(key) { $0.text += json["delta"] as? String ?? "" } }
            if type.contains("reasoning") && type.hasSuffix(".delta") { update(key) { $0.reasoning += json["delta"] as? String ?? "" } }
            if type == "response.output_item.added", let item = json["item"] as? [String: Any], item["type"] as? String == "function_call" {
                update(key) { $0.toolNames["0"] = item["name"] as? String ?? "tool"; $0.tools["0"] = item["arguments"] as? String ?? "" }
            }
            if type == "response.function_call_arguments.delta" { update(key) { $0.tools["0", default: ""] += json["delta"] as? String ?? "" } }
            if let response = json["response"] as? [String: Any] {
                if let value = response["model"] as? String { model = value }
                if let value = response["usage"] { usage = Self.pretty(value) }
                if type == "response.failed" || type == "response.incomplete" { error = Self.pretty(response["error"] ?? response["incomplete_details"] ?? type) }
            }
            if type == "response.completed" { completed = true }
        case .anthropic:
            let key = "block \(json["index"] as? Int ?? 0)"
            if type == "message_start", let message = json["message"] as? [String: Any] {
                if let value = message["model"] as? String { model = value }
                mergeUsage(message["usage"])
            }
            if type == "content_block_start", let block = json["content_block"] as? [String: Any] {
                update(key) {
                    $0.text += block["text"] as? String ?? ""
                    $0.reasoning += block["thinking"] as? String ?? ""
                    if block["type"] as? String == "tool_use" { $0.toolNames["0"] = block["name"] as? String ?? "tool"; $0.tools["0"] = "" }
                }
            }
            if type == "content_block_delta", let delta = json["delta"] as? [String: Any] {
                update(key) { $0.text += delta["text"] as? String ?? ""; $0.reasoning += delta["thinking"] as? String ?? ""; if let partial = delta["partial_json"] as? String { $0.tools["0", default: ""] += partial } }
            }
            if type == "message_delta" { mergeUsage(json["usage"]); if let reason = (json["delta"] as? [String: Any])?["stop_reason"] as? String { update("main") { $0.finishReason = reason } } }
            if type == "message_stop" { completed = true }
        default:
            if !path.isEmpty, let value = Self.extract(json, path: path) {
                let text = value as? String ?? Self.pretty(value)
                update("main") { if cumulative { $0.text = text } else { $0.text += text } }
            } else if path.isEmpty {
                if json["response"] is String || json["responseAll"] is String {
                    let details = Self.extract(json, path: "resultMap.eventData.resultMap") as? [String: Any] ?? [:]
                    let subtype = details["subMessageType"] as? String
                    let thinking = subtype == "exec_thought" || (subtype == nil && !(details["execThought"] as? String ?? "").isEmpty)
                    let snapshot = json["responseAll"] as? String
                    let fragment = json["response"] as? String ?? ""
                    update("main") { output in
                        if thinking {
                            if let snapshot, !snapshot.isEmpty { output.reasoning = snapshot }
                            else { output.reasoning += details["execThought"] as? String ?? fragment }
                        } else {
                            if let snapshot, !snapshot.isEmpty { output.text = snapshot }
                            else { output.text += fragment }
                        }
                        if json["finished"] as? Bool == true { output.finishReason = "finished" }
                    }
                    if json["finished"] as? Bool == true { completed = true }
                    if let tokens = json["useTokens"] as? NSNumber, tokens.intValue > 0 { mergeUsage(["total_tokens": tokens]) }
                } else if let answer = Self.answer(json) {
                    update("main") { if cumulative { $0.text = answer } else { $0.text += answer } }
                }
            }
        }
    }

    private static let difyEvents: Set<String> = ["message", "agent_message", "text_chunk", "message_replace", "agent_thought", "message_end", "workflow_started", "workflow_finished", "node_started", "node_finished", "ping"]
    private static func answer(_ json: [String: Any]) -> String? {
        for path in ["answer", "content", "text", "data.answer", "data.content", "data.text", "outputs.answer", "outputs.text", "data.outputs.answer", "data.outputs.text"] {
            if let value = extract(json, path: path) as? String { return value }
        }
        return nil
    }

    private mutating func update(_ id: String, _ body: (inout AIStreamOutput) -> Void) {
        if let index = outputs.firstIndex(where: { $0.id == id }) { body(&outputs[index]) }
        else { var output = AIStreamOutput(id: id); body(&output); outputs.append(output) }
    }
    private mutating func mergeUsage(_ value: Any?) {
        guard let incoming = value as? [String: Any] else { return }
        var old = (try? JSONSerialization.jsonObject(with: Data(usage.utf8))) as? [String: Any] ?? [:]
        old.merge(incoming, uniquingKeysWith: { _, new in new }); usage = Self.pretty(old)
    }
    public static func pretty(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]), let text = String(data: data, encoding: .utf8) else { return String(describing: value) }
        return text
    }
    public static func extract(_ value: Any, path: String) -> Any? {
        let parts = path.replacingOccurrences(of: "[", with: ".").replacingOccurrences(of: "]", with: "").split(separator: ".")
        return parts.reduce(Optional(value)) { current, part in
            if let object = current as? [String: Any] { return object[String(part)] }
            if let array = current as? [Any], let index = Int(part), array.indices.contains(index) { return array[index] }
            return nil
        }
    }
}
