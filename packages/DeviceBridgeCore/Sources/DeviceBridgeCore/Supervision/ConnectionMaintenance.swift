import Foundation

public protocol ConnectionMaintenanceTransport: Sendable {
    func probe(_ candidate: TransportCandidate) async throws -> Bool
    /// Read-only liveness on the captured route, without helper forwards or identity authority.
    func observeCurrentRoute(_ candidate: TransportCandidate) async throws -> Bool
    func discover() async throws -> [TransportCandidate]
    func recoveryEndpoints(for candidate: TransportCandidate) async throws -> [String]
    func connect(endpoint: String) async throws
    /// Metadata-only proof of the already-authenticated helper identity AND a working command.
    func verifyIdentity(_ candidate: TransportCandidate) async throws -> Bool
}

public struct ConnectionMaintenanceSnapshot: Sendable, Equatable {
    public let health: ConnectionHealthState
    public let session: ConnectionSession
    public let lastSuccessfulCommandAt: Date?
    public let recoveryAttempt: Int
}

/// One instance is bound to one selected physical device. The store owns session commits;
/// this actor owns scheduling/policy only, and never accepts inventory as identity proof.
public actor ConnectionMaintenance {
    private let owner = UUID()
    private let store: DeviceSessionStore
    private let transport: any ConnectionMaintenanceTransport
    private var session: ConnectionSession
    private var candidate: TransportCandidate?
    private var policy = ConnectionSupervisor(state: .healthy)
    private var registered = false
    private var stopped = false
    private var actionRequired = false
    private var lastSuccess: Date?
    private var attempts = 0
    private var tickTask: Task<ConnectionMaintenanceSnapshot, Never>?

    public init(store: DeviceSessionStore, transport: any ConnectionMaintenanceTransport,
                device: DeviceRecord, session: ConnectionSession) {
        self.store = store; self.transport = transport; self.session = session
        candidate = device.candidates.first { $0.id == session.transportID }
    }

    public var snapshot: ConnectionMaintenanceSnapshot {
        ConnectionMaintenanceSnapshot(health: stopped ? .stopped : (actionRequired ? .actionRequired : policy.state),
            session: session, lastSuccessfulCommandAt: lastSuccess, recoveryAttempt: attempts)
    }

    public var nextDelay: Duration {
        policy.state == .reconnecting ? .seconds(min(1 << min(attempts, 3), 8)) : .seconds(5)
    }

    public func activate() async -> Bool {
        guard !stopped, !registered, candidate != nil else { return false }
        registered = await store.registerMaintenance(owner: owner, session: session)
        if stopped { await store.stopMaintenance(owner: owner); return false }
        return registered
    }

    public func tick() async -> ConnectionMaintenanceSnapshot {
        guard registered, !stopped, !actionRequired, tickTask == nil,
              session.state != .selecting else { return snapshot }
        let work = Task { await self.performTick() }
        tickTask = work
        let result = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
        tickTask = nil
        return stopped ? snapshot : result
    }

    public func stop() async {
        stopped = true
        policy.stop()
        tickTask?.cancel()
        await store.stopMaintenance(owner: owner)
    }

    public func resumeAfterRebinding() async -> Bool {
        guard await isCurrent(), let next = await store.completeRecoveryRebinding(owner: owner, session: session),
              !stopped, !Task.isCancelled else { return false }
        session = next
        return true
    }

    private func isCurrent() async -> Bool {
        let matches = await store.maintenanceMatches(owner: owner, session: session)
        return matches && !stopped && !Task.isCancelled
    }

    private func performTick() async -> ConnectionMaintenanceSnapshot {
        guard await isCurrent(), let candidate, candidate.id == session.transportID else { return snapshot }
        let exclusive = await store.reserveConnectionProbe(owner: owner, session: session)
        if !exclusive {
            guard await store.reserveCurrentRouteObservation(owner: owner, session: session) else { return snapshot }
        }
        guard await isCurrent() else {
            await store.releaseConnectionProbe(owner: owner)
            return snapshot
        }
        if !exclusive {
            await checkHealth(candidate, observingOnly: true)
        } else if session.state == .disconnected {
            await recover(from: candidate)
        } else {
            await checkHealth(candidate, observingOnly: false)
        }
        await store.releaseConnectionProbe(owner: owner)
        return snapshot
    }

    private func checkHealth(_ candidate: TransportCandidate, observingOnly: Bool) async {
        guard policy.beginHealthProbe() == .started else { return }
        let healthy: Bool
        if observingOnly {
            healthy = (try? await transport.observeCurrentRoute(candidate)) == true
        } else {
            healthy = (try? await transport.probe(candidate)) == true
        }
        guard await isCurrent() else { return }
        let transition = policy.completeHealthProbe(succeeded: healthy)
        if healthy {
            lastSuccess = Date()
            // Wired preference is considered only while the store's between-operation
            // reservation is held. In-flight transfers are never migrated.
            if !observingOnly, candidate.kind == .wifi, let candidates = try? await transport.discover(), await isCurrent() {
                for usb in candidates.filter({ $0.kind == .usb }).prefix(8) {
                    guard await isCurrent() else { return }
                    if (try? await transport.verifyIdentity(usb)) == true, await isCurrent() {
                        await commit(usb)
                        return
                    }
                }
            }
        } else if transition == .beginRecoveryAndInvalidate,
                  let next = await store.invalidateForRecovery(owner: owner, session: session), !stopped {
            session = next
            attempts = 0
        }
    }

    private func recover(from previous: TransportCandidate) async {
        attempts += 1
        do {
            // USB arrival and ADB's own reconnect may already have supplied a healthy route.
            if try await findVerifiedRoute() { return }
            guard await isCurrent() else { return }
            let endpoints = try await transport.recoveryEndpoints(for: previous)
            for endpoint in endpoints.prefix(4) {
                guard await isCurrent() else { return }
                try? await transport.connect(endpoint: endpoint)
                guard await isCurrent() else { return }
                if try await findVerifiedRoute() { return }
            }
        } catch { /* External text is never used as a user-facing diagnostic. */ }
        guard await isCurrent() else { return }
        if attempts >= 8 { actionRequired = true }
    }

    private func findVerifiedRoute() async throws -> Bool {
        let candidates = try await transport.discover()
        guard await isCurrent() else { return false }
        let sorted = candidates.sorted { $0.kind != $1.kind ? $0.kind == .usb : $0.id < $1.id }
        for candidate in sorted.prefix(8) {
            guard await isCurrent() else { return false }
            if (try? await transport.verifyIdentity(candidate)) == true, await isCurrent() {
                await commit(candidate)
                return session.state == .selecting
            }
        }
        return false
    }

    private func commit(_ candidate: TransportCandidate) async {
        guard await isCurrent(),
              let next = await store.commitVerifiedRecovery(owner: owner, session: session, candidate: candidate),
              !stopped, !Task.isCancelled else { return }
        session = next
        self.candidate = candidate
        lastSuccess = Date()
        attempts = 0
        _ = policy.verifyRecovery(identityMatches: true, commandSucceeded: true)
    }
}
