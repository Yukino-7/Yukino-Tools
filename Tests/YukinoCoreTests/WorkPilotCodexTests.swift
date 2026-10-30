import Foundation
import Testing
@testable import YukinoCore

struct WorkPilotCodexTests {
    private var calendar: Calendar {
        var result = Calendar(identifier: .gregorian); result.timeZone = TimeZone(identifier: "Asia/Shanghai")!; return result
    }
    private var day: Date { CodexDates.parse("2026-10-25T04:00:00Z")! }
    private func line(_ type: String, _ payload: [String: Any], at timestamp: String = "2026-10-25T01:00:00Z") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["timestamp": timestamp, "type": type, "payload": payload], options: [.sortedKeys])
    }
    private func message(_ role: String, _ text: String, phase: String? = nil, at timestamp: String = "2026-10-25T01:00:00Z") throws -> Data {
        var payload: [String: Any] = ["type": "message", "role": role, "content": [["type": role == "assistant" ? "output_text" : "input_text", "text": text]]]
        if let phase { payload["phase"] = phase }
        return try line("response_item", payload, at: timestamp)
    }
    private func metadata(_ id: String = "session-one", source: Any = "vscode", fork: Bool = false) throws -> Data {
        var payload: [String: Any] = ["id": id, "cwd": "/work/demo", "source": source, "timestamp": "2026-10-24T16:00:00Z"]
        if fork { payload["forked_from_id"] = "parent" }
        return try line("session_meta", payload, at: "2026-10-24T16:00:00Z")
    }
    private func transcript(_ id: String = "session-one", turn: String = "turn-one") throws -> [Data] {
        [try metadata(id), try line("turn_context", ["turn_id": turn, "cwd": "/work/demo"]),
         try message("user", "排查示例接口超时"), try message("assistant", "调整连接池参数，当前待压测验证。", phase: "final_answer")]
    }

    @Test func parserKeepsOnlyHumanRequestsAndFinalAnswersWithinTheLocalDay() throws {
        var parser = WorkCodexParser(day: day, calendar: calendar)
        parser.ingest(try metadata())
        parser.ingest(try line("turn_context", ["turn_id": "turn-one", "cwd": "/work/demo/module"]))
        parser.ingest(try message("system", "SECRET_SYSTEM"))
        parser.ingest(try message("developer", "SECRET_INSTRUCTIONS"))
        parser.ingest(try message("user", "<environment_context>EXCLUDE</environment_context>"))
        parser.ingest(try message("user", "# AGENTS.md instructions EXCLUDE"))
        parser.ingest(try message("user", "排查示例接口超时", at: "2026-10-24T15:50:00Z"))
        parser.ingest(try message("assistant", "中间更新 EXCLUDE", phase: "commentary"))
        parser.ingest(try line("response_item", ["type": "reasoning", "summary": "EXCLUDE_REASONING"]))
        parser.ingest(try line("response_item", ["type": "function_call_output", "output": "EXCLUDE_TOOL_SECRET"]))
        parser.ingest(try message("assistant", "调整连接池参数，当前待压测验证。", phase: "final_answer", at: "2026-10-24T16:10:00Z"))
        parser.ingest(try line("event_msg", ["type": "task_complete", "turn_id": "turn-one", "last_agent_message": "重复答复"], at: "2026-10-24T16:10:01Z"))
        let activity = try #require(parser.activities.first)
        #expect(parser.activities.count == 1)
        #expect(activity.request == "排查示例接口超时")
        #expect(activity.response == "调整连接池参数，当前待压测验证。")
        #expect(activity.directory == "/work/demo/module")
        #expect(!activity.recordText.contains("EXCLUDE"))
        #expect(activity.recordText.contains("尚未经独立验证"))
        parser.ingest(try line("turn_context", ["turn_id": "future"]))
        parser.ingest(try message("user", "未来记录", at: "2026-10-25T16:00:00Z"))
        parser.ingest(try message("assistant", "明天完成的答复", phase: "final_answer", at: "2026-10-25T16:01:00Z"))
        #expect(parser.activities.count == 1)
    }

    @Test func parserWaitsForCompletionAndIgnoresReportGenerationAndSubagents() throws {
        var parser = WorkCodexParser(day: day, calendar: calendar)
        parser.ingest(try metadata())
        parser.ingest(try line("event_msg", ["type": "task_started", "turn_id": "legacy"]))
        parser.ingest(try line("event_msg", ["type": "user_message", "message": "整理接口清单"]))
        parser.ingest(try message("assistant", "旧格式中间更新"))
        #expect(parser.activities.isEmpty)
        parser.ingest(try line("event_msg", ["type": "task_complete", "turn_id": "legacy", "last_agent_message": "旧格式的最终回答"]))
        #expect(parser.activities.count == 1)
        #expect(parser.activities[0].response == "旧格式的最终回答")
        parser.ingest(try line("turn_context", ["turn_id": "report"]))
        parser.ingest(try message("user", "请使用 $daily-report-optimizer（日报优化）skill，根据以下 WorkPilot 素材生成 2026-10-25 的中文工作日报。"))
        parser.ingest(try message("assistant", "日报输出不循环采集", phase: "final_answer"))
        #expect(parser.activities.count == 1)
        var child = WorkCodexParser(day: day, calendar: calendar)
        child.ingest(try metadata("child", source: ["subagent": ["thread_spawn": "parent"]]))
        for row in try transcript().dropFirst() { child.ingest(row) }
        #expect(child.activities.isEmpty)
    }

    @Test func forkHistoryIsExcludedAndLongSummariesAreExplicitlyTruncated() throws {
        var parser = WorkCodexParser(day: day, calendar: calendar)
        parser.ingest(try line("session_meta", ["id": "fork", "cwd": "/work/demo", "source": "vscode", "forked_from_id": "parent", "timestamp": "2026-10-25T00:00:00Z"]))
        parser.ingest(try line("turn_context", ["turn_id": "inherited"]))
        parser.ingest(try message("user", "父会话内容", at: "2026-10-24T17:00:00Z"))
        parser.ingest(try message("assistant", "父会话答复", phase: "final_answer", at: "2026-10-24T17:30:00Z"))
        parser.ingest(try line("turn_context", ["turn_id": "own"]))
        parser.ingest(try message("user", String(repeating: "事项", count: 2_000)))
        parser.ingest(try message("assistant", String(repeating: "结果", count: 5_000), phase: "final_answer"))
        let activity = try #require(parser.activities.first)
        #expect(parser.activities.count == 1)
        #expect(activity.truncated)
        #expect(activity.request.count <= 2_000 && activity.response.count <= 8_000)
        #expect(activity.recordText.contains("长内容已截取"))
    }

    @Test func discoveryMatchesPathBoundariesAndKeepsIgnoreAndAcceptanceStable() throws {
        var parser = WorkCodexParser(day: day, calendar: calendar)
        for row in try transcript() { parser.ingest(row) }
        let activity = try #require(parser.activities.first)
        var data = WorkPilotData()
        var parent = WorkProject(name: "示例项目"); parent.repositoryPath = "/work"
        var child = WorkProject(name: "子项目"); child.repositoryPath = "/work/demo"
        data.projects = [parent, child]
        #expect(data.matchingCodexProject(directory: "/work/demo/module") == child.id)
        #expect(data.matchingCodexProject(directory: "/workspace/demo") == nil)
        data.projects[1].archived = true
        #expect(data.matchingCodexProject(directory: "/work/demo/module") == parent.id)
        data.projects[1].archived = false
        let added = data.discoverCodexActivities([activity, activity])
        #expect(added == 1 && data.codexDiscoveries.count == 1)
        let id = data.codexDiscoveries[0].id
        #expect(data.codexDiscoveries[0].projectID == child.id)
        data.setCodexDiscovery(id, state: .ignored)
        data.discoverCodexActivities([activity])
        #expect(data.codexDiscoveries[0].state == .ignored && data.logs.isEmpty)
        data.setCodexDiscovery(id, state: .pending)
        data.setCodexDiscovery(id, state: .accepted)
        data.setCodexDiscovery(id, state: .accepted)
        #expect(data.logs.count == 1)
        #expect(data.logs[0].codexActivityID == activity.id)
        #expect(data.logs[0].followUpStatus == nil)
        #expect(data.progress(for: child.id) == 0)
        #expect(data.report(for: day, calendar: calendar).contains("调整连接池参数，当前待压测验证。"))
        #expect(!data.report(for: day.addingTimeInterval(86400), calendar: calendar).contains(activity.response))
        let restored = try WorkPilotStore.decode(JSONEncoder().encode(data))
        #expect(restored.codexDiscoveries[0].state == .accepted)
        #expect(restored.logs[0].codexActivityID == activity.id)
        var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(WorkPilotData())) as? [String: Any])
        legacy.removeValue(forKey: "codexDiscoveries")
        #expect(try WorkPilotStore.decode(JSONSerialization.data(withJSONObject: legacy)).codexDiscoveries.isEmpty)
    }

    @Test func scannerHandlesPartialLinesArchiveCopiesPaginationAndTruncation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("sessions/2026/10/25")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("page.jsonl")
        var rows = try transcript()
        let final = rows.removeLast()
        var bytes = Data(); for row in rows { bytes.append(row); bytes.append(10) }
        bytes.append(final.prefix(final.count / 2)); try bytes.write(to: file)
        let scanner = WorkPilotCodexService()
        #expect(try await scanner.scan(root: root, day: day, calendar: calendar).activities.isEmpty)
        let handle = try FileHandle(forWritingTo: file); try handle.seekToEnd()
        try handle.write(contentsOf: final.suffix(final.count - final.count / 2) + Data([10])); try handle.close()
        let first = try await scanner.scan(root: root, day: day, calendar: calendar)
        #expect(first.activities.count == 1)
        let archived = root.appendingPathComponent("archived_sessions")
        try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: file, to: archived.appendingPathComponent("copy.jsonl"))
        var more = Data(); for row in try transcript(turn: "turn-two") { more.append(row); more.append(10) }
        try more.write(to: directory.appendingPathComponent("page-two.jsonl"))
        #expect(try await scanner.scan(root: root, day: day, calendar: calendar).activities.count == 2)
        try Data().write(to: file)
        #expect(try await scanner.scan(root: root, day: day, calendar: calendar).activities.count == 2)
        try FileManager.default.removeItem(at: archived.appendingPathComponent("copy.jsonl"))
        let last = try await scanner.scan(root: root, day: day, calendar: calendar)
        #expect(last.activities.map(\.turnID) == ["turn-two"])
        #expect(last.unreadableFiles == 0 && !last.limited)
    }
}
