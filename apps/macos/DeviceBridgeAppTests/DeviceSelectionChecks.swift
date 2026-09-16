import DeviceBridgeCore
import Foundation

/// Slow external probe, real Workspace selection. Never starts an app or a physical command.
@main
struct DeviceSelectionChecks {
    @MainActor static func main() async throws {
        let runner = SelectionProbeRunner()
        let runnerPreparations = LockedCounter()
        let model = WorkspaceViewModel(arguments: [], runner: runner,
            iosScreenshotRunnerFactory: { _ in
                runnerPreparations.increment()
                throw IOSRunnerSourceConfigurationError.signingTeamRequired
            },
            iosMemoryProvider: NoSelectionMemory())
        defer { model.stop() }
        model.start()
        try require(model.isRefreshing, "launch must immediately advertise discovery")
        try await wait { !model.isRefreshing && model.devices.count == 2 }
        let first = model.devices[0], second = model.devices[1]
        model.select(first.identity)
        try require(model.deviceSelection?.device.identity == first.identity && model.deviceSelection?.isChecking == true,
                    "first click must immediately present the pending device before probe completion")
        try require(model.selectedDeviceIdentity == nil && !model.agentActionsAllowed,
                    "pending feedback must not commit a session or grant content access")
        try await wait { await runner.probes == 1 }
        // The probe remains held while MainActor accepts a second device selection.
        model.select(second.identity)
        try require(model.deviceSelection?.device.identity == second.identity,
                    "a second click must update feedback without waiting for the old probe")
        await runner.release(probe: 1, exitCode: 1)
        try await wait { await runner.probes == 2 }
        try require(model.deviceSelection?.device.identity == second.identity && model.deviceSelection?.isChecking == true,
                    "late cancelled failure replaced current selection feedback")
        await runner.release(probe: 2, exitCode: 1)
        try await wait { !model.isSelecting }
        try require(model.deviceSelection?.device.identity == second.identity && model.deviceSelection?.isChecking == false,
                    "a failed first connection must remain visibly actionable without a committed device")
        try require(model.selectedDeviceIdentity == nil && !model.agentActionsAllowed,
                    "failed candidate must not become an authorized selection")
        try require(await runner.restarts == 0, "failed probes must never restart a system service automatically")
        let repairRevision = model.iosConnectionRepairRevision!
        model.repairIOSConnection(identity: first.identity, expectedRevision: repairRevision)
        try require(await runner.restarts == 0, "wrong-device confirmation restarted the service")
        model.repairIOSConnection(identity: second.identity, expectedRevision: repairRevision)
        model.repairIOSConnection(identity: second.identity, expectedRevision: repairRevision)
        try await wait { await runner.probes == 3 }
        try require(await runner.restarts == 1, "explicit recovery must restart exactly once before probing")
        try require(model.selectedDeviceIdentity == nil && !model.agentActionsAllowed,
                    "service restart must not bypass the real command readiness gate")
        await runner.release(probe: 3, exitCode: 0)
        try await wait { model.selectedDeviceIdentity == second.identity && !model.isSelecting }
        try require(model.deviceSelection == nil, "successful commit must dismiss pending feedback")
        try require(runnerPreparations.value == 0,
                    "selection must not prepare or foreground the iOS runner")
        model.select(second.identity)
        try await Task.sleep(for: .milliseconds(50))
        try require(await runner.probes == 3 && !model.isSelecting,
                    "re-selecting the healthy active device must be a no-op")
        model.select(first.identity)
        try await wait { await runner.probes == 4 }
        model.repairIOSConnection(identity: second.identity, expectedRevision: repairRevision)
        try require(await runner.restarts == 1, "stale repair confirmation restarted the service")
        await runner.hideFirstDevice()
        model.requestRefresh()
        try await wait { !model.isRefreshing && !model.devices.contains(where: { $0.identity == first.identity }) }
        await runner.release(probe: 4, exitCode: 1)
        try await wait { !model.isSelecting }
        try require(model.deviceSelection?.device.identity == first.identity && model.deviceSelection?.isChecking == false,
                    "a device removed while waiting for old cleanup must fail visibly, not spin forever")
        model.select(second.identity)
        try await wait { await runner.probes == 5 }
        model.stop()
        try require(model.deviceSelection == nil && !model.isSelecting, "Stop must clear pending feedback synchronously")
        await runner.release(probe: 5, exitCode: 1)
        for _ in 0..<100 { await Task.yield() }
        try require(model.deviceSelection == nil, "late stopped probe republished feedback")
        let recoveryRunner = SelectionProbeRunner()
        let recovering = WorkspaceViewModel(arguments: [], runner: recoveryRunner,
            iosScreenshotRunnerFactory: { _ in throw IOSRunnerSourceConfigurationError.signingTeamRequired },
            iosMemoryProvider: NoSelectionMemory())
        defer { recovering.stop() }
        recovering.start()
        try await wait { !recovering.isRefreshing && recovering.devices.count == 2 }
        let recoveryDevice = recovering.devices[0]
        recovering.select(recoveryDevice.identity)
        try await wait { await recoveryRunner.probes == 1 }
        await recoveryRunner.release(probe: 1, exitCode: 1)
        try await wait { !recovering.isSelecting }
        await recoveryRunner.configureRestart(exitCode: 2, held: false)
        recovering.repairIOSConnection(identity: recoveryDevice.identity,
            expectedRevision: recovering.iosConnectionRepairRevision!)
        try await wait { !recovering.isSelecting }
        try require(await recoveryRunner.probes == 1 && recovering.selectedDeviceIdentity == nil,
                    "failed service restart must not proceed to a probe or publish a session")
        try require(recovering.iosConnectionRepairRevision != nil, "failed repair must remain retryable")
        await recoveryRunner.configureRestart(exitCode: 0, held: true)
        recovering.repairIOSConnection(identity: recoveryDevice.identity,
            expectedRevision: recovering.iosConnectionRepairRevision!)
        try await wait { await recoveryRunner.restarts == 2 }
        recovering.stop()
        await recoveryRunner.releaseRestart()
        for _ in 0..<100 { await Task.yield() }
        try require(await recoveryRunner.probes == 1 && recovering.deviceSelection == nil,
                    "stopped repair must not issue a device probe or republish selection")
        print("PASS: immediate first/second-click feedback, responsive MainActor during held probe, separate candidate/commit, visible first-use failure, retry, Stop and stale result rejection; no device or UI commands")
    }
    @MainActor static func wait(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw Failure.failed("state wait timed out") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure.failed(message) }
    }
    enum Failure: Error { case failed(String) }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

