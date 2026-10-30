import Foundation
import Darwin

public struct CurlFavorite: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var command: String
    public var sourceShell: CurlShell
    public var updatedAt: Date

    public init(id: UUID = UUID(), name: String, command: String, sourceShell: CurlShell, updatedAt: Date = Date()) {
        self.id = id; self.name = name; self.command = command
        self.sourceShell = sourceShell; self.updatedAt = updatedAt
    }
}

/// Only explicit favorites are persisted. Commands are retained verbatim, including credentials.
/// A failed read or a change by another app instance must never overwrite the existing library.
public final class CurlFavoritesStore {
    private struct Document: Codable {
        var version = 1
        var favorites: [CurlFavorite]
    }
    public let fileURL: URL
    private var loaded = false
    private var snapshot: Data?
    private static let maximumBytes = 20 * 1_024 * 1_024

    public init(directory: URL? = nil) {
        let directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("YukinoTools/Curl", isDirectory: true)
        fileURL = directory.appendingPathComponent("favorites.json")
    }

    public func load() throws -> [CurlFavorite] {
        loaded = false
        let data = try read()
        let values: [CurlFavorite]
        if let data {
            let document = try JSONDecoder().decode(Document.self, from: data)
            guard document.version == 1 else { throw ToolError.invalid("收藏文件版本不受支持，原文件已保留。") }
            values = document.favorites
            try validate(values)
        } else { values = [] }
        snapshot = data; loaded = true
        return values
    }

    public func save(_ favorites: [CurlFavorite]) throws {
        guard loaded else { throw ToolError.invalid("请先成功读取收藏，避免覆盖原文件。") }
        try validate(favorites)
        let data = try JSONEncoder().encode(Document(favorites: favorites))
        guard data.count <= Self.maximumBytes else { throw ToolError.invalid("收藏总大小不能超过 20 MB。") }
        let manager = FileManager.default, directory = fileURL.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // A stable lock file makes the snapshot check and replacement one transaction across app instances.
        let lockURL = directory.appendingPathComponent(".favorites.lock")
        let lock = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, mode_t(0o600))
        guard lock >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(lock) }
        guard flock(lock, LOCK_EX) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { _ = flock(lock, LOCK_UN) }
        guard try read() == snapshot else { throw ToolError.invalid("收藏文件已在其他窗口更新，请重新读取后再保存。") }
        let temporary = directory.appendingPathComponent(".favorites-\(UUID().uuidString).tmp")
        defer { try? manager.removeItem(at: temporary) }
        guard manager.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw ToolError.invalid("收藏写入失败，原文件未修改。")
        }
        guard try read() == snapshot else { throw ToolError.invalid("收藏文件已更新，请重新读取后再保存。") }
        guard rename(temporary.path, fileURL.path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        snapshot = data
    }

    private func read() throws -> Data? {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            guard (attributes[.size] as? NSNumber)?.intValue ?? 0 <= Self.maximumBytes else {
                throw ToolError.invalid("收藏文件超过 20 MB，原文件已保留。")
            }
            return try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
    }

    private func validate(_ favorites: [CurlFavorite]) throws {
        guard favorites.count <= 1_000, Set(favorites.map(\.id)).count == favorites.count else {
            throw ToolError.invalid("收藏最多 1,000 条，标识不能重复。")
        }
        for item in favorites {
            guard !item.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, item.name.count <= 100,
                  !item.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  item.command.utf8.count <= 262_144, !item.command.contains("\0") else {
                throw ToolError.invalid("收藏名称须为 1–100 字，命令不能为空、超过 256 KB 或包含 NUL。")
            }
        }
    }
}
