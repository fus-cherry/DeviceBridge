import DeviceBridgeCore
import Foundation

/// Slow external probe, real Workspace selection. Never starts an app or a physical command.
@main
struct DeviceSelectionChecks {
    @MainActor static func main() async throws {
        let runner = SelectionProbeRunner()
        let model = WorkspaceViewModel(arguments: [], runner: runner,
            iosRunnerFactory: { _ in throw IOSRunnerSourceConfigurationError.signingTeamRequired },
            iosMemoryProvider: NoSelectionMemory())
        defer { model.stop() }
        model.start()
        try require(model.isRefreshing, "launch must immediately advertise discovery")
        try await wait { !model.isRefreshing && model.devices.count == 2 }
        let first = model.devices[0], second = model.devices[1]
        model.select(first.identity)
        try require(model.deviceSelection?.device.identity == first.identity && model.deviceSelection?.isChecking == true,
                    "first click must immediately present the pending device before probe completion")
        try require(model.selectedDeviceIdentity == nil && !model.contentActionsAllowed,
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
        try require(model.selectedDeviceIdentity == nil && !model.contentActionsAllowed,
                    "failed candidate must not become an authorized selection")
        model.select(second.identity)
        try await wait { await runner.probes == 3 }
        await runner.release(probe: 3, exitCode: 0)
        try await wait { model.selectedDeviceIdentity == second.identity && !model.isSelecting }
        try require(model.deviceSelection == nil, "successful commit must dismiss pending feedback")
        model.select(second.identity)
        try await wait { await runner.probes == 4 }
        model.select(first.identity)
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

private actor SelectionProbeRunner: HostCommandRunning {
    private(set) var probes = 0
    private var pending: [Int: CheckedContinuation<HostCommandResult, Never>] = [:]
    private var hideFirst = false
    func hideFirstDevice() { hideFirst = true }
    func run(_ request: HostCommandRequest) async throws -> HostCommandResult {
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
