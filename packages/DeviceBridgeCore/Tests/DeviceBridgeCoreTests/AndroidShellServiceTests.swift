import Foundation
import Testing
@testable import DeviceBridgeCore

@Suite("Android Shell execution ownership")
struct AndroidShellServiceTests {
    @Test("raw command and real exit evidence survive without retries or stderr heuristics")
    func rawCommandAndExit() async throws {
        let fixture = try await Fixture()
        let command = "  printf '你好\\n'; printf 'adb: device offline' >&2; exit 255\n"
        let result = AndroidShellCommandResult(stdout: Data([0xff, 0x41]), stderr: Data("adb: device offline".utf8),
            completion: .remoteExit(255))
        await fixture.executor.setResult(result)
        let id = UUID()
        let started = Date.distantPast
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        let outcome = await fixture.service.run(command: command, session: fixture.session, operationID: id,
            origin: .agent, startedAt: started, deadline: deadline)
        let execution = try execution(outcome)
        #expect(execution.command == command)
        #expect(execution.id == id && execution.origin == .agent && execution.startedAt == started)
        #expect(execution.stdout == Data([0xff, 0x41]))
        #expect(execution.stderr == result.stderr)
        #expect(execution.completion == .remoteExit(255))
        #expect(await fixture.executor.commands == [command])
        #expect(await fixture.executor.deadlines == [deadline])
        #expect(await fixture.store.snapshot().activeOperationIDs.isEmpty)
    }

    @Test("invalid input, iOS and expired deadlines never reach the executor")
    func rejectsBeforeExecution() async throws {
        let fixture = try await Fixture()
        for command in [" \n\t", "echo\0secret", String(repeating: "x", count: 16_385)] {
            let outcome = await fixture.run(command: command)
            guard case .notStarted = try execution(outcome).completion else {
                Issue.record("Invalid command must be rejected before execution")
                continue
            }
        }
        let ios = try ConnectionSession(deviceIdentity: DeviceIdentity(rawValue: "ios", stability: .stable, platform: .iOS),
            generation: 1, transportID: "ios-route", state: .active, startedAt: Date())
        let unsupported = await fixture.service.run(command: "id", session: ios, operationID: UUID(),
            origin: .ui, startedAt: Date(), deadline: .now.advanced(by: .seconds(30)))
        guard case .notStarted = try execution(unsupported).completion else {
            Issue.record("iOS must not run Android Shell")
            return
        }
        let timeout = await fixture.service.run(command: "id", session: fixture.session, operationID: UUID(),
            origin: .ui, startedAt: Date(), deadline: .now.advanced(by: .seconds(-1)))
        #expect(try execution(timeout).completion == .timedOut)
        #expect(await fixture.executor.commands.isEmpty)
        #expect(await fixture.store.snapshot().activeOperationIDs.isEmpty)
    }

    @Test("captured admission cannot move a command to a newly selected session")
    func staleAdmission() async throws {
        let fixture = try await Fixture()
        _ = try await fixture.store.select(fixture.session.deviceIdentity)
        #expect(await fixture.run() == .stale)
        #expect(await fixture.executor.commands.isEmpty)
    }

