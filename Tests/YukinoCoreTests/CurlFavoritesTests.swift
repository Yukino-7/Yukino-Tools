import Foundation
import Testing
@testable import YukinoCore

private func withCurlFavorites(_ action: (URL) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("curl-favorites-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    try action(directory)
}

@Test func curlFavoritesPreserveOriginalTextShellAndIDsAcrossRelaunch() throws {
    try withCurlFavorites { directory in
        let store = CurlFavoritesStore(directory: directory)
        #expect(try store.load().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        let command = "curl 'https://example.com/api?tag=雪乃' \\\r\n  -H 'Authorization: Bearer sample-only' --data-raw '{\"id\":9007199254740993}'\n"
        let favorites = CurlShell.allCases.map { CurlFavorite(name: "重复名称", command: command, sourceShell: $0) }
        try store.save(favorites)
        #expect(try CurlFavoritesStore(directory: directory).load() == favorites)
        let permissions = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
        var updated = favorites
        updated[0].name = "新的名称"; updated[0].command = "curl https://example.com/changed"
        try store.save(updated)
        #expect(try CurlFavoritesStore(directory: directory).load() == updated)
        try store.save(Array(updated.dropFirst()))
        #expect(try CurlFavoritesStore(directory: directory).load() == Array(updated.dropFirst()))
    }
}

@Test func curlFavoritesRejectCorruptionAndNeverReplaceUnreadableOrFutureData() throws {
    try withCurlFavorites { directory in
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for raw in ["not JSON", "{\"version\":2,\"favorites\":[]}"] {
            let store = CurlFavoritesStore(directory: directory), original = Data(raw.utf8)
            try original.write(to: store.fileURL)
            #expect(throws: (any Error).self) { try store.load() }
            #expect(throws: (any Error).self) { try store.save([]) }
            #expect(try Data(contentsOf: store.fileURL) == original)
        }
    }
}

@Test func curlFavoritesRejectInvalidWritesWithoutChangingStoredLibrary() throws {
    try withCurlFavorites { directory in
        let store = CurlFavoritesStore(directory: directory)
        _ = try store.load()
        let good = CurlFavorite(name: "接口", command: "curl https://example.com", sourceShell: .bash)
        try store.save([good])
        let original = try Data(contentsOf: store.fileURL)
        for invalid in [
            [good, good],
            [CurlFavorite(name: "  ", command: good.command, sourceShell: .bash)],
            [CurlFavorite(name: "接口", command: " ", sourceShell: .bash)],
            [CurlFavorite(name: "接口", command: "curl\0https://example.com", sourceShell: .bash)],
            [CurlFavorite(name: "接口", command: String(repeating: "x", count: 262_145), sourceShell: .bash)]
        ] {
            #expect(throws: (any Error).self) { try store.save(invalid) }
            #expect(try Data(contentsOf: store.fileURL) == original)
        }
    }
}

@Test func curlFavoritesDetectOtherInstanceChangesAndAllowExplicitReload() throws {
    try withCurlFavorites { directory in
        let first = CurlFavoritesStore(directory: directory), second = CurlFavoritesStore(directory: directory)
        _ = try first.load(); _ = try second.load()
        let item = CurlFavorite(name: "接口", command: "curl https://example.com", sourceShell: .bash)
        try first.save([item])
        #expect(throws: (any Error).self) { try second.save([]) }
        #expect(try second.load() == [item])
        try second.save([])
        #expect(try first.load().isEmpty)
    }
}
