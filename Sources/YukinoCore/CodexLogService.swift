import Foundation
import CoreFoundation

/// Reads only metadata and token counters. Conversation text is neither stored nor exposed.
public struct CodexLogParser {
    public private(set) var sessionID = ""
    private var createdAt: Date?
    private var directory = ""
    private var model: String?
    private var source: String?
    private var forked = false
    private var hasHistoryBase = false
    private var previous = TokenTotals()
    private var legacy: [CodexUsageEvent] = []
    private var records: [CodexUsageEvent] = []
    private var responseIDs: Set<String> = []
    private var contextTokens: Int64?
    private var contextWindow: Int64?
    private var contextDate: Date?
    public private(set) var latestLimits: CodexLimits?
    public private(set) var malformedLines = 0
    public init() {}

    public mutating func ingest(_ line: Data) {
        guard !line.isEmpty else { return }
        // Skip large conversation/tool messages without decoding their contents.
        let relevant = ["session_meta", "turn_context", "token_usage_record", "token_count"]
        guard relevant.contains(where: { line.range(of: Data($0.utf8)) != nil }) else { return }
        guard let row = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let kind = row["type"] as? String, let payload = row["payload"] as? [String: Any] else {
            malformedLines += 1; return
        }
        let date = CodexDates.parse(row["timestamp"] as? String)
        if kind == "session_meta" {
            sessionID = payload["id"] as? String ?? sessionID
            directory = payload["cwd"] as? String ?? directory
            createdAt = CodexDates.parse(payload["timestamp"] as? String) ?? date
            source = payload["source"] as? String
            forked = payload["forked_from_id"] as? String != nil
            hasHistoryBase = payload["history_base"] is [String: Any]
        } else if kind == "turn_context" {
            model = payload["model"] as? String ?? model
        } else if kind == "token_usage_record", let date,
                  let usage = Self.tokens(payload["usage"]) {
            let owner = payload["thread_id"] as? String ?? sessionID
            guard owner == sessionID || sessionID.isEmpty else { return }
            guard !forked || createdAt == nil || date >= createdAt! else { return }
            let identifier = payload["response_id"] as? String ?? "\(owner):\(row["ordinal"] ?? "\(date.timeIntervalSince1970)")"
            guard responseIDs.insert(identifier).inserted else { return }
            records.append(CodexUsageEvent(id: "response:\(identifier)", sessionID: owner, date: date, tokens: usage))
        } else if kind == "event_msg", payload["type"] as? String == "token_count", let date {
            if let info = payload["info"] as? [String: Any] {
                if let total = Self.tokens(info["total_token_usage"]) {
                    let delta = total.delta(after: previous)
                    previous = total
                    if delta.total > 0 && (!forked || createdAt == nil || date >= createdAt!) {
                        legacy.append(CodexUsageEvent(id: "legacy:\(sessionID):\(date.timeIntervalSince1970):\(total.input):\(total.output)", sessionID: sessionID, date: date, tokens: delta))
                    }
                }
                if let last = Self.tokens(info["last_token_usage"]) {
                    contextTokens = last.total
                    contextDate = date
                }
                if let window = Self.integer(info["model_context_window"]), window > 0 { contextWindow = window }
            }
            if let raw = payload["rate_limits"] as? [String: Any] {
                // Never merge an unrelated bucket into the normal Codex allowance.
                let bucket = raw["limit_id"] as? String
                if bucket == nil || bucket == "codex" {
                    let primary = Self.window(raw["primary"], snakeCase: true)
                    let secondary = Self.window(raw["secondary"], snakeCase: true)
                    if primary != nil || secondary != nil {
                        latestLimits = CodexLimits(primary: primary, secondary: secondary,
                            planType: raw["plan_type"] as? String, capturedAt: date, source: "Session log")
                    }
                }
            }
        }
    }

    public var events: [CodexUsageEvent] {
        guard let first = records.map(\.date).min() else { return legacy }
        // A resumed page begins with inherited cumulative counters, not new work.
        // Its response records describe only the work actually performed in this page.
        if hasHistoryBase { return records }
        // Modern logs also emit legacy token_count records for the same responses.
        // Prefer response IDs, retaining only the pre-upgrade part of legacy history.
        let firstUsage = records.first { $0.date == first }?.tokens
        return legacy.filter { $0.date < first && !(first.timeIntervalSince($0.date) < 2 && $0.tokens == firstUsage) } + records
    }
    public func session(archived: Bool) -> CodexSession? {
        guard !sessionID.isEmpty else { return nil }
        let events = events
        let last = events.map(\.date).max() ?? contextDate ?? createdAt ?? .distantPast
        return CodexSession(id: sessionID,
            project: directory.isEmpty ? "Untitled session" : URL(fileURLWithPath: directory).lastPathComponent,
            directory: directory, model: model, source: source, lastActivity: last,
            tokens: events.reduce(TokenTotals()) { $0 + $1.tokens },
            contextTokens: contextTokens, contextWindow: contextWindow, archived: archived)
    }
    static func integer(_ value: Any?) -> Int64? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite,
              value.doubleValue >= 0, value.doubleValue < Double(Int64.max) else { return nil }
        return value.int64Value
    }
    static func tokens(_ value: Any?) -> TokenTotals? {
        guard let value = value as? [String: Any], let input = integer(value["input_tokens"]), let output = integer(value["output_tokens"]) else { return nil }
        return TokenTotals(input: input, cached: min(input, integer(value["cached_input_tokens"]) ?? 0),
                           output: output, reasoning: min(output, integer(value["reasoning_output_tokens"]) ?? 0))
    }
    static func window(_ value: Any?, snakeCase: Bool) -> CodexLimitWindow? {
        guard let value = value as? [String: Any], let number = value[snakeCase ? "used_percent" : "usedPercent"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let used = number.doubleValue
        guard
              used.isFinite, used >= 0, used <= 100 else { return nil }
        return CodexLimitWindow(usedPercent: used,
            windowDurationMins: integer(value[snakeCase ? "window_minutes" : "windowDurationMins"]).map(Int.init),
            resetsAt: integer(value[snakeCase ? "resets_at" : "resetsAt"]).map(Double.init))
    }
}

