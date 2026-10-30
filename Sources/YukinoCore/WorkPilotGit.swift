import Foundation
import Darwin

public struct WorkGitCommit: Codable, Equatable, Sendable {
    public var hash: String
    public var date: Date
    public var author: String
    public var email: String
    public var subject: String
    public var fileCount = 0
    public var additions = 0
    public var deletions = 0
}

public struct WorkGitFileChange: Equatable, Sendable {
    public let path: String
    public let status: String
}
public struct WorkGitWorkingTree: Equatable, Sendable {
    public let files: [WorkGitFileChange]
    public var untrackedCount: Int { files.filter { $0.status == "??" }.count }
}

/// Reads committed metadata and numeric diff statistics; never reads patches or contacts a remote.
public enum WorkPilotGit {
    public static func workingTree(repository: URL) async throws -> WorkGitWorkingTree {
        try await Task.detached(priority: .utility) {
            // --porcelain=v1 -z is independent of user display settings and quotes no paths.
            let output = try run(repository, ["status", "--porcelain=v1", "-z", "--untracked-files=normal"], deadline: Date().addingTimeInterval(10))
            return try parseStatus(output)
        }.value
    }
    public static func parseStatus(_ data: Data) throws -> WorkGitWorkingTree {
        let entries = data.split(separator: 0)
        var files: [WorkGitFileChange] = [], i = 0
        while i < entries.count {
            let entry = Array(entries[i]); i += 1
            guard entry.count >= 4, entry[2] == 32 else { throw ToolError.invalid("无法读取 Git 工作区状态") }
            let status = String(decoding: entry.prefix(2), as: UTF8.self)
            files.append(WorkGitFileChange(path: String(decoding: entry.dropFirst(3), as: UTF8.self), status: status))
            if status.contains("R") || status.contains("C") {
                guard i < entries.count else { throw ToolError.invalid("Git 重命名记录不完整") }
                i += 1 // -z emits the original path after the destination path.
            }
        }
        return WorkGitWorkingTree(files: files)
    }
    public static func scan(repository: URL, day: Date, authorEmail: String? = nil, calendar: Calendar = .current) async throws -> [WorkGitCommit] {
        try await Task.detached(priority: .utility) {
            let deadline = Date().addingTimeInterval(25)
            _ = try root(of: repository, deadline: deadline)
            let interval = calendar.dateInterval(of: .day, for: day)!
            // --since-as-filter preserves commits whose parent timestamps are out of order.
            let output = try run(repository, ["log", "--all", "--since-as-filter=@\(Int(interval.start.timeIntervalSince1970))", "--until=@\(Int(interval.end.timeIntervalSince1970))", "--format=%H%x00%ct%x00%an%x00%ae%x00%s", "-z", "-n", "501", "--"], deadline: deadline)
            var commits = try parseLog(output)
            guard commits.count <= 500 else { throw ToolError.invalid("当天提交超过 500 条，请缩小仓库范围") }
            let configured = (try? run(repository, ["config", "--get", "user.email"], deadline: deadline)).map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
            let email = (authorEmail ?? configured).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !email.isEmpty else { throw ToolError.invalid("仓库没有 user.email，请在项目里填写要采集的作者邮箱") }
            commits = commits.filter { $0.email.caseInsensitiveCompare(email) == .orderedSame && interval.contains($0.date) }
            for i in commits.indices {
                try Task.checkCancellation()
                let stats = try run(repository, ["show", "--format=", "--numstat", "-z", "--no-renames", "--no-ext-diff", "--no-textconv", commits[i].hash, "--"], deadline: deadline)
                for entry in stats.split(separator: 0) {
                    let fields = entry.split(separator: 9, maxSplits: 2, omittingEmptySubsequences: false)
                    guard fields.count == 3 else { continue }
                    commits[i].fileCount += 1
                    commits[i].additions += Int(String(decoding: fields[0], as: UTF8.self)) ?? 0
                    commits[i].deletions += Int(String(decoding: fields[1], as: UTF8.self)) ?? 0
                }
            }
            return commits.sorted { $0.date < $1.date }
        }.value
    }
    public static func repositoryRoot(_ directory: URL) async throws -> String {
        try await Task.detached(priority: .utility) { try root(of: directory, deadline: Date().addingTimeInterval(5)) }.value
    }
    public static func parseLog(_ data: Data) throws -> [WorkGitCommit] {
        var fields = data.split(separator: 0, omittingEmptySubsequences: false)
        if fields.last?.isEmpty == true { fields.removeLast() }
        guard fields.count % 5 == 0 else { throw ToolError.invalid("Git 返回了无法识别的提交记录") }
        var result: [WorkGitCommit] = []
        for i in stride(from: 0, to: fields.count, by: 5) {
            let hash = String(decoding: fields[i], as: UTF8.self)
            guard (40...64).contains(hash.count), hash.allSatisfy(\.isHexDigit),
                  let seconds = Double(String(decoding: fields[i + 1], as: UTF8.self)) else { throw ToolError.invalid("Git 提交标识或时间无效") }
            result.append(WorkGitCommit(hash: hash, date: Date(timeIntervalSince1970: seconds), author: String(decoding: fields[i + 2], as: UTF8.self), email: String(decoding: fields[i + 3], as: UTF8.self), subject: String(decoding: fields[i + 4], as: UTF8.self)))
        }
        return result
    }
    private static func root(of directory: URL, deadline: Date) throws -> String {
        let bytes = try run(directory, ["rev-parse", "--show-toplevel"], deadline: deadline)
        let path = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .newlines)
        guard !path.isEmpty, path.hasPrefix("/") else { throw ToolError.invalid("请选择普通 Git 工作区或 worktree 目录") }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
    private static func run(_ repository: URL, _ arguments: [String], deadline: Date) throws -> Data {
        guard Date() < deadline else { throw ToolError.invalid("Git 扫描超时，请检查仓库规模") }
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["--no-pager", "--literal-pathspecs", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "-C", repository.path] + arguments
        var environment = ProcessInfo.processInfo.environment
        for key in environment.keys.filter({ $0.hasPrefix("GIT_") }) { environment.removeValue(forKey: key) }
        environment["GIT_OPTIONAL_LOCKS"] = "0"; environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        let timeout = DispatchWorkItem { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        DispatchQueue.global().asyncAfter(deadline: .now() + max(0, deadline.timeIntervalSinceNow), execute: timeout)
        defer { timeout.cancel(); try? output.fileHandleForReading.close() }
        var data = Data()
        while true {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            data.append(chunk)
            if data.count > 4_000_000 {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                throw ToolError.invalid("Git 输出超过 4 MB，请整理提交规模")
            }
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ToolError.invalid(Date() >= deadline ? "Git 扫描超时" : "无法读取 Git 仓库，请检查目录、Git 安装和仓库权限") }
        return data
    }
}
