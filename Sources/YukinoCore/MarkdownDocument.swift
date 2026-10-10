import Foundation

public struct MarkdownBlock: Identifiable, Equatable, Sendable {
    public let id: Int
    public let kind: Kind
    public enum Kind: Equatable, Sendable {
        case heading(Int, String), paragraph(String), quote(String)
        case list(String, String, Int), code(String, String), rule
        case table([String], [[String]], [Alignment])
    }
    public enum Alignment: Equatable, Sendable { case left, center, right }
}

/// Block layout for report Markdown. Inline styling is handled by Foundation in the reader.
public enum MarkdownDocument {
    public static let openRouterRankingHeaders = ["排名", "模型", "提供方", "Tokens/wk", "上次用量", "变化", "排名变化", "上下文", "详情"]

    /// Hide obsolete reference sections and combine legacy TOP 5 tables without rewriting stored Markdown.
    public static func openRouterReadingBlocks(_ source: String) -> [MarkdownBlock] {
        var visible: [MarkdownBlock.Kind] = []
        var hiddenSection: Int?
        for block in parse(source) {
            if let level = hiddenSection {
                switch block.kind {
                case .rule: hiddenSection = nil
                case .heading(let nextLevel, _) where nextLevel <= level: hiddenSection = nil
                default: continue
                }
            }
            if case .heading(let level, let title) = block.kind, level == 2, title.contains("全平台非免费榜首") {
                hiddenSection = level
                continue
            }
            visible.append(block.kind)
        }
        let blocks = visible.enumerated().map { MarkdownBlock(id: $0.offset, kind: $0.element) }
        guard let rankingIndex = blocks.firstIndex(where: {
            if case .table(let headers, _, _) = $0.kind { return headers == ["排名", "模型", "提供方", "Tokens/wk", "上下文", "详情"] }
            return false
        }), case .table(_, let rankingRows, _) = blocks[rankingIndex].kind,
        let comparisonIndex = blocks.indices.first(where: { index in
            guard index > rankingIndex + 2, case .table(let headers, _, _) = blocks[index].kind else { return false }
            return headers == ["排名今日", "模型", "提供方", "Tokens/wk 上次 → 今日", "变化", "排名变化"]
        }), case .table(_, let comparisonRows, _) = blocks[comparisonIndex].kind,
        case .heading(3, "对比上次榜单") = blocks[comparisonIndex - 2].kind,
        case .quote = blocks[comparisonIndex - 1].kind else { return blocks }

        let rankings = rankingRows.filter { $0.count == 6 && Int($0[0]) != nil }
        let comparisons = comparisonRows.filter { $0.count == 6 && Int($0[0]) != nil }
        guard rankings.map({ $0[0] }) == ["1", "2", "3", "4", "5"], comparisons.count == 5 else { return blocks }
        var merged: [[String]] = []
        for row in rankings {
            let matches = comparisons.filter { Array($0.prefix(3)) == Array(row.prefix(3)) }
            guard matches.count == 1 else { return blocks }
            let comparison = matches[0]
            let values = comparison[3].components(separatedBy: "→").map { $0.trimmingCharacters(in: .whitespaces) }
            guard values.count == 2 else { return blocks }
            merged.append(Array(row.prefix(4)) + [values[0], comparison[4], comparison[5], row[4], row[5]])
        }
        var result: [MarkdownBlock.Kind] = []
        for index in blocks.indices {
            if index == rankingIndex {
                result.append(blocks[comparisonIndex - 1].kind)
                result.append(.table(openRouterRankingHeaders, merged, [.right, .left, .left, .right, .right, .right, .center, .right, .left]))
            } else if !(comparisonIndex - 2...comparisonIndex).contains(index) { result.append(blocks[index].kind) }
        }
        return result.enumerated().map { MarkdownBlock(id: $0.offset, kind: $0.element) }
    }

