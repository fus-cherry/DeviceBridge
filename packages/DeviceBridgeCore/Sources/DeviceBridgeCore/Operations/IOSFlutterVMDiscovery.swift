import Foundation

/// A Bonjour hint only. Authentication stays in memory and never becomes a diagnostic description.
public struct IOSVMCandidate: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let port: UInt16
    let authenticationCode: String
    public init(port: UInt16, authenticationCode: String) {
        self.port = port; self.authenticationCode = authenticationCode
    }
    public var description: String { "Unverified iOS VM candidate (redacted)" }
    public var debugDescription: String { description }
}

protocol IOSApplicationProcessProviding: Sendable {
    func load(session: ConnectionSession) async throws -> IOSApplicationProcessProvider.Inventory
}
extension IOSApplicationProcessProvider: IOSApplicationProcessProviding {}

protocol IOSVMCandidateDiscovering: Sendable {
    func discover(applicationIDs: Set<String>, duration: Duration) async throws -> [IOSVMBonjourHint]
}
extension IOSVMBonjourDiscovery: IOSVMCandidateDiscovering {}

protocol IOSVMChannelConnecting: Sendable {
    func connect(candidate: IOSVMCandidate, session: ConnectionSession, processID: Int) async throws -> IOSVMMetadataChannel
}

struct IOSVMNativeChannelConnector: IOSVMChannelConnecting {
    func connect(candidate: IOSVMCandidate, session: ConnectionSession, processID: Int) async throws -> IOSVMMetadataChannel {
        try await IOSVMMetadataChannel.connect(hardwareUDID: session.deviceIdentity.rawValue,
            port: candidate.port, authenticationCode: candidate.authenticationCode, expectedProcessID: processID)
    }
}

public enum IOSVMBindingError: Error, Equatable, Sendable {
    case staleSession, unverifiedApplication, closed, operationInProgress, unavailable, cleanupFailed
}

/// Stateless issuer; its caller owns/cancels the attempt and must recheck UI selection before committing.
public struct IOSFlutterVMDiscovery: Sendable {
    private let store: DeviceSessionStore
    private let processes: any IOSApplicationProcessProviding
    private let connector: any IOSVMChannelConnecting
    private let candidates: any IOSVMCandidateDiscovering

    public init(sessionStore: DeviceSessionStore) {
        self.init(sessionStore: sessionStore, processes: IOSApplicationProcessProvider(), connector: IOSVMNativeChannelConnector())
    }

    init(sessionStore: DeviceSessionStore, processes: any IOSApplicationProcessProviding,
         connector: any IOSVMChannelConnecting, candidates: any IOSVMCandidateDiscovering = IOSVMBonjourDiscovery()) {
        store = sessionStore; self.processes = processes; self.connector = connector; self.candidates = candidates
    }

    /// Discover hints for one independently identified app, then qualify them on the selected phone.
    /// The attempt admits at most four candidates within one shared budget; cleanup is always awaited.
    /// No content RPC, host connection or automatic retry is performed here.
    public func discover(session: ConnectionSession, applicationID: String) async throws -> IOSVerifiedVMBinding {
        let deadline = ContinuousClock.now + .seconds(60)
        do {
            try await requireIOSVMSession(store: store, session: session, deadline: deadline)
            let inventory = try await processes.load(session: session)
            try await requireIOSVMSession(store: store, session: session, deadline: deadline)
            _ = try selectedIOSVMApplication(inventory, session: session, applicationID: applicationID)
            let hints = try await candidates.discover(applicationIDs: [applicationID], duration: .seconds(5))
            try await requireIOSVMSession(store: store, session: session, deadline: deadline)
            guard !hints.isEmpty, hints.count <= 4,
                  hints.allSatisfy({ $0.applicationID == applicationID }) else { throw IOSVMBindingError.unavailable }
            for hint in hints {
                try await requireIOSVMSession(store: store, session: session, deadline: deadline)
                do {
                    return try await verify(candidate: hint.candidate, session: session, applicationID: applicationID,
                        deadline: deadline)
                } catch IOSVMBindingError.unavailable {
                    // A stale/foreign VM hint is expected. verify has closed its channel before this point.
                    // Session, app-identity, cancellation and cleanup failures must not try another hint.
                    continue
                }
            }
            throw IOSVMBindingError.unavailable
        } catch {
            throw iosVMBindingFailure(error)
        }
    }

