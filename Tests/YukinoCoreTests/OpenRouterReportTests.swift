import Foundation
import Testing
@testable import YukinoCore

private let reportDate = Date(timeIntervalSince1970: 1_790_750_400) // 2026-09-30, Asia/Shanghai
private func modelData(_ rows: [[String: Any]]) throws -> Data { try JSONSerialization.data(withJSONObject: ["data": rows]) }
private func free(_ id: String = "vendor/a:free", name: String = "Vendor: Model A (free)", context: Any? = nil) -> [String: Any] {
    var row: [String: Any] = ["id": id, "name": name, "pricing": ["prompt": "0", "completion": 0], "supported_parameters": ["tools", "structured_outputs"]]
    if let context { row["context_length"] = context }
    return row
}
private func weeklyHTML() -> String {
    "<nav>Free models\n1 Bogus 99T 1M</nav><h2>Free models</h2><table>" + (1...5).map {
        "<tr><td>\($0)</td><td>Model \(Character(UnicodeScalar(64 + $0)!)) (free)</td><td>\(6 - $0).5B</td><td>1M</td></tr>"
    }.joined() + "</table><h2>Video models</h2><tr>1 Bogus 99T 1M</tr>"
}
private func sampleReport(day: Date = reportDate) throws -> DailyReport {
    try OpenRouterReportService.report(modelData: modelData([free()]), html: weeklyHTML(), previous: nil, now: day)
}
private func tempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("yukino-report-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func dailyModelsDistinguishZeroUnknownAndPaidWithoutMissingContextCrash() throws {
    var numeric = free("vendor/numeric"); numeric["pricing"] = ["prompt": 0, "completion": 0]
    var missing = free("vendor/missing"); missing.removeValue(forKey: "pricing")
    var boolean = free("vendor/bool"); boolean["pricing"] = ["prompt": false, "completion": false]
    var negative = free("vendor/negative"); negative["pricing"] = ["prompt": "-1", "completion": "0"]
    var paid = free("vendor/paid"); paid["pricing"] = ["prompt": "0", "completion": "0.01"]
    let result = try OpenRouterReportService.parseModels(modelData([numeric, missing, boolean, negative, paid, free(context: 262144)]))
    #expect(result.total == 6 && result.models.count == 2 && result.paid == 1 && result.unknown == 3)
    #expect(result.models[0].context == 262144)
    #expect(result.models[1].context == nil)
    #expect(result.models.allSatisfy { $0.tools && $0.structured })
}

@Test func dailyModelsRejectDuplicateIDsInvalidShapeAndAcceptGenuineEmptyList() throws {
    #expect(throws: ToolError.self) { try OpenRouterReportService.parseModels(modelData([free(), free()])) }
    #expect(throws: ToolError.self) { try OpenRouterReportService.parseModels(modelData([free("../bad")])) }
    #expect(throws: ToolError.self) { try OpenRouterReportService.parseModels(Data(#"{"error":"offline"}"#.utf8)) }
    let empty = try OpenRouterReportService.parseModels(modelData([]))
    #expect(empty.total == 0 && empty.models.isEmpty)
    #expect(try OpenRouterReportService.parseModels(modelData([free("~vendor/latest")])).models.count == 1)
}

@Test func dailyWeeklyParserIsolatesFreeSectionAndRequiresCompleteOrderedRanking() {
    let html = weeklyHTML()
    let rows = OpenRouterReportService.parseTop5(html)
    #expect(rows.map(\.rank) == [1, 2, 3, 4, 5])
    #expect(rows.first?.name == "Model A")
    #expect(rows.first?.tokens == 5_500_000_000)
    #expect(OpenRouterReportService.parseTop5(html.replacingOccurrences(of: "<td>3</td>", with: "<td>7</td>")).isEmpty)
    #expect(OpenRouterReportService.parseTop5("<h2>Paid models</h2>" + html.replacingOccurrences(of: "Free models", with: "Other models")).isEmpty)
}

@Test func dailyAmbiguousModelNamesDoNotInventIDsAndEscapingPreservesTables() throws {
    let report = try OpenRouterReportService.report(modelData: modelData([free(), free("other/a", name: "Other: Model A (free)"), free("vendor/markup", name: "pipe|name **bold**\n<script>")]), html: weeklyHTML(), previous: nil, now: reportDate)
    #expect(report.snapshot.top5.first?.modelID == nil)
    #expect(report.snapshot.top5.first?.provider == "—")
    let tables = MarkdownDocument.parse(report.markdown).compactMap { block -> [[String]]? in
        if case .table(let headers, let rows, _) = block.kind, headers.contains("模型 ID") { return rows }; return nil
    }
    #expect(tables.first?.allSatisfy { $0.count == 9 } == true)
    #expect(report.markdown.contains(#"pipe\|name \*\*bold\*\* \<script\>"#))
}

