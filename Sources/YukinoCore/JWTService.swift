import Foundation
import CoreFoundation

public struct JWTDateClaim: Identifiable, Sendable {
    public let name: String
    public let date: Date
    public var id: String { name }
}

public enum JWTTimeState: Equatable, Sendable {
    case expired, notYetValid, withinTimeWindow, noExpiration, invalidTimeClaims
    public var title: String {
        switch self {
        case .expired: return "已过期（仅检查时间声明）"
        case .notYetValid: return "尚未生效（仅检查时间声明）"
        case .withinTimeWindow: return "处于声明的时间范围内"
        case .noExpiration: return "未声明过期时间"
        case .invalidTimeClaims: return "时间声明格式无效，无法判断有效期"
        }
    }
}

public struct JWTDocument: Sendable {
    public let header: String
    public let payload: String
    public let algorithm: String
    public let signatureBytes: Int
    public let dateClaims: [JWTDateClaim]
    public let warnings: [String]
    public let invalidDateClaims: Bool
    public var expiration: Date? { dateClaims.first { $0.name == "exp" }?.date }
    public var notBefore: Date? { dateClaims.first { $0.name == "nbf" }?.date }
    public func timeState(at now: Date) -> JWTTimeState {
        if invalidDateClaims { return .invalidTimeClaims }
        if let expiration, now >= expiration { return .expired }
        if let notBefore, now < notBefore { return .notYetValid }
        return expiration == nil ? .noExpiration : .withinTimeWindow
    }
}

public enum JWTService {
    public static func decode(_ input: String) throws -> JWTDocument {
        guard input.utf8.count <= 262_144 else { throw ToolError.invalid("JWT 输入不能超过 256 KB。") }
        var token = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if token.lowercased().hasPrefix("bearer ") { token = String(token.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines) }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        if parts.count == 5 { throw ToolError.invalid("这是五段式 JWE 加密令牌；当前查看器支持三段式 JWT（JWS），无法解密 JWE。") }
        guard parts.count == 3 else { throw ToolError.invalid("JWT 需要三段：Header.Payload.Signature。") }
        func object(_ part: String, name: String) throws -> (String, [String: Any]) {
            let data = try base64URL(part, allowEmpty: false)
            guard let text = String(data: data, encoding: .utf8),
                  let value = try? JSONSerialization.jsonObject(with: data), let dictionary = value as? [String: Any] else {
                throw ToolError.invalid("\(name) 必须是 UTF-8 JSON 对象。")
            }
            return (try JSONService.transform(text), dictionary)
        }
        let (headerText, header) = try object(parts[0], name: "Header")
        let (payloadText, payload) = try object(parts[1], name: "Payload")
        guard let algorithm = header["alg"] as? String, !algorithm.isEmpty else { throw ToolError.invalid("Header 缺少字符串类型的 alg。") }
        if let b64 = header["b64"] as? NSNumber, CFGetTypeID(b64) == CFBooleanGetTypeID(), !b64.boolValue {
            throw ToolError.invalid("不支持 b64=false 的未编码 JWS Payload。")
        }
        let signature = try base64URL(parts[2], allowEmpty: algorithm == "none")
        guard algorithm != "none" || signature.isEmpty else { throw ToolError.invalid("alg=none 的令牌应使用空签名。") }
        var warnings = [String]()
        if algorithm == "none" { warnings.append("alg=none：此令牌未签名，内容可被任意修改。") }
        if header["crit"] != nil { warnings.append("Header 包含 crit 扩展；本查看器未验证这些扩展。") }
        var claims = [JWTDateClaim]()
        var invalidDates = false
        for name in ["iat", "nbf", "exp"] {
            guard let raw = payload[name] else { continue }
            guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, (-62135596800...253402300799).contains(number.doubleValue) else {
                warnings.append("\(name) 必须是有效的 NumericDate 数值（Unix 秒，非毫秒）；无法检查该时间声明。")
                invalidDates = true
                continue
            }
            claims.append(.init(name: name, date: Date(timeIntervalSince1970: number.doubleValue)))
        }
        if let exp = claims.first(where: { $0.name == "exp" })?.date,
           let nbf = claims.first(where: { $0.name == "nbf" })?.date, nbf >= exp {
            warnings.append("nbf 不早于 exp，令牌没有可用的生效时间范围。")
        }
        return JWTDocument(header: headerText, payload: payloadText, algorithm: algorithm, signatureBytes: signature.count, dateClaims: claims, warnings: warnings, invalidDateClaims: invalidDates)
    }

    private static func base64URL(_ text: String, allowEmpty: Bool) throws -> Data {
        guard (allowEmpty || !text.isEmpty), text.utf8.allSatisfy({
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }), text.count % 4 != 1 else { throw ToolError.invalid("JWT 段包含无效 Base64URL 字符或长度；应使用不带 = 填充的 Base64URL。") }
        let padded = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + String(repeating: "=", count: (4 - text.count % 4) % 4)
        guard let data = Data(base64Encoded: padded) else { throw ToolError.invalid("无法解码 Base64URL。") }
        return data
    }

    public static var example: String {
        let header = Data(#"{"alg":"none","typ":"JWT"}"#.utf8)
        let payload = Data(#"{"sub":"example-user","name":"Yukino","iat":1792540800,"nbf":1792540800,"exp":1792627200}"#.utf8)
        func encode(_ data: Data) -> String { data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
        return encode(header) + "." + encode(payload) + "."
    }
}
