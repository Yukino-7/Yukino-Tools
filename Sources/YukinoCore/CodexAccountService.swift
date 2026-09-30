import Foundation
import Darwin

/// Read-only JSON-RPC over the installed Codex CLI. Authentication stays inside Codex.
public enum CodexAccountService {
    public static func discoverExecutable(customPath: String = "") -> URL? {
        let paths = customPath.isEmpty ? [
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex"
        ] : [NSString(string: customPath).expandingTildeInPath]
        return paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map { URL(fileURLWithPath: $0) }
    }

    public static func fetch(executable: URL, timeout: TimeInterval = 15) async throws -> CodexLimits {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do { continuation.resume(returning: try read(executable: executable, timeout: timeout)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    public static func parseResponse(_ data: Data, capturedAt: Date = Date()) throws -> CodexLimits {
        guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ToolError.invalid("Codex returned an unreadable usage response.")
        }
        let buckets = response["rateLimitsByLimitId"] as? [String: Any]
        let raw = (buckets?["codex"] as? [String: Any]) ?? response["rateLimits"] as? [String: Any]
        guard let raw, (raw["limitId"] as? String == nil || raw["limitId"] as? String == "codex") else {
            throw ToolError.invalid("Codex allowance is unavailable for the signed-in account.")
        }
        let primary = CodexLogParser.window(raw["primary"], snakeCase: false)
        let secondary = CodexLogParser.window(raw["secondary"], snakeCase: false)
        guard primary != nil || secondary != nil else {
            throw ToolError.invalid("Codex returned no account allowance windows. Sign in with ChatGPT in Codex.")
        }
        return CodexLimits(primary: primary, secondary: secondary, planType: raw["planType"] as? String,
                           capturedAt: capturedAt, source: "Account API")
    }

    private static func read(executable: URL, timeout: TimeInterval) throws -> CodexLimits {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        // A CLI that exits during initialization must not send SIGPIPE to the UI process.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        do { try process.run() } catch { throw ToolError.invalid("Could not launch the selected Codex CLI.") }
        let deadline = Date().addingTimeInterval(timeout)
        let timeoutWork = DispatchWorkItem {
            if process.isRunning { process.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutWork)
        defer {
            timeoutWork.cancel()
            try? input.fileHandleForWriting.close()
            if process.isRunning {
                process.terminate()
                let killWork = DispatchWorkItem { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 1, execute: killWork)
                process.waitUntilExit()
                killWork.cancel()
            }
            try? output.fileHandleForReading.close()
        }
        func send(_ message: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes])
            data.append(10)
            try input.fileHandleForWriting.write(contentsOf: data)
        }
        try send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "yukino_tools", "title": "Yukino Tools", "version": "0.2.0"]]])
        var buffer = Data()
        var initialized = false
        while Date() < deadline {
            let chunk = output.fileHandleForReading.availableData
            guard !chunk.isEmpty else { break }
            buffer.append(chunk)
            guard buffer.count < 8 * 1024 * 1024 else { throw ToolError.invalid("Unexpected Codex response size.") }
            while let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], let id = message["id"] as? Int else { continue }
                if message["error"] != nil, id == 1 || id == 2 {
                    throw ToolError.invalid("Codex account request failed. Check the CLI sign-in and network connection.")
                }
                if id == 1 && !initialized && message["result"] != nil {
                    initialized = true
                    try send(["method": "initialized", "params": [:]])
                    try send(["id": 2, "method": "account/rateLimits/read"])
                } else if id == 2, let result = message["result"] as? [String: Any] {
                    return try parseResponse(JSONSerialization.data(withJSONObject: result))
                }
            }
        }
        if Date() >= deadline { throw ToolError.invalid("Account refresh timed out. The last recorded snapshot is shown when available.") }
        throw ToolError.invalid("Codex app-server stopped before responding. Check the CLI path and sign-in.")
    }
}
