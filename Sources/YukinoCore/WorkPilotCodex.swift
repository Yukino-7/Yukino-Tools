import Foundation

public struct WorkCodexActivity: Codable, Equatable, Identifiable, Sendable {
    public var sessionID: String
    public var turnID: String
    public var directory: String
    public var date: Date
    public var request: String
    public var response: String
    public var truncated: Bool
    public var id: String { "\(sessionID):\(turnID)" }
    public var title: String {
        let line = request.split(whereSeparator: \.isNewline).first.map(String.init) ?? "Codex 工作会话"
        return String(line.prefix(100))
    }
    public var recordText: String {
        "Codex 会话记录（答复内容尚未经独立验证）\n事项：\(request)\n答复：\(response)"
            + (truncated ? "\n（长内容已截取，可打开原会话查看完整记录。）" : "")
    }
}

/// A separate parser from the usage counter: only human requests and final answers become candidates.
public struct WorkCodexParser: Sendable {
    private struct Turn: Sendable {
        var directory = ""
        var request = ""
        var response = ""
        var finalDate: Date?
        var fallbackDate: Date?
        var finished = false
        var reportGeneration = false
        var truncated = false
    }
    private let interval: DateInterval
    private var sessionID = ""
    private var directory = ""
    private var createdAt: Date?
    private var forked = false
    private var subagent = false
    private var activeTurn = ""
    private var turns: [String: Turn] = [:]
    public init(day: Date, calendar: Calendar = .current) { interval = calendar.dateInterval(of: .day, for: day)! }

    public mutating func ingest(_ line: Data) {
        guard line.count <= 1_048_576,
              ["session_meta", "turn_context", "task_started", "task_complete", "user_message", "agent_message", "\"message\""].contains(where: { line.range(of: Data($0.utf8)) != nil }),
              let row = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = row["type"] as? String, let payload = row["payload"] as? [String: Any] else { return }
        let date = CodexDates.parse(row["timestamp"] as? String)
        if type == "session_meta" {
            sessionID = payload["id"] as? String ?? payload["session_id"] as? String ?? ""
            directory = payload["cwd"] as? String ?? ""
            createdAt = CodexDates.parse(payload["timestamp"] as? String) ?? date
            forked = payload["forked_from_id"] != nil
            subagent = (payload["source"] as? [String: Any])?["subagent"] != nil || (payload["source"] as? String)?.hasPrefix("subagent") == true
            return
        }
        guard !sessionID.isEmpty, !subagent else { return }
        if type == "turn_context" || (type == "event_msg" && payload["type"] as? String == "task_started") {
            activeTurn = payload["turn_id"] as? String ?? payload["root_turn_id"] as? String ?? activeTurn
            if type == "turn_context" { directory = payload["cwd"] as? String ?? directory }
            return
        }
        let kind = payload["type"] as? String
        let message = type == "response_item" && kind == "message"
        let legacyUser = type == "event_msg" && kind == "user_message"
        let complete = type == "event_msg" && kind == "task_complete"
        guard message || legacyUser || complete else { return }
        if let owner = payload["thread_id"] as? String, owner != sessionID { return }
        if forked, let createdAt, let date, date < createdAt { return }
        let role = legacyUser ? "user" : payload["role"] as? String
        let text: String
        if legacyUser { text = payload["message"] as? String ?? "" }
        else if complete { text = payload["last_agent_message"] as? String ?? "" }
        else {
            text = (payload["content"] as? [[String: Any]] ?? []).compactMap {
                guard ["input_text", "output_text", "text"].contains($0["type"] as? String ?? "") else { return nil }
                guard let text = $0["text"] as? String else { return nil }
                return role == "user" && !Self.isHumanRequest(text.trimmingCharacters(in: .whitespacesAndNewlines)) ? nil : text
            }.joined(separator: "\n")
        }
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if role == "user", !Self.isHumanRequest(cleaned) { return }
        if let id = payload["turn_id"] as? String ?? payload["root_turn_id"] as? String { activeTurn = id }
        else if role == "user", turns[activeTurn]?.finished == true, let date { activeTurn = "legacy-\(date.timeIntervalSince1970)" }
        if activeTurn.isEmpty, role == "user", let date { activeTurn = "legacy-\(date.timeIntervalSince1970)" }
        if turns.count >= 5_000 {
            turns = turns.filter { id, turn in id == activeTurn || (turn.finished && (turn.finalDate ?? turn.fallbackDate).map { interval.contains($0) } == true) }
        }
        guard !activeTurn.isEmpty, turns.count < 5_000 || turns[activeTurn] != nil else { return }
        var turn = turns[activeTurn] ?? Turn(directory: directory)
        if !directory.isEmpty { turn.directory = directory }
        if role == "user" {
            if cleaned.contains("$daily-report-optimizer") && cleaned.contains("WorkPilot 素材生成") { turn.reportGeneration = true }
            let request = String(cleaned.prefix(2_000))
            if turn.request.isEmpty { turn.request = request }
            else if !turn.request.contains(request) { turn.request = String((turn.request + "\n" + request).prefix(4_000)) }
            turn.truncated = turn.truncated || cleaned.count > 2_000
        } else if role == "assistant" {
            let phase = payload["phase"] as? String
            guard phase == nil || phase == "final_answer" else { return }
            guard !cleaned.isEmpty else { return }
            turn.response = String(cleaned.prefix(8_000)); turn.truncated = turn.truncated || cleaned.count > 8_000
            if phase == "final_answer" { turn.finished = true; turn.finalDate = date }
        } else if complete {
            turn.finished = true
            turn.fallbackDate = CodexDates.parse(payload["completed_at"] as? String) ?? date
            if turn.finalDate == nil, !cleaned.isEmpty {
                turn.response = String(cleaned.prefix(8_000)); turn.truncated = turn.truncated || cleaned.count > 8_000
            }
        } else { return }
        turns[activeTurn] = turn
    }

