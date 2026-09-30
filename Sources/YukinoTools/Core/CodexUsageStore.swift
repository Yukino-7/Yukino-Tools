import SwiftUI
import YukinoCore

struct UsagePoint: Identifiable {
    let date: Date
    let tokens: Double
    var id: Date { date }
}

@MainActor final class CodexUsageStore: ObservableObject {
    @Published private(set) var local = CodexLocalSnapshot()
    @Published private(set) var limits: CodexLimits?
    @Published private(set) var scanning = false
    @Published private(set) var accountRefreshing = false
    @Published private(set) var localUpdatedAt: Date?
    @Published private(set) var accountError: String?
    @Published private(set) var localError: String?
    private let scanner = CodexLogService()
    private let defaults: UserDefaults
    private var pollingTask: Task<Void, Never>?
    private var accountRoot: String?
    private var accountCLI: String?

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    var dataPath: String {
        let configured = defaults.string(forKey: "codexDataPath") ?? ""
        let environment = ProcessInfo.processInfo.environment["CODEX_HOME"]
        return NSString(string: configured.isEmpty ? environment ?? "~/.codex" : configured).expandingTildeInPath
    }
    var ready: Bool { localUpdatedAt != nil }
    var latestSession: CodexSession? { local.sessions.first { $0.contextFraction != nil } }
    var todaySessions: Int {
        let today = Calendar.current.startOfDay(for: Date())
        return Set(local.events.filter { $0.date >= today }.map(\.sessionID)).count
    }
    var todayTotals: TokenTotals { local.totals(since: Calendar.current.startOfDay(for: Date())) }
    var limitIsRecorded: Bool { limits?.source != "Account API" || accountError != nil }
    var status: String {
        if scanning || accountRefreshing { return "Refreshing" }
        if localError != nil && limits == nil { return "Unavailable" }
        return limitIsRecorded ? "Local data" : "Connected"
    }
    func start() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.defaults.object(forKey: "codexAutoRefresh") == nil || self.defaults.bool(forKey: "codexAutoRefresh") || !self.ready {
                    await self.refresh()
                }
                let interval = max(15, self.defaults.integer(forKey: "codexRefreshInterval") == 0 ? 60 : self.defaults.integer(forKey: "codexRefreshInterval"))
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }
    func restartPolling() {
        pollingTask?.cancel()
        pollingTask = nil
        start()
    }
    func refresh() async {
        guard !scanning && !accountRefreshing else { return }
        let path = dataPath
        let customCLI = defaults.string(forKey: "codexCLIPath") ?? ""
        if accountRoot != path || accountCLI != customCLI {
            limits = nil; accountError = nil; local = CodexLocalSnapshot(); localUpdatedAt = nil
            accountRoot = path; accountCLI = customCLI
        }
        scanning = true
        accountRefreshing = true
        async let account = fetchAccount(customPath: customCLI)
        do {
            local = try await scanner.scan(root: URL(fileURLWithPath: path))
            localUpdatedAt = Date()
            localError = nil
        } catch { localError = error.localizedDescription }
        scanning = false
        let accountResult = await account
        switch accountResult {
        case .success(let current): limits = current; accountError = nil
        case .failure(let error):
            accountError = error.localizedDescription
            if let recorded = local.latestLimits, limits == nil || recorded.capturedAt > limits!.capturedAt { limits = recorded }
        }
        accountRefreshing = false
    }
    private func fetchAccount(customPath: String) async -> Result<CodexLimits, Error> {
        guard let executable = CodexAccountService.discoverExecutable(customPath: customPath) else {
            return .failure(ToolError.invalid("Codex CLI not found. Select the installed CLI in Settings → Codex."))
        }
        do { return .success(try await CodexAccountService.fetch(executable: executable)) }
        catch { return .failure(error) }
    }
    func points(days: Int) -> [UsagePoint] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let start = calendar.date(byAdding: .day, value: 1 - days, to: today)!
        var totals: [Date: Int64] = [:]
        for event in local.events where event.date >= start {
            let bucket = days == 1 ? calendar.dateInterval(of: .hour, for: event.date)!.start : calendar.startOfDay(for: event.date)
            totals[bucket, default: 0] += event.tokens.total
        }
        let count = days == 1 ? calendar.component(.hour, from: Date()) + 1 : days
        return (0..<count).map { index in
            let date = calendar.date(byAdding: days == 1 ? .hour : .day, value: index, to: start)!
            return UsagePoint(date: date, tokens: Double(totals[date] ?? 0))
        }
    }
}

enum UsageFormat {
    static func tokens(_ value: Int64) -> String {
        if value >= 1_000_000_000 { return String(format: "%.2fB", Double(value) / 1_000_000_000) }
        if value >= 1_000_000 { return String(format: "%.2fM", Double(value) / 1_000_000) }
        if value >= 1000 { return String(format: "%.1fK", Double(value) / 1000) }
        return value.formatted()
    }
    static func percent(_ fraction: Double?) -> String {
        fraction.map { String(format: "%.1f%%", $0 * 100) } ?? "—"
    }
    static func windowTitle(_ window: CodexLimitWindow?, fallback: String) -> String {
        guard let minutes = window?.windowDurationMins else { return fallback }
        if minutes == 10080 { return "Weekly usage" }
        if minutes % 60 == 0 { return "\(minutes / 60) hour usage" }
        return "\(minutes) minute usage"
    }
}
