import Foundation
import Testing
@testable import YukinoCore

private func curlValue(_ name: String, in plan: CurlCommandPlan) -> String? {
    guard let index = plan.arguments.firstIndex(of: name), index + 1 < plan.arguments.count else { return nil }
    return plan.arguments[index + 1]
}

@Test func curlJSONBodyPreviewFormatsNestedPOSTWithoutChangingCommandArguments() throws {
    let body = #"{"id":9007199254740993,"nested":{"items":["雪乃",{"path":"C:\\tools","newline":"\n"}]},"id":1.2300e+04}"#
    for option in ["--data", "--data-raw", "--data-binary", "--json"] {
        let original = "curl https://example.com/api -X POST \(option) '\(body)'"
        let plan = try CurlCommandParser.parse(original, shell: .bash)
        let pretty = try #require(CurlShellService.formattedJSONBody(plan))
        #expect(pretty.contains("\n  \"nested\": {\n    \"items\": ["))
        #expect(pretty.contains("9007199254740993"))
        #expect(pretty.contains("1.2300e+04"))
        #expect(try JSONService.transform(pretty, minify: true) == body)
        #expect(curlValue(option, in: plan) == body)
        for shell in CurlShell.allCases {
            let command = try CurlShellService.render(plan, shell: shell).text
            let imported = try CurlCommandParser.parse(command, shell: shell)
            #expect(CurlShellService.formattedJSONBody(imported) == pretty)
        }
    }
}

@Test func curlJSONBodyPreviewIgnoresFilesFormsCombinedDataAndOptionLikeValues() throws {
    for suffix in ["-H '--data-raw'", "-d @/does/not/exist.json", "--data-binary @-", "-d '{broken}'", "-d '{\"a\":1}' -d '{\"b\":2}'", "-d '{\"a\":1}' --data-urlencode 'x=1'", "--data-urlencode '123'", "--form-string 'x=123'", "-G --data-raw '123'", "-I --data-raw '123'"] {
        let plan = try CurlCommandParser.parse("curl https://example.com/api \(suffix)", shell: .bash)
        #expect(CurlShellService.formattedJSONBody(plan) == nil)
    }
    let plan = try CurlCommandParser.parse("curl https://example.com/api -H '--data' --data-raw '{\"ok\":true}'", shell: .bash)
    #expect(CurlShellService.formattedJSONBody(plan) == "{\n  \"ok\": true\n}")
}

