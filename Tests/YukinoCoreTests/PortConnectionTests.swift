import Foundation
import Network
import Testing
@testable import YukinoCore

@Test func portConnectsToLocalListenerAndReportsClosedPort() async throws {
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host("127.0.0.1"), port: .any)
    let listener = try NWListener(using: parameters)
    let queue = DispatchQueue(label: "yukino.tests.local-listener")
    listener.newConnectionHandler = { connection in
        connection.stateUpdateHandler = { state in
            if case .ready = state {
                connection.stateUpdateHandler = nil
                connection.cancel()
            }
        }
        connection.start(queue: queue)
    }
    let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                listener.stateUpdateHandler = nil
                continuation.resume(returning: listener.port!.rawValue)
            case .failed(let error):
                listener.stateUpdateHandler = nil
                continuation.resume(throwing: error)
            default: break
            }
        }
        listener.start(queue: queue)
    }
    let connected = try await PortService.check(host: "127.0.0.1", port: String(port), timeout: 2)
    #expect(connected.connected)
    #expect(connected.latency >= 0)
    await withCheckedContinuation { continuation in
        listener.stateUpdateHandler = { state in
            if case .cancelled = state {
                listener.stateUpdateHandler = nil
                continuation.resume()
            }
        }
        listener.cancel()
    }
    let closed = try await PortService.check(host: "127.0.0.1", port: String(port), timeout: 1)
    #expect(!closed.connected)
    #expect(closed.latency < 2000)
}
