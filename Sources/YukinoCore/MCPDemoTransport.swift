import Foundation

/// In-memory service using the same lifecycle and JSON-RPC path as a real connection.
@MainActor final class MCPDemoTransport: MCPTransport {
    var receive: ((MCPTransportEvent) -> Void)?
    var protocolVersion: String?
    private var active = false
    func start() throws { active = true }
    func close() { active = false }
    func cancel(_ id: Int) {}
    func send(_ data: Data, id: Int?) {
        guard active, let id, let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let method = request["method"] as? String else { return }
        let params = request["params"] as? [String: Any] ?? [:]
        var result = [String: Any]()
        switch method {
        case "initialize": result = ["protocolVersion": "2025-11-25", "serverInfo": ["name": "Yukino 本地演示", "version": "1.0"], "capabilities": ["tools": [:], "resources": [:], "prompts": [:]]]
        case "tools/list": result = ["tools": [
            ["name": "echo", "title": "回声工具", "description": "原样返回文本，体验参数编辑与工具调用。", "inputSchema": ["type": "object", "properties": ["text": ["type": "string", "default": "你好，MCP！"]], "required": ["text"]], "annotations": ["readOnlyHint": true]],
            ["name": "add", "title": "数字相加", "description": "输入两个数字，返回计算结果。", "inputSchema": ["type": "object", "properties": ["a": ["type": "number", "default": 12], "b": ["type": "number", "default": 30]], "required": ["a", "b"]], "annotations": ["readOnlyHint": true]]]]
        case "tools/call":
            let args = params["arguments"] as? [String: Any] ?? [:]
            if params["name"] as? String == "echo", let text = args["text"] as? String {
                result = ["content": [["type": "text", "text": text]], "isError": false]
            } else if params["name"] as? String == "add", let a = args["a"] as? Double, let b = args["b"] as? Double {
                result = ["content": [["type": "text", "text": "\(a) + \(b) = \(a + b)"]], "structuredContent": ["sum": a + b], "isError": false]
            } else { result = ["content": [["type": "text", "text": "参数不正确，请检查工具 Schema。"]], "isError": true] }
        case "resources/list": result = ["resources": [["name": "welcome", "title": "MCP 入门说明", "uri": "demo://welcome", "mimeType": "text/plain", "description": "本地演示资源。"]]]
        case "resources/templates/list": result = ["resourceTemplates": [["name": "greeting", "title": "问候资源模板", "uriTemplate": "demo://greeting/{name}", "description": "把 URI 中的 {name} 替换为你的名字。"]]]
        case "resources/read": result = ["contents": [["uri": params["uri"] as? String ?? "", "mimeType": "text/plain", "text": "欢迎使用 MCP 调试器。\n连接 → 发现工具 → 查看 Schema → 编辑 JSON → 手动调用。\n当前为本地演示，不会联网。"]]]
        case "prompts/list": result = ["prompts": [["name": "explain", "title": "代码解释模板", "description": "提供代码，预览生成的 Prompt；不会调用模型。", "arguments": [["name": "code", "description": "需要解释的代码", "required": true]]]]]
        case "prompts/get": result = ["description": "代码解释", "messages": [["role": "user", "content": ["type": "text", "text": "请解释下面代码的行为与边界条件：\n\((params["arguments"] as? [String: String])?["code"] ?? "")"]]]]
        case "ping": result = [:]
        default:
            let response: [String: Any] = ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found"]]
            if let bytes = try? JSONSerialization.data(withJSONObject: response) { receive?(.message(bytes)) }
            return
        }
        let response: [String: Any] = ["jsonrpc": "2.0", "id": id, "result": result]
        if let bytes = try? JSONSerialization.data(withJSONObject: response) { receive?(.message(bytes)) }
    }
}
