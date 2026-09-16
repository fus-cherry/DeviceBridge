import Foundation
import Network
import CryptoKit
import zlib
import Testing
import DeviceBridgeProtocol
@testable import DeviceBridgeSecureChannel

struct IOSRunnerSessionServerTests {
    @Test func multiChunkScreenshotKeepsBytesOrderedAndCorrelatesInterleavedHeartbeat() async throws {
        let handler = LargeScreenshotFixture()
        let running = try await RunningSession.start(maximum: .seconds(10), screenshotHandler: handler)
        do {
            let request = running.request(.screenshotCapture)
            let descriptor = try await running.send(request)
            #expect(descriptor.status == .success)
            let heartbeat = running.request(.identity)
            try await running.host.writeFrame(HelperWireCodec().encode(heartbeat))
            var bytes = Data(), chunks = 0, heartbeatReceived = false
            while bytes.count < handler.png.count || !heartbeatReceived {
                let frame = try await running.host.readFrame(timeout: 2)
                if IOSRunnerScreenshotWire.isAttachmentFrame(frame) {
                    let chunk = try IOSRunnerScreenshotWire.decodeChunk(frame)
                    #expect(chunk.requestID == request.requestID)
                    #expect(chunk.offset == bytes.count)
                    bytes.append(chunk.bytes); chunks += 1
                } else {
                    let result = try HelperWireCodec().decodeResult(frame)
                    try #require(!heartbeatReceived && result.requestID == heartbeat.requestID && result.status == .success)
                    heartbeatReceived = true
                }
            }
            #expect(chunks == 3)
            #expect(bytes == handler.png)
            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            #expect(descriptor.payload?["sha256"] == .string(digest))
            _ = try await running.send(running.request(.stop))
            #expect(try await running.task.value == .stopped)
        } catch { await running.cancel(); throw error }
    }

    @Test func screenshotSendsDescriptorThenExactRequestBoundBinaryBytes() async throws {
        let handler = ScreenshotBytesFixture()
        let running = try await RunningSession.start(screenshotHandler: handler)
        do {
            let request = running.request(.screenshotCapture)
            let reply = try await running.send(request)
            #expect(reply.status == .success)
            #expect(reply.payload == handler.payload)
            let chunk = try IOSRunnerScreenshotWire.decodeChunk(await running.host.readFrame(timeout: 2))
            #expect(chunk.requestID == request.requestID)
            #expect(chunk.offset == 0)
            #expect(chunk.bytes == handler.png)
            _ = try await running.send(running.request(.stop))
            #expect(try await running.task.value == .stopped)
        } catch { await running.cancel(); throw error }
    }

    @Test func screenshotFailureIsCorrelatedWithoutAnAttachment() async throws {
        let running = try await RunningSession.start(screenshotHandler: ScreenshotFailureFixture())
        do {
            try #require(running.session.allowedActions.contains(.screenshotCapture))
            let request = running.request(.screenshotCapture)
            let reply = try await running.send(request)
            #expect(reply.requestID == request.requestID)
            #expect(reply.status == .actionRequired)
            #expect(reply.payload == nil)
            #expect(try await running.send(running.request(.identity)).status == .success)
            _ = try await running.send(running.request(.stop))
            #expect(try await running.task.value == .stopped)
        } catch { await running.cancel(); throw error }
    }

    @Test func heartbeatAndStopBypassAnUncooperativeScreenCapture() async throws {
        let handler = GatedScreenshotFixture()
        let running = try await RunningSession.start(screenshotHandler: handler)
        do {
            try #require(running.session.allowedActions.contains(.screenshotCapture))
            try await running.host.writeFrame(HelperWireCodec().encode(running.request(.screenshotCapture)))
            try await handler.waitUntilEntered()
            #expect(try await running.send(running.request(.identity)).status == .success)
            #expect(try await running.send(running.request(.stop)).status == .success)
            #expect(try await running.task.value == .stopped)
            await handler.release()
        } catch { await handler.release(); await running.cancel(); throw error }
    }

    @Test("queued execution preserves the caller's original maximum deadline")
    func queueDelayCannotExtendMaximum() {
        let captured = ContinuousClock.now
        let maximumDeadline = captured.advanced(by: .seconds(10))
        let executed = captured.advanced(by: .seconds(3))
        let deadlines = IOSRunnerSessionDeadlines(now: executed, maximumDeadline: maximumDeadline, leaseDuration: .seconds(30))
        #expect(deadlines.maximumDeadline == maximumDeadline)
        #expect(deadlines.expired(at: maximumDeadline) == .lifetimeExpired)
    }

    @Test("an already elapsed caller deadline closes without starting identity")
    func expiredBeforeEntry() async throws {
        let (host, runner) = try await RunningSession.pair()
        let maximumDeadline = ContinuousClock.now.advanced(by: .seconds(-1))
        let result = try await IOSRunnerSessionServer.run(stream: runner, launchID: UUID(),
            maximumDeadline: maximumDeadline)
        #expect(result == .lifetimeExpired)
        // The peer never sent a first identity frame; any handshake attempt would wait here.
        await #expect(throws: PinnedTLSFrameStream.Failure.closed) { try await host.readFrame(timeout: 1) }
        await host.close()
    }

