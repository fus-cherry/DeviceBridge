import Foundation
import Testing
@testable import DeviceBridgeCore

@Suite("Host command boundary", .serialized)
struct HostCommandRunnerTests {
    private let runner = HostCommandRunner()

    @Test("output quota stops a still-running writer before its timeout")
    func streamingOutputLimit() async {
        await #expect(throws: HostCommandError.outputLimitExceeded) {
            try await runner.run(HostCommandRequest(executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
                arguments: ["-c", "import sys,time; sys.stdout.write('x'*100000); sys.stdout.flush(); time.sleep(2)"],
                timeout: .milliseconds(500), maximumOutputBytes: 1_024))
        }
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
            executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-c", "import sys; print('out'); print('err', file=sys.stderr); sys.exit(7)"],
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
            executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: [
                "-c",
                "import sys; sys.stdout.write('o'*200000); sys.stderr.write('e'*200000)"
            ],
            timeout: .seconds(3),
            maximumOutputBytes: 500_000
        ))

        #expect(result.standardOutput.count == 200_000)
        #expect(result.standardError.count == 200_000)
    }

    @Test("combined output over the limit fails safely")
    func outputLimitStopsCommand() async {
        do {
            _ = try await runner.run(HostCommandRequest(
                executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
                arguments: ["-c", "print('x'*10000)"],
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
