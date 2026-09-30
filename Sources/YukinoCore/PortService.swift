import Foundation
import Network

public struct PortResult: Sendable {
    public let connected: Bool
    public let latency: Double
    public let message: String
}

public enum PortService {
    public static func check(host: String, port: String, timeout: Double = 5) async throws -> PortResult {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !host.contains(where: { $0.isWhitespace }), !host.contains("://") else {
            throw ToolError.invalid("Enter a hostname or IP address, without a URL scheme.")
        }
        guard let number = UInt16(port), number > 0, let endpoint = NWEndpoint.Port(rawValue: number) else {
            throw ToolError.invalid("Port must be a number between 1 and 65535.")
        }
        return await withCheckedContinuation { continuation in
            let probe = TCPProbe(host: host, port: endpoint, timeout: timeout, continuation: continuation)
            probe.start()
        }
    }
}

private final class TCPProbe: @unchecked Sendable {
    let connection: NWConnection
    let queue = DispatchQueue(label: "tools.yukino.tcp-probe")
    let timeout: Double
    var continuation: CheckedContinuation<PortResult, Never>?
    let started = DispatchTime.now()
    var timeoutWork: DispatchWorkItem?
    init(host: String, port: NWEndpoint.Port, timeout: Double, continuation: CheckedContinuation<PortResult, Never>) {
        connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        self.timeout = timeout
        self.continuation = continuation
    }
    func start() {
        connection.stateUpdateHandler = { [self] state in
            switch state {
            case .ready: finish(connected: true, message: "TCP connection established")
            case .failed(let error): finish(connected: false, message: error.localizedDescription)
            default: break
            }
        }
        let work = DispatchWorkItem { [self] in finish(connected: false, message: "Timeout after \(Int(timeout))s") }
        timeoutWork = work
        queue.asyncAfter(deadline: .now() + timeout, execute: work)
        connection.start(queue: queue)
    }
    func finish(connected: Bool, message: String) {
        guard let continuation else { return }
        self.continuation = nil
        timeoutWork?.cancel()
        timeoutWork = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        let latency = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
        continuation.resume(returning: PortResult(connected: connected, latency: latency, message: message))
    }
}
