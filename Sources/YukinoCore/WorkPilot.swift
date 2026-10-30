import Foundation

public enum WorkStatus: String, Codable, CaseIterable, Sendable {
    case todo, doing, blocked, done
    public var title: String {
        switch self { case .todo: "待办"; case .doing: "进行中"; case .blocked: "阻塞"; case .done: "已完成" }
    }
}

public struct WorkProject: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var name: String
    public var goal: String
    public var archived = false
    public var repositoryPath: String?
    public var gitAuthorEmail: String?
    public init(name: String, goal: String = "") { self.name = name; self.goal = goal }
}

public struct WorkTask: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var projectID: UUID?
    public var title: String
    public var detail: String
    public var day: Date
    public var priority: Int
    public var status: WorkStatus = .todo
    public var completedAt: Date?
    public init(title: String, projectID: UUID? = nil, detail: String = "", day: Date = Date(), priority: Int = 1) {
        self.title = title; self.projectID = projectID; self.detail = detail; self.day = day; self.priority = priority
    }
}

public struct WorkLog: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var projectID: UUID?
    public var taskID: UUID?
    public var date: Date
    public var action: String
    public var result: String
    public var gitCommit: String?
    public var gitRepository: String?
    public var followUpStatus: WorkStatus?
    public var completedAt: Date?
    public var codexActivityID: String?
    public var codexSessionID: String?
    public init(action: String, result: String = "", projectID: UUID? = nil, date: Date = Date(), taskID: UUID? = nil) {
        self.action = action; self.result = result; self.projectID = projectID; self.date = date; self.taskID = taskID
    }
}

public struct WorkIssue: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var projectID: UUID?
    public var title: String
    public var detail: String
    public var solution: String
    public var followUp: String
    public var due: Date?
    public var createdAt: Date
    public var resolvedAt: Date?
    public var status: WorkStatus?
    public init(title: String, projectID: UUID? = nil, detail: String = "", solution: String = "", followUp: String = "", due: Date? = nil, createdAt: Date = Date()) {
        self.title = title; self.projectID = projectID; self.detail = detail; self.solution = solution
        self.followUp = followUp; self.due = due; self.createdAt = createdAt
    }
}

public struct WorkSession: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var projectID: UUID
    public var start: Date
    public var end: Date
    public var automatic: Bool
    public init(projectID: UUID, start: Date, end: Date, automatic: Bool) {
        self.projectID = projectID; self.start = start; self.end = end; self.automatic = automatic
    }
}

public struct WorkAppRule: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var projectID: UUID
    public var bundleID: String
    public var appName: String
    public init(projectID: UUID, bundleID: String, appName: String) {
        self.projectID = projectID; self.bundleID = bundleID; self.appName = appName
    }
}

public struct WorkReportDraft: Codable, Identifiable, Equatable, Sendable {
    public var day: Date
    public var markdown: String
    public var updatedAt: Date
    public var id: Date { day }
    public init(day: Date, markdown: String, updatedAt: Date = Date()) {
        self.day = day; self.markdown = markdown; self.updatedAt = updatedAt
    }
}

public enum WorkDiscoveryState: String, Codable, Sendable { case pending, accepted, ignored }
public struct WorkDiscovery: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var projectID: UUID
    public var repository: String
    public var commit: WorkGitCommit
    public var state: WorkDiscoveryState = .pending
}

public struct WorkCodexDiscovery: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var projectID: UUID?
    public var activity: WorkCodexActivity
    public var state: WorkDiscoveryState = .pending
}

public struct WorkPilotData: Codable, Equatable, Sendable {
    public var version = 1
    public var projects: [WorkProject] = []
    public var tasks: [WorkTask] = []
    public var logs: [WorkLog] = []
    public var issues: [WorkIssue] = []
    public var sessions: [WorkSession] = []
    public var rules: [WorkAppRule] = []
    public var reports: [WorkReportDraft] = []
    public var discoveries: [WorkDiscovery] = []
    public var codexDiscoveries: [WorkCodexDiscovery] = []
    public init() {}