/// Incremental, off-main-thread scanning: unchanged files are not reread.
public actor CodexLogService {
    private struct FileCache {
        var inode: UInt64
        var modified: Date
        var offset: UInt64 = 0
        var pending = Data()
        var parser = CodexLogParser()
        var archived: Bool
    }
    private var cache: [String: FileCache] = [:]
    private var rootPath: String?
    public init() {}
    public func scan(root: URL) throws -> CodexLocalSnapshot {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ToolError.invalid("Codex data folder not found. Choose your .codex folder in Settings.")
        }
        guard manager.isReadableFile(atPath: root.path) else { throw ToolError.invalid("Codex data folder cannot be read.") }
        if rootPath != root.path { cache.removeAll(); rootPath = root.path }
        var present: Set<String> = []
        var unreadable = 0
        for folder in ["sessions", "archived_sessions"] {
            let directory = root.appendingPathComponent(folder)
            guard manager.fileExists(atPath: directory.path) else { continue }
            guard let enumerator = manager.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles], errorHandler: { _, _ in unreadable += 1; return true }) else {
                unreadable += 1; continue
            }
            for case let file as URL in enumerator where file.pathExtension == "jsonl" {
                guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                present.insert(file.path)
                do {
                    let attributes = try manager.attributesOfItem(atPath: file.path)
                    let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
                    let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
                    let modified = attributes[.modificationDate] as? Date ?? .distantPast
                    var entry = cache[file.path] ?? FileCache(inode: inode, modified: modified, archived: folder == "archived_sessions")
                    if entry.inode != inode || size < entry.offset || (size == entry.offset && modified != entry.modified) {
                        entry = FileCache(inode: inode, modified: modified, archived: folder == "archived_sessions")
                    }
                    if size > entry.offset {
                        let handle = try FileHandle(forReadingFrom: file)
                        defer { try? handle.close() }
                        try handle.seek(toOffset: entry.offset)
                        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                            entry.offset += UInt64(chunk.count)
                            entry.pending.append(chunk)
                            while let newline = entry.pending.firstIndex(of: 10) {
                                let line = Data(entry.pending[..<newline])
                                entry.pending.removeSubrange(...newline)
                                entry.parser.ingest(line)
                            }
                        }
                    }
                    entry.modified = modified
                    cache[file.path] = entry
                } catch { unreadable += 1 }
            }
        }
        cache = cache.filter { present.contains($0.key) }
        // A thread can span multiple paginated logs and can also have archive copies.
        // Merge every page by response ID instead of keeping only the newest file.
        var grouped: [String: [FileCache]] = [:]
        for entry in cache.values {
            let id = entry.parser.sessionID
            guard !id.isEmpty else { continue }
            grouped[id, default: []].append(entry)
        }
        var seen: Set<String> = []
        var events: [CodexUsageEvent] = []
        var sessions: [CodexSession] = []
        for entries in grouped.values {
            let all = entries.flatMap { $0.parser.events }
            let firstModern = all.filter { $0.id.hasPrefix("response:") }.min { $0.date < $1.date }
            var threadEvents: [CodexUsageEvent] = []
            for event in all.sorted(by: { $0.date < $1.date }) {
                if event.id.hasPrefix("legacy:"), let firstModern {
                    if event.date >= firstModern.date { continue }
                    if firstModern.date.timeIntervalSince(event.date) < 2 && event.tokens == firstModern.tokens { continue }
                }
                if seen.insert(event.id).inserted { threadEvents.append(event) }
            }
            let metadata = entries.compactMap { $0.parser.session(archived: $0.archived) }.max { $0.lastActivity < $1.lastActivity }!
            let context = entries.compactMap { $0.parser.session(archived: $0.archived) }
                .filter { $0.contextTokens != nil }.max { $0.lastActivity < $1.lastActivity }
            sessions.append(CodexSession(id: metadata.id, project: metadata.project, directory: metadata.directory,
                model: metadata.model, source: metadata.source, lastActivity: metadata.lastActivity,
                tokens: threadEvents.reduce(TokenTotals()) { $0 + $1.tokens },
                contextTokens: context?.contextTokens, contextWindow: context?.contextWindow,
                archived: entries.allSatisfy(\.archived)))
            events.append(contentsOf: threadEvents)
        }
        return CodexLocalSnapshot(
            sessions: sessions.sorted { $0.lastActivity > $1.lastActivity },
            events: events.sorted { $0.date < $1.date },
            latestLimits: cache.values.compactMap { $0.parser.latestLimits }.max { $0.capturedAt < $1.capturedAt },
            scannedFiles: cache.count, malformedLines: cache.values.reduce(0) { $0 + $1.parser.malformedLines }, unreadableFiles: unreadable)
    }
}
