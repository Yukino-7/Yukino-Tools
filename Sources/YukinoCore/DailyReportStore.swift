import Foundation
import CryptoKit

public struct DailyReportEntry: Identifiable, Equatable, Sendable {
    public let dateKey: String
    public let url: URL
    public var id: String { dateKey }
}
public struct ReportImportResult: Sendable {
    public var imported = 0
    public var skipped = 0
    public var errors: [String] = []
}

public actor DailyReportStore {
    public let directory: URL
    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("YukinoTools/Reports/OpenRouter", isDirectory: true)
    }
    private struct CachedSnapshot: Codable {
        let digest: String
        let snapshot: DailySnapshot
    }
    public init(directory: URL = DailyReportStore.defaultDirectory) { self.directory = directory }

    public func entries() throws -> [DailyReportEntry] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
            .filter { $0.pathExtension == "md" && OpenRouterReportService.validDateKey($0.deletingPathExtension().lastPathComponent) && regular($0) }
            .map { DailyReportEntry(dateKey: $0.deletingPathExtension().lastPathComponent, url: $0) }
            .sorted { $0.dateKey > $1.dateKey }
    }
    public func markdown(for key: String) throws -> String { try read(file(key, extension: "md")) }

    public func previous(before key: String) throws -> DailySnapshot? {
        for entry in try entries() where entry.dateKey < key {
            guard let markdown = try? read(entry.url) else { continue }
            let cached = try file(entry.dateKey, extension: "json")
            if regular(cached), let data = try? Data(contentsOf: cached), data.count <= 3_000_000,
               let decoded = try? JSONDecoder().decode(CachedSnapshot.self, from: data),
               decoded.digest == digest(markdown), decoded.snapshot.dateKey == entry.dateKey, decoded.snapshot.models != nil {
                return decoded.snapshot
            }
            let parsed = OpenRouterReportService.legacySnapshot(markdown: markdown, dateKey: entry.dateKey)
            if parsed.models != nil { return parsed }
        }
        return nil
    }

    /// Same-day replacement keeps a recoverable copy; imports never overwrite existing dates.
    public func save(_ report: DailyReport, replacing: Bool = false) throws -> DailyReportEntry {
        let markdownURL = try file(report.snapshot.dateKey, extension: "md")
        let snapshotURL = try file(report.snapshot.dateKey, extension: "json")
        guard report.markdown.utf8.count <= 2_000_000 else { throw ToolError.invalid("报告超过 2 MB") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: markdownURL.path) {
            guard replacing else { throw ToolError.invalid("今日报告已存在，请选择更新今日报告") }
            guard regular(markdownURL) else { throw ToolError.invalid("报告路径不是普通文件") }
            let backup = directory.appendingPathComponent("Revisions/\(report.snapshot.dateKey)/\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: markdownURL, to: backup.appendingPathComponent(markdownURL.lastPathComponent))
            if regular(snapshotURL) { try FileManager.default.copyItem(at: snapshotURL, to: backup.appendingPathComponent(snapshotURL.lastPathComponent)) }
        }
        if FileManager.default.fileExists(atPath: snapshotURL.path), !regular(snapshotURL) { throw ToolError.invalid("数据快照路径不是普通文件") }
        let metadata = try JSONEncoder().encode(CachedSnapshot(digest: digest(report.markdown), snapshot: report.snapshot))
        // A stale sidecar is never trusted: its digest must match the Markdown file on read.
        try Data(report.markdown.utf8).write(to: markdownURL, options: .atomic)
        try metadata.write(to: snapshotURL, options: .atomic)
        return DailyReportEntry(dateKey: report.snapshot.dateKey, url: markdownURL)
    }

    public func importDirectory(_ source: URL) throws -> ReportImportResult {
        let files = try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
            .filter { $0.pathExtension.lowercased() == "md" && OpenRouterReportService.validDateKey($0.deletingPathExtension().lastPathComponent) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var result = ReportImportResult()
        for sourceFile in files {
            do {
                let key = sourceFile.deletingPathExtension().lastPathComponent
                let destination = try file(key, extension: "md")
                if FileManager.default.fileExists(atPath: destination.path) { result.skipped += 1; continue }
                let text = try read(sourceFile)
                guard text.contains("# OpenRouter 免费模型日报"), !MarkdownDocument.parse(text).isEmpty else { throw ToolError.invalid("不是 OpenRouter 日报") }
                try Data(text.utf8).write(to: destination, options: .withoutOverwriting)
                result.imported += 1
            } catch { result.errors.append("\(sourceFile.lastPathComponent)：\(error.localizedDescription)") }
        }
        return result
    }

    private func file(_ key: String, extension suffix: String) throws -> URL {
        guard OpenRouterReportService.validDateKey(key) else { throw ToolError.invalid("无效报告日期") }
        return directory.appendingPathComponent("\(key).\(suffix)")
    }
    private func regular(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }
    private func read(_ url: URL) throws -> String {
        guard regular(url) else { throw ToolError.invalid("报告不是普通文件") }
        let attributes = try url.resourceValues(forKeys: [.fileSizeKey])
        guard (attributes.fileSize ?? 0) <= 2_000_000 else { throw ToolError.invalid("报告超过 2 MB") }
        let data = try Data(contentsOf: url)
        guard data.count <= 2_000_000, let text = String(data: data, encoding: .utf8) else { throw ToolError.invalid("报告必须是 UTF-8 Markdown，大小不超过 2 MB") }
        return text
    }
    private func digest(_ markdown: String) -> String { SHA256.hash(data: Data(markdown.utf8)).map { String(format: "%02x", $0) }.joined() }
}
