import Foundation
import Testing
@testable import DeviceBridgeCore

struct IOSRunnerForegroundActivatorTests {
    private let xcrun = URL(fileURLWithPath: "/public-fixture/Xcode/usr/bin/xcrun")
    private let identifier = "ABCDEF01-23456789ABCDEF01"

    @Test("executor entered after the absolute deadline never reaches synchronous spawn")
    func lateExecutorDoesNotSpawn() async {
        let spawn = ForegroundSpawnSpy()
        let runner = IOSRunnerForegroundProcessRunner(deadline: .now.advanced(by: .seconds(-1)), start: spawn.start)
        await #expect(throws: HostCommandError.timedOut) {
            try await runner.run(HostCommandRequest(executableURL: xcrun, timeout: .seconds(8)))
        }
        let didNotSpawn = spawn.request == nil
        #expect(didNotSpawn)
    }

    @Test("executor recomputes remaining lifetime and inherits only the allowed environment")
    func spawnUsesFreshRemainingTime() async throws {
        let spawn = ForegroundSpawnSpy()
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(200))
        let runner = IOSRunnerForegroundProcessRunner(deadline: deadline, start: spawn.start)
        try await Task.sleep(for: .milliseconds(50))
        await #expect(throws: HostCommandError.launchFailed) {
            try await runner.run(HostCommandRequest(executableURL: xcrun,
                environment: ["PUBLIC_REQUEST_SENTINEL": "must-not-propagate"], timeout: .seconds(8)))
        }
        let request = try #require(spawn.request)
        #expect(request.maximumLifetime > .zero && request.maximumLifetime <= .milliseconds(150))
        #expect(Set(request.environment.keys).isSubset(of: ["PATH", "HOME", "TMPDIR", "DEVELOPER_DIR", "LANG", "LC_ALL"]))
        #expect(request.environment["PUBLIC_REQUEST_SENTINEL"] == nil)
    }

    @Test("cancellation at executor entry prevents synchronous spawn")
    func cancelledExecutorDoesNotSpawn() async {
        let spawn = ForegroundSpawnSpy()
        let runner = IOSRunnerForegroundProcessRunner(deadline: .now.advanced(by: .seconds(1)), start: spawn.start)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await runner.run(HostCommandRequest(executableURL: xcrun, timeout: .seconds(8)))
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        let didNotSpawn = spawn.request == nil
        #expect(didNotSpawn)
    }

    @Test("native foreground boundary returns only the child exit status")
    func nativeExitOnly() async throws {
        let runner = IOSRunnerForegroundProcessRunner(deadline: .now.advanced(by: .seconds(1)))
        let result = try await runner.run(HostCommandRequest(executableURL: URL(fileURLWithPath: "/usr/bin/true"), timeout: .seconds(8)))
        #expect(result.exitCode == 0)
        #expect(result.standardOutput.isEmpty && result.standardError.isEmpty)
    }

    @Test("activates only the exact supplied hardware target and runner without request data", arguments: [
        "ABCDEF0123456789ABCDEF01", "0123456789abcdef0123456789abcdef01234567", "ABCDEF01-23456789ABCDEF01"
    ])
    func exactCommand(device: String) async throws {
        let commands = ForegroundCommandSpy()
        let activator = IOSRunnerForegroundActivator(xcrunURL: xcrun, commands: commands)
        try await activator.activate(launch: IOSRunnerLaunch(deviceIdentifier: device), deadline: .now.advanced(by: .seconds(30)))
        let requests = await commands.requests
        try #require(requests.count == 1)
        let request = requests[0]
        #expect(request.executableURL == xcrun)
        #expect(request.arguments == ["devicectl", "device", "process", "launch", "--device", device,
            "--activate", "--timeout", "5", "dev.debugutility.DeviceBridgeRunnerUITests.xctrunner"])
        #expect(request.environment == [:])
        #expect(request.maximumOutputBytes == 0)
        #expect(request.timeout > .zero && request.timeout <= .seconds(8))
    }

    @Test("CoreDevice requires integer seconds; the native owner bounds a subsecond deadline")
    func boundedRemainingTime() async throws {
        let commands = ForegroundCommandSpy()
        try await IOSRunnerForegroundActivator(xcrunURL: xcrun, commands: commands).activate(
            launch: IOSRunnerLaunch(deviceIdentifier: identifier), deadline: .now.advanced(by: .milliseconds(200)))
        let request = try #require(await commands.requests.first)
        let index = try #require(request.arguments.firstIndex(of: "--timeout"))
        let toolSeconds = try #require(Int(request.arguments[index + 1]))
        #expect(toolSeconds == 1)
        #expect(request.timeout > .zero && request.timeout <= .milliseconds(200))
    }

    @Test("expired deadlines issue no command")
    func expiredDeadline() async {
        let commands = ForegroundCommandSpy()
        await #expect(throws: IOSRunnerForegroundActivator.Failure.timedOut) {
            try await IOSRunnerForegroundActivator(xcrunURL: xcrun, commands: commands).activate(
                launch: IOSRunnerLaunch(deviceIdentifier: identifier), deadline: .now.advanced(by: .seconds(-1)))
        }
        #expect(await commands.requests.isEmpty)
    }

    @Test("names flags paths and malformed identifiers never reach the command boundary", arguments: [
        "", "--device", "Phone", "/tmp/public", "ABCDEF01-23456789ABCDEF0Z", "ABCDEF0123456789ABCDEF0",
        "ABCDEF0123456789ABCDEF012", "ABCDEF0-123456789ABCDEF01", "ABCDEF01-23456789ABCDEF01\n"
    ])
    func invalidTarget(device: String) async {
        let commands = ForegroundCommandSpy()
        await #expect(throws: IOSRunnerForegroundActivator.Failure.invalidInput) {
            try await IOSRunnerForegroundActivator(xcrunURL: xcrun, commands: commands).activate(
                launch: IOSRunnerLaunch(deviceIdentifier: device), deadline: .now.advanced(by: .seconds(10)))
        }
        #expect(await commands.requests.isEmpty)
    }

    @Test("nonzero and foreign errors become fixed failures", arguments: [ForegroundCommandSpy.Mode.nonzero, .foreignError, .timedOut, .cancelled])
    private func fixedErrors(mode: ForegroundCommandSpy.Mode) async {
        let commands = ForegroundCommandSpy(mode: mode)
        let expected: IOSRunnerForegroundActivator.Failure = mode == .timedOut ? .timedOut : mode == .cancelled ? .cancelled : .activationFailed
        await #expect(throws: expected) {
            try await IOSRunnerForegroundActivator(xcrunURL: xcrun, commands: commands).activate(
                launch: IOSRunnerLaunch(deviceIdentifier: identifier), deadline: .now.advanced(by: .seconds(10)))
        }
        #expect(await commands.requests.count == 1)
    }

    @Test("pre-cancelled activation never starts a process")
    func preCancelled() async {
        let commands = ForegroundCommandSpy()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await IOSRunnerForegroundActivator(xcrunURL: xcrun, commands: commands).activate(
                launch: IOSRunnerLaunch(deviceIdentifier: identifier), deadline: .now.advanced(by: .seconds(10)))
        }
        await #expect(throws: IOSRunnerForegroundActivator.Failure.cancelled) { try await task.value }
        #expect(await commands.requests.isEmpty)
    }

    @Test("uncooperative late success cannot escape cancellation or the original deadline", arguments: [false, true])
    func lateSuccess(cancel: Bool) async throws {
        let commands = ForegroundCommandSpy(mode: .held)
        let task = Task {
            // Allocate the budget when this task actually runs. A 50 ms deadline created
            // before scheduling can expire under the full suite before reaching the held boundary.
            let deadline = ContinuousClock.now.advanced(by: cancel ? .seconds(10) : .seconds(1))
            try await IOSRunnerForegroundActivator(xcrunURL: xcrun, commands: commands).activate(
                launch: IOSRunnerLaunch(deviceIdentifier: identifier), deadline: deadline)
        }
        let waitDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        while await commands.requests.isEmpty, ContinuousClock.now < waitDeadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        let didStart = await !commands.requests.isEmpty
        if didStart {
            if cancel { task.cancel() }
            else {
                let remainingAtEntry = try #require(await commands.requests.first?.timeout)
                try await Task.sleep(for: remainingAtEntry + .milliseconds(10))
            }
        }
        await commands.release()
        await #expect(throws: cancel ? IOSRunnerForegroundActivator.Failure.cancelled : .timedOut) { try await task.value }
        #expect(didStart)
    }
}

