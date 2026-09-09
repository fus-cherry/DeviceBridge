import DeviceBridgeProtocol
import Foundation

public struct HelperSessionContext: Sendable, Equatable {
    public let sessionNonce: String
    public let helperDeviceID: String
    public let helperVersion: String

    public init(sessionNonce: String, helperDeviceID: String, helperVersion: String) {
        self.sessionNonce = sessionNonce
        self.helperDeviceID = helperDeviceID
        self.helperVersion = helperVersion
    }
}

public struct HelperAuthenticationOutcome: Sendable, Equatable {
    public let context: HelperSessionContext?
    public let failure: OperationFailure?

    public init(context: HelperSessionContext? = nil, failure: OperationFailure? = nil) {
        self.context = context
        self.failure = failure
    }
}

public struct HelperSessionAuthenticator: Sendable {
    private let channel: any HelperRequestSending

    public init(channel: any HelperRequestSending) {
        self.channel = channel
    }

    public func authenticate(
        sessionNonce: String,
        now: Date = Date()
    ) async -> HelperAuthenticationOutcome {
        guard !sessionNonce.isEmpty else { return invalidHandshake() }
        let request = HelperRequest(
            requestID: UUID(),
            sessionNonce: sessionNonce,
            helperDeviceID: "bootstrap",
            action: .identity,
            createdAt: now,
            expiresAt: now.addingTimeInterval(30),
            payload: [:]
        )

        do {
            let result = try await channel.send(request)
            guard result.protocolVersion == 1,
                  result.requestID == request.requestID,
                  result.status == .success,
                  result.isStructurallyValid,
                  let helperDeviceID = result.payload?["helperDeviceId"]?.stringValue,
                  !helperDeviceID.isEmpty,
                  let helperVersion = result.payload?["helperVersion"]?.stringValue,
                  !helperVersion.isEmpty,
                  case let .array(protocolVersions)? = result.payload?["protocolVersions"],
                  protocolVersions.contains(.number(1)) else {
                return invalidHandshake()
            }
            return HelperAuthenticationOutcome(context: HelperSessionContext(
                sessionNonce: sessionNonce,
                helperDeviceID: helperDeviceID,
                helperVersion: helperVersion
            ))
        } catch is CancellationError {
            return HelperAuthenticationOutcome(failure: OperationFailure(
                code: .cancelled,
                safeMessage: "Helper authentication cancelled."
            ))
        } catch {
            return HelperAuthenticationOutcome(failure: OperationFailure(
                code: .helperMissing,
                safeMessage: "The managed helper did not complete its handshake.",
                recoveryAction: "Open the helper on the device and retry."
            ))
        }
    }

    public func verifyExisting(_ context: HelperSessionContext) async -> Bool {
        let now = Date()
        let request = HelperRequest(requestID: UUID(), sessionNonce: context.sessionNonce,
            helperDeviceID: context.helperDeviceID, action: .identity, createdAt: now,
            expiresAt: now.addingTimeInterval(5), payload: [:])
        guard let result = try? await channel.send(request), !Task.isCancelled else { return false }
        return result.protocolVersion == 1 && result.requestID == request.requestID
            && result.status == .success && result.isStructurallyValid
            && result.payload?["helperDeviceId"]?.stringValue == context.helperDeviceID
            && result.payload?["helperVersion"]?.stringValue == context.helperVersion
            && result.payload?["protocolVersions"] == .array([.number(1)])
    }

    private func invalidHandshake() -> HelperAuthenticationOutcome {
        HelperAuthenticationOutcome(failure: OperationFailure(
            code: .helperMissing,
            safeMessage: "The managed helper is incompatible or returned an invalid identity.",
            recoveryAction: "Update or restart the managed helper."
        ))
    }
}