    @Test("reply completion at or after lease expiry never renews", arguments: [100, 101])
    func lateReplyCannotRenew(milliseconds: Int) throws {
        let started = ContinuousClock.now
        var deadlines = IOSRunnerSessionDeadlines(now: started, maximumDeadline: started.advanced(by: .seconds(1)), leaseDuration: .milliseconds(100))
        let original = deadlines.lease
        #expect(throws: IOSRunnerSessionServer.Failure.rejected) {
            try deadlines.renew(at: started.advanced(by: .milliseconds(milliseconds)))
        }
        #expect(deadlines.lease == original)
    }

    @Test("renewal never moves the maximum lifetime or revives expiry")
    func maximumRemainsAbsolute() throws {
        let started = ContinuousClock.now
        var deadlines = IOSRunnerSessionDeadlines(now: started, maximumDeadline: started.advanced(by: .milliseconds(200)), leaseDuration: .milliseconds(150))
        try deadlines.renew(at: started.advanced(by: .milliseconds(100)))
        #expect(deadlines.maximumDeadline == started.advanced(by: .milliseconds(200)))
        let original = deadlines.lease
        #expect(throws: IOSRunnerSessionServer.Failure.rejected) {
            try deadlines.renew(at: started.advanced(by: .milliseconds(200)))
        }
        #expect(deadlines.lease == original)
        #expect(deadlines.expired(at: started.advanced(by: .milliseconds(200))) == .lifetimeExpired)
    }

    @Test("real TLS identity heartbeats renew a lease and stop returns an empty success")
    func heartbeatAndStop() async throws {
        let running = try await RunningSession.start(lease: .milliseconds(250))
        do {
            for _ in 0..<4 {
                try await Task.sleep(for: .milliseconds(90))
                let result = try await running.send(running.request(.identity))
                let valid = result.status == .success && result.payload == [
                    "helperDeviceId": .string(running.session.helperDeviceID),
                    "helperVersion": .string("devicebridge-ios-runner-v1"),
                    "protocolVersions": .array([.number(1)])]
                #expect(valid)
            }
            let stop = running.request(.stop)
            let result = try await running.send(stop)
            let valid = result.requestID == stop.requestID && result.status == .success && result.payload == [:]
            #expect(valid)
            #expect(try await running.task.value == .stopped)
            await running.host.close()
        } catch { await running.cancel(); throw error }
    }

    @Test("only session-bound fresh empty requests are accepted", arguments: ["nonce", "helper", "version", "expired", "payload", "content", "replay", "bootstrapReplay"])
    func rejectsInvalidRequest(mutation: String) async throws {
        let running = try await RunningSession.start()
        do {
            var request = running.request(.identity)
            switch mutation {
            case "nonce": request.sessionNonce = "public-invalid-nonce"
            case "helper": request.helperDeviceID = "other-public-helper"
            case "version": request.protocolVersion = 2
            case "expired": request.expiresAt = Date().addingTimeInterval(-1)
            case "payload": request.payload = ["extra": .bool(true)]
            case "content": request.action = .clipboardRead
            case "replay": _ = try await running.send(request)
            default: request.requestID = running.session.bootstrapRequestID
            }
            try await running.host.writeFrame(HelperWireCodec().encode(request))
            let expected: IOSRunnerSessionServer.Failure = ["replay", "bootstrapReplay"].contains(mutation) ? .replay : .rejected
            await #expect(throws: expected) { try await running.task.value }
            await running.host.close()
        } catch { await running.cancel(); throw error }
    }

    @Test("idle lease expires and cancellation closes pending reads")
    func idleAndCancellation() async throws {
        let idle = try await RunningSession.start(lease: .milliseconds(150))
        #expect(try await idle.task.value == .leaseExpired)
        await idle.host.close()
        let running = try await RunningSession.start()
        let started = ContinuousClock.now
        running.task.cancel()
        await #expect(throws: IOSRunnerSessionServer.Failure.cancelled) { try await running.task.value }
        #expect(started.duration(to: .now) < .seconds(1))
        await #expect(throws: PinnedTLSFrameStream.Failure.closed) { try await running.host.readFrame(timeout: 1) }
        await running.host.close()
    }

    @Test("1024-ID ledger includes bootstrap and terminates without evicting replay history")
    func boundedReplayLedger() async throws {
        let running = try await RunningSession.start(maximum: .seconds(10))
        do {
            for _ in 0..<1023 { _ = try await running.send(running.request(.identity)) }
            try await running.host.writeFrame(HelperWireCodec().encode(running.request(.identity)))
            await #expect(throws: IOSRunnerSessionServer.Failure.requestLimitReached) { try await running.task.value }
            await running.host.close()
        } catch { await running.cancel(); throw error }
    }

    @Test("partial frame traffic cannot renew the absolute lease")
    func partialTrafficExpires() async throws {
        let hostIdentity = try EphemeralTLSIdentity.create(), runnerIdentity = try EphemeralTLSIdentity.create()
        let launch = UUID(), now = Date()
        let bootstrap = HelperRequest(requestID: UUID(), sessionNonce: Data(repeating: 1, count: 32).base64EncodedString(),
            helperDeviceID: "bootstrap", action: .identity, createdAt: now, expiresAt: now.addingTimeInterval(5),
            payload: ["launchId": .string(launch.uuidString), "challenge": .string(Data(repeating: 2, count: 32).base64EncodedString())])
        let frame = try HelperFrameCodec.encode(HelperWireCodec().encode(bootstrap))
        let chunks = [frame, Data([0, 0, 0, 100])] + Array(repeating: Data([32]), count: 10)
        let peer = try PartialSessionPeer(identity: hostIdentity, pin: runnerIdentity.certificateDER, chunks: chunks)
        let port = try await peer.start()
        defer { peer.close() }
        let stream = try await PinnedTLSFrameStream.connect(localPort: port, identity: runnerIdentity, peerCertificateDER: hostIdentity.certificateDER)
        let started = ContinuousClock.now
        let result = try await IOSRunnerSessionServer.run(stream: stream, launchID: launch,
            maximumDeadline: started.advanced(by: .seconds(2)), leaseDuration: .milliseconds(150))
        #expect(result == .leaseExpired)
        #expect(started.duration(to: .now) < .milliseconds(350))
    }

    @Test("maximum lifetime includes a silent initial identity handshake")
    func lifetimeIncludesHandshake() async throws {
        let (host, runner) = try await RunningSession.pair()
        let started = ContinuousClock.now
        let result = try await IOSRunnerSessionServer.run(stream: runner, launchID: UUID(),
            maximumDeadline: started.advanced(by: .milliseconds(100)), leaseDuration: .seconds(1))
        #expect(result == .lifetimeExpired)
        #expect(started.duration(to: .now) < .seconds(1))
        await host.close()
    }

    @Test("continuous complete heartbeats cannot extend maximum lifetime", arguments: [0, 250])
    func heartbeatsCannotExtendLifetime(heartbeatDelayMilliseconds: Int) async throws {
        // This case tests the maximum lifetime, independently of idle lease expiry.
        // A delayed CI heartbeat must not lose a race against an unrelated shorter lease.
        let started = ContinuousClock.now
        let running = try await RunningSession.start(lease: .seconds(2), maximum: .seconds(1))
        var traffic: Task<Void, Error>?
        do {
            try await Task.sleep(for: .milliseconds(heartbeatDelayMilliseconds))
            // Prove actual authenticated heartbeats happened; a failed background task
            // followed by silent lifetime expiry must not satisfy this test.
            for _ in 0..<2 {
                let request = running.request(.identity)
                let reply = try await running.send(request)
                try #require(reply.requestID == request.requestID && reply.status == .success)
            }
            traffic = Task {
                while !Task.isCancelled {
                    _ = try await running.send(running.request(.identity))
                    try await Task.sleep(for: .milliseconds(50))
                }
            }
            let exit = try await running.task.value
            traffic?.cancel(); _ = try? await traffic?.value
            #expect(exit == .lifetimeExpired)
            #expect(started.duration(to: .now) < .seconds(3))
            await running.host.close()
        } catch {
            traffic?.cancel(); await running.cancel(); _ = try? await traffic?.value
            throw error
        }
    }

    @Test("invalid lease configuration closes the stream", arguments: [Duration.zero, .seconds(-1), .seconds(31)])
    func invalidConfiguration(lease: Duration) async throws {
        let (host, runner) = try await RunningSession.pair()
        await #expect(throws: IOSRunnerSessionServer.Failure.invalidConfiguration) {
            try await IOSRunnerSessionServer.run(stream: runner, launchID: UUID(),
                maximumDeadline: .now.advanced(by: .seconds(10)), leaseDuration: lease)
        }
        await #expect(throws: PinnedTLSFrameStream.Failure.closed) { try await host.readFrame(timeout: 1) }
        await host.close()
    }

    @Test("an excessively distant maximum deadline closes as invalid configuration")
    func maximumTooDistant() async throws {
        let (host, runner) = try await RunningSession.pair()
        await #expect(throws: IOSRunnerSessionServer.Failure.invalidConfiguration) {
            try await IOSRunnerSessionServer.run(stream: runner, launchID: UUID(),
                maximumDeadline: .now.advanced(by: .seconds(86_401)))
        }
        await #expect(throws: PinnedTLSFrameStream.Failure.closed) { try await host.readFrame(timeout: 1) }
        await host.close()
    }
}

