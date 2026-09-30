import Foundation

public struct TokenTotals: Codable, Equatable, Sendable {
    public var input: Int64
    public var cached: Int64
    public var output: Int64
    public var reasoning: Int64
    public var total: Int64 { input + output }
    public var cacheHit: Double? { input > 0 ? min(1, Double(cached) / Double(input)) : nil }
    public init(input: Int64 = 0, cached: Int64 = 0, output: Int64 = 0, reasoning: Int64 = 0) {
        self.input = input; self.cached = cached; self.output = output; self.reasoning = reasoning
    }
    public static func + (left: Self, right: Self) -> Self {
        Self(input: left.input + right.input, cached: left.cached + right.cached,
             output: left.output + right.output, reasoning: left.reasoning + right.reasoning)
    }
    func delta(after previous: Self) -> Self {
        // Counters can restart when a session is resumed by a different CLI version.
        if input < previous.input || output < previous.output { return self }
        return Self(input: input - previous.input, cached: max(0, cached - previous.cached),
                    output: output - previous.output, reasoning: max(0, reasoning - previous.reasoning))
    }
}

public struct CodexUsageEvent: Sendable {
    public let id: String
    public let sessionID: String
    public let date: Date
    public let tokens: TokenTotals
}

public struct CodexSession: Identifiable, Sendable {
    public let id: String
    public let project: String
    public let directory: String
    public let model: String?
    public let source: String?
    public let lastActivity: Date
    public let tokens: TokenTotals
    public let contextTokens: Int64?
    public let contextWindow: Int64?
    public var contextFraction: Double? {
        guard let contextTokens, let contextWindow, contextWindow > 0 else { return nil }
        return min(1, Double(contextTokens) / Double(contextWindow))
    }
    public let archived: Bool
}

public struct CodexLimitWindow: Codable, Equatable, Sendable {
    public let usedPercent: Double
    public let windowDurationMins: Int?
    public let resetsAt: Double?
    public var fraction: Double { min(1, max(0, usedPercent / 100)) }
    public var resetDate: Date? { resetsAt.map { Date(timeIntervalSince1970: $0) } }
    public init(usedPercent: Double, windowDurationMins: Int? = nil, resetsAt: Double? = nil) {
        self.usedPercent = usedPercent; self.windowDurationMins = windowDurationMins; self.resetsAt = resetsAt
    }
}

public struct CodexLimits: Codable, Equatable, Sendable {
    public let primary: CodexLimitWindow?
    public let secondary: CodexLimitWindow?
    public let planType: String?
    public let capturedAt: Date
    public let source: String
    public init(primary: CodexLimitWindow?, secondary: CodexLimitWindow?, planType: String?, capturedAt: Date, source: String) {
        self.primary = primary; self.secondary = secondary; self.planType = planType
        self.capturedAt = capturedAt; self.source = source
    }
}

public struct CodexLocalSnapshot: Sendable {
    public let sessions: [CodexSession]
    public let events: [CodexUsageEvent]
    public let latestLimits: CodexLimits?
    public let scannedFiles: Int
    public let malformedLines: Int
    public let unreadableFiles: Int
    public var totals: TokenTotals { events.reduce(TokenTotals()) { $0 + $1.tokens } }
    public func totals(since date: Date) -> TokenTotals {
        events.filter { $0.date >= date }.reduce(TokenTotals()) { $0 + $1.tokens }
    }
    public init(sessions: [CodexSession] = [], events: [CodexUsageEvent] = [], latestLimits: CodexLimits? = nil,
                scannedFiles: Int = 0, malformedLines: Int = 0, unreadableFiles: Int = 0) {
        self.sessions = sessions; self.events = events; self.latestLimits = latestLimits
        self.scannedFiles = scannedFiles; self.malformedLines = malformedLines; self.unreadableFiles = unreadableFiles
    }
}

public enum CodexDates {
    public static func parse(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}
