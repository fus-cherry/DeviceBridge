@preconcurrency import Foundation
import Darwin

public struct HostCommandRequest: Sendable {
    public let executableURL: URL
    public let arguments: [String]
    public let environment: [String: String]?
    public let timeout: Duration
    public let maximumOutputBytes: Int
    public let standardInput: Data?

    public init(
        executableURL: URL,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        timeout: Duration,
        maximumOutputBytes: Int = 1_048_576,
        standardInput: Data? = nil
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.timeout = timeout
        self.maximumOutputBytes = maximumOutputBytes
        self.standardInput = standardInput
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
        let deadline = ContinuousClock.now.advanced(by: request.timeout)

        let process = Process()
        let standardOutputPipe = Pipe()
        let standardErrorPipe = Pipe()
        process.executableURL = request.executableURL
        process.arguments = request.arguments
        process.environment = request.environment
        process.standardOutput = standardOutputPipe
        process.standardError = standardErrorPipe
        // A seekable, immediately unlinked input avoids pipe backpressure deadlocks and keeps
        // clipboard text out of argv, shell quoting and named request files. The child owns its
        // descriptor until exit; cancellation uses the same process owner as all other commands.
        let inputHandle: FileHandle?
        if let input = request.standardInput {
            var path = Array(FileManager.default.temporaryDirectory.appendingPathComponent("devicebridge-stdin.XXXXXX").path.utf8CString)
            let descriptor = mkstemp(&path)
            guard descriptor >= 0 else { throw HostCommandError.launchFailed }
            unlink(path)
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            do {
                try handle.write(contentsOf: input)
                try handle.seek(toOffset: 0)
            } catch {
                try? handle.close()
                throw HostCommandError.launchFailed
            }
            inputHandle = handle
            process.standardInput = handle
        } else {
            inputHandle = nil
            process.standardInput = FileHandle.nullDevice
        }
        defer { try? inputHandle?.close() }

        // Register exit observation before launch: a short-lived command can exit before
        // its first async waiter is scheduled.
        let processBox = ProcessBox(process)
        do {
            try process.run()
        } catch {
            try? standardOutputPipe.fileHandleForReading.close()
            try? standardOutputPipe.fileHandleForWriting.close()
            try? standardErrorPipe.fileHandleForReading.close()
            try? standardErrorPipe.fileHandleForWriting.close()
            throw HostCommandError.launchFailed
        }
        // The child owns duplicated write descriptors after launch. Retaining these parent
        // copies would prevent EOF even after the child and all inheritors have exited.
        try? standardOutputPipe.fileHandleForWriting.close()
        try? standardErrorPipe.fileHandleForWriting.close()

        let stdoutHandle = SendableFileHandle(standardOutputPipe.fileHandleForReading)
        let stderrHandle = SendableFileHandle(standardErrorPipe.fileHandleForReading)
        let outputBudget = CommandOutputBudget(maximum: request.maximumOutputBytes)
        let resources = CommandRunResources(process: processBox, handles: [stdoutHandle, stderrHandle])
        let stdoutTask = Task.detached {
            try stdoutHandle.read(budget: outputBudget, resources: resources)
        }
        let stderrTask = Task.detached {
            try stderrHandle.read(budget: outputBudget, resources: resources)
        }

        do {
            let result = try await withTaskCancellationHandler {
                try await withThrowingTaskGroup(of: HostCommandResult.self) { group in
                    group.addTask {
                        let exitCode = await processBox.waitForExit()
                        let standardOutput = try await stdoutTask.value
                        let standardError = try await stderrTask.value
                        if outputBudget.exceeded {
                            throw HostCommandError.outputLimitExceeded
                        }
                        return HostCommandResult(
                            exitCode: exitCode,
                            standardOutput: standardOutput,
                            standardError: standardError
                        )
                    }
                    group.addTask {
                        let remaining = ContinuousClock.now.duration(to: deadline)
                        if remaining > .zero {
                            try await Task.sleep(for: remaining)
                        }
                        resources.reachDeadline()
                        throw HostCommandError.timedOut
                    }

                    defer { group.cancelAll() }
                    guard let first = try await group.next() else {
                        throw HostCommandError.launchFailed
                    }
                    if Task.isCancelled {
                        resources.requestStop()
                        throw HostCommandError.cancelled
                    }
                    if outputBudget.exceeded {
                        throw HostCommandError.outputLimitExceeded
                    }
                    if resources.deadlineReached {
                        throw HostCommandError.timedOut
                    }
                    return first
                }
            } onCancel: {
                resources.requestStop()
            }
            if Task.isCancelled {
                throw HostCommandError.cancelled
            }
            resources.closeHandles()
            return result
        } catch {
            resources.requestStop()
            _ = await processBox.waitForExit()
            _ = try? await stdoutTask.value
            _ = try? await stderrTask.value
            resources.closeHandles()
            if Task.isCancelled || error is CancellationError { throw HostCommandError.cancelled }
            if outputBudget.exceeded { throw HostCommandError.outputLimitExceeded }
            if resources.deadlineReached { throw HostCommandError.timedOut }
            throw error
        }
    }
}