extension IOSRunnerSessionServerTests {
    @Test("clipboard capabilities are authenticated only when a handler is installed")
    func clipboardCapabilities() async throws {
        let running = try await RunningSession.start(clipboardHandler: GatedClipboardHandler())
        #expect(running.session.allowedActions == [.identity, .stop, .clipboardRead, .clipboardWrite])
        await running.cancel()
    }

    @Test("heartbeats and Stop complete while clipboard ignores cancellation; late result is discarded")
    func metadataBypassesBlockedClipboard() async throws {
        let handler = GatedClipboardHandler()
        let running = try await RunningSession.start(lease: .milliseconds(400), clipboardHandler: handler)
        do {
            let read = running.request(.clipboardRead)
            try await running.host.writeFrame(HelperWireCodec().encode(read))
            try await handler.waitUntilEntered()
            for _ in 0..<4 {
                try await Task.sleep(for: .milliseconds(120))
                let heartbeat = running.request(.identity)
                let result = try await running.send(heartbeat)
                #expect(result.requestID == heartbeat.requestID && result.status == .success)
            }
            let stop = running.request(.stop)
            let stoppedAt = ContinuousClock.now
            let result = try await running.send(stop)
            #expect(result.requestID == stop.requestID && result.payload == [:])
            #expect(try await running.task.value == .stopped)
            #expect(stoppedAt.duration(to: .now) < .seconds(1))
            await handler.release()
            await #expect(throws: PinnedTLSFrameStream.Failure.closed) { try await running.host.readFrame(timeout: 1) }
            #expect(await handler.callCount == 1)
            await running.host.close()
        } catch { await handler.release(); await running.cancel(); throw error }
    }

