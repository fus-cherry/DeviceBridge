import Foundation
import Testing
import DeviceBridgeProtocol
@testable import DeviceBridgeSecureChannel

@Suite struct IOSRunnerIdentityHandshakeTests {
    private let launch = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    // Public fixtures only. Actual secrets are generated inside the TLS host handshake.
    private var request: HelperRequest {
        HelperRequest(requestID: UUID(), sessionNonce: Data(repeating: 1, count: 32).base64EncodedString(),
            helperDeviceID: "bootstrap", action: .identity, createdAt: now, expiresAt: now.addingTimeInterval(10),
            payload: ["launchId": .string(launch.uuidString),
                      "challenge": .string(Data(repeating: 2, count: 32).base64EncodedString())])
    }

    // Removing exact launch/challenge binding, or returning a default context, breaks this contract.
    @Test func bindsReplyToLaunchNonceChallengeAndAvailableActions() throws {
        let request = request
        let (result, runner) = try IOSRunnerIdentityHandshake.reply(to: request, launchID: launch,
            helperBuild: "runner-test-v1", allowedActions: [.identity, .stop], now: now)
        #expect(result.requestID == request.requestID)
        #expect(result.payload?["launchId"] == .string("11111111-2222-3333-4444-555555555555"))
        #expect(result.payload?["challenge"] == request.payload["challenge"])
        let host = try IOSRunnerIdentityHandshake.validate(result, request: request, launchID: launch,
            helperBuild: "runner-test-v1", requiredActions: [.identity, .stop], now: now)
        #expect(host.helperDeviceID == "11111111-2222-3333-4444-555555555555")
        #expect(host.sessionNonce == request.sessionNonce)
        #expect(runner.sessionNonce == host.sessionNonce)
        #expect(host.allowedActions == [.identity, .stop])
        #expect(!host.allowedActions.contains(.clipboardRead))
    }

