import Foundation
import Testing
@testable import DeviceBridgeCore

@Suite("Host command boundary", .serialized)
struct HostCommandRunnerTests {
    private let runner = HostCommandRunner()

    @Test("output quota stops a still-running writer before its timeout")
    func streamingOutputLimit() async {
        // Use a native endless writer: interpreter startup is unrelated to the quota.
        // The elapsed assertion distinguishes early termination from a timeout later
        // remapped to outputLimitExceeded after the pipe readers finish draining.
        let started = ContinuousClock.now
        await #expect(throws: HostCommandError.outputLimitExceeded) {
            try await runner.run(HostCommandRequest(executableURL: URL(fileURLWithPath: "/usr/bin/yes"),
                timeout: .seconds(5), maximumOutputBytes: 1_024))
        }
        #expect(started.duration(to: .now) < .seconds(2))
    }

    @Test("rapid process exits cannot be lost before an async waiter attaches")
    func rapidExitIsRetained() async throws {
        for _ in 0..<30 {
            let result = try await runner.run(HostCommandRequest(
                executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                timeout: .seconds(2)
            ))
            #expect(result.exitCode == 0)
        }
    }

    @Test("arguments are passed without shell interpretation")
    func argumentsRemainLiteral() async throws {
        let result = try await runner.run(HostCommandRequest(
            executableURL: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: ["value=$(whoami);`id`"],
            timeout: .seconds(2)
        ))

        #expect(result.exitCode == 0)
        #expect(result.standardOutputString == "value=$(whoami);`id`")
        #expect(result.standardError.isEmpty)
    }

    @Test("nonzero exit preserves both output channels")
    func nonzeroExitPreservesOutput() async throws {
        let result = try await runner.run(HostCommandRequest(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf 'out\\n'; printf 'err\\n' >&2; exit 7"],
            timeout: .seconds(2)
        ))

        #expect(result.exitCode == 7)
        #expect(result.standardOutputString == "out\n")
        #expect(result.standardErrorString == "err\n")
    }

    @Test("timeout terminates a command")
    func timeoutTerminatesCommand() async {
        do {
            _ = try await runner.run(HostCommandRequest(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["5"],
                timeout: .milliseconds(50)
            ))
            Issue.record("Expected timeout")
        } catch let error as HostCommandError {
            #expect(error == .timedOut)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("task cancellation terminates a command")
    func cancellationTerminatesCommand() async {
        let task = Task {
            try await runner.run(HostCommandRequest(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["5"],
                timeout: .seconds(10)
            ))
        }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch let error as HostCommandError {
            #expect(error == .cancelled)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("stdout and stderr are drained without deadlock")
    func drainsBothChannels() async throws {
        let result = try await runner.run(HostCommandRequest(
            executableURL: URL(fileURLWithPath: "/usr/bin/awk"),
            arguments: [
                "BEGIN { for (i=0; i<200000; i++) printf \"o\"; for (i=0; i<200000; i++) printf \"e\" > \"/dev/stderr\" }"
            ],
            timeout: .seconds(3),
            maximumOutputBytes: 500_000
        ))

        #expect(result.standardOutput.count == 200_000)
        #expect(result.standardError.count == 200_000)
        #expect(result.standardOutputString == String(repeating: "o", count: 200_000))
        #expect(result.standardErrorString == String(repeating: "e", count: 200_000))
    }

    @Test("combined output over the limit fails safely")
    func outputLimitStopsCommand() async {
        do {
            _ = try await runner.run(HostCommandRequest(
                executableURL: URL(fileURLWithPath: "/usr/bin/printf"),
                arguments: ["%s\\n", String(repeating: "x", count: 10_000)],
                timeout: .seconds(2),
                maximumOutputBytes: 1_024
            ))
            Issue.record("Expected output limit failure")
        } catch let error as HostCommandError {
            #expect(error == .outputLimitExceeded)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
