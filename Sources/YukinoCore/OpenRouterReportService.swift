import Foundation
import CoreFoundation

public struct FreeModel: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let context: Int?
    public let input: [String]
    public let output: [String]
    public let tools: Bool
    public let structured: Bool
}
public struct WeeklyModel: Codable, Equatable, Sendable {
    public let rank: Int
    public let name: String
    public var provider: String
    public var modelID: String?
    public let tokens: Double
    public let context: String
}
public struct DailySnapshot: Codable, Equatable, Sendable {
    public let dateKey: String
    public let generatedAt: Date
    public var models: [FreeModel]?
    public var totalModels: Int?
    public var paidModels: Int?
    public var unknownPrices: Int?
    public var top5: [WeeklyModel]
    public var warnings: [String]
}
public struct DailyReport: Sendable {
    public let snapshot: DailySnapshot
    public let markdown: String
}

public enum OpenRouterReportService {
    public static let modelsURL = URL(string: "https://openrouter.ai/api/v1/models")!
    public static let discoverURL = URL(string: "https://openrouter.ai/discover?lane=free")!
    public static var timeZone: TimeZone { TimeZone(identifier: "Asia/Shanghai")! }

    public static func dateKey(_ date: Date = Date()) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = timeZone; formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
    public static func validDateKey(_ key: String) -> Bool {
        guard key.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return false }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = timeZone; formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
        return formatter.date(from: key).map { formatter.string(from: $0) == key } ?? false
    }

    public static func generate(previous: DailySnapshot?, now: Date = Date(), session: URLSession = .shared) async throws -> DailyReport {
        async let models = fetch(modelsURL, limit: 5_000_000, session: session)
        async let discover = fetch(discoverURL, limit: 8_000_000, session: session)
        let results = await (models, discover)
        try Task.checkCancellation()
        let modelData = try? results.0.get(); let htmlData = try? results.1.get()
        var errors: [String] = []
        if case .failure(let error) = results.0 { errors.append("模型接口：\(error.localizedDescription)") }
        if case .failure(let error) = results.1 { errors.append("周榜页面：\(error.localizedDescription)") }
        return try report(modelData: modelData, html: htmlData.flatMap { String(data: $0, encoding: .utf8) }, previous: previous, now: now, errors: errors)
    }

    private static func fetch(_ url: URL, limit: Int, session: URLSession) async -> Result<Data, Error> {
        do {
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
            request.setValue("Yukino-Tools/0.3", forHTTPHeaderField: "User-Agent")
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw ToolError.invalid("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)") }
            guard response.expectedContentLength <= limit else { throw ToolError.invalid("响应超出大小限制") }
            var data = Data()
            for try await byte in bytes {
                if data.count >= limit { throw ToolError.invalid("响应超出大小限制") }
                data.append(byte)
            }
            return .success(data)
        } catch { return .failure(error) }
    }

    public static func parseModels(_ data: Data) throws -> (models: [FreeModel], total: Int, paid: Int, unknown: Int) {
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any], let values = payload["data"] as? [[String: Any]] else { throw ToolError.invalid("模型接口结构不符合预期") }
        var free: [FreeModel] = []; var paid = 0; var unknown = 0; var seen: Set<String> = []
        for model in values {
            guard let id = model["id"] as? String, id.range(of: #"^~?[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.:/-]*$"#, options: .regularExpression) != nil, seen.insert(id).inserted else { throw ToolError.invalid("模型 ID 缺失、重复或无效") }
            let pricing = model["pricing"] as? [String: Any] ?? [:]
            guard let prompt = price(pricing["prompt"]), let completion = price(pricing["completion"]) else { unknown += 1; continue }
            guard prompt == 0 && completion == 0 else { paid += 1; continue }
            let architecture = model["architecture"] as? [String: Any] ?? [:]
            let provider = model["top_provider"] as? [String: Any] ?? [:]
            let context = (model["context_length"] as? Int) ?? (provider["context_length"] as? Int)
            let parameters = model["supported_parameters"] as? [String] ?? []
            free.append(FreeModel(id: id, name: model["name"] as? String ?? id, context: context.flatMap { $0 > 0 ? $0 : nil }, input: architecture["input_modalities"] as? [String] ?? [], output: architecture["output_modalities"] as? [String] ?? [], tools: parameters.contains("tools"), structured: parameters.contains("structured_outputs")))
        }
        return (free.sorted { ($0.context ?? 0) == ($1.context ?? 0) ? $0.id < $1.id : ($0.context ?? 0) > ($1.context ?? 0) }, values.count, paid, unknown)
    }
    private static func price(_ value: Any?) -> Double? {
        if let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() { return nil }
        guard let value, let number = Double(String(describing: value)), number.isFinite, number >= 0 else { return nil }
        return number
    }

    public static func parseTop5(_ html: String) -> [WeeklyModel] {
        var cleaned = replacing(html, #"(?is)<(script|style|aside|nav|header|footer)\b[^>]*>.*?</\1>"#, " ")
        guard let start = cleaned.range(of: "free models", options: .caseInsensitive) else { return [] }
        cleaned = String(cleaned[start.lowerBound...])
        let ends = ["video models", "image models", "explore every modality"].compactMap { cleaned.range(of: $0, options: .caseInsensitive)?.lowerBound }
        if let end = ends.min() { cleaned = String(cleaned[..<end]) }
        cleaned = replacing(cleaned, #"(?i)<br\s*/?>|<tr\b[^>]*>|</tr>"#, "\n")
        cleaned = decodeEntities(replacing(cleaned, #"<[^>]+>"#, " "))
        cleaned = replacing(cleaned, #"[ \t]+"#, " ")
        let pattern = #"^\s*(\d+)\s+(.+?)\s*(?:\(free\))?\s+([\d.]+)\s*([TBMK])\s+(\d+(?:\.\d+)?)\s*([KM]?)\s*$"#
        var rows: [WeeklyModel] = []; var seen: Set<String> = []
        for line in cleaned.components(separatedBy: "\n") {
            guard let fields = captures(line, pattern), let rank = Int(fields[0]), rank == rows.count + 1,
                  let amount = Double(fields[2]), amount.isFinite, amount > 0, seen.insert(canonical(fields[1])).inserted else { continue }
            let units: [String: Double] = ["T": 1e12, "B": 1e9, "M": 1e6, "K": 1e3]
            let multiplier = units[fields[3].uppercased()] ?? 1
            guard (amount * multiplier).isFinite else { continue }
            rows.append(WeeklyModel(rank: rank, name: fields[1].trimmingCharacters(in: .whitespaces), provider: "—", tokens: amount * multiplier, context: fields[4] + fields[5]))
            if rows.count == 5 { break }
        }
        return rows.count == 5 ? rows : []
    }

    public static func report(modelData: Data?, html: String?, previous: DailySnapshot?, now: Date, errors: [String] = []) throws -> DailyReport {
        var snapshot = DailySnapshot(dateKey: dateKey(now), generatedAt: now, models: nil, totalModels: nil, paidModels: nil, unknownPrices: nil, top5: [], warnings: errors)
        if let modelData {
            do {
                let parsed = try parseModels(modelData); snapshot.models = parsed.models; snapshot.totalModels = parsed.total; snapshot.paidModels = parsed.paid; snapshot.unknownPrices = parsed.unknown
                if parsed.unknown > 0 { snapshot.warnings.append("\(parsed.unknown) 个模型价格未知，未计入免费或付费列表") }
            } catch { snapshot.warnings.append("模型列表解析失败：\(error.localizedDescription)") }
        } else if !errors.contains(where: { $0.hasPrefix("模型接口") }) { snapshot.warnings.append("模型接口数据不可用") }
        if let html {
            snapshot.top5 = parseTop5(html)
            if snapshot.top5.isEmpty { snapshot.warnings.append("周榜页面结构变化或数据不足五条，跳过 TOP 5") }
        } else if !errors.contains(where: { $0.hasPrefix("周榜页面") }) { snapshot.warnings.append("周榜页面数据不可用") }
        guard snapshot.models != nil || !snapshot.top5.isEmpty else { throw ToolError.invalid("日报数据源不可用，未保存空报告。\n" + snapshot.warnings.joined(separator: "\n")) }
        let grouped = Dictionary(grouping: snapshot.models ?? [], by: { canonical($0.name) })
        for index in snapshot.top5.indices {
            if let matches = grouped[canonical(snapshot.top5[index].name)], matches.count == 1 {
                snapshot.top5[index].modelID = matches[0].id; snapshot.top5[index].provider = String(matches[0].id.split(separator: "/")[0])
            }
        }
        return DailyReport(snapshot: snapshot, markdown: render(snapshot, previous: previous))
    }

    public static func legacySnapshot(markdown: String, dateKey: String) -> DailySnapshot {
        var models: [FreeModel]?; var rows: [WeeklyModel] = []
        for block in MarkdownDocument.parse(markdown) {
            if case .table(let headers, let values, _) = block.kind {
                if headers.contains("模型 ID") {
                    models = values.compactMap { cells in
                        guard cells.count >= 3, Int(cells[0]) != nil else { return nil }
                        let id = cells[1].trimmingCharacters(in: CharacterSet(charactersIn: "` "))
                        return FreeModel(id: id, name: cells[2], context: cells.count > 3 ? Int(cells[3].replacingOccurrences(of: ",", with: "")) : nil, input: [], output: [], tools: false, structured: false)
                    }
                } else if headers.contains("Tokens/wk") && headers.contains("排名") {
                    rows = values.compactMap { cells in
                        guard cells.count >= 6, let rank = Int(cells[0]), (1...5).contains(rank), let tokens = tokenValue(cells[3]) else { return nil }
                        let name = cells[1].trimmingCharacters(in: CharacterSet(charactersIn: "* "))
                        let provider = cells[2].trimmingCharacters(in: CharacterSet(charactersIn: "` "))
                        guard let detailIndex = headers.firstIndex(of: "详情"), let contextIndex = headers.firstIndex(of: "上下文"), cells.count > max(detailIndex, contextIndex) else { return nil }
                        let id = captures(cells[detailIndex], #"https://openrouter\.ai/([^\s)]+)"#)?.first
                        return WeeklyModel(rank: rank, name: name, provider: provider, modelID: id, tokens: tokens, context: cells[contextIndex])
                    }.sorted { $0.rank < $1.rank }
                }
            }
        }
        if rows.map(\.rank) != [1, 2, 3, 4, 5] { rows = [] }
        return DailySnapshot(dateKey: dateKey, generatedAt: .distantPast, models: models, top5: rows, warnings: [])
    }

    public static func render(_ today: DailySnapshot, previous: DailySnapshot?) -> String {
        let previous = previous.flatMap { $0.dateKey < today.dateKey ? $0 : nil }
        let stamp = DateFormatter(); stamp.locale = Locale(identifier: "en_US_POSIX"); stamp.timeZone = timeZone; stamp.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let count = today.models.map { String($0.count) } ?? "数据不可用"
        var out = ["# OpenRouter 免费模型日报 — \(today.dateKey)", "", "> 生成时间: \(stamp.string(from: today.generatedAt)) (Asia/Shanghai)  ", "> 数据源: openrouter.ai/api/v1/models + openrouter.ai/discover?lane=free  ", "> 总模型数: \(today.totalModels.map(String.init) ?? "数据不可用") / 免费: \(count) / 付费: \(today.paidModels.map(String.init) ?? "数据不可用") / 价格未知: \(today.unknownPrices.map(String.init) ?? "—")", "", "> 免费口径：prompt 与 completion 的 Token 单价均为 0；周榜数值来自页面展示值。", ""]
        if !today.warnings.isEmpty { out += [today.models != nil && !today.top5.isEmpty ? "> ⚠️ 数据提示" : "> ⚠️ 数据源降级"] + today.warnings.map { "> " + escape($0) } + [""] }
        out += ["## 零、相比上次报告变化", ""]
        if let before = previous, let old = before.models, let current = today.models {
            let oldIDs = Set(old.map(\.id)); let newIDs = Set(current.map(\.id))
            out += ["- 上次（\(before.dateKey)）免费模型数: **\(old.count)**", "- 今日（\(today.dateKey)）免费模型数: **\(current.count)**", "- 数量变化: **\(current.count - old.count)**", ""]
            for (title, ids) in [("🆕 新增免费模型", newIDs.subtracting(oldIDs)), ("❌ 移出免费列表", oldIDs.subtracting(newIDs))] where !ids.isEmpty {
                out += ["**\(title)（\(ids.count)）**"] + ids.sorted().map { "- `\(escape($0))`" } + [""]
            }
        } else { out += ["> \(today.models == nil ? "今日模型数据不可用，跳过新增/移出对比。" : "无可用历史基线，跳过变化对比。")", ""] }
        out += ["## 一、免费模型本周调用量榜 TOP 5", "", "> 来源: [OpenRouter Free models](https://openrouter.ai/discover?lane=free)", ""]
        if today.top5.isEmpty { out += ["> 数据源不可用，跳过本周调用量榜。", ""] }
        else {
            let baseline = previous.flatMap { $0.top5.count == 5 ? $0 : nil }
            out += [baseline.map { "> 基线: `\($0.dateKey).md`；周 Token 为页面展示值，变化百分比由展示值计算。" } ?? "> 无可用周榜基线，暂不计算用量与排名变化。", ""]
            out += ["| " + MarkdownDocument.openRouterRankingHeaders.joined(separator: " | ") + " |", "| ---: | --- | --- | ---: | ---: | ---: | :---: | ---: | --- |"]
            for row in today.top5 {
                let detail = row.modelID.map { "[→](https://openrouter.ai/\($0))" } ?? "—"
                let matches = baseline?.top5.filter { row.modelID != nil && $0.modelID != nil ? row.modelID == $0.modelID : canonical(row.name) == canonical($0.name) } ?? []
                let before = matches.count == 1 ? matches[0] : nil
                let delta = before.flatMap { $0.tokens > 0 ? (row.tokens - $0.tokens) / $0.tokens * 100 : nil }
                let change = delta.map { abs($0) < 0.05 ? "➖ 持平" : String(format: "%+.1f%%", $0) } ?? (baseline == nil ? "—" : before == nil ? "🆕 新上榜" : "—")
                let rank = before.map { $0.rank == row.rank ? "持平" : String(format: "%+d", $0.rank - row.rank) } ?? "—"
                out.append("| \(row.rank) | **\(escape(row.name))** | `\(escape(row.provider))` | **\(formatTokens(row.tokens))** | \(before.map { formatTokens($0.tokens) } ?? "—") | \(change) | \(rank) | \(escape(row.context)) | \(detail) |")
            }
            let sum = today.top5.reduce(0) { $0 + $1.tokens }
            out += ["", "- 榜单合计: **\(formatTokens(sum)) tokens/周**", "- 头部集中度: TOP1 占 \(String(format: "%.1f", today.top5[0].tokens / sum * 100))%", ""]
            if let previous = baseline {
                let gone = previous.top5.filter { old in !today.top5.contains { new in old.modelID != nil && new.modelID != nil ? old.modelID == new.modelID : canonical(old.name) == canonical(new.name) } }
                if !gone.isEmpty { out += ["", "**上次 TOP5 中掉出今日榜单的模型**："] + gone.map { "- ~~**\(escape($0.name))**~~（\(formatTokens($0.tokens))），原第 \($0.rank) 名" } }
                out.append("")
            }
        }
        out += ["## 二、今日免费模型全量", "", "按上下文窗口从大到小排序。🏆 表示周榜排名；🆕 表示相对历史基线新增。", ""]
        if let models = today.models {
            out += ["| # | 模型 ID | 名称 | 上下文 | 输入 | 输出 | 工具 | 结构化 | 标记 |", "| --- | --- | --- | ---: | --- | --- | :---: | :---: | --- |"]
            let oldIDs = previous?.models.map { Set($0.map(\.id)) }
            for (index, model) in models.enumerated() {
                var flags: [String] = []
                if let rank = today.top5.first(where: { $0.modelID == model.id })?.rank { flags.append("🏆 TOP\(rank)") }
                if let oldIDs, !oldIDs.contains(model.id) { flags.append("🆕新增") }
                out.append("| \(index + 1) | `\(escape(model.id))` | \(escape(model.name)) | \(model.context.map { $0.formatted(.number.locale(Locale(identifier: "en_US"))) } ?? "—") | \(escape(model.input.isEmpty ? "—" : model.input.joined(separator: ","))) | \(escape(model.output.isEmpty ? "—" : model.output.joined(separator: ","))) | \(model.tools ? "✅" : "—") | \(model.structured ? "✅" : "—") | \(flags.joined(separator: " ")) |")
            }
            if models.isEmpty { out += ["", "> 当前接口中没有符合上述免费口径的模型。"] }
        } else { out.append("> 未能获取模型列表；不将失败显示为零个模型。") }
        out += ["", "---", "", "_本报告由 Yukino Tools 获取公开数据并生成。_", ""]
        return out.joined(separator: "\n")
    }

    static func canonical(_ name: String) -> String {
        var name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let colon = name.firstIndex(of: ":") { name = String(name[name.index(after: colon)...]).trimmingCharacters(in: .whitespaces) }
        for suffix in [" (free)", " (preview)"] where name.lowercased().hasSuffix(suffix) { name = String(name.dropLast(suffix.count)) }
        return name.lowercased()
    }
    static func escape(_ value: String) -> String {
        var text = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
        for character in ["|", "`", "*", "_", "[", "]", "<", ">"] { text = text.replacingOccurrences(of: character, with: "\\" + character) }
        return text
    }
    static func replacing(_ source: String, _ pattern: String, _ template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return source }
        return regex.stringByReplacingMatches(in: source, range: NSRange(source.startIndex..., in: source), withTemplate: template)
    }
    static func captures(_ text: String, _ pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive), let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).map { Range(match.range(at: $0), in: text).map { String(text[$0]) } ?? "" }
    }
    static func tokenValue(_ value: String) -> Double? {
        guard let parts = captures(value, #"([\d.]+)\s*([TBMK])"#), let amount = Double(parts[0]), amount.isFinite, amount >= 0 else { return nil }
        return amount * (["T": 1e12, "B": 1e9, "M": 1e6, "K": 1e3][parts[1].uppercased()] ?? 1)
    }
    static func formatTokens(_ value: Double) -> String {
        for (scale, suffix) in [(1e12, "T"), (1e9, "B"), (1e6, "M"), (1e3, "K")] where value >= scale { return String(format: "%.1f%@", value / scale, suffix) }
        return String(format: "%.0f", value)
    }
    private static func decodeEntities(_ text: String) -> String {
        var text = text
        for (entity, value) in [("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'")] { text = text.replacingOccurrences(of: entity, with: value) }
        return text
    }
}
