import DeviceBridgeProtocol
import Foundation
import Testing
@testable import DeviceBridgeCore

@Suite("HarmonyOS captured-route clipboard adapter")
struct HarmonyClipboardChannelTests {
    @Test("construction performs no commands; explicit capability probing reads no clipboard data")
    func capabilityProbe() async throws {
        let runner = HarmonyClipboardRunner()
        let channel = try channel(runner)
        #expect(await runner.requests.isEmpty)
        let capability = try await channel.probeCapabilities()
        #expect(capability.canRead && capability.canWrite)
        #expect(capability.maximumWriteUTF8Bytes == 2_048)
        let requests = await runner.requests
        #expect(requests.count == 2)
        #expect(requests[0].arguments == ["-t", "HDC-ROUTE", "shell", "testhelper help"])
        #expect(requests[1].arguments.last == HarmonyClipboardChannel.encodingProbeCommand)
        #expect(!requests.contains { $0.arguments.last == "testhelper get-pastedata" })
        #expect(!requests.contains { ($0.arguments.last ?? "").contains("testhelper set-pastedata") })
        #expect(!requests.contains { ($0.arguments.last ?? "").contains("clear-pastedata") })
        #expect(requests.allSatisfy { $0.timeout > .zero && $0.timeout <= .seconds(10) })
    }

    @Test("read and write adapt v1 IDs without claiming a remote authenticated helper")
    func adapterSuccess() async throws {
        let text = "  failed ERROR permission denied\n设备 👩🏽‍💻\r\n\n "
        let runner = HarmonyClipboardRunner(readText: text)
        let channel = try channel(runner)
        let read = request(.clipboardRead)
        let readResult = try await channel.send(read)
        #expect(readResult.protocolVersion == 1 && readResult.requestID == read.requestID)
        #expect(readResult.status == .success && readResult.isStructurallyValid)
        #expect(readResult.payload == ["text": .string(text)])
        let write = request(.clipboardWrite, text: "设备 ' \" $(not-executed)\n\n")
        let result = try await channel.send(write)
        #expect(result.requestID == write.requestID && result.status == .success)
        #expect(result.payload == ["written": .bool(true)])
        let requests = await runner.requests
        #expect(requests.count == 4) // Help, non-clipboard encoding probe, read, one write.
        #expect(requests.allSatisfy { Array($0.arguments.prefix(3)) == ["-t", "HDC-ROUTE", "shell"] })
        #expect(requests.last?.maximumOutputBytes == 256)
        #expect(!requests.last!.arguments.joined().contains("not-executed"))
        #expect(requests.last!.arguments.last!.utf8.count <= 4_096)
        #expect(requests.allSatisfy { $0.standardInput == nil })
    }

    @Test("read parsing removes one protocol LF and preserves every byte of user whitespace", arguments: [
        "", "test-123", "  leading and trailing  ", "\n", "\n\n", "\r", "\r\n", "\t a\t\n\r\n",
        "Pasteboard text: nested\nfailed\n[Error] belongs to text", "你好 👩🏽‍💻\n\n",
    ])
    func readExact(_ text: String) throws {
        let output = Data(("Pasteboard text: " + text + "\n").utf8)
        #expect(try HarmonyClipboardChannel.parseRead(.init(exitCode: 0, standardOutput: output, standardError: Data())) == text)
    }

