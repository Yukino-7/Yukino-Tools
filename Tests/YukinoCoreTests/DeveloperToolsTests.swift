import Foundation
import Testing
@testable import YukinoCore

private func instant(_ string: String) -> Date { ISO8601DateFormatter().date(from: string)! }
private let utcZone = TimeZone(secondsFromGMT: 0)!
private func dates(_ expression: String, after: String, dialect: CronDialect = .standard, zone: TimeZone = utcZone, count: Int = 1) throws -> [Date] {
    try CronSchedule(expression, dialect: dialect).nextDates(after: instant(after), timeZone: zone, count: count)
}

@Test func cronStandardStepsListsNamesAndStrictlyFutureResults() throws {
    let actual = try dates("*/15 9-10 * jan,oct mon-fri", after: "2026-10-21T09:00:00Z", count: 3)
    #expect(actual == ["2026-10-21T09:15:00Z", "2026-10-21T09:30:00Z", "2026-10-21T09:45:00Z"].map(instant))
    #expect(try dates("5/20 * * * *", after: "2026-10-21T09:25:00Z").first == instant("2026-10-21T09:45:00Z"))
    #expect(try dates("0 9 * * 0", after: "2026-10-21T00:00:00Z") == dates("0 9 * * 7", after: "2026-10-21T00:00:00Z"))
}

@Test func cronStandardRestrictedDaysUseOrAndWildcardDaysUseAnd() throws {
    let actual = try dates("0 9 1 * MON", after: "2026-10-30T00:00:00Z", count: 3)
    #expect(actual == ["2026-11-01T09:00:00Z", "2026-11-02T09:00:00Z", "2026-11-09T09:00:00Z"].map(instant))
    // */2 is a restricted wildcard, not an independent OR rule.
    #expect(try dates("0 9 */2 * MON", after: "2026-11-01T00:00:00Z").first == instant("2026-11-09T09:00:00Z"))
}

@Test func cronQuartzSecondsAndOptionalYear() throws {
    #expect(try dates("0/10 * * * * ?", after: "2026-10-21T09:00:10Z", dialect: .quartz, count: 2) == [instant("2026-10-21T09:00:20Z"), instant("2026-10-21T09:00:30Z")])
    #expect(try dates("0 0 9 1 JAN ? 2028", after: "2026-10-21T09:00:00Z", dialect: .quartz, count: 10) == [instant("2028-01-01T09:00:00Z")])
    #expect(try dates("0 0 9 ? * 1", after: "2026-10-21T00:00:00Z", dialect: .quartz).first == instant("2026-10-25T09:00:00Z"))
}

@Test func cronQuartzMonthEndAndLeapYears() throws {
    #expect(try dates("0 0 9 L FEB ?", after: "2028-02-01T00:00:00Z", dialect: .quartz).first == instant("2028-02-29T09:00:00Z"))
    #expect(try dates("0 0 9 L-2 FEB ?", after: "2027-02-01T00:00:00Z", dialect: .quartz).first == instant("2027-02-26T09:00:00Z"))
    #expect(try dates("0 0 9 LW * ?", after: "2026-10-01T00:00:00Z", dialect: .quartz).first == instant("2026-10-30T09:00:00Z"))
    #expect(try dates("0 9 29 FEB *", after: "2026-10-21T00:00:00Z").first == instant("2028-02-29T09:00:00Z"))
}

@Test func cronQuartzNearestWeekdayDoesNotCrossMonth() throws {
    #expect(try dates("0 0 9 1W * ?", after: "2026-08-01T00:00:00Z", dialect: .quartz).first == instant("2026-08-03T09:00:00Z"))
    #expect(try dates("0 0 9 31W * ?", after: "2026-05-01T00:00:00Z", dialect: .quartz).first == instant("2026-05-29T09:00:00Z"))
    #expect(try dates("0 0 9 31W * ?", after: "2026-04-01T00:00:00Z", dialect: .quartz).first == instant("2026-05-29T09:00:00Z"))
}

@Test func cronQuartzLastAndNthWeekdays() throws {
    #expect(try dates("0 0 9 ? * FRIL", after: "2026-10-01T00:00:00Z", dialect: .quartz).first == instant("2026-10-30T09:00:00Z"))
    #expect(try dates("0 0 9 ? * FRI#3", after: "2026-10-01T00:00:00Z", dialect: .quartz).first == instant("2026-10-16T09:00:00Z"))
    #expect(try dates("0 0 9 ? * MON#5", after: "2026-02-01T00:00:00Z", dialect: .quartz).first == instant("2026-03-30T09:00:00Z"))
    #expect(try dates("0 0 9 ? * L", after: "2026-10-01T00:00:00Z", dialect: .quartz).first == instant("2026-10-03T09:00:00Z"))
}

