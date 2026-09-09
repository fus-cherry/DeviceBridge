import Foundation

public enum DeviceSessionStoreError: Error, Equatable, Sendable {
    case deviceNotFound
    case noUsableTransport
    case noActiveSession
    case connectionBusy
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
    private var activeOperations: [UUID: OperationKind] = [:]
    private var maintenanceOwner: UUID?
    private var probeOwner: UUID?

    public init() {}

    public func replaceInventory(_ replacement: [DeviceRecord]) {
        // Inventory is observational while maintenance owns a selected session. Only a
        // verified recovery may change that session's physical route.
        if maintenanceOwner != nil, let selectedDeviceIdentity,
           let selected = devices.first(where: { $0.identity == selectedDeviceIdentity }) {
            let ownedRoutes = Set(selected.candidates.map(\.id))
            devices = replacement.filter {
                $0.identity != selectedDeviceIdentity
                    && !$0.candidates.contains { ownedRoutes.contains($0.id) && $0.source == .adb }
            } + [selected]
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
           current.transportID != preferredTransportID {
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
        probeOwner = nil
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
        id: UUID = UUID()
    ) throws -> SessionToken {
        guard let session, session.state == .active else {
            throw DeviceSessionStoreError.noActiveSession
        }
        guard probeOwner == nil else { throw DeviceSessionStoreError.connectionBusy }
        activeOperations[id] = kind
        return SessionToken(
            deviceIdentity: session.deviceIdentity,
            transportID: session.transportID,
            sessionGeneration: session.generation,
            operationID: id
        )
    }

    public func canPublish(_ token: SessionToken) -> Bool {
        guard let session else { return false }
        return token.canPublish(
            in: session,
            activeOperationIDs: Set(activeOperations.keys)
        )
    }

    /// Consume the operation and return its publication eligibility atomically on this owner.
    @discardableResult
    public func finishOperation(_ token: SessionToken) -> Bool {
        let eligible = canPublish(token)
        activeOperations.removeValue(forKey: token.operationID)
        return eligible
    }

    public func disconnect() {
        maintenanceOwner = nil
        probeOwner = nil
        guard let current = session else {
            invalidateOperations()
            return
        }
        guard current.state != .disconnected || !activeOperations.isEmpty else { return }

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
        guard maintenanceMatches(owner: owner, session: expected), activeOperations.isEmpty,
              probeOwner == nil else { return false }
        probeOwner = owner
        return true
    }

    public func releaseConnectionProbe(owner: UUID) {
        if probeOwner == owner { probeOwner = nil }
    }

    public func stopMaintenance(owner: UUID) {
        guard maintenanceOwner == owner else { return }
        maintenanceOwner = nil
        probeOwner = nil
    }

    public func invalidateForRecovery(owner: UUID, session expected: ConnectionSession) -> ConnectionSession? {
        guard maintenanceMatches(owner: owner, session: expected) else { return nil }
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
        guard maintenanceMatches(owner: owner, session: expected), probeOwner == owner,
              activeOperations.isEmpty, candidate.source == .adb,
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
        activeOperations.removeAll(keepingCapacity: true)
    }

    private func makeSnapshot() -> WorkspaceSnapshot {
        WorkspaceSnapshot(
            devices: devices,
            selectedDeviceIdentity: selectedDeviceIdentity,
            session: session,
            generation: generation,
            activeOperationIDs: Set(activeOperations.keys)
        )
    }
}
