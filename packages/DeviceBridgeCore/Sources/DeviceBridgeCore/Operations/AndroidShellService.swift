import Foundation

/// A cleaned native execution result. This boundary never interprets stderr as transport status.
public struct AndroidShellCommandResult: Sendable, Equatable {
    public let stdout: Data
    public let stderr: Data
    public let completion: AndroidShellCompletion
    public let outputTruncated: Bool

    public init(stdout: Data, stderr: Data, completion: AndroidShellCompletion, outputTruncated: Bool = false) {
        self.stdout = stdout; self.stderr = stderr
        self.completion = completion; self.outputTruncated = outputTruncated
    }
}

/// One native execution, created for a fixed server epoch and route. `run` returns only after
/// all of its sockets and read/write tasks close; `cancel` never launches or retries a command.
public protocol AndroidShellCommandExecuting: Sendable {
    func run(command: String, deadline: ContinuousClock.Instant,
             validateSession: @escaping @Sendable () async -> Bool) async -> AndroidShellCommandResult
    func cancel() async
}

/// Coordinates one in-flight native execution with the authoritative Store resource lease.
/// The returned result is a candidate; the Workspace still owns history and UI publication.
public actor AndroidShellService: AndroidShellExecuting {
    private enum Phase {
        case admitting
        case admissionCancelled
        case admitted(SessionToken)
        case running(SessionToken, any AndroidShellCommandExecuting)
        case draining(Task<Void, Never>)
        case finishing
    }
    private struct ActiveRun {
        // Distinguishes late cancellation delivery even if a caller reuses an operation ID.
        let invocationID: UUID
        var phase: Phase
    }
    private let store: DeviceSessionStore
    private let makeExecutor: @Sendable () -> any AndroidShellCommandExecuting
    private let bindingIsCurrent: @Sendable (ConnectionSession) async -> Bool
    private let timeout: Duration
    private var active: ActiveRun?

    public init(store: DeviceSessionStore,
                makeExecutor: @escaping @Sendable () -> any AndroidShellCommandExecuting,
                bindingIsCurrent: @escaping @Sendable (ConnectionSession) async -> Bool,
                timeout: Duration = .seconds(30)) {
        self.store = store; self.makeExecutor = makeExecutor
        self.bindingIsCurrent = bindingIsCurrent
        self.timeout = min(.seconds(30), max(.zero, timeout))
    }

    public func run(command: String, session: ConnectionSession, operationID: UUID,
                    origin: DeviceOperationOrigin, startedAt: Date,
                    deadline requestedDeadline: ContinuousClock.Instant) async -> AndroidShellOutcome {
        func rejected(_ completion: AndroidShellCompletion) -> AndroidShellOutcome {
            .execution(AndroidShellExecution(id: operationID, origin: origin, session: session, command: command,
                startedAt: startedAt, finishedAt: Date(), stdout: Data(), stderr: Data(), completion: completion))
        }
        if let failure = AndroidShellInput.validate(command) { return rejected(.notStarted(failure)) }
        guard session.deviceIdentity.platform == .android else {
            return rejected(.notStarted(OperationFailure(code: .unsupported,
                safeMessage: "Shell is available only for Android devices.")))
        }
        guard active == nil else { return rejected(.notStarted(Self.busyFailure)) }
        let deadline = min(requestedDeadline, ContinuousClock.now.advanced(by: timeout))
        let invocationID = UUID()
        active = ActiveRun(invocationID: invocationID, phase: .admitting)
        defer { active = nil }
        return await withTaskCancellationHandler {
            await perform(command: command, session: session, operationID: operationID, origin: origin,
                startedAt: startedAt, deadline: deadline, invocationID: invocationID)
        } onCancel: {
            Task { await self.requestCancellation(invocationID: invocationID) }
        }
    }

    private func perform(command: String, session: ConnectionSession, operationID: UUID,
                         origin: DeviceOperationOrigin, startedAt: Date, deadline: ContinuousClock.Instant,
                         invocationID: UUID) async -> AndroidShellOutcome {
        let token: SessionToken
        do {
            token = try await store.beginOperation(.androidShell, id: operationID, expectedSession: session)
        } catch DeviceSessionStoreError.connectionBusy {
            return .execution(AndroidShellExecution(id: operationID, origin: origin, session: session,
                command: command, startedAt: startedAt, finishedAt: Date(), stdout: Data(), stderr: Data(),
                completion: .notStarted(Self.busyFailure)))
        } catch {
            return .stale
        }

        let admissionWasCancelled: Bool
        if case .admissionCancelled = active?.phase { admissionWasCancelled = true }
        else { admissionWasCancelled = Task.isCancelled }
        active?.phase = .admitted(token)
        if admissionWasCancelled { requestCancellation(invocationID: invocationID) }

        var result: AndroidShellCommandResult
        if case .draining = active?.phase {
            result = Self.emptyResult(.cancelled)
        } else if ContinuousClock.now >= deadline {
            result = Self.emptyResult(.timedOut)
        } else {
            let bindingMatches = await bindingIsCurrent(session)
            let tokenIsActive = await store.canPublish(token)
            if Task.isCancelled { requestCancellation(invocationID: invocationID) }
            if case .draining = active?.phase {
                result = Self.emptyResult(.cancelled)
            } else if !bindingMatches || !tokenIsActive {
                active?.phase = .finishing
                await store.invalidateOperation(token, reason: .sessionInvalidated)
                _ = await store.finishShellOperation(token, terminal: .failure)
                return .stale
            } else if ContinuousClock.now >= deadline {
                result = Self.emptyResult(.timedOut)
            } else {
                let executor = makeExecutor()
                active?.phase = .running(token, executor)
                let store = store, bindingIsCurrent = bindingIsCurrent
                result = await executor.run(command: command, deadline: deadline) {
                    guard await store.canPublish(token), await bindingIsCurrent(session) else { return false }
                    return await store.canPublish(token)
                }
                // Cancellation may have arrived before its actor notification was scheduled.
                if Task.isCancelled { requestCancellation(invocationID: invocationID) }
            }
        }

        if case let .draining(cleanup) = active?.phase {
            // A cancel request can itself await physical cleanup. Neither its completion nor
            // native run's completion alone is permission to release the Store lease.
            await cleanup.value
            result = AndroidShellCommandResult(stdout: result.stdout, stderr: result.stderr,
                completion: .cancelled, outputTruncated: result.outputTruncated)
        }
        active?.phase = .finishing
        if result.completion == .timedOut { await store.invalidateOperation(token, reason: .timedOut) }
        else if result.completion == .cancelled { await store.invalidateOperation(token, reason: .cancelled) }

        let bindingMatches = await bindingIsCurrent(session)
        if !bindingMatches { await store.invalidateOperation(token, reason: .sessionInvalidated) }
        let eligible = await store.finishShellOperation(token, terminal: Self.storeTerminal(result.completion))
        guard bindingMatches, eligible, await bindingIsCurrent(session) else { return .stale }
        return .execution(AndroidShellExecution(id: operationID, origin: origin, session: session,
            command: command, startedAt: startedAt, finishedAt: Date(), stdout: result.stdout, stderr: result.stderr,
            completion: result.completion, outputTruncated: result.outputTruncated))
    }

    private func requestCancellation(invocationID: UUID) {
        guard active?.invocationID == invocationID else { return }
        switch active?.phase {
        case .admitting: active?.phase = .admissionCancelled
        case let .admitted(token):
            let store = store
            active?.phase = .draining(Task {
                await store.invalidateOperation(token, reason: .cancelled)
            })
        case let .running(token, executor):
            let store = store
            active?.phase = .draining(Task {
                await store.invalidateOperation(token, reason: .cancelled)
                await executor.cancel()
            })
        default: break
        }
    }

    private static var busyFailure: OperationFailure {
        OperationFailure(code: .failure, safeMessage: "Another operation is using the device connection. Try again after it finishes.")
    }
    private static func emptyResult(_ completion: AndroidShellCompletion) -> AndroidShellCommandResult {
        AndroidShellCommandResult(stdout: Data(), stderr: Data(), completion: completion)
    }
    private static func storeTerminal(_ completion: AndroidShellCompletion) -> ShellOperationTerminal {
        switch completion {
        case .remoteExit: .remoteExit
        case .cancelled: .cancelled
        case .timedOut: .timedOut
        default: .failure
        }
    }
}