    @Test("blocked clipboard cancellation and session expiry return without joining handler", arguments: ["cancel", "lease", "maximum"])
    func blockedClipboardTeardown(reason: String) async throws {
        let handler = GatedClipboardHandler()
        let running = try await RunningSession.start(lease: reason == "lease" ? .milliseconds(300) : .seconds(2),
            maximum: reason == "maximum" ? .milliseconds(300) : .seconds(3), clipboardHandler: handler)
        do {
            try await running.host.writeFrame(HelperWireCodec().encode(running.request(.clipboardRead)))
            try await handler.waitUntilEntered()
            let started = ContinuousClock.now
            if reason == "cancel" {
                running.task.cancel()
                await #expect(throws: IOSRunnerSessionServer.Failure.cancelled) { try await running.task.value }
            } else {
                #expect(try await running.task.value == (reason == "lease" ? .leaseExpired : .lifetimeExpired))
            }
            #expect(started.duration(to: .now) < .seconds(1))
            await handler.release()
            await #expect(throws: PinnedTLSFrameStream.Failure.closed) { try await running.host.readFrame(timeout: 1) }
            await running.host.close()
        } catch { await handler.release(); await running.cancel(); throw error }
    }

    @Test("a blocked content request expires even while metadata renews the session")
    func clipboardExpiryDespiteHeartbeat() async throws {
        let handler = GatedClipboardHandler()
        let running = try await RunningSession.start(clipboardHandler: handler)
        do {
            var read = running.request(.clipboardRead)
            read.expiresAt = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) + 2)
            try await running.host.writeFrame(HelperWireCodec().encode(read))
            try await handler.waitUntilEntered()
            let traffic = Task {
                while !Task.isCancelled {
                    _ = try await running.send(running.request(.identity))
                    try await Task.sleep(for: .milliseconds(80))
                }
            }
            await #expect(throws: IOSRunnerSessionServer.Failure.rejected) { try await running.task.value }
            traffic.cancel(); _ = try? await traffic.value
            await handler.release()
            await #expect(throws: PinnedTLSFrameStream.Failure.closed) { try await running.host.readFrame(timeout: 1) }
            await running.host.close()
        } catch { await handler.release(); await running.cancel(); throw error }
    }

    @Test("completed content expiry does not remain the next read's session deadline")
    func completedClipboardDoesNotShortenIdleLease() async throws {
        let handler = GatedClipboardHandler(released: true)
        let running = try await RunningSession.start(lease: .seconds(3), maximum: .seconds(4), clipboardHandler: handler)
        do {
            var read = running.request(.clipboardRead)
            read.expiresAt = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) + 2)
            let result = try await running.send(read)
            #expect(result.payload == ["text": .string("public-clipboard-fixture")])
            try await Task.sleep(for: .seconds(read.expiresAt.timeIntervalSinceNow + 0.1))
            let stop = try await running.send(running.request(.stop))
            #expect(stop.status == .success)
            #expect(try await running.task.value == .stopped)
            await running.host.close()
        } catch { await running.cancel(); throw error }
    }

    @Test("invalid clipboard requests are rejected before handler invocation", arguments: ["readPayload", "missingText", "textType", "sensitivityType", "extraWrite", "oversize", "nonce", "expiry", "bootstrapReplay"])
    func clipboardAdmissionRejects(mutation: String) async throws {
        let handler = GatedClipboardHandler(released: true)
        let running = try await RunningSession.start(clipboardHandler: handler)
        do {
            var request = running.request(.clipboardWrite)
            request.payload = ["text": .string("public-marker")]
            switch mutation {
            case "readPayload": request.action = .clipboardRead
            case "missingText": request.payload = [:]
            case "textType": request.payload = ["text": .number(1)]
            case "sensitivityType": request.payload["sensitive"] = .string("yes")
            case "extraWrite": request.payload["extra"] = .bool(true)
            case "oversize": request.payload = ["text": .string(String(repeating: "é", count: 524_289))]
            case "nonce": request.sessionNonce = "invalid-public-nonce"
            case "expiry": request.expiresAt = Date().addingTimeInterval(-1)
            default: request.requestID = running.session.bootstrapRequestID
            }
            try await running.host.writeFrame(HelperWireCodec().encode(request))
            let expected: IOSRunnerSessionServer.Failure = mutation == "bootstrapReplay" ? .replay : .rejected
            await #expect(throws: expected) { try await running.task.value }
            #expect(await handler.callCount == 0)
            await running.host.close()
        } catch { await running.cancel(); throw error }
    }

    @Test("in-flight IDs cannot replay and a second content request fails bounded", arguments: [true, false])
    func boundedClipboardAdmission(replay: Bool) async throws {
        let handler = GatedClipboardHandler()
        let running = try await RunningSession.start(clipboardHandler: handler)
        do {
            var write = running.request(.clipboardWrite)
            write.payload = ["text": .string("public-write-marker"), "sensitive": .bool(true)]
            try await running.host.writeFrame(HelperWireCodec().encode(write))
            try await handler.waitUntilEntered()
            if !replay { write.requestID = UUID() }
            try await running.host.writeFrame(HelperWireCodec().encode(write))
            let expected: IOSRunnerSessionServer.Failure = replay ? .replay : .rejected
            await #expect(throws: expected) { try await running.task.value }
            #expect(await handler.callCount == 1)
            await handler.release()
            await running.host.close()
        } catch { await handler.release(); await running.cancel(); throw error }
    }

    @Test("complete 1 MiB UTF-8 writes return only acknowledgement and cannot replay")
    func clipboardWriteLimitAndCompletedReplay() async throws {
        let handler = GatedClipboardHandler(released: true)
        let running = try await RunningSession.start(clipboardHandler: handler)
        do {
            var write = running.request(.clipboardWrite)
            write.payload = ["text": .string(String(repeating: "é", count: 524_288)), "sensitive": .bool(false)]
            let result = try await running.send(write)
            #expect(result.requestID == write.requestID && result.payload == ["written": .bool(true)])
            try await running.host.writeFrame(HelperWireCodec().encode(write))
            await #expect(throws: IOSRunnerSessionServer.Failure.replay) { try await running.task.value }
            #expect(await handler.callCount == 1)
            await running.host.close()
        } catch { await running.cancel(); throw error }
    }

    @Test("malformed clipboard handler results close the channel before publication", arguments: ["id", "version", "expired", "future", "beforeRequest", "textType", "oversize", "extra", "disposition", "errorWithPayload", "writeEcho"])
    func malformedClipboardResults(mutation: String) async throws {
        let handler = ClipboardResultFixture { request in
            let write = request.action == .clipboardWrite
            var payload: [String: JSONValue] = write ? ["written": .bool(true)] : ["text": .string("public-fixture")]
            switch mutation {
            case "textType": payload = ["text": .number(1)]
            case "oversize": payload = ["text": .string(String(repeating: "é", count: 524_289))]
            case "extra", "writeEcho": payload["extra"] = .string("must-not-publish")
            case "disposition": payload["foregroundDisposition"] = .string("unknown")
            default: break
            }
            let completedAt: Date
            switch mutation {
            case "expired": completedAt = request.expiresAt
            case "future": completedAt = Date().addingTimeInterval(1)
            case "beforeRequest": completedAt = request.createdAt.addingTimeInterval(-1)
            default: completedAt = Date()
            }
            return HelperResult(protocolVersion: mutation == "version" ? 2 : 1,
                requestID: mutation == "id" ? UUID() : request.requestID,
                status: mutation == "errorWithPayload" ? .permissionDenied : .success,
                completedAt: completedAt, payload: payload,
                error: mutation == "errorWithPayload" ? HelperErrorPayload(code: "clipboard.denied", message: "Denied") : nil)
        }
        let running = try await RunningSession.start(clipboardHandler: handler)
        do {
            var request = running.request(mutation == "writeEcho" ? .clipboardWrite : .clipboardRead)
            if request.action == .clipboardWrite { request.payload = ["text": .string("public-fixture")] }
            try await running.host.writeFrame(HelperWireCodec().encode(request))
            await #expect(throws: IOSRunnerSessionServer.Failure.rejected) { try await running.task.value }
            await #expect(throws: PinnedTLSFrameStream.Failure.closed) { try await running.host.readFrame(timeout: 1) }
            await running.host.close()
        } catch { await running.cancel(); throw error }
    }

    @Test("permission denial remains a terminal request result while metadata is usable")
    func clipboardDenial() async throws {
        let handler = ClipboardResultFixture { request in
            HelperResult(requestID: request.requestID, status: .permissionDenied, completedAt: Date(),
                error: HelperErrorPayload(code: "clipboard.denied", message: "Clipboard access denied."))
        }
        let running = try await RunningSession.start(clipboardHandler: handler)
        do {
            let result = try await running.send(running.request(.clipboardRead))
            #expect(result.status == .permissionDenied && result.payload == nil && result.error?.code == "clipboard.denied")
            #expect(try await running.send(running.request(.stop)).status == .success)
            #expect(try await running.task.value == .stopped)
            await running.host.close()
        } catch { await running.cancel(); throw error }
    }

    @Test("accepted host clock skew does not reject a fresh local clipboard result")
    func clipboardHostClockSkew() async throws {
        let handler = ClipboardResultFixture { request in
            HelperResult(requestID: request.requestID, status: .success, completedAt: Date(), payload: [
                "text": .string("public-clipboard-fixture"),
                "foregroundDisposition": .string("clipboardHostRemainsForeground"),
            ])
        }
        let running = try await RunningSession.start(clipboardHandler: handler)
        do {
            var request = running.request(.clipboardRead)
            request.createdAt = Date().addingTimeInterval(10)
            request.expiresAt = Date().addingTimeInterval(15)
            let result = try await running.send(request)
            #expect(result.status == .success && result.payload == [
                "text": .string("public-clipboard-fixture"),
                "foregroundDisposition": .string("clipboardHostRemainsForeground"),
            ])
            _ = try await running.send(running.request(.stop))
            #expect(try await running.task.value == .stopped)
            await running.host.close()
        } catch { await running.cancel(); throw error }
    }

    @Test("Stop cancels clipboard before sending acknowledgement")
    func stopCancelsClipboardBeforeAcknowledgement() async throws {
        let cancellation = PausedClipboardCancellation()
        // Always release the synchronous fixture gate, including assertion/error paths.
        defer { cancellation.release() }
        let handler = CooperativeClipboardHandler(cancellation: cancellation)
        let running = try await RunningSession.start(clipboardHandler: handler)
        let replyObservation = StopReplyObservation()
        var stopTask: Task<HelperResult, Error>?
        do {
            var write = running.request(.clipboardWrite)
            write.payload = ["text": .string("public-write-marker")]
            try await running.host.writeFrame(HelperWireCodec().encode(write))
            try await handler.waitUntilEntered()
            let sendingStop = Task {
                let result = try await running.send(running.request(.stop))
                await replyObservation.receivedReply()
                return result
            }
            stopTask = sendingStop
            try await cancellation.waitUntilEntered()
            // The fixture holds the synchronous cancellation callback. Old teardown ordering
            // had already sent Stop; correct admission ordering has not started that write.
            try await Task.sleep(for: .milliseconds(80))
            #expect(await replyObservation.received == false)
            cancellation.release()
            await handler.release()
            #expect(try await sendingStop.value.status == .success)
            #expect(try await running.task.value == .stopped)
            #expect(await handler.writeCount == 0)
            await running.host.close()
        } catch {
            cancellation.release()
            await handler.release()
            stopTask?.cancel()
            await running.cancel()
            throw error
        }
    }

    @Test("terminal failures cancel clipboard before awaiting transport close", arguments: ["invalid", "cancel"])
    func failureCancelsClipboardBeforeClose(reason: String) async throws {
        let cancellation = PausedClipboardCancellation()
        defer { cancellation.release() }
        let handler = CooperativeClipboardHandler(cancellation: cancellation)
        let running = try await RunningSession.start(clipboardHandler: handler)
        let closeObservation = StopReplyObservation()
        var peerRead: Task<Void, Never>?
        do {
            var write = running.request(.clipboardWrite)
            write.payload = ["text": .string("public-write-marker")]
            try await running.host.writeFrame(HelperWireCodec().encode(write))
            try await handler.waitUntilEntered()
            let readingClose = Task {
                _ = try? await running.host.readFrame(timeout: 2)
                await closeObservation.receivedReply()
            }
            peerRead = readingClose
            if reason == "cancel" { running.task.cancel() }
            else {
                var invalid = running.request(.identity)
                invalid.sessionNonce = "invalid-public-nonce"
                try await running.host.writeFrame(HelperWireCodec().encode(invalid))
            }
            try await cancellation.waitUntilEntered()
            try await Task.sleep(for: .milliseconds(80))
            #expect(await closeObservation.received == false)
            cancellation.release()
            await handler.release()
            let expected: IOSRunnerSessionServer.Failure = reason == "cancel" ? .cancelled : .rejected
            await #expect(throws: expected) { try await running.task.value }
            await readingClose.value
            #expect(await handler.writeCount == 0)
            await running.host.close()
        } catch {
            cancellation.release()
            await handler.release()
            peerRead?.cancel()
            await running.cancel()
            throw error
        }
    }
}

