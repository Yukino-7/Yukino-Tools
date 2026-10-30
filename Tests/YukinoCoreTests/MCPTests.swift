import Foundation
import Testing
@testable import YukinoCore

@MainActor private final class MCPTestTransport: MCPTransport {
    var receive: ((MCPTransportEvent) -> Void)?
    var protocolVersion: String?
    var messages = [[String: Any]]()
    var raw = [String]()
    var handler: (([String: Any]) -> [String: Any]?)?
    var initialized = false
    var initialization: [String: Any]?
    var closed = false
    func start() throws {}
    func close() { closed = true }
    func cancel(_ id: Int) {}
    func send(_ data: Data, id: Int?) {
        raw.append(String(decoding: data, as: UTF8.self))
        let object = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        messages.append(object)
        if object["method"] as? String == "notifications/initialized" { initialized = true }
        guard let id else { return }
        if object["method"] as? String == "initialize" {
            respond(id, result: initialization ?? ["protocolVersion": "2025-11-25", "serverInfo": ["name": "test", "version": "1"], "capabilities": ["tools": [:], "prompts": [:], "resources": [:]]])
        } else if let result = handler?(object) { respond(id, result: result) }
    }
    func respond(_ id: Int, result: [String: Any]) { deliver(["jsonrpc": "2.0", "id": id, "result": result]) }
    func deliver(_ object: [String: Any]) { receive?(.message(try! JSONSerialization.data(withJSONObject: object))) }
}

private func mcpTool(_ name: String = "echo") throws -> MCPEntry {
    try MCPEntry(kind: .tool, object: ["name": name, "inputSchema": ["type": "object"]])
}

@Test @MainActor func mcpDemoSupportsFullWorkflowAndBusinessErrors() async throws {
    let client = MCPClient(); try await client.connectDemo(); defer { client.disconnect() }
    #expect(client.connected && client.capabilities == ["tools", "resources", "prompts"])
    let tools = try await client.list(.tool)
    #expect(tools.count == 2)
    let echo = try #require(tools.first { $0.name == "echo" })
    let result = try await client.perform(echo, arguments: "{\"text\":\"你好 👋\"}")
    #expect(result.text == "你好 👋" && !result.isError)
    let failed = try await client.perform(echo, arguments: "{}")
    #expect(failed.isError && client.connected)
    let resources = try await client.list(.resource)
    #expect(try await client.perform(resources[0], arguments: "{}").text.contains("欢迎"))
    let templates = try await client.list(.template)
    await #expect(throws: (any Error).self) { try await client.perform(templates[0], arguments: "{}") }
    #expect(try await client.perform(templates[0], arguments: "{}", uri: "demo://greeting/test").raw.contains("test"))
    let prompts = try await client.list(.prompt)
    #expect(try await client.perform(prompts[0], arguments: "{\"code\":\"print(1)\"}").text.contains("print(1)"))
    await #expect(throws: (any Error).self) { try await client.perform(prompts[0], arguments: "{\"code\":1}") }
    await #expect(throws: (any Error).self) { try await client.perform(prompts[0], arguments: "{}") }
}

@Test @MainActor func mcpHandshakePrecedesDiscoveryAndKeepsLargeArgumentNumbers() async throws {
    let client = MCPClient(), transport = MCPTestTransport()
    transport.handler = { _ in ["content": []] }
    try await client.connect(using: transport); defer { client.disconnect() }
    #expect(transport.messages[0]["method"] as? String == "initialize")
    #expect(transport.initialized && transport.protocolVersion == "2025-11-25")
    let params = "{\"id\":123456789012345678901234567890,\"decimal\":0.123456789012345678901}"
    _ = try await client.perform(mcpTool(), arguments: params)
    #expect(transport.raw.last?.contains(params) == true)
    await #expect(throws: (any Error).self) { try await client.perform(mcpTool(), arguments: "[]") }
}

