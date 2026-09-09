import Foundation

public enum AndroidShellInput {
    public static let maximumBytes = 16 * 1_024
    public static func validate(_ command: String) -> OperationFailure? {
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return OperationFailure(code: .failure, safeMessage: "Enter a command before running.")
        }
        guard command.utf8.count <= maximumBytes, !command.utf8.contains(0) else {
            return OperationFailure(code: .failure, safeMessage: "Commands must be at most 16 KiB and cannot contain NUL.")
        }
        return nil
    }
}

public enum AndroidShellCompletion: Codable, Equatable, Sendable {
    case remoteExit(Int), cancelled, timedOut, outputLimitExceeded, connectionLost, resultUnknown, protocolFailure
    case notStarted(OperationFailure)

    public var exitCode: Int? { if case let .remoteExit(code) = self { return code }; return nil }
    public var statusText: String {
        switch self {
        case .remoteExit: "Completed"
        case .cancelled: "Cancelled"
        case .timedOut: "Timed out"
        case .outputLimitExceeded: "Output limit reached"
        case .connectionLost: "Connection lost"
        case .resultUnknown: "Result unknown"
        case .protocolFailure: "Invalid Shell response"
        case .notStarted: "Not started"
        }
    }
}

public struct AndroidShellExecution: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let origin: DeviceOperationOrigin
    public let session: ConnectionSession
    public let command: String
    public let startedAt: Date
    public let finishedAt: Date
    public let stdout: Data
    public let stderr: Data
    public let completion: AndroidShellCompletion
    public let outputTruncated: Bool
    public var exitCode: Int? { completion.exitCode }
    public var retainedByteCount: Int { command.utf8.count + stdout.count + stderr.count }

    public init(id: UUID, origin: DeviceOperationOrigin, session: ConnectionSession, command: String,
                startedAt: Date, finishedAt: Date, stdout: Data, stderr: Data,
                completion: AndroidShellCompletion, outputTruncated: Bool = false) {
        self.id = id; self.origin = origin; self.session = session; self.command = command
        self.startedAt = startedAt; self.finishedAt = finishedAt
        self.stdout = stdout; self.stderr = stderr; self.completion = completion
        self.outputTruncated = outputTruncated
    }
}

public enum AndroidShellOutcome: Sendable, Equatable {
    case execution(AndroidShellExecution), stale
}

public protocol AndroidShellExecuting: Sendable {
    func run(command: String, session: ConnectionSession, operationID: UUID,
             origin: DeviceOperationOrigin, startedAt: Date, deadline: ContinuousClock.Instant) async -> AndroidShellOutcome
}
