import Foundation

/// Stores ordering only. Category membership always comes from the current catalog.
public struct SidebarOrder: Codable, Equatable {
    private var groups: [String] = []
    private var items: [String: [String]] = [:]

    public init() {}

    public func orderedGroups(_ available: [String]) -> [String] {
        Self.visible(available, saved: groups)
    }

    public func orderedItems(in group: String, available: [String]) -> [String] {
        Self.visible(available, saved: items[group] ?? [])
    }

    @discardableResult
    public mutating func moveGroup(_ source: String, to target: String, after: Bool, available: [String]) -> Bool {
        guard let result = Self.moved(source, to: target, after: after, available: available, saved: groups) else { return false }
        groups = result
        return true
    }

    @discardableResult
    public mutating func moveItem(_ source: String, in group: String, to target: String, after: Bool, available: [String]) -> Bool {
        guard let result = Self.moved(source, to: target, after: after, available: available, saved: items[group] ?? []) else { return false }
        items[group] = result
        return true
    }

    private static func visible(_ available: [String], saved: [String]) -> [String] {
        var seen: Set<String> = []
        let allowed = Set(available)
        return (saved + available).filter { allowed.contains($0) && seen.insert($0).inserted }
    }

    private static func moved(_ source: String, to target: String, after: Bool, available: [String], saved: [String]) -> [String]? {
        guard source != target, available.contains(source), available.contains(target) else { return nil }
        // Retain temporarily unavailable entries, so switching catalogs does not erase preferences.
        var result = visible(saved + available, saved: saved)
        result.removeAll { $0 == source }
        guard let index = result.firstIndex(of: target) else { return nil }
        result.insert(source, at: index + (after ? 1 : 0))
        return result
    }
}