    @Test("Task cancellation revokes success immediately and holds exclusion through cleanup")
    func cancellationDrains() async throws {
        let fixture = try await Fixture()
        let gate = ShellServiceGate()
        await fixture.executor.setRunGate(gate)
        let id = UUID()
        let work = Task { await fixture.run(id: id) }
        await gate.waitUntilEntered()
        work.cancel()
        await fixture.executor.waitUntilCancelled()
        let token = SessionToken(deviceIdentity: fixture.session.deviceIdentity, transportID: fixture.session.transportID,
            sessionGeneration: fixture.session.generation, operationID: id)
        #expect(await !fixture.store.canPublish(token))
        #expect(await fixture.store.snapshot().activeOperationIDs.isEmpty)
        await #expect(throws: DeviceSessionStoreError.connectionBusy) {
            try await fixture.store.beginOperation(.androidShell, expectedSession: fixture.session)
        }
        await gate.release()
        #expect(try execution(await work.value).completion == .cancelled)
        #expect(await fixture.executor.cancelCount == 1)
        let next = try await fixture.store.beginOperation(.androidShell, expectedSession: fixture.session)
        #expect(await fixture.store.finishShellOperation(next, terminal: .remoteExit))
    }

    @Test("a pending cancellation request is part of cleanup even after run returns")
    func cancellationRequestMustDrain() async throws {
        let fixture = try await Fixture()
        let runGate = ShellServiceGate()
        let cancelGate = ShellServiceGate()
        await fixture.executor.setRunGate(runGate)
        await fixture.executor.setCancelGate(cancelGate)
        let work = Task { await fixture.run() }
        await runGate.waitUntilEntered()
        work.cancel()
        await cancelGate.waitUntilEntered()
        await runGate.release()
        await fixture.executor.waitUntilReturned()
        await #expect(throws: DeviceSessionStoreError.connectionBusy) {
            try await fixture.store.beginOperation(.androidShell, expectedSession: fixture.session)
        }
        await cancelGate.release()
        #expect(try execution(await work.value).completion == .cancelled)
    }

    @Test("cancel during binding validation revokes the admitted token without starting native execution")
    func cancelBeforeNativeExecution() async throws {
        let fixture = try await Fixture()
        let gate = ShellServiceGate()
        await fixture.binding.setGate(gate)
        let work = Task { await fixture.run() }
        await gate.waitUntilEntered()
        work.cancel()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await !fixture.store.snapshot().activeOperationIDs.isEmpty, ContinuousClock.now < deadline {
            await Task.yield()
        }
        #expect(await fixture.store.snapshot().activeOperationIDs.isEmpty)
        await gate.release()
        #expect(try execution(await work.value).completion == .cancelled)
        #expect(await fixture.executor.commands.isEmpty)
    }

    @Test("same instance reentry and another service share the Store Shell exclusion")
    func concurrentAdmission() async throws {
        let fixture = try await Fixture()
        let gate = ShellServiceGate()
        await fixture.executor.setRunGate(gate)
        let work = Task { await fixture.run() }
        await gate.waitUntilEntered()
        let localBusy = await fixture.run()
        guard case .notStarted = try execution(localBusy).completion else {
            Issue.record("Reentry must not run or replace the current execution")
            await gate.release()
            return
        }
        let otherExecutor = ShellCommandFixture()
        let otherService = AndroidShellService(store: fixture.store, makeExecutor: { otherExecutor },
            bindingIsCurrent: { _ in true })
        let globalBusy = await otherService.run(command: "second", session: fixture.session, operationID: UUID(),
            origin: .agent, startedAt: Date(), deadline: .now.advanced(by: .seconds(30)))
        guard case .notStarted = try execution(globalBusy).completion else {
            Issue.record("Another service must share Store exclusion")
            await gate.release()
            return
        }
        #expect(await otherExecutor.commands.isEmpty)
        await gate.release()
        #expect(try execution(await work.value).completion == .remoteExit(0))
        #expect(await fixture.executor.commands.count == 1)
    }

    @Test("session change while executing drains but cannot publish into the replacement session")
    func sessionLoss() async throws {
        let fixture = try await Fixture()
        let gate = ShellServiceGate()
        await fixture.executor.setRunGate(gate)
        let work = Task { await fixture.run() }
        await gate.waitUntilEntered()
        let next = try #require(await fixture.store.select(fixture.session.deviceIdentity).session)
        await #expect(throws: DeviceSessionStoreError.connectionBusy) {
            try await fixture.store.beginOperation(.androidShell, expectedSession: next)
        }
        await gate.release()
        #expect(await work.value == .stale)
        let nextToken = try await fixture.store.beginOperation(.androidShell, expectedSession: next)
        #expect(await fixture.store.finishShellOperation(nextToken, terminal: .remoteExit))
    }

    @Test("epoch loss makes the fixed validator false and suppresses late exit publication")
    func epochLoss() async throws {
        let fixture = try await Fixture()
        let gate = ShellServiceGate()
        await fixture.executor.setRunGate(gate)
        let work = Task { await fixture.run() }
        await gate.waitUntilEntered()
        await fixture.binding.invalidate()
        #expect(await fixture.executor.validateCapturedSession() == false)
        await gate.release()
        #expect(await work.value == .stale)
        #expect(await fixture.store.snapshot().activeOperationIDs.isEmpty)
    }

    @Test("timeout and unknown execution results retain their category without replay")
    func nativeTerminals() async throws {
        let fixture = try await Fixture()
        for terminal in [AndroidShellCompletion.timedOut, .resultUnknown, .connectionLost, .outputLimitExceeded,
                         .protocolFailure, .notStarted(OperationFailure(code: .unsupported, safeMessage: "Unavailable"))] {
            await fixture.executor.setResult(AndroidShellCommandResult(stdout: Data("partial".utf8),
                stderr: Data(), completion: terminal, outputTruncated: terminal == .outputLimitExceeded))
            let result = try execution(await fixture.run())
            #expect(result.completion == terminal)
            #expect(result.stdout == Data("partial".utf8))
            #expect(result.outputTruncated == (terminal == .outputLimitExceeded))
            #expect(await fixture.store.snapshot().activeOperationIDs.isEmpty)
        }
        #expect(await fixture.executor.commands.count == 6)
    }

    @Test("the captured monotonic deadline includes time spent awaiting binding admission")
    func deadlineIncludesBindingAdmission() async throws {
        let fixture = try await Fixture()
        let gate = ShellServiceGate()
        await fixture.binding.setGate(gate)
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(30))
        let work = Task {
            await fixture.service.run(command: "id", session: fixture.session, operationID: UUID(),
                origin: .ui, startedAt: Date(), deadline: deadline)
        }
        await gate.waitUntilEntered()
        try await ContinuousClock().sleep(until: deadline)
        await gate.release()
        #expect(try execution(await work.value).completion == .timedOut)
        #expect(await fixture.executor.commands.isEmpty)
        #expect(await fixture.store.snapshot().activeOperationIDs.isEmpty)
    }

    @Test("cancellation already present at entry never invokes native execution")
    func cancelledAtEntry() async throws {
        let fixture = try await Fixture()
        let gate = ShellServiceGate()
        let work = Task {
            await gate.enter()
            return await fixture.run()
        }
        await gate.waitUntilEntered()
        work.cancel()
        await gate.release()
        #expect(try execution(await work.value).completion == .cancelled)
        #expect(await fixture.executor.commands.isEmpty)
        #expect(await fixture.store.snapshot().activeOperationIDs.isEmpty)
    }

    private func execution(_ outcome: AndroidShellOutcome) throws -> AndroidShellExecution {
        guard case let .execution(value) = outcome else {
            throw OperationFailure(code: .failure, safeMessage: "Expected an execution result")
        }
        return value
    }

    private struct Fixture {
        let store = DeviceSessionStore()
        let executor = ShellCommandFixture()
        let binding = ShellBindingFixture()
        let session: ConnectionSession
        let service: AndroidShellService
        init() async throws {
            let identity = try DeviceIdentity(rawValue: "shell-fixture", stability: .stable, platform: .android)
            let candidate = try TransportCandidate(id: "11", identity: identity, kind: .usb, source: .adb,
                status: .available, observedAt: Date(), metadata: ["adbSerial": "fixture-serial"])
            await store.replaceInventory([DeviceRecord(identity: identity, name: "Fixture", authorization: .authorized,
                candidates: [candidate], preferredTransportID: "11")])
            session = try #require(await store.select(identity).session)
            let executor = executor, binding = binding
            service = AndroidShellService(store: store, makeExecutor: { executor },
                bindingIsCurrent: { _ in await binding.isCurrent() })
        }
        func run(command: String = "id", id: UUID = UUID()) async -> AndroidShellOutcome {
            await service.run(command: command, session: session, operationID: id, origin: .ui,
                startedAt: Date(), deadline: .now.advanced(by: .seconds(30)))
        }
    }
}

