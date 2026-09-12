import Foundation
import Testing
import Darwin
import DeviceBridgeSecureChannel
import DeviceBridgeTLSProbeSupport

@Suite(.serialized)
struct TLSIdentityProbeTests {
    @Test(arguments: [TLSIdentityProbe.Mode.normal, .orphan, .invalid, .disconnect, .partial, .sustain])
    func realTLSLifecycle(mode: TLSIdentityProbe.Mode) async throws {
        let host = try EphemeralTLSIdentity.create()
        let launch = UUID()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("devicebridge-public-test-" + UUID().uuidString)
        let recordURL = directory.appendingPathComponent(launch.uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let port = try unusedPort()
        let server = TLSIdentityProbe(isServer: true, lifetimeSeconds: mode == .sustain ? 0.5 : 3)
        let task = Task.detached {
            try server.serve(port: port, launchID: launch, hostCertificateDER: host.certificateDER,
                recordURL: recordURL, leaseSeconds: 0.2)
        }
        do {
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while !FileManager.default.fileExists(atPath: recordURL.path), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            let record = try Data(contentsOf: recordURL)
            let peer = try PublicBootstrapRecord.validate(record, launchID: launch, hostCertificateDER: host.certificateDER,
                helperBuild: TLSIdentityProbe.helperBuild)
            let client = TLSIdentityProbe(isServer: false, lifetimeSeconds: 3)
            let clientResult = try await Task.detached {
                try client.exchange(port: port, identity: host,
                    peerCertificateDER: peer, publicCanary: String(repeating: "a", count: 32), mode: mode)
            }.value
            let serverResult = try await task.value
            switch mode {
            case .normal:
                #expect(clientResult == "tls13-31-exchanges")
                #expect(serverResult == "tls13-31-exchanges")
            case .orphan, .partial:
                #expect(clientResult == "peerClosed")
                #expect(serverResult == "leaseExpired")
                #expect((0.15...0.8).contains(client.idleBeforeCloseSeconds))
                #expect(client.latencyMilliseconds.count == 30)
            case .invalid:
                #expect(clientResult == "peerClosed")
                #expect(serverResult == "invalidFrame")
            case .disconnect:
                #expect(clientResult == "clientDisconnected")
                #expect(serverResult == "peerClosed")
            case .sustain:
                // After established exchanges, server cancellation may arrive through either
                // the receive callback or NWConnection.failed. Callback order is not guaranteed.
                // The deadline result and exchange count below rule out handshake rejection.
                #expect(clientResult == "peerClosed" || clientResult == "connectionRejected")
                #expect(serverResult == "deadlineExpired")
                #expect(client.latencyMilliseconds.count >= 2)
                #expect((0.35...1.5).contains(client.connectedSeconds))
            case .heartbeat: Issue.record("Not selected by this fast test")
            }
            #expect(!FileManager.default.fileExists(atPath: recordURL.path))
        } catch {
            _ = try? await task.value
            throw error
        }
    }

    private func unusedPort() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, size) == 0 ? getsockname(descriptor, $0, &size) : -1
            }
        }
        guard result == 0 else { throw POSIXError(.EIO) }
        return UInt16(bigEndian: address.sin_port)
    }
}