@Test func dailyFailureDoesNotMasqueradeAsAllModelsRemoved() throws {
    let previous = try sampleReport(day: reportDate.addingTimeInterval(-172800)).snapshot
    let partial = try OpenRouterReportService.report(modelData: nil, html: weeklyHTML(), previous: previous, now: reportDate)
    #expect(partial.snapshot.models == nil && !partial.snapshot.warnings.isEmpty)
    #expect(partial.markdown.contains("免费: 数据不可用"))
    #expect(!partial.markdown.contains("移出免费列表"))
    #expect(throws: ToolError.self) { try OpenRouterReportService.report(modelData: nil, html: "layout changed", previous: previous, now: reportDate) }
    let noRank = try OpenRouterReportService.report(modelData: modelData([]), html: "layout changed", previous: previous, now: reportDate)
    #expect(noRank.snapshot.models == [] && noRank.snapshot.top5.isEmpty)
    #expect(noRank.markdown.contains("移出免费列表"))
}

@Test func dailyComparisonUsesActualBaselineAndLegacyMarkdownRetainsIDs() throws {
    let old = try sampleReport(day: reportDate.addingTimeInterval(-172800))
    let parsed = OpenRouterReportService.legacySnapshot(markdown: old.markdown, dateKey: old.snapshot.dateKey)
    #expect(parsed.models?.map(\.id) == ["vendor/a:free"])
    #expect(parsed.top5.count == 5 && parsed.top5[0].modelID == "vendor/a:free")
    let next = try OpenRouterReportService.report(modelData: modelData([free(), free("vendor/new", name: "New")]), html: weeklyHTML(), previous: parsed, now: reportDate)
    #expect(next.markdown.contains("上次（2026-09-28）"))
    #expect(next.markdown.contains("`vendor/new`"))
    #expect(!next.markdown.contains("昨日"))
}

@Test func dailyMarkdownHandlesTablesCodeEscapesAndReportBlockTypes() {
    let md = "# Title\r\n\r\n> quote\r\n> **bold**\r\n\r\n| A | B |\r\n| :--- | ---: |\r\n| `a|b` | x\\|y |\r\n\r\n- ~~gone~~\r\n\r\n```sh\r\n# literal\r\n```\r\n\r\n---"
    let blocks = MarkdownDocument.parse(md)
    #expect(blocks.count == 6)
    #expect(blocks[2].kind == .table(["A", "B"], [["`a|b`", #"x\|y"#]], [.left, .right]))
    #expect(blocks[4].kind == .code("sh", "# literal"))
}

@Test func dailyCombinedRankingKeepsComparisonAndRoundTripsSnapshot() throws {
    let previous = try sampleReport(day: reportDate.addingTimeInterval(-86400)).snapshot
    var today = try sampleReport().snapshot
    let first = today.top5[0]
    today.top5[0] = WeeklyModel(rank: 1, name: first.name, provider: first.provider, modelID: first.modelID, tokens: first.tokens * 2, context: first.context)
    today.top5[4] = WeeklyModel(rank: 5, name: "New model", provider: "new", modelID: "new/model", tokens: 1e9, context: "32K")
    let markdown = OpenRouterReportService.render(today, previous: previous)
    let rankings = MarkdownDocument.parse(markdown).compactMap { block -> [[String]]? in
        if case .table(let headers, let rows, _) = block.kind, headers == MarkdownDocument.openRouterRankingHeaders { return rows }
        return nil
    }
    let rows = try #require(rankings.first)
    #expect(rankings.count == 1 && rows.count == 5)
    #expect(rows[0][3] == "**11.0B**" && rows[0][4] == "5.5B" && rows[0][5] == "+100.0%")
    #expect(rows[4][4] == "—" && rows[4][5] == "🆕 新上榜")
    #expect(markdown.contains("2026-09-29.md") && markdown.contains("掉出今日榜单"))
    #expect(!markdown.contains("### 对比上次榜单") && !markdown.contains("█"))
    #expect(!markdown.contains("全平台非免费榜首") && !markdown.contains("未列出排名或分数"))
    let parsed = OpenRouterReportService.legacySnapshot(markdown: markdown, dateKey: today.dateKey)
    #expect(parsed.top5 == today.top5)

    let noBaseline = OpenRouterReportService.render(today, previous: nil)
    #expect(noBaseline.contains("无可用周榜基线"))
    #expect(!noBaseline.contains("新上榜"))
}