    @Test("malformed read responses fail closed without exposing their content", arguments: [
        Data("test-123\n".utf8), Data(" Pasteboard text: value\n".utf8),
        Data("Pasteboard text:value\n".utf8), Data("Pasteboard text: value".utf8),
        Data("[Fail] permission denied\n".utf8), Data("Pasteboard text: x\0y\n".utf8),
        Data("Pasteboard text: ".utf8) + Data([0xFF, 0x0A]),
    ])
    func malformedRead(_ data: Data) {
        #expect(throws: HarmonyClipboardChannel.Failure.self) {
            try HarmonyClipboardChannel.parseRead(.init(exitCode: 0, standardOutput: data, standardError: Data()))
        }
    }

    @Test("read requires clean stderr and host exit, with an exact 1 MiB whole-text ceiling")
    func readLimitsAndStatus() throws {
        let limit = HarmonyClipboardChannel.maximumReadUTF8Bytes
        let allowed = "Pasteboard text: " + String(repeating: "a", count: limit) + "\n"
        #expect(try HarmonyClipboardChannel.parseRead(.init(exitCode: 0,
            standardOutput: Data(allowed.utf8), standardError: Data())).utf8.count == limit)
        #expect(throws: HarmonyClipboardChannel.Failure.readTooLarge) {
            try HarmonyClipboardChannel.parseRead(.init(exitCode: 0,
                standardOutput: Data(("Pasteboard text: " + String(repeating: "a", count: limit + 1) + "\n").utf8),
                standardError: Data()))
        }
        for result in [
            HostCommandResult(exitCode: 1, standardOutput: Data(allowed.utf8), standardError: Data()),
            HostCommandResult(exitCode: 0, standardOutput: Data(allowed.utf8), standardError: Data("device-private-error".utf8)),
        ] {
            #expect(throws: HarmonyClipboardChannel.Failure.commandFailed) { try HarmonyClipboardChannel.parseRead(result) }
        }
    }

    @Test("write size, NUL and invalid payloads are rejected before even help runs")
    func writeInputLimits() async throws {
        let runner = HarmonyClipboardRunner()
        let channel = try channel(runner)
        for (text, expected) in [(String(repeating: "a", count: 2_049), HarmonyClipboardChannel.Failure.textTooLarge),
                                 (String(repeating: "👋", count: 513), .textTooLarge), ("a\0b", .containsNUL)] {
            await #expect(throws: expected) { try await channel.send(request(.clipboardWrite, text: text)) }
        }
        var extra = request(.clipboardWrite, text: "allowed")
        extra.payload["clear"] = .bool(true)
        await #expect(throws: HarmonyClipboardChannel.Failure.invalidRequest) { try await channel.send(extra) }
        #expect(await runner.requests.isEmpty)
        #expect(!HarmonyClipboardChannel.Failure.textTooLarge.operationFailure.safeMessage.contains("1 MiB"))
    }

    @Test("binding, action, nonce, identity, timestamps and replay are checked before content access")
    func requestBindings() async throws {
        let runner = HarmonyClipboardRunner()
        let channel = try channel(runner)
        var cases: [HelperRequest] = []
        var wrong = request(.clipboardRead); wrong.protocolVersion = 2; cases.append(wrong)
        wrong = request(.clipboardRead); wrong.sessionNonce = "other-session"; cases.append(wrong)
        wrong = request(.clipboardRead); wrong.helperDeviceID = "harmonyos:other"; cases.append(wrong)
        wrong = request(.clipboardRead); wrong.action = .identity; cases.append(wrong)
        wrong = request(.clipboardRead); wrong.payload = ["text": .string("not valid for read")]; cases.append(wrong)
        wrong = request(.clipboardRead); wrong.expiresAt = wrong.createdAt.addingTimeInterval(31); cases.append(wrong)
        wrong = request(.clipboardRead); wrong.createdAt = Date(timeIntervalSince1970: .infinity); cases.append(wrong)
        wrong = request(.clipboardRead); wrong.expiresAt = Date(timeIntervalSince1970: .nan); cases.append(wrong)
        for invalid in cases {
            await #expect(throws: HarmonyClipboardChannel.Failure.invalidRequest) { try await channel.send(invalid) }
        }
        wrong = request(.clipboardRead); wrong.createdAt = Date().addingTimeInterval(-10); wrong.expiresAt = Date().addingTimeInterval(-1)
        await #expect(throws: HarmonyClipboardChannel.Failure.expiredRequest) { try await channel.send(wrong) }
        #expect(await runner.requests.isEmpty)
        let valid = request(.clipboardRead)
        _ = try await channel.send(valid)
        let count = await runner.requests.count
        await #expect(throws: HarmonyClipboardChannel.Failure.replayedRequest) { try await channel.send(valid) }
        #expect(await runner.requests.count == count)
    }

    @Test("a stale captured store session cannot send to an old or new route")
    func staleSession() async throws {
        let store = DeviceSessionStore()
        let first = try device("FIRST")
        let second = try device("SECOND")
        await store.replaceInventory([first, second])
        let selected = try await store.select(first.identity)
        let session = try #require(selected.session)
        let runner = HarmonyClipboardRunner()
        let channel = try HarmonyClipboardChannel(hdcURL: URL(fileURLWithPath: "/hdc"),
            expectedSession: session, sessionNonce: "nonce", runner: runner, store: store)
        _ = try await store.select(second.identity)
        let now = Date()
        let write = HelperRequest(requestID: UUID(), sessionNonce: "nonce", helperDeviceID: first.identity.rawValue,
            action: .clipboardWrite, createdAt: now, expiresAt: now.addingTimeInterval(30), payload: ["text": .string("not-sent")])
        await #expect(throws: HarmonyClipboardChannel.Failure.staleSession) { try await channel.send(write) }
        #expect(await runner.requests.isEmpty)
    }

    @Test("session changes during capability checks block writes; changes after reads block publication")
    func changesAroundCommands() async throws {
        let gate = HarmonyClipboardSessionGate()
        let runner = HarmonyClipboardRunner(afterCommand: { command in
            if command == "testhelper help" { await gate.invalidate() }
        })
        let channel = try channel(runner, validate: { try await gate.validate() })
        await #expect(throws: HarmonyClipboardChannel.Failure.staleSession) {
            try await channel.send(request(.clipboardWrite, text: "not-sent"))
        }
        #expect(await runner.requests.count == 1)
        let readGate = HarmonyClipboardSessionGate()
        let readRunner = HarmonyClipboardRunner(afterCommand: { command in
            if command == "testhelper get-pastedata" { await readGate.invalidate() }
        })
        let readChannel = try self.channel(readRunner, validate: { try await readGate.validate() })
        await #expect(throws: HarmonyClipboardChannel.Failure.staleSession) { try await readChannel.send(request(.clipboardRead)) }
        #expect(await readRunner.requests.count == 3)
    }

    @Test("unsupported help or unavailable base64 cannot write or silently fall back")
    func unsupportedCapabilities() async throws {
        for configuration in [HarmonyClipboardRunner.Configuration.missingHelper, .noDecoder] {
            let runner = HarmonyClipboardRunner(configuration: configuration)
            let channel = try channel(runner)
            let capabilities = try await channel.probeCapabilities()
            #expect(!capabilities.canWrite)
            await #expect(throws: HarmonyClipboardChannel.Failure.unsupported) {
                try await channel.send(request(.clipboardWrite, text: "not-sent"))
            }
            #expect(!(await runner.requests).contains { ($0.arguments.last ?? "").contains("testhelper set-pastedata") })
        }
    }

    @Test("a write needs the exact success acknowledgment and never retries or reads back", arguments: [
        "", "Success\n", "Pasteboard text set successfully.", "Pasteboard text set successfully.\nextra\n",
        "failed\n", "Pasteboard text set successfully.\r\n",
    ])
    func unconfirmedAcknowledgment(_ output: String) async throws {
        let runner = HarmonyClipboardRunner(writeResult: .init(exitCode: 0, standardOutput: Data(output.utf8), standardError: Data()))
        let channel = try channel(runner)
        await #expect(throws: HarmonyClipboardChannel.Failure.writeUnconfirmed) {
            try await channel.send(request(.clipboardWrite, text: "not-in-errors"))
        }
        let commands = await runner.requests.compactMap(\.arguments.last)
        #expect(commands.count == 3)
        #expect(commands.filter { $0.contains("testhelper set-pastedata") }.count == 1)
        #expect(!commands.contains("testhelper get-pastedata"))
        #expect(!commands.contains { $0.contains("clear-pastedata") })
        #expect(!HarmonyClipboardChannel.Failure.writeUnconfirmed.operationFailure.safeMessage.contains("not-in-errors"))
    }

    @Test("cancelled, timed-out, over-limit, nonzero and stderr writes are ambiguous, never rolled back", arguments: ["cancel", "timeout", "limit", "exit", "stderr"])
    func interruptedWrite(_ variant: String) async throws {
        let runner = HarmonyClipboardRunner(configuration: .interruptedWrite(variant))
        let channel = try channel(runner)
        await #expect(throws: HarmonyClipboardChannel.Failure.writeUnconfirmed) {
            try await channel.send(request(.clipboardWrite, text: "not-in-errors"))
        }
        #expect(await runner.requests.count == 3)
    }

    @Test("actual Task cancellation after dispatch is ambiguous for writes and cancels reads",
          arguments: [false, true])
    func taskCancellationAndBusy(_ writing: Bool) async throws {
        let runner = HarmonyClipboardBlockingRunner()
        let channel = try channel(runner)
        let request = self.request(writing ? .clipboardWrite : .clipboardRead, text: writing ? "not-in-errors" : nil)
        let task = Task { try await channel.send(request) }
        let waitDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !(await runner.dispatched), ContinuousClock.now < waitDeadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await runner.dispatched)
        await #expect(throws: HarmonyClipboardChannel.Failure.busy) {
            try await channel.send(self.request(.clipboardWrite, text: "no-concurrent-write"))
        }
        task.cancel()
        if writing {
            await #expect(throws: HarmonyClipboardChannel.Failure.writeUnconfirmed) { try await task.value }
        } else {
            await #expect(throws: CancellationError.self) { try await task.value }
        }
        #expect(await runner.requests.count == 3)
        await #expect(throws: HarmonyClipboardChannel.Failure.replayedRequest) { try await channel.send(request) }
        #expect(await runner.requests.count == 3)
    }

    @Test("a session change after a dispatched write cannot publish success or trigger rollback")
    func sessionChangesAfterWrite() async throws {
        let gate = HarmonyClipboardSessionGate()
        let runner = HarmonyClipboardRunner(afterCommand: { command in
            if command.contains("testhelper set-pastedata") { await gate.invalidate() }
        })
        let channel = try channel(runner, validate: { try await gate.validate() })
        await #expect(throws: HarmonyClipboardChannel.Failure.staleSession) {
            try await channel.send(request(.clipboardWrite, text: "already-may-be-written"))
        }
        #expect(await runner.requests.count == 3)
    }

    @Test("an expired overall request cannot reset its deadline after help or reach a write")
    func overallDeadline() async throws {
        let runner = HarmonyClipboardBlockingRunner(delayHelp: .milliseconds(80))
        let channel = try channel(runner)
        var request = self.request(.clipboardWrite, text: "not-dispatched")
        request.expiresAt = Date().addingTimeInterval(0.03)
        await #expect(throws: HarmonyClipboardChannel.Failure.deadlineExceeded) { try await channel.send(request) }
        #expect(await runner.requests.count == 1)
        #expect(!(await runner.dispatched))
        #expect(await runner.requests.first!.timeout <= .milliseconds(30))
    }

    @Test("production ClipboardService preserves the HDC client limit and ambiguous-write failures",
          arguments: [false, true])
    func serviceTypedFailureMapping(_ oversized: Bool) async throws {
        let store = DeviceSessionStore()
        let device = try device("HDC-ROUTE")
        await store.replaceInventory([device])
        let selected = try await store.select(device.identity)
        let session = try #require(selected.session)
        let runner = HarmonyClipboardRunner(writeResult: .init(exitCode: 0,
            standardOutput: Data("not a valid acknowledgment".utf8), standardError: Data()))
        let channel = try HarmonyClipboardChannel(hdcURL: URL(fileURLWithPath: "/hdc"),
            expectedSession: session, sessionNonce: "nonce", runner: runner, store: store)
        let service = ClipboardService(store: store, channel: channel,
            sessionNonce: "nonce", helperDeviceID: device.identity.rawValue)
        let outcome = await service.write(oversized ? String(repeating: "a", count: 2_049) : "private user content")
        let failure: HarmonyClipboardChannel.Failure = oversized ? .textTooLarge : .writeUnconfirmed
        #expect(outcome.failure == failure.operationFailure)
        #expect(!outcome.failure!.safeMessage.contains("private user content"))
        #expect(await runner.requests.count == (oversized ? 0 : 3))
        #expect(await service.currentSnapshot == nil)
        #expect(await store.snapshot().activeOperationIDs.isEmpty)
    }

    @Test("production ClipboardService read preserves typed HDC failures without publishing text")
    func serviceReadFailureMapping() async throws {
        let store = DeviceSessionStore()
        let device = try device("HDC-ROUTE")
        await store.replaceInventory([device])
        let selected = try await store.select(device.identity)
        let session = try #require(selected.session)
        let runner = HarmonyClipboardRunner(readText: "private content\0not-valid")
        let channel = try HarmonyClipboardChannel(hdcURL: URL(fileURLWithPath: "/hdc"),
            expectedSession: session, sessionNonce: "nonce", runner: runner, store: store)
        let service = ClipboardService(store: store, channel: channel,
            sessionNonce: "nonce", helperDeviceID: device.identity.rawValue)
        let outcome = await service.read()
        #expect(outcome.failure == HarmonyClipboardChannel.Failure.containsNUL.operationFailure)
        #expect(!outcome.failure!.safeMessage.contains("private content"))
        #expect(await service.currentSnapshot == nil)
        #expect(await store.snapshot().activeOperationIDs.isEmpty)
    }

    @Test("production ClipboardService does not downgrade a cancelled dispatched write to a rollback-like cancellation")
    func serviceCancelledWriteIsUnconfirmed() async throws {
        let store = DeviceSessionStore()
        let device = try device("HDC-ROUTE")
        await store.replaceInventory([device])
        let selected = try await store.select(device.identity)
        let session = try #require(selected.session)
        let runner = HarmonyClipboardBlockingRunner()
        let channel = try HarmonyClipboardChannel(hdcURL: URL(fileURLWithPath: "/hdc"),
            expectedSession: session, sessionNonce: "nonce", runner: runner, store: store)
        let service = ClipboardService(store: store, channel: channel,
            sessionNonce: "nonce", helperDeviceID: device.identity.rawValue)
        let task = Task { await service.write("private user content") }
        let waitDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !(await runner.dispatched), ContinuousClock.now < waitDeadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await runner.dispatched)
        task.cancel()
        let outcome = await task.value
        #expect(outcome.failure == HarmonyClipboardChannel.Failure.writeUnconfirmed.operationFailure)
        #expect(outcome.failure?.code != .cancelled)
        #expect(await runner.requests.count == 3)
        #expect(await store.snapshot().activeOperationIDs.isEmpty)
    }

    @Test("real shell Base64/sentinel quoting preserves the full UTF-8 injection matrix")
    func realShellQuoting() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("db-hdc-clipboard-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let canary = directory.appendingPathComponent("must-not-exist")
        let texts = ["", "hello", "  \t whitespace \t  ", "你好 👩🏽‍💻 مرحبا", "\n", "\n\n", "\r", "\r\n", "a\n\n\r\n",
            "'\"`$\\;|&<>(){}[]!*?~#", "$(touch \(canary.path))", "'; touch \(canary.path); #", "${IFS} --help -n %s",
            "DBCLIP_END", "xDBCLIP_END\n\n", String(repeating: "a", count: 2_048), String(repeating: "👋", count: 512)]
        let fixture = shellDecoderShim + "testhelper() { test \"$#\" -eq 2 && test \"$1\" = set-pastedata || exit 91; printf '%s' \"$2\"; }; "
        for text in texts {
            let command = try HarmonyClipboardChannel.writeCommand(text)
            #expect(command.utf8.count <= HarmonyClipboardChannel.maximumShellCommandUTF8Bytes)
            let result = try runShell(fixture + command)
            #expect(result.exitCode == 0)
            #expect(result.standardError.isEmpty)
            #expect(result.standardOutput == Data(text.utf8))
            #expect(!FileManager.default.fileExists(atPath: canary.path))
        }
        let probe = try runShell(shellDecoderShim + HarmonyClipboardChannel.encodingProbeCommand)
        #expect(probe.exitCode == 0 && probe.standardError.isEmpty)
        #expect(probe.standardOutput == Data(HarmonyClipboardChannel.encodingProbeText.utf8))
    }

    @Test("failed or partially failed decoder exits before invoking testhelper", arguments: [false, true])
    func decoderFailureStopsBeforeWrite(_ partial: Bool) throws {
        let decoder = "base64() { cat >/dev/null; " + (partial ? "printf 'partial'; " : "") + "return 9; }; "
        let helper = "testhelper() { printf 'UNEXPECTED_HELPER_INVOCATION'; }; "
        let result = try runShell(decoder + helper + HarmonyClipboardChannel.writeCommand("not-written\n\n"))
        #expect(result.exitCode == 73)
        #expect(result.standardOutput.isEmpty)
        #expect(result.standardError.isEmpty)
    }

    private func request(_ action: HelperAction, text: String? = nil) -> HelperRequest {
        let now = Date()
        return .init(requestID: UUID(), sessionNonce: "nonce", helperDeviceID: "harmonyos:TEST",
            action: action, createdAt: now, expiresAt: now.addingTimeInterval(30),
            payload: text.map { ["text": .string($0)] } ?? [:])
    }

    private func session() throws -> ConnectionSession {
        .init(deviceIdentity: try DeviceIdentity(rawValue: "harmonyos:TEST", stability: .provisional, platform: .harmonyOS),
              generation: 1, transportID: "HDC-ROUTE", state: .active, startedAt: Date())
    }

    private func channel(_ runner: any HostCommandRunning,
                         validate: @escaping @Sendable () async throws -> Void = {}) throws -> HarmonyClipboardChannel {
        try .init(hdcURL: URL(fileURLWithPath: "/hdc"), expectedSession: session(), sessionNonce: "nonce",
                  runner: runner, validateSession: validate)
    }

    private func device(_ target: String) throws -> DeviceRecord {
        let identity = try DeviceIdentity(rawValue: "harmonyos:" + target, stability: .provisional, platform: .harmonyOS)
        let route = try TransportCandidate(id: target, identity: identity, kind: .usb, source: .hdc,
                                          status: .available, observedAt: Date())
        return .init(identity: identity, name: target, authorization: .authorized, candidates: [route], preferredTransportID: target)
    }

    private var shellDecoderShim: String {
        #if os(macOS)
        // Exercise the production -d invocation with the host's equivalent BSD
        // decoder flag. Capability detection still tests literal -d ON THE DEVICE.
        "base64() { test \"$1\" = -d || return 79; command /usr/bin/base64 -D; }; "
        #else
        ""
        #endif
    }

    private func runShell(_ command: String) throws -> HostCommandResult {
        let process = Process()
        let stdout = Pipe(), stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C"]
        process.standardOutput = stdout; process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        try process.run()
        try stdout.fileHandleForWriting.close(); try stderr.fileHandleForWriting.close()
        // This matrix is bounded to 2 KiB; neither pipe can fill before reading.
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let error = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return .init(exitCode: process.terminationStatus, standardOutput: output, standardError: error)
    }
}