    public static func parse(_ source: String) -> [MarkdownBlock] {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []; var index = 0
        func append(_ kind: MarkdownBlock.Kind) { blocks.append(MarkdownBlock(id: blocks.count, kind: kind)) }
        while index < lines.count {
            let line = lines[index]; let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { index += 1; continue }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let fence = String(trimmed.prefix(3)); let language = String(trimmed.dropFirst(3))
                index += 1; var code: [String] = []
                while index < lines.count && !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) { code.append(lines[index]); index += 1 }
                append(.code(language, code.joined(separator: "\n"))); index = min(lines.count, index + 1); continue
            }
            if let heading = heading(trimmed) { append(.heading(heading.0, heading.1)); index += 1; continue }
            if ["---", "***", "___"].contains(trimmed) { append(.rule); index += 1; continue }
            if trimmed.hasPrefix(">") {
                var quote: [String] = []
                while index < lines.count && lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    quote.append(String(lines[index].trimmingCharacters(in: .whitespaces).dropFirst()).trimmingCharacters(in: .whitespaces)); index += 1
                }
                append(.quote(quote.joined(separator: "\n"))); continue
            }
            if trimmed.hasPrefix("|"), index + 1 < lines.count, let alignment = tableAlignment(lines[index + 1]) {
                let headers = cells(line); var rows: [[String]] = []; index += 2
                while index < lines.count && lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("|") { rows.append(cells(lines[index])); index += 1 }
                append(.table(headers, rows, alignment)); continue
            }
            if let item = listItem(line) { append(.list(item.0, item.1, item.2)); index += 1; continue }
            var paragraph = [trimmed]; index += 1
            while index < lines.count {
                let next = lines[index].trimmingCharacters(in: .whitespaces)
                if next.isEmpty || heading(next) != nil || next.hasPrefix(">") || next.hasPrefix("|") || next.hasPrefix("```") || next.hasPrefix("~~~") || ["---", "***", "___"].contains(next) || listItem(lines[index]) != nil { break }
                paragraph.append(next); index += 1
            }
            append(.paragraph(paragraph.joined(separator: "\n")))
        }
        return blocks
    }

    public static func cells(_ line: String) -> [String] {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("|") { text.removeFirst() }
        if text.hasSuffix("|") { text.removeLast() }
        var result: [String] = []; var cell = ""; var escaped = false; var code = false
        for character in text {
            if escaped { cell.append(character); escaped = false; continue }
            if character == "\\" { cell.append(character); escaped = true; continue }
            if character == "`" { code.toggle() }
            if character == "|" && !code { result.append(cell.trimmingCharacters(in: .whitespaces)); cell = "" }
            else { cell.append(character) }
        }
        result.append(cell.trimmingCharacters(in: .whitespaces)); return result
    }

    private static func tableAlignment(_ line: String) -> [MarkdownBlock.Alignment]? {
        let fields = cells(line)
        guard !fields.isEmpty, fields.allSatisfy({ $0.range(of: #"^:?-{3,}:?$"#, options: .regularExpression) != nil }) else { return nil }
        return fields.map { $0.hasSuffix(":") ? ($0.hasPrefix(":") ? .center : .right) : .left }
    }
    private static func heading(_ text: String) -> (Int, String)? {
        let count = text.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(count), text.dropFirst(count).first == " " else { return nil }
        return (count, String(text.dropFirst(count)).trimmingCharacters(in: .whitespaces))
    }
    private static func listItem(_ text: String) -> (String, String, Int)? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let indent = min(6, (text.count - trimmed.count) / 2)
        for prefix in ["- ", "* ", "+ "] where trimmed.hasPrefix(prefix) { return ("•", String(trimmed.dropFirst(2)), indent) }
        if let range = trimmed.range(of: #"^\d+[.)] "#, options: .regularExpression) { return (String(trimmed[range]).trimmingCharacters(in: .whitespaces), String(trimmed[range.upperBound...]), indent) }
        return nil
    }
}
