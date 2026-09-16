import Foundation
import Testing
@testable import DeviceBridgeCore

@Suite("ADB Shell-v2 result and cleanup boundary", .serialized)
struct ADBShellV2Tests {
    @Test("fragmented stdout, stderr and exit frames preserve real exit codes 0, 7 and 255")
    func fragmentedFramesPreserveExitEvidence() async throws {
        for code: UInt8 in [0, 7, 255] {
            let fake = try FakeADBServer(configuration: .init(shellFrames: [
                shellFrame(id: 1, payload: Data("looks like adb failure\n".utf8)),
                shellFrame(id: 2, payload: Data("diagnostic\n".utf8)),
                shellFrame(id: 3, payload: Data([code])),
            ]))
            try await fake.start()
            let (owner, _, shell) = try await makeShell(fake)

            let result = await shell.run(command: "printf '$HOME' | cat\nexit \(code)",
                deadline: ContinuousClock.now.advanced(by: .seconds(2))) { true }

            #expect(result.termination == .remoteExit)
            #expect(result.exitCode == Int(code))
            #expect(result.standardOutput == Data("looks like adb failure\n".utf8))
            #expect(result.standardError == Data("diagnostic\n".utf8))
            #expect(!result.outputTruncated)
            #expect(fake.requests.filter { $0 == "shell,v2,raw:printf '$HOME' | cat\nexit \(code)" }.count == 1)
            try await waitUntil { fake.closeStdinFrames.count == 1 }
            #expect(fake.closeStdinFrames == [Data([4, 0, 0, 0, 0])])
            await owner.close()
            fake.stop()
        }
    }

    @Test("stdout and stderr each retain 256 KiB while sharing the one MiB raw budget")
    func largeTwoStreamOutputIsPreserved() async throws {
        let stdout = Data(repeating: 0x6f, count: 256 * 1_024)
        let stderr = Data(repeating: 0x65, count: 256 * 1_024)
        let fake = try FakeADBServer(configuration: .init(shellFrames: [
            shellFrame(id: 1, payload: stdout),
            shellFrame(id: 2, payload: stderr),
            shellFrame(id: 3, payload: Data([0])),
        ], fragmentResponses: false))
        try await fake.start()
        defer { fake.stop() }
        let (_, _, shell) = try await makeShell(fake)

        let result = await shell.run(command: "large", deadline: ContinuousClock.now.advanced(by: .seconds(3))) { true }

        #expect(result.termination == .remoteExit)
        #expect(result.standardOutput == stdout)
        #expect(result.standardError == stderr)
    }

    @Test("combined output beyond one MiB retains only the bounded prefix")
    func combinedOutputLimitIsTerminal() async throws {
        let fake = try FakeADBServer(configuration: .init(shellFrames: [
            shellFrame(id: 1, payload: Data(repeating: 0x6f, count: 700 * 1_024)),
            shellFrame(id: 2, payload: Data(repeating: 0x65, count: 400 * 1_024)),
            shellFrame(id: 3, payload: Data([0])),
        ], fragmentResponses: false))
        try await fake.start()
        defer { fake.stop() }
        let (_, _, shell) = try await makeShell(fake)

        let result = await shell.run(command: "large", deadline: ContinuousClock.now.advanced(by: .seconds(3))) { true }

        #expect(result.termination == .outputLimitExceeded)
        #expect(result.standardOutput.count + result.standardError.count == 1_048_576)
        #expect(result.exitCode == nil)
        #expect(result.outputTruncated)
    }

    @Test("the first byte beyond the output budget terminates without waiting for its declared frame")
    func firstOverflowByteIsImmediate() async throws {
        let oversizedTail = shellFrameHeader(id: 2, declaredLength: 64 * 1_024) + Data([0x65])
        let fake = try FakeADBServer(configuration: .init(shellFrames: [
            shellFrame(id: 1, payload: Data(repeating: 0x6f, count: 1_048_576)),
            oversizedTail,
        ], keepShellOpen: true, fragmentResponses: false))
        try await fake.start()
        defer { fake.stop() }
        let (_, _, shell) = try await makeShell(fake)

        let result = await shell.run(command: "overflow",
            deadline: ContinuousClock.now.advanced(by: .milliseconds(200))) { true }

        #expect(result.termination == .outputLimitExceeded)
        #expect(result.standardOutput.count == 1_048_576)
        #expect(result.standardError.isEmpty)
        #expect(result.outputTruncated)
    }

    @Test("EOF without an exit frame cannot be mistaken for remote exit 255")
    func missingExitIsResultUnknown() async throws {
        let fake = try FakeADBServer(configuration: .init(shellFrames: [
            shellFrame(id: 1, payload: Data("partial".utf8)),
        ]))
        try await fake.start()
        defer { fake.stop() }
        let (_, _, shell) = try await makeShell(fake)

        let result = await shell.run(command: "exit 255", deadline: ContinuousClock.now.advanced(by: .seconds(2))) { true }

        #expect(result.termination == .resultUnknown)
        #expect(result.exitCode == nil)
        #expect(result.standardOutput == Data("partial".utf8))
        #expect(result.outputTruncated)
    }