    @Test(arguments: ["content", "version", "device", "launch", "nonce", "challenge", "sameSecret", "expired", "future", "longExpiry", "extra"])
    func rejectsInvalidFirstRequest(mutation: String) throws {
        var candidate = request
        switch mutation {
        case "content": candidate.action = .clipboardRead
        case "version": candidate.protocolVersion = 2
        case "device": candidate.helperDeviceID = "another-runner"
        case "launch": candidate.payload["launchId"] = .string(UUID().uuidString)
        case "nonce": candidate.sessionNonce = "short"
        case "challenge": candidate.payload["challenge"] = .string("short")
        case "sameSecret": candidate.payload["challenge"] = .string(candidate.sessionNonce)
        case "expired": candidate.expiresAt = now
        case "future": candidate.createdAt = now.addingTimeInterval(121); candidate.expiresAt = now.addingTimeInterval(125)
        case "longExpiry": candidate.expiresAt = now.addingTimeInterval(31)
        default: candidate.payload["clipboard"] = .string("public-fixture")
        }
        #expect(throws: IOSRunnerIdentityHandshake.Failure.rejected) {
            _ = try IOSRunnerIdentityHandshake.reply(to: candidate, launchID: launch,
                helperBuild: "runner-test-v1", allowedActions: [.identity, .stop], now: now)
        }
    }

    @Test(arguments: ["request", "version", "status", "error", "launchId", "sessionNonce", "challenge", "helperDeviceId", "helperVersion", "missingAction", "extraAction", "duplicateAction", "expired", "completed", "extra"])
    func rejectsUnboundOrIncompatibleReply(mutation: String) throws {
        let request = request
        let (valid, _) = try IOSRunnerIdentityHandshake.reply(to: request, launchID: launch,
            helperBuild: "runner-test-v1", allowedActions: [.identity, .stop], now: now)
        var payload = valid.payload!
        switch mutation {
        case "launchId", "sessionNonce", "challenge", "helperDeviceId", "helperVersion": payload[mutation] = .string("wrong")
        case "missingAction": payload["allowedActions"] = .array([.string("identity")])
        case "extraAction": payload["allowedActions"] = .array([.string("identity"), .string("stop"), .string("file.hash")])
        case "duplicateAction": payload["allowedActions"] = .array([.string("identity"), .string("stop"), .string("stop")])
        case "extra": payload["unexpected"] = .bool(true)
        default: break
        }
        let candidate = HelperResult(protocolVersion: mutation == "version" ? 2 : 1,
            requestID: mutation == "request" ? UUID() : request.requestID,
            status: mutation == "status" ? .failure : .success,
            completedAt: mutation == "completed" ? now.addingTimeInterval(121) : now,
            payload: payload, error: mutation == "error" ? .init(code: "fixture", message: "fixture") : nil)
        #expect(throws: IOSRunnerIdentityHandshake.Failure.rejected) {
            _ = try IOSRunnerIdentityHandshake.validate(candidate, request: request, launchID: launch,
                helperBuild: "runner-test-v1", requiredActions: [.identity, .stop],
                now: mutation == "expired" ? now.addingTimeInterval(10) : now)
        }
    }

    @Test func performsActualPinnedTLSHandshakeWithFreshIndependentSecrets() async throws {
        let hostIdentity = try EphemeralTLSIdentity.create()
        let runnerIdentity = try EphemeralTLSIdentity.create()
        let listener = try await PinnedTLSFrameStream.listen(identity: runnerIdentity,
            peerCertificateDER: hostIdentity.certificateDER)
        let hostStream = try await PinnedTLSFrameStream.connect(localPort: listener.port,
            identity: hostIdentity, peerCertificateDER: runnerIdentity.certificateDER)
        let runnerStream = try await listener.accept()
        do {
            async let runner = IOSRunnerIdentityHandshake.acceptRunner(stream: runnerStream, launchID: launch,
                helperBuild: "runner-test-v1", allowedActions: [.identity, .stop])
            let host = try await IOSRunnerIdentityHandshake.openHost(stream: hostStream, launchID: launch,
                helperBuild: "runner-test-v1", requiredActions: [.identity, .stop])
            let accepted = try await runner
            // Boolean assertions do not serialize production-generated secrets on failure.
            let matched = accepted.sessionNonce == host.sessionNonce
            let isFresh = host.sessionNonce != request.sessionNonce
            #expect(matched)
            #expect(isFresh)
            #expect(Data(base64Encoded: host.sessionNonce)?.count == 32)
            #expect(host.allowedActions == [.identity, .stop])
            await hostStream.close(); await runnerStream.close()
        } catch {
            await hostStream.close(); await runnerStream.close()
            throw error
        }
    }

    @Test func hostDeadlineUsesTheSameWholeSecondWindowAsTheWire() throws {
        let request = try IOSRunnerIdentityHandshake.makeRequest(launchID: launch,
            now: now.addingTimeInterval(0.75), timeout: 2)
        let wire = try HelperWireCodec().decodeRequest(HelperWireCodec().encode(request))
        #expect(request.createdAt == wire.createdAt)
        #expect(request.expiresAt == wire.expiresAt)
        #expect(request.expiresAt == now.addingTimeInterval(2))
    }

    @Test(arguments: [0.5, 1, 2.5, 31, Double.infinity, Double.nan])
    func rejectsUnrepresentableHostTimeout(timeout: TimeInterval) {
        #expect(throws: IOSRunnerIdentityHandshake.Failure.rejected) {
            _ = try IOSRunnerIdentityHandshake.makeRequest(launchID: launch, now: now, timeout: timeout)
        }
    }

    @Test func runnerDoesNotCommitSessionIfRequestExpiresDuringReplyWrite() async throws {
        let hostIdentity = try EphemeralTLSIdentity.create()
        let runnerIdentity = try EphemeralTLSIdentity.create()
        let listener = try await PinnedTLSFrameStream.listen(identity: runnerIdentity,
            peerCertificateDER: hostIdentity.certificateDER)
        let hostStream = try await PinnedTLSFrameStream.connect(localPort: listener.port,
            identity: hostIdentity, peerCertificateDER: runnerIdentity.certificateDER)
        let runnerStream = try await listener.accept()
        let request = request
        let clock = ReplyClock(before: now, after: request.expiresAt)
        let runner = Task {
            try await IOSRunnerIdentityHandshake.exchangeRunnerIdentity(stream: runnerStream, launchID: launch,
                helperBuild: "runner-test-v1", allowedActions: [.identity, .stop], timeout: 2,
                wallClock: { clock.read() })
        }
        do {
            try await hostStream.writeFrame(HelperWireCodec().encode(request))
            // A stack-processed reply is allowed; the runner must still refuse to commit its session.
            _ = try? await hostStream.readFrame(timeout: 2)
            var rejected = false
            do { _ = try await runner.value }
            catch IOSRunnerIdentityHandshake.Failure.rejected { rejected = true }
            #expect(rejected)
            await hostStream.close(); await runnerStream.close()
        } catch {
            runner.cancel(); await hostStream.close(); await runnerStream.close()
            _ = try? await runner.value
            throw error
        }
    }
}

private final class ReplyClock: @unchecked Sendable {
    private let lock = NSLock()
    private let before: Date, after: Date
    private var firstRead = true
    init(before: Date, after: Date) { self.before = before; self.after = after }
    func read() -> Date {
        lock.lock(); defer { lock.unlock() }
        defer { firstRead = false }
        return firstRead ? before : after
    }
}
