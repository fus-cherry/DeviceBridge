import DeviceBridgeProtocol
import Foundation
@preconcurrency import Network

public struct ADBServerEpoch: Hashable, Sendable {
    fileprivate let id: UUID

    fileprivate init(id: UUID = UUID()) {
        self.id = id
    }
}

public enum ADBRouteIdentityEvidence: Sendable, Equatable {
    case uniqueUSBSerial
    case trustedWiFiHelper(HelperSessionContext)
}

public struct ADBCapturedRoute: Sendable, Equatable {
    public let adbSerial: String
    public let transportID: UInt64
    public let sessionGeneration: Int
    public let identityEvidence: ADBRouteIdentityEvidence

    public init(
        adbSerial: String,
        transportID: UInt64,
        sessionGeneration: Int,
        identityEvidence: ADBRouteIdentityEvidence
    ) throws {
        guard !adbSerial.isEmpty, !adbSerial.contains("\0"), transportID > 0,
              sessionGeneration > 0 else {
            throw ADBServerConnectionError.invalidRoute
        }
        self.adbSerial = adbSerial
        self.transportID = transportID
        self.sessionGeneration = sessionGeneration
        self.identityEvidence = identityEvidence
    }
}

public enum ADBServerConnectionError: Error, Sendable, Equatable {
    case invalidEndpoint
    case invalidRoute
    case connectionFailed
    case timedOut
    case cancelled
    case protocolFailure
    case serviceRejected
    case shellV2Unavailable
    case routeMismatch
    case identityMismatch
    case staleSession
    case epochInvalidated
}

