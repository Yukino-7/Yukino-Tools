import Foundation
import Darwin
import Testing
@testable import YukinoCore

@Test func processQueryDistinguishesNamesPortsAndInvalidInput() throws {
    #expect(try LocalProcessQuery(" 3000 ") == .port(3000))
    #expect(try LocalProcessQuery("Node") == .name("Node"))
    #expect(try LocalProcessQuery("3000", mode: .name) == .name("3000"))
    #expect(try LocalProcessQuery("java -jar app.jar") == .name("java -jar app.jar"))
    for input in ["", "  ", "0", "65536", String(repeating: "9", count: 260), "node\0bad"] {
        #expect(throws: ToolError.self) { try LocalProcessQuery(input) }
    }
    for input in ["-1", "80/tcp", "node", "1.5", "12 34"] {
        #expect(throws: ToolError.self) { try LocalProcessQuery(input, mode: .port) }
    }
}

@Test func processPortFieldsHandleIPv6DuplicatesAndIgnoreRemoteConnections() {
    let output = """
    p42
    n127.0.0.1:3000
    n[::1]:3000
    n*:8080
    n127.0.0.1:45678->127.0.0.1:3000
    p88
    n*:3000
    n*:0
    n*:65536
    pbad
    n*:8081
    """
    #expect(LocalProcessService.parseListeningPorts(output) == [42: [3000, 8080], 88: [3000]])
    #expect(LocalProcessService.parseListeningPorts("").isEmpty)
}

private func sleepingChild() throws -> Process {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sleep")
    child.arguments = ["60"]
    child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
    try child.run()
    return child
}
private func cleanup(_ child: Process) {
    if child.isRunning { child.terminate() }
    child.waitUntilExit()
}

@Test func processSearchFindsAndTerminatesOnlyTheChildCreatedByThisTest() async throws {
    let child = try sleepingChild(); defer { cleanup(child) }
    let service = LocalProcessService()
    let found = try await service.search("sleep", mode: .name)
    let target = try #require(found.processes.first { $0.pid == child.processIdentifier })
    #expect(target.name == "sleep" && target.command.contains("60"))
    #expect(target.executable == "/bin/sleep" && target.canTerminate)
    #expect(target.listeningPorts == [])
    #expect(try await service.terminate(target) == .exited)
    child.waitUntilExit()
    #expect(!child.isRunning && child.terminationReason == .uncaughtSignal && child.terminationStatus == SIGTERM)
    #expect(try await service.terminate(target) == .exited)
    #expect(try await !service.search("sleep", mode: .name).processes.contains { $0.pid == target.pid })
}

@Test func processTerminationRevalidatesIdentityAndRejectsProtectedTargets() async throws {
    let child = try sleepingChild(); defer { cleanup(child) }
    let service = LocalProcessService()
    let found = try await service.search("sleep", mode: .name)
    let target = try #require(found.processes.first { $0.pid == child.processIdentifier })
    func changed(pid: Int32? = nil, uid: UInt32? = nil, seconds: UInt64? = nil, path: String? = nil) -> LocalProcess {
        LocalProcess(pid: pid ?? target.pid, uid: uid ?? target.uid, startedAtSeconds: seconds ?? target.startedAtSeconds,
                     startedAtMicroseconds: target.startedAtMicroseconds, name: target.name, executable: path ?? target.executable,
                     command: target.command, listeningPorts: target.listeningPorts)
    }
    for unsafe in [changed(seconds: target.startedAtSeconds + 1), changed(path: "/bin/different"), changed(uid: 0), changed(pid: 1), changed(pid: 0), changed(pid: getpid())] {
        do { _ = try await service.terminate(unsafe); Issue.record("Unsafe target should be rejected") }
        catch { #expect(error is ToolError) }
        #expect(child.isRunning)
    }
}

@Test func processPortSearchFindsTheActualLocalTCPListener() async throws {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno)!) }
    defer { Darwin.close(fd) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let bound = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard bound == 0, listen(fd, 1) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno)!) }
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let located = withUnsafeMutablePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
    }
    #expect(located == 0)
    let port = Int(UInt16(bigEndian: address.sin_port))
    let result = try await LocalProcessService().search(String(port))
    let current = try #require(result.processes.first { $0.pid == getpid() })
    #expect(current.listeningPorts?.contains(port) == true)
    #expect(!current.canTerminate)
    #expect(result.processes.allSatisfy { $0.listeningPorts?.contains(port) == true })
}