@Test @MainActor func mcpPaginationChecksCursorsAndDuplicateEntries() async throws {
    let client = MCPClient(), transport = MCPTestTransport()
    transport.handler = { request in
        let hasCursor = (request["params"] as? [String: Any])?["cursor"] != nil
        return ["tools": [["name": hasCursor ? "second" : "first", "inputSchema": ["type": "object"]]], "nextCursor": "same"]
    }
    try await client.connect(using: transport); defer { client.disconnect() }
    await #expect(throws: (any Error).self) { try await client.list(.tool) }
    transport.handler = { request in
        if (request["params"] as? [String: Any])?["cursor"] != nil { return ["tools": [["name": "second", "inputSchema": [:]]]] }
        return ["tools": [["name": "first", "inputSchema": [:]]], "nextCursor": "two"]
    }
    #expect(try await client.list(.tool).map(\.name) == ["first", "second"])
    transport.handler = { _ in ["tools": [["name": "dup", "inputSchema": [:]], ["name": "dup", "inputSchema": [:]]]] }
    await #expect(throws: (any Error).self) { try await client.list(.tool) }
    #expect(client.connected)
}

@Test @MainActor func mcpVersionNegotiationRejectsUnsupportedAndHonorsCapabilities() async throws {
    let client = MCPClient(), unsupported = MCPTestTransport()
    unsupported.initialization = ["protocolVersion": "2099-01-01", "serverInfo": ["name": "future"], "capabilities": [:]]
    await #expect(throws: (any Error).self) { try await client.connect(using: unsupported) }
    #expect(!client.connected && unsupported.closed && !unsupported.initialized)
    let limited = MCPTestTransport()
    limited.initialization = ["protocolVersion": "2025-03-26", "serverInfo": ["name": "limited"], "capabilities": [:]]
    try await client.connect(using: limited); defer { client.disconnect() }
    #expect(client.protocolVersion == "2025-03-26")
    #expect(try await client.list(.tool).isEmpty)
    #expect(limited.messages.count == 2)
}

@Test @MainActor func mcpOldConnectionAndMalformedUTF8CannotCorruptNewSession() async throws {
    let client = MCPClient(), old = MCPTestTransport()
    try await client.connect(using: old)
    let oldReceiver = old.receive
    let next = MCPTestTransport(); try await client.connect(using: next)
    oldReceiver?(.closed("late close"))
    #expect(client.connected)
    next.receive?(.message(Data([0xff, 0xfe])))
    #expect(!client.connected && next.closed)
    #expect(client.logs.last?.text.contains("UTF-8") == true)
}