/// Owns one observed lifetime of a loopback ADB server. Once the observer drops,
/// this owner and its epoch stay invalid; a future session must create a new owner.
public actor ADBServerConnection {
    private struct Opening {
        let id: UUID
        let socket: ADBClientSocket
        let task: Task<Void, Error>
    }

    private enum State {
        case idle
        case opening(Opening)
        case active(ADBServerEpoch)
        case invalidated
    }

    private let host: NWEndpoint.Host
    private let port: NWEndpoint.Port
    private let onEpochInvalidated: @Sendable (ADBServerEpoch) -> Void
    private var state: State = .idle
    private var observer: ADBClientSocket?
    private var observerTask: Task<Void, Never>?
    private var invalidationCleanup: Task<Void, Never>?
    private var activeResources: [ObjectIdentifier: ADBExecutionResources] = [:]

    public init(
        host: String = "127.0.0.1",
        port: Int = 5_037,
        onEpochInvalidated: @escaping @Sendable (ADBServerEpoch) -> Void = { _ in }
    ) throws {
        guard host == "127.0.0.1" || host == "::1",
              let rawPort = UInt16(exactly: port), rawPort > 0,
              let endpointPort = NWEndpoint.Port(rawValue: rawPort) else {
            throw ADBServerConnectionError.invalidEndpoint
        }
        self.host = NWEndpoint.Host(host)
        self.port = endpointPort
        self.onEpochInvalidated = onEpochInvalidated
    }

    public func beginEpoch(deadline: ContinuousClock.Instant) async throws -> ADBServerEpoch {
        let opening: Opening
        switch state {
        case let .active(epoch): return epoch
        case .invalidated: throw ADBServerConnectionError.epochInvalidated
        case let .opening(existing): opening = existing
        case .idle:
            try Task.checkCancellation()
            let socket = ADBClientSocket(host: host, port: port)
            let task = Task {
                try await socket.start(deadline: deadline)
                try await socket.sendSmartRequest("host:track-devices", deadline: deadline)
                try await socket.readOkay(deadline: deadline)
                _ = try await socket.readSmartPayload(maximumBytes: 1_048_576, deadline: deadline)
                try Task.checkCancellation()
            }
            opening = Opening(id: UUID(), socket: socket, task: task)
            state = .opening(opening)
        }

        do {
            try await opening.task.value
        } catch {
            await opening.socket.cancelAndWait()
            if case let .opening(current) = state, current.id == opening.id {
                state = .idle
            }
            if case .invalidated = state {
                if let invalidationCleanup { await invalidationCleanup.value }
                throw ADBServerConnectionError.epochInvalidated
            }
            throw Self.map(error)
        }

        let epoch: ADBServerEpoch
        switch state {
        case let .opening(current) where current.id == opening.id:
            epoch = ADBServerEpoch()
            state = .active(epoch)
            observer = opening.socket
            observerTask = Task { [weak self] in
                await self?.observe(socket: opening.socket, epoch: epoch)
            }
        case let .active(current):
            epoch = current
        case .invalidated:
            await opening.socket.cancelAndWait()
            if let invalidationCleanup { await invalidationCleanup.value }
            throw ADBServerConnectionError.epochInvalidated
        case .idle, .opening:
            await opening.socket.cancelAndWait()
            throw ADBServerConnectionError.connectionFailed
        }
        try Task.checkCancellation()
        return epoch
    }

    public func isCurrent(_ epoch: ADBServerEpoch) -> Bool {
        guard case let .active(current) = state else { return false }
        return current == epoch
    }

    public func close() async {
        switch state {
        case .idle:
            state = .invalidated
        case let .opening(opening):
            state = .invalidated
            opening.task.cancel()
            opening.socket.cancel()
            let cleanup = Task { await opening.socket.cancelAndWait() }
            invalidationCleanup = cleanup
            await cleanup.value
        case let .active(epoch):
            await invalidate(epoch)
        case .invalidated:
            if let invalidationCleanup { await invalidationCleanup.value }
        }
    }

    func openExecution(
        route: ADBCapturedRoute,
        epoch: ADBServerEpoch,
        resources: ADBExecutionResources,
        deadline: ContinuousClock.Instant,
        validateSession: @escaping @Sendable () async -> Bool
    ) async throws -> ADBClientSocket {
        try await validate(route: route, epoch: epoch, validateSession: validateSession)
        activeResources[ObjectIdentifier(resources)] = resources
        try await requireShellV2(route: route, epoch: epoch, resources: resources,
            deadline: deadline, validateSession: validateSession)

        let execution = try await openSocket(resources: resources, deadline: deadline)
        do {
            try await bind(execution, route: route, deadline: deadline)
            try await validate(route: route, epoch: epoch, validateSession: validateSession)
            if case let .trustedWiFiHelper(context) = route.identityEvidence {
                try await verifyHelper(context, route: route, epoch: epoch, resources: resources,
                    deadline: deadline, validateSession: validateSession)
                try await validate(route: route, epoch: epoch, validateSession: validateSession)
            }
            return execution
        } catch {
            await resources.remove(execution)
            throw Self.map(error)
        }
    }

    func finishExecution(_ resources: ADBExecutionResources) {
        activeResources.removeValue(forKey: ObjectIdentifier(resources))
    }

    private func requireShellV2(
        route: ADBCapturedRoute,
        epoch: ADBServerEpoch,
        resources: ADBExecutionResources,
        deadline: ContinuousClock.Instant,
        validateSession: @escaping @Sendable () async -> Bool
    ) async throws {
        let socket = try await openSocket(resources: resources, deadline: deadline)
        do {
            try await socket.sendSmartRequest("host-serial:\(route.adbSerial):features", deadline: deadline)
            try await socket.readOkay(deadline: deadline)
            let payload = try await socket.readSmartPayload(maximumBytes: 1_048_576, deadline: deadline)
            await resources.remove(socket)
            guard String(decoding: payload, as: UTF8.self).split(separator: ",").contains("shell_v2") else {
                throw ADBServerConnectionError.shellV2Unavailable
            }
            try await validate(route: route, epoch: epoch, validateSession: validateSession)
        } catch {
            await resources.remove(socket)
            throw Self.map(error)
        }
    }

    private func verifyHelper(
        _ context: HelperSessionContext,
        route: ADBCapturedRoute,
        epoch: ADBServerEpoch,
        resources: ADBExecutionResources,
        deadline: ContinuousClock.Instant,
        validateSession: @escaping @Sendable () async -> Bool
    ) async throws {
        let socket = try await openSocket(resources: resources, deadline: deadline)
        do {
            try await bind(socket, route: route, deadline: deadline)
            try await validate(route: route, epoch: epoch, validateSession: validateSession)
            try await socket.sendSmartRequest("localabstract:\(AndroidHelperManager.socketName)", deadline: deadline)
            try await socket.readOkay(deadline: deadline)
            let now = Date()
            let request = HelperRequest(requestID: UUID(), sessionNonce: context.sessionNonce,
                helperDeviceID: context.helperDeviceID, action: .identity, createdAt: now,
                expiresAt: now.addingTimeInterval(5), payload: [:])
            try await socket.write(HelperFrameCodec.encode(HelperWireCodec().encode(request)), deadline: deadline)
            let header = try await socket.readExactly(4, deadline: deadline)
            let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard length <= 1_048_576 else { throw ADBServerConnectionError.protocolFailure }
            let response = try await socket.readExactly(Int(length), deadline: deadline)
            let result = try HelperWireCodec().decodeResult(response)
            guard result.protocolVersion == 1, result.requestID == request.requestID,
                  result.status == .success, result.isStructurallyValid,
                  result.payload?["helperDeviceId"]?.stringValue == context.helperDeviceID,
                  result.payload?["helperVersion"]?.stringValue == context.helperVersion,
                  case let .array(protocolVersions)? = result.payload?["protocolVersions"],
                  protocolVersions.contains(.number(1)) else {
                throw ADBServerConnectionError.identityMismatch
            }
            await resources.remove(socket)
        } catch {
            await resources.remove(socket)
            if error as? ADBServerConnectionError == .identityMismatch { throw error }
            throw Self.map(error)
        }
    }

    private func openSocket(
        resources: ADBExecutionResources,
        deadline: ContinuousClock.Instant
    ) async throws -> ADBClientSocket {
        let socket = ADBClientSocket(host: host, port: port)
        guard resources.insert(socket) else { throw ADBServerConnectionError.cancelled }
        do {
            try await socket.start(deadline: deadline)
            return socket
        } catch {
            await resources.remove(socket)
            throw Self.map(error)
        }
    }

    private func bind(
        _ socket: ADBClientSocket,
        route: ADBCapturedRoute,
        deadline: ContinuousClock.Instant
    ) async throws {
        try await socket.sendSmartRequest("host:tport:serial:\(route.adbSerial)", deadline: deadline)
        try await socket.readOkay(deadline: deadline)
        let payload = try await socket.readExactly(8, deadline: deadline)
        let actual = payload.enumerated().reduce(UInt64(0)) { partial, element in
            partial | (UInt64(element.element) << UInt64(element.offset * 8))
        }
        guard actual == route.transportID else { throw ADBServerConnectionError.routeMismatch }
    }

    private func validate(
        route: ADBCapturedRoute,
        epoch: ADBServerEpoch,
        validateSession: @escaping @Sendable () async -> Bool
    ) async throws {
        guard isCurrent(epoch) else { throw ADBServerConnectionError.epochInvalidated }
        guard await validateSession() else { throw ADBServerConnectionError.staleSession }
        guard route.sessionGeneration > 0 else { throw ADBServerConnectionError.invalidRoute }
        guard isCurrent(epoch) else { throw ADBServerConnectionError.epochInvalidated }
        try Task.checkCancellation()
    }

    private func observe(
        socket: ADBClientSocket,
        epoch: ADBServerEpoch
    ) async {
        do {
            while isCurrent(epoch) {
                _ = try await socket.readSmartPayload(maximumBytes: 1_048_576)
            }
        } catch {
            await invalidate(epoch)
        }
    }

    private func invalidate(_ epoch: ADBServerEpoch) async {
        guard case let .active(current) = state, current == epoch else { return }
        state = .invalidated
        let closingObserver = observer
        closingObserver?.cancel()
        observer = nil
        observerTask?.cancel()
        observerTask = nil
        activeResources.values.forEach { $0.cancel() }
        onEpochInvalidated(epoch)
        if let closingObserver {
            let cleanup = Task { await closingObserver.cancelAndWait() }
            invalidationCleanup = cleanup
            await cleanup.value
        }
    }

    private static func map(_ error: any Error) -> ADBServerConnectionError {
        if let error = error as? ADBServerConnectionError { return error }
        if error is CancellationError { return .cancelled }
        if let error = error as? ADBClientSocket.Failure {
            switch error {
            case .timedOut: return .timedOut
            case .cancelled: return .cancelled
            case .connectionFailed, .closed: return .connectionFailed
            case .protocolFailure: return .protocolFailure
            }
        }
        return .protocolFailure
    }
}