private func legacyRankingMarkdown() -> String {
    let ranking = (1...5).map { "| \($0) | **Model \($0)** | `vendor` | **5.5B** | 1M | [→](https://openrouter.ai/vendor/\($0)) |\n| | | | `████` | | |" }.joined(separator: "\n")
    // Deliberately reorder comparisons: joining must follow model identity, not row position.
    let comparison = (1...5).reversed().map { "| \($0) | **Model \($0)** | `vendor` | 5.0B → 5.5B | +10.0% | 持平 |" }.joined(separator: "\n")
    return """
    ## 一、免费模型本周调用量榜 TOP 5
    > 来源: OpenRouter

    | 排名 | 模型 | 提供方 | Tokens/wk | 上下文 | 详情 |
    | ---: | --- | --- | ---: | ---: | --- |
    \(ranking)

    - 榜单合计: **27.5B tokens/周**

    ### 对比上次榜单
    > 基线: `2026-09-29.md`；周 Token 为页面展示值。

    | 排名今日 | 模型 | 提供方 | Tokens/wk 上次 → 今日 | 变化 | 排名变化 |
    | ---: | --- | --- | ---: | ---: | :---: |
    \(comparison)

    **上次 TOP5 中掉出今日榜单的模型**：
    - ~~Old model~~

    ## 二、今日免费模型全量
    """
}

@Test func dailyLegacyReadingCombinesByIdentityAndPreservesBaselineAndDroppedModels() throws {
    let markdown = legacyRankingMarkdown()
    let original = MarkdownDocument.parse(markdown)
    let blocks = MarkdownDocument.openRouterReadingBlocks(markdown)
    let tables = blocks.compactMap { block -> [[String]]? in
        if case .table(let headers, let rows, _) = block.kind, headers == MarkdownDocument.openRouterRankingHeaders { return rows }
        return nil
    }
    let rows = try #require(tables.first)
    #expect(tables.count == 1 && rows.count == 5)
    #expect(rows[0] == ["1", "**Model 1**", "`vendor`", "**5.5B**", "5.0B", "+10.0%", "持平", "1M", "[→](https://openrouter.ai/vendor/1)"])
    #expect(blocks.contains { if case .quote(let text) = $0.kind { return text.contains("2026-09-29.md") }; return false })
    #expect(blocks.contains { if case .list(_, let text, _) = $0.kind { return text.contains("Old model") }; return false })
    #expect(blocks.contains { $0.kind == .heading(2, "二、今日免费模型全量") })
    #expect(blocks.map(\.id) == Array(blocks.indices))
    #expect(MarkdownDocument.parse(markdown) == original)
}

@Test func dailyLegacyReadingKeepsMismatchedTablesRatherThanHidingData() {
    let markdown = legacyRankingMarkdown().replacingOccurrences(of: "| 3 | **Model 3** | `vendor` | 5.0B", with: "| 3 | **Different** | `vendor` | 5.0B")
    #expect(MarkdownDocument.openRouterReadingBlocks(markdown) == MarkdownDocument.parse(markdown))
    #expect(MarkdownDocument.openRouterReadingBlocks("# Ordinary Markdown") == MarkdownDocument.parse("# Ordinary Markdown"))
    let oldReference = "# 日报\n\n## 二、今日免费模型全量\n\n保留模型列表\n\n## 三、参考：全平台非免费榜首（对比用）\n\n> 当前没有接入可验证的榜首数据，未列出排名或分数。\n\n### 旧占位\n\n删除此段\n\n---\n\n_报告来源_"
    let expected = "# 日报\n\n## 二、今日免费模型全量\n\n保留模型列表\n\n---\n\n_报告来源_"
    #expect(MarkdownDocument.openRouterReadingBlocks(oldReference) == MarkdownDocument.parse(expected))
    #expect(MarkdownDocument.openRouterReadingBlocks(oldReference.replacingOccurrences(of: "---", with: "## 四、保留章节")) == MarkdownDocument.parse(expected.replacingOccurrences(of: "---", with: "## 四、保留章节")))
}

