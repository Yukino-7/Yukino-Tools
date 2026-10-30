import Foundation
import Testing
@testable import YukinoCore

@Test func sseIncrementalFramingPreservesUTF8CRLFBOMAndMultilineData() throws {
    let bytes = Data("\u{FEFF}: heartbeat\r\nid: 9\r\nretry: 2000\r\nevent: custom\r\ndata: 你好🌊\r\ndata: second: value\r\n\r\ndata:\r\n\r\ndata: tail".utf8)
    for size in [1, 2, 3, 7, 19, bytes.count] {
        var parser = SSEParser(), events = [SSEEvent]()
        var offset = 0
        while offset < bytes.count { let end = min(offset + size, bytes.count); events += try parser.feed(bytes.subdata(in: offset..<end)); offset = end }
        #expect(events.count == 3)
        #expect(events[0].isComment)
        #expect(events[1].name == "custom")
        #expect(events[1].data == "你好🌊\nsecond: value")
        #expect(events[1].eventID == "9")
        #expect(events[1].retry == 2000)
        #expect(events[2].data == "")
        #expect(events[2].eventID == "9")
        parser.finish(); #expect(!parser.unfinished.isEmpty)
    }
}

@Test func sseBareCRUnknownFieldsAndIDResetFollowStandard() throws {
    var parser = SSEParser()
    let events = try parser.feed(Data("id: first\rdata: one\r\rid:\rretry: nope\runknown: x\rdata:  two\r\r".utf8))
    #expect(events.map(\.data) == ["one", " two"])
    #expect(events.last?.eventID == "")
    #expect(events.last?.retry == nil)
    parser.finish(); #expect(parser.unfinished.isEmpty)
    #expect(throws: (any Error).self) { _ = try parser.feed(Data(repeating: 120, count: 1_048_577)) }
}

private func streamEvents(_ data: String) throws -> [SSEEvent] { var parser = SSEParser(); return try parser.feed(Data(data.utf8)) }

@Test func aiChatKeepsChoicesAndToolsSeparateAndDoesNotSumCumulativeUsage() throws {
    let input = #"{"model":"test","choices":[{"index":0,"delta":{"content":"你","tool_calls":[{"index":0,"function":{"name":"lookup","arguments":"{"}}]}},{"index":1,"delta":{"content":"B"}}],"usage":{"total_tokens":8}}"#
    let next = #"{"choices":[{"index":0,"delta":{"content":"好","tool_calls":[{"index":0,"function":{"arguments":"}"}}]},"finish_reason":"tool_calls"}],"usage":{"total_tokens":10}}"#
    var result = AIStreamAccumulator()
    for event in try streamEvents("data: \(input)\n\ndata: \(next)\n\n") { result.consume(event) }
    #expect(result.detected == .chat)
    #expect(result.outputs[0].text == "你好")
    #expect(result.outputs[1].text == "B")
    #expect(result.outputs[0].tools["0"] == "{}")
    #expect(result.outputs[0].toolNames["0"] == "lookup")
    #expect(!result.completed)
    #expect(result.usage.contains("10"))
    for event in try streamEvents("data: [DONE]\n\n") { result.consume(event) }
    #expect(result.completed)
}

