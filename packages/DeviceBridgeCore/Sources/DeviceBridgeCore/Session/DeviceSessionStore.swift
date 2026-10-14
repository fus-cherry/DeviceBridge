import Foundation

public enum DeviceSessionStoreError: Error, Equatable, Sendable {
    case deviceNotFound
    case noUsableTransport
    case noActiveSession
    case staleSession
    case connectionBusy
}

/// Publication invalidation is separate from confirmation that Shell resources have closed.
public enum ShellOperationInvalidationReason: Sendable, Equatable {
    case cancelled
    case timedOut
    case sessionInvalidated
}

/// Store-level terminal categories; the execution owner retains output and remote exit code.
public enum ShellOperationTerminal: Sendable, Equatable {
    case remoteExit
    case cancelled
    case timedOut
    case failure
}

public struct WorkspaceSnapshot: Sendable, Equatable {
    public let devices: [DeviceRecord]
    public let selectedDeviceIdentity: DeviceIdentity?
    public let session: ConnectionSession?
    public let generation: Int
    public let activeOperationIDs: Set<UUID>

    public init(
        devices: [DeviceRecord],
        selectedDeviceIdentity: DeviceIdentity?,
        session: ConnectionSession?,
        generation: Int,
        activeOperationIDs: Set<UUID>
    ) {
        self.devices = devices
        self.selectedDeviceIdentity = selectedDeviceIdentity
        self.session = session
        self.generation = generation
        self.activeOperationIDs = activeOperationIDs
    }
}

