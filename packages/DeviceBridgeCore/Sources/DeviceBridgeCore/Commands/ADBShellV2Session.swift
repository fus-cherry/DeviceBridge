import Foundation

public enum ADBShellNotStartedReason: Sendable, Equatable {
    case invalidCommand
    case busy
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

public enum ADBShellTermination: Sendable, Equatable {
    case remoteExit
    case outputLimitExceeded
    case resultUnknown
    case protocolFailure
    case timedOut
    case cancelled
    case notStarted(ADBShellNotStartedReason)
}

public struct ADBShellV2Result: Sendable, Equatable {
    public let standardOutput: Data
    public let standardError: Data
    public let exitCode: Int?
    public let termination: ADBShellTermination
    public let outputTruncated: Bool

    public init(
        standardOutput: Data = Data(),
        standardError: Data = Data(),
        exitCode: Int? = nil,
        termination: ADBShellTermination,
        outputTruncated: Bool = false
    ) {
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.exitCode = exitCode
        self.termination = termination
        self.outputTruncated = outputTruncated
    }
}

/// Serializes raw, non-interactive Shell-v2 commands for one captured route and
/// one observed ADB server lifetime. Each run owns a fresh execution socket.
public actor ADBShellV2Session {
    private static let maximumCommandBytes = 16 * 1_024
    private static let maximumFrameBytes = 1_048_576
    private static let maximumOutputBytes = 1_048_576
    private static let maximumReadBytes = 64 * 1_024
    private static let maximumDuration: Duration = .seconds(30)
    private static let closeStdinFrame = Data([4, 0, 0, 0, 0])

    private struct ActiveRun {
        let id: UUID
        let resources: ADBExecutionResources
        var cancellationAccepted: Bool
    }

    private struct OutputAccumulator {
        var standardOutput = Data()
        var standardError = Data()

        var retainedByteCount: Int {
            standardOutput.count + standardError.count
        }

        mutating func append(_ bytes: Data, streamID: UInt8) -> Bool {
            let available = max(0, ADBShellV2Session.maximumOutputBytes - retainedByteCount)
            if available > 0 {
                let retained = bytes.prefix(available)
                if streamID == 1 {
                    standardOutput.append(contentsOf: retained)
                } else {
                    standardError.append(contentsOf: retained)
                }
            }
            return bytes.count > available
        }
    }

    private let server: ADBServerConnection
    private let epoch: ADBServerEpoch
    private let route: ADBCapturedRoute
    private var activeRun: ActiveRun?

    public init(server: ADBServerConnection, epoch: ADBServerEpoch, route: ADBCapturedRoute) {
        self.server = server
        self.epoch = epoch
        self.route = route
    }

    public func run(
        command: String,
        deadline requestedDeadline: ContinuousClock.Instant,
        validateSession: @escaping @Sendable () async -> Bool
    ) async -> ADBShellV2Result {
        guard Self.isValid(command) else {
            return ADBShellV2Result(termination: .notStarted(.invalidCommand))
        }
        guard activeRun == nil else {
            return ADBShellV2Result(termination: .notStarted(.busy))
        }

        let now = ContinuousClock.now
        let deadline = min(requestedDeadline, now.advanced(by: Self.maximumDuration))
        guard deadline > now else {
            return ADBShellV2Result(termination: .notStarted(.timedOut))
        }

        let id = UUID()
        let resources = ADBExecutionResources()
        activeRun = ActiveRun(id: id, resources: resources, cancellationAccepted: false)

        var closeStdinTask: Task<Void, Error>?
        let result = await withTaskCancellationHandler {
            await execute(
                command: command,
                deadline: deadline,
                validateSession: validateSession,
                runID: id,
                resources: resources,
                closeStdinTask: &closeStdinTask
            )
        } onCancel: {
            resources.cancel()
        }

        if let closeStdinTask {
            _ = await closeStdinTask.result
        }
        resources.cancel()
        await resources.drain()
        await server.finishExecution(resources)
        if activeRun?.id == id {
            activeRun = nil
        }
        return result
    }

    public func cancel() {
        guard var run = activeRun else { return }
        run.cancellationAccepted = true
        activeRun = run
        run.resources.cancel()
    }

    private func execute(
        command: String,
        deadline: ContinuousClock.Instant,
        validateSession: @escaping @Sendable () async -> Bool,
        runID: UUID,
        resources: ADBExecutionResources,
        closeStdinTask: inout Task<Void, Error>?
    ) async -> ADBShellV2Result {
        let socket: ADBClientSocket
        do {
            socket = try await server.openExecution(
                route: route,
                epoch: epoch,
                resources: resources,
                deadline: deadline,
                validateSession: validateSession
            )
            guard await server.isCurrent(epoch) else {
                return notStarted(.epochInvalidated)
            }
            guard await validateSession() else {
                return notStarted(.staleSession)
            }
            try Task.checkCancellation()
            guard !wasCancellationAccepted(for: runID) else {
                return notStarted(.cancelled)
            }
        } catch {
            return resultBeforeSubmission(for: error, runID: runID)
        }

        // Once this write begins, the remote execution state is conservatively unknown
        // until a valid Shell-v2 exit frame proves the result.
        do {
            try await socket.sendSmartRequest("shell,v2,raw:\(command)", deadline: deadline)
            try await socket.readOkay(deadline: deadline)
        } catch {
            return resultAfterSubmission(for: error, runID: runID)
        }

        closeStdinTask = Task {
            try await socket.write(Self.closeStdinFrame, deadline: deadline)
        }

        return await readResult(from: socket, deadline: deadline, runID: runID)
    }

    private func readResult(
        from socket: ADBClientSocket,
        deadline: ContinuousClock.Instant,
        runID: UUID
    ) async -> ADBShellV2Result {
        var output = OutputAccumulator()
        do {
            while true {
                let header = try await socket.readExactly(5, deadline: deadline)
                if wasCancellationAccepted(for: runID) || Task.isCancelled {
                    return result(output: output, termination: .cancelled, truncated: true)
                }
                let streamID = header[header.startIndex]
                let length = header.dropFirst().enumerated().reduce(UInt32(0)) { partial, element in
                    partial | (UInt32(element.element) << UInt32(element.offset * 8))
                }
                guard length <= Self.maximumFrameBytes else {
                    return result(output: output, termination: .protocolFailure, truncated: true)
                }

                switch streamID {
                case 1, 2:
                    var remaining = Int(length)
                    while remaining > 0 {
                        let outputRemaining = Self.maximumOutputBytes - output.retainedByteCount
                        let count = min(Self.maximumReadBytes, remaining, outputRemaining + 1)
                        let chunk = try await readFramePayload(count, from: socket, deadline: deadline)
                        if wasCancellationAccepted(for: runID) || Task.isCancelled {
                            return result(output: output, termination: .cancelled, truncated: true)
                        }
                        remaining -= chunk.count
                        if output.append(chunk, streamID: streamID) {
                            return result(output: output, termination: .outputLimitExceeded, truncated: true)
                        }
                    }
                case 3:
                    guard length == 1 else {
                        return result(output: output, termination: .protocolFailure, truncated: true)
                    }
                    let payload = try await readFramePayload(1, from: socket, deadline: deadline)
                    if wasCancellationAccepted(for: runID) || Task.isCancelled {
                        return result(output: output, termination: .cancelled, truncated: true)
                    }
                    return ADBShellV2Result(
                        standardOutput: output.standardOutput,
                        standardError: output.standardError,
                        exitCode: Int(payload[payload.startIndex]),
                        termination: .remoteExit
                    )
                default:
                    return result(output: output, termination: .protocolFailure, truncated: true)
                }
            }
        } catch {
            if wasCancellationAccepted(for: runID) || Task.isCancelled {
                return result(output: output, termination: .cancelled, truncated: true)
            }
            if Self.isTimeout(error) || ContinuousClock.now >= deadline {
                return result(output: output, termination: .timedOut, truncated: true)
            }
            if !(await server.isCurrent(epoch)) {
                return result(output: output, termination: .resultUnknown, truncated: true)
            }
            if Self.isProtocolFailure(error) {
                return result(output: output, termination: .protocolFailure, truncated: true)
            }
            return result(output: output, termination: .resultUnknown, truncated: true)
        }
    }

    private func resultBeforeSubmission(for error: any Error, runID: UUID) -> ADBShellV2Result {
        if wasCancellationAccepted(for: runID) || Task.isCancelled {
            return notStarted(.cancelled)
        }
        let reason: ADBShellNotStartedReason
        switch error as? ADBServerConnectionError {
        case .connectionFailed: reason = .connectionFailed
        case .timedOut: reason = .timedOut
        case .cancelled: reason = .cancelled
        case .protocolFailure: reason = .protocolFailure
        case .serviceRejected: reason = .serviceRejected
        case .shellV2Unavailable: reason = .shellV2Unavailable
        case .routeMismatch: reason = .routeMismatch
        case .identityMismatch: reason = .identityMismatch
        case .staleSession: reason = .staleSession
        case .epochInvalidated: reason = .epochInvalidated
        case .invalidEndpoint, .invalidRoute, .none: reason = .protocolFailure
        }
        return notStarted(reason)
    }

    private func resultAfterSubmission(for error: any Error, runID: UUID) -> ADBShellV2Result {
        if wasCancellationAccepted(for: runID) || Task.isCancelled {
            return ADBShellV2Result(termination: .cancelled, outputTruncated: true)
        }
        if Self.isTimeout(error) {
            return ADBShellV2Result(termination: .timedOut, outputTruncated: true)
        }
        if Self.isProtocolFailure(error) {
            return ADBShellV2Result(termination: .protocolFailure, outputTruncated: true)
        }
        return ADBShellV2Result(termination: .resultUnknown, outputTruncated: true)
    }

    private func wasCancellationAccepted(for runID: UUID) -> Bool {
        activeRun?.id == runID && activeRun?.cancellationAccepted == true
    }

    private func readFramePayload(
        _ count: Int,
        from socket: ADBClientSocket,
        deadline: ContinuousClock.Instant
    ) async throws -> Data {
        do {
            return try await socket.readExactly(count, deadline: deadline)
        } catch {
            if Self.isTimeout(error) || error is CancellationError {
                throw error
            }
            throw ADBClientSocket.Failure.protocolFailure
        }
    }

    private func notStarted(_ reason: ADBShellNotStartedReason) -> ADBShellV2Result {
        ADBShellV2Result(termination: .notStarted(reason))
    }

    private func result(
        output: OutputAccumulator,
        termination: ADBShellTermination,
        truncated: Bool
    ) -> ADBShellV2Result {
        ADBShellV2Result(
            standardOutput: output.standardOutput,
            standardError: output.standardError,
            termination: termination,
            outputTruncated: truncated
        )
    }

    private static func isValid(_ command: String) -> Bool {
        !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && command.utf8.count <= maximumCommandBytes
            && !command.utf8.contains(0)
    }

    private static func isTimeout(_ error: any Error) -> Bool {
        error as? ADBServerConnectionError == .timedOut
            || error as? ADBClientSocket.Failure == .timedOut
    }

    private static func isProtocolFailure(_ error: any Error) -> Bool {
        error as? ADBServerConnectionError == .protocolFailure
            || error as? ADBClientSocket.Failure == .protocolFailure
    }
}
