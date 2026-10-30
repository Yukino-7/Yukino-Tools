import Foundation
import Testing
@testable import YukinoCore

struct WorkPilotTests {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(secondsFromGMT: 0)!; return value
    }
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    @Test func completionTransitionsKeepOneDerivedLogAndProjectProgress() throws {
        var data = WorkPilotData()
        let project = WorkProject(name: "示例项目"), other = WorkProject(name: "其他项目")
        data.projects = [project, other]
        let task = WorkTask(title: "修复登录", projectID: project.id)
        data.tasks = [task, WorkTask(title: "回归测试", projectID: project.id), WorkTask(title: "其他", projectID: other.id)]
        let completed = date("2026-10-24T10:00:00Z")
        data.setStatus(taskID: task.id, status: .done, at: completed)
        data.setStatus(taskID: task.id, status: .done, at: completed.addingTimeInterval(90))
        #expect(data.logs.count == 1)
        #expect(data.logs[0].taskID == task.id)
        #expect(data.tasks[0].completedAt == completed)
        #expect(data.progress(for: project.id) == 0.5)
        #expect(data.progress(for: other.id) == 0)
        data.logs.append(WorkLog(action: "手工补充", projectID: project.id))
        data.setStatus(taskID: task.id, status: .doing)
        #expect(data.tasks[0].completedAt == nil)
        #expect(data.logs.map(\.action) == ["手工补充"])
        #expect(data.progress(for: project.id) == 0)
        try data.validate()
    }

    @Test func reportUsesActualLogDateSeparatesBlockersAndKeepsFollowUp() {
        var data = WorkPilotData()
        let project = WorkProject(name: "示例项目"); data.projects = [project]
        let today = date("2026-10-24T10:00:00Z")
        data.tasks = [WorkTask(title: "昨日计划今日完成", projectID: project.id, day: today.addingTimeInterval(-86400)),
                      WorkTask(title: "等待接口", projectID: project.id, detail: "依赖测试环境", day: today),
                      WorkTask(title: "明日回归", day: today.addingTimeInterval(86400))]
        data.setStatus(taskID: data.tasks[0].id, status: .done, at: today)
        data.setStatus(taskID: data.tasks[1].id, status: .blocked, at: today)
        data.logs.append(WorkLog(action: "已上线", result: "灰度验证通过", projectID: project.id, date: today))
        data.logs.append(WorkLog(action: "未来日志不可出现", date: today.addingTimeInterval(86400)))
        data.issues = [WorkIssue(title: "偶发超时", projectID: project.id, solution: "调整连接池", followUp: "观察错误率", due: today.addingTimeInterval(86400), createdAt: today)]
        let report = data.report(for: today, calendar: calendar)
        #expect(report.contains("灰度验证通过"))
        #expect(report.contains("[阻塞] 示例项目 · 等待接口；依赖测试环境"))
        #expect(report.contains("方案：调整连接池；跟进：观察错误率（2026-10-25）"))
        #expect(report.contains("2026-10-25 · 未归属项目 · 明日回归"))
        #expect(!report.contains("未来日志不可出现"))
        #expect(report.components(separatedBy: "昨日计划今日完成").count == 2)
    }

    @Test func timeIsClippedAtMidnightAndAdjacentTicksMergeWithoutLosingPauses() {
        var data = WorkPilotData()
        let project = WorkProject(name: "示例项目"); data.projects = [project]
        let start = date("2026-10-24T23:59:30Z"), midnight = date("2026-10-25T00:00:00Z")
        data.recordTime(projectID: project.id, start: start, end: midnight, automatic: true)
        data.recordTime(projectID: project.id, start: midnight, end: midnight.addingTimeInterval(30), automatic: true)
        data.recordTime(projectID: project.id, start: midnight.addingTimeInterval(90), end: midnight.addingTimeInterval(105), automatic: true)
        data.recordTime(projectID: project.id, start: midnight.addingTimeInterval(105), end: midnight.addingTimeInterval(120), automatic: false)
        #expect(data.seconds(on: start, calendar: calendar) == 30)
        #expect(data.seconds(on: midnight, calendar: calendar) == 60)
        let count = data.sessions.count
        data.recordTime(projectID: project.id, start: midnight, end: start, automatic: false)
        #expect(data.sessions.count == count)
        var adjacent = WorkPilotData(); adjacent.projects = [project]
        adjacent.recordTime(projectID: project.id, start: midnight, end: midnight.addingTimeInterval(15), automatic: false)
        adjacent.recordTime(projectID: project.id, start: midnight.addingTimeInterval(15), end: midnight.addingTimeInterval(30), automatic: false)
        #expect(adjacent.sessions.count == 1)
        #expect(adjacent.seconds(on: midnight, calendar: calendar) == 30)
    }

    @Test func applicationRulesRejectAmbiguityAndArchivedProjects() {
        var data = WorkPilotData()
        let one = WorkProject(name: "一"), two = WorkProject(name: "二"); data.projects = [one, two]
        data.rules = [WorkAppRule(projectID: one.id, bundleID: "test.editor", appName: "Editor")]
        #expect(data.detectedProject(bundleID: "test.editor") == one.id)
        data.rules.append(WorkAppRule(projectID: two.id, bundleID: "test.editor", appName: "Editor"))
        #expect(data.detectedProject(bundleID: "test.editor") == nil)
        data.projects[1].archived = true
        #expect(data.detectedProject(bundleID: "test.editor") == one.id)
        #expect(data.detectedProject(bundleID: "unknown") == nil)
    }

    @Test func storageRetainsBackupAndRefusesToReplaceCorruptOrFutureData() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkPilotStore(url: directory.appendingPathComponent("workspace.json"))
        #expect(try store.load() == WorkPilotData())
        var data = WorkPilotData(); data.projects = [WorkProject(name: "项目")]
        try store.save(data)
        let first = data
        data.logs = [WorkLog(action: "记录", projectID: data.projects[0].id)]
        try store.save(data)
        #expect(try store.load() == data)
        #expect(try WorkPilotStore.decode(Data(contentsOf: store.backupURL)) == first)
        let corrupt = Data("broken".utf8)
        try corrupt.write(to: store.url)
        #expect(throws: (any Error).self) { try store.load() }
        #expect(throws: (any Error).self) { try store.save(data) }
        #expect(try Data(contentsOf: store.url) == corrupt)
        data.version = 99
        #expect(throws: (any Error).self) { try WorkPilotStore.decode(JSONEncoder().encode(data)) }
        data.version = 1; data.tasks = [WorkTask(title: "孤立任务", projectID: UUID())]
        #expect(throws: (any Error).self) { try data.validate() }
    }

    @Test func gitScanFindsOwnCommitsAcrossBranchesAndImportDeduplicates() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WorkPilot repo ; \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func git(_ arguments: [String], author: String = "owner@example.invalid", timestamp: String = "2026-10-24T10:00:00Z") throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git"); process.arguments = ["-C", directory.path] + arguments
            var env = ProcessInfo.processInfo.environment
            env["GIT_CONFIG_GLOBAL"] = "/dev/null"; env["GIT_CONFIG_NOSYSTEM"] = "1"
            env["GIT_AUTHOR_NAME"] = "Example"; env["GIT_AUTHOR_EMAIL"] = author
            env["GIT_COMMITTER_NAME"] = "Example"; env["GIT_COMMITTER_EMAIL"] = author
            env["GIT_AUTHOR_DATE"] = timestamp; env["GIT_COMMITTER_DATE"] = timestamp
            process.environment = env; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit(); #expect(process.terminationStatus == 0)
        }
        try git(["init", "-b", "main"])
        try git(["config", "user.email", "owner@example.invalid"])
        let file = directory.appendingPathComponent("含空格\t换行\n.txt")
        try Data("one\ntwo\n".utf8).write(to: file)
        try git(["add", "--", file.lastPathComponent]); try git(["commit", "-m", "完成第一步 🛠"])
        try git(["checkout", "-b", "feature"])
        try Data("one\ntwo\nthree\n".utf8).write(to: file)
        try git(["add", "--", file.lastPathComponent]); try git(["commit", "-m", "补充回归"], timestamp: "2026-10-24T11:00:00Z")
        try git(["checkout", "main"])
        try git(["commit", "--allow-empty", "-m", "其他作者"], author: "other@example.invalid")
        let root = try await WorkPilotGit.repositoryRoot(directory)
        #expect(root == directory.resolvingSymlinksInPath().path)
        let commits = try await WorkPilotGit.scan(repository: directory, day: date("2026-10-24T12:00:00Z"), calendar: calendar)
        #expect(commits.map(\.subject) == ["完成第一步 🛠", "补充回归"])
        #expect(commits.map(\.fileCount) == [1, 1])
        #expect(commits.map(\.additions) == [2, 1])
        #expect(commits.map(\.deletions) == [0, 0])
        var data = WorkPilotData(); let project = WorkProject(name: "示例项目"); data.projects = [project]
        #expect(data.importCommits(commits, projectID: project.id, repository: root) == 2)
        #expect(data.importCommits(commits, projectID: project.id, repository: root) == 0)
        #expect(data.logs.count == 2)
        #expect(data.report(for: date("2026-10-24T12:00:00Z"), calendar: calendar).contains("Git "))
        var inbox = WorkPilotData(); inbox.projects = [project]
        #expect(inbox.discoverCommits(commits, projectID: project.id, repository: root) == 2)
        #expect(inbox.logs.isEmpty)
        let firstID = inbox.discoveries[0].id, secondID = inbox.discoveries[1].id
        inbox.setDiscovery(firstID, state: .ignored)
        inbox.setDiscovery(secondID, state: .accepted)
        inbox.setDiscovery(secondID, state: .accepted)
        #expect(inbox.logs.count == 1)
        #expect(inbox.discoverCommits(commits, projectID: project.id, repository: root) == 0)
        let restored = try WorkPilotStore.decode(JSONEncoder().encode(inbox))
        #expect(restored.discoveries.map(\.state) == [.ignored, .accepted])
        inbox.setDiscovery(firstID, state: .pending)
        #expect(inbox.discoveries[0].state == .pending)
        try Data("working\n".utf8).write(to: file)
        try Data("new\n".utf8).write(to: directory.appendingPathComponent("untracked.txt"))
        let status = try await WorkPilotGit.workingTree(repository: directory)
        #expect(status.files.count == 2)
        #expect(status.untrackedCount == 1)
        #expect(status.files.contains { $0.path == file.lastPathComponent && $0.status == " M" })
        try data.validate()
        #expect(throws: (any Error).self) { try WorkPilotGit.parseLog(Data("bad\0record".utf8)) }
    }

    @Test func gitStatusParsesRenamesWithoutTreatingOriginalPathsAsChanges() throws {
        let status = try WorkPilotGit.parseStatus(Data("R  new\tname.txt\0old\nname.txt\0?? untracked.txt\0".utf8))
        #expect(status.files.count == 2)
        #expect(status.files[0].path == "new\tname.txt")
        #expect(status.untrackedCount == 1)
        #expect(throws: (any Error).self) { try WorkPilotGit.parseStatus(Data("R  incomplete\0".utf8)) }
        #expect(try WorkPilotGit.parseLog(Data()).isEmpty)
    }
}
