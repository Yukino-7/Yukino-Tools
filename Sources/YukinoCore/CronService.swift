import Foundation

public enum CronDialect: String, CaseIterable, Sendable {
    case standard = "标准 Cron（5 字段）"
    case quartz = "Quartz（6 / 7 字段）"
}

public struct CronFieldInfo: Sendable {
    public let name: String
    public let expression: String
    public let explanation: String
}

/// Preview only: this service never registers or runs a system task.
public struct CronSchedule: Sendable {
    public let dialect: CronDialect
    public let expression: String
    public let fields: [CronFieldInfo]
    private let seconds: Field
    private let minutes: Field
    private let hours: Field
    private let days: DayRule
    private let months: Field
    private let weekdays: DayRule
    private let years: Field
    private let dayWildcard: Bool
    private let weekdayWildcard: Bool

    private struct Field: Sendable {
        let values: Set<Int>
        let summary: String
    }
    private enum DayRule: Sendable {
        case unspecified, values(Set<Int>), lastDay(Int), nearestWeekday(Int), lastWeekday
        case lastOccurrence(Int), nthOccurrence(Int, Int)
    }

    public init(_ input: String, dialect: CronDialect = .standard) throws {
        self.dialect = dialect
        guard input.utf8.count <= 512 else { throw ToolError.invalid("Cron 表达式不能超过 512 字节。") }
        let parts = input.uppercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard dialect == .standard ? parts.count == 5 : (parts.count == 6 || parts.count == 7) else {
            throw ToolError.invalid(dialect == .standard ? "标准 Cron 需要 5 个字段：分 时 日 月 星期。" : "Quartz 需要 6 或 7 个字段：秒 分 时 日 月 星期 [年]。")
        }
        expression = parts.joined(separator: " ")
        let tokens = dialect == .standard ? ["0"] + parts : parts
        seconds = try Self.parse(tokens[0], range: 0...59, name: "秒")
        minutes = try Self.parse(tokens[1], range: 0...59, name: "分")
        hours = try Self.parse(tokens[2], range: 0...23, name: "时")
        let monthNames = Dictionary(uniqueKeysWithValues: ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"].enumerated().map { ($1, $0 + 1) })
        let weekdayNames = Dictionary(uniqueKeysWithValues: ["SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"].enumerated().map { ($1, $0 + (dialect == .standard ? 0 : 1)) })
        months = try Self.parse(tokens[4], range: 1...12, name: "月", names: monthNames)
        years = try Self.parse(tokens.count == 7 ? tokens[6] : "*", range: 1970...2099, name: "年")
        if dialect == .quartz {
            guard (tokens[3] == "?") != (tokens[5] == "?") else {
                throw ToolError.invalid("Quartz 的“日”和“星期”必须恰好有一个使用 ?，另一个指定规则。")
            }
        }
        days = try Self.parseDay(tokens[3], weekday: false, dialect: dialect, names: [:])
        weekdays = try Self.parseDay(tokens[5], weekday: true, dialect: dialect, names: weekdayNames)
        dayWildcard = tokens[3].contains("*")
        weekdayWildcard = tokens[5].contains("*")
        var details = [CronFieldInfo]()
        if dialect == .quartz { details.append(.init(name: "秒", expression: tokens[0], explanation: seconds.summary)) }
        details += [
            .init(name: "分", expression: tokens[1], explanation: minutes.summary),
            .init(name: "时", expression: tokens[2], explanation: hours.summary),
            .init(name: "日", expression: tokens[3], explanation: Self.describe(days, source: tokens[3])),
            .init(name: "月", expression: tokens[4], explanation: months.summary),
            .init(name: "星期", expression: tokens[5], explanation: Self.describe(weekdays, source: tokens[5], weekday: true))
        ]
        if tokens.count == 7 { details.append(.init(name: "年", expression: tokens[6], explanation: years.summary)) }
        fields = details
    }

    public var explanation: String {
        let time = hours.values.count == 1 && minutes.values.count == 1 && seconds.values.count == 1
            ? String(format: "%02d:%02d:%02d", hours.values.first!, minutes.values.first!, seconds.values.first!)
            : "符合下列时间字段时"
        let dayText: String
        if dialect == .standard {
            if dayWildcard && weekdayWildcard { dayText = "按日与星期规则共同筛选" }
            else if !dayWildcard && !weekdayWildcard { dayText = "日期或星期任意一个匹配" }
            else { dayText = "按指定日期或星期筛选" }
        } else { dayText = "按非 ? 的日期规则筛选" }
        return "在所选时区，\(time) 执行；\(dayText)，同时满足月份\(fields.contains { $0.name == "年" } ? "与年份" : "")规则。"
    }

    /// Strictly after `after`, through 2099. Walk actual minutes to preserve both
    /// occurrences of a repeated DST hour and skip nonexistent wall-clock times.
    public func nextDates(after: Date, timeZone: TimeZone, count: Int = 10) throws -> [Date] {
        guard (1...100).contains(count), after.timeIntervalSince1970.isFinite,
              after.timeIntervalSince1970 >= 0, after.timeIntervalSince1970 < 4102444800 else {
            throw ToolError.invalid("预览起点须在 1970–2099 年内，结果数量须为 1–100。")
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var day = calendar.startOfDay(for: after)
        var output: [Date] = []
        let sortedSeconds = seconds.values.sorted()
        let startingMinute = calendar.dateInterval(of: .minute, for: after)?.start ?? after
        while calendar.component(.year, from: day) <= 2099 {
            if Task.isCancelled { throw CancellationError() }
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: day), nextDay > day else { break }
            let components = calendar.dateComponents([.year, .month, .day, .weekday], from: day)
            if years.values.contains(components.year!), months.values.contains(components.month!), matchesDay(day, calendar: calendar) {
                var minute = max(day, startingMinute)
                while minute < nextDay {
                    if Task.isCancelled { throw CancellationError() }
                    let time = calendar.dateComponents([.hour, .minute], from: minute)
                    if hours.values.contains(time.hour!), minutes.values.contains(time.minute!) {
                        for second in sortedSeconds {
                            let candidate = minute.addingTimeInterval(Double(second))
                            if candidate > after && candidate < nextDay {
                                output.append(candidate)
                                if output.count == count { return output }
                            }
                        }
                    }
                    minute = minute.addingTimeInterval(60)
                }
            }
            day = nextDay
        }
        return output
    }

    private func matchesDay(_ date: Date, calendar: Calendar) -> Bool {
        let day = calendar.component(.day, from: date)
        let weekday = calendar.component(.weekday, from: date)
        let last = calendar.range(of: .day, in: .month, for: date)!.count
        func matches(_ rule: DayRule, isWeekday: Bool) -> Bool {
            switch rule {
            case .unspecified: return true
            case .values(let values): return values.contains(isWeekday ? weekday : day)
            case .lastDay(let offset): return day == last - offset
            case .lastWeekday: return day == nearestWeekday(last)
            case .nearestWeekday(let target): return target <= last && day == nearestWeekday(target)
            case .lastOccurrence(let target): return weekday == target && day + 7 > last
            case .nthOccurrence(let target, let occurrence): return weekday == target && (day - 1) / 7 + 1 == occurrence
            }
        }
        func nearestWeekday(_ target: Int) -> Int {
            let targetDate = calendar.date(byAdding: .day, value: target - day, to: date)!
            switch calendar.component(.weekday, from: targetDate) {
            case 7: return target == 1 ? 3 : target - 1
            case 1: return target == last ? target - 2 : target + 1
            default: return target
            }
        }
        let dom = matches(days, isWeekday: false), dow = matches(weekdays, isWeekday: true)
        return dialect == .standard && !dayWildcard && !weekdayWildcard ? dom || dow : dom && dow
    }

    private static func parse(_ text: String, range: ClosedRange<Int>, name: String, names: [String: Int] = [:]) throws -> Field {
        func fail() -> ToolError { .invalid("\(name)字段“\(text)”无效；允许 \(range.lowerBound)–\(range.upperBound)、列表、递增区间和步长。") }
        func number(_ source: String) throws -> Int {
            if let named = names[source] { return named }
            guard !source.isEmpty, source.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(source), range.contains(value) else { throw fail() }
            return value
        }
        var values: Set<Int> = []
        for item in text.split(separator: ",", omittingEmptySubsequences: false).map(String.init) {
            let stepParts = item.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard (1...2).contains(stepParts.count) else { throw fail() }
            let step: Int
            if stepParts.count == 2 {
                guard stepParts[1].allSatisfy({ $0.isASCII && $0.isNumber }), let parsed = Int(stepParts[1]), parsed > 0, parsed <= range.count else { throw fail() }
                step = parsed
            } else { step = 1 }
            let bounds = stepParts[0].split(separator: "-", omittingEmptySubsequences: false).map(String.init)
            let lower: Int, upper: Int
            if stepParts[0] == "*" { lower = range.lowerBound; upper = range.upperBound }
            else if bounds.count == 2 { lower = try number(bounds[0]); upper = try number(bounds[1]) }
            else if bounds.count == 1 { lower = try number(bounds[0]); upper = stepParts.count == 2 ? range.upperBound : lower }
            else { throw fail() }
            guard lower <= upper else { throw fail() }
            values.formUnion(stride(from: lower, through: upper, by: step))
        }
        guard !values.isEmpty else { throw fail() }
        let summary: String
        if text == "*" { summary = "每个\(name)" }
        else if text.hasPrefix("*/"), let step = Int(text.dropFirst(2)) { summary = "每隔 \(step) 个\(name)，从 \(range.lowerBound) 开始（在本字段内重复）" }
        else { summary = "取值：" + values.sorted().map(String.init).joined(separator: "、") }
        return Field(values: values, summary: summary)
    }

    private static func parseDay(_ text: String, weekday: Bool, dialect: CronDialect, names: [String: Int]) throws -> DayRule {
        let range = weekday ? (dialect == .standard ? 0...7 : 1...7) : 1...31
        let name = weekday ? "星期" : "日"
        if dialect == .quartz {
            if text == "?" { return .unspecified }
            if !weekday {
                if text == "L" { return .lastDay(0) }
                if text == "LW" { return .lastWeekday }
                if text.hasPrefix("L-"), let n = Int(text.dropFirst(2)), (0...30).contains(n), String(n) == String(text.dropFirst(2)) { return .lastDay(n) }
                if text.hasSuffix("W"), let n = Int(text.dropLast()), (1...31).contains(n), String(n) == String(text.dropLast()) { return .nearestWeekday(n) }
            } else {
                if text == "L" { return .values([7]) }
                if text.hasSuffix("L") {
                    let prefix = String(text.dropLast())
                    guard names[prefix] != nil || (!prefix.isEmpty && prefix.allSatisfy({ $0.isASCII && $0.isNumber })) else { throw ToolError.invalid("星期 L 前须为单个星期值。") }
                    let field = try parse(prefix, range: range, name: name, names: names)
                    guard field.values.count == 1 else { throw ToolError.invalid("星期 L 前须为单个星期值。") }
                    return .lastOccurrence(field.values.first!)
                }
                if text.contains("#") {
                    let parts = text.split(separator: "#", omittingEmptySubsequences: false)
                    guard parts.count == 2, let n = Int(parts[1]), (1...5).contains(n), String(n) == parts[1] else { throw ToolError.invalid("# 后须为 1–5，表示当月第几个星期。") }
                    let prefix = String(parts[0])
                    guard names[prefix] != nil || (!prefix.isEmpty && prefix.allSatisfy({ $0.isASCII && $0.isNumber })) else { throw ToolError.invalid("# 前须为单个星期值。") }
                    let field = try parse(prefix, range: range, name: name, names: names)
                    guard field.values.count == 1 else { throw ToolError.invalid("# 前须为单个星期值。") }
                    return .nthOccurrence(field.values.first!, n)
                }
            }
        }
        let field = try parse(text, range: range, name: name, names: names)
        return .values(Set(field.values.map { weekday && dialect == .standard ? ($0 % 7) + 1 : $0 }))
    }

    private static func describe(_ rule: DayRule, source: String, weekday: Bool = false) -> String {
        switch rule {
        case .unspecified: return "不指定，使用另一个日期字段"
        case .lastDay(let n): return n == 0 ? "每月最后一天" : "每月最后一天向前 \(n) 天"
        case .nearestWeekday(let day): return "离每月 \(day) 日最近的工作日（周一至周五，不跨月）"
        case .lastWeekday: return "每月最后一个工作日（周一至周五）"
        case .lastOccurrence(let day): return "每月最后一个\(weekdayName(day))"
        case .nthOccurrence(let day, let n): return "每月第 \(n) 个\(weekdayName(day))"
        case .values(let values):
            if source == "*" { return "任意值" }
            return weekday ? values.sorted().map(weekdayName).joined(separator: "、") : "每月 " + values.sorted().map(String.init).joined(separator: "、") + " 日"
        }
    }
    private static func weekdayName(_ value: Int) -> String { ["周日", "周一", "周二", "周三", "周四", "周五", "周六"][value - 1] }
}
