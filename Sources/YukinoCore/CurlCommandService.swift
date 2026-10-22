import Foundation

public enum CurlMethod: String, CaseIterable, Sendable {
    case get = "GET", post = "POST", put = "PUT", patch = "PATCH", delete = "DELETE", head = "HEAD", options = "OPTIONS"
}
public enum CurlBodyMode: String, CaseIterable, Sendable {
    case none = "无请求体", json = "JSON", text = "纯文本", urlEncoded = "URL 编码表单", multipart = "Multipart 文本字段"
}
public enum CurlAuthMode: String, CaseIterable, Sendable {
    case none = "无认证", bearer = "Bearer Token", basic = "Basic Auth"
}
public struct CurlField: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var enabled: Bool
    public var name: String
    public var value: String
    public init(name: String = "", value: String = "", enabled: Bool = true) {
        id = UUID(); self.name = name; self.value = value; self.enabled = enabled
    }
}
public struct CurlRequest: Equatable, Sendable {
    public var url = "https://example.com/api/items"
    public var method = CurlMethod.get
    public var query: [CurlField] = []
    public var headers: [CurlField] = []
    public var bodyMode = CurlBodyMode.none
    public var body = ""
    public var form: [CurlField] = []
    public var auth = CurlAuthMode.none
    public var bearerToken = ""
    public var username = ""
    public var password = ""
    public var followRedirects = false
    public var includeHeaders = false
    public var verbose = false
    public var timeout = 30
    public var connectTimeout = 10
    public init() {}
}
public struct CurlCommandPlan: Equatable, Sendable {
    public let url: String
    public let arguments: [String]
    public let warnings: [String]
    public let containsCredentials: Bool
    public func command(multiline: Bool = true) -> String {
        let pieces = arguments.map(CurlCommandService.shellQuote)
        return multiline ? "curl \\\n  " + pieces.joined(separator: " \\\n  ") : (["curl"] + pieces).joined(separator: " ")
    }

}