private actor StopReplyObservation {
    private(set) var received = false
    func receivedReply() { received = true }
}

/// The bounded synchronous pause makes cancellation/acknowledgement ordering observable.
/// Production cancellation callbacks must not block as this test-only callback deliberately does.
private final class PausedClipboardCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var entered = false
    func pause() {
        lock.withLock { entered = true }
        _ = gate.wait(timeout: .now() + 2)
    }
    func release() { gate.signal() }
    func waitUntilEntered() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !lock.withLock({ entered }) {
            guard ContinuousClock.now < deadline else { throw IOSRunnerSessionServer.Failure.rejected }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private actor CooperativeClipboardHandler: IOSRunnerClipboardHandling {
    let cancellation: PausedClipboardCancellation
    private var waiting: CheckedContinuation<Void, Never>?
    private var entered = false
    private var released = false
    private(set) var writeCount = 0
    init(cancellation: PausedClipboardCancellation) { self.cancellation = cancellation }
    func handle(_ request: HelperRequest) async -> HelperResult {
        await withTaskCancellationHandler {
            entered = true
            if !released { await withCheckedContinuation { waiting = $0 } }
            if Task.isCancelled {
                return HelperResult(requestID: request.requestID, status: .cancelled, completedAt: Date(),
                    error: HelperErrorPayload(code: "clipboard.cancelled", message: "Cancelled"))
            }
            writeCount += 1
            return HelperResult(requestID: request.requestID, status: .success, completedAt: Date(),
                payload: ["written": .bool(true)])
        } onCancel: { cancellation.pause() }
    }
    func release() { released = true; waiting?.resume(); waiting = nil }
    func waitUntilEntered() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !entered {
            guard ContinuousClock.now < deadline else { throw IOSRunnerSessionServer.Failure.rejected }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private struct ClipboardResultFixture: IOSRunnerClipboardHandling {
    let result: @Sendable (HelperRequest) -> HelperResult
    init(_ result: @escaping @Sendable (HelperRequest) -> HelperResult) { self.result = result }
    func handle(_ request: HelperRequest) async -> HelperResult { result(request) }
}

/// Only the external clipboard wait is replaced: framing, authentication and dispatch are real.
/// This gate deliberately ignores cancellation so teardown cannot hide a structured-task join.
private actor GatedClipboardHandler: IOSRunnerClipboardHandling {
    private var released: Bool
    private var waiting: CheckedContinuation<Void, Never>?
    private(set) var callCount = 0
    init(released: Bool = false) { self.released = released }
    func handle(_ request: HelperRequest) async -> HelperResult {
        callCount += 1
        if !released { await withCheckedContinuation { waiting = $0 } }
        let payload: [String: JSONValue] = request.action == .clipboardRead
            ? ["text": .string("public-clipboard-fixture")] : ["written": .bool(true)]
        return HelperResult(requestID: request.requestID, status: .success, completedAt: Date(), payload: payload)
    }
    func release() { released = true; waiting?.resume(); waiting = nil }
    func waitUntilEntered() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while callCount == 0 {
            guard ContinuousClock.now < deadline else { throw IOSRunnerSessionServer.Failure.rejected }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private struct LargeScreenshotFixture: IOSRunnerScreenshotHandling {
    let png: Data = {
        let small = ScreenshotBytesFixture().png
        let text = Data("fixture\0".utf8) + Data(repeating: 65, count: 150_000)
        var length = UInt32(text.count).bigEndian
        let body = Data("tEXt".utf8) + text
        let checksum = body.withUnsafeBytes { crc32(0, $0.bindMemory(to: UInt8.self).baseAddress, uInt(body.count)) }
        var checksum32 = UInt32(checksum).bigEndian
        var chunk = withUnsafeBytes(of: &length) { Data($0) }
        chunk.append(body)
        withUnsafeBytes(of: &checksum32) { chunk.append(contentsOf: $0) }
        return Data(small.dropLast(12)) + chunk + small.suffix(12)
    }()
    func capture(_ request: HelperRequest) async -> IOSRunnerScreenshotResult {
        let digest = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
        return IOSRunnerScreenshotResult(result: HelperResult(requestID: request.requestID, status: .success,
            completedAt: Date(), payload: ["mediaType": .string("image/png"), "byteLength": .number(Double(png.count)),
                "sha256": .string(digest)]), pngData: png)
    }
}

private struct ScreenshotBytesFixture: IOSRunnerScreenshotHandling {
    let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==")!
    let payload: [String: JSONValue] = ["mediaType": .string("image/png"), "byteLength": .number(70),
        "sha256": .string("4ff6ab670a58c14270e034e2090d9a432caa263a14e0a25785386b0c12f880b5")]
    func capture(_ request: HelperRequest) async -> IOSRunnerScreenshotResult {
        IOSRunnerScreenshotResult(result: HelperResult(requestID: request.requestID, status: .success,
            completedAt: Date(), payload: payload), pngData: png)
    }
}

private struct ScreenshotFailureFixture: IOSRunnerScreenshotHandling {
    func capture(_ request: HelperRequest) async -> IOSRunnerScreenshotResult {
        IOSRunnerScreenshotResult(result: HelperResult(requestID: request.requestID, status: .actionRequired,
            completedAt: Date(), error: HelperErrorPayload(code: "screenshot.device_locked", message: "Unlock the phone.")))
    }
}

private actor GatedScreenshotFixture: IOSRunnerScreenshotHandling {
    private var waiting: CheckedContinuation<Void, Never>?
    private var entered = false
    func capture(_ request: HelperRequest) async -> IOSRunnerScreenshotResult {
        entered = true
        await withCheckedContinuation { waiting = $0 }
        return await ScreenshotFailureFixture().capture(request)
    }
    func waitUntilEntered() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !entered {
            guard ContinuousClock.now < deadline else { throw IOSRunnerSessionServer.Failure.rejected }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    func release() { waiting?.resume(); waiting = nil }
}

struct RunningSession: Sendable {
    let host: PinnedTLSFrameStream
    let session: IOSRunnerIdentityHandshake.Session
    let task: Task<IOSRunnerSessionServer.Exit, Error>

    static func pair() async throws -> (PinnedTLSFrameStream, PinnedTLSFrameStream) {
        let hostIdentity = try EphemeralTLSIdentity.create(), runnerIdentity = try EphemeralTLSIdentity.create()
        let listener = try await PinnedTLSFrameStream.listen(identity: runnerIdentity, peerCertificateDER: hostIdentity.certificateDER)
        let host = try await PinnedTLSFrameStream.connect(localPort: listener.port, identity: hostIdentity, peerCertificateDER: runnerIdentity.certificateDER)
        return (host, try await listener.accept())
    }

    static func start(lease: Duration = .seconds(2), maximum: Duration = .seconds(3),
                      clipboardHandler: (any IOSRunnerClipboardHandling)? = nil,
                      screenshotHandler: (any IOSRunnerScreenshotHandling)? = nil,
                      deviceInformationHandler: (any IOSRunnerDeviceInformationHandling)? = nil) async throws -> RunningSession {
        let (host, runner) = try await pair()
        let launch = UUID()
        let maximumDeadline = ContinuousClock.now.advanced(by: maximum)
        let task = Task { try await IOSRunnerSessionServer.run(stream: runner, launchID: launch, maximumDeadline: maximumDeadline,
            leaseDuration: lease, clipboardHandler: clipboardHandler, screenshotHandler: screenshotHandler, deviceInformationHandler: deviceInformationHandler) }
        do {
            let session = try await IOSRunnerIdentityHandshake.openHost(stream: host, launchID: launch,
                helperBuild: "devicebridge-ios-runner-v1", requiredActions: [.identity, .stop])
            if clipboardHandler == nil && screenshotHandler == nil && deviceInformationHandler == nil { #expect(session.allowedActions == [.identity, .stop]) }
            return RunningSession(host: host, session: session, task: task)
        } catch {
            task.cancel(); _ = try? await task.value
            await host.close(); throw error
        }
    }

    func request(_ action: HelperAction) -> HelperRequest {
        let now = Date()
        return HelperRequest(requestID: UUID(), sessionNonce: session.sessionNonce, helperDeviceID: session.helperDeviceID,
            action: action, createdAt: now, expiresAt: now.addingTimeInterval(5), payload: [:])
    }

    func send(_ request: HelperRequest) async throws -> HelperResult {
        try await host.writeFrame(HelperWireCodec().encode(request), timeout: 2)
        return try HelperWireCodec().decodeResult(await host.readFrame(timeout: 2))
    }

    func cancel() async { task.cancel(); _ = try? await task.value; await host.close() }
}

/// Raw TLS fixture keeps sending only a partial application frame. It never supplies an
/// arbitrary connection to production code; run() receives a normally authenticated stream.
private final class PartialSessionPeer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "DeviceBridge.SessionPartialTest")
    private let listener: NWListener
    private let chunks: [Data]
    private var connection: NWConnection?

    init(identity: EphemeralTLSIdentity, pin: Data, chunks: [Data]) throws {
        self.chunks = chunks
        let parameters = try PinnedTLSParameters.make(identity: identity, peerCertificateDER: pin, queue: queue)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        listener.stateUpdateHandler = nil
                        if let port = listener.port { continuation.resume(returning: port.rawValue) }
                        else { continuation.resume(throwing: IOSRunnerSessionServer.Failure.rejected) }
                    case .failed:
                        listener.stateUpdateHandler = nil
                        continuation.resume(throwing: IOSRunnerSessionServer.Failure.rejected)
                    default: break
                    }
                }
                listener.newConnectionHandler = { [weak self] incoming in
                    guard let self, connection == nil else { incoming.cancel(); return }
                    connection = incoming
                    listener.cancel()
                    incoming.stateUpdateHandler = { [weak self] state in
                        if case .ready = state { self?.send(0) }
                    }
                    incoming.start(queue: queue)
                }
                listener.start(queue: queue)
            }
        }
    }

    private func send(_ index: Int) {
        guard let connection, index < chunks.count else { return }
        connection.send(content: chunks[index], completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else { return }
            queue.asyncAfter(deadline: .now() + 0.04) { [weak self] in self?.send(index + 1) }
        })
    }

    func close() {
        queue.async { [self] in
            listener.stateUpdateHandler = nil; listener.newConnectionHandler = nil; listener.cancel()
            connection?.stateUpdateHandler = nil; connection?.cancel(); connection = nil
        }
    }
}
