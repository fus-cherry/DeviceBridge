import DeviceBridgeCore
import Foundation

/// One committed route and one observed server lifetime, shared by information and Shell.
struct AndroidDeviceCommandBinding: Sendable {
    let id: UUID
    let session: ConnectionSession
    let server: ADBServerConnection
    let epoch: ADBServerEpoch
    let route: ADBCapturedRoute

    func isCurrent(in store: DeviceSessionStore) async -> Bool {
        guard await server.isCurrent(epoch) else { return false }
        let snapshot = await store.snapshot()
        guard snapshot.session == session,
              let device = snapshot.devices.first(where: { $0.identity == session.deviceIdentity }),
              device.authorization == .authorized,
              let candidate = device.candidates.first(where: { $0.id == session.transportID }),
              candidate.metadata["adbSerial"] == route.adbSerial,
              snapshot.devices.flatMap(\.candidates).filter({ $0.metadata["adbSerial"] == route.adbSerial }).count == 1 else { return false }
        let current = await server.isCurrent(epoch)
        return current
    }
    func makeExecutor() -> any AndroidShellCommandExecuting {
        NativeAndroidShellExecutor(shell: ADBShellV2Session(server: server, epoch: epoch, route: route))
    }
}

private struct NativeAndroidShellExecutor: AndroidShellCommandExecuting {
    let shell: ADBShellV2Session
    func run(command: String, deadline: ContinuousClock.Instant,
             validateSession: @escaping @Sendable () async -> Bool) async -> AndroidShellCommandResult {
        let result = await shell.run(command: command, deadline: deadline, validateSession: validateSession)
        let completion: AndroidShellCompletion
        switch result.termination {
        case .remoteExit:
            if let exit = result.exitCode, (0...255).contains(exit) { completion = .remoteExit(exit) }
            else { completion = .protocolFailure }
        case .cancelled: completion = .cancelled
        case .timedOut: completion = .timedOut
        case .outputLimitExceeded: completion = .outputLimitExceeded
        case .resultUnknown: completion = .resultUnknown
        case .protocolFailure: completion = .protocolFailure
        case let .notStarted(reason): completion = .notStarted(Self.failure(reason))
        }
        return AndroidShellCommandResult(stdout: result.standardOutput, stderr: result.standardError,
            completion: completion, outputTruncated: result.outputTruncated)
    }
    func cancel() async { await shell.cancel() }

    private static func failure(_ reason: ADBShellNotStartedReason) -> OperationFailure {
        switch reason {
        case .cancelled: return OperationFailure(code: .cancelled, safeMessage: "Shell execution cancelled.")
        case .timedOut: return OperationFailure(code: .timeout, safeMessage: "Shell preparation timed out.")
        case .invalidCommand: return OperationFailure(code: .failure, safeMessage: "The Shell command is invalid.")
        case .busy: return OperationFailure(code: .failure, safeMessage: "Android Shell is running or cleaning up.")
        case .shellV2Unavailable: return OperationFailure(code: .unsupported, safeMessage: "This Android connection does not support Shell v2.")
        case .protocolFailure: return OperationFailure(code: .malformedOutput, safeMessage: "The Android connection returned an invalid response.")
        case .identityMismatch, .routeMismatch, .staleSession, .epochInvalidated:
            return OperationFailure(code: .disconnected, safeMessage: "The Android connection changed. Select the device again.")
        case .connectionFailed, .serviceRejected:
            return OperationFailure(code: .disconnected, safeMessage: "The Android connection could not start this operation.")
        }
    }
}

struct NativeAndroidInformationCommands: AndroidDeviceInformationCommandRunning {
    let binding: AndroidDeviceCommandBinding
    let store: DeviceSessionStore

    func run(arguments: [String], deadline: ContinuousClock.Instant,
             validateSession: @escaping @Sendable () async throws -> Void) async throws -> HostCommandResult {
        try await validateSession()
        guard await binding.isCurrent(in: store) else { throw DeviceSessionStoreError.staleSession }
        let executor = binding.makeExecutor()
        // Only the provider's fixed argv uses quoting. User Shell text takes the direct raw command path.
        let command = arguments.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
        let result = await executor.run(command: command, deadline: deadline) {
            do {
                try await validateSession()
                return await binding.isCurrent(in: store)
            } catch { return false }
        }
        try await validateSession()
        guard await binding.isCurrent(in: store) else { throw DeviceSessionStoreError.staleSession }
        guard result.stdout.count + result.stderr.count <= 1_048_576 else { throw HostCommandError.outputLimitExceeded }
        switch result.completion {
        case let .remoteExit(code):
            return HostCommandResult(exitCode: Int32(code), standardOutput: result.stdout, standardError: result.stderr)
        case .cancelled: throw CancellationError()
        case .timedOut: throw HostCommandError.timedOut
        case .outputLimitExceeded: throw HostCommandError.outputLimitExceeded
        case let .notStarted(failure): throw failure
        default: throw OperationFailure(code: .malformedOutput, safeMessage: "The Android information query did not return a confirmed result.")
        }
    }
}