private final class ForegroundSpawnSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var captured: IOSRunnerProcessRequest?
    var request: IOSRunnerProcessRequest? { lock.lock(); defer { lock.unlock() }; return captured }
    func start(_ request: IOSRunnerProcessRequest) throws -> IOSRunnerProcess {
        lock.lock(); captured = request; lock.unlock()
        throw HostCommandError.launchFailed
    }
}

private actor ForegroundCommandSpy: HostCommandRunning {
    enum Mode: Sendable { case success, nonzero, foreignError, timedOut, cancelled, held }
    private let mode: Mode
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var requests: [HostCommandRequest] = []
    init(mode: Mode = .success) { self.mode = mode }

    func run(_ request: HostCommandRequest) async throws -> HostCommandResult {
        requests.append(request)
        switch mode {
        case .foreignError: throw NSError(domain: "public-foreign-diagnostic", code: 99)
        case .timedOut: throw HostCommandError.timedOut
        case .cancelled: throw HostCommandError.cancelled
        case .held: await withCheckedContinuation { continuation = $0 }
        default: break
        }
        return HostCommandResult(exitCode: mode == .nonzero ? 1 : 0,
            standardOutput: Data("public ignored stdout".utf8), standardError: Data("public ignored stderr".utf8))
    }

    func release() { continuation?.resume(); continuation = nil }
}