    public func verify(candidate: IOSVMCandidate, session: ConnectionSession, applicationID: String) async throws -> IOSVerifiedVMBinding {
        try await verify(candidate: candidate, session: session, applicationID: applicationID,
            deadline: ContinuousClock.now + .seconds(45))
    }

    private func verify(candidate: IOSVMCandidate, session: ConnectionSession, applicationID: String,
                        deadline: ContinuousClock.Instant) async throws -> IOSVerifiedVMBinding {
        var ownedChannel: IOSVMMetadataChannel?
        do {
            try await requireIOSVMSession(store: store, session: session, deadline: deadline)
            let before = try await processes.load(session: session)
            try await requireIOSVMSession(store: store, session: session, deadline: deadline)
            let application = try selectedIOSVMApplication(before, session: session, applicationID: applicationID)
            guard let processID = application.target.processID else { throw IOSVMBindingError.unverifiedApplication }
            let channel = try await connector.connect(candidate: candidate, session: session, processID: processID)
            ownedChannel = channel
            try await requireIOSVMSession(store: store, session: session, deadline: deadline)
            let metadata = try await channel.readMetadata()
            try await requireIOSVMSession(store: store, session: session, deadline: deadline)
            let after = try await processes.load(session: session)
            try await requireIOSVMSession(store: store, session: session, deadline: deadline)
            guard try selectedIOSVMApplication(after, session: session, applicationID: applicationID) == application else {
                throw IOSVMBindingError.unverifiedApplication
            }
            // The same stream must still describe the pinned VM after the independent device query.
            guard try await channel.readMetadata() == metadata else { throw IOSVMBindingError.unverifiedApplication }
            try await requireIOSVMSession(store: store, session: session, deadline: deadline)
            return IOSVerifiedVMBinding(session: session, application: application, metadata: metadata,
                channel: channel, store: store, processes: processes)
        } catch {
            await ownedChannel?.close()
            throw iosVMBindingFailure(error)
        }
    }
}

/// Non-transferable route owner. Only the issuer constructs it; sampling is always explicit.
public actor IOSVerifiedVMBinding: MemorySampling {
    public nonisolated let id = UUID()
    public nonisolated let session: ConnectionSession
    public nonisolated let target: TargetApplication
    public nonisolated let isolateID: String
    private let channel: IOSVMMetadataChannel
    private let application: IOSApplicationProcessProvider.Application
    private let store: DeviceSessionStore
    private let processes: any IOSApplicationProcessProviding
    private var closed = false
    private var reading = false

    fileprivate init(session: ConnectionSession, application: IOSApplicationProcessProvider.Application,
                     metadata: IOSVMMetadataChannel.Metadata, channel: IOSVMMetadataChannel,
                     store: DeviceSessionStore, processes: any IOSApplicationProcessProviding) {
        self.session = session; target = application.target; isolateID = metadata.isolateID; self.channel = channel
        self.application = application; self.store = store; self.processes = processes
    }

    public func renew() async throws {
        guard !closed else { throw IOSVMBindingError.closed }
        guard !reading else { throw IOSVMBindingError.operationInProgress }
        reading = true
        defer { reading = false }
        let deadline = ContinuousClock.now + .seconds(25)
        do {
            try await checkActive(deadline: deadline)
            let current = try await processes.load(session: session)
            try await checkActive(deadline: deadline)
            guard try selectedIOSVMApplication(current, session: session, applicationID: target.applicationID) == application else {
                throw IOSVMBindingError.unverifiedApplication
            }
            let metadata = try await channel.readMetadata()
            try await checkActive(deadline: deadline)
            guard metadata.processID == target.processID, metadata.isolateID == isolateID else {
                throw IOSVMBindingError.unverifiedApplication
            }
        } catch {
            let wasClosed = closed
            closed = true
            await channel.close()
            throw iosVMBindingFailure(error, closed: wasClosed)
        }
    }

    public func close() async {
        closed = true
        await channel.close()
    }

    /// MemoryMonitor can consume only this already-verified owner, never a URI or an invented PID.
    public func sample(target: TargetApplication, transportID: String) async -> MemoryProviderOutcome {
        guard target == self.target, transportID == session.transportID else {
            await close()
            return .invalidated(OperationFailure(code: .disconnected,
                safeMessage: "Device or application selection changed."))
        }
        do {
            return .sample(try await readMemory())
        } catch IOSVMBindingError.operationInProgress {
            return .failure(OperationFailure(code: .failure,
                safeMessage: "The verified iOS VM connection is busy."))
        } catch {
            return .invalidated(OperationFailure(code: .disconnected,
                safeMessage: "Verified iOS VM connection ended. Discover again before monitoring."))
        }
    }

    /// Explicit one-shot sampling; discovery and renewal never call this method.
    public func readMemory() async throws -> MemorySample {
        guard !closed else { throw IOSVMBindingError.closed }
        guard !reading else { throw IOSVMBindingError.operationInProgress }
        reading = true
        defer { reading = false }
        let deadline = ContinuousClock.now + .seconds(35)
        do {
            try await checkActive(deadline: deadline)
            // The private channel checks the pinned VM on both sides of the usage RPC.
            let usage = try await channel.readMemoryUsage(store: store, session: session)
            try await checkActive(deadline: deadline)
            let current = try await processes.load(session: session)
            try await checkActive(deadline: deadline)
            guard try selectedIOSVMApplication(current, session: session, applicationID: target.applicationID) == application,
                  let processID = target.processID else { throw IOSVMBindingError.unverifiedApplication }
            // Renew on the same owner after the independent app query, then commit the result.
            let metadata = try await channel.readMetadata()
            try await checkActive(deadline: deadline)
            guard metadata.processID == processID, metadata.isolateID == isolateID else { throw IOSVMBindingError.unverifiedApplication }
            return MemorySample(deviceIdentity: session.deviceIdentity, applicationID: target.applicationID,
                processID: processID, processStartIdentity: target.processStartIdentity, capturedAt: usage.capturedAt,
                source: .flutterVMService, heapUsedBytes: usage.heapUsedBytes, externalBytes: usage.externalBytes)
        } catch {
            let wasClosed = closed
            closed = true
            await channel.close()
            throw iosVMBindingFailure(error, closed: wasClosed)
        }
    }

    private func checkActive(deadline: ContinuousClock.Instant) async throws {
        guard !closed else { throw IOSVMBindingError.closed }
        try await requireIOSVMSession(store: store, session: session, deadline: deadline)
        guard !closed else { throw IOSVMBindingError.closed }
    }
}

