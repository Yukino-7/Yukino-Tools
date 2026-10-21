import Foundation
import Darwin

public enum ProcessSearchMode: String, CaseIterable, Sendable {
    case automatic, name, port
}

public enum LocalProcessQuery: Equatable, Sendable {
    case name(String), port(Int)
    public init(_ input: String, mode: ProcessSearchMode = .automatic) throws {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 256, !value.contains("\0") else {
            throw ToolError.invalid("请输入进程名称或端口号，长度不超过 256 个字符。")
        }
        let digits = value.utf8.allSatisfy { (48...57).contains($0) }
        if mode == .port || (mode == .automatic && digits) {
            guard digits, let port = Int(value), (1...65535).contains(port) else {
                throw ToolError.invalid("端口号必须是 1–65535 的整数。")
            }
            self = .port(port)
        } else { self = .name(value) }
    }
}

public struct LocalProcess: Identifiable, Equatable, Sendable {
    public let pid: Int32
    public let uid: UInt32
    public let startedAtSeconds: UInt64
    public let startedAtMicroseconds: UInt64
    public let name: String
    public let executable: String
    public let command: String
    /// nil means port inspection failed; [] means no visible TCP listener.
    public let listeningPorts: [Int]?
    public var id: Int32 { pid }
    public var canTerminate: Bool { pid > 1 && pid != getpid() && uid != 0 && uid == geteuid() && !executable.isEmpty }
    public var owner: String { uid == geteuid() ? "当前用户" : uid == 0 ? "root" : "其他用户" }
}

public struct LocalProcessSearchResult: Sendable {
    public let processes: [LocalProcess]
    public let portWarning: String?
}

public enum ProcessTerminationResult: Sendable { case exited, requested }