private actor SelectionProbeRunner: HostCommandRunning {
    private(set) var probes = 0
    private(set) var restarts = 0
    private var restartExitCode: Int32 = 0
    private var holdRestart = false
    private var pendingRestart: CheckedContinuation<Void, Never>?
    func configureRestart(exitCode: Int32, held: Bool) { restartExitCode = exitCode; holdRestart = held }
    func releaseRestart() { pendingRestart?.resume(); pendingRestart = nil }
    private var pending: [Int: CheckedContinuation<HostCommandResult, Never>] = [:]
    private var hideFirst = false
    func hideFirstDevice() { hideFirst = true }
    func run(_ request: HostCommandRequest) async throws -> HostCommandResult {
        if request.executableURL.path == "/usr/bin/pkill" {
            restarts += 1
            if holdRestart { await withCheckedContinuation { pendingRestart = $0 } }
            return HostCommandResult(exitCode: restartExitCode, standardOutput: Data(), standardError: Data())
        }
        if request.arguments == ["devices", "-l"] {
            return HostCommandResult(exitCode: 0, standardOutput: Data("List of devices attached\n".utf8), standardError: Data())
        }
        if request.arguments.starts(with: ["devicectl", "list", "devices"]),
           let index = request.arguments.firstIndex(of: "--json-output") {
            let devices = (hideFirst ? ["B"] : ["A", "B"]).map { name in
                ["identifier": "selection-route-" + name,
                 "hardwareProperties": ["udid": "selection-udid-" + name, "platform": "iOS", "marketingName": "iPhone " + name],
                 "connectionProperties": ["transportType": "wired", "pairingState": "paired", "tunnelState": "connected"],
                 "deviceProperties": ["name": "iPhone " + name, "osVersionNumber": "18.3.1", "developerModeStatus": "enabled", "isLocked": false]] as [String: Any]
            }
            try JSONSerialization.data(withJSONObject: ["result": ["devices": devices]])
                .write(to: URL(fileURLWithPath: request.arguments[index + 1]))
            return HostCommandResult(exitCode: 0, standardOutput: Data(), standardError: Data())
        }
        guard request.arguments.starts(with: ["devicectl", "device", "info", "details"]) else {
            throw DeviceSelectionChecks.Failure.failed("unexpected external command")
        }
        probes += 1
        let probe = probes
        return await withCheckedContinuation { pending[probe] = $0 }
    }
    func release(probe: Int, exitCode: Int32) {
        pending.removeValue(forKey: probe)?.resume(returning: HostCommandResult(exitCode: exitCode, standardOutput: Data(), standardError: Data()))
    }
}

private struct NoSelectionMemory: IOSWorkspaceVMProviding {
    func applications(session: ConnectionSession) async throws -> [TargetApplication] { [] }
    func binding(store: DeviceSessionStore, session: ConnectionSession, applicationID: String) async throws -> IOSVerifiedVMBinding {
        throw DeviceSelectionChecks.Failure.failed("memory binding forbidden")
    }
}
