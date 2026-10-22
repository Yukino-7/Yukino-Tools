import Foundation

public enum CurlShell: String, CaseIterable, Sendable {
    case bash = "Linux / macOS（bash / zsh）"
    case cmd = "Windows CMD"
    case powershell = "Windows PowerShell（5.1 / 7）"
    public var fileExtension: String { self == .bash ? "sh" : self == .cmd ? "cmd" : "ps1" }
}
public enum CurlCMDStyle: String, CaseIterable, Sendable {
    case native = "原生 curl.exe"
    case powershell = "PowerShell 兼容封装"
}
public struct CurlRenderedCommand: Equatable, Sendable {
    public let text: String
    public let warnings: [String]
}

public enum CurlShellService {
    /// A readable view of one literal JSON body. Never reads referenced files or
    /// mistakes a header/option value for a body; combined data is not a single JSON document.
    public static func formattedJSONBody(_ plan: CurlCommandPlan) -> String? {
        let groups = argumentGroups(plan.arguments)
        guard !groups.contains(where: { ["--get", "--head"].contains($0[0]) }) else { return nil }
        let bodyOptions = jsonBodyOptions.union(["--data-urlencode", "--form", "--form-string", "--upload-file"])
        let bodies = groups.filter { bodyOptions.contains($0[0]) }
        guard bodies.count == 1, let body = bodies.first, body.count == 2,
              jsonBodyOptions.contains(body[0]) else { return nil }
        return try? JSONService.transform(body[1])
    }

