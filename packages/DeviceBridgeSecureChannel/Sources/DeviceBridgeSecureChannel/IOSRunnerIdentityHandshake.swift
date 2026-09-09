import Foundation
import CryptoKit
import DeviceBridgeProtocol

/// Application identity is additional to the stream's mutual TLS pin verification.
public enum IOSRunnerIdentityHandshake {
    public enum Failure: Error, Equatable, Sendable { case rejected }
    private static let supportedActions: Set<HelperAction> = [.identity, .stop, .clipboardRead, .clipboardWrite, .screenshotCapture, .deviceInformation]

    public struct Session: Sendable {
        public let bootstrapRequestID: UUID
        public let launchID: UUID
        public let sessionNonce: String
        public let helperDeviceID: String
        public let helperBuild: String
        public let allowedActions: Set<HelperAction>
    }

    /// The channel owner invokes this once, before publishing content readiness. Only this
    /// TLS stream carries the fresh secrets; callers cannot supply them through launch metadata.
    /// Host timeout is whole seconds in 2...30; version-1 timestamps have whole-second precision.
    public static func openHost(stream: PinnedTLSFrameStream, launchID: UUID, helperBuild: String,
                                requiredActions: Set<HelperAction>, timeout: TimeInterval = 10) async throws -> Session {
        do {
            try Task.checkCancellation()
            try validateConfiguration(build: helperBuild, actions: requiredActions)
            let now = Date()
            let request = try makeRequest(launchID: launchID, now: now, timeout: timeout)
            let deadline = try deadline(after: request.expiresAt.timeIntervalSince(now))
            let codec = HelperWireCodec()
            try await stream.writeFrame(codec.encode(request), timeout: remaining(until: deadline))
            let frame = try await stream.readFrame(timeout: remaining(until: deadline))
            try Task.checkCancellation()
            _ = try remaining(until: deadline)
            return try validate(codec.decodeResult(frame), request: request, launchID: launchID,
                helperBuild: helperBuild, requiredActions: requiredActions, now: Date())
        } catch {
            await stream.close()
            throw Task.isCancelled ? CancellationError() : Failure.rejected
        }
    }

    /// Consumes the first frame of a new mutually pinned stream. No content handlers run here.
    public static func acceptRunner(stream: PinnedTLSFrameStream, launchID: UUID, helperBuild: String,
                                   allowedActions: Set<HelperAction>, timeout: TimeInterval = 10) async throws -> Session {
        try await exchangeRunnerIdentity(stream: stream, launchID: launchID, helperBuild: helperBuild,
            allowedActions: allowedActions, timeout: timeout, wallClock: Date.init)
    }

    // Wall-clock is an external validation boundary, separate from the monotonic I/O deadline.
    static func exchangeRunnerIdentity(stream: PinnedTLSFrameStream, launchID: UUID, helperBuild: String,
                                      allowedActions: Set<HelperAction>, timeout: TimeInterval,
                                      wallClock: @Sendable () -> Date) async throws -> Session {
        do {
            try Task.checkCancellation()
            let deadline = try deadline(after: timeout)
            try validateConfiguration(build: helperBuild, actions: allowedActions)
            let codec = HelperWireCodec()
            let frame = try await stream.readFrame(timeout: remaining(until: deadline))
            let request = try codec.decodeRequest(frame)
            let (result, session) = try reply(to: request, launchID: launchID,
                helperBuild: helperBuild, allowedActions: allowedActions, now: wallClock())
            try await stream.writeFrame(codec.encode(result), timeout: remaining(until: deadline))
            try Task.checkCancellation()
            _ = try remaining(until: deadline)
            try validateRequest(request, launchID: launchID, now: wallClock())
            return session
        } catch {
            await stream.close()
            throw Task.isCancelled ? CancellationError() : Failure.rejected
        }
    }