/// Builds request arguments only; never executes curl or sends network requests.
public enum CurlCommandService {
    public static func plan(_ request: CurlRequest) throws -> CurlCommandPlan {
        guard request.url.utf8.count <= 8192, request.body.utf8.count <= 65_536,
              request.query.count <= 100, request.headers.count <= 100, request.form.count <= 100 else {
            throw ToolError.invalid("URL 最多 8 KB，请求体最多 64 KB，每组参数最多 100 行。")
        }
        guard (1...3600).contains(request.timeout), (1...3600).contains(request.connectTimeout) else {
            throw ToolError.invalid("总超时和连接超时须为 1–3600 秒。")
        }
        guard !request.body.contains("\0"), !request.password.contains("\0"), !request.username.contains("\0") else {
            throw ToolError.invalid("输入不能包含 NUL 字符。")
        }
        let query = try activeFields(request.query, label: "查询参数")
        let headers = try activeFields(request.headers, label: "请求头")
        let form = request.bodyMode == .urlEncoded || request.bodyMode == .multipart ? try activeFields(request.form, label: "表单") : []
        let inputURL = request.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !hasControl(inputURL), var components = URLComponents(string: inputURL),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty, components.url != nil,
              components.port.map({ (1...65535).contains($0) }) ?? true else {
            throw ToolError.invalid("请输入完整的 HTTP / HTTPS URL，例如 https://example.com/api。")
        }
        guard components.user == nil && components.password == nil else {
            throw ToolError.invalid("请移除 URL 中的用户名和密码，改在“认证”中填写。")
        }
        var warnings = [String]()
        if components.fragment != nil {
            components.fragment = nil
            warnings.append("URL 的 #fragment 不会发送给服务器，已从命令中移除。")
        }
        let addedQuery = query.map { percentEncode($0.name) + "=" + percentEncode($0.value) }.joined(separator: "&")
        if !addedQuery.isEmpty {
            let existing = components.percentEncodedQuery ?? ""
            components.percentEncodedQuery = existing.isEmpty ? addedQuery : existing + "&" + addedQuery
        }
        guard let url = components.url?.absoluteString else { throw ToolError.invalid("URL 无法编码。") }
        guard request.method != .head || request.bodyMode == .none else {
            throw ToolError.invalid("HEAD 只获取响应头，请将请求体切换为“无请求体”。")
        }
        var arguments = ["--disable", "--globoff"]
        if request.method == .head { arguments.append("--head") }
        else { arguments += ["--request", request.method.rawValue] }
        arguments += ["--url", url, "--connect-timeout", String(request.connectTimeout), "--max-time", String(request.timeout)]
        if request.followRedirects { arguments += ["--location", "--proto-redir", "=http,https"] }
        if request.includeHeaders && request.method != .head { arguments.append("--include") }
        if request.verbose { arguments.append("--verbose") }
        var headerNames = Set<String>()
        let tokenCharacters = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
        for field in headers {
            guard field.name.unicodeScalars.allSatisfy({ tokenCharacters.contains($0) }), !hasControl(field.value) else {
                throw ToolError.invalid("请求头名称须为合法 HTTP 字段名，值不能包含换行或控制字符。")
            }
            headerNames.insert(field.name.lowercased())
            // curl treats 'Name:' as removal; 'Name;' sends a genuinely empty header.
            arguments += ["--header", field.value.isEmpty ? field.name + ";" : field.name + ": " + field.value]
        }
        if request.auth != .none && headerNames.contains("authorization") {
            throw ToolError.invalid("请求头中已有 Authorization，请选择“无认证”或删除该请求头，避免重复认证。")
        }
        switch request.auth {
        case .none: break
        case .bearer:
            let token = request.bearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty, !token.contains(where: \.isWhitespace), !hasControl(token), token.utf8.count <= 8192 else {
                throw ToolError.invalid("请输入不含空白的 Bearer Token，最多 8 KB。")
            }
            arguments += ["--header", "Authorization: Bearer " + token]
        case .basic:
            guard !request.username.isEmpty, !request.username.contains(":"), !hasControl(request.username), !hasControl(request.password),
                  request.username.utf8.count + request.password.utf8.count <= 8192 else {
                throw ToolError.invalid("Basic 用户名不能为空或包含冒号；凭据不能含控制字符，合计最多 8 KB。")
            }
            arguments += ["--basic", "--user", request.username + ":" + request.password]
        }
        func contentType(_ value: String) {
            if !headerNames.contains("content-type") { arguments += ["--header", "Content-Type: " + value] }
        }
        switch request.bodyMode {
        case .none: break
        case .json:
            guard (try? JSONSerialization.jsonObject(with: Data(request.body.utf8), options: [.fragmentsAllowed])) != nil else {
                throw ToolError.invalid("JSON 请求体格式无效，请检查后再复制命令。")
            }
            contentType("application/json")
            arguments += ["--data-raw", request.body]
        case .text:
            contentType("text/plain; charset=utf-8")
            arguments += ["--data-raw", request.body]
        case .urlEncoded:
            contentType("application/x-www-form-urlencoded")
            arguments += ["--data-raw", form.map { percentEncode($0.name) + "=" + percentEncode($0.value) }.joined(separator: "&")]
        case .multipart:
            guard !form.isEmpty else { throw ToolError.invalid("Multipart 至少需要一个文本字段。") }
            guard !headerNames.contains("content-type") else {
                throw ToolError.invalid("Multipart 的 Content-Type 与 boundary 由 curl 生成，请移除自定义 Content-Type 请求头。")
            }
            for field in form {
                guard !field.name.contains("="), !hasControl(field.name) else { throw ToolError.invalid("Multipart 字段名不能包含 = 或控制字符。") }
                arguments += ["--form-string", field.name + "=" + field.value]
            }
        }
        if request.method == .get && request.bodyMode != .none { warnings.append("此 GET 请求包含请求体；请确认目标服务支持这种用法。") }
        let sensitiveHeaders = ["authorization", "proxy-authorization", "cookie", "x-api-key", "api-key"]
        let sensitive = request.auth != .none || !headerNames.isDisjoint(with: sensitiveHeaders)
        guard arguments.reduce(0, { $0 + $1.utf8.count }) <= 262_144 else { throw ToolError.invalid("命令参数合计不能超过 256 KB。") }
        return CurlCommandPlan(url: url, arguments: arguments, warnings: warnings, containsCredentials: sensitive)
    }

    private static func activeFields(_ fields: [CurlField], label: String) throws -> [CurlField] {
        try fields.filter { $0.enabled && (!$0.name.isEmpty || !$0.value.isEmpty) }.map { field in
            var value = field
            value.name = value.name.trimmingCharacters(in: .whitespaces)
            guard !value.name.isEmpty, !value.name.contains("\0"), !value.value.contains("\0"), value.name.utf8.count <= 1024, value.value.utf8.count <= 8192 else {
                throw ToolError.invalid("\(label)的名称不能为空，名称最多 1 KB、值最多 8 KB，且不能包含 NUL。")
            }
            return value
        }
    }
    private static func hasControl(_ value: String) -> Bool { value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } }
    private static func percentEncode(_ value: String) -> String {
        value.utf8.map { byte in
            if (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || [45, 46, 95, 126].contains(byte) {
                return String(UnicodeScalar(byte))
            }
            return String(format: "%%%02X", byte)
        }.joined()
    }
    /// Single quotes prevent expansion. ANSI-C quoting preserves line breaks in
    /// one physical line on the macOS zsh/bash shells, including trailing LF.
    static func shellQuote(_ value: String) -> String {
        if value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) {
            var escaped = ""
            for scalar in value.unicodeScalars {
                let character = String(scalar)
                switch character {
                case "\\": escaped += "\\\\"
                case "'": escaped += "\\'"
                case "\n": escaped += "\\n"
                case "\r": escaped += "\\r"
                case "\t": escaped += "\\t"
                default:
                    if scalar.value < 32 || scalar.value == 127 { escaped += String(format: "\\%03o", scalar.value) }
                    else { escaped += character }
                }
            }
            return "$'" + escaped + "'"
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