    public static func render(_ original: CurlCommandPlan, shell: CurlShell, multiline: Bool = true, cmdStyle: CurlCMDStyle = .native, prettyJSON: Bool = false) throws -> CurlRenderedCommand {
        let prettyBody = prettyJSON && multiline ? formattedJSONBody(original) : nil
        let bodyIndex = prettyBody == nil ? nil : argumentGroups(original.arguments).firstIndex { jsonBodyOptions.contains($0[0]) }
        let compactJSON = shell == .cmd && cmdStyle == .native && requiresJSONCompaction(original)
        let plan = compactJSON ? try compactedJSONPlan(original) : original
        guard !plan.arguments.contains(where: { $0.contains("\0") }) else { throw ToolError.invalid("命令参数不能包含 NUL。") }
        switch shell {
        case .bash:
            if let prettyBody, let bodyIndex {
                let lines = argumentGroups(plan.arguments).enumerated().map { index, group in
                    if index == bodyIndex {
                        return CurlCommandService.shellQuote(group[0]) + " '" + prettyBody.replacingOccurrences(of: "'", with: "'\\''") + "'"
                    }
                    return group.map(CurlCommandService.shellQuote).joined(separator: " ")
                }
                return .init(text: "curl \\\n  " + lines.joined(separator: " \\\n  "), warnings: [])
            }
            return .init(text: plan.command(multiline: multiline), warnings: [])
        case .powershell:
            var arguments = plan.arguments
            if let prettyBody, let bodyIndex {
                var groups = argumentGroups(arguments); groups[bodyIndex][1] = prettyBody
                arguments = groups.flatMap { $0 }
            }
            guard nativeArguments(arguments).utf16.count < 32_000 else { throw ToolError.invalid("Windows 命令行超过长度限制，请缩短请求体。") }
            return .init(text: powershellScript(arguments, multiline: multiline, literalNewlines: prettyBody != nil), warnings: ["采用 PowerShell 5.1 / 7 兼容的 curl.exe 启动形式，保留 JSON 引号。"])
        case .cmd:
            let needsWrapper = cmdStyle == .powershell
            let text: String
            var warnings: [String]
            if needsWrapper {
                // CMD expands %...% even in quotes, and can expand !...! depending
                // on /V. A fixed, encoded PowerShell launcher avoids both phases.
                let script = powershellScript(plan.arguments, multiline: false) + "; exit $LASTEXITCODE"
                let encoded = script.data(using: .utf16LittleEndian)!.base64EncodedString()
                text = "powershell.exe -NoProfile -EncodedCommand " + encoded
                warnings = ["已选择 PowerShell 兼容封装：命令可在 CMD 中运行，编码仅用于完整保留参数，不是加密。"]
            } else {
                if plan.arguments.contains(where: { $0.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } }) {
                    throw ToolError.invalid("原生 CMD 不能内联保留换行或控制字符。有效的多行 JSON 会自动转为单行；其他内容请使用请求体文件，或选择“PowerShell 兼容封装”。")
                }
                if plan.arguments.contains(where: { $0.contains("%") || $0.contains("!") }) {
                    throw ToolError.invalid("参数含 % 或 !，可能被 CMD 当成变量展开。为保留原值，请显式选择“PowerShell 兼容封装”，或切换 PowerShell 目标。")
                }
                let lines = argumentGroups(plan.arguments).enumerated().map { index, group in
                    if index == bodyIndex, let prettyBody {
                        // Every quote is caret-escaped, so continuations occur outside
                        // CMD quoting. The CRT's outer quotes keep this one argv value.
                        let body = windowsQuote(prettyBody).components(separatedBy: "\n").map { line in
                            let indentation = line.prefix(while: { $0 == " " })
                            let escaped = line.dropFirst(indentation.count).map { "^\"&|<>() ".contains($0) ? "^" + String($0) : String($0) }.joined()
                            return String(indentation) + escaped
                        }.joined(separator: "^\n    ")
                        return group[0] + " " + body
                    }
                    return group.count == 2 ? group[0] + " " + cmdQuote(group[1]) : group[0]
                }
                text = multiline ? "curl.exe ^\n  " + lines.joined(separator: " ^\n  ") : (["curl.exe"] + lines).joined(separator: " ")
                warnings = []
            }
            guard text.utf16.count <= 8000 else { throw ToolError.invalid("CMD 命令超过约 8 KB 的长度限制，请切换到 PowerShell 或缩短请求体。") }
            if prettyBody != nil && !needsWrapper { warnings.append("JSON 请求体已在命令内缩进排版，使用 ^ 续行；原始输入保持不变。") }
            else if compactJSON { warnings.append("已自动将 JSON 请求体转为单行以适配 CMD，保留数值和转义文本；原始输入保持不变。") }
            warnings.append("CMD 版本用于直接粘贴到交互终端；导出 .cmd 时会按批处理模式生成。")
            return .init(text: text, warnings: warnings)
        }
    }

    public static func script(_ plan: CurlCommandPlan, shell: CurlShell, multiline: Bool = true, cmdStyle: CurlCMDStyle = .native, prettyJSON: Bool = false) throws -> String {
        let rendered = try render(plan, shell: shell, multiline: multiline, cmdStyle: cmdStyle, prettyJSON: prettyJSON).text
        switch shell {
        case .bash: return "#!/bin/bash\n" + rendered + "\n"
        case .powershell: return rendered + "\r\n"
        case .cmd:
            // Wrapper commands contain no percent signs. Literal CMD commands use
            // batch escaping in addition to interactive command escaping.
            return "@echo off\r\nsetlocal DisableDelayedExpansion\r\n" + rendered.replacingOccurrences(of: "%", with: "%%").replacingOccurrences(of: "\n", with: "\r\n") + "\r\n"
        }
    }

    private static func cmdQuote(_ value: String) -> String {
        let quoted = windowsQuote(value)
        // Ordinary values stay readable. Embedded quotes require escaping CMD's
        // parser separately from the CRT parser; protect all metacharacters then.
        if !value.contains("\"") { return quoted }
        return quoted.map { "^\"&|<>() ".contains($0) ? "^" + String($0) : String($0) }.joined()
    }

    private static let noValueOptions: Set<String> = ["--disable", "--globoff", "--location", "--include", "--head", "--verbose", "--silent", "--show-error", "--compressed", "--insecure", "--get", "--http1.1", "--http2", "--no-buffer", "--fail", "--fail-with-body", "--path-as-is", "--raw", "--basic", "--digest", "--anyauth"]
    private static let jsonBodyOptions: Set<String> = ["--data", "--data-raw", "--data-binary", "--json"]
    private static func argumentGroups(_ arguments: [String]) -> [[String]] {
        var groups = [[String]](), index = 0
        while index < arguments.count {
            let length = !noValueOptions.contains(arguments[index]) && index + 1 < arguments.count ? 2 : 1
            groups.append(Array(arguments[index..<index + length])); index += length
        }
        return groups
    }
    private static func requiresJSONCompaction(_ plan: CurlCommandPlan) -> Bool {
        argumentGroups(plan.arguments).contains { group in
            group.count == 2 && jsonBodyOptions.contains(group[0])
                && group[1].unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
                && (try? JSONService.transform(group[1], minify: true)) != nil
        }
    }
    private static func compactedJSONPlan(_ plan: CurlCommandPlan) throws -> CurlCommandPlan {
        var changed = false
        let groups = argumentGroups(plan.arguments).map { group -> [String] in
            guard group.count == 2, jsonBodyOptions.contains(group[0]), group[1].unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }), let value = try? JSONService.transform(group[1], minify: true) else { return group }
            changed = true
            return [group[0], value]
        }
        guard changed else { throw ToolError.invalid("没有可压缩的内联 JSON 请求体；文件引用和其他文本不会被改写。") }
        return CurlCommandPlan(url: plan.url, arguments: groups.flatMap { $0 }, warnings: plan.warnings, containsCredentials: plan.containsCredentials)
    }

    private static func powershellScript(_ arguments: [String], multiline: Bool, literalNewlines: Bool = false) -> String {
        [
            "$curlStart = New-Object System.Diagnostics.ProcessStartInfo",
            "$curlStart.FileName = 'curl.exe'",
            "$curlStart.Arguments = " + psQuote(nativeArguments(arguments), literalNewlines: literalNewlines),
            "$curlStart.UseShellExecute = $false",
            "$curlProcess = [System.Diagnostics.Process]::Start($curlStart)",
            "$curlProcess.WaitForExit()",
            "$global:LASTEXITCODE = $curlProcess.ExitCode"
        ].joined(separator: multiline ? "\n" : "; ")
    }

    // Win32 CRT quoting, applied to each argv entry before bypassing the shell.
    static func windowsQuote(_ value: String) -> String {
        var result = "\"", slashes = 0
        for scalar in value.unicodeScalars {
            if scalar == "\\" { slashes += 1; continue }
            if scalar == "\"" { result += String(repeating: "\\", count: slashes * 2 + 1) + "\"" }
            else { result += String(repeating: "\\", count: slashes) + String(scalar) }
            slashes = 0
        }
        return result + String(repeating: "\\", count: slashes * 2) + "\""
    }
    private static func nativeArguments(_ arguments: [String]) -> String { arguments.map(windowsQuote).joined(separator: " ") }
    static func psQuote(_ value: String, literalNewlines: Bool = false) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "`", "$", "\"", "“", "”": result += "`" + String(scalar)
            case "\n": result += literalNewlines ? "\n" : "`n"
            case "\r": result += "`r"
            case "\t": result += "`t"
            case "\u{07}": result += "`a"
            case "\u{08}": result += "`b"
            case "\u{0C}": result += "`f"
            case "\u{0B}": result += "`v"
            default: result += String(scalar)
            }
        }
        return result + "\""
    }

    /// Recognizes only our exact fixed launcher template, never arbitrary scripts.
    static func unwrapPowerShell(_ source: String) throws -> [String]? {
        let prefix = "$curlStart = New-Object System.Diagnostics.ProcessStartInfo"
        guard source.hasPrefix(prefix) else { return nil }
        let separator = source.hasPrefix(prefix + "; ") ? "; " : "\n"
        let head = prefix + separator + "$curlStart.FileName = 'curl.exe'" + separator + "$curlStart.Arguments = "
        let tail = separator + "$curlStart.UseShellExecute = $false" + separator + "$curlProcess = [System.Diagnostics.Process]::Start($curlStart)" + separator + "$curlProcess.WaitForExit()" + separator + "$global:LASTEXITCODE = $curlProcess.ExitCode"
        guard source.hasPrefix(head), source.hasSuffix(tail) else { throw ToolError.invalid("PowerShell 封装与支持的固定模板不一致；不解析任意脚本。") }
        let literal = String(source.dropFirst(head.count).dropLast(tail.count))
        let values = try CurlCommandParser.shellTokens(literal, shell: .powershell)
        guard values.count == 1 else { throw ToolError.invalid("PowerShell 参数字符串无效。") }
        let arguments = try CurlCommandParser.windowsTokens(values[0])
        // Regeneration ensures the supposedly literal string cannot contain code.
        guard source == powershellScript(arguments, multiline: separator == "\n") || source == powershellScript(arguments, multiline: separator == "\n", literalNewlines: true) else { throw ToolError.invalid("PowerShell 封装不符合固定模板。") }
        return ["curl.exe"] + arguments
    }
}
