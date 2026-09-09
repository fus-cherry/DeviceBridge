import Foundation

protocol IOSRunnerForegroundActivating: Sendable {
    func activate(launch: IOSRunnerLaunch, deadline: ContinuousClock.Instant) async throws
}

/// Captures the activation's absolute deadline across the async command-executor hop.
struct IOSRunnerForegroundProcessRunner: HostCommandRunning {
    let deadline: ContinuousClock.Instant
    private let start: @Sendable (IOSRunnerProcessRequest) throws -> IOSRunnerProcess

    init(deadline: ContinuousClock.Instant,
         start: @escaping @Sendable (IOSRunnerProcessRequest) throws -> IOSRunnerProcess = { request in
             try IOSRunnerProcess.start(executableURL: request.executableURL, arguments: request.arguments,
                 environment: request.environment, lifetime: request.maximumLifetime)
         }) {
        self.deadline = deadline
        self.start = start
    }

    func run(_ request: HostCommandRequest) async throws -> HostCommandResult {
        let allowed = ["PATH", "HOME", "TMPDIR", "DEVELOPER_DIR", "LANG", "LC_ALL"]
        let environment = ProcessInfo.processInfo.environment.filter { allowed.contains($0.key) }
        // This check runs after the async executor hop. Nothing suspends between here and
        // the synchronous native start, so queued work cannot reuse an old relative lifetime.
        try Task.checkCancellation()
        let remaining = ContinuousClock.now.duration(to: deadline)
        guard remaining > .zero else { throw HostCommandError.timedOut }
        let process = try start(IOSRunnerProcessRequest(executableURL: request.executableURL,
            arguments: request.arguments, environment: environment, maximumLifetime: min(request.timeout, remaining)))
        let exit = await withTaskCancellationHandler {
            await process.waitForExit()
        } onCancel: { Task { await process.stop() } }
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw HostCommandError.timedOut }
        guard case let .exited(code) = exit else { throw HostCommandError.timedOut }
        return HostCommandResult(exitCode: code, standardOutput: Data(), standardError: Data())
    }
}

/// Exit-only CoreDevice activation. The channel must recheck launch/process/session ownership
/// around this call; activating an app does not authenticate a channel or prove content readiness.
struct IOSRunnerForegroundActivator: IOSRunnerForegroundActivating {
    enum Failure: Error, Equatable, Sendable { case invalidInput, timedOut, cancelled, activationFailed }
    private let xcrunURL: URL
    private let commands: (any HostCommandRunning)?

    init(xcrunURL: URL, commands: (any HostCommandRunning)? = nil) {
        self.xcrunURL = xcrunURL
        self.commands = commands
    }

    func activate(launch: IOSRunnerLaunch, deadline: ContinuousClock.Instant) async throws {
        let activationDeadline = min(deadline, ContinuousClock.now.advanced(by: .seconds(8)))
        try Self.check(deadline: activationDeadline)
        guard xcrunURL.isFileURL, Self.isHardwareIdentifier(launch.deviceIdentifier) else { throw Failure.invalidInput }
        do {
            try Self.check(deadline: activationDeadline)
            let remaining = ContinuousClock.now.duration(to: activationDeadline)
            guard remaining > .zero else { throw Failure.timedOut }
            let seconds = Double(remaining.components.seconds) + Double(remaining.components.attoseconds) / 1e18
            // CoreDevice parses integer seconds only. Round its advisory timer up; the native
            // owner still enforces the original absolute deadline, including subsecond budgets.
            let toolSeconds = Int(ceil(min(5, seconds)))
            let executor: any HostCommandRunning = commands ?? IOSRunnerForegroundProcessRunner(deadline: activationDeadline)
            let result = try await executor.run(HostCommandRequest(executableURL: xcrunURL,
                arguments: ["devicectl", "device", "process", "launch", "--device", launch.deviceIdentifier,
                    "--activate", "--timeout", String(toolSeconds), IOSRunnerCodeRole.runner.bundleIdentifier],
                environment: [:], timeout: remaining, maximumOutputBytes: 0))
            try Self.check(deadline: activationDeadline)
            guard result.exitCode == 0 else { throw Failure.activationFailed }
        } catch {
            if Task.isCancelled || error is CancellationError || error as? HostCommandError == .cancelled { throw Failure.cancelled }
            if ContinuousClock.now >= activationDeadline || error as? HostCommandError == .timedOut { throw Failure.timedOut }
            throw (error as? Failure) ?? Failure.activationFailed
        }
    }

    private static func check(deadline: ContinuousClock.Instant) throws {
        guard !Task.isCancelled else { throw Failure.cancelled }
        guard ContinuousClock.now < deadline else { throw Failure.timedOut }
    }

    private static func isHardwareIdentifier(_ value: String) -> Bool {
        let count = value.utf8.count
        guard count == 24 || count == 25 || count == 40 else { return false }
        return value.utf8.enumerated().allSatisfy { index, byte in
            if count == 25 && index == 8 { return byte == 45 }
            return (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
        }
    }
}