private func requireIOSVMSession(store: DeviceSessionStore, session: ConnectionSession,
                                 deadline: ContinuousClock.Instant) async throws {
    try Task.checkCancellation()
    let current = await store.snapshot()
    try Task.checkCancellation()
    guard current.session == session, current.selectedDeviceIdentity == session.deviceIdentity,
          session.state == .active, session.deviceIdentity.platform == .iOS,
          session.deviceIdentity.stability == .stable else { throw IOSVMBindingError.staleSession }
    guard ContinuousClock.now < deadline else { throw IOSVMBindingError.unavailable }
}

private func selectedIOSVMApplication(_ inventory: IOSApplicationProcessProvider.Inventory, session: ConnectionSession,
                                     applicationID: String) throws -> IOSApplicationProcessProvider.Application {
    guard inventory.session == session else { throw IOSVMBindingError.staleSession }
    let matches = inventory.applications.filter { $0.target.applicationID == applicationID }
    guard matches.count == 1, let app = matches.first, app.target.deviceIdentity == session.deviceIdentity,
          app.target.state == .running, app.target.debuggable == true,
          let pid = app.target.processID, pid > 0, pid <= Int(Int32.max) else { throw IOSVMBindingError.unverifiedApplication }
    return app
}

private func iosVMBindingFailure(_ error: any Error, closed: Bool = false) -> any Error {
    if error as? IOSApplicationProcessProvider.Failure == .cleanupFailed
        || error as? IOSVMBindingError == .cleanupFailed { return IOSVMBindingError.cleanupFailed }
    if Task.isCancelled || error is CancellationError { return CancellationError() }
    if closed { return IOSVMBindingError.closed }
    if let providerFailure = error as? IOSApplicationProcessProvider.Failure {
        switch providerFailure {
        case .wrongDevice, .unsupportedRoute: return IOSVMBindingError.staleSession
        case .invalidMetadata, .unavailable: return IOSVMBindingError.unverifiedApplication
        case .cleanupFailed: return IOSVMBindingError.cleanupFailed
        }
    }
    if error as? IOSVMMetadataChannel.Failure == .staleSession { return IOSVMBindingError.staleSession }
    return (error as? IOSVMBindingError) ?? IOSVMBindingError.unavailable
}