final class ADBExecutionResources: @unchecked Sendable {
    private let lock = NSLock()
    private var sockets: [ObjectIdentifier: ADBClientSocket] = [:]
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }

    func insert(_ socket: ADBClientSocket) -> Bool {
        let accepted = lock.withLock {
            guard !cancelled else { return false }
            sockets[ObjectIdentifier(socket)] = socket
            return true
        }
        if !accepted { socket.cancel() }
        return accepted
    }

    func remove(_ socket: ADBClientSocket) async {
        _ = lock.withLock { sockets.removeValue(forKey: ObjectIdentifier(socket)) }
        await socket.cancelAndWait()
    }

    func cancel() {
        let owned = lock.withLock { () -> [ADBClientSocket] in
            cancelled = true
            return Array(sockets.values)
        }
        owned.forEach { $0.cancel() }
    }

    func drain() async {
        let owned = lock.withLock { () -> [ADBClientSocket] in
            cancelled = true
            return Array(sockets.values)
        }
        await withTaskGroup(of: Void.self) { group in
            for socket in owned {
                group.addTask { await socket.cancelAndWait() }
            }
        }
        lock.withLock {
            for socket in owned {
                sockets.removeValue(forKey: ObjectIdentifier(socket))
            }
        }
    }
}

final class ADBClientSocket: @unchecked Sendable {
    enum Failure: Error, Equatable {
        case connectionFailed
        case closed
        case timedOut
        case cancelled
        case protocolFailure
    }

