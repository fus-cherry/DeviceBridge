@preconcurrency import Foundation

public struct HostCommandRequest: Sendable {
    public let executableURL: URL
    public let arguments: [String]
    public let environment: [String: String]?
    public let timeout: Duration
    public let maximumOutputBytes: Int

    public init(
        executableURL: URL,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        timeout: Duration,
        maximumOutputBytes: Int = 1_048_576
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.timeout = timeout
        self.maximumOutputBytes = maximumOutputBytes
    }
}

public struct HostCommandResult: Sendable, Equatable {
    public let exitCode: Int32
    public let standardOutput: Data
    public let standardError: Data

    public init(exitCode: Int32, standardOutput: Data, standardError: Data) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    public var standardOutputString: String {
        String(decoding: standardOutput, as: UTF8.self)
    }

    public var standardErrorString: String {
        String(decoding: standardError, as: UTF8.self)
    }
}

public enum HostCommandError: Error, Equatable, Sendable {
    case launchFailed
    case timedOut
    case cancelled
    case outputLimitExceeded
}

public protocol HostCommandRunning: Sendable {
    func run(_ request: HostCommandRequest) async throws -> HostCommandResult
}

public struct HostCommandRunner: HostCommandRunning {
    public init() {}

    public func run(_ request: HostCommandRequest) async throws -> HostCommandResult {
        if Task.isCancelled {
            throw HostCommandError.cancelled
        }

        let process = Process()
        let standardOutputPipe = Pipe()
        let standardErrorPipe = Pipe()
        process.executableURL = request.executableURL
        process.arguments = request.arguments
        process.environment = request.environment
        process.standardOutput = standardOutputPipe
        process.standardError = standardErrorPipe

        // Register exit observation before launch: a short-lived command can exit before
        // its first async waiter is scheduled.
        let processBox = ProcessBox(process)
        do {
            try process.run()
        } catch {
            throw HostCommandError.launchFailed
        }

        let stdoutHandle = SendableFileHandle(standardOutputPipe.fileHandleForReading)
        let stderrHandle = SendableFileHandle(standardErrorPipe.fileHandleForReading)
        let outputBudget = CommandOutputBudget(maximum: request.maximumOutputBytes)
        let stdoutTask = Task.detached {
            try stdoutHandle.read(budget: outputBudget, process: processBox)
        }
        let stderrTask = Task.detached {
            try stderrHandle.read(budget: outputBudget, process: processBox)
        }

        do {
            let exitCode = try await withTaskCancellationHandler {
                try await withThrowingTaskGroup(of: Int32.self) { group in
                    group.addTask {
                        await processBox.waitForExit()
                    }
                    group.addTask {
                        try await Task.sleep(for: request.timeout)
                        processBox.terminate()
                        throw HostCommandError.timedOut
                    }

                    defer { group.cancelAll() }
                    guard let first = try await group.next() else {
                        throw HostCommandError.launchFailed
                    }
                    return first
                }
            } onCancel: {
                processBox.terminate()
            }

            let standardOutput = try await stdoutTask.value
            let standardError = try await stderrTask.value
            if outputBudget.exceeded {
                throw HostCommandError.outputLimitExceeded
            }
            if Task.isCancelled {
                throw HostCommandError.cancelled
            }
            return HostCommandResult(
                exitCode: exitCode,
                standardOutput: standardOutput,
                standardError: standardError
            )
        } catch is CancellationError {
            processBox.terminate()
            _ = await processBox.waitForExit()
            throw HostCommandError.cancelled
        } catch {
            processBox.terminate()
            _ = await processBox.waitForExit()
            _ = try? await stdoutTask.value
            _ = try? await stderrTask.value
            if outputBudget.exceeded, !Task.isCancelled { throw HostCommandError.outputLimitExceeded }
            throw error
        }
    }
}

private struct SendableFileHandle: @unchecked Sendable {
    let value: FileHandle

    init(_ value: FileHandle) {
        self.value = value
    }

    func read(budget: CommandOutputBudget, process: ProcessBox) throws -> Data {
        var result = Data()
        while let chunk = try value.read(upToCount: 16 * 1_024), !chunk.isEmpty {
            if budget.reserve(chunk.count) { result.append(chunk) }
            else { process.terminate() }
            // Continue draining after termination without retaining more bytes. Both pipes
            // share one quota, so neither stream can allocate the entire output independently.
        }
        return result
    }
}

private final class CommandOutputBudget: @unchecked Sendable {
    private let lock = NSLock()
    private let maximum: Int
    private var retained = 0
    private var didExceed = false
    init(maximum: Int) { self.maximum = max(0, maximum) }
    var exceeded: Bool { lock.withLock { didExceed } }
    func reserve(_ count: Int) -> Bool {
        lock.withLock {
            guard !didExceed, count <= maximum - retained else { didExceed = true; return false }
            retained += count
            return true
        }
    }
}

private final class ProcessBox: @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    private var exitCode: Int32?
    private var exitWaiters: [CheckedContinuation<Int32, Never>] = []

    init(_ process: Process) {
        self.process = process
        process.terminationHandler = { [weak self] terminated in
            self?.recordExit(terminated.terminationStatus)
        }
    }

    func waitForExit() async -> Int32 {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let exitCode {
                lock.unlock()
                continuation.resume(returning: exitCode)
            } else {
                exitWaiters.append(continuation)
                lock.unlock()
            }
        }
    }

    private func recordExit(_ status: Int32) {
        lock.lock()
        guard exitCode == nil else { lock.unlock(); return }
        exitCode = status
        let waiters = exitWaiters
        exitWaiters.removeAll()
        lock.unlock()
        for waiter in waiters { waiter.resume(returning: status) }
    }

    func terminate() {
        lock.lock()
        defer { lock.unlock() }
        guard process.isRunning else { return }
        process.terminate()
    }
}