@Test func aiProtocolsSupportResponsesAnthropicGenericAndStreamErrors() throws {
    var responses = AIStreamAccumulator()
    for event in try streamEvents("event: response.output_text.delta\ndata: {\"type\":\"response.output_text.delta\",\"delta\":\"hello\"}\n\nevent: response.completed\ndata: {\"type\":\"response.completed\",\"response\":{\"usage\":{\"output_tokens\":2}}}\n\n") { responses.consume(event) }
    #expect(responses.text == "hello"); #expect(responses.completed); #expect(responses.detected == .responses)
    var anthropic = AIStreamAccumulator()
    let messages = [#"{"type":"message_start","message":{"model":"test","usage":{"input_tokens":7}}}"#, #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"hey"}}"#, #"{"type":"message_delta","usage":{"output_tokens":4}}"#, #"{"type":"message_stop"}"#]
    for message in messages { for event in try streamEvents("data: \(message)\n\n") { anthropic.consume(event) } }
    #expect(anthropic.text == "hey"); #expect(anthropic.completed)
    #expect(anthropic.usage.contains("input_tokens")); #expect(anthropic.usage.contains("output_tokens"))
    var generic = AIStreamAccumulator()
    for event in try streamEvents("data: {\"data\":{\"content\":\"a\"}}\n\ndata: {\"data\":{\"content\":\"ab\"}}\n\n") { generic.consume(event, mode: .generic, path: "data.content", cumulative: true) }
    #expect(generic.text == "ab")
    for event in try streamEvents("event: error\ndata: {\"error\":{\"message\":\"overloaded\"}}\n\n") { generic.consume(event) }
    #expect(generic.error == "overloaded")
}

@Test func curlExecutionBlocksFileAccessOutputConfusionAndUnsafeRedirects() throws {
    for suffix in ["-d @/tmp/body", "-H @/tmp/headers", "-b /tmp/cookies", "--data-urlencode x@/tmp/file", "--output /tmp/out", "--config /tmp/options", "--upload-file /tmp/file", "--cacert /tmp/cert", "--raw", "-L -H 'X-Secret: token'"] {
        #expect(throws: (any Error).self) { let parsed = try CurlCommandParser.parse("curl https://example.com \(suffix)", shell: .bash); _ = try CurlExecutionPlan(parsed) }
    }
    #expect(throws: (any Error).self) { _ = try CurlExecutionPlan(CurlCommandParser.parse("curl -L https://example.com -H 'Authorization: Bearer secret'", shell: .bash)) }
    let plan = try CurlExecutionPlan(CurlCommandParser.parse("curl -N -i -v https://example.com --data-raw '@literal'", shell: .bash))
    let text = String(decoding: plan.configuration, as: UTF8.self)
    #expect(text.contains("no-buffer")); #expect(text.contains("data-raw = \"@literal\""))
    #expect(!text.contains("verbose\n")); #expect(!text.contains("include\n"))
    #expect(try CurlExecutionPlan.quote("x\"\nurl = evil\\z") == "\"x\\\"\\nurl = evil\\\\z\"")
}

@Test func curlStreamRunsRealLocalSSEAndPreservesHeadersAndErrorBodies() async throws {
    let server = Process(), pipe = Pipe()
    server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    server.arguments = ["-u", "-c", """
    from http.server import BaseHTTPRequestHandler, HTTPServer
    import time, json
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *a): pass
        def do_POST(self):
            body=self.rfile.read(int(self.headers.get('Content-Length',0)))
            if self.path=='/error':
                self.send_response(429); self.send_header('Content-Type','application/json'); self.end_headers(); self.wfile.write(b'{"error":"rate limited"}'); return
            self.send_response(200); self.send_header('Content-Type','text/event-stream'); self.end_headers()
            self.wfile.write(('data: '+json.dumps({'choices':[{'index':0,'delta':{'content':body.decode()}}]})+'\\n\\n').encode()); self.wfile.flush()
            time.sleep(0.25)
            if self.path in ['/slow','/idle']: time.sleep(2)
            try: self.wfile.write(b'data: [DONE]\\n\\n'); self.wfile.flush()
            except BrokenPipeError: pass
    server=HTTPServer(('127.0.0.1',0),Handler)
    print(server.server_port,flush=True); server.serve_forever()
    """]
    server.standardOutput = pipe; server.standardError = FileHandle.nullDevice
    try server.run()
    defer { if server.isRunning { server.terminate(); server.waitUntilExit() } }
    var line = Data()
    while true { let byte = pipe.fileHandleForReading.readData(ofLength: 1); if byte.isEmpty || byte.first == 10 { break }; line.append(byte) }
    let port = try #require(Int(String(decoding: line, as: UTF8.self)))
    for route in ["/stream", "/error", "/idle", "/slow"] {
        let runner = CurlStreamRunner()
        let body = "你好 🌊 \\\"quoted\\\"\nurl = injected"
        let config = try CurlExecutionPlan(CurlCommandParser.parse("curl http://127.0.0.1:\(port)\(route) --data-raw " + CurlCommandService.shellQuote(body), shell: .bash))
        var received = Data(), headers = "", parser = SSEParser(), result = AIStreamAccumulator(), bodyTimes = [Double](), finished = false
        for try await update in runner.stream(config, idleTimeout: route == "/idle" ? 1 : 5) {
            switch update {
            case let .body(bytes, time):
                received.append(bytes); bodyTimes.append(time)
                for event in try parser.feed(bytes) { result.consume(event) }
                if route == "/slow" { runner.cancel() }
            case let .headers(text): headers = text
            case let .finished(code, _, reason): finished = true; if route == "/idle" { #expect(reason?.contains("未收到") == true) } else { #expect(reason == nil) }; if !["/slow", "/idle"].contains(route) { #expect(code == 0) }
            default: break
            }
        }
        #expect(finished)
        if route == "/error" { #expect(headers.contains("429")); #expect(String(decoding: received, as: UTF8.self).contains("rate limited")) }
        else { #expect(result.text == body); #expect(result.completed == (route == "/stream")); #expect(headers.contains("text/event-stream")) }
        if route == "/stream" { #expect(bodyTimes.count >= 2); #expect((bodyTimes.last ?? 0) - (bodyTimes.first ?? 0) > 0.15) }
    }
}

@Test func difyAnswersIgnoreHeartbeatsReplaceAndFinishWithoutDuplicating() throws {
    let messages = [
        #"{"event":"workflow_started","data":{}}"#,
        #"{"event":"ping"}"#,
        ###"{"event":"message","answer":"## 回答\n\n"}"###,
        #"{"event":"agent_message","answer":"**你好** 🌊"}"#,
        ###"{"event":"message_replace","answer":"## 最终回答\n\n已修正"}"###,
        #"{"event":"message_end","metadata":{"usage":{"total_tokens":12}}}"#,
        #"{"event":"workflow_finished","data":{"status":"succeeded","outputs":{"answer":"不要重复"}}}"#
    ]
    var result = AIStreamAccumulator()
    for event in try streamEvents("data: ping\n\n" + messages.map { "data: \($0)\n\n" }.joined()) { result.consume(event) }
    #expect(result.detected == .dify)
    #expect(result.text == "## 最终回答\n\n已修正")
    #expect(result.completed)
    #expect(result.malformedCount == 0)
    #expect(result.usage.contains("12"))
}

@Test func difyTextChunksWorkflowFallbackAndErrorsArePreserved() throws {
    var result = AIStreamAccumulator()
    for event in try streamEvents(#"data: {"event":"text_chunk","data":{"text":"hello"}}"# + "\n\n" + #"data: {"event":"workflow_finished","data":{"status":"failed","error":"node failed"}}"# + "\n\n") { result.consume(event) }
    #expect(result.text == "hello")
    #expect(result.error == "node failed")
    var workflow = AIStreamAccumulator()
    for event in try streamEvents(#"data: {"event":"workflow_finished","data":{"status":"succeeded","outputs":{"text":"final"}}}"# + "\n\n") { workflow.consume(event) }
    #expect(workflow.text == "final")
    #expect(workflow.completed)
}

@Test func genericAnswersSupportCommonFieldsAndExplicitPathOverrides() throws {
    var automatic = AIStreamAccumulator(), explicit = AIStreamAccumulator()
    for event in try streamEvents(#"data: {"data":{"content":"正文","other":"自定义"}}"# + "\n\n") {
        automatic.consume(event)
        explicit.consume(event, mode: .generic, path: "data.other")
    }
    #expect(automatic.text == "正文")
    #expect(explicit.text == "自定义")
    for event in try streamEvents("data: ordinary text\n\ndata: {broken\n\n") { automatic.consume(event) }
    #expect(automatic.malformedCount == 1)
}

@Test func thinkingTagsSplitAcrossEventsStaySeparateFromMarkdownAnswer() throws {
    var result = AIStreamAccumulator()
    let chunks = ["<thi", "nk>先分析", "</thi", "nk>## 答案\n\n", "**完成**"]
    for (index, chunk) in chunks.enumerated() {
        let data = try JSONSerialization.data(withJSONObject: ["choices": [["delta": ["content": chunk]]]])
        for event in try streamEvents("data: " + String(decoding: data, as: UTF8.self) + "\n\n") { result.consume(event) }
        if index < 4 { #expect(!result.text.contains("think")) }
    }
    #expect(result.text == "## 答案\n\n**完成**")
    #expect(result.outputs[0].thinkingText == "先分析")
    #expect(MarkdownDocument.parse(result.text).count == 2)
}

@Test func difyAgentFinalMessageReplacesTextChunks() throws {
    var result = AIStreamAccumulator()
    for event in try streamEvents(#"data: {"event":"text_chunk","data":{"text":"hello"}}"# + "\n\n" + #"data: {"event":"message","answer":"hello world"}"# + "\n\n") { result.consume(event) }
    #expect(result.text == "hello world")
}

@Test func genericResponseSnapshotsSeparateExecutionThoughtsAndComplete() throws {
    let messages = [
        #"{"response":"分析","responseAll":"分析","finished":false,"resultMap":{"eventData":{"resultMap":{"subMessageType":"exec_thought","execThought":"分析"}}}}"#,
        #"{"response":"步骤","responseAll":"分析步骤","finished":false,"resultMap":{"eventData":{"resultMap":{"subMessageType":"exec_thought","execThought":"步骤"}}}}"#,
        #"{"response":"正文","responseAll":"正文","finished":false}"#,
        #"{"response":"内容","responseAll":"正文内容","finished":false}"#,
        #"{"response":"","responseAll":"正文内容","finished":true,"useTokens":42}"#
    ]
    var result = AIStreamAccumulator()
    for event in try streamEvents(messages.map { "data: \($0)\n\n" }.joined()) { result.consume(event) }
    #expect(result.text == "正文内容")
    #expect(result.outputs[0].thinkingText == "分析步骤")
    #expect(result.completed)
    #expect(result.usage.contains("42"))
}

@Test func normalJSONResponsesPreserveNumbersKeysEscapesAndFragments() throws {
    let raw = #"{"id":9007199254740993,"amount":1.2300e+04,"id":2,"text":"雪乃\n\"quoted\""}"#
    let pretty = try #require(HTTPResponseService.formattedJSON(Data(raw.utf8)))
    #expect(pretty.contains("9007199254740993"))
    #expect(pretty.contains("1.2300e+04"))
    #expect(try JSONService.transform(pretty, minify: true) == raw)
    for text in ["[1,true,null]", "true", "null", "123", #"": not an SSE comment""#] {
        #expect(HTTPResponseService.formattedJSON(Data(text.utf8)) != nil)
        #expect(!HTTPResponseService.isEventStream(headers: "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n", prefix: Data(text.utf8)))
    }
    #expect(HTTPResponseService.formattedJSON(Data("\u{FEFF}".utf8) + Data(raw.utf8)) == pretty)
    #expect(HTTPResponseService.formattedJSON(Data("{incomplete".utf8)) == nil)
    #expect(HTTPResponseService.formattedJSON(Data([0xff, 0xfe])) == nil)
}

@Test func responseTransportUsesFinalContentTypeAndDoesNotConfuseTextWithSSE() {
    let prefix = Data("data: not an event\n\n".utf8)
    let jsonHeaders = "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\nContent-Type: Application/JSON; charset=utf-8\r\n\r\n"
    #expect(HTTPResponseService.contentType(jsonHeaders) == "application/json")
    #expect(!HTTPResponseService.isEventStream(headers: jsonHeaders, prefix: prefix))
    #expect(!HTTPResponseService.isEventStream(headers: "HTTP/1.1 200 OK\nContent-Type: text/plain\n\n", prefix: prefix))
    #expect(HTTPResponseService.isEventStream(headers: "", prefix: Data("\u{FEFF}data: {}\n\n".utf8)))
    #expect(HTTPResponseService.isEventStream(headers: "HTTP/1.1 200 OK\nContent-Type: text/event-stream; charset=utf-8\n\n", prefix: Data()))
    #expect(HTTPResponseService.contentType("HTTP/1.1 302 Found\nContent-Type: text/event-stream\n\nHTTP/1.1 204 No Content\n\n") == nil)
    #expect(HTTPResponseService.isEventStream(headers: jsonHeaders, prefix: prefix, forced: true))
}

@Test func curlRunnerSupportsOrdinaryJSONAndHTMLErrorsWithoutSSEParsing() async throws {
    let server = Process(), pipe = Pipe()
    server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    server.arguments = ["-u", "-c", """
    from http.server import BaseHTTPRequestHandler, HTTPServer
    class Handler(BaseHTTPRequestHandler):
        def log_message(self,*a): pass
        def do_GET(self):
            html=self.path=='/html'
            self.send_response(404 if html else (429 if self.path=='/error' else 200))
            self.send_header('Content-Type','text/html' if html else 'application/json; charset=utf-8')
            body=b'<html>not found</html>' if html else '{"id":9007199254740993,"text":"你好","error":null}'.encode()
            self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
    server=HTTPServer(('127.0.0.1',0),Handler)
    print(server.server_port,flush=True);server.serve_forever()
    """]
    server.standardOutput = pipe; server.standardError = FileHandle.nullDevice
    try server.run()
    defer { if server.isRunning { server.terminate(); server.waitUntilExit() } }
    var line = Data()
    while true { let byte = pipe.fileHandleForReading.readData(ofLength: 1); if byte.isEmpty || byte.first == 10 { break }; line.append(byte) }
    let port = try #require(Int(String(decoding: line, as: UTF8.self)))
    for path in ["/json", "/error", "/html"] {
        let execution = try CurlExecutionPlan(CurlCommandParser.parse("curl http://127.0.0.1:\(port)\(path)", shell: .bash))
        var raw = Data(), headers = "", finished = false
        for try await update in CurlStreamRunner().stream(execution) {
            switch update {
            case let .body(bytes, _): raw.append(bytes)
            case let .headers(value): headers = value
            case let .finished(code, _, reason): #expect(code == 0); #expect(reason == nil); finished = true
            default: break
            }
        }
        #expect(finished)
        #expect(!HTTPResponseService.isEventStream(headers: headers, prefix: raw))
        if path == "/html" { #expect(headers.contains("404")); #expect(HTTPResponseService.formattedJSON(raw) == nil) }
        else { #expect(HTTPResponseService.formattedJSON(raw)?.contains("9007199254740993") == true) }
        if path == "/error" { #expect(headers.contains("429")) }
    }
}
