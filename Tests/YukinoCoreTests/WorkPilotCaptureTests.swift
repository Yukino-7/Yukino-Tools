import Foundation
import Testing
@testable import YukinoCore

struct WorkPilotCaptureTests {
    private var calendar: Calendar {
        var result = Calendar(identifier: .gregorian); result.timeZone = TimeZone(secondsFromGMT: 0)!; return result
    }
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    @Test func oneLineCaptureNeedsOnlyContentAndPreservesBothKinds() throws {
        var data = WorkPilotData()
        let now = date("2026-10-24T09:00:00Z")
        let blank = data.capture(" \n ", followUp: false, at: now)
        let note = data.capture("  调整接口参数，待联调 \n", followUp: false, at: now)
        let issue = data.capture("等待对方确认权限", followUp: true, at: now.addingTimeInterval(30))
        #expect(!blank)
        #expect(note)
        #expect(issue)
        #expect(data.logs[0].action == "调整接口参数，待联调")
        #expect(data.logs[0].projectID == nil)
        #expect(data.logs[1].followUpStatus == .todo)
        #expect(data.issues.isEmpty)
        let restored = try WorkPilotStore.decode(JSONEncoder().encode(data))
        let records = restored.records(on: now, calendar: calendar)
        #expect(records.count == 2)
        #expect(records.first == .log(data.logs[1]))
        #expect(records.last == .log(data.logs[0]))
    }

    @Test func unifiedTimelineCarriesPendingItemsWithoutShowingFutureOrOldResolvedItems() {
        var data = WorkPilotData()
        let today = date("2026-10-24T09:00:00Z")
        data.issues.append(WorkIssue(title: "昨日未解决", createdAt: today.addingTimeInterval(-86400)))
        data.issues.append(WorkIssue(title: "昨日已解决", createdAt: today.addingTimeInterval(-86400)))
        data.issues[1].resolvedAt = today.addingTimeInterval(-80000)
        data.issues.append(WorkIssue(title: "明天新问题", createdAt: today.addingTimeInterval(86400)))
        data.capture("昨日普通记录", followUp: false, at: today.addingTimeInterval(-86400))
        #expect(data.records(on: today, calendar: calendar) == [.issue(data.issues[0])])
        data.issues[0].resolvedAt = today
        #expect(data.records(on: today, calendar: calendar) == [.issue(data.issues[0])])
        #expect(!data.records(on: today.addingTimeInterval(86400), calendar: calendar).contains(.issue(data.issues[0])))
    }

    @Test func oldTasksAndCompletionLogsAppearOnceWithoutMigratingOrLosingDetails() throws {
        let today = date("2026-10-24T10:00:00Z")
        var data = WorkPilotData()
        let project = WorkProject(name: "示例项目")
        data.projects = [project]
        let task = WorkTask(title: "旧任务", projectID: project.id, day: today)
        data.tasks = [task]
        data.setStatus(taskID: task.id, status: .done, at: today)
        data.logs[0].result = "已有验证结论"
        data.logs.append(WorkLog(action: "独立记录", projectID: project.id, date: today))
        data.issues.append(WorkIssue(title: "旧问题", projectID: project.id, solution: "已有方案", createdAt: today))
        let restored = try WorkPilotStore.decode(JSONEncoder().encode(data))
        #expect(restored.tasks == data.tasks && restored.logs == data.logs && restored.issues == data.issues)
        #expect(restored.allRecords.count == 3)
        #expect(restored.records(on: today, calendar: calendar).count == 3)
        #expect(restored.progress(for: project.id) == 0.5)
        #expect(restored.allRecords.filter { $0.title == "旧任务" }.count == 1)
        data.setStatus(taskID: task.id, status: .todo, at: today)
        #expect(data.tasks[0].detail.contains("已有验证结论"))
        #expect(data.logs.count == 1)
        try data.validate()
    }

    @Test func oneItemCanBeFollowedBlockedCompletedAndReopenedWithoutDuplication() throws {
        var data = WorkPilotData()
        let project = WorkProject(name: "示例项目")
        data.projects = [project]
        let yesterday = date("2026-10-23T10:00:00Z"), today = date("2026-10-24T10:00:00Z")
        data.capture("接口联调", followUp: true, projectID: project.id, at: yesterday)
        let id = data.logs[0].id
        #expect(data.records(on: today, calendar: calendar).count == 1)
        data.setRecordStatus(.log(data.logs[0]), status: .blocked, at: today)
        #expect(data.allRecords[0].status == .blocked)
        #expect(data.report(for: today, calendar: calendar).contains("[阻塞] 示例项目 · 接口联调"))
        data.setRecordStatus(.log(data.logs[0]), status: .done, at: today)
        data.setRecordStatus(.log(data.logs[0]), status: .done, at: today.addingTimeInterval(60))
        #expect(data.logs.count == 1 && data.logs[0].id == id)
        #expect(data.logs[0].completedAt == today)
        #expect(data.progress(for: project.id) == 1)
        #expect(data.report(for: today, calendar: calendar).components(separatedBy: "接口联调").count == 2)
        #expect(data.records(on: today.addingTimeInterval(86400), calendar: calendar).isEmpty)
        data.setRecordStatus(.log(data.logs[0]), status: .todo, at: today)
        #expect(data.logs[0].completedAt == nil)
        #expect(data.records(on: today.addingTimeInterval(86400), calendar: calendar).count == 1)
        data.setRecordStatus(.log(data.logs[0]), status: nil, at: today)
        #expect(data.allRecords[0].status == nil)
        #expect(data.progress(for: project.id) == 0)
        try data.validate()
    }

    @Test func codexHandoffInvokesInstalledSkillAndKeepsMaterialLiteralInTheURL() throws {
        let material = "接口 + 回归 & 待确认 #1\n$HOME `echo unsafe` 中文 😀"
        let prompt = WorkPilotCodexHandoff.prompt(material: material, day: date("2026-10-24T09:00:00Z"), calendar: calendar)
        #expect(prompt == "请使用 $daily-report-optimizer（日报优化）skill，根据以下 WorkPilot 素材生成 2026-10-24 的中文工作日报。\n\n\(material)")
        let url = try WorkPilotCodexHandoff.url(prompt: prompt)
        let parsed = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(url.scheme == "codex")
        #expect(url.host == "threads" && url.path == "/new")
        #expect(parsed.queryItems?.first { $0.name == "mode" }?.value == "codex")
        #expect(parsed.queryItems?.first { $0.name == "prompt" }?.value == prompt)
        #expect(!url.absoluteString.contains("+"))
        #expect(url.absoluteString.contains("%2B"))
    }
}
