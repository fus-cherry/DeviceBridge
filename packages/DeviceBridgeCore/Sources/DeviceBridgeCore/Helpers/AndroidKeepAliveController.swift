import DeviceBridgeProtocol
import Foundation

public struct AndroidKeepAliveLease: Sendable, Equatable {
    public let leaseID: String
    public let deviceIdentity: DeviceIdentity
    public let transportID: String
    public let sessionGeneration: Int
    public let startedAt: Date
    public let renewedAt: Date
    public let expiresAt: Date
    public let notificationVisible: Bool
    public let wifiLockHeld: Bool

    public init(
        leaseID: String,
        deviceIdentity: DeviceIdentity,
        transportID: String,
        sessionGeneration: Int,
        startedAt: Date,
        renewedAt: Date,
        expiresAt: Date,
        notificationVisible: Bool,
        wifiLockHeld: Bool
    ) {
        self.leaseID = leaseID
        self.deviceIdentity = deviceIdentity
        self.transportID = transportID
        self.sessionGeneration = sessionGeneration
        self.startedAt = startedAt
        self.renewedAt = renewedAt
        self.expiresAt = expiresAt
        self.notificationVisible = notificationVisible
        self.wifiLockHeld = wifiLockHeld
    }
}

public enum AndroidKeepAliveControllerState: Sendable, Equatable {
    case idle
    case starting
    case active(AndroidKeepAliveLease)
    case stopped
    case failed(OperationFailure)
}

public struct AndroidKeepAliveOutcome: Sendable, Equatable {
    public let lease: AndroidKeepAliveLease?
    public let failure: OperationFailure?

    public init(
        lease: AndroidKeepAliveLease? = nil,
        failure: OperationFailure? = nil
    ) {
        self.lease = lease
        self.failure = failure
    }
}

public protocol AndroidKeepAliveSleeping: Sendable {
    func sleep(for duration: Duration) async throws
}