    private enum CodingKeys: String, CodingKey { case version, projects, tasks, logs, issues, sessions, rules, reports, discoveries, codexDiscoveries }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        projects = try values.decode([WorkProject].self, forKey: .projects)
        tasks = try values.decode([WorkTask].self, forKey: .tasks)
        logs = try values.decode([WorkLog].self, forKey: .logs)
        issues = try values.decode([WorkIssue].self, forKey: .issues)
        sessions = try values.decode([WorkSession].self, forKey: .sessions)
        rules = try values.decode([WorkAppRule].self, forKey: .rules)
        reports = try values.decode([WorkReportDraft].self, forKey: .reports)
        discoveries = try values.decodeIfPresent([WorkDiscovery].self, forKey: .discoveries) ?? []
        codexDiscoveries = try values.decodeIfPresent([WorkCodexDiscovery].self, forKey: .codexDiscoveries) ?? []
    }

    public func projectName(_ id: UUID?) -> String {
        projects.first { $0.id == id }?.name ?? "未归属项目"
    }
    public func progress(for projectID: UUID) -> Double {
        let items = allRecords.filter { $0.projectID == projectID && $0.status != nil }
        return items.isEmpty ? 0 : Double(items.filter { $0.status == .done }.count) / Double(items.count)
    }
    @discardableResult
    public mutating func importCommits(_ commits: [WorkGitCommit], projectID: UUID, repository: String) -> Int {
        guard projects.contains(where: { $0.id == projectID }) else { return 0 }
        var imported = 0
        for commit in commits {
            guard !logs.contains(where: { $0.gitCommit == commit.hash && $0.gitRepository == repository }) else { continue }
            var log = WorkLog(action: commit.subject, result: "Git \(commit.hash.prefix(8)) · \(commit.fileCount) 个文件，+\(commit.additions) / -\(commit.deletions) 行", projectID: projectID, date: commit.date)
            log.gitCommit = commit.hash; log.gitRepository = repository
            logs.append(log); imported += 1
        }
        return imported
    }
    @discardableResult
    public mutating func discoverCommits(_ commits: [WorkGitCommit], projectID: UUID, repository: String) -> Int {
        guard projects.contains(where: { $0.id == projectID }) else { return 0 }
        var added = 0
        for commit in commits {
            guard !discoveries.contains(where: { $0.repository == repository && $0.commit.hash == commit.hash }),
                  !logs.contains(where: { $0.gitRepository == repository && $0.gitCommit == commit.hash }) else { continue }
            discoveries.append(WorkDiscovery(projectID: projectID, repository: repository, commit: commit)); added += 1
        }
        return added
    }
    public mutating func setDiscovery(_ id: UUID, state: WorkDiscoveryState) {
        guard let i = discoveries.firstIndex(where: { $0.id == id }) else { return }
        if state == .accepted {
            let discovery = discoveries[i]
            importCommits([discovery.commit], projectID: discovery.projectID, repository: discovery.repository)
        }
        discoveries[i].state = state
    }
    public func detectedProject(bundleID: String) -> UUID? {
        let ids = Set(rules.filter { $0.bundleID == bundleID }.map(\.projectID))
            .filter { id in projects.contains { $0.id == id && !$0.archived } }
        return ids.count == 1 ? ids.first : nil
    }
    /// Status changes update one linked completion log; reopening removes that derived log.
    public mutating func setStatus(taskID: UUID, status: WorkStatus, at date: Date = Date()) {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }), tasks[index].status != status else { return }
        tasks[index].status = status
        tasks[index].completedAt = status == .done ? date : nil
        for log in logs where log.taskID == taskID && !log.result.isEmpty && log.result != "已完成" {
            if !tasks[index].detail.contains(log.result) {
                tasks[index].detail += (tasks[index].detail.isEmpty ? "" : "\n") + log.result
            }
        }
        logs.removeAll { $0.taskID == taskID }
        if status == .done {
            let task = tasks[index]
            logs.append(WorkLog(action: task.title, result: "已完成", projectID: task.projectID, date: date, taskID: taskID))
        }
    }
    public func seconds(on day: Date, projectID: UUID? = nil, calendar: Calendar = .current) -> TimeInterval {
        guard let range = calendar.dateInterval(of: .day, for: day) else { return 0 }
        return sessions.filter { projectID == nil || $0.projectID == projectID }.reduce(0) { total, session in
            total + max(0, min(range.end, session.end).timeIntervalSince(max(range.start, session.start)))
        }
    }
    public mutating func recordTime(projectID: UUID, start: Date, end: Date, automatic: Bool) {
        guard end > start else { return }
        // Adjacent ticks form one session, while pauses, project switches and day boundaries remain visible.
        if let last = sessions.indices.last, sessions[last].projectID == projectID,
           sessions[last].automatic == automatic, sessions[last].end == start,
           Calendar.current.isDate(sessions[last].start, inSameDayAs: end) {
            sessions[last].end = end
        } else { sessions.append(WorkSession(projectID: projectID, start: start, end: end, automatic: automatic)) }
    }

    public func report(for day: Date, calendar: Calendar = .current) -> String {
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        let formatter = DateFormatter(); formatter.calendar = calendar; formatter.timeZone = calendar.timeZone; formatter.dateFormat = "yyyy-MM-dd"
        let dayLogs = logs.filter {
            if $0.followUpStatus == .done { return $0.completedAt.map { $0 >= start && $0 < end } == true }
            return $0.followUpStatus == nil && $0.date >= start && $0.date < end
        }.sorted { $0.date < $1.date }
        let completed = tasks.filter { $0.completedAt.map { $0 >= start && $0 < end } == true && $0.status == .done }
        var lines = ["# 工作日报 · \(formatter.string(from: day))", "", "## 今日工作与产出"]
        let projectIDs = Set(dayLogs.map(\.projectID) + completed.map(\.projectID))
        if projectIDs.isEmpty { lines.append("- 暂无工作记录") }
        for id in projectIDs.sorted(by: { projectName($0) < projectName($1) }) {
            lines += ["", "### \(projectName(id))"]
            for log in dayLogs where log.projectID == id {
                lines.append("- \(log.action)\(log.followUpStatus == .done ? "；已完成" : "")\(log.result.isEmpty ? "" : "；结果：\(log.result)")")
            }
            for task in completed where task.projectID == id && !dayLogs.contains(where: { $0.taskID == task.id }) {
                lines.append("- \(task.title)；已完成")
            }
        }
        lines += ["", "## 进行中与阻塞"]
        // Only include tasks planned by this date; future tasks belong to the next-step section.
        let unfinished = tasks.filter { $0.status != .done && $0.day < end }
        let pendingNotes = logs.filter { $0.followUpStatus != nil && $0.followUpStatus != .done && $0.date < end }
        let ongoingLines = unfinished.map { "- [\($0.status.title)] \(projectName($0.projectID)) · \($0.title)\($0.detail.isEmpty ? "" : "；\($0.detail)")" }
            + pendingNotes.map { "- [\($0.followUpStatus!.title)] \(projectName($0.projectID)) · \($0.action)\($0.result.isEmpty ? "" : "；\($0.result)")" }
        lines += ongoingLines.isEmpty ? ["- 无"] : ongoingLines
        lines += ["", "## 问题、解决方案与跟进"]
        let relevant = issues.filter { $0.createdAt < end && ($0.resolvedAt == nil || $0.resolvedAt! >= start) }
        lines += relevant.isEmpty ? ["- 无"] : relevant.map { issue in
            var text = "- [\(issue.resolvedAt != nil ? "已解决" : issue.status == .blocked ? "阻塞" : "待解决")] \(projectName(issue.projectID)) · \(issue.title)"
            if !issue.detail.isEmpty { text += "；问题：\(issue.detail)" }
            if !issue.solution.isEmpty { text += "；方案：\(issue.solution)" }
            if !issue.followUp.isEmpty { text += "；跟进：\(issue.followUp)" }
            if let due = issue.due { text += "（\(formatter.string(from: due))）" }
            return text
        }
        lines += ["", "## 下一步"]
        let next = tasks.filter { $0.status != .done && $0.day >= end }
        let nextLines = next.sorted { $0.day < $1.day }.map { "- \(formatter.string(from: $0.day)) · \(projectName($0.projectID)) · \($0.title)" }
            + logs.filter { $0.followUpStatus != nil && $0.followUpStatus != .done && $0.date >= end }.map { "- \(formatter.string(from: $0.date)) · \(projectName($0.projectID)) · \($0.action)" }
        lines += nextLines.isEmpty ? ["- 待补充"] : nextLines
        lines += ["", "## 项目投入时间"]
        let timed = projects.filter { seconds(on: day, projectID: $0.id, calendar: calendar) > 0 }
        lines += timed.isEmpty ? ["- 暂无计时记录"] : timed.map { "- \($0.name)：\(Int(seconds(on: day, projectID: $0.id, calendar: calendar) / 60)) 分钟" }
        lines += ["", "*日报根据本机工作记录生成；投入时间不代表完成进度。历史日期使用当前任务与问题状态。*", ""]
        return lines.joined(separator: "\n")
    }

    public func validate() throws {
        guard version == 1 else { throw ToolError.invalid("不支持的 WorkPilot 数据版本") }
        func unique<T: Hashable>(_ ids: [T]) -> Bool { Set(ids).count == ids.count }
        let projectIDs = Set(projects.map(\.id)), taskIDs = Set(tasks.map(\.id))
        func validProject(_ id: UUID?) -> Bool { id == nil || projectIDs.contains(id!) }
        guard unique(projects.map(\.id)), unique(tasks.map(\.id)), unique(logs.map(\.id)), unique(issues.map(\.id)),
              unique(sessions.map(\.id)), unique(rules.map(\.id)), unique(reports.map(\.day)), unique(discoveries.map(\.id)),
              unique(codexDiscoveries.map(\.id)), unique(codexDiscoveries.map { $0.activity.id }), unique(logs.compactMap(\.codexActivityID)),
              projects.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              tasks.allSatisfy({ validProject($0.projectID) && !$0.title.isEmpty && (0...2).contains($0.priority) && (($0.status == .done) == ($0.completedAt != nil)) }),
              logs.allSatisfy({ validProject($0.projectID) && !$0.action.isEmpty && ($0.taskID == nil || taskIDs.contains($0.taskID!)) && (($0.followUpStatus == .done) == ($0.completedAt != nil)) }),
              issues.allSatisfy({ validProject($0.projectID) && !$0.title.isEmpty && ($0.status == nil || (($0.status == .done) == ($0.resolvedAt != nil))) }),
              sessions.allSatisfy({ projectIDs.contains($0.projectID) && $0.end > $0.start }),
              rules.allSatisfy({ projectIDs.contains($0.projectID) && !$0.bundleID.isEmpty }),
              discoveries.allSatisfy({ projectIDs.contains($0.projectID) && !$0.repository.isEmpty && (40...64).contains($0.commit.hash.count) && $0.commit.hash.allSatisfy(\.isHexDigit) }),
              codexDiscoveries.allSatisfy({ validProject($0.projectID) && !$0.activity.sessionID.isEmpty && !$0.activity.turnID.isEmpty && !$0.activity.request.isEmpty && !$0.activity.response.isEmpty }) else {
            throw ToolError.invalid("WorkPilot 数据包含重复标识、无效状态或丢失的项目关联")
        }
    }
}