    public var activities: [WorkCodexActivity] {
        turns.compactMap { id, turn in
            guard turn.finished, !turn.reportGeneration, !turn.request.isEmpty, !turn.response.isEmpty,
                  let date = turn.finalDate ?? turn.fallbackDate, interval.contains(date) else { return nil }
            return WorkCodexActivity(sessionID: sessionID, turnID: id, directory: turn.directory, date: date,
                                     request: turn.request, response: turn.response, truncated: turn.truncated)
        }.sorted { $0.date < $1.date }
    }
    private static func isHumanRequest(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let scaffolding = ["# AGENTS.md instructions", "<environment_context>", "<external_codex_apps_open_page>", "<skill>", "<permissions", "<turn_aborted>", "<system_reminder>", "<user_instructions>"]
        return !scaffolding.contains { text.hasPrefix($0) }
    }
}

extension WorkPilotData {
    public func matchingCodexProject(directory: String) -> UUID? {
        guard directory.hasPrefix("/") else { return nil }
        let path = URL(fileURLWithPath: directory).resolvingSymlinksInPath().standardizedFileURL.path
        let matches = projects.compactMap { project -> (UUID, String)? in
            guard !project.archived, let repository = project.repositoryPath, repository.hasPrefix("/") else { return nil }
            let root = URL(fileURLWithPath: repository).resolvingSymlinksInPath().standardizedFileURL.path
            guard path == root || path.hasPrefix(root == "/" ? root : root + "/") else { return nil }
            return (project.id, root)
        }
        guard let length = matches.map({ $0.1.count }).max() else { return nil }
        let best = matches.filter { $0.1.count == length }
        return best.count == 1 ? best[0].0 : nil
    }
    @discardableResult
    public mutating func discoverCodexActivities(_ activities: [WorkCodexActivity]) -> Int {
        var added = 0
        for activity in activities {
            if let i = codexDiscoveries.firstIndex(where: { $0.activity.id == activity.id }) {
                if codexDiscoveries[i].state != .accepted { codexDiscoveries[i].activity = activity }
                if codexDiscoveries[i].state == .pending && codexDiscoveries[i].projectID == nil {
                    codexDiscoveries[i].projectID = matchingCodexProject(directory: activity.directory)
                }
                continue
            }
            guard !logs.contains(where: { $0.codexActivityID == activity.id }) else { continue }
            codexDiscoveries.append(WorkCodexDiscovery(projectID: matchingCodexProject(directory: activity.directory), activity: activity))
            added += 1
        }
        return added
    }
    public mutating func setCodexDiscovery(_ id: UUID, state: WorkDiscoveryState) {
        guard let i = codexDiscoveries.firstIndex(where: { $0.id == id }) else { return }
        let discovery = codexDiscoveries[i]
        if state == .accepted && !logs.contains(where: { $0.codexActivityID == discovery.activity.id }) {
            var log = WorkLog(action: "Codex · \(discovery.activity.title)", result: discovery.activity.recordText,
                              projectID: discovery.projectID, date: discovery.activity.date)
            log.codexActivityID = discovery.activity.id; log.codexSessionID = discovery.activity.sessionID
            logs.append(log)
        }
        codexDiscoveries[i].state = state
    }
}