    private let connection: NWConnection
    private let lifecycle = Lifecycle()

    init(host: NWEndpoint.Host, port: NWEndpoint.Port) {
        connection = NWConnection(host: host, port: port, using: .tcp)
        connection.stateUpdateHandler = { [lifecycle] state in
            lifecycle.observe(state)
        }
    }

    func start(deadline: ContinuousClock.Instant) async throws {
        try await withDeadline(deadline) {
            self.connection.start(queue: .global(qos: .userInitiated))
            try await self.lifecycle.waitUntilReady()
        }
    }

    func sendSmartRequest(_ service: String, deadline: ContinuousClock.Instant) async throws {
        let payload = Data(service.utf8)
        guard payload.count <= 65_535 else { throw Failure.protocolFailure }
        let header = String(format: "%04X", payload.count)
        try await write(Data(header.utf8) + payload, deadline: deadline)
    }

    func readOkay(deadline: ContinuousClock.Instant) async throws {
        let status = try await readExactly(4, deadline: deadline)
        if status == Data("OKAY".utf8) { return }
        if status == Data("FAIL".utf8) {
            _ = try await readSmartPayload(maximumBytes: 64 * 1_024, deadline: deadline)
            throw ADBServerConnectionError.serviceRejected
        }
        throw Failure.protocolFailure
    }

    func readSmartPayload(maximumBytes: Int, deadline: ContinuousClock.Instant) async throws -> Data {
        let header = try await readExactly(4, deadline: deadline)
        guard let count = Self.strictHexLength(header), count <= maximumBytes else {
            throw Failure.protocolFailure
        }
        return try await readExactly(count, deadline: deadline)
    }

    func readSmartPayload(maximumBytes: Int) async throws -> Data {
        let header = try await readExactly(4)
        guard let count = Self.strictHexLength(header), count <= maximumBytes else {
            throw Failure.protocolFailure
        }
        return try await readExactly(count)
    }

