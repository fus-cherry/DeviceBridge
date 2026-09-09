import DeviceBridgeProtocol
import Foundation
import Network
import Testing
@testable import DeviceBridgeCore

@Suite("Helper TCP deadlines")
struct TCPHelperChannelTests {
    @Test("a silent local peer cannot hold the maintenance loop indefinitely", .timeLimit(.minutes(1)))
    func silentPeerTimeout() async throws {
        let peer = try SilentHelperPeer()
        let port = try await peer.start()
        let channel = try TCPHelperChannel(hostPort: port, timeout: .milliseconds(100))
        let start = ContinuousClock.now
        do {
            _ = try await channel.send(request())
            Issue.record("Silent peer unexpectedly replied")
        } catch {
            #expect(error as? TCPHelperChannelError == .timedOut)
        }
        #expect(start.duration(to: .now) < .seconds(3))
        await peer.stop()
    }

    @Test("cancellation releases a pending socket read", .timeLimit(.minutes(1)))
    func cancelledRead() async throws {
        let peer = try SilentHelperPeer()
        let port = try await peer.start()
        let channel = try TCPHelperChannel(hostPort: port, timeout: .seconds(30))
        let task = Task { try await channel.send(request()) }
        try await Task.sleep(for: .milliseconds(100))
        let start = ContinuousClock.now
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancelled request succeeded") } catch {}
        #expect(start.duration(to: .now) < .seconds(3))
        await peer.stop()
    }

    private func request() -> HelperRequest {
        HelperRequest(requestID: UUID(), sessionNonce: "fixture", helperDeviceID: "fixture",
            action: .identity, createdAt: Date(), expiresAt: Date().addingTimeInterval(5), payload: [:])
    }
}

private actor SilentHelperPeer {
    private let listener: NWListener
    private var connections: [NWConnection] = []

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> Int {
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            Task { await self.retain(connection) }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume()
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: .global())
        }
        return Int(try #require(listener.port).rawValue)
    }

    private func retain(_ connection: NWConnection) { connections.append(connection) }

    func stop() {
        listener.cancel()
        connections.forEach { $0.cancel() }
        connections.removeAll()
    }
}