public actor DeviceSessionStore {
    private var devices: [DeviceRecord] = []
    private var selectedDeviceIdentity: DeviceIdentity?
    private var session: ConnectionSession?
    private var generation = 0
    private enum OperationPhase {
        case active
        case draining(ShellOperationInvalidationReason)
    }
    private struct OperationRecord {
        let kind: OperationKind
        let token: SessionToken
        var phase: OperationPhase
    }
    private enum ProbeMode { case exclusive, currentRouteObservation }
    private struct ProbeReservation {
        let owner: UUID
        let mode: ProbeMode
    }
    private var operations: [UUID: OperationRecord] = [:]
    private var maintenanceOwner: UUID?
    private var probeReservation: ProbeReservation?

    public init() {}

    public func replaceInventory(_ replacement: [DeviceRecord]) {
        // Inventory is observational while maintenance owns a selected session. Only a
        // verified recovery may change that session's physical route.
        if maintenanceOwner != nil, let selectedDeviceIdentity,
           let selected = devices.first(where: { $0.identity == selectedDeviceIdentity }) {
            let ownedRoutes = Set(selected.candidates.map(\.id))
            let displayed: DeviceRecord
            if selectedDeviceIdentity.stability == .stable,
               let fresh = replacement.first(where: { $0.identity == selectedDeviceIdentity }) {
                var routes = fresh.candidates
                if let owned = selected.candidates.first(where: { $0.id == session?.transportID }),
                   !routes.contains(where: { $0.id == owned.id }) {
                    routes.append(owned)
                }
                displayed = DeviceRecord(identity: selected.identity, name: fresh.name,
                    model: fresh.model, osVersion: fresh.osVersion, authorization: fresh.authorization,
                    candidates: routes, preferredTransportID: session?.transportID ?? selected.preferredTransportID)
            } else {
                displayed = hasShellOperation ? (replacement.first { $0.identity == selectedDeviceIdentity } ?? selected) : selected
            }
            devices = replacement.filter {
                $0.identity != selectedDeviceIdentity
                    && !$0.candidates.contains { ownedRoutes.contains($0.id) && $0.source == .adb }
            } + [displayed]
            return
        }
        devices = replacement
        guard let selectedDeviceIdentity else { return }
        guard let selected = replacement.first(where: { $0.identity == selectedDeviceIdentity }) else {
            invalidateOperations()
            generation += 1
            if let current = session {
                session = ConnectionSession(
                    deviceIdentity: current.deviceIdentity,
                    generation: generation,
                    transportID: current.transportID,
                    state: .disconnected,
                    startedAt: current.startedAt
                )
            }
            return
        }

        guard let preferredTransportID = selected.preferredTransportID else {
            invalidateOperations()
            generation += 1
            if let current = session {
                session = ConnectionSession(
                    deviceIdentity: current.deviceIdentity,
                    generation: generation,
                    transportID: current.transportID,
                    state: .disconnected,
                    startedAt: current.startedAt
                )
            }
            return
        }

        if let current = session,
           current.state == .active,
           current.transportID != preferredTransportID,
           operations.isEmpty, probeReservation == nil {
            invalidateOperations()
            generation += 1
            session = ConnectionSession(
                deviceIdentity: selectedDeviceIdentity,
                generation: generation,
                transportID: preferredTransportID,
                state: .active,
                startedAt: Date()
            )
        }
    }

    @discardableResult
    public func select(_ identity: DeviceIdentity) throws -> WorkspaceSnapshot {
        guard let selected = devices.first(where: { $0.identity == identity }) else {
            throw DeviceSessionStoreError.deviceNotFound
        }
        guard let preferredTransportID = selected.preferredTransportID else {
            throw DeviceSessionStoreError.noUsableTransport
        }

        invalidateOperations()
        maintenanceOwner = nil
        probeReservation = nil
        generation += 1
        selectedDeviceIdentity = identity
        session = ConnectionSession(
            deviceIdentity: identity,
            generation: generation,
            transportID: preferredTransportID,
            state: .active,
            startedAt: Date()
        )
        return makeSnapshot()
    }

    public func beginOperation(
        _ kind: OperationKind,
        id: UUID = UUID(),
        expectedSession: ConnectionSession? = nil
    ) throws -> SessionToken {
        guard let session, session.state == .active else {
            throw DeviceSessionStoreError.noActiveSession
        }
        guard expectedSession == nil || expectedSession == session else {
            throw DeviceSessionStoreError.staleSession
        }
        guard probeReservation == nil, operations[id] == nil,
              kind != .androidShell || !hasShellOperation else {
            throw DeviceSessionStoreError.connectionBusy
        }
        let token = SessionToken(
            deviceIdentity: session.deviceIdentity,
            transportID: session.transportID,
            sessionGeneration: session.generation,
            operationID: id
        )
        operations[id] = OperationRecord(kind: kind, token: token, phase: .active)
        return token
    }

    public func canPublish(_ token: SessionToken) -> Bool {
        guard let session, let operation = operations[token.operationID],
              operation.token == token, case .active = operation.phase else { return false }
        return token.canPublish(
            in: session,
            activeOperationIDs: activeOperationIDs
        )
    }

    /// Consume the operation and return its publication eligibility atomically on this owner.
    @discardableResult
    public func finishOperation(_ token: SessionToken) -> Bool {
        guard operations[token.operationID]?.token == token else { return false }
        let eligible = canPublish(token)
        operations.removeValue(forKey: token.operationID)
        return eligible
    }

    /// Revoke success immediately. Only Shell retains its resource exclusion until finish.
    public func invalidateOperation(_ token: SessionToken, reason: ShellOperationInvalidationReason) {
        guard var operation = operations[token.operationID], operation.token == token else { return }
        guard operation.kind == .androidShell else {
            operations.removeValue(forKey: token.operationID)
            return
        }
        // The first local terminal cause wins, but session loss always revokes history eligibility.
        if case .active = operation.phase {
            operation.phase = .draining(reason)
        } else if reason == .sessionInvalidated {
            operation.phase = .draining(.sessionInvalidated)
        }
        operations[token.operationID] = operation
    }

    /// Call only after every socket and read/write task for this execution has finished closing.
    /// The result authorizes presentation, not remote success; the caller still checks its epoch.
    @discardableResult
    public func finishShellOperation(_ token: SessionToken, terminal: ShellOperationTerminal) -> Bool {
        guard let operation = operations[token.operationID], operation.token == token,
              operation.kind == .androidShell else { return false }
        operations.removeValue(forKey: token.operationID)
        guard let session, token.canPublish(in: session, activeOperationIDs: [token.operationID]) else {
            return false
        }
        switch operation.phase {
        case .active: return true
        case .draining(.cancelled): return terminal == .cancelled
        case .draining(.timedOut): return terminal == .timedOut
        case .draining(.sessionInvalidated): return false
        }
    }

    public func disconnect() {
        maintenanceOwner = nil
        probeReservation = nil
        guard let current = session else {
            invalidateOperations()
            return
        }
        guard current.state != .disconnected || !activeOperationIDs.isEmpty else { return }

        invalidateOperations()
        generation += 1
        session = ConnectionSession(
            deviceIdentity: current.deviceIdentity,
            generation: generation,
            transportID: current.transportID,
            state: .disconnected,
            startedAt: current.startedAt
        )
    }

    public func snapshot() -> WorkspaceSnapshot {
        makeSnapshot()
    }

    public func registerMaintenance(owner: UUID, session expected: ConnectionSession) -> Bool {
        guard session == expected, expected.state == .active, maintenanceOwner == nil else { return false }
        maintenanceOwner = owner
        return true
    }

    public func markCommandReady(session expected: ConnectionSession) {
        guard session == expected,
              let index = devices.firstIndex(where: { $0.identity == expected.deviceIdentity }),
              let candidate = devices[index].candidates.first(where: { $0.id == expected.transportID }),
              let ready = try? TransportCandidate(id: candidate.id, identity: candidate.identity,
                kind: candidate.kind, source: candidate.source, status: .available, observedAt: Date(),
                lastHealthyAt: Date(), metadata: candidate.metadata, endpoint: candidate.endpoint) else { return }
        let previous = devices[index]
        devices[index] = DeviceRecord(identity: previous.identity, name: previous.name, model: previous.model,
            osVersion: previous.osVersion, authorization: .authorized,
            candidates: previous.candidates.map { $0.id == ready.id ? ready : $0 },
            preferredTransportID: ready.id, capabilities: previous.capabilities)
    }

    public func maintenanceMatches(owner: UUID, session expected: ConnectionSession) -> Bool {
        maintenanceOwner == owner && session == expected
    }

    public func reserveConnectionProbe(owner: UUID, session expected: ConnectionSession) -> Bool {
        guard maintenanceMatches(owner: owner, session: expected), operations.isEmpty,
              probeReservation == nil else { return false }
        probeReservation = ProbeReservation(owner: owner, mode: .exclusive)
        return true
    }

    /// A weak health observation may coexist only with Shell, never legacy content work.
    /// It cannot gain migration authority if Shell finishes while the observation awaits.
    public func reserveCurrentRouteObservation(owner: UUID, session expected: ConnectionSession) -> Bool {
        guard maintenanceMatches(owner: owner, session: expected), expected.state == .active,
              probeReservation == nil, hasShellOperation,
              operations.values.allSatisfy({ $0.kind == .androidShell }) else { return false }
        probeReservation = ProbeReservation(owner: owner, mode: .currentRouteObservation)
        return true
    }

    public func releaseConnectionProbe(owner: UUID) {
        if probeReservation?.owner == owner { probeReservation = nil }
    }

    public func stopMaintenance(owner: UUID) {
        guard maintenanceOwner == owner else { return }
        maintenanceOwner = nil
        probeReservation = nil
    }

    public func invalidateForRecovery(owner: UUID, session expected: ConnectionSession) -> ConnectionSession? {
        guard maintenanceMatches(owner: owner, session: expected),
              probeReservation?.owner == owner else { return nil }
        invalidateOperations()
        generation += 1
        let next = ConnectionSession(deviceIdentity: expected.deviceIdentity, generation: generation,
            transportID: expected.transportID, state: .disconnected, startedAt: expected.startedAt)
        session = next
        return next
    }

    /// The caller must have verified the helper identity on this route. The selecting state
    /// blocks old feature providers until the workspace has rebound them to the new transport.
    public func commitVerifiedRecovery(
        owner: UUID, session expected: ConnectionSession, candidate: TransportCandidate
    ) -> ConnectionSession? {
        guard maintenanceMatches(owner: owner, session: expected), probeReservation?.owner == owner,
              probeReservation?.mode == .exclusive, operations.isEmpty, candidate.source == .adb,
              let index = devices.firstIndex(where: { $0.identity == expected.deviceIdentity }),
              let verified = try? TransportCandidate(
                id: candidate.id, identity: expected.deviceIdentity, kind: candidate.kind, source: .adb,
                status: .available, observedAt: Date(), lastHealthyAt: Date(),
                metadata: candidate.metadata, endpoint: candidate.endpoint
              ) else { return nil }
        let previous = devices[index]
        devices[index] = DeviceRecord(identity: previous.identity, name: previous.name,
            model: previous.model, osVersion: previous.osVersion, authorization: .authorized,
            candidates: [verified], preferredTransportID: verified.id)
        devices.removeAll { $0.identity != previous.identity && $0.candidates.contains {
            $0.source == .adb && $0.id == verified.id
        } }
        invalidateOperations()
        generation += 1
        let next = ConnectionSession(deviceIdentity: expected.deviceIdentity, generation: generation,
            transportID: verified.id, state: .selecting, startedAt: Date())
        session = next
        return next
    }

    public func completeRecoveryRebinding(owner: UUID, session expected: ConnectionSession) -> ConnectionSession? {
        guard maintenanceMatches(owner: owner, session: expected), expected.state == .selecting else { return nil }
        let next = ConnectionSession(deviceIdentity: expected.deviceIdentity, generation: expected.generation,
            transportID: expected.transportID, state: .active, startedAt: expected.startedAt)
        session = next
        return next
    }

    private func invalidateOperations() {
        for operation in operations.values {
            invalidateOperation(operation.token, reason: .sessionInvalidated)
        }
    }

    private var hasShellOperation: Bool {
        operations.values.contains { $0.kind == .androidShell }
    }

    private var activeOperationIDs: Set<UUID> {
        Set(operations.values.compactMap {
            if case .active = $0.phase { return $0.token.operationID }
            return nil
        })
    }

    private func makeSnapshot() -> WorkspaceSnapshot {
        WorkspaceSnapshot(
            devices: devices,
            selectedDeviceIdentity: selectedDeviceIdentity,
            session: session,
            generation: generation,
            activeOperationIDs: activeOperationIDs
        )
    }
}
