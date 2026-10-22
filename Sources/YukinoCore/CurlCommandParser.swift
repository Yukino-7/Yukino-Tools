import Foundation

/// Literal command parsing only. No shell, subprocess, environment, file or network access.
public enum CurlCommandParser {
    public static func parse(_ input: String, shell: CurlShell) throws -> CurlCommandPlan {
        try Task.checkCancellation()
        guard input.utf8.count <= 262_144, !input.contains("\0") else { throw ToolError.invalid("命令最多 256 KB，不能包含 NUL。") }
        let source = input.trimmingCharacters(in: .whitespacesAndNewlines)
        var tokens: [String]
        if shell == .powershell, let unwrapped = try CurlShellService.unwrapPowerShell(source.replacingOccurrences(of: "\r\n", with: "\n")) { tokens = unwrapped }
        else if shell == .cmd {
            tokens = try windowsTokens(unescapeCMD(source))
            if tokens.first?.lowercased() == "powershell.exe" {
                guard tokens.count == 4, tokens[1] == "-NoProfile", tokens[2] == "-EncodedCommand",
                      let data = Data(base64Encoded: tokens[3]), let script = String(data: data, encoding: .utf16LittleEndian),
                      script.hasSuffix("; exit $LASTEXITCODE"),
                      let unwrapped = try CurlShellService.unwrapPowerShell(String(script.dropLast("; exit $LASTEXITCODE".count))) else {
                    throw ToolError.invalid("仅识别本工具生成的 CMD PowerShell 封装，不解析任意 PowerShell 脚本。")
                }
                tokens = unwrapped
            }
        } else {
            let literal = shell == .powershell && source.hasPrefix("& ") ? String(source.dropFirst(2)) : source
            tokens = try shellTokens(literal, shell: shell)
        }
        guard let executable = tokens.first?.lowercased(), ["curl", "curl.exe"].contains(executable) else {
            throw ToolError.invalid("请输入以 curl / curl.exe 开头的单条命令；不支持 Invoke-WebRequest、脚本或管道。")
        }
        tokens.removeFirst()
        guard !tokens.isEmpty, tokens.count <= 1000 else { throw ToolError.invalid("缺少 curl 参数，或参数数量超过 1,000。") }
        var normalized = [String](), urls = [String](), warnings = [String]()
        let values: Set<String> = ["--request", "--header", "--data", "--data-raw", "--data-binary", "--data-urlencode", "--json", "--form", "--form-string", "--user", "--oauth2-bearer", "--url", "--url-query", "--connect-timeout", "--max-time", "--proto", "--proto-redir", "--user-agent", "--referer", "--cookie", "--cookie-jar", "--output", "--upload-file", "--proxy", "--cert", "--key", "--cacert", "--resolve", "--range", "--write-out"]
        let flags: Set<String> = ["--disable", "--globoff", "--location", "--include", "--head", "--verbose", "--silent", "--show-error", "--compressed", "--insecure", "--get", "--http1.1", "--http2", "--no-buffer", "--fail", "--fail-with-body", "--path-as-is", "--raw", "--basic", "--digest", "--anyauth"]
        let short: [Character: String] = ["X":"--request", "H":"--header", "d":"--data", "F":"--form", "u":"--user", "m":"--max-time", "A":"--user-agent", "e":"--referer", "b":"--cookie", "c":"--cookie-jar", "o":"--output", "T":"--upload-file", "x":"--proxy", "r":"--range", "w":"--write-out", "q":"--disable", "g":"--globoff", "L":"--location", "i":"--include", "I":"--head", "v":"--verbose", "s":"--silent", "S":"--show-error", "k":"--insecure", "G":"--get", "N":"--no-buffer", "f":"--fail"]
        var index = 0
        func append(_ name: String, _ value: String?) throws {
            if let value {
                normalized += [name, value]
                if name == "--url" { urls.append(value) }
                if ["--data", "--data-binary", "--json", "--header", "--cookie"].contains(name) && value.hasPrefix("@") || ["--upload-file", "--cert", "--key", "--cacert", "--cookie-jar", "--output"].contains(name) || name == "--form" || name == "--data-urlencode" && value.contains("@") {
                    if !warnings.contains("命令涉及文件路径或 curl 文件语法；仅保留文本，未读取文件，跨系统后请检查路径。") {
                        warnings.append("命令涉及文件路径或 curl 文件语法；仅保留文本，未读取文件，跨系统后请检查路径。")
                    }
                }
            } else { normalized.append(name) }
        }
        while index < tokens.count {
            try Task.checkCancellation()
            let token = tokens[index]; index += 1
            if token.hasPrefix("--") {
                let parts = token.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                let name = parts[0]
                if flags.contains(name), parts.count == 1 { try append(name, nil) }
                else if values.contains(name) {
                    let value: String
                    if parts.count == 2 { value = parts[1] }
                    else {
                        guard index < tokens.count else { throw ToolError.invalid("\(name) 缺少参数。") }
                        value = tokens[index]; index += 1
                    }
                    try append(name, value)
                } else { throw ToolError.invalid("暂不支持选项 \(name)，已停止转换，避免丢失含义。") }
            } else if token.hasPrefix("-"), token.count > 1 {
                let characters = Array(token.dropFirst()); var offset = 0
                while offset < characters.count {
                    guard let name = short[characters[offset]] else { throw ToolError.invalid("暂不支持短选项 -\(characters[offset])，已停止转换。") }
                    offset += 1
                    if values.contains(name) {
                        let value: String
                        if offset < characters.count { value = String(characters[offset...]); offset = characters.count }
                        else {
                            guard index < tokens.count else { throw ToolError.invalid("\(name) 缺少参数。") }
                            value = tokens[index]; index += 1
                        }
                        try append(name, value)
                    } else { try append(name, nil) }
                }
            } else {
                guard let c = URLComponents(string: token), ["http", "https"].contains(c.scheme?.lowercased() ?? ""), c.host?.isEmpty == false else {
                    throw ToolError.invalid("无法识别参数“\(token.prefix(60))”；仅支持完整 HTTP / HTTPS URL 和已支持的 curl 选项。")
                }
                normalized += ["--url", token]; urls.append(token)
            }
        }
        guard urls.count == 1, let url = urls.first, let components = URLComponents(string: url),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""), components.host?.isEmpty == false, components.url != nil,
              components.port.map({ (1...65535).contains($0) }) ?? true,
              !url.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ToolError.invalid("转换需要且只支持一个完整的 HTTP / HTTPS URL。")
        }
        if normalized.contains("--insecure") { warnings.append("原命令包含 --insecure：执行时将跳过 TLS 证书验证。") }
        if !normalized.contains("--disable") { warnings.append("原命令未禁用 .curlrc；转换结果保留原参数，执行时可能受终端本机 curl 配置影响。") }
        let sensitive = components.user != nil || normalized.enumerated().contains { index, value in
            ["--user", "--oauth2-bearer", "--cookie", "--proxy"].contains(value) || value == "--header" && index + 1 < normalized.count && ["authorization:", "proxy-authorization:", "cookie:", "x-api-key:", "api-key:"].contains(where: { normalized[index + 1].lowercased().hasPrefix($0) })
        }
        return CurlCommandPlan(url: url, arguments: normalized, warnings: warnings, containsCredentials: sensitive)
    }

    static func shellTokens(_ input: String, shell: CurlShell) throws -> [String] {
        let chars = Array(input.unicodeScalars)
        var words = [String](), word = "", started = false, i = 0
        enum Quote { case none, single, double, ansi }
        var quote = Quote.none
        func fail(_ detail: String) -> ToolError { .invalid(detail) }
        func append(_ scalar: UnicodeScalar) { word.unicodeScalars.append(scalar); started = true }
        while i < chars.count {
            if i % 256 == 0 { try Task.checkCancellation() }
            let c = chars[i]; i += 1
            if quote == .single {
                if c == "'" {
                    if shell == .powershell, i < chars.count, chars[i] == "'" { append(c); i += 1 }
                    else { quote = .none }
                } else {
                    if shell == .powershell && (c == "‘" || c == "’") { throw fail("PowerShell 智能引号含义有歧义，请改用 ASCII 引号并转义内容。") }
                    append(c)
                }
                continue
            }
            if quote == .ansi {
                if c == "'" { quote = .none; continue }
                if c == "\\" {
                    guard i < chars.count else { throw fail("未完成的 ANSI-C 转义。") }
                    let escape = chars[i]; i += 1
                    let known: [UnicodeScalar: UnicodeScalar] = ["n":"\n", "r":"\r", "t":"\t", "a":"\u{07}", "b":"\u{08}", "f":"\u{0C}", "v":"\u{0B}", "\\":"\\", "'":"'", "\"":"\""]
                    if let value = known[escape] { append(value) }
                    else if (48...55).contains(escape.value) {
                        var digits = String(escape)
                        for _ in 0..<2 where i < chars.count && (48...55).contains(chars[i].value) { digits += String(chars[i]); i += 1 }
                        guard let value = UInt32(digits, radix: 8), value > 0, value <= 127, let scalar = UnicodeScalar(value) else { throw fail("仅支持 ASCII 八进制转义；非 ASCII 请直接使用 Unicode 文本。") }
                        append(scalar)
                    } else { throw fail("暂不支持 ANSI-C 转义 \\\(escape)，请改为字面文本。") }
                } else { append(c) }
                continue
            }
            let escape: UnicodeScalar = shell == .bash ? "\\" : "`"
            if c == escape {
                guard i < chars.count else { throw fail("命令结尾有未完成的转义或续行。") }
                let next = chars[i]; i += 1
                if next == "\n" { continue }
                if next == "\r", i < chars.count, chars[i] == "\n" { i += 1; continue }
                if shell == .bash {
                    if quote == .double && ![UnicodeScalar("$"), "`", "\"", "\\"].contains(next) { append(c) }
                    append(next)
                } else {
                    let known: [UnicodeScalar: UnicodeScalar] = ["n":"\n", "r":"\r", "t":"\t", "a":"\u{07}", "b":"\u{08}", "f":"\u{0C}", "v":"\u{0B}"]
                    append(quote == .double ? known[next] ?? next : next)
                }
                continue
            }
            if quote == .double {
                if c == "\"" { quote = .none }
                else if shell == .powershell && (c == "“" || c == "”") { throw fail("PowerShell 智能引号需转义，请使用 ASCII 引号或反引号转义。") }
                else if c == "$" || shell == .bash && c == "`" { throw fail("不展开变量或命令替换，请先将它们替换为字面值。") }
                else { append(c) }
                continue
            }
            if c == "\n" || c == "\r" { throw fail("多行命令缺少续行符：Linux 使用反斜杠，PowerShell 使用反引号。") }
            if c == "#" && !started { throw fail("不解析 Shell 注释，请只粘贴单条 curl 命令。") }
            if shell == .bash && ((c == "~" && !started) || "*?[".unicodeScalars.contains(c)) { throw fail("未加引号的参数可能触发 Shell 展开，请先将参数加上引号。") }
            if c.properties.isWhitespace {
                if started { words.append(word); word = ""; started = false }
            } else if c == "'" { quote = .single; started = true }
            else if c == "\"" { quote = .double; started = true }
            else if c == "$", shell == .bash, i < chars.count, chars[i] == "'" { i += 1; quote = .ansi; started = true }
            else if c == "$" || "|;&<>`(){}".unicodeScalars.contains(c) || shell == .powershell && "@,“”‘’".unicodeScalars.contains(c) {
                throw fail("仅支持一条使用字面参数的 curl 命令；不支持变量、管道、重定向或脚本表达式。")
            } else { append(c) }
        }
        guard quote == .none else { throw fail("引号未闭合，请检查命令所用的终端版本。") }
        if started { words.append(word) }
        return words
    }

    private static func unescapeCMD(_ input: String) throws -> String {
        let chars = Array(input.unicodeScalars); var output = "", quoted = false, i = 0
        while i < chars.count {
            if i % 256 == 0 { try Task.checkCancellation() }
            let c = chars[i]; i += 1
            if c == "^", !quoted {
                guard i < chars.count else { throw ToolError.invalid("CMD 命令以未完成的 ^ 续行或转义结尾。") }
                let next = chars[i]; i += 1
                if next == "\r", i < chars.count, chars[i] == "\n" { i += 1 }
                else if next != "\n" { output.unicodeScalars.append(next) }
            } else {
                if c == "\n" || c == "\r" { throw ToolError.invalid("CMD 多行命令缺少 ^ 续行符。") }
                if c == "\"" { quoted.toggle() }
                if !quoted && "&|<>()".unicodeScalars.contains(c) { throw ToolError.invalid("CMD 命令包含运算符或重定向，不支持转换任意脚本。") }
                if c == "!" { throw ToolError.invalid("CMD 参数含 !，其值受延迟扩展影响；请提供展开后的字面值或 PowerShell 版本。") }
                output.unicodeScalars.append(c)
            }
        }
        // Literal percent-encoded URLs are retained. Shell variable references are
        // ambiguous and must not be silently substituted by this offline parser.
        if output.range(of: #"%[A-Za-z_][A-Za-z0-9_]*%"#, options: .regularExpression) != nil {
            throw ToolError.invalid("CMD 中存在可能的 %变量% 或有歧义的百分号序列，请提供展开后的 URL 或本工具生成的封装版本。")
        }
        return output
    }

    static func windowsTokens(_ input: String) throws -> [String] {
        let chars = Array(input.unicodeScalars); var result = [String](), word = "", quoted = false, started = false, i = 0
        while i < chars.count {
            if i % 256 == 0 { try Task.checkCancellation() }
            let c = chars[i]
            if c.properties.isWhitespace && !quoted {
                if started { result.append(word); word = ""; started = false }
                i += 1; continue
            }
            if c == "\\" {
                var count = 0
                while i < chars.count, chars[i] == "\\" { count += 1; i += 1 }
                if i < chars.count, chars[i] == "\"" {
                    word += String(repeating: "\\", count: count / 2)
                    if count % 2 == 1 { word += "\""; i += 1 }
                    else { quoted.toggle(); i += 1 }
                } else { word += String(repeating: "\\", count: count) }
                started = true
            } else if c == "\"" {
                if quoted, i + 1 < chars.count, chars[i + 1] == "\"" { word += "\""; i += 2 }
                else { quoted.toggle(); i += 1 }
                started = true
            } else { word.unicodeScalars.append(c); started = true; i += 1 }
        }
        guard !quoted else { throw ToolError.invalid("Windows 命令引号未闭合。") }
        if started { result.append(word) }
        return result
    }
}
