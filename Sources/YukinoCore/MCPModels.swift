import Foundation

public enum MCPConnectionKind: String, CaseIterable {
    case stdio = "本机 stdio", http = "Streamable HTTP"
}

public struct MCPConnectionConfiguration {
    public var kind: MCPConnectionKind = .stdio
    public var executable = ""
    public var arguments = "[]"
    public var environment = "{}"
    public var directory = ""
    public var endpoint = "http://127.0.0.1:3000/mcp"
    public var headers = "{}"
    public var timeout: TimeInterval = 30
    public init() {}

    public func validate() throws {
        guard (1...300).contains(timeout) else { throw ToolError.invalid("超时须为 1–300 秒。") }
        if kind == .stdio {
            guard executable.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: executable) else {
                throw ToolError.invalid("请选择可执行文件的绝对路径，例如 /opt/homebrew/bin/uvx；命令与参数分开填写。")
            }
            _ = try parsedArguments()
            _ = try stringMap(environment, name: "环境变量")
            if !directory.isEmpty {
                var isDirectory: ObjCBool = false
                guard directory.hasPrefix("/"), FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
                    throw ToolError.invalid("工作目录须为已存在的绝对目录。")
                }
            }
        } else {
            guard let url = URL(string: endpoint), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  url.host != nil, url.user == nil, url.password == nil, url.fragment == nil else {
                throw ToolError.invalid("请输入 HTTP(S) MCP 完整地址；认证请填写到请求头中。")
            }
            for (key, value) in try stringMap(headers, name: "请求头") {
                let permitted = "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
                guard !key.isEmpty, key.allSatisfy({ permitted.contains($0) }),
                      !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
                      !["host", "content-type", "accept", "content-length", "connection", "transfer-encoding", "mcp-session-id", "mcp-protocol-version"].contains(key.lowercased()) else {
                    throw ToolError.invalid("请求头 \(key) 无效或由协议管理，不能覆盖。")
                }
            }
        }
    }

    public func parsedArguments() throws -> [String] {
        guard arguments.utf8.count <= 262_144,
              let value = try JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String],
              value.allSatisfy({ !$0.contains("\0") }) else { throw ToolError.invalid("参数须为 JSON 字符串数组，例如 [\"-u\", \"/path/server.py\"]。") }
        return value
    }
    public func stringMap(_ text: String, name: String) throws -> [String: String] {
        guard text.utf8.count <= 262_144,
              let value = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: String],
              value.allSatisfy({ !$0.key.contains("\0") && !$0.value.contains("\0") }),
              name != "环境变量" || value.keys.allSatisfy({ !$0.isEmpty && !$0.contains("=") }) else {
            throw ToolError.invalid("\(name)须为 JSON 字符串对象，例如 {\"KEY\": \"value\"}。")
        }
        return value
    }
}

public enum MCPJSON {
    public static let limit = 4 * 1_024 * 1_024
    public static func object(_ text: String) throws -> [String: Any] {
        guard text.utf8.count <= limit else { throw ToolError.invalid("JSON 超过 4 MiB。") }
        guard let result = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw ToolError.invalid("请输入 JSON 对象（{…}）。")
        }
        return result
    }
    public static func text(_ value: Any) -> String { AIStreamAccumulator.pretty(value) }
    public static func quote(_ text: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [text])
        return String(decoding: data, as: UTF8.self).dropFirst().dropLast().description
    }
}

public struct MCPEntry: Identifiable, Equatable {
    public enum Kind: String, CaseIterable { case tool = "工具", resource = "资源", template = "资源模板", prompt = "Prompts" }
    public let kind: Kind
    public let name: String
    public let title: String
    public let detail: String
    public let uri: String
    public let metadata: String
    public let schema: String
    public var id: String { kind.rawValue + ":" + (kind == .resource || kind == .template ? uri : name) }
    public init(kind: Kind, object: [String: Any]) throws {
        guard let name = object["name"] as? String, !name.isEmpty else { throw ToolError.invalid("服务返回了没有名称的\(kind.rawValue)。") }
        self.kind = kind; self.name = name
        title = object["title"] as? String ?? name
        detail = object["description"] as? String ?? ""
        uri = object[kind == .template ? "uriTemplate" : "uri"] as? String ?? ""
        if kind == .resource || kind == .template, uri.isEmpty { throw ToolError.invalid("资源缺少 URI。") }
        if kind == .tool, !(object["inputSchema"] is [String: Any]) { throw ToolError.invalid("工具 \(name) 缺少 inputSchema。") }
        metadata = MCPJSON.text(object)
        schema = MCPJSON.text(object["inputSchema"] ?? [:])
    }
    public var exampleArguments: String {
        let object = (try? MCPJSON.object(metadata)) ?? [:]
        if kind == .prompt {
            var values = [String: String]()
            for arg in object["arguments"] as? [[String: Any]] ?? [] {
                if let name = arg["name"] as? String { values[name] = "" }
            }
            return MCPJSON.text(values)
        }
        func sample(_ schema: [String: Any], depth: Int) -> Any {
            if let value = schema["default"] { return value }
            if let value = (schema["enum"] as? [Any])?.first { return value }
            guard depth < 6 else { return NSNull() }
            switch schema["type"] as? String {
            case "object":
                let properties = schema["properties"] as? [String: [String: Any]] ?? [:]
                var value = [String: Any]()
                for key in schema["required"] as? [String] ?? [] { value[key] = sample(properties[key] ?? [:], depth: depth + 1) }
                return value
            case "array": return [Any]()
            case "integer", "number": return 0
            case "boolean": return false
            case "null": return NSNull()
            default: return ""
            }
        }
        return MCPJSON.text(sample((try? MCPJSON.object(schema)) ?? [:], depth: 0))
    }
}

public struct MCPResult {
    public let raw: String
    public let text: String
    public let isError: Bool
    public let elapsed: TimeInterval
    public init(object: [String: Any], elapsed: TimeInterval) {
        raw = MCPJSON.text(object)
        isError = object["isError"] as? Bool ?? false
        self.elapsed = elapsed
        let blocks = object["content"] as? [[String: Any]] ?? object["contents"] as? [[String: Any]]
            ?? (object["messages"] as? [[String: Any]])?.compactMap { $0["content"] as? [String: Any] } ?? []
        text = blocks.compactMap { block -> String? in
            if let text = block["text"] as? String { return text }
            return (block["resource"] as? [String: Any])?["text"] as? String
        }.joined(separator: "\n\n")
    }
}

public struct MCPLogEntry: Identifiable {
    public let id = UUID()
    public let date = Date()
    public let direction: String
    public let text: String
    public init(direction: String, text: String) {
        self.direction = direction
        self.text = text.count > 16_384 ? String(text.prefix(16_384)) + "\n…（日志预览截断，结果页保留完整返回）" : text
    }
}
