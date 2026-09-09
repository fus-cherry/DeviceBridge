import Foundation
import Darwin
import Testing
import DeviceBridgeSecureChannel
import DeviceBridgeProtocol
import DeviceBridgeTLSProbeSupport

struct IOSRunnerHandshakeProbeTests {
    @Test("CLI identity mode preserves bootstrap schemas and returns only public diagnostics")
    func cliIdentityMode() async throws {
        let fixture = try ProbeFixture()
        defer { fixture.removeDirectory() }
        let process = Process(), output = Pipe(), input = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/debug/DeviceBridgeTLSProbe")
        process.arguments = ["identity"]
        process.standardOutput = output; process.standardInput = input; process.standardError = errors
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: watchdog)
        defer { watchdog.cancel() }
        let first = try await Task.detached { () throws -> Data in
            var line = Data()
            while line.count < 16384, let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty {
                if byte == Data([10]) { return line }
                line.append(byte)
            }
            throw IOSRunnerHandshakeProbe.Failure.probeFailed
        }.value
        let host = try #require(JSONSerialization.jsonObject(with: first) as? [String: Any])
        #expect(Set(host.keys) == ["launchID", "hostCertificateDER"])
        let launchText = try #require(host["launchID"] as? String)
        let launch = try #require(UUID(uuidString: launchText))
        let certificateText = try #require(host["hostCertificateDER"] as? String)
        let certificate = try #require(Data(base64Encoded: certificateText))
        let server = Task { try await IOSRunnerHandshakeProbe.serve(port: fixture.port, launchID: launch,
            hostCertificateDER: certificate, recordURL: fixture.recordURL) }
        do {
            try await fixture.waitForRecord()
            let record = try Data(contentsOf: fixture.recordURL)
            let peerInput = try JSONSerialization.data(withJSONObject: ["port": Int(fixture.port), "record": record.base64EncodedString()])
            try input.fileHandleForWriting.write(contentsOf: peerInput + Data([10]))
            try input.fileHandleForWriting.close()
            let rest = await Task.detached { output.fileHandleForReading.readDataToEndOfFile() }.value
            process.waitUntilExit()
            try #require(process.terminationStatus == 0)
            let result = try #require(JSONSerialization.jsonObject(with: rest) as? [String: Any])
            #expect(Set(result.keys) == ["result", "publicCanary", "latencyMilliseconds", "idleBeforeCloseSeconds", "connectedSeconds"])
            #expect(result["result"] as? String == "identity-2-exchanges")
            #expect((result["latencyMilliseconds"] as? [Double])?.count == 2)
            #expect(UUID(uuidString: result["publicCanary"] as? String ?? "") != nil)
            #expect(try await server.value == "identity-2-exchanges")
            #expect(!FileManager.default.fileExists(atPath: fixture.recordURL.path))
        } catch {
            server.cancel(); _ = try? await server.value
            throw error
        }
    }

    @Test("identity probe completes two real TLS exchanges and removes its public record")
    func identityAndStop() async throws {
        let fixture = try ProbeFixture()
        defer { fixture.removeDirectory() }
        let server = fixture.serve()
        do {
            let peer = try await fixture.peer()
            let result = try await IOSRunnerHandshakeProbe.exchange(port: fixture.port, launchID: fixture.launch,
                identity: fixture.host, peerCertificateDER: peer)
            #expect(result.result == "identity-2-exchanges")
            #expect(UUID(uuidString: result.publicCanary) != nil)
            #expect(result.latencyMilliseconds.count == 2)
            #expect(result.latencyMilliseconds.allSatisfy { $0.isFinite && $0 >= 0 })
            #expect(result.connectedSeconds > 0)
            #expect(result.idleBeforeCloseSeconds == 0)
            #expect(try await server.value == "identity-2-exchanges")
            #expect(!FileManager.default.fileExists(atPath: fixture.recordURL.path))
        } catch {
            server.cancel(); _ = try? await server.value
            throw error
        }
    }

    @Test("stop rejects mismatched binding or expiry and cleans up", arguments: ["nonce", "launch", "helper", "action", "expired", "version", "extra"])
    func invalidStop(field: String) async throws {
        let fixture = try ProbeFixture()
        defer { fixture.removeDirectory() }
        let server = fixture.serve()
        do {
            let peer = try await fixture.peer()
            let stream = try await PinnedTLSFrameStream.connect(localPort: fixture.port, identity: fixture.host, peerCertificateDER: peer)
            let session = try await IOSRunnerIdentityHandshake.openHost(stream: stream, launchID: fixture.launch,
                helperBuild: "devicebridge-ios-identity-v1", requiredActions: [.identity, .stop])
            let onlyDiagnosticActions = session.allowedActions == [.identity, .stop]
            #expect(onlyDiagnosticActions)
            let now = Date()
            var stop = HelperRequest(requestID: UUID(), sessionNonce: session.sessionNonce,
                helperDeviceID: session.helperDeviceID, action: .stop, createdAt: now,
                expiresAt: now.addingTimeInterval(5), payload: ["launchId": .string(fixture.launch.uuidString)])
            switch field {
            case "nonce": stop.sessionNonce = "public-invalid-nonce"
            case "launch": stop.payload["launchId"] = .string(UUID().uuidString)
            case "helper": stop.helperDeviceID = "wrong-public-helper"
            case "action": stop.action = .clipboardRead
            case "expired": stop.expiresAt = now.addingTimeInterval(-1)
            case "version": stop.protocolVersion = 2
            default: stop.payload["extra"] = .bool(true)
            }
            try await stream.writeFrame(HelperWireCodec().encode(stop))
            await #expect(throws: IOSRunnerHandshakeProbe.Failure.probeFailed) { try await server.value }
            await stream.close()
            #expect(!FileManager.default.fileExists(atPath: fixture.recordURL.path))
        } catch {
            server.cancel(); _ = try? await server.value
            throw error
        }
    }

    @Test("cancellation cleans up only the probe-owned public record", arguments: [false, true])
    func cancelPreservesReplacement(replace: Bool) async throws {
        let fixture = try ProbeFixture()
        defer { fixture.removeDirectory() }
        let server = fixture.serve()
        do {
            _ = try await fixture.peer()
            let replacement = Data("public replacement".utf8)
            if replace { try replacement.write(to: fixture.recordURL, options: .atomic) }
            let start = ContinuousClock.now
            server.cancel()
            await #expect(throws: IOSRunnerHandshakeProbe.Failure.probeFailed) { try await server.value }
            #expect(start.duration(to: .now) < .seconds(1))
            if replace { #expect(try Data(contentsOf: fixture.recordURL) == replacement) }
            else { #expect(!FileManager.default.fileExists(atPath: fixture.recordURL.path)) }
        } catch {
            server.cancel(); _ = try? await server.value
            throw error
        }
    }

    @Test("host rejects stop replies not bound to its request and session", arguments: ["request", "nonce", "launch", "helper", "expired", "status"])
    func invalidStopReply(field: String) async throws {
        let fixture = try ProbeFixture()
        let identity = try EphemeralTLSIdentity.create()
        let listener = try await PinnedTLSFrameStream.listen(identity: identity, peerCertificateDER: fixture.host.certificateDER)
        let runner = Task {
            let stream = try await listener.accept()
            do {
                let session = try await IOSRunnerIdentityHandshake.acceptRunner(stream: stream, launchID: fixture.launch,
                    helperBuild: "devicebridge-ios-identity-v1", allowedActions: [.identity, .stop])
                let codec = HelperWireCodec()
                let stop = try codec.decodeRequest(await stream.readFrame(timeout: 2))
                var payload: [String: JSONValue] = ["launchId": .string(fixture.launch.uuidString),
                    "sessionNonce": .string(session.sessionNonce), "helperDeviceId": .string(session.helperDeviceID)]
                if field == "nonce" { payload["sessionNonce"] = .string("invalid-public-nonce") }
                if field == "launch" { payload["launchId"] = .string(UUID().uuidString) }
                if field == "helper" { payload["helperDeviceId"] = .string("wrong-public-helper") }
                let reply = HelperResult(requestID: field == "request" ? UUID() : stop.requestID,
                    status: field == "status" ? .failure : .success,
                    completedAt: field == "expired" ? stop.expiresAt.addingTimeInterval(1) : Date(), payload: payload)
                try await stream.writeFrame(codec.encode(reply), timeout: 2)
                await stream.close()
            } catch { await stream.close(); throw IOSRunnerHandshakeProbe.Failure.probeFailed }
        }
        await #expect(throws: IOSRunnerHandshakeProbe.Failure.probeFailed) {
            try await IOSRunnerHandshakeProbe.exchange(port: listener.port, launchID: fixture.launch,
                identity: fixture.host, peerCertificateDER: identity.certificateDER)
        }
        _ = try? await runner.value
        await listener.close()
    }
}

