import Foundation
import Testing
@testable import YukinoCore

@Test func jsonRoundTripPreservesUnicodeAndStructure() throws {
    let input = #"{"emoji":"☃️","path":"/tmp/yukino","list":[true,null,4],"中文":"雪乃"}"#
    let formatted = try JSONService.transform(input)
    #expect(formatted.contains("\n"))
    let compact = try JSONService.transform(formatted, minify: true)
    #expect(!compact.contains("\n"))
    let original = try JSONSerialization.jsonObject(with: Data(input.utf8)) as! NSDictionary
    let result = try JSONSerialization.jsonObject(with: Data(compact.utf8)) as! NSDictionary
    #expect(original == result)
}

@Test func jsonSupportsScalarFragmentsAndReportsInvalidInput() throws {
    #expect(try JSONService.transform("42", minify: true) == "42")
    #expect(try JSONService.transform("null") == "null")
    #expect(throws: ToolError.self) { try JSONService.transform("{\"a\":}") }
    #expect(throws: ToolError.self) { try JSONService.transform("   ") }
}

@Test func base64RoundTripAndRejectsBinaryOrMalformedData() throws {
    let text = "Hello, 雪乃 👋\nsecond line"
    let encoded = Base64Service.encode(text)
    #expect(try Base64Service.decode(" \n" + encoded + "\n") == text)
    #expect(throws: ToolError.self) { try Base64Service.decode("%%invalid") }
    #expect(throws: ToolError.self) { try Base64Service.decode("/w==") }
    #expect(try Base64Service.decode("") == "")
}

@Test func timestampUTCMatchesKnownEpochAndMilliseconds() throws {
    let epoch = try TimestampService.date(from: "0", unit: .seconds)
    #expect(TimestampService.formatter(utc: true).string(from: epoch) == "1970-01-01 00:00:00")
    let date = try TimestampService.parse("2026-09-30 06:40:00", utc: true)
    #expect(TimestampService.timestamp(from: date, unit: .seconds) == "1790750400")
    #expect(TimestampService.timestamp(from: date, unit: .milliseconds) == "1790750400000")
    #expect(try TimestampService.date(from: "1790750400000", unit: .milliseconds) == date)
}

@Test func timestampRejectsInvalidValuesAndCalendarDates() {
    #expect(throws: ToolError.self) { try TimestampService.date(from: "nan", unit: .seconds) }
    #expect(throws: ToolError.self) { try TimestampService.date(from: "1e99", unit: .seconds) }
    #expect(throws: ToolError.self) { try TimestampService.parse("2026-02-30 00:00:00", utc: true) }
    #expect(throws: ToolError.self) { try TimestampService.parse("2026-9-3 0:0:0", utc: true) }
}

@Test func uuidBatchIsUniqueV4AndEnforcesBounds() throws {
    let batch = try UUIDService.generate(count: 1000)
    #expect(Set(batch).count == 1000)
    for value in batch {
        #expect(UUID(uuidString: value) != nil)
        #expect(value[value.index(value.startIndex, offsetBy: 14)] == "4")
        #expect("89ab".contains(value[value.index(value.startIndex, offsetBy: 19)]))
    }
    let upper = try UUIDService.generate(count: 1, uppercase: true)[0]
    #expect(upper == upper.uppercased())
    #expect(throws: ToolError.self) { try UUIDService.generate(count: 0) }
    #expect(throws: ToolError.self) { try UUIDService.generate(count: 1001) }
}

@Test func portRejectsInvalidInputBeforeConnecting() async {
    do { _ = try await PortService.check(host: "https://localhost", port: "80"); Issue.record("URL should be rejected") } catch {}
    do { _ = try await PortService.check(host: "localhost", port: "65536"); Issue.record("Port should be rejected") } catch {}
    do { _ = try await PortService.check(host: "localhost", port: "0"); Issue.record("Zero port should be rejected") } catch {}
}

@Test func jsonFormattingPreservesExactNumbersEscapesAndKeyOrder() throws {
    let input = #"{"z":0.1,"a":9007199254740993123456789,"exp":1.2300e+20,"text":"a \"quote\" \\ path","empty":[],"object":{}}"#
    let output = try JSONService.transform(input)
    #expect(output.contains("0.1,"))
    #expect(!output.contains("0.10000000000000001"))
    #expect(try JSONService.transform(output, minify: true) == input)
    let array = try JSONService.transform("[ {}, [1, 2], [], true ]")
    #expect(try JSONService.transform(array, minify: true) == "[{},[1,2],[],true]")
}
