import Foundation
import Testing
import Darwin
@testable import DeviceBridgeCore

@Suite("Host command boundary", .serialized)
struct HostCommandRunnerTests {
    private let runner = HostCommandRunner()

    @Test("large binary stdin round trips without pipe deadlock or shell interpretation")
    func binaryInput() async throws {
        let input = Data((0..<1_048_576).map { UInt8($0 % 256) })
        let result = try await runner.run(HostCommandRequest(executableURL: URL(fileURLWithPath: "/bin/cat"),
            timeout: .seconds(5), maximumOutputBytes: input.count, standardInput: input))
        #expect(result.exitCode == 0)
        #expect(result.standardOutput == input)
    }

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

    @Test("the total deadline includes pipe EOF after the direct process exits")
    func inheritedPipeDescriptorsCannotOutliveDeadline() async {
        let started = ContinuousClock.now

        do {
            _ = try await runner.run(HostCommandRequest(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "printf inherited-out; printf inherited-err >&2; (trap '' HUP TERM; sleep 2) & exit 0"],
                timeout: .milliseconds(100)
            ))
            Issue.record("Expected the inherited pipe descriptors to reach the total deadline")
        } catch let error as HostCommandError {
            #expect(error == .timedOut)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(started.duration(to: .now) < .seconds(1))
    }

    @Test("timeout escalates termination for the owned child that ignores SIGTERM")
    func timeoutKillsOwnedChildAfterGrace() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("devicebridge-host-command-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: marker) }
        let started = ContinuousClock.now

        do {
            _ = try await runner.run(HostCommandRequest(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "trap '' TERM; printf '%s' \"$$\" > \"$0\"; sleep 2", marker.path],
                timeout: .milliseconds(100)
            ))
            Issue.record("Expected timeout")
        } catch let error as HostCommandError {
            #expect(error == .timedOut)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(started.duration(to: .now) < .seconds(1))
        let pid = try #require(processID(in: marker))
        #expect(!processExists(pid), "The runner returned while its directly owned child was still alive")
    }

    @Test("cancellation escalates and finishes cleanup for both output streams")
    func cancellationCleansBothStreamsAndOwnedChild() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("devicebridge-host-command-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: marker) }
        let task = Task {
            try await runner.run(HostCommandRequest(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: [
                    "-c",
                    "trap '' TERM; printf cancellation-out; printf cancellation-err >&2; printf '%s' \"$$\" > \"$0\"; sleep 2",
                    marker.path,
                ],
                timeout: .seconds(5)
            ))
        }
        try await waitForFile(marker)
        let startedCancellation = ContinuousClock.now
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch let error as HostCommandError {
            #expect(error == .cancelled)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(startedCancellation.duration(to: .now) < .seconds(1))
        let pid = try #require(processID(in: marker))
        #expect(!processExists(pid), "Cancellation returned while its directly owned child was still alive")
    }

    private func waitForFile(_ url: URL) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !FileManager.default.fileExists(atPath: url.path) {
            guard ContinuousClock.now < deadline else {
                throw FixtureError.markerWasNotWritten
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func processID(in url: URL) -> pid_t? {
        guard let contents = try? String(contentsOf: url, encoding: .utf8),
              let processID = pid_t(contents) else { return nil }
        return processID
    }

    private func processExists(_ processID: pid_t) -> Bool {
        errno = 0
        return Darwin.kill(processID, 0) == 0 || errno != ESRCH
    }

    private enum FixtureError: Error {
        case markerWasNotWritten
    }
}
