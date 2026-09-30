import Foundation
import Testing
@testable import YukinoCore

private func line(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
private func meta(id: String = "session-a", fork: String? = nil) throws -> Data {
    var payload: [String: Any] = ["id": id, "timestamp": "2026-09-30T06:00:00Z", "cwd": "/projects/Yukino", "source": "cli"]
    if let fork { payload["forked_from_id"] = fork }
    return try line(["type": "session_meta", "payload": payload])
}
private func counters(_ input: Int, _ output: Int, cached: Int = 0, reasoning: Int = 0) -> [String: Int] {
    ["input_tokens": input, "output_tokens": output, "cached_input_tokens": cached, "reasoning_output_tokens": reasoning, "total_tokens": input + output]
}
private func legacy(_ total: [String: Int], last: [String: Int]? = nil, time: String = "2026-09-30T06:01:00Z", limits: [String: Any]? = nil) throws -> Data {
    var payload: [String: Any] = ["type": "token_count", "info": ["total_token_usage": total, "last_token_usage": last ?? total, "model_context_window": 1000]]
    if let limits { payload["rate_limits"] = limits }
    return try line(["type": "event_msg", "timestamp": time, "payload": payload])
}
private func record(_ usage: [String: Int], id: String, owner: String = "session-a", time: String = "2026-09-30T06:01:00Z") throws -> Data {
    try line(["type": "token_usage_record", "timestamp": time, "payload": ["thread_id": owner, "response_id": id, "usage": usage]])
}

@Test func legacyUsageUsesCumulativeDeltasAndSkipsRepeatedSnapshots() throws {
    var parser = CodexLogParser()
    parser.ingest(try meta())
    parser.ingest(try legacy(counters(100, 20, cached: 60, reasoning: 5)))
    parser.ingest(try legacy(counters(100, 20, cached: 60, reasoning: 5), time: "2026-09-30T06:02:00Z"))
    parser.ingest(try legacy(counters(250, 50, cached: 180, reasoning: 12), last: counters(150, 30), time: "2026-09-30T06:03:00Z"))
    let session = try #require(parser.session(archived: false))
    #expect(parser.events.count == 2)
    #expect(session.tokens == TokenTotals(input: 250, cached: 180, output: 50, reasoning: 12))
    #expect(session.tokens.total == 300) // Cached input and reasoning are subsets, not extra tokens.
    #expect(session.contextFraction == 0.18)
}

@Test func modernAndLegacyRecordsDoNotDoubleCountAndRetainPreUpgradeHistory() throws {
    var parser = CodexLogParser()
    parser.ingest(try meta())
    parser.ingest(try legacy(counters(100, 20), time: "2026-09-30T06:00:10Z"))
    parser.ingest(try record(counters(150, 30, cached: 100), id: "response-1"))
    parser.ingest(try record(counters(150, 30, cached: 100), id: "response-1"))
    parser.ingest(try legacy(counters(250, 50, cached: 100), last: counters(150, 30, cached: 100), time: "2026-09-30T06:01:01Z"))
    #expect(parser.events.count == 2)
    #expect(parser.session(archived: false)?.tokens.total == 300)
}

@Test func forkIgnoresInheritedResponsesAndLegacyCountersBeforeCreation() throws {
    var parser = CodexLogParser()
    parser.ingest(try meta(id: "fork", fork: "parent"))
    parser.ingest(try record(counters(100, 10), id: "parent-response", owner: "parent"))
    parser.ingest(try legacy(counters(100, 10), time: "2026-09-29T06:00:00Z"))
    parser.ingest(try legacy(counters(150, 20), last: counters(50, 10)))
    #expect(parser.session(archived: false)?.tokens.total == 60)
}

@Test func missingContextAndNullQuotaStayUnknownAndOtherBucketsAreIgnored() throws {
    var parser = CodexLogParser()
    parser.ingest(try meta())
    parser.ingest(try line(["type": "event_msg", "timestamp": "2026-09-30T06:01:00Z", "payload": ["type": "token_count", "info": NSNull(), "rate_limits": ["limit_id": "other-model", "primary": ["used_percent": 99]]]]))
    #expect(parser.latestLimits == nil)
    #expect(parser.session(archived: false)?.contextFraction == nil)
    #expect(TokenTotals().cacheHit == nil)
}

@Test func accountResponsePrefersCodexBucketAndKeepsNullWindowsUnknown() throws {
    let response: [String: Any] = [
        "rateLimits": ["limitId": "other-model", "primary": ["usedPercent": 99]],
        "rateLimitsByLimitId": ["codex": ["planType": "plus", "primary": ["usedPercent": 35, "windowDurationMins": 300, "resetsAt": 1790768590], "secondary": NSNull()]]
    ]
    let result = try CodexAccountService.parseResponse(line(response))
    #expect(result.primary?.fraction == 0.35)
    #expect(result.primary?.windowDurationMins == 300)
    #expect(result.secondary == nil)
    #expect(result.source == "Account API")
    #expect(throws: ToolError.self) { try CodexAccountService.parseResponse(line(["rateLimits": ["primary": NSNull(), "secondary": NSNull()]])) }
}

@Test func incrementalScanWaitsForCompleteLinesAndHandlesTruncationAndArchiveDuplicates() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let active = root.appendingPathComponent("sessions")
    let archived = root.appendingPathComponent("archived_sessions")
    try FileManager.default.createDirectory(at: active, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
    let path = active.appendingPathComponent("rollout.jsonl")
    var data = try meta(); data.append(10)
    let event = try record(counters(100, 20), id: "r1")
    let split = event.count / 2
    data.append(event.prefix(split))
    try data.write(to: path)
    let service = CodexLogService()
    #expect(try await service.scan(root: root).totals.total == 0)
    let handle = try FileHandle(forWritingTo: path)
    try handle.seekToEnd()
    var tail = Data(event.suffix(event.count - split)); tail.append(10)
    try handle.write(contentsOf: tail); try handle.close()
    let result = try await service.scan(root: root)
    #expect(result.totals.total == 120)
    #expect(try await service.scan(root: root).totals.total == 120)
    try FileManager.default.copyItem(at: path, to: archived.appendingPathComponent("copy.jsonl"))
    #expect(try await service.scan(root: root).sessions.count == 1)
    #expect(try await service.scan(root: root).totals.total == 120)
    try FileManager.default.removeItem(at: archived.appendingPathComponent("copy.jsonl"))
    var replacement = try meta(); replacement.append(10)
    replacement.append(try record(counters(5, 1), id: "r2")); replacement.append(10)
    try replacement.write(to: path)
    #expect(try await service.scan(root: root).totals.total == 6)
    try FileManager.default.removeItem(at: path)
    #expect(try await service.scan(root: root).sessions.isEmpty)
}

@Test func accountBridgePerformsReadOnlyHandshakeAndHandlesSubprocessTimeout() async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("yukino-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: path) }
    let script = #"""
    #!/bin/sh
    while IFS= read -r request; do
      case "$request" in
        *'"initialize"'*) printf '%s\n' '{"id":1,"result":{}}' ;;
        *'"initialized"'*) ;;
        *'account/rateLimits/read'*) printf '%s\n' '{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":7,"windowDurationMins":300}}}}' ;;
        *) exit 42 ;;
      esac
    done
    """#
    try Data(script.utf8).write(to: path)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
    let result = try await CodexAccountService.fetch(executable: path, timeout: 2)
    #expect(result.primary?.usedPercent == 7)
    try Data("#!/bin/sh\nexec /bin/sleep 30\n".utf8).write(to: path)
    let started = Date()
    do { _ = try await CodexAccountService.fetch(executable: path, timeout: 0.1); Issue.record("Should time out") } catch {}
    #expect(Date().timeIntervalSince(started) < 3)
}

@Test func paginatedLogsMergeDisjointResponsesAndArchiveCopiesWithoutInheritedCounters() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let active = root.appendingPathComponent("sessions")
    let archived = root.appendingPathComponent("archived_sessions")
    try FileManager.default.createDirectory(at: active, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
    var first = try meta(); first.append(10)
    first.append(try record(counters(100, 20), id: "first")); first.append(10)
    first.append(try legacy(counters(100, 20))); first.append(10)
    try first.write(to: archived.appendingPathComponent("page1.jsonl"))
    var second = try line(["type": "session_meta", "payload": ["id": "session-a", "cwd": "/projects/Yukino", "history_base": ["thread_id": "session-a", "end_ordinal_exclusive": 10]]]); second.append(10)
    // This snapshot includes tokens from the previous page; it is not new activity.
    second.append(try legacy(counters(100, 20), time: "2026-09-30T06:02:00Z")); second.append(10)
    second.append(try record(counters(50, 10), id: "second", time: "2026-09-30T06:03:00Z")); second.append(10)
    second.append(try legacy(counters(150, 30), last: counters(50, 10), time: "2026-09-30T06:03:01Z")); second.append(10)
    try second.write(to: active.appendingPathComponent("page2.jsonl"))
    try second.write(to: archived.appendingPathComponent("page2-copy.jsonl"))
    let result = try await CodexLogService().scan(root: root)
    #expect(result.sessions.count == 1)
    #expect(result.events.count == 2)
    #expect(result.totals.total == 180)
    #expect(result.sessions.first?.tokens.total == 180)
    #expect(result.sessions.first?.archived == false)
}