    static func makeRequest(launchID: UUID, now: Date, timeout: TimeInterval) throws -> HelperRequest {
        guard timeout.isFinite, (2...30).contains(timeout), timeout.rounded(.down) == timeout,
              now.timeIntervalSince1970.isFinite else { throw Failure.rejected }
        // Match the existing ISO8601 envelope precision without changing Android's wire codec.
        // The monotonic host deadline is derived from this same expiry, never extended by rounding.
        let createdAt = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970))
        return HelperRequest(requestID: UUID(), sessionNonce: secret(), helperDeviceID: "bootstrap",
            action: .identity, createdAt: createdAt, expiresAt: createdAt.addingTimeInterval(timeout), payload: [
                "launchId": .string(launchID.uuidString), "challenge": .string(secret()),
            ])
    }

    static func reply(to request: HelperRequest, launchID: UUID, helperBuild: String,
                      allowedActions: Set<HelperAction>, now: Date) throws -> (HelperResult, Session) {
        try validateRequest(request, launchID: launchID, now: now)
        try validateConfiguration(build: helperBuild, actions: allowedActions)
        let session = Session(bootstrapRequestID: request.requestID, launchID: launchID, sessionNonce: request.sessionNonce,
            helperDeviceID: launchID.uuidString, helperBuild: helperBuild, allowedActions: allowedActions)
        return (HelperResult(requestID: request.requestID, status: .success, completedAt: now, payload: [
            "launchId": .string(launchID.uuidString), "sessionNonce": .string(request.sessionNonce),
            "challenge": request.payload["challenge"]!, "helperDeviceId": .string(session.helperDeviceID),
            "helperVersion": .string(helperBuild),
            "allowedActions": .array(allowedActions.map(\.rawValue).sorted().map(JSONValue.string)),
        ]), session)
    }

    static func validate(_ result: HelperResult, request: HelperRequest, launchID: UUID,
                         helperBuild: String, requiredActions: Set<HelperAction>, now: Date) throws -> Session {
        try validateRequest(request, launchID: launchID, now: now)
        try validateConfiguration(build: helperBuild, actions: requiredActions)
        guard result.protocolVersion == 1, result.requestID == request.requestID,
              result.status == .success, result.error == nil,
              result.completedAt.timeIntervalSince1970.isFinite,
              abs(result.completedAt.timeIntervalSince(now)) <= 120,
              let payload = result.payload,
              Set(payload.keys) == ["launchId", "sessionNonce", "challenge", "helperDeviceId", "helperVersion", "allowedActions"],
              payload["launchId"] == .string(launchID.uuidString),
              payload["sessionNonce"] == .string(request.sessionNonce),
              payload["challenge"] == request.payload["challenge"],
              payload["helperDeviceId"] == .string(launchID.uuidString),
              payload["helperVersion"] == .string(helperBuild),
              case .array(let values) = payload["allowedActions"], values.count <= supportedActions.count else {
            throw Failure.rejected
        }
        let actions = Set(values.compactMap { $0.stringValue.flatMap(HelperAction.init(rawValue:)) })
        guard actions.count == values.count, actions.isSubset(of: supportedActions),
              requiredActions.isSubset(of: actions) else { throw Failure.rejected }
        return Session(bootstrapRequestID: request.requestID, launchID: launchID, sessionNonce: request.sessionNonce,
            helperDeviceID: launchID.uuidString, helperBuild: helperBuild, allowedActions: actions)
    }

    private static func validateConfiguration(build: String, actions: Set<HelperAction>) throws {
        guard !build.isEmpty, build.utf8.count <= 128,
              actions.isSubset(of: supportedActions), Set<HelperAction>([.identity, .stop]).isSubset(of: actions) else {
            throw Failure.rejected
        }
    }

    private static func validateRequest(_ request: HelperRequest, launchID: UUID, now: Date) throws {
        guard request.protocolVersion == 1, request.action == .identity, request.helperDeviceID == "bootstrap",
              Set(request.payload.keys) == ["launchId", "challenge"],
              request.payload["launchId"] == .string(launchID.uuidString),
              canonicalSecret(request.sessionNonce),
              let challenge = request.payload["challenge"]?.stringValue, canonicalSecret(challenge),
              challenge != request.sessionNonce,
              now.timeIntervalSince1970.isFinite, request.createdAt.timeIntervalSince1970.isFinite,
              request.expiresAt.timeIntervalSince1970.isFinite,
              abs(request.createdAt.timeIntervalSince(now)) <= 120,
              request.createdAt < request.expiresAt, request.expiresAt > now,
              request.expiresAt.timeIntervalSince(request.createdAt) <= 30 else { throw Failure.rejected }
    }

    private static func canonicalSecret(_ value: String) -> Bool {
        guard value.utf8.count == 44, let decoded = Data(base64Encoded: value), decoded.count == 32 else { return false }
        return decoded.base64EncodedString() == value
    }

    private static func secret() -> String {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0).base64EncodedString() }
    }

    private static func deadline(after seconds: TimeInterval) throws -> ContinuousClock.Instant {
        guard seconds.isFinite, seconds > 0, seconds <= 30 else { throw Failure.rejected }
        return ContinuousClock.now.advanced(by: .seconds(seconds))
    }

    private static func remaining(until deadline: ContinuousClock.Instant) throws -> TimeInterval {
        let duration = ContinuousClock.now.duration(to: deadline)
        guard duration > .zero else { throw Failure.rejected }
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