/// Local atomic storage. A bad primary file never silently becomes an empty workspace.
public struct WorkPilotStore: Sendable {
    public let url: URL
    public var backupURL: URL { url.deletingPathExtension().appendingPathExtension("backup.json") }
    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("YukinoTools/WorkPilot/workspace.json")
    }
    public init(url: URL = Self.defaultURL) { self.url = url }
    public func load() throws -> WorkPilotData {
        guard FileManager.default.fileExists(atPath: url.path) else { return WorkPilotData() }
        return try Self.decode(Data(contentsOf: url))
    }
    public static func decode(_ data: Data) throws -> WorkPilotData {
        guard data.count <= 20_000_000 else { throw ToolError.invalid("工作区超过 20 MB") }
        let result = try JSONDecoder().decode(WorkPilotData.self, from: data)
        try result.validate()
        return result
    }
    public func save(_ workspace: WorkPilotData) throws {
        try workspace.validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(workspace)
        guard data.count <= 20_000_000 else { throw ToolError.invalid("工作区超过 20 MB，请导出备份后整理记录") }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path) {
            let previous = try Data(contentsOf: url)
            _ = try Self.decode(previous)
            try previous.write(to: backupURL, options: .atomic)
        }
        try data.write(to: url, options: .atomic)
    }
}