public struct ContinuousAndroidKeepAliveSleeper: AndroidKeepAliveSleeping {
    public init() {}

    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

public actor AndroidKeepAliveController {
    public static let renewalInterval: Duration = .seconds(10)

    private struct BoundSession: Sendable, Equatable {
        let deviceIdentity: DeviceIdentity
        let transportID: String
        let generation: Int
    }

    private let store: DeviceSessionStore
    private let channel: any HelperRequestSending
    private let sessionNonce: String
    private let helperDeviceID: String
    private let sleeper: any AndroidKeepAliveSleeping
    private let interval: Duration
    private var lifecycleRevision = 0
    private var renewalTask: Task<Void, Never>?

    public private(set) var state: AndroidKeepAliveControllerState = .idle

    public init(
        store: DeviceSessionStore,
        channel: any HelperRequestSending,
        sessionNonce: String,
        helperDeviceID: String,
        interval: Duration = AndroidKeepAliveController.renewalInterval,
        sleeper: any AndroidKeepAliveSleeping = ContinuousAndroidKeepAliveSleeper()
    ) {
        self.store = store
        self.channel = channel
        self.sessionNonce = sessionNonce
        self.helperDeviceID = helperDeviceID
        self.interval = interval
        self.sleeper = sleeper
    }

    public func start() async -> AndroidKeepAliveOutcome {
        lifecycleRevision += 1
        let revision = lifecycleRevision
        renewalTask?.cancel()
        renewalTask = nil
        state = .starting

        guard let boundSession = await selectedWirelessAndroidSession() else {
            let failure = OperationFailure(
                code: .unsupported,
                safeMessage: "Android Wi-Fi maintenance is available only for the selected wireless transport."
            )
            state = .failed(failure)
            return AndroidKeepAliveOutcome(failure: failure)
        }

        let response = await send(action: .keepAliveStart, payload: [:])
        guard case let .success(result) = response else {
            guard lifecycleRevision == revision else { return AndroidKeepAliveOutcome() }
            let failure = response.failure ?? helperFailure("Android Wi-Fi maintenance could not start.")
            state = .failed(failure)
            return AndroidKeepAliveOutcome(failure: failure)
        }
        guard let lease = parseLease(result, session: boundSession) else {
            guard lifecycleRevision == revision else { return AndroidKeepAliveOutcome() }
            let failure = helperFailure("Android returned an invalid connection-maintenance lease.")
            state = .failed(failure)
            return AndroidKeepAliveOutcome(failure: failure)
        }
        guard lifecycleRevision == revision else {
            await sendStop(leaseID: lease.leaseID)
            return AndroidKeepAliveOutcome()
        }
        guard await isCurrent(boundSession) else {
            await sendStop(leaseID: lease.leaseID)
            state = .stopped
            return AndroidKeepAliveOutcome(failure: staleFailure())
        }
        guard lease.notificationVisible, lease.wifiLockHeld else {
            await sendStop(leaseID: lease.leaseID)
            let failure = OperationFailure(
                code: .permissionDenied,
                safeMessage: "Android connection maintenance requires a visible notification and Wi-Fi lock.",
                recoveryAction: "Allow helper notifications on the device, then retry."
            )
            state = .failed(failure)
            return AndroidKeepAliveOutcome(failure: failure)
        }

        state = .active(lease)
        renewalTask = Task { [weak self] in
            await self?.renewLoop(session: boundSession, revision: revision)
        }
        return AndroidKeepAliveOutcome(lease: lease)
    }

    public func stop() async {
        lifecycleRevision += 1
        renewalTask?.cancel()
        renewalTask = nil
        guard case let .active(lease) = state else {
            state = .stopped
            return
        }
        state = .stopped
        await sendStop(leaseID: lease.leaseID)
    }

    private func renewLoop(session: BoundSession, revision: Int) async {
        while !Task.isCancelled, lifecycleRevision == revision {
            do {
                try await sleeper.sleep(for: interval)
            } catch {
                return
            }
            guard !Task.isCancelled, lifecycleRevision == revision else { return }
            guard await isCurrent(session),
                  case let .active(currentLease) = state else {
                await stopFromRenewalLoop(revision: revision)
                return
            }

            let response = await send(
                action: .keepAliveRenew,
                payload: ["leaseId": .string(currentLease.leaseID)]
            )
            guard !Task.isCancelled, lifecycleRevision == revision else { return }
            guard await isCurrent(session) else {
                await stopFromRenewalLoop(revision: revision)
                return
            }
            guard case let .success(result) = response,
                  let renewedLease = parseLease(result, session: session),
                  renewedLease.leaseID == currentLease.leaseID,
                  renewedLease.notificationVisible,
                  renewedLease.wifiLockHeld else {
                await failRenewal(response.failure, leaseID: currentLease.leaseID, revision: revision)
                return
            }
            state = .active(renewedLease)
        }
    }

    private func stopFromRenewalLoop(revision: Int) async {
        guard lifecycleRevision == revision else { return }
        lifecycleRevision += 1
        let leaseID: String?
        if case let .active(lease) = state { leaseID = lease.leaseID } else { leaseID = nil }
        renewalTask = nil
        state = .stopped
        if let leaseID { await sendStop(leaseID: leaseID) }
    }

    private func failRenewal(
        _ responseFailure: OperationFailure?,
        leaseID: String,
        revision: Int
    ) async {
        guard lifecycleRevision == revision else { return }
        lifecycleRevision += 1
        renewalTask = nil
        let failure = responseFailure ?? helperFailure(
            "Android connection maintenance could not be renewed; the device lease will expire."
        )
        state = .failed(failure)
        await sendStop(leaseID: leaseID)
    }

    private func selectedWirelessAndroidSession() async -> BoundSession? {
        let snapshot = await store.snapshot()
        guard let session = snapshot.session,
              session.state == .active,
              session.deviceIdentity.platform == .android,
              snapshot.selectedDeviceIdentity == session.deviceIdentity,
              let device = snapshot.devices.first(where: { $0.identity == session.deviceIdentity }),
              let transport = device.candidates.first(where: { $0.id == session.transportID }),
              transport.kind == .wifi,
              transport.status == .available else { return nil }
        return BoundSession(
            deviceIdentity: session.deviceIdentity,
            transportID: session.transportID,
            generation: session.generation
        )
    }

    private func isCurrent(_ expected: BoundSession) async -> Bool {
        guard let current = await selectedWirelessAndroidSession() else { return false }
        return current == expected
    }

    private enum Response {
        case success(HelperResult)
        case failure(OperationFailure)

        var failure: OperationFailure? {
            if case let .failure(failure) = self { return failure }
            return nil
        }
    }

    private func send(action: HelperAction, payload: [String: JSONValue]) async -> Response {
        let now = Date()
        let request = HelperRequest(
            requestID: UUID(),
            sessionNonce: sessionNonce,
            helperDeviceID: helperDeviceID,
            action: action,
            createdAt: now,
            expiresAt: now.addingTimeInterval(30),
            payload: payload
        )
        do {
            let result = try await channel.send(request)
            guard result.requestID == request.requestID,
                  result.protocolVersion == 1,
                  result.isStructurallyValid else {
                return .failure(helperFailure("Android returned an invalid helper response."))
            }
            guard result.status == .success else {
                return .failure(mapFailure(result))
            }
            return .success(result)
        } catch is CancellationError {
            return .failure(OperationFailure(
                code: .cancelled,
                safeMessage: "Android connection maintenance was cancelled."
            ))
        } catch {
            return .failure(helperFailure("The Android helper channel is unavailable."))
        }
    }

    private func sendStop(leaseID: String) async {
        _ = await send(
            action: .keepAliveStop,
            payload: ["leaseId": .string(leaseID)]
        )
    }

    private func parseLease(
        _ result: HelperResult,
        session: BoundSession
    ) -> AndroidKeepAliveLease? {
        guard result.payload?["state"]?.stringValue == "active",
              let leaseID = result.payload?["leaseId"]?.stringValue,
              !leaseID.isEmpty,
              let startedAt = parseDate(result.payload?["startedAt"]),
              let renewedAt = parseDate(result.payload?["renewedAt"]),
              let expiresAt = parseDate(result.payload?["expiresAt"]),
              let notificationVisible = result.payload?["notificationVisible"]?.boolValue,
              let wifiLockHeld = result.payload?["wifiLockHeld"]?.boolValue,
              renewedAt >= startedAt,
              expiresAt > renewedAt,
              expiresAt.timeIntervalSince(renewedAt) <= 30.5 else { return nil }
        return AndroidKeepAliveLease(
            leaseID: leaseID,
            deviceIdentity: session.deviceIdentity,
            transportID: session.transportID,
            sessionGeneration: session.generation,
            startedAt: startedAt,
            renewedAt: renewedAt,
            expiresAt: expiresAt,
            notificationVisible: notificationVisible,
            wifiLockHeld: wifiLockHeld
        )
    }

    private func parseDate(_ value: JSONValue?) -> Date? {
        guard let text = value?.stringValue else { return nil }
        return ISO8601DateFormatter().date(from: text)
    }

    private func mapFailure(_ result: HelperResult) -> OperationFailure {
        let code: OperationFailureCode
        let safeMessage: String
        let recoveryAction: String?
        switch result.status {
        case .permissionDenied:
            code = .permissionDenied
            safeMessage = "Android connection maintenance permission was denied."
            recoveryAction = "Allow helper notifications on the device, then retry."
        case .actionRequired:
            code = .helperMissing
            safeMessage = "Android connection maintenance needs device attention."
            recoveryAction = "Unlock the device, open the managed helper, and retry."
        case .cancelled:
            code = .cancelled
            safeMessage = "Android connection maintenance was cancelled."
            recoveryAction = nil
        case .expired:
            code = .timeout
            safeMessage = "The Android connection-maintenance request expired."
            recoveryAction = "Check the connection and retry."
        case .invalid:
            code = .malformedOutput
            safeMessage = "Android returned an invalid helper response."
            recoveryAction = "Restart the managed helper and retry."
        case .failure, .success:
            code = .failure
            safeMessage = "Android connection maintenance failed."
            recoveryAction = "Restart the managed helper and retry."
        }
        return OperationFailure(
            code: code,
            safeMessage: safeMessage,
            recoveryAction: recoveryAction
        )
    }

    private func helperFailure(_ message: String) -> OperationFailure {
        OperationFailure(
            code: .helperMissing,
            safeMessage: message,
            recoveryAction: "Unlock the device, open the managed helper, and retry."
        )
    }

    private func staleFailure() -> OperationFailure {
        OperationFailure(
            code: .disconnected,
            safeMessage: "The selected Android wireless session changed before maintenance started."
        )
    }
}