    @Test("invalid frame types, oversized declarations and malformed exit payloads are protocol failures")
    func malformedFramesAreRejected() async throws {
        let cases: [[Data]] = [
            [shellFrame(id: 9, payload: Data())],
            [shellFrameHeader(id: 1, declaredLength: 1_048_577)],
            [shellFrame(id: 3, payload: Data([0, 1]))],
            [Data([1, 3, 0])],
            [shellFrameHeader(id: 1, declaredLength: 3) + Data("a".utf8)],
        ]
        for frames in cases {
            let fake = try FakeADBServer(configuration: .init(shellFrames: frames))
            try await fake.start()
            let (owner, _, shell) = try await makeShell(fake)

            let result = await shell.run(command: "bad", deadline: ContinuousClock.now.advanced(by: .seconds(2))) { true }

            #expect(result.termination == .protocolFailure)
            #expect(result.exitCode == nil)
            await owner.close()
            fake.stop()
        }
    }

    @Test("an immediate exit frame wins if peer EOF races with CloseStdin")
    func immediateExitWinsCloseStdinRace() async throws {
        let fake = try FakeADBServer(configuration: .init(
            shellFrames: [shellFrame(id: 3, payload: Data([255]))],
            finishAfterShellFrames: true
        ))
        try await fake.start()
        defer { fake.stop() }
        let (_, _, shell) = try await makeShell(fake)

        let result = await shell.run(command: "exit 255", deadline: ContinuousClock.now.advanced(by: .seconds(2))) { true }

        #expect(result.termination == .remoteExit)
        #expect(result.exitCode == 255)
    }

    @Test("a selected execution socket disconnect never reconnects or replays the command")
    func selectedSocketDisconnectDoesNotRetry() async throws {
        let fake = try FakeADBServer(configuration: .init(disconnectAfterTport: true))
        try await fake.start()
        defer { fake.stop() }
        let (_, _, shell) = try await makeShell(fake)

        let result = await shell.run(command: "touch forbidden", deadline: ContinuousClock.now.advanced(by: .seconds(2))) { true }

        #expect(result.termination == .resultUnknown)
        #expect(fake.requests.filter { $0 == "host:tport:serial:SERIAL-1" }.count == 1)
        #expect(fake.requests.filter { $0 == "shell,v2,raw:touch forbidden" }.count <= 1)
    }

    @Test("timeout closes a submitted shell and reports incomplete output")
    func deadlineStopsHeldShell() async throws {
        let fake = try FakeADBServer(configuration: .init(shellFrames: [
            shellFrame(id: 1, payload: Data("before timeout".utf8)),
        ], keepShellOpen: true))
        try await fake.start()
        defer { fake.stop() }
        let (_, _, shell) = try await makeShell(fake)

        let result = await shell.run(command: "sleep", deadline: ContinuousClock.now.advanced(by: .milliseconds(100))) { true }

        #expect(result.termination == .timedOut)
        #expect(result.exitCode == nil)
        #expect(result.outputTruncated)
    }

    @Test("an active run rejects a second command and accepted cancellation is terminal")
    func cancellationWinsAndDrainsBeforeNextRun() async throws {
        let fake = try FakeADBServer(configuration: .init(shellFrames: [
            shellFrame(id: 1, payload: Data("before cancel".utf8)),
        ], keepShellOpen: true))
        try await fake.start()
        defer { fake.stop() }
        let (_, _, shell) = try await makeShell(fake)
        let task = Task {
            await shell.run(command: "held", deadline: ContinuousClock.now.advanced(by: .seconds(3))) { true }
        }
        try await fake.waitForRequest("shell,v2,raw:held")

        let busy = await shell.run(command: "second", deadline: ContinuousClock.now.advanced(by: .seconds(1))) { true }
        await shell.cancel()
        let result = await task.value

        #expect(busy.termination == .notStarted(.busy))
        #expect(result.termination == .cancelled)
        #expect(result.exitCode == nil)
        #expect(result.outputTruncated)
        #expect(!fake.requests.contains("shell,v2,raw:second"))
    }

    @Test("invalid commands are rejected before opening any route socket")
    func invalidInputNeverReachesServer() async throws {
        let fake = try FakeADBServer()
        try await fake.start()
        defer { fake.stop() }
        let (_, _, shell) = try await makeShell(fake)
        let baseline = fake.requests

        for command in ["", " \n\t", "bad\0command", String(repeating: "x", count: 16 * 1_024 + 1)] {
            let result = await shell.run(command: command,
                deadline: ContinuousClock.now.advanced(by: .seconds(1))) { true }
            #expect(result.termination == .notStarted(.invalidCommand))
        }
        #expect(fake.requests == baseline)
    }

    private func makeShell(_ fake: FakeADBServer) async throws
        -> (ADBServerConnection, ADBServerEpoch, ADBShellV2Session) {
        let owner = try ADBServerConnection(port: fake.port)
        let epoch = try await owner.beginEpoch(deadline: ContinuousClock.now.advanced(by: .seconds(2)))
        let shell = ADBShellV2Session(server: owner, epoch: epoch, route: try usbRoute())
        return (owner, epoch, shell)
    }
}

private func shellFrameHeader(id: UInt8, declaredLength: UInt32) -> Data {
    var length = declaredLength.littleEndian
    var result = Data([id])
    result.append(withUnsafeBytes(of: &length) { Data($0) })
    return result
}
