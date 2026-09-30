import SwiftUI

enum Tool: String, CaseIterable, Identifiable, Codable {
    case overview, codex, token, json, base64, timestamp, uuid, port, http, dns, postgres, redis
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: "Overview"
        case .codex: "Codex Usage"
        case .token: "Token Calculator"
        case .json: "JSON Formatter"
        case .base64: "Base64 Converter"
        case .timestamp: "Timestamp Converter"
        case .uuid: "UUID Generator"
        case .port: "Port Check"
        case .http: "HTTP Client"
        case .dns: "DNS Lookup"
        case .postgres: "PostgreSQL"
        case .redis: "Redis"
        }
    }
    var subtitle: String {
        switch self {
        case .overview: "Your personal developer toolbox."
        case .codex: "A little clarity for your AI workflow."
        case .token: "Estimate tokens and model costs."
        case .json: "Format, validate and inspect JSON data."
        case .base64: "Encode and decode UTF-8 text in a single step."
        case .timestamp: "Move between Unix timestamps and human time."
        case .uuid: "Unique identifiers, ready when you need them."
        case .port: "Check a TCP connection to any host and port."
        case .http: "Send requests and inspect responses."
        case .dns: "Explore the records behind a domain."
        case .postgres: "A home for your PostgreSQL connections."
        case .redis: "Inspect and manage your Redis data."
        }
    }
    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .codex: "terminal"
        case .token: "text.word.spacing"
        case .json: "curlybraces"
        case .base64: "arrow.left.arrow.right"
        case .timestamp: "clock"
        case .uuid: "number"
        case .port: "network"
        case .http: "arrow.up.arrow.down"
        case .dns: "globe"
        case .postgres: "cylinder.split.1x2"
        case .redis: "externaldrive"
        }
    }
    var group: String {
        switch self {
        case .overview: "Workspace"
        case .codex, .token: "AI"
        case .json, .base64, .timestamp, .uuid: "Developer"
        case .port, .http, .dns: "Network"
        case .postgres, .redis: "Database"
        }
    }
    var available: Bool { ![.token, .http, .dns, .postgres, .redis].contains(self) }
    func matches(_ query: String) -> Bool {
        query.isEmpty || "\(title) \(subtitle) \(group) \(rawValue)".localizedCaseInsensitiveContains(query)
    }
}

struct RecentTool: Codable, Identifiable {
    let tool: Tool
    let date: Date
    var id: String { tool.rawValue }
}

@MainActor final class AppState: ObservableObject {
    @Published var selected: Tool = .overview
    @Published var paletteVisible = false
    @Published var favorites: [Tool] = []
    @Published var recent: [RecentTool] = []
    @Published var notice: String?
    private var noticeTask: Task<Void, Never>?
    private let defaults = UserDefaults.standard
    init() {
        if let data = defaults.data(forKey: "favorites"), let values = try? JSONDecoder().decode([Tool].self, from: data) {
            favorites = values
        } else { favorites = [.json, .timestamp, .uuid] }
        if let data = defaults.data(forKey: "recentTools"), let values = try? JSONDecoder().decode([RecentTool].self, from: data) { recent = values }
        if defaults.object(forKey: "rememberLastTool") == nil || defaults.bool(forKey: "rememberLastTool") {
            selected = Tool(rawValue: defaults.string(forKey: "lastTool") ?? "overview") ?? .overview
        }
    }
    func navigate(_ tool: Tool) {
        selected = tool
        paletteVisible = false
        defaults.set(tool.rawValue, forKey: "lastTool")
        if tool != .overview {
            recent.removeAll { $0.tool == tool }
            recent.insert(RecentTool(tool: tool, date: Date()), at: 0)
            recent = Array(recent.prefix(8))
            defaults.set(try? JSONEncoder().encode(recent), forKey: "recentTools")
        }
    }
    func toggleFavorite(_ tool: Tool) {
        if favorites.contains(tool) { favorites.removeAll { $0 == tool } } else { favorites.append(tool) }
        saveFavorites()
    }
    func saveFavorites() { defaults.set(try? JSONEncoder().encode(favorites), forKey: "favorites") }
    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        notify("Copied to clipboard")
    }
    func notify(_ message: String) {
        noticeTask?.cancel()
        notice = message
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }
}