private actor ShellCommandFixture: AndroidShellCommandExecuting {
    private(set) var commands: [String] = []
    private(set) var deadlines: [ContinuousClock.Instant] = []
    private(set) var cancelCount = 0
    private var validator: (@Sendable () async -> Bool)?
    private var result = AndroidShellCommandResult(stdout: Data(), stderr: Data(), completion: .remoteExit(0))
    private var runGate: ShellServiceGate?
    private var cancelGate: ShellServiceGate?
    private var cancelledWaiter: CheckedContinuation<Void, Never>?
    private var returned = false
    private var returnedWaiter: CheckedContinuation<Void, Never>?
    func setResult(_ value: AndroidShellCommandResult) { result = value }
    func setRunGate(_ value: ShellServiceGate) { runGate = value }
    func setCancelGate(_ value: ShellServiceGate) { cancelGate = value }
    func run(command: String, deadline: ContinuousClock.Instant,
             validateSession: @escaping @Sendable () async -> Bool) async -> AndroidShellCommandResult {
        commands.append(command); deadlines.append(deadline); validator = validateSession
        await runGate?.enter()
        returned = true; returnedWaiter?.resume(); returnedWaiter = nil
        return result
    }
    func cancel() async {
        cancelCount += 1; cancelledWaiter?.resume(); cancelledWaiter = nil
        await cancelGate?.enter()
    }
    func waitUntilCancelled() async {
        if cancelCount == 0 { await withCheckedContinuation { cancelledWaiter = $0 } }
    }
    func waitUntilReturned() async {
        if !returned { await withCheckedContinuation { returnedWaiter = $0 } }
    }
    func validateCapturedSession() async -> Bool { await validator?() ?? false }
}

private actor ShellBindingFixture {
    private var current = true
    private var gate: ShellServiceGate?
    func setGate(_ value: ShellServiceGate) { gate = value }
    func invalidate() { current = false }
    func isCurrent() async -> Bool { await gate?.enter(); return current }
}

private actor ShellServiceGate {
    private var entered = false
    private var released = false
    private var entryWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    func enter() async {
        entered = true; entryWaiter?.resume(); entryWaiter = nil
        if !released { await withCheckedContinuation { releaseWaiter = $0 } }
    }
    func waitUntilEntered() async {
        if !entered { await withCheckedContinuation { entryWaiter = $0 } }
    }
    func release() { released = true; releaseWaiter?.resume(); releaseWaiter = nil }
}
