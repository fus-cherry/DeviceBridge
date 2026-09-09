import Foundation
import Testing
@testable import DeviceBridgeCore

struct IOSRunnerPublicRecordReaderTests {
    @Test func copyTargetsOnlyCapturedPhoneBundleAndLaunch() async throws {
        let launch = IOSRunnerLaunch(deviceIdentifier: "PUBLIC-PHONE")
        let runner = PublicRecordCommand { request in
            #expect(request.arguments.prefix(5) == ["devicectl", "device", "copy", "from", "--device"])
            #expect(value("--device", in: request) == launch.deviceIdentifier)
            #expect(value("--domain-type", in: request) == "appDataContainer")
            #expect(value("--domain-identifier", in: request) == "dev.debugutility.DeviceBridgeRunnerUITests.xctrunner")
            #expect(value("--source", in: request) == "Documents/DeviceBridgeBootstrap/\(launch.id.uuidString).json")
            #expect(request.timeout == .seconds(8))
            #expect(request.maximumOutputBytes == 0)
            let destination = try #require(value("--destination", in: request))
            try Data("public-record".utf8).write(to: URL(fileURLWithPath: destination))
            return 0
        }
        let reader = IOSRunnerPublicRecordReader(xcrunURL: URL(fileURLWithPath: "/usr/bin/xcrun"), commands: runner)
        let data = try await reader.read(launch: launch)
        #expect(data == Data("public-record".utf8))
        let request = try #require(await runner.lastRequest)
        let destination = try #require(value("--destination", in: request))
        #expect(!FileManager.default.fileExists(atPath: URL(fileURLWithPath: destination).deletingLastPathComponent().path))
    }

    @Test(arguments: ["empty", "oversized", "directory", "symlink", "failedCopy", "missing"])
    func untrustedOrFailedCopiesAreNotReturned(mode: String) async throws {
        let runner = PublicRecordCommand { request in
            let destination = URL(fileURLWithPath: try #require(value("--destination", in: request)))
            switch mode {
            case "empty": try Data().write(to: destination)
            case "oversized": try Data(repeating: 42, count: 8193).write(to: destination)
            case "directory": try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            case "symlink": try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
            case "failedCopy": try Data("partial".utf8).write(to: destination); return 1
            default: break
            }
            return 0
        }
        let reader = IOSRunnerPublicRecordReader(xcrunURL: URL(fileURLWithPath: "/usr/bin/xcrun"), commands: runner)
        await #expect(throws: (any Error).self) { try await reader.read(launch: IOSRunnerLaunch(deviceIdentifier: "PUBLIC-PHONE")) }
        let request = try #require(await runner.lastRequest)
        let destination = try #require(value("--destination", in: request))
        #expect(!FileManager.default.fileExists(atPath: URL(fileURLWithPath: destination).deletingLastPathComponent().path))
    }

    @Test func cancellationRejectsLateSuccessfulCopyAndCleansIt() async throws {
        let gate = PublicRecordGate()
        let runner = PublicRecordCommand { request in
            await gate.wait()
            let destination = try #require(value("--destination", in: request))
            try Data("late-public-record".utf8).write(to: URL(fileURLWithPath: destination))
            return 0
        }
        let reader = IOSRunnerPublicRecordReader(xcrunURL: URL(fileURLWithPath: "/usr/bin/xcrun"), commands: runner)
        let task = Task { try await reader.read(launch: IOSRunnerLaunch(deviceIdentifier: "PUBLIC-PHONE")) }
        while await runner.lastRequest == nil { await Task.yield() }
        task.cancel()
        await gate.release()
        await #expect(throws: CancellationError.self) { try await task.value }
        let request = try #require(await runner.lastRequest)
        let destination = try #require(value("--destination", in: request))
        #expect(!FileManager.default.fileExists(atPath: URL(fileURLWithPath: destination).deletingLastPathComponent().path))
    }

    @Test func cancelledCallDoesNotStartACommand() async throws {
        let runner = PublicRecordCommand { _ in Issue.record("Cancelled request started a copy"); return 0 }
        let reader = IOSRunnerPublicRecordReader(xcrunURL: URL(fileURLWithPath: "/usr/bin/xcrun"), commands: runner)
        let gate = PublicRecordGate()
        let task = Task { await gate.wait(); return try await reader.read(launch: IOSRunnerLaunch(deviceIdentifier: "PUBLIC-PHONE")) }
        task.cancel(); await gate.release()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await runner.lastRequest == nil)
    }

    @Test func nativeCopyDeadlineEscalatesAndCleansTheOwnedDirectory() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("PublicCopyCommandTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let executable = temporary.appendingPathComponent("copy-fixture")
        // This bounded fixture outlives TERM unless the owned group is escalated to KILL.
        try Data("#!/bin/sh\ntrap '' TERM\nprintf ready > \"${0%/*}/ready\"\nn=0\nwhile [ \"$n\" -lt 6 ]; do /bin/sleep 1; n=$((n+1)); done\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let runner = PublicRecordCommand { request in
            do {
                let result = try await IOSRunnerPublicCopyProcessRunner().run(request)
                Issue.record("TERM-ignoring fixture exited without deadline escalation")
                return result.exitCode
            } catch HostCommandError.timedOut { throw HostCommandError.timedOut }
            catch { Issue.record("Unexpected fixture failure, not deadline escalation"); throw error }
        }
        let reader = IOSRunnerPublicRecordReader(xcrunURL: executable, commands: runner, copyTimeout: .seconds(1))
        let started = ContinuousClock.now
        await #expect(throws: (any Error).self) { try await reader.read(launch: IOSRunnerLaunch(deviceIdentifier: "PUBLIC-PHONE")) }
        #expect(FileManager.default.fileExists(atPath: temporary.appendingPathComponent("ready").path))
        #expect(started.duration(to: .now) >= .seconds(2.5))
        #expect(started.duration(to: .now) < .seconds(4.5))
        let request = try #require(await runner.lastRequest)
        let destination = try #require(value("--destination", in: request))
        #expect(!FileManager.default.fileExists(atPath: URL(fileURLWithPath: destination).deletingLastPathComponent().path))
    }
}

private func value(_ key: String, in request: HostCommandRequest) -> String? {
    guard let index = request.arguments.firstIndex(of: key), index + 1 < request.arguments.count else { return nil }
    return request.arguments[index + 1]
}

private actor PublicRecordCommand: HostCommandRunning {
    let operation: @Sendable (HostCommandRequest) async throws -> Int32
    var lastRequest: HostCommandRequest?
    init(_ operation: @escaping @Sendable (HostCommandRequest) async throws -> Int32) { self.operation = operation }
    func run(_ request: HostCommandRequest) async throws -> HostCommandResult {
        lastRequest = request
        return try await HostCommandResult(exitCode: operation(request), standardOutput: Data(), standardError: Data())
    }
}

private actor PublicRecordGate {
    var released = false
    var waiter: CheckedContinuation<Void, Never>?
    func wait() async { if !released { await withCheckedContinuation { waiter = $0 } } }
    func release() { released = true; waiter?.resume(); waiter = nil }
}