@Test func cronTimezoneAndDSTSkipMissingTimesAndPreserveRepeatedInstants() throws {
    #expect(try dates("0 9 * * *", after: "2026-10-21T00:00:00Z", zone: TimeZone(identifier: "Asia/Shanghai")!).first == instant("2026-10-21T01:00:00Z"))
    let ny = TimeZone(identifier: "America/New_York")!
    #expect(try dates("30 2 * * *", after: "2026-03-08T00:00:00Z", zone: ny).first == instant("2026-03-09T06:30:00Z"))
    #expect(try dates("30 1 * * *", after: "2026-11-01T00:00:00Z", zone: ny, count: 2) == [instant("2026-11-01T05:30:00Z"), instant("2026-11-01T06:30:00Z")])
    #expect(try dates("30 1 * * *", after: "2026-11-01T05:45:00Z", zone: ny).first == instant("2026-11-01T06:30:00Z"))
}

@Test func cronRejectsUnsupportedAndMalformedExpressions() throws {
    for expression in ["", "* * * *", "60 * * * *", "*/0 * * * *", "1,,2 * * * *", "0 9 ? * *", "0 9 * * 8", "0 9 * FOO MON", "0 9-2 * * *", "0 9 * * MON echo hi", "@daily"] {
        #expect(throws: ToolError.self) { try CronSchedule(expression) }
    }
    for expression in ["0 0 9 * * *", "0 0 9 ? * ?", "0 0 9 ? * 0", "0 0 9 ? * MON#6", "0 0 9 ? * 1-1L", "0 0 9 ? * 1/7#2", "0 0 9 15W,16W * ?", "0 0 9 L-31 * ?", "0 0 9 * * ? 2100"] {
        #expect(throws: ToolError.self) { try CronSchedule(expression, dialect: .quartz) }
    }
}

@Test func cronImpossibleDatesExhaustHorizonWithoutInventingResults() throws {
    #expect(try dates("0 9 31 FEB *", after: "2026-10-21T00:00:00Z", count: 10).isEmpty)
    #expect(try dates("0 0 9 1 JAN ? 2020", after: "2026-10-21T00:00:00Z", dialect: .quartz).isEmpty)
    #expect(try dates("* * * * *", after: "2099-12-31T23:58:00Z", count: 10) == [instant("2099-12-31T23:59:00Z")])
}