private actor HarmonyClipboardSessionGate {
    private var current = true
    func invalidate() { current = false }
    func validate() throws { if !current { throw DeviceSessionStoreError.staleSession } }
}

private actor HarmonyClipboardRunner: HostCommandRunning {
    enum Configuration: Sendable { case normal, missingHelper, noDecoder, interruptedWrite(String) }
    var requests: [HostCommandRequest] = []
    private let readText: String
    private let writeResult: HostCommandResult
    private let configuration: Configuration
    private let afterCommand: @Sendable (String) async -> Void

    init(readText: String = "test-123", configuration: Configuration = .normal,
         writeResult: HostCommandResult = .init(exitCode: 0,
            standardOutput: Data("Pasteboard text set successfully.\n".utf8), standardError: Data()),
         afterCommand: @escaping @Sendable (String) async -> Void = { _ in }) {
        self.readText = readText; self.configuration = configuration
        self.writeResult = writeResult; self.afterCommand = afterCommand
    }

    func run(_ request: HostCommandRequest) async throws -> HostCommandResult {
        requests.append(request)
        let command = request.arguments.last ?? ""
        let output: HostCommandResult
        if command == "testhelper help" {
            let help: String
            if case .missingHelper = configuration { help = "sh: testhelper: not found\n" }
            else { help = "get-pastedata      Get pasteboard text content\nset-pastedata <text>     Set pasteboard text content\nclear-pastedata    Clear pasteboard content\n" }
            output = .init(exitCode: 0, standardOutput: Data(help.utf8), standardError: Data())
        } else if command == HarmonyClipboardChannel.encodingProbeCommand {
            if case .noDecoder = configuration {
                output = .init(exitCode: 0, standardOutput: Data("incorrect\n".utf8), standardError: Data())
            } else { output = .init(exitCode: 0, standardOutput: Data(HarmonyClipboardChannel.encodingProbeText.utf8), standardError: Data()) }
        } else if command == "testhelper get-pastedata" {
            output = .init(exitCode: 0, standardOutput: Data(("Pasteboard text: " + readText + "\n").utf8), standardError: Data())
        } else if command.contains("testhelper set-pastedata") {
            if case .interruptedWrite(let variant) = configuration {
                switch variant {
                case "cancel": throw HostCommandError.cancelled
                case "timeout": throw HostCommandError.timedOut
                case "limit": throw HostCommandError.outputLimitExceeded
                case "exit": return .init(exitCode: 1, standardOutput: writeResult.standardOutput, standardError: Data())
                case "stderr": return .init(exitCode: 0, standardOutput: writeResult.standardOutput, standardError: Data("private device error".utf8))
                default: break
                }
            }
            output = writeResult
        } else { output = .init(exitCode: 99, standardOutput: Data(), standardError: Data()) }
        await afterCommand(command)
        return output
    }
}

private actor HarmonyClipboardBlockingRunner: HostCommandRunning {
    var requests: [HostCommandRequest] = []
    var dispatched = false
    private let delayHelp: Duration
    init(delayHelp: Duration = .zero) { self.delayHelp = delayHelp }

    func run(_ request: HostCommandRequest) async throws -> HostCommandResult {
        requests.append(request)
        let command = request.arguments.last ?? ""
        if command == "testhelper help" {
            if delayHelp > .zero { try await Task.sleep(for: delayHelp) }
            return .init(exitCode: 0, standardOutput: Data("get-pastedata  Read\nset-pastedata <text> Write\n".utf8), standardError: Data())
        }
        if command == HarmonyClipboardChannel.encodingProbeCommand {
            return .init(exitCode: 0, standardOutput: Data(HarmonyClipboardChannel.encodingProbeText.utf8), standardError: Data())
        }
        dispatched = true
        try await Task.sleep(for: .seconds(30))
        throw HostCommandError.timedOut
    }
}