@Test func dailyDateKeysRejectInvalidCalendarDatesAndPaths() {
    #expect(OpenRouterReportService.dateKey(reportDate) == "2026-09-30")
    #expect(OpenRouterReportService.validDateKey("2024-02-29"))
    for key in ["2026-02-29", "2026-02-30", "2026-9-3", "../2026-09-30", "2026-09-30.md"] { #expect(!OpenRouterReportService.validDateKey(key)) }
}

@Test func dailyStoreImportPreservesSourceSkipsDatesAndRejectsInvalidFiles() async throws {
    let root = try tempDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source"); try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    let report = try sampleReport(); let md = source.appendingPathComponent("2026-09-30.md")
    try Data(report.markdown.utf8).write(to: md)
    try Data("not a daily report".utf8).write(to: source.appendingPathComponent("2026-09-29.md"))
    try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("2026-09-28.md"), withDestinationURL: md)
    try Data(report.markdown.utf8).write(to: source.appendingPathComponent("2026-02-30.md"))
    let store = DailyReportStore(directory: root.appendingPathComponent("destination"))
    let result = try await store.importDirectory(source)
    #expect(result.imported == 1 && result.errors.count == 2)
    #expect(try String(contentsOf: md, encoding: .utf8) == report.markdown)
    #expect(try await store.markdown(for: "2026-09-30") == report.markdown)
    #expect(try await store.entries().map(\.dateKey) == ["2026-09-30"])
    #expect(try await store.importDirectory(source).skipped == 1)
}

@Test func dailyStoreReplacementRetainsRevisionAndEditedMarkdownInvalidatesSnapshot() async throws {
    let root = try tempDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let store = DailyReportStore(directory: root); let old = try sampleReport()
    _ = try await store.save(old)
    do { _ = try await store.save(old); Issue.record("Existing date should require replacement") } catch {}
    let newer = try OpenRouterReportService.report(modelData: modelData([free("vendor/new")]), html: weeklyHTML(), previous: nil, now: reportDate)
    _ = try await store.save(newer, replacing: true)
    let revisions = root.appendingPathComponent("Revisions/2026-09-30")
    let saved = try FileManager.default.contentsOfDirectory(at: revisions, includingPropertiesForKeys: nil)
    #expect(saved.count == 1)
    #expect(try String(contentsOf: saved[0].appendingPathComponent("2026-09-30.md"), encoding: .utf8) == old.markdown)
    #expect(try await store.previous(before: "2026-10-01")?.models?.map(\.id) == ["vendor/new"])
    try Data(old.markdown.utf8).write(to: root.appendingPathComponent("2026-09-30.md"))
    #expect(try await store.previous(before: "2026-10-01")?.models?.map(\.id) == ["vendor/a:free"])
}

@Test func dailyStoreUsesNearestUsableHistoryAndRejectsOversizedReports() async throws {
    let root = try tempDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let store = DailyReportStore(directory: root)
    _ = try await store.save(sampleReport(day: reportDate.addingTimeInterval(-172800)))
    try Data([0xff, 0xfe]).write(to: root.appendingPathComponent("2026-09-29.md"))
    #expect(try await store.previous(before: "2026-09-30")?.dateKey == "2026-09-28")
    try Data(repeating: 0x61, count: 2_000_001).write(to: root.appendingPathComponent("2026-09-30.md"))
    do { _ = try await store.markdown(for: "2026-09-30"); Issue.record("Oversized report should fail") } catch {}
}

private final class PartialReportProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let isModels = request.url == OpenRouterReportService.modelsURL
        let response = HTTPURLResponse(url: request.url!, statusCode: isModels ? 200 : 503, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((isModels ? #"{"data":[]}"# : "unavailable").utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
private final class TimedOutReportProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.timedOut)) }
    override func stopLoading() {}
}

@Test func dailyNetworkPartialHTTPFailureProducesExplicitDegradedReport() async throws {
    let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [PartialReportProtocol.self]
    let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
    let report = try await OpenRouterReportService.generate(previous: nil, now: reportDate, session: session)
    #expect(report.snapshot.models == [])
    #expect(report.snapshot.warnings.contains { $0.contains("HTTP 503") })
    #expect(report.markdown.contains("数据源降级"))
    #expect(report.markdown.contains("免费: 0"))
}

@Test func dailyNetworkTimeoutAndCancellationNeverProduceEmptyReports() async {
    let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [TimedOutReportProtocol.self]
    let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
    do { _ = try await OpenRouterReportService.generate(previous: nil, session: session); Issue.record("Failed sources should not generate reports") }
    catch { #expect(error is ToolError) }
    let task = Task { try await OpenRouterReportService.generate(previous: nil, session: session) }
    task.cancel()
    do { _ = try await task.value; Issue.record("Cancelled fetch must not return a report") }
    catch { #expect(error is CancellationError) }
}
