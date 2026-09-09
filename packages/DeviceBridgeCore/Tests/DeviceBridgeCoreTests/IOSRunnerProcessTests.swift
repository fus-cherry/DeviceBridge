import Darwin
import Foundation
import Testing
@testable import DeviceBridgeCore

struct IOSRunnerProcessTests {
    @Test func cancelledCallerCannotStartAProcess() async {
        let attempt = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                let process = try IOSRunnerProcess.start(executableURL: URL(fileURLWithPath: "/bin/sleep"),
                    arguments: ["1"], environment: [:], lifetime: .seconds(2))
                await process.stop()
                return false
            } catch is CancellationError { return true }
            catch { return false }
        }
        #expect(await attempt.value)
    }

    @Test func leaderExitCleansItsRemainingGroupBeforeReaping() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("DeviceBridgeProcessTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let childFile = temporary.appendingPathComponent("child-pid")
        let process = try IOSRunnerProcess.start(executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "/bin/sleep 10 & child=$!; printf '%s' \"$child\" > \"$1\"; exit 0", "fixture", childFile.path],
            environment: [:], lifetime: .seconds(2))
        #expect(await process.waitForExit().code == 0)
        let child = try #require(Int32(String(contentsOf: childFile, encoding: .utf8)))
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while kill(child, 0) == 0 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(kill(child, 0) == -1 && errno == ESRCH)
    }

    @Test func cancelledObserverDoesNotAbandonExplicitStop() async throws {
        let process = try IOSRunnerProcess.start(executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["10"], environment: [:], lifetime: .seconds(2), terminationGrace: .milliseconds(100))
        let observer = Task { await process.waitForExit() }
        observer.cancel()
        await process.stop()
        let exit = await observer.value
        #expect(exit.signal == SIGTERM)
        #expect(await process.waitForExit() == exit)
    }

    @Test func observesImmediateExitAndSpawnFailure() async throws {
        for code in [0, 7] {
            let process = try IOSRunnerProcess.start(executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "exit \(code)"], environment: [:], lifetime: .seconds(2))
            let exit = await process.waitForExit()
            #expect(exit.code == Int32(code))
            #expect(exit.signal == nil)
            await process.stop()
            #expect(await process.waitForExit() == exit)
        }
        #expect(throws: (any Error).self) {
            try IOSRunnerProcess.start(executableURL: URL(fileURLWithPath: "/nonexistent/devicebridge-test"),
                arguments: [], environment: [:], lifetime: .seconds(1))
        }
    }

    @Test func deadlineEscalatesAnUnresponsiveOwnedProcess() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        let process = try IOSRunnerProcess.start(executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "trap '' TERM; while :; do /bin/sleep 1; done"], environment: [:],
            lifetime: .milliseconds(150), terminationGrace: .milliseconds(100))
        let exit = await process.waitForExit()
        #expect(exit.signal == SIGKILL)
        #expect(start.duration(to: clock.now) < .seconds(2))
    }

    @Test func stoppingOneAttemptLeavesAnotherAlive() async throws {
        let first = try IOSRunnerProcess.start(executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["10"], environment: [:], lifetime: .seconds(2), terminationGrace: .milliseconds(100))
        let second = try IOSRunnerProcess.start(executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "/bin/sleep 0.3; exit 9"], environment: [:], lifetime: .seconds(2))
        await first.stop()
        await first.stop()
        #expect(await first.waitForExit().signal == SIGTERM)
        #expect(await second.waitForExit().code == 9)
    }
}
