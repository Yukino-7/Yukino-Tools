import Foundation

public enum WorkRecordEntry: Identifiable, Equatable, Sendable {
    case task(WorkTask), log(WorkLog), issue(WorkIssue)
    public var id: String {
        switch self { case .task(let value): "task:\(value.id)"; case .log(let value): "log:\(value.id)"; case .issue(let value): "issue:\(value.id)" }
    }
    public var date: Date {
        switch self { case .task(let value): value.completedAt ?? value.day; case .log(let value): value.completedAt ?? value.date; case .issue(let value): value.resolvedAt ?? value.createdAt }
    }
    public var projectID: UUID? {
        switch self { case .task(let value): value.projectID; case .log(let value): value.projectID; case .issue(let value): value.projectID }
    }
    public var title: String {
        switch self { case .task(let value): value.title; case .log(let value): value.action; case .issue(let value): value.title }
    }
    public var status: WorkStatus? {
        switch self {
        case .task(let value): value.status
        case .log(let value): value.followUpStatus
        case .issue(let value): value.resolvedAt != nil ? .done : (value.status ?? .todo)
        }
    }
    public var isPending: Bool { status != nil && status != .done }
    public var detail: String {
        switch self {
        case .task(let value): value.detail
        case .log(let value): value.result
        case .issue(let value): [value.detail, value.solution.isEmpty ? "" : "方案：\(value.solution)", value.followUp.isEmpty ? "" : "跟进：\(value.followUp)"].filter { !$0.isEmpty }.joined(separator: "\n")
        }
    }
}

extension WorkPilotData {
    /// New work always stays in one record; old tasks and issues are projected without a destructive migration.
    @discardableResult
    public mutating func capture(_ content: String, followUp: Bool, projectID: UUID? = nil, at date: Date = Date()) -> Bool {
        let content = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return false }
        var log = WorkLog(action: content, projectID: projectID, date: date)
        log.followUpStatus = followUp ? .todo : nil
        logs.append(log)
        return true
    }

    public var allRecords: [WorkRecordEntry] {
        let taskIDs = Set(tasks.map(\.id))
        return tasks.map(WorkRecordEntry.task) + logs.filter { $0.taskID.map { !taskIDs.contains($0) } ?? true }.map(WorkRecordEntry.log) + issues.map(WorkRecordEntry.issue)
    }

    public func records(on day: Date, calendar: Calendar = .current) -> [WorkRecordEntry] {
        guard let interval = calendar.dateInterval(of: .day, for: day) else { return [] }
        return allRecords.filter { entry in
            if entry.isPending { return entry.date < interval.end }
            return interval.contains(entry.date)
        }.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date }
    }

    public mutating func setRecordStatus(_ entry: WorkRecordEntry, status: WorkStatus?, at date: Date = Date()) {
        switch entry {
        case .task(let task): setStatus(taskID: task.id, status: status ?? .todo, at: date)
        case .log(let log):
            guard let i = logs.firstIndex(where: { $0.id == log.id }), logs[i].followUpStatus != status else { return }
            logs[i].followUpStatus = status; logs[i].completedAt = status == .done ? date : nil
        case .issue(let issue):
            guard let i = issues.firstIndex(where: { $0.id == issue.id }) else { return }
            if status == .done, issues[i].resolvedAt != nil { return }
            issues[i].resolvedAt = status == .done ? date : nil
            issues[i].status = status
        }
    }
}

public enum WorkPilotCodexHandoff {
    public static func prompt(material: String, day: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter(); formatter.calendar = calendar; formatter.timeZone = calendar.timeZone; formatter.dateFormat = "yyyy-MM-dd"
        return "请使用 $daily-report-optimizer（日报优化）skill，根据以下 WorkPilot 素材生成 \(formatter.string(from: day)) 的中文工作日报。\n\n\(material)"
    }

    public static func url(prompt: String) throws -> URL {
        var components = URLComponents()
        components.scheme = "codex"; components.host = "threads"; components.path = "/new"
        components.queryItems = [URLQueryItem(name: "mode", value: "codex"), URLQueryItem(name: "prompt", value: prompt)]
        // The receiver uses URLSearchParams, where a literal '+' means a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else { throw ToolError.invalid("无法准备 Codex 对话") }
        return url
    }
}