private final class SendableFileHandle: @unchecked Sendable {
    let value: FileHandle

    init(_ value: FileHandle) {
        self.value = value
    }

    func read(budget: CommandOutputBudget, resources: CommandRunResources) throws -> Data {
        let descriptor = value.fileDescriptor
        let originalFlags = Darwin.fcntl(descriptor, F_GETFL)
        guard originalFlags >= 0,
              Darwin.fcntl(descriptor, F_SETFL, originalFlags | O_NONBLOCK) >= 0 else {
            resources.requestStop()
            throw HostCommandError.launchFailed
        }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1_024)

        while !resources.isStopping {
            var pollDescriptor = pollfd(
                fd: descriptor,
                events: Int16(POLLIN | POLLHUP),
                revents: 0
            )
            let pollResult = Darwin.poll(&pollDescriptor, 1, 20)
            if pollResult == 0 { continue }
            if pollResult < 0 {
                if errno == EINTR { continue }
                resources.requestStop()
                throw HostCommandError.launchFailed
            }
            if pollDescriptor.revents & Int16(POLLIN | POLLHUP) != 0 {
                let count = buffer.withUnsafeMutableBytes { bytes in
                    Darwin.read(descriptor, bytes.baseAddress, bytes.count)
                }
                if count > 0 {
                    guard budget.reserve(count) else {
                        resources.requestStop()
                        return result
                    }
                    result.append(contentsOf: buffer.prefix(count))
                    continue
                }
                if count == 0 { return result }
                if errno == EINTR || errno == EAGAIN { continue }
                resources.requestStop()
                throw HostCommandError.launchFailed
            }
            if pollDescriptor.revents & Int16(POLLERR | POLLNVAL) != 0 {
                resources.requestStop()
                throw HostCommandError.launchFailed
            }
        }
        return result
    }

    func close() {
        try? value.close()
    }
}

private final class CommandRunResources: @unchecked Sendable {
    private let process: ProcessBox
    private let handles: [SendableFileHandle]
    private let lock = NSLock()
    private var stopping = false
    private var reachedDeadline = false

    init(process: ProcessBox, handles: [SendableFileHandle]) {
        self.process = process
        self.handles = handles
    }

    var isStopping: Bool { lock.withLock { stopping } }
    var deadlineReached: Bool { lock.withLock { reachedDeadline } }

    func reachDeadline() {
        lock.withLock { reachedDeadline = true }
        requestStop()
    }

    func requestStop() {
        let shouldTerminate = lock.withLock {
            guard !stopping else { return false }
            stopping = true
            return true
        }
        if shouldTerminate {
            process.terminateAfterGrace()
        }
    }

    func closeHandles() {
        for handle in handles { handle.close() }
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
    private static let terminationGrace = DispatchTimeInterval.milliseconds(200)
    private let process: Process
    private let lock = NSLock()
    private var exitCode: Int32?
    private var exitWaiters: [CheckedContinuation<Int32, Never>] = []
    private var terminationRequested = false

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

    func terminateAfterGrace() {
        let ownedProcessID: pid_t? = lock.withLock {
            guard exitCode == nil, process.isRunning, !terminationRequested else { return nil }
            terminationRequested = true
            return process.processIdentifier
        }
        guard let ownedProcessID else { return }
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.terminationGrace) { [weak self] in
            self?.forceTerminateIfStillOwned(ownedProcessID)
        }
    }

    private func forceTerminateIfStillOwned(_ ownedProcessID: pid_t) {
        let shouldTerminate = lock.withLock {
            exitCode == nil
                && process.isRunning
                && process.processIdentifier == ownedProcessID
        }
        if shouldTerminate {
            _ = Darwin.kill(ownedProcessID, SIGKILL)
        }
    }
}