@Test func curlPrettyJSONLivesInsideExecutableCommandsAndExportedScripts() throws {
    var request = CurlRequest(); request.method = .post; request.bodyMode = .json
    request.body = #"{"name":"it's 雪乃","id":9007199254740993,"nested":{"items":[true,null,{"path":"C:\\tools","text":"a & b | < > ( ) ^ $ ` \n \"quoted\""}]},"id":1.2300e+04}"#
    let plan = try CurlCommandService.plan(request)
    let pretty = try JSONService.transform(request.body)
    for shell in CurlShell.allCases {
        let rendered = try CurlShellService.render(plan, shell: shell, prettyJSON: true)
        #expect(rendered.text.contains("\n"))
        #expect(!rendered.text.contains("EncodedCommand"))
        let parsed = try CurlCommandParser.parse(rendered.text, shell: shell)
        let body = try #require(curlValue("--data-raw", in: parsed))
        #expect(try JSONService.transform(body, minify: true) == request.body)
        #expect(CurlShellService.formattedJSONBody(parsed) == pretty)
        #expect(parsed.arguments.filter { $0 != body } == plan.arguments.filter { $0 != request.body })
        if shell == .cmd {
            #expect(rendered.text.contains("--data-raw ^\"{^\n"))
            #expect(rendered.text.contains("\n      " + #"\^"nested"#))
            #expect(!body.contains("\n"))
            #expect(body.contains("9007199254740993"))
        } else { #expect(body == pretty) }
        let script = try CurlShellService.script(plan, shell: shell, prettyJSON: true)
        #expect(script.contains(shell == .cmd ? rendered.text.replacingOccurrences(of: "\n", with: "\r\n") : rendered.text))
        if shell == .bash {
            for executable in ["/bin/bash", "/bin/zsh"] {
                let process = Process(), output = Pipe()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = ["-c", "curl() { /usr/bin/printf '%s\\0' \"$@\"; };\n" + rendered.text]
                process.standardOutput = output; process.standardError = FileHandle.nullDevice
                try process.run()
                let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
                #expect(process.terminationStatus == 0)
                let actual = data.split(separator: 0, omittingEmptySubsequences: false).dropLast().map { String(decoding: $0, as: UTF8.self) }
                #expect(actual == parsed.arguments)
            }
        }
    }
    #expect(curlValue("--data-raw", in: plan) == request.body)
}

@Test func curlPrettyJSONRespectsSingleLineModeAndLeavesUnsupportedBodiesAndWrapperExact() throws {
    for suffix in ["--data-raw '{\"a\":1}'", "--data-raw 'ordinary text'", "--data-binary '@body.json'", "--data-raw '{\"a\":1}' --data-raw '{\"b\":2}'"] {
        let plan = try CurlCommandParser.parse("curl https://example.com/api \(suffix)", shell: .bash)
        for shell in CurlShell.allCases {
            let rendered = try CurlShellService.render(plan, shell: shell, multiline: false, prettyJSON: true)
            #expect(!rendered.text.contains("\n"))
            #expect(try CurlCommandParser.parse(rendered.text, shell: shell).arguments == plan.arguments)
            if CurlShellService.formattedJSONBody(plan) == nil {
                #expect(try CurlShellService.render(plan, shell: shell, prettyJSON: true) == CurlShellService.render(plan, shell: shell))
            }
        }
        let wrapped = try CurlShellService.render(plan, shell: .cmd, cmdStyle: .powershell, prettyJSON: true)
        #expect(try CurlCommandParser.parse(wrapped.text, shell: .cmd).arguments == plan.arguments)
    }
}

@Test func curlQueryPreservesExistingEscapesDuplicateKeysAndLiteralUnicode() throws {
    var request = CurlRequest()
    request.url = "https://example.com/api?fixed=a%2Bb&tag=old#section"
    request.query = [.init(name: "tag", value: "雪乃 +&=?"), .init(name: "tag", value: ""), .init(name: "skip", value: "no", enabled: false), .init()]
    let plan = try CurlCommandService.plan(request)
    #expect(plan.url == "https://example.com/api?fixed=a%2Bb&tag=old&tag=%E9%9B%AA%E4%B9%83%20%2B%26%3D%3F&tag=")
    #expect(plan.warnings.count == 1)
    #expect(plan.arguments.prefix(2) == ["--disable", "--globoff"])
}

@Test func curlJSONPreservesBytesAndContentTypeOverrides() throws {
    var request = CurlRequest(); request.method = .post; request.bodyMode = .json
    request.body = "{\n  \"id\": 9007199254740993, \"name\": \"Yukino\"\n}\n"
    let plan = try CurlCommandService.plan(request)
    #expect(curlValue("--data-raw", in: plan) == request.body)
    #expect(plan.arguments.contains("Content-Type: application/json"))
    request.headers = [.init(name: "content-type", value: "application/vnd.example+json")]
    let overridden = try CurlCommandService.plan(request)
    #expect(!overridden.arguments.contains("Content-Type: application/json"))
    #expect(overridden.arguments.contains("content-type: application/vnd.example+json"))
}

@Test func curlHeadersValidateNamesRejectInjectionAndSendEmptyValues() throws {
    var request = CurlRequest(); request.headers = [.init(name: "X-Empty", value: ""), .init(name: "X-Tag", value: "one"), .init(name: "X-Tag", value: "two")]
    let plan = try CurlCommandService.plan(request)
    #expect(plan.arguments.contains("X-Empty;"))
    #expect(plan.arguments.contains("X-Tag: one"))
    #expect(plan.arguments.contains("X-Tag: two"))
    for field in [CurlField(name: "Bad Name", value: "x"), .init(name: "X-Test", value: "ok\r\nInjected: true"), .init(name: "@file", value: "oops")] {
        request.headers = [field]
        #expect(throws: ToolError.self) { try CurlCommandService.plan(request) }
    }
}

@Test func curlBodyModesNeverInterpretLiteralAtSignsAsFiles() throws {
    var request = CurlRequest(); request.method = .post; request.bodyMode = .text; request.body = "@/does/not/exist\r\n"
    #expect(curlValue("--data-raw", in: try CurlCommandService.plan(request)) == request.body)
    request.bodyMode = .urlEncoded
    request.form = [.init(name: "tag", value: "@file +&"), .init(name: "tag", value: "雪乃")]
    #expect(curlValue("--data-raw", in: try CurlCommandService.plan(request)) == "tag=%40file%20%2B%26&tag=%E9%9B%AA%E4%B9%83")
    request.bodyMode = .multipart
    let plan = try CurlCommandService.plan(request)
    #expect(plan.arguments.contains("--form-string"))
    #expect(plan.arguments.contains("tag=@file +&"))
    request.headers = [.init(name: "Content-Type", value: "multipart/form-data")]
    #expect(throws: ToolError.self) { try CurlCommandService.plan(request) }
}

@Test func curlAuthModesAreExplicitAndRejectConflicts() throws {
    var request = CurlRequest(); request.auth = .bearer; request.bearerToken = "example-token"
    let bearer = try CurlCommandService.plan(request)
    #expect(bearer.containsCredentials)
    #expect(bearer.arguments.contains("Authorization: Bearer example-token"))
    request.headers = [.init(name: "authorization", value: "Other")]
    #expect(throws: ToolError.self) { try CurlCommandService.plan(request) }
    request.headers = []; request.auth = .basic; request.username = "user"; request.password = "p:a'ss$word"
    #expect(curlValue("--user", in: try CurlCommandService.plan(request)) == "user:p:a'ss$word")
    request.username = "bad:user"
    #expect(throws: ToolError.self) { try CurlCommandService.plan(request) }
}

@Test func curlHEADAndRedirectOptionsKeepTheirCurlSemantics() throws {
    var request = CurlRequest(); request.method = .head; request.includeHeaders = true; request.followRedirects = true
    let plan = try CurlCommandService.plan(request)
    #expect(plan.arguments.contains("--head"))
    #expect(!plan.arguments.contains("--request"))
    #expect(curlValue("--proto-redir", in: plan) == "=http,https")
    request.bodyMode = .text
    #expect(throws: ToolError.self) { try CurlCommandService.plan(request) }
}

@Test func curlGeneratorRejectsMalformedAndOversizedRequests() throws {
    for url in ["", "example.com", "file:///tmp/test", "https://user:pass@example.com", "http://example.com:0", "https://example.com/\nheader"] {
        var request = CurlRequest(); request.url = url
        #expect(throws: ToolError.self) { try CurlCommandService.plan(request) }
    }
    var request = CurlRequest(); request.bodyMode = .json; request.body = "{bad}"
    #expect(throws: ToolError.self) { try CurlCommandService.plan(request) }
    request.bodyMode = .text; request.body = String(repeating: "a", count: 65_537)
    #expect(throws: ToolError.self) { try CurlCommandService.plan(request) }
    request.body = "\0"
    #expect(throws: ToolError.self) { try CurlCommandService.plan(request) }
    request.body = ""; request.timeout = 0
    #expect(throws: ToolError.self) { try CurlCommandService.plan(request) }
}

@Test func curlBashAndZshPassExactlyTheIntendedArgumentsWithoutExecutingInput() throws {
    var request = CurlRequest(); request.method = .post; request.bodyMode = .text
    request.body = "@file\r\n雪乃 😀\t'\"\\$(printf unexpected)`uname` & | > %PATH% !\n"
    request.headers = [.init(name: "X-Test", value: "it's $(printf unexpected); & ! ^ %PATH%")]
    let plan = try CurlCommandService.plan(request)
    for shell in ["/bin/bash", "/bin/zsh"] {
        for multiline in [true, false] {
            let script = "curl() { /usr/bin/printf '%s\\0' \"$@\"; };\n" + plan.command(multiline: multiline)
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: shell)
            process.arguments = shell.hasSuffix("bash") ? ["--noprofile", "--norc", "-c", script] : ["-f", "-c", script]
            process.standardOutput = output; process.standardError = FileHandle.nullDevice
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            #expect(process.terminationStatus == 0)
            let actual = data.split(separator: 0, omittingEmptySubsequences: false).dropLast().map { String(decoding: $0, as: UTF8.self) }
            #expect(actual == plan.arguments)
            if !multiline { #expect(!plan.command(multiline: false).contains("\n")) }
        }
    }
}

@Test func curlAllShellsRoundTripQuotesBackslashesAndComplexBodies() throws {
    var request = CurlRequest(); request.method = .post; request.bodyMode = .text
    request.url = "https://example.com/api?first=1&second=2"
    request.body = "雪乃 😀\r\n'\"\\%NAME% ! $HOME `uname` “smart”\n"
    request.auth = .basic; request.username = "user"; request.password = "a'b\"\\$!%"
    let plan = try CurlCommandService.plan(request)
    for shell in CurlShell.allCases {
        for multiline in [false, true] {
            let rendered = try CurlShellService.render(plan, shell: shell, multiline: multiline, cmdStyle: shell == .cmd ? .powershell : .native)
            let decoded = try CurlCommandParser.parse(rendered.text, shell: shell)
            #expect(decoded.arguments == plan.arguments)
        }
    }
}

@Test func curlCMDLiteralArgumentsAndWindowsBackslashRulesRoundTrip() throws {
    var request = CurlRequest(); request.method = .post; request.bodyMode = .json
    request.body = #"{"path":"C:\\temp\\","text":"a&b|c<d>(e)^f'\""}"#
    let plan = try CurlCommandService.plan(request)
    let rendered = try CurlShellService.render(plan, shell: .cmd)
    #expect(rendered.text.hasPrefix("curl.exe"))
    #expect(try CurlCommandParser.parse(rendered.text, shell: .cmd).arguments == plan.arguments)
    for value in ["", "space here", "C:\\", #"a\\\"b"#, #"C:\a b\"#] {
        #expect(try CurlCommandParser.windowsTokens(CurlShellService.windowsQuote(value)) == [value])
    }
}

@Test func curlImportRecognizesBrowserCommandsAndCommonOptions() throws {
    let source = #"curl 'https://example.com/api?x=1&y=2' -XPOST -H 'Content-Type: application/json' --data-raw '{"name":"Yukino"}' -sSL --compressed"#
    let plan = try CurlCommandParser.parse(source, shell: .bash)
    #expect(plan.url == "https://example.com/api?x=1&y=2")
    #expect(curlValue("--request", in: plan) == "POST")
    #expect(plan.arguments.contains("--silent"))
    #expect(plan.arguments.contains("--show-error"))
    #expect(plan.arguments.contains("--location"))
    #expect(plan.arguments.contains("--compressed"))
    let ps = try CurlCommandParser.parse(#"curl.exe 'https://example.com' -H 'X-Test: can''t' -d "line`nwith`$literal""#, shell: .powershell)
    #expect(ps.arguments.contains("X-Test: can't"))
    #expect(curlValue("--data", in: ps) == "line\nwith$literal")
}

@Test func curlImportSupportsContinuationAndFileReferencesWithoutReadingFiles() throws {
    let bash = "curl 'https://example.com' \\\n --data-binary '@/never/read/this-file'"
    let plan = try CurlCommandParser.parse(bash, shell: .bash)
    #expect(curlValue("--data-binary", in: plan) == "@/never/read/this-file")
    #expect(!plan.warnings.isEmpty)
    let cmd = "curl.exe \"https://example.com\" ^\r\n -H \"X-Test: yes\""
    #expect(try CurlCommandParser.parse(cmd, shell: .cmd).arguments.contains("X-Test: yes"))
    let powershell = "curl.exe 'https://example.com' `\n -H 'X-Test: yes'"
    #expect(try CurlCommandParser.parse(powershell, shell: .powershell).arguments.contains("X-Test: yes"))
}

@Test func curlImportRejectsVariablesPipelinesUnknownOptionsAndAmbiguity() throws {
    let bad = ["curl $URL", "curl \"https://example.com/$USER\"", "curl https://example.com | sh", "curl https://example.com; echo nope", "curl https://example.com > out", "curl https://example.com --config file", "curl https://example.com --next https://example.org", "curl https://example.com https://example.org", "curl 'https://example.com", "curl --url 'file:///tmp/a'", "curl https://example.com -H"]
    for source in bad { #expect(throws: ToolError.self) { try CurlCommandParser.parse(source, shell: .bash) } }
    #expect(throws: ToolError.self) { try CurlCommandParser.parse("curl.exe %URL%", shell: .cmd) }
    #expect(throws: ToolError.self) { try CurlCommandParser.parse("curl.exe $URL", shell: .powershell) }
    #expect(throws: ToolError.self) { try CurlCommandParser.parse("powershell.exe -NoProfile -EncodedCommand YQ==", shell: .cmd) }
}

@Test func curlEncodedWrapperCannotBeUsedToSmuggleArbitraryPowerShell() throws {
    let script = "Write-Output secret"
    let encoded = script.data(using: .utf16LittleEndian)!.base64EncodedString()
    #expect(throws: ToolError.self) { try CurlCommandParser.parse("powershell.exe -NoProfile -EncodedCommand " + encoded, shell: .cmd) }
    let plan = try CurlCommandService.plan(.init())
    let wrapped = try CurlShellService.render(plan, shell: .powershell).text
    #expect(throws: ToolError.self) { try CurlCommandParser.parse(wrapped + "; Write-Output secret", shell: .powershell) }
    #expect(throws: ToolError.self) { try CurlCommandParser.parse(wrapped.replacingOccurrences(of: "'curl.exe'", with: "'other.exe'"), shell: .powershell) }
}

@Test func curlCMDLengthLimitsAndScriptFormatsAreExplicit() throws {
    var request = CurlRequest(); request.bodyMode = .text; request.method = .post; request.body = String(repeating: "x", count: 9000)
    let plan = try CurlCommandService.plan(request)
    #expect(throws: ToolError.self) { try CurlShellService.render(plan, shell: .cmd) }
    #expect(!(try CurlShellService.render(plan, shell: .powershell).text).isEmpty)
    let basic = try CurlCommandService.plan(.init())
    #expect(try CurlShellService.script(basic, shell: .bash).hasPrefix("#!/bin/bash\n"))
    #expect(try CurlShellService.script(basic, shell: .cmd).hasPrefix("@echo off\r\nsetlocal DisableDelayedExpansion\r\n"))
}

@Test func curlRealLocalHTTPPreservesRawBodiesQueryAndMultipartLiterals() throws {
    // All network traffic stays on a disposable loopback HTTP server.
    let serverCode = #"""
import base64, http.server, json
class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get('Content-Length', '0')))
        result = json.dumps({'path': self.path, 'headers': list(self.headers.items()), 'body': base64.b64encode(body).decode()}).encode()
        self.send_response(200)
        self.send_header('Content-Length', str(len(result)))
        self.end_headers()
        self.wfile.write(result)
    def log_message(self, *args): pass
server = http.server.HTTPServer(('127.0.0.1', 0), Handler)
server.timeout = 5
print(server.server_port, flush=True)
server.handle_request()
"""#
    for mode in [CurlBodyMode.text, .urlEncoded, .multipart] {
        let server = Process(), ready = Pipe()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3"); server.arguments = ["-u", "-c", serverCode]
        server.standardOutput = ready; server.standardError = FileHandle.nullDevice
        try server.run()
        defer { if server.isRunning { server.terminate() }; server.waitUntilExit() }
        var line = Data()
        while let next = try ready.fileHandleForReading.read(upToCount: 1), !next.isEmpty {
            if next.first == 10 { break }; line.append(next)
        }
        let port = try #require(Int(String(decoding: line, as: UTF8.self)))
        var request = CurlRequest(); request.url = "http://127.0.0.1:\(port)/api?old=a%2Bb"
        request.method = .post; request.bodyMode = mode; request.timeout = 3; request.connectTimeout = 2
        request.query = [.init(name: "tag", value: "a&b"), .init(name: "tag", value: "雪乃")]
        request.body = "@literal\r\n雪乃\n"
        request.form = [.init(name: "tag", value: "@/does/not/exist;type=text/plain"), .init(name: "tag", value: "a+b &雪乃")]
        request.headers = [.init(name: "X-Empty", value: ""), .init(name: "X-Test", value: "value")]
        let plan = try CurlCommandService.plan(request)
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl"); process.arguments = plan.arguments + ["--silent", "--show-error", "--noproxy", "*"]
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let captured = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(captured["path"] as? String == "/api?old=a%2Bb&tag=a%26b&tag=%E9%9B%AA%E4%B9%83")
        let encodedBody = try #require(captured["body"] as? String)
        let body = try #require(Data(base64Encoded: encodedBody))
        if mode == .text { #expect(body == Data(request.body.utf8)) }
        if mode == .urlEncoded { #expect(String(decoding: body, as: UTF8.self) == curlValue("--data-raw", in: plan)) }
        if mode == .multipart {
            let multipart = String(decoding: body, as: UTF8.self)
            #expect(multipart.contains("@/does/not/exist;type=text/plain"))
            #expect(multipart.contains("a+b &雪乃"))
        }
    }
}

@Test func curlImportPreservesLiteralCRLFAndRejectsMissingContinuations() throws {
    let raw = "curl 'https://example.com' --data-raw 'first\r\nsecond\n'"
    let plan = try CurlCommandParser.parse(raw, shell: .bash)
    #expect(curlValue("--data-raw", in: plan) == "first\r\nsecond\n")
    for shell in CurlShell.allCases {
        #expect(throws: ToolError.self) { try CurlCommandParser.parse("curl https://example.com\n-H X-Test:value", shell: shell) }
    }
    let continued = "curl 'https://example.com' \\\r\n --data-raw 'abc'"
    #expect(curlValue("--data-raw", in: try CurlCommandParser.parse(continued, shell: .bash)) == "abc")
    #expect(throws: ToolError.self) { try CurlCommandParser.parse("curl https://example.com -d #comment", shell: .bash) }
    #expect(throws: ToolError.self) { try CurlCommandParser.parse("curl https://example.com -d ~/file", shell: .bash) }
    #expect(throws: ToolError.self) { try CurlCommandParser.parse("curl https://example.com -d *", shell: .bash) }
}

@Test func curlCMDDefaultsToReadableNativeCommandAndGroupsOptionsWithValues() throws {
    var request = CurlRequest(); request.method = .post
    request.url = "https://example.com/api?x=1&y=2"
    request.headers = [.init(name: "X-Test", value: "one & two ^ three")]
    let plan = try CurlCommandService.plan(request)
    let native = try CurlShellService.render(plan, shell: .cmd)
    #expect(native.text.hasPrefix("curl.exe ^\n"))
    #expect(native.text.contains("--request \"POST\""))
    #expect(native.text.contains("--url \"https://example.com/api?x=1&y=2\""))
    #expect(!native.text.contains("powershell.exe"))
    #expect(!native.text.contains("EncodedCommand"))
    #expect(try CurlCommandParser.parse(native.text, shell: .cmd).arguments == plan.arguments)
    let singleLine = try CurlShellService.render(plan, shell: .cmd, multiline: false)
    #expect(!singleLine.text.contains("\n"))
    #expect(try CurlCommandParser.parse(singleLine.text, shell: .cmd).arguments == plan.arguments)
}

@Test func curlCMDDoesNotSilentlyWrapUnsupportedLiteralValues() throws {
    for value in ["line\nnext", "line\r\nnext", "100%", "%TOKEN%", "hello!"] {
        var request = CurlRequest(); request.method = .post; request.bodyMode = .text; request.body = value
        let plan = try CurlCommandService.plan(request)
        #expect(throws: ToolError.self) { try CurlShellService.render(plan, shell: .cmd) }
        let explicit = try CurlShellService.render(plan, shell: .cmd, cmdStyle: .powershell)
        #expect(explicit.text.hasPrefix("powershell.exe -NoProfile -EncodedCommand "))
        #expect(try CurlCommandParser.parse(explicit.text, shell: .cmd).arguments == plan.arguments)
    }
}

@Test func curlCMDAutomaticallyCompactsJSONAndPreservesOriginalInputAndNumbers() throws {
    var request = CurlRequest(); request.method = .post; request.bodyMode = .json
    request.body = "{\r\n  \"id\": 9007199254740993,\r\n  \"text\": \"first\\nsecond\", \"same\": 1, \"same\": 2\r\n}\r\n"
    let plan = try CurlCommandService.plan(request)
    let rendered = try CurlShellService.render(plan, shell: .cmd)
    #expect(rendered.text.hasPrefix("curl.exe ^\n"))
    #expect(!rendered.text.contains("EncodedCommand"))
    let decoded = try CurlCommandParser.parse(rendered.text, shell: .cmd)
    #expect(curlValue("--data-raw", in: decoded) == #"{"id":9007199254740993,"text":"first\nsecond","same":1,"same":2}"#)
    #expect(curlValue("--data-raw", in: plan) == request.body)
    #expect(rendered.warnings.contains(where: { $0.contains("自动将 JSON") }))
    let script = try CurlShellService.script(plan, shell: .cmd)
    #expect(script.contains("--data-raw"))
    #expect(!script.contains("powershell.exe"))
}

@Test func curlCMDDoesNotCompactFilesOrArbitraryTextAndOtherShellsStayExact() throws {
    let file = try CurlCommandParser.parse("curl 'https://example.com' --data-binary '@request.json'", shell: .bash)
    let fileCommand = try CurlShellService.render(file, shell: .cmd)
    #expect(try CurlCommandParser.parse(fileCommand.text, shell: .cmd).arguments == file.arguments)
    var request = CurlRequest(); request.bodyMode = .text; request.method = .post; request.body = "<xml>\n  <value>hello</value>\n</xml>"
    let plan = try CurlCommandService.plan(request)
    #expect(throws: ToolError.self) { try CurlShellService.render(plan, shell: .cmd) }
    for shell in [CurlShell.bash, .powershell] {
        let rendered = try CurlShellService.render(plan, shell: shell)
        #expect(try CurlCommandParser.parse(rendered.text, shell: shell).arguments == plan.arguments)
    }
}

@Test func curlScreenshotStyleSSEJSONConvertsToCMDWithoutManualPreparation() throws {
    let source = #"""
    curl -k -X POST 'https://example.com/api/stream' \
      -H 'Content-Type: application/json' \
      -H 'Accept: text/event-stream' \
      -H 'X-APP-ID: example-id' \
      -H 'X-APP-KEY: example-key' \
      --data-raw '{
        "businessType": "example",
        "apiKey": "",
        "apiData": {
          "name": "雪乃",
          "nested": [true, null, {"id": 9007199254740993}]
        }
      }'
    """#
    let original = try CurlCommandParser.parse(source, shell: .bash)
    let rendered = try CurlShellService.render(original, shell: .cmd)
    #expect(rendered.text.hasPrefix("curl.exe ^\n"))
    #expect(!rendered.text.contains("powershell.exe"))
    #expect(!rendered.text.contains("EncodedCommand"))
    let decoded = try CurlCommandParser.parse(rendered.text, shell: .cmd)
    let originalBody = try #require(curlValue("--data-raw", in: original))
    let convertedBody = try #require(curlValue("--data-raw", in: decoded))
    let expectedBody = try JSONService.transform(originalBody, minify: true)
    #expect(convertedBody == expectedBody)
    #expect(!convertedBody.contains("\n"))
    #expect(originalBody.contains("\n"))
    #expect(decoded.arguments.contains("Accept: text/event-stream"))
    #expect(decoded.arguments.contains("X-APP-KEY: example-key"))
    #expect(decoded.arguments.contains("--insecure"))
    let script = try CurlShellService.script(original, shell: .cmd)
    #expect(script.contains("curl.exe ^\r\n"))
    #expect(!script.contains("EncodedCommand"))
    let powershell = try CurlShellService.render(original, shell: .powershell)
    #expect(try CurlCommandParser.parse(powershell.text, shell: .powershell).arguments == original.arguments)
}

@Test func curlCMDAutoConversionOnlyChangesMultilineJSONBodyArguments() throws {
    let source = #"""
    curl 'https://example.com' --data-raw '{"keep":   1}' --data-raw '{
      "change": 2
    }' -H 'X-Text: value'
    """#
    let plan = try CurlCommandParser.parse(source, shell: .bash)
    let rendered = try CurlShellService.render(plan, shell: .cmd, multiline: false)
    let parsed = try CurlCommandParser.parse(rendered.text, shell: .cmd)
    #expect(parsed.arguments.contains(#"{"keep":   1}"#))
    #expect(parsed.arguments.contains(#"{"change":2}"#))
    #expect(parsed.arguments.contains("X-Text: value"))
    #expect(!rendered.text.contains("\n"))
    let wrapped = try CurlShellService.render(plan, shell: .cmd, cmdStyle: .powershell)
    #expect(try CurlCommandParser.parse(wrapped.text, shell: .cmd).arguments == plan.arguments)
}

@Test func curlImportCanBeCancelledBeforeParsingReplacedInput() async throws {
    let worker = Task.detached {
        while !Task.isCancelled { await Task.yield() }
        return try CurlCommandParser.parse("curl 'https://example.com'", shell: .bash)
    }
    worker.cancel()
    do { _ = try await worker.value; Issue.record("Cancelled import unexpectedly succeeded") }
    catch is CancellationError {} catch { Issue.record("Unexpected error: \(error)") }
}