public actor LocalProcessService {
    public init() {}

    public func search(_ input: String, mode: ProcessSearchMode = .automatic) throws -> LocalProcessSearchResult {
        let query = try LocalProcessQuery(input, mode: mode)
        try Task.checkCancellation()
        let ports: [Int32: [Int]]?
        var warning: String?
        do { ports = try Self.listeningPorts() }
        catch {
            if case .port = query { throw error }
            ports = nil; warning = "进程已找到，但监听端口暂时无法读取。"
        }
        var matches: [LocalProcess] = []
        for pid in try Self.allPIDs() {
            try Task.checkCancellation()
            if case .port(let port) = query, ports?[pid]?.contains(port) != true { continue }
            guard let process = Self.inspect(pid, ports: ports.map { $0[pid] ?? [] }) else { continue }
            if case .name(let name) = query,
               !process.name.localizedCaseInsensitiveContains(name),
               !process.executable.localizedCaseInsensitiveContains(name),
               !process.command.localizedCaseInsensitiveContains(name) { continue }
            matches.append(process)
        }
        return LocalProcessSearchResult(processes: matches.sorted { $0.name == $1.name ? $0.pid < $1.pid : $0.name.localizedStandardCompare($1.name) == .orderedAscending }, portWarning: warning)
    }

    public func terminate(_ selected: LocalProcess) async throws -> ProcessTerminationResult {
        guard selected.canTerminate else { throw ToolError.invalid("只能结束当前用户拥有的普通进程；系统进程和本应用不支持结束。") }
        guard let current = Self.inspect(selected.pid, ports: nil) else { return .exited }
        guard Self.sameIdentity(selected, current), current.executable == selected.executable else {
            throw ToolError.invalid("目标进程已变化，请重新查找后再操作。")
        }
        guard current.canTerminate else { throw ToolError.invalid("没有结束此进程的权限。") }
        if Darwin.kill(current.pid, SIGTERM) != 0 {
            let code = errno
            if code == ESRCH { return .exited }
            throw ToolError.invalid(code == EPERM ? "没有结束此进程的权限。" : "结束请求失败：\(String(cString: strerror(code)))")
        }
        for _ in 0..<12 {
            if let now = Self.inspect(current.pid, ports: nil), Self.sameIdentity(current, now) {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return .requested }
            } else { return .exited }
        }
        return .requested
    }

    private static func sameIdentity(_ left: LocalProcess, _ right: LocalProcess) -> Bool {
        left.pid == right.pid && left.uid == right.uid && left.startedAtSeconds == right.startedAtSeconds && left.startedAtMicroseconds == right.startedAtMicroseconds
    }
    private static func info(_ pid: Int32) -> proc_bsdinfo? {
        guard pid > 0 else { return nil }
        var value = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &value, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size,
              value.pbi_status != SZOMB else { return nil }
        return value
    }
    private static func inspect(_ pid: Int32, ports: [Int]?) -> LocalProcess? {
        guard let value = info(pid) else { return nil }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let capacity = UInt32(buffer.count)
        let path = proc_pidpath(pid, &buffer, capacity) > 0 ? String(cString: buffer) : ""
        var nameBytes = value.pbi_name
        let fallback = withUnsafeBytes(of: &nameBytes) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
        let name = path.isEmpty ? fallback : URL(fileURLWithPath: path).lastPathComponent
        let command = arguments(pid) ?? (path.isEmpty ? name : path)
        guard let after = info(pid), value.pbi_start_tvsec == after.pbi_start_tvsec,
              value.pbi_start_tvusec == after.pbi_start_tvusec, value.pbi_uid == after.pbi_uid else { return nil }
        return LocalProcess(pid: pid, uid: value.pbi_uid, startedAtSeconds: value.pbi_start_tvsec, startedAtMicroseconds: value.pbi_start_tvusec,
                            name: name.isEmpty ? "PID \(pid)" : name, executable: path, command: command, listeningPorts: ports)
    }
    private static func allPIDs() throws -> [Int32] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { throw ToolError.invalid("无法读取本机进程列表，请检查 macOS 权限后重试。") }
        var pids = [Int32](repeating: 0, count: Int(count) + 256)
        let bytes = Int32(pids.count * MemoryLayout<Int32>.size)
        let read = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, bytes) }
        guard read > 0 else { throw ToolError.invalid("无法读取本机进程列表。") }
        return Array(pids.prefix(min(Int(read), pids.count))).filter { $0 > 0 }
    }
    private static func arguments(_ pid: Int32) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4, size <= 2_000_000 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &bytes, &size, nil, 0) == 0 else { return nil }
        let count = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard (1...4096).contains(count) else { return nil }
        var cursor = MemoryLayout<Int32>.size
        func next() -> String? {
            guard cursor < size, let end = bytes[cursor..<size].firstIndex(of: 0) else { return nil }
            let value = String(decoding: bytes[cursor..<end], as: UTF8.self); cursor = end + 1; return value
        }
        guard next() != nil else { return nil } // Executable path precedes argv.
        while cursor < size && bytes[cursor] == 0 { cursor += 1 }
        var values: [String] = []
        for _ in 0..<count {
            guard let value = next() else { return nil }
            let simple = !value.isEmpty && value.range(of: #"^[A-Za-z0-9_./:=@+,-]+$"#, options: .regularExpression) != nil
            values.append(simple ? value : "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'")
        }
        return values.joined(separator: " ")
    }

    /// lsof field output; only TCP LISTEN sockets are requested. No user input is passed to a shell.
    static func parseListeningPorts(_ output: String) -> [Int32: [Int]] {
        var pid: Int32?; var ports: [Int32: Set<Int>] = [:]
        for line in output.split(separator: "\n") {
            if line.first == "p" { pid = Int32(line.dropFirst()); continue }
            guard line.first == "n", let pid, pid > 0, !line.contains("->"),
                  let suffix = line.split(separator: ":").last, let port = Int(suffix), (1...65535).contains(port) else { continue }
            ports[pid, default: []].insert(port)
        }
        return ports.mapValues { $0.sorted() }
    }
    private static func listeningPorts() throws -> [Int32: [Int]] {
        let process = Process(); let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpn"]
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        process.environment = ["LC_ALL": "C", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        do { try process.run() } catch { throw ToolError.invalid("无法启动系统端口查询工具。") }
        let timeout = DispatchWorkItem { if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 4, execute: timeout)
        defer { timeout.cancel(); try? pipe.fileHandleForReading.close() }
        var data = Data()
        while true {
            let chunk = pipe.fileHandleForReading.readData(ofLength: 65_536)
            if chunk.isEmpty { break }
            data.append(chunk)
            if data.count > 2_000_000 {
                if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                throw ToolError.invalid("监听端口列表过大，请稍后重试。")
            }
        }
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 || process.terminationStatus == 1 else {
            throw ToolError.invalid("监听端口读取失败或超时，请重试。")
        }
        return parseListeningPorts(String(decoding: data, as: UTF8.self))
    }
}
