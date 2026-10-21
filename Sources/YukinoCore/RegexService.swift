import Foundation

public struct RegexOptions: Sendable, Equatable {
    public var ignoreCase: Bool
    public var multiline: Bool
    public var dotMatchesNewline: Bool
    public init(ignoreCase: Bool = false, multiline: Bool = false, dotMatchesNewline: Bool = false) {
        self.ignoreCase = ignoreCase; self.multiline = multiline; self.dotMatchesNewline = dotMatchesNewline
    }
}
public struct RegexCapture: Identifiable, Sendable {
    public let index: Int
    public let range: NSRange?
    public let text: String?
    public var id: Int { index }
}
public struct RegexMatch: Identifiable, Sendable {
    public let index: Int
    public let range: NSRange
    public let text: String
    public let captures: [RegexCapture]
    public var id: Int { index }
}
public struct RegexResult: Sendable {
    public let matches: [RegexMatch]
    public let replacement: String?
    public let truncated: Bool
}

public enum RegexService {
    /// ICU engine, UTF-16 ranges. Progress callbacks bound pathological backtracking.
    public static func evaluate(pattern: String, text: String, replacement: String = "", options: RegexOptions = .init(), timeout: TimeInterval = 0.5, maximumMatches: Int = 1000) throws -> RegexResult {
        guard !pattern.isEmpty else { throw ToolError.invalid("请输入正则表达式。") }
        guard pattern.utf16.count <= 4096, text.utf16.count <= 100_000, replacement.utf16.count <= 4096 else {
            throw ToolError.invalid("表达式和替换模板最多 4,096 个 UTF-16 单元，测试文本最多 100,000 个 UTF-16 单元。")
        }
        guard timeout.isFinite, timeout > 0, (1...1000).contains(maximumMatches) else { throw ToolError.invalid("无效的匹配限制。") }
        var flags: NSRegularExpression.Options = []
        if options.ignoreCase { flags.insert(.caseInsensitive) }
        if options.multiline { flags.insert(.anchorsMatchLines) }
        if options.dotMatchesNewline { flags.insert(.dotMatchesLineSeparators) }
        let regex: NSRegularExpression
        do { regex = try NSRegularExpression(pattern: pattern, options: flags) }
        catch { throw ToolError.invalid("正则表达式无效：\(error.localizedDescription)") }
        guard regex.numberOfCaptureGroups <= 100 else { throw ToolError.invalid("最多支持 100 个捕获组，请使用 (?:...) 减少不必要的捕获。") }
        let source = text as NSString
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var results = [NSTextCheckingResult]()
        var timedOut = false, cancelled = false, internalError = false, truncated = false
        regex.enumerateMatches(in: text, options: [.reportProgress], range: NSRange(location: 0, length: source.length)) { result, flags, stop in
            cancelled = Task.isCancelled
            timedOut = ProcessInfo.processInfo.systemUptime >= deadline
            internalError = flags.contains(.internalError)
            if cancelled || timedOut || internalError { stop.pointee = true; return }
            if let result {
                if results.count == maximumMatches { truncated = true; stop.pointee = true }
                else { results.append(result) }
            }
        }
        if cancelled || Task.isCancelled { throw CancellationError() }
        if timedOut || ProcessInfo.processInfo.systemUptime >= deadline { throw ToolError.invalid("匹配超过时间限制，请简化表达式或缩短文本。") }
        if internalError { throw ToolError.invalid("正则引擎无法完成匹配，请简化表达式。") }
        let matches = results.enumerated().map { index, match in
            RegexMatch(index: index + 1, range: match.range, text: source.substring(with: match.range), captures: (1..<match.numberOfRanges).map { group in
                let range = match.range(at: group)
                return RegexCapture(index: group, range: range.location == NSNotFound ? nil : range, text: range.location == NSNotFound ? nil : source.substring(with: range))
            })
        }
        // Never present a partially replaced document as a complete result.
        var output: String? = nil
        if !truncated {
            var value = "", cursor = 0
            for match in results {
                if Task.isCancelled { throw CancellationError() }
                value += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
                value += regex.replacementString(for: match, in: text, offset: 0, template: replacement)
                guard value.utf16.count <= 1_000_000 else { throw ToolError.invalid("替换结果超过 1,000,000 个 UTF-16 单元，请缩短替换模板。") }
                cursor = NSMaxRange(match.range)
            }
            value += source.substring(from: cursor)
            guard value.utf16.count <= 1_000_000 else { throw ToolError.invalid("替换结果过大。") }
            output = value
        }
        return RegexResult(matches: matches, replacement: output, truncated: truncated)
    }
}