public struct WorkCodexScan: Sendable {
    public var activities: [WorkCodexActivity]
    public var unreadableFiles: Int
    public var limited: Bool
}

/// Incremental bounded reads of session logs only; credentials and remote accounts are never accessed.
public actor WorkPilotCodexService {
    private struct Cache {
        var inode: UInt64
        var modified: Date
        var offset: UInt64 = 0
        var pending = Data()
        var discardingLongLine = false
        var parser: WorkCodexParser
    }
    private var cache: [String: Cache] = [:]
    private var scope = ""
    public init() {}
    public func scan(root: URL, day: Date, calendar: Calendar = .current) throws -> WorkCodexScan {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ToolError.invalid("找不到 Codex 本地记录，可在设置 → Codex 中选择数据目录")
        }
        let start = calendar.startOfDay(for: day)
        let key = "\(root.standardizedFileURL.path):\(start.timeIntervalSince1970):\(calendar.timeZone.identifier)"
        if scope != key { scope = key; cache.removeAll() }
        var present: Set<String> = [], unreadable = 0, totalBytes = 0, limited = false
        let deadline = Date().addingTimeInterval(20)
        for folder in ["sessions", "archived_sessions"] {
            let directory = root.appendingPathComponent(folder)
            guard manager.fileExists(atPath: directory.path) else { continue }
            guard let files = manager.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey], options: [.skipsHiddenFiles], errorHandler: { _, _ in unreadable += 1; return true }) else { unreadable += 1; continue }
            for case let file as URL in files where file.pathExtension == "jsonl" {
                try Task.checkCancellation()
                if Date() >= deadline || totalBytes >= 256 * 1_024 * 1_024 || present.count >= 2_000 { limited = true; break }
                guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]),
                      values.isRegularFile == true, values.isSymbolicLink != true, (values.contentModificationDate ?? .distantPast) >= start else { continue }
                present.insert(file.path)
                do {
                    let attributes = try manager.attributesOfItem(atPath: file.path)
                    let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
                    let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
                    let modified = values.contentModificationDate ?? .distantPast
                    var entry = cache[file.path] ?? Cache(inode: inode, modified: modified, parser: WorkCodexParser(day: day, calendar: calendar))
                    if entry.inode != inode || size < entry.offset || (size == entry.offset && modified != entry.modified) {
                        entry = Cache(inode: inode, modified: modified, parser: WorkCodexParser(day: day, calendar: calendar))
                    }
                    if size > entry.offset {
                        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
                        try handle.seek(toOffset: entry.offset)
                        while entry.offset < size {
                            if Date() >= deadline || totalBytes >= 256 * 1_024 * 1_024 { limited = true; break }
                            guard let chunk = try handle.read(upToCount: Int(min(65_536, size - entry.offset))), !chunk.isEmpty else { break }
                            entry.offset += UInt64(chunk.count); totalBytes += chunk.count
                            entry.pending.append(chunk)
                            while let newline = entry.pending.firstIndex(of: 10) {
                                if !entry.discardingLongLine { entry.parser.ingest(Data(entry.pending[..<newline])) }
                                entry.pending.removeSubrange(...newline); entry.discardingLongLine = false
                            }
                            if entry.pending.count > 1_048_576 { entry.pending.removeAll(keepingCapacity: false); entry.discardingLongLine = true }
                        }
                    }
                    entry.modified = modified; cache[file.path] = entry
                } catch { unreadable += 1 }
            }
        }
        if !limited { cache = cache.filter { present.contains($0.key) } }
        var unique: [String: WorkCodexActivity] = [:]
        for activity in cache.values.flatMap({ $0.parser.activities }) {
            if unique[activity.id] == nil || activity.response.count > unique[activity.id]!.response.count { unique[activity.id] = activity }
        }
        return WorkCodexScan(activities: unique.values.sorted { $0.date < $1.date }, unreadableFiles: unreadable, limited: limited)
    }
}