private func jwtToken(header: String = #"{"alg":"HS256","typ":"JWT"}"#, payload: String, signature: String = "c2ln") -> String {
    func encode(_ text: String) -> String { Data(text.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    return encode(header) + "." + encode(payload) + "." + signature
}

@Test func jwtDecodesUnicodeBearerPrefixAndPreservesExactPayloadNumbers() throws {
    let doc = try JWTService.decode("  Bearer " + jwtToken(payload: #"{"sub":"雪乃😀","id":9007199254740993,"exp":1792627200}"#) + "\n")
    #expect(doc.algorithm == "HS256")
    #expect(doc.signatureBytes == 3)
    #expect(doc.payload.contains("雪乃😀"))
    #expect(doc.payload.contains("9007199254740993"))
    #expect(doc.expiration == Date(timeIntervalSince1970: 1792627200))
}

@Test func jwtTimeBoundariesAndFractionalNumericDates() throws {
    let doc = try JWTService.decode(jwtToken(payload: #"{"nbf":1000.5,"exp":2000.5,"iat":5000}"#))
    #expect(doc.timeState(at: Date(timeIntervalSince1970: 1000.4)) == .notYetValid)
    #expect(doc.timeState(at: Date(timeIntervalSince1970: 1000.5)) == .withinTimeWindow)
    #expect(doc.timeState(at: Date(timeIntervalSince1970: 2000.5)) == .expired)
    #expect(try JWTService.decode(jwtToken(payload: #"{"sub":"user"}"#)).timeState(at: .now) == .noExpiration)
}

@Test func jwtInvalidTimeClaimsRemainVisibleAndNeverBecomeValid() throws {
    for value in ["true", "false", "null", "\"2000\"", "1792627200000", "{}"] {
        let doc = try JWTService.decode(jwtToken(payload: "{\"exp\":\(value)}"))
        #expect(doc.invalidDateClaims)
        #expect(!doc.warnings.isEmpty)
        #expect(doc.timeState(at: .now) == .invalidTimeClaims)
        #expect(!doc.payload.isEmpty)
    }
    let doc = try JWTService.decode(jwtToken(payload: #"{"nbf":2000,"exp":1000}"#))
    #expect(!doc.warnings.isEmpty)
    #expect(doc.timeState(at: Date(timeIntervalSince1970: 1500)) == .expired)
}

@Test func jwtUnsignedExampleAndUnsupportedHeadersAreExplicit() throws {
    let doc = try JWTService.decode(JWTService.example)
    #expect(doc.algorithm == "none")
    #expect(doc.signatureBytes == 0)
    #expect(!doc.warnings.isEmpty)
    #expect(throws: ToolError.self) { try JWTService.decode(jwtToken(header: #"{"alg":"none"}"#, payload: "{}")) }
    #expect(throws: ToolError.self) { try JWTService.decode(jwtToken(header: #"{"alg":"HS256","b64":false}"#, payload: "{}")) }
    #expect(try !JWTService.decode(jwtToken(header: #"{"alg":"HS256","crit":["custom"]}"#, payload: "{}")).warnings.isEmpty)
}

@Test func jwtRejectsBrokenSegmentsNonObjectsAndJWE() throws {
    for value in ["", "a.b", "a.b.c.d.e", "!.e30.c2ln", "e30=.e30.c2ln", jwtToken(payload: "[]"), jwtToken(payload: "null"), jwtToken(header: "{}", payload: "{}"), jwtToken(payload: "{}", signature: ""), jwtToken(payload: "{}", signature: "a")] {
        #expect(throws: ToolError.self) { try JWTService.decode(value) }
    }
    #expect(throws: ToolError.self) { try JWTService.decode(String(repeating: "a", count: 262_145)) }
}

@Test func regexUTF16RangesCapturesAndReplacementRemainCorrectAroundEmoji() throws {
    let result = try RegexService.evaluate(pattern: #"(雪乃)-(\d+)"#, text: "😀雪乃-42！", replacement: "$2:$1")
    #expect(result.matches.count == 1)
    #expect(result.matches[0].range == NSRange(location: 2, length: 5))
    #expect(result.matches[0].captures.map(\.text) == ["雪乃", "42"])
    #expect(result.replacement == "😀42:雪乃！")
}

@Test func regexOptionsAndUnmatchedGroupsHaveDistinctBehavior() throws {
    #expect(try RegexService.evaluate(pattern: "^hello$", text: "HELLO\nworld", options: .init(ignoreCase: true, multiline: true)).matches.count == 1)
    #expect(try RegexService.evaluate(pattern: "a.b", text: "a\nb", options: .init(dotMatchesNewline: true)).matches.count == 1)
    #expect(try RegexService.evaluate(pattern: "a.b", text: "a\nb").matches.isEmpty)
    let optional = try RegexService.evaluate(pattern: "(a)?b(c*)", text: "b")
    #expect(optional.matches[0].captures[0].text == nil)
    #expect(optional.matches[0].captures[1].text == "")
}

@Test func regexZeroWidthMatchesAndEscapedReplacementAreSupported() throws {
    let zero = try RegexService.evaluate(pattern: "(?=a)", text: "aa", replacement: "X")
    #expect(zero.matches.map(\.range.length) == [0, 0])
    #expect(zero.replacement == "XaXa")
    #expect(try RegexService.evaluate(pattern: "(a)", text: "a", replacement: #"\$1-$1"#).replacement == "$1-a")
    #expect(try RegexService.evaluate(pattern: "x", text: "abc", replacement: "z").replacement == "abc")
    #expect(try RegexService.evaluate(pattern: "a", text: "aba").replacement == "b")
}

@Test func regexTruncationDoesNotReturnMisleadingPartialReplacement() throws {
    let capped = try RegexService.evaluate(pattern: "a", text: "aaa", replacement: "b", maximumMatches: 2)
    #expect(capped.matches.count == 2)
    #expect(capped.truncated)
    #expect(capped.replacement == nil)
    let exact = try RegexService.evaluate(pattern: "a", text: "aa", maximumMatches: 2)
    #expect(!exact.truncated)
    #expect(exact.replacement == "")
}

@Test func regexMalformedPatternsAndInputLimitsReturnErrors() throws {
    #expect(throws: ToolError.self) { try RegexService.evaluate(pattern: "[", text: "abc") }
    #expect(throws: ToolError.self) { try RegexService.evaluate(pattern: "", text: "abc") }
    #expect(throws: ToolError.self) { try RegexService.evaluate(pattern: "a", text: String(repeating: "a", count: 100_001)) }
    #expect(throws: ToolError.self) { try RegexService.evaluate(pattern: String(repeating: "()", count: 101), text: "abc") }
    #expect(throws: ToolError.self) { try RegexService.evaluate(pattern: "a", text: String(repeating: "a", count: 1000), replacement: String(repeating: "b", count: 2000)) }
}

@Test func regexPathologicalBacktrackingHonorsDeadline() throws {
    let start = ProcessInfo.processInfo.systemUptime
    #expect(throws: ToolError.self) { try RegexService.evaluate(pattern: "(a+)+$", text: String(repeating: "a", count: 500) + "!", timeout: 0.02) }
    #expect(ProcessInfo.processInfo.systemUptime - start < 2)
}

@Test func developerToolComputationsHonorCancellation() async throws {
    let worker = Task.detached {
        while !Task.isCancelled { await Task.yield() }
        return try RegexService.evaluate(pattern: "a", text: "a")
    }
    worker.cancel()
    do { _ = try await worker.value; Issue.record("Cancelled regex evaluation unexpectedly succeeded") }
    catch is CancellationError {} catch { Issue.record("Unexpected error: \(error)") }
    let cron = Task.detached {
        while !Task.isCancelled { await Task.yield() }
        return try CronSchedule("0 9 31 FEB *").nextDates(after: instant("2026-10-21T00:00:00Z"), timeZone: utcZone)
    }
    cron.cancel()
    do { _ = try await cron.value; Issue.record("Cancelled Cron evaluation unexpectedly succeeded") }
    catch is CancellationError {} catch { Issue.record("Unexpected error: \(error)") }
}