private struct ProbeFixture: Sendable {
    let host: EphemeralTLSIdentity
    let launch = UUID()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("identity-probe-test-" + UUID().uuidString)
    let port: UInt16
    var recordURL: URL { directory.appendingPathComponent(launch.uuidString + ".json") }

    init() throws {
        host = try EphemeralTLSIdentity.create()
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { Darwin.close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let status = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, length) == 0 ? getsockname(fd, $0, &length) : -1
            }
        }
        guard status == 0 else { throw POSIXError(.EIO) }
        port = UInt16(bigEndian: address.sin_port)
    }

    func serve() -> Task<String, Error> {
        Task { try await IOSRunnerHandshakeProbe.serve(port: port, launchID: launch,
            hostCertificateDER: host.certificateDER, recordURL: recordURL) }
    }

    func peer() async throws -> Data {
        try await waitForRecord()
        return try PublicBootstrapRecord.validate(Data(contentsOf: recordURL), launchID: launch,
            hostCertificateDER: host.certificateDER, helperBuild: "devicebridge-ios-identity-v1")
    }

    func waitForRecord() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !FileManager.default.fileExists(atPath: recordURL.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        guard FileManager.default.fileExists(atPath: recordURL.path) else { throw IOSRunnerHandshakeProbe.Failure.probeFailed }
    }

    func removeDirectory() { try? FileManager.default.removeItem(at: directory) }
}