    func write(_ data: Data, deadline: ContinuousClock.Instant) async throws {
        try await withDeadline(deadline) {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                self.connection.send(content: data, completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                })
            }
        }
    }

    func readExactly(_ count: Int, deadline: ContinuousClock.Instant) async throws -> Data {
        guard count >= 0 else { throw Failure.protocolFailure }
        var result = Data()
        while result.count < count {
            let maximum = min(64 * 1_024, count - result.count)
            let chunk: Data
            do {
                chunk = try await receive(maximumBytes: maximum, deadline: deadline)
            } catch {
                if !result.isEmpty, error as? Failure != .timedOut,
                   error as? Failure != .cancelled {
                    throw Failure.protocolFailure
                }
                throw error
            }
            guard !chunk.isEmpty else { throw Failure.closed }
            result.append(chunk)
        }
        return result
    }

    func receive(maximumBytes: Int, deadline: ContinuousClock.Instant) async throws -> Data {
        try await withDeadline(deadline) {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                self.connection.receive(minimumIncompleteLength: 1, maximumLength: maximumBytes) {
                    data, _, complete, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let data, !data.isEmpty { continuation.resume(returning: data) }
                    else if complete { continuation.resume(throwing: Failure.closed) }
                    else { continuation.resume(returning: Data()) }
                }
            }
        }
    }

    private func readExactly(_ count: Int) async throws -> Data {
        guard count >= 0 else { throw Failure.protocolFailure }
        var result = Data()
        while result.count < count {
            let maximum = min(64 * 1_024, count - result.count)
            let chunk: Data
            do {
                chunk = try await receive(maximumBytes: maximum)
            } catch {
                if !result.isEmpty { throw Failure.protocolFailure }
                throw error
            }
            guard !chunk.isEmpty else { throw Failure.closed }
            result.append(chunk)
        }
        return result
    }

    private func receive(maximumBytes: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: maximumBytes) {
                data, _, complete, error in
                if let error { continuation.resume(throwing: error) }
                else if let data, !data.isEmpty { continuation.resume(returning: data) }
                else if complete { continuation.resume(throwing: Failure.closed) }
                else { continuation.resume(returning: Data()) }
            }
        }
    }

    func cancel() {
        connection.cancel()
    }

    func cancelAndWait() async {
        connection.cancel()
        await lifecycle.waitUntilTerminal()
    }

    var hasReachedTerminalState: Bool { lifecycle.hasReachedTerminalState }

    private static func strictHexLength(_ header: Data) -> Int? {
        guard header.count == 4 else { return nil }
        var result = 0
        for byte in header {
            let digit: Int
            switch byte {
            case 48...57: digit = Int(byte - 48)
            case 65...70: digit = Int(byte - 65 + 10)
            case 97...102: digit = Int(byte - 97 + 10)
            default: return nil
            }
            result = result * 16 + digit
        }
        return result
    }

    private func withDeadline<T: Sendable>(
        _ deadline: ContinuousClock.Instant,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: T.self) { group in
                group.addTask { try await operation() }
                group.addTask {
                    let remaining = ContinuousClock.now.duration(to: deadline)
                    if remaining > .zero { try await Task.sleep(for: remaining, tolerance: .zero) }
                    self.cancel()
                    throw Failure.timedOut
                }
                defer { group.cancelAll() }
                guard let value = try await group.next() else { throw Failure.closed }
                return value
            }
        } onCancel: {
            self.cancel()
        }
    }

    private final class Lifecycle: @unchecked Sendable {
        private enum State {
            case waiting
            case ready
            case terminal
        }

        private let lock = NSLock()
        private var state: State = .waiting
        private var readyWaiters: [CheckedContinuation<Void, Error>] = []
        private var terminalWaiters: [CheckedContinuation<Void, Never>] = []

        var hasReachedTerminalState: Bool {
            lock.withLock { if case .terminal = state { true } else { false } }
        }

        func observe(_ connectionState: NWConnection.State) {
            let completions = lock.withLock {
                () -> ([CheckedContinuation<Void, Error>], [CheckedContinuation<Void, Never>], Bool) in
                switch connectionState {
                case .ready:
                    guard case .waiting = state else { return ([], [], false) }
                    state = .ready
                    let ready = readyWaiters
                    readyWaiters.removeAll()
                    return (ready, [], true)
                case .failed, .cancelled:
                    guard case .terminal = state else {
                        state = .terminal
                        let ready = readyWaiters
                        let terminal = terminalWaiters
                        readyWaiters.removeAll()
                        terminalWaiters.removeAll()
                        return (ready, terminal, false)
                    }
                    return ([], [], false)
                default:
                    return ([], [], false)
                }
            }
            if completions.2 {
                completions.0.forEach { $0.resume() }
            } else {
                completions.0.forEach { $0.resume(throwing: Failure.connectionFailed) }
                completions.1.forEach { $0.resume() }
            }
        }

        func waitUntilReady() async throws {
            try await withCheckedThrowingContinuation { continuation in
                let outcome = lock.withLock { () -> State in
                    switch state {
                    case .waiting:
                        readyWaiters.append(continuation)
                        return .waiting
                    case .ready: return .ready
                    case .terminal: return .terminal
                    }
                }
                switch outcome {
                case .waiting: break
                case .ready: continuation.resume()
                case .terminal: continuation.resume(throwing: Failure.connectionFailed)
                }
            }
        }

        func waitUntilTerminal() async {
            await withCheckedContinuation { continuation in
                let shouldResume = lock.withLock { () -> Bool in
                    if case .terminal = state { return true }
                    terminalWaiters.append(continuation)
                    return false
                }
                if shouldResume { continuation.resume() }
            }
        }
    }
}