@Test @MainActor func mcpRPCErrorAndMalformedResponseAreDistinctFromBusinessErrors() async throws {
    let client = MCPClient(), transport = MCPTestTransport()
    try await client.connect(using: transport); defer { client.disconnect() }
    transport.handler = { object in
        transport.deliver(["jsonrpc": "2.0", "id": object["id"]!, "error": ["code": -32602, "message": "bad argument"]]); return nil
    }
    do { _ = try await client.perform(mcpTool(), arguments: "{}"); Issue.record("Expected RPC error") }
    catch { #expect(error.localizedDescription.contains("-32602")) }
    #expect(client.connected)
    transport.handler = { object in
        transport.deliver(["jsonrpc": "2.0", "id": object["id"]!, "result": [:], "error": [:]]); return nil
    }
    await #expect(throws: (any Error).self) { try await client.perform(mcpTool(), arguments: "{}") }
}

@Test @MainActor func mcpCancellationDoesNotRetryAndIgnoresLateReply() async throws {
    let client = MCPClient(), transport = MCPTestTransport()
    try await client.connect(using: transport); defer { client.disconnect() }
    let operation = Task { try await client.perform(mcpTool(), arguments: "{}") }
    while transport.messages.last?["method"] as? String != "tools/call" { await Task.yield() }
    let requestID = transport.messages.last!["id"] as! Int
    operation.cancel()
    await #expect(throws: CancellationError.self) { try await operation.value }
    #expect(transport.messages.last?["method"] as? String == "notifications/cancelled")
    transport.respond(requestID, result: ["content": [["type": "text", "text": "late"]]])
    #expect(client.connected)
    transport.handler = { _ in ["content": [["type": "text", "text": "next"]]] }
    #expect(try await client.perform(mcpTool(), arguments: "{}").text == "next")
    #expect(transport.messages.filter { $0["method"] as? String == "tools/call" }.count == 2)
}

@Test @MainActor func mcpTimeoutAndDisconnectResolvePendingRequests() async throws {
    let client = MCPClient(), transport = MCPTestTransport()
    try await client.connect(using: transport, timeout: 1)
    do { _ = try await client.perform(mcpTool(), arguments: "{}"); Issue.record("Expected timeout") }
    catch { #expect(error.localizedDescription.contains("超时")) }
    #expect(client.connected)
    let operation = Task { try await client.perform(mcpTool(), arguments: "{}") }
    while transport.messages.last?["method"] as? String != "tools/call" { await Task.yield() }
    client.disconnect()
    await #expect(throws: CancellationError.self) { try await operation.value }
    #expect(transport.closed && !client.connected)
}

@Test @MainActor func mcpServerRequestsOnlyPingIsSupportedAndLogsAreBounded() async throws {
    let client = MCPClient(), transport = MCPTestTransport()
    try await client.connect(using: transport); defer { client.disconnect() }
    transport.deliver(["jsonrpc": "2.0", "id": "server-ping", "method": "ping"])
    #expect(transport.messages.last?["id"] as? String == "server-ping")
    #expect(transport.messages.last?["result"] is [String: Any])
    transport.deliver(["jsonrpc": "2.0", "id": 99, "method": "sampling/createMessage"])
    #expect((transport.messages.last?["error"] as? [String: Any])?["code"] as? Int == -32601)
    for _ in 0..<220 { transport.deliver(["jsonrpc": "2.0", "method": "notifications/message", "params": ["data": "test"]]) }
    #expect(client.logs.count == 200)
    client.clearLogs(); #expect(client.logs.isEmpty)
}

@Test func mcpConfigurationRejectsInvalidOrReservedInputs() throws {
    var config = MCPConnectionConfiguration(); config.kind = .http
    config.headers = "{\"Authorization\":\"Bearer test\"}"; try config.validate()
    for headers in ["[]", "{\"Accept\":\"x\"}", "{\"X-Key\":\"bad\\r\\nheader\"}", "{\"MCP-Session-Id\":\"x\"}", "{\"X Key\":\"x\"}", "{\"X-Key\":1}"] {
        config.headers = headers; #expect(throws: (any Error).self) { try config.validate() }
    }
    config.headers = "{}"
    for endpoint in ["file:///tmp/test", "https://user:password@example.com/mcp", "https://example.com/mcp#fragment", "invalid"] {
        config.endpoint = endpoint; #expect(throws: (any Error).self) { try config.validate() }
    }
    config.kind = .stdio; config.executable = "/bin/cat"; config.arguments = "[\"literal; $(echo no)\"]"; try config.validate()
    config.arguments = "\"--bad\""; #expect(throws: (any Error).self) { try config.validate() }
    config.arguments = "[]"; config.environment = "{\"A=B\":\"x\"}"; #expect(throws: (any Error).self) { try config.validate() }
}

private let mcpStdioFixture = #"""
import sys,json,time
def emit(obj):
    data=(json.dumps(obj,ensure_ascii=False)+'\n').encode()
    for chunk in [data[:3],data[3:-2],data[-2:]]:
        sys.stdout.buffer.write(chunk); sys.stdout.buffer.flush()
for line in sys.stdin:
    obj=json.loads(line)
    if 'method' not in obj or 'id' not in obj: continue
    method=obj['method']; params=obj.get('params',{})
    if method=='initialize':
        print('fixture stderr, not a protocol error',file=sys.stderr,flush=True)
        result={'protocolVersion':'2025-11-25','serverInfo':{'name':'stdio fixture','version':'1'},'capabilities':{'tools':{}}}
    elif method=='tools/list':
        result={'tools':[{'name':'echo','inputSchema':{'type':'object'}}]}
    elif method=='tools/call':
        result={'content':[{'type':'text','text':params['arguments']['text']}],'isError':False}
    else: result={}
    emit({'jsonrpc':'2.0','id':obj['id'],'result':result})
"""#

@Test @MainActor func mcpRealStdioHandlesFramingUnicodeAndStderr() async throws {
    var config = MCPConnectionConfiguration()
    config.executable = "/usr/bin/python3"
    config.arguments = MCPJSON.text(["-u", "-c", mcpStdioFixture])
    let client = MCPClient(); try await client.connect(config); defer { client.disconnect() }
    let tool = try #require(try await client.list(.tool).first)
    let result = try await client.perform(tool, arguments: #"{"text":"分片中文 👋\n换行"}"#)
    #expect(result.text == "分片中文 👋\n换行")
    #expect(client.logs.contains { $0.direction == "stderr" })
}

private let mcpHTTPFixture = #"""
import json,sys,threading,time
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
initialized=False
class Handler(BaseHTTPRequestHandler):
    protocol_version='HTTP/1.1'
    def log_message(self,*args): pass
    def send(self,status,body=b'',kind='application/json',extra=None):
        self.send_response(status); self.send_header('Content-Type',kind); self.send_header('Content-Length',str(len(body)))
        for k,v in (extra or {}).items(): self.send_header(k,v)
        self.end_headers(); self.wfile.write(body); self.wfile.flush()
    def do_DELETE(self): self.send(200)
    def do_POST(self):
        global initialized
        obj=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        method=obj.get('method'); ident=obj.get('id')
        if self.path=='/redirect':
            self.send(307,extra={'Location':'/mcp'}); return
        if self.path=='/denied': self.send(401); return
        if method=='initialize':
            result={'protocolVersion':'2025-11-25','serverInfo':{'name':'HTTP fixture','version':'1'},'capabilities':{'tools':{}}}
            self.send(200,json.dumps({'jsonrpc':'2.0','id':ident,'result':result}).encode(),extra={'MCP-Session-Id':'test-session'})
            return
        if self.headers.get('MCP-Session-Id')!='test-session' or self.headers.get('MCP-Protocol-Version')!='2025-11-25' or self.headers.get('Authorization')!='Bearer fixture':
            self.send(400); return
        if method=='notifications/initialized': initialized=True; self.send(202); return
        if method is None: self.send(202); return
        if ident is None: self.send(202); return
        if not initialized: self.send(409); return
        if method=='tools/list':
            result={'tools':[{'name':'echo','inputSchema':{'type':'object'}}]}
            body=': heartbeat\n\ndata: '+json.dumps({'jsonrpc':'2.0','method':'notifications/message','params':{'data':'hello'}})+'\n\ndata: '+json.dumps({'jsonrpc':'2.0','id':'server-ping','method':'ping'})+'\n\ndata: '+json.dumps({'jsonrpc':'2.0','id':ident,'result':result})+'\n\n'
            if self.path=='/open':
                self.send_response(200); self.send_header('Content-Type','text/event-stream'); self.send_header('Connection','close'); self.end_headers()
                self.wfile.write(body.encode()); self.wfile.flush(); time.sleep(5); self.close_connection=True; return
            self.send(200,body.encode(),'text/event-stream'); return
        if method=='tools/call':
            result={'content':[{'type':'text','text':obj['params']['arguments']['text']}],'isError':False}
            self.send(200,json.dumps({'jsonrpc':'2.0','id':ident,'result':result}).encode()); return
        self.send(404)
server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
print(server.server_address[1],flush=True)
server.serve_forever()
"""#

@Test @MainActor func mcpRealHTTPNegotiatesSessionHeadersAndBothResponseFormats() async throws {
    let process = Process(), output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3"); process.arguments = ["-u", "-c", mcpHTTPFixture]
    process.standardOutput = output; process.standardError = Pipe(); try process.run()
    defer { if process.isRunning { process.terminate() } }
    let bytes = await Task.detached { output.fileHandleForReading.availableData }.value
    let port = try #require(Int(String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
    var config = MCPConnectionConfiguration(); config.kind = .http
    config.endpoint = "http://127.0.0.1:\(port)/mcp"; config.headers = "{\"Authorization\":\"Bearer fixture\"}"
    let client = MCPClient(); try await client.connect(config)
    let tools = try await client.list(.tool)
    #expect(tools.count == 1)
    #expect(try await client.perform(tools[0], arguments: #"{"text":"HTTP + SSE 中文"}"#).text == "HTTP + SSE 中文")
    #expect(!client.logs.contains { $0.text.contains("Bearer fixture") || $0.text.contains("test-session") })
    #expect(client.logs.contains { $0.direction == "发送" && $0.text.contains("server-ping") })
    client.disconnect()
    config.endpoint = "http://127.0.0.1:\(port)/open"; config.timeout = 1
    try await client.connect(config)
    #expect(try await client.list(.tool).count == 1) // Matching SSE response completes before the stream closes.
    client.disconnect()
    for path in ["redirect", "denied"] {
        config.endpoint = "http://127.0.0.1:\(port)/\(path)"
        await #expect(throws: (any Error).self) { try await client.connect(config) }
        #expect(!client.connected)
    }
}
