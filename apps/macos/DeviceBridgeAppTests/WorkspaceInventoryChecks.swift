import Combine
import DeviceBridgeCore
import Foundation

/// Executes production polling, publication and cancellation using synthetic commands only.
@main
struct WorkspaceInventoryChecks {
    @MainActor
    static func main() async throws {
        let runner = InventoryRunner()
        let model = WorkspaceViewModel(arguments: [], runner: runner)
        var devicePublications = 0
        var diagnosticPublications = 0
        let devices = model.$devices.dropFirst().sink { _ in devicePublications += 1 }
        let diagnostics = model.$diagnostics.dropFirst().sink { _ in diagnosticPublications += 1 }
        defer { devices.cancel(); diagnostics.cancel(); model.stop() }

        model.start()
        try await wait { await runner.scans == 1 }
        try require(model.isRefreshing, "initial discovery must show busy feedback")
        await runner.release()
        try await wait { !model.isRefreshing && model.devices.count == 1 }
        let identity = model.devices[0].identity
        let firstPublications = devicePublications
        let firstDiagnostics = diagnosticPublications

        // This is the actual five-second production timer, not a test-only refresh entry.
        try await wait(seconds: 7) { await runner.scans == 2 }
        try require(!model.isRefreshing, "background inventory must not show spinner")
        model.requestRefresh()
        try require(model.isRefreshing, "manual request joining a poll must show feedback")
        await runner.release()
        try await wait { !model.isRefreshing }
        try require(devicePublications == firstPublications, "timestamp-only poll republished devices")
        try require(diagnosticPublications == firstDiagnostics, "unchanged poll republished diagnostics")
        try require(model.devices[0].identity == identity, "unchanged poll replaced identity")

        model.requestRefresh()
        try await wait { await runner.scans == 3 }
        try require(model.isRefreshing, "manual discovery must show busy feedback")
        model.requestRefresh()
        await runner.release(name: "Renamed")
        try await wait { !model.isRefreshing && model.devices.first?.model == "Renamed" }
        try require(await runner.scans == 3, "manual refresh must remain single-flight")
        try require(devicePublications == firstPublications + 1, "name change must publish once")

        model.requestRefresh()
        try await wait { await runner.scans == 4 }
        await runner.release(status: "unauthorized")
        try await wait { !model.isRefreshing && model.devices.first?.authorization == .denied }
        model.requestRefresh()
        try await wait { await runner.scans == 5 }
        await runner.release(empty: true)
        try await wait { !model.isRefreshing && model.devices.isEmpty }

        // A command that ignores cancellation must not publish after stop or clear a new task.
        model.requestRefresh()
        try await wait { await runner.scans == 6 }
        model.stop()
        try require(!model.isRefreshing, "stop must immediately clear busy presentation")
        model.start()
        try await wait { await runner.scans == 7 }
        await runner.release(scan: 6, name: "Stale")
        for _ in 0..<100 { await Task.yield() }
        try require(model.devices.isEmpty && model.isRefreshing, "stale refresh changed restarted UI")
        model.requestRefresh()
        await runner.release(scan: 7, name: "Current")
        try await wait { !model.isRefreshing && model.devices.first?.model == "Current" }
        try require(await runner.scans == 7, "stale task cleared the current single-flight owner")
        model.requestRefresh()
        try await wait { await runner.scans == 8 }
        await runner.release(scan: 8, name: "Current", transportID: "2")
        try await wait { !model.isRefreshing && model.devices.first?.preferredTransportID == "2" }
        model.requestRefresh()
        try await wait { await runner.scans == 9 }
        await runner.release(scan: 9, name: "Current", transportID: "2", serial: "192.0.2.1:5555", usb: false)
        try await wait { !model.isRefreshing && model.devices.first?.identity.rawValue == "android:192.0.2.1:5555" }
        try require(model.devices.first?.candidates.first?.endpoint == "192.0.2.1:5555", "changed route endpoint was lost")
        try require(model.devices.first?.candidates.first?.kind == .wifi, "changed transport kind was lost")
        model.stop()
        try await multipleWorkspaceHostsRetainDiscovery()
        try await pollingRecoversDetectedDevice()
        try await removedSelectionCanReconnect()
        try await heldProbeCannotSelectReplacementRoute()

        let selectedModel = WorkspaceViewModel(arguments: ["--fixture-devices"], runner: runner)
        selectedModel.start()
        try await wait { !selectedModel.isRefreshing }
        let selected = selectedModel.devices[0].identity
        let beforeSelection = selectedModel.clipboardExportGeneration
        selectedModel.select(selected)
        try await wait { !selectedModel.isSelecting }
        try require(selectedModel.clipboardExportGeneration > beforeSelection, "selection must invalidate old export panels")
        let selectedGeneration = selectedModel.clipboardExportGeneration
        var selectionPublications = 0
        var fixtureDevicePublications = 0
        let selectionSubscription = selectedModel.$selectedDeviceIdentity.dropFirst().sink { _ in selectionPublications += 1 }
        let fixtureSubscription = selectedModel.$devices.dropFirst().sink { _ in fixtureDevicePublications += 1 }
        selectedModel.requestRefresh()
        try await wait { !selectedModel.isRefreshing }
        try require(selectedModel.selectedDeviceIdentity == selected, "refresh lost selected identity")
        try require(selectionPublications == 0 && fixtureDevicePublications == 0, "unchanged selected inventory republished")
        try require(selectedModel.clipboardExportGeneration == selectedGeneration, "unchanged poll invalidated export panel")
        let other = selectedModel.devices.first { $0.identity != selected }!.identity
        selectedModel.select(other)
        try await wait { !selectedModel.isSelecting }
        fixtureDevicePublications = 0
        selectionPublications = 0
        selectedModel.requestRefresh()
        try await wait { !selectedModel.isRefreshing }
        try require(selectionPublications == 0 && fixtureDevicePublications == 0,
                    "switching selection must not defer a sidebar reorder to the next poll")
        try require(selectedModel.selectedDeviceIdentity == other, "refresh reverted the new selection")
        let beforeStop = selectedModel.clipboardExportGeneration
        selectedModel.stop()
        try require(selectedModel.clipboardExportGeneration > beforeStop, "stop must invalidate export panels")
        selectionSubscription.cancel()
        fixtureSubscription.cancel()
        try await fixtureContentActions()
        let recovery = WorkspaceViewModel(arguments: ["--fixture-devices", "--fixture-recovery"])
        recovery.start()
        try await wait { !recovery.isRefreshing }
        guard let android = recovery.devices.first(where: { $0.identity.platform == .android }) else {
            throw Failure.failed("Android recovery fixture missing")
        }
        recovery.select(android.identity)
        try await wait { recovery.connectionRecoveryCount > 0 && !recovery.isSelecting }
        recovery.requestClipboardRead()
        try await wait { !recovery.isClipboardBusy }
        try require(recovery.clipboardFeedback == "Read",
                    "recovered same-device route skipped rebinding without a foreground helper context")
        recovery.stop()
        print("PASS: workspace inventory — initial/manual busy, silent timer, meaningful publication, offline/authorization recovery, explicit retries, selected removal/reappearance and route rebinding, preserved selection, single-flight, stop/restart stale completion; synthetic commands only, no device or UI")
    }

    @MainActor
    static func multipleWorkspaceHostsRetainDiscovery() async throws {
        let runner = InventoryRunner()
        let model = WorkspaceViewModel(arguments: [], runner: runner)
        defer { model.stop() }
        let first = UUID(), second = UUID(), reopened = UUID()
        model.attachWorkspace(first)
        model.attachWorkspace(first) // repeated appearances must not leak ownership
        model.attachWorkspace(second)
        try await wait { await runner.scans == 1 }
        await runner.release()
        try await wait { !model.isRefreshing && model.devices.count == 1 }
        model.detachWorkspace(second)
        model.detachWorkspace(second) // a repeated disappearance is harmless
        model.detachWorkspace(UUID()) // an unrelated window cannot stop the owner
        try await wait(seconds: 7) { await runner.scans == 2 }
        await runner.release(status: "offline")
        try await wait { model.devices.first?.candidates.first?.status == .offline }
        try require(model.connectionHealth != .stopped,
                    "closing one of two windows stopped the remaining window's discovery")
        model.detachWorkspace(first)
        try require(model.connectionHealth == .stopped && !model.isRefreshing,
                    "last workspace host must release discovery and owned resources")
        model.attachWorkspace(reopened)
        try await wait { await runner.scans == 3 }
        await runner.release()
        try await wait { !model.isRefreshing && model.devices.first?.authorization == .authorized }
        model.detachWorkspace(reopened)
        try require(model.connectionHealth == .stopped, "reopened last window did not clean up")
        print("PASS: repeated two-window appearances/disappearances retain the actual inventory timer until the final host closes")
    }

    /// Exercise the actual parser and five-second production timer. A newly detected
    /// route permits an explicit attempt, never an automatic connection or Ready claim.
    @MainActor
    static func pollingRecoversDetectedDevice() async throws {
        let runner = InventoryRunner()
        let model = WorkspaceViewModel(arguments: [], runner: runner)
        defer { model.stop() }
        model.start()
        try await wait { await runner.scans == 1 }
        await runner.release(status: "offline")
        try await wait { !model.isRefreshing && model.devices.count == 1 }
        try require(!DeviceConnectionPresentation(device: model.devices[0]).canAttemptConnection,
                    "offline route must not be classified as a connection attempt")

        try await wait(seconds: 7) { await runner.scans == 2 }
        try require(!model.isRefreshing, "offline recovery poll must remain silent")
        await runner.release()
        try await wait { model.devices.first?.authorization == .authorized }
        try requireDetectedOnly(model)

        model.requestRefresh()
        try await wait { await runner.scans == 3 }
        await runner.release(status: "unauthorized")
        try await wait { !model.isRefreshing && model.devices.first?.authorization == .denied }
        try require(!DeviceConnectionPresentation(device: model.devices[0]).canAttemptConnection,
                    "unauthorized route must remain in the attention classification")
        model.requestRefresh()
        try await wait { await runner.scans == 4 }
        await runner.release()
        try await wait { !model.isRefreshing && model.devices.first?.authorization == .authorized }
        try requireDetectedOnly(model)

        let identity = model.devices[0].identity
        model.select(identity)
        try await wait { !model.isSelecting && model.deviceSelection != nil }
        guard case let .failed(_, failure) = model.deviceSelection else {
            throw Failure.failed("synthetic readiness failure did not remain visible")
        }
        try require(await runner.probeAttempts == 1, "explicit selection must issue one readiness probe")
        model.requestRefresh()
        try await wait { await runner.scans == 5 }
        await runner.release()
        try await wait { !model.isRefreshing }
        try requireDetectedOnly(model)
        let retry = DeviceConnectionPresentation(device: model.devices[0], failedSelectionReason: failure.safeMessage)
        try require(retry.canAttemptConnection && retry.reason == failure.safeMessage,
                    "last probe failure must remain advisory without hiding a detected retry route")
        model.select(identity)
        try await wait { !model.isSelecting && model.deviceSelection != nil }
        try require(await runner.probeAttempts == 2, "same-device explicit Retry was suppressed")
        try requireDetectedOnly(model)
    }

    @MainActor
    static func requireDetectedOnly(_ model: WorkspaceViewModel) throws {
        guard let device = model.devices.first else { throw Failure.failed("detected device missing") }
        try require(device.candidates.contains { $0.status == .candidate }, "real parser must preserve candidate status")
        try require(!device.candidates.contains { $0.status == .available }, "discovery must not mark a route command-ready")
        try require(DeviceConnectionPresentation(device: device).canAttemptConnection,
                    "authorized candidate must be classified as a detected connection attempt")
        try require(model.selectedDeviceIdentity == nil && model.lastSuccessfulCommandAt == nil,
                    "metadata polling or failed probe automatically committed a selected connection")
        try require(model.connectionHealth != .healthy && model.connectionHealth != .recovered,
                    "metadata polling or failed probe claimed command readiness")
        try require(!model.canStartClipboardOperation && !model.agentActionsAllowed,
                    "detected-only route enabled connected device actions")
    }

    /// CoreDevice disappearance/reappearance must not leave a stale Healthy no-op
    /// guard blocking an explicit reselect. Synthetic runner + VM provider only.
    @MainActor
    static func removedSelectionCanReconnect() async throws {
        let runner = ReappearingPhoneInventory()
        let model = WorkspaceViewModel(arguments: [], runner: runner, iosMemoryProvider: InventoryNoIOSMemory())
        defer { model.stop() }
        model.start()
        try await wait { !model.isRefreshing && model.devices.count == 1 }
        let identity = model.devices[0].identity
        model.select(identity)
        try await wait { !model.isSelecting && model.connectionHealth == .healthy }
        try require(await runner.probes == 1, "initial phone selection must verify the route")
        let initialGeneration = model.clipboardExportGeneration
        model.select(identity)
        try require(!model.isSelecting && model.clipboardExportGeneration == initialGeneration,
                    "unchanged healthy selection must remain an idempotent no-op")

        for expectedProbes in 2...3 {
            await runner.setPresent(false)
            model.requestRefresh()
            try await wait { !model.isRefreshing && model.devices.isEmpty }
            try require(model.connectionHealth == .actionRequired,
                        "removed selected phone retained healthy session presentation")
            let lastSuccessfulCommandAt = model.lastSuccessfulCommandAt
            await runner.setPresent(true)
            model.requestRefresh()
            try await wait { !model.isRefreshing && model.devices.count == 1 }
            try require(model.selectedDeviceIdentity == identity && model.connectionHealth == .actionRequired,
                        "reappearing metadata must preserve selection without restoring readiness")
            try require(model.lastSuccessfulCommandAt == lastSuccessfulCommandAt,
                        "reappearance falsely published a successful command")
            try require(await runner.probes == expectedProbes - 1,
                        "inventory must not auto-probe or auto-connect a reappearing phone")
            model.select(identity)
            try await wait { !model.isSelecting && model.connectionHealth == .healthy }
            try require(await runner.probes == expectedProbes,
                        "same-row retry after reappearance was incorrectly treated as already connected")
        }

        await runner.changeRoute()
        model.requestRefresh()
        try await wait { !model.isRefreshing && model.devices.first?.preferredTransportID == "22222222-2222-4222-8222-222222222222" }
        try require(model.connectionHealth == .actionRequired,
                    "inventory route replacement retained the previous command-ready ownership")
        try require(await runner.probes == 3, "inventory route replacement automatically verified a new route")
        model.select(identity)
        try await wait { !model.isSelecting && model.connectionHealth == .healthy }
        try require(await runner.probes == 4, "same-row retry after route replacement did not rebind")
    }

    @MainActor
    static func heldProbeCannotSelectReplacementRoute() async throws {
        let runner = ReappearingPhoneInventory()
        let model = WorkspaceViewModel(arguments: [], runner: runner, iosMemoryProvider: InventoryNoIOSMemory())
        defer { model.stop() }
        model.start()
        try await wait { !model.isRefreshing && model.devices.count == 1 }
        let identity = model.devices[0].identity
        let originalRoute = model.devices[0].preferredTransportID!
        await runner.holdNextProbe()
        model.select(identity)
        try await wait { await runner.hasPendingProbe }
        await runner.changeRoute()
        model.requestRefresh()
        let replacementRoute = "22222222-2222-4222-8222-222222222222"
        try await wait { !model.isRefreshing && model.devices.first?.preferredTransportID == replacementRoute }
        try require(model.isSelecting, "readiness probe must still be held while inventory replaces its route")
        await runner.releaseProbe()
        try await wait { !model.isSelecting }
        guard case .failed = model.deviceSelection else {
            throw Failure.failed("a successful old-route probe selected an unprobed replacement route")
        }
        try require(model.selectedDeviceIdentity == nil && model.connectionHealth == .actionRequired,
                    "unprobed replacement route was committed as a healthy selection")
        try require(model.lastSuccessfulCommandAt == nil && !model.agentActionsAllowed,
                    "stale probe completion granted command-ready presentation or actions")
        try require(await runner.probedRoutes == [originalRoute], "inventory replacement automatically probed its new route")
        model.select(identity)
        try await wait { !model.isSelecting && model.connectionHealth == .healthy }
        try require(await runner.probedRoutes == [originalRoute, replacementRoute],
                    "explicit retry did not probe the replacement route before committing it")
    }

    /// Distinguish model readiness/publication failures from desktop event synthesis failures.
    /// These are synthetic Android samples; no real VM or system clipboard is accessed.
    @MainActor
    static func fixtureContentActions() async throws {
        let runner = RejectContentCommands()
        var firstSampleMilliseconds: [Int] = []
        for _ in 0..<3 {
            let model = WorkspaceViewModel(arguments: ["--fixture-devices"], runner: runner)
            defer { model.stop() }
            model.start()
            try await wait { !model.isRefreshing && !model.devices.isEmpty }
            guard let device = model.devices.first(where: { $0.identity.platform == .android }) else {
                throw Failure.failed("Android fixture missing")
            }
            model.select(device.identity)
            try await wait { !model.isSelecting }
            if case .availableOnDemand = model.clipboardReadiness { }
            else { throw Failure.failed("Android selection must publish on-demand clipboard availability") }
            try require(await runner.calls == 0,
                "Android selection must not launch or foreground the helper")
            try await wait { model.canStartClipboardOperation }
            try require(model.clipboardReadinessText == "Available on demand",
                "on-demand capability status and enabled action must come from the same state")
            let text = "Keyboard transfer\n中文🙂"
            model.clipboardText = text
            model.requestClipboardSend()
            try require(!model.canStartClipboardOperation && model.clipboardReadinessText != "Ready",
                "a busy clipboard action must never retain a Ready label with disabled controls")
            try await wait { !model.isClipboardBusy }
            try require(model.clipboardReadinessText == "Ready" && model.canStartClipboardOperation,
                "prepared clipboard status and action availability diverged")
            try require(model.clipboardFeedback == "Sent", "ready fixture send did not complete")
            model.clipboardText = ""
            model.requestClipboardRead()
            try await wait { !model.isClipboardBusy }
            try require(model.clipboardFeedback == "Read" && model.clipboardText == text,
                        "explicit fixture read did not match the sent content")
            try await wait { model.memoryReadiness == .ready && model.agentActionsAllowed }
            try require(model.memorySamples.isEmpty && !model.isMonitoringMemory,
                        "readiness must not start memory monitoring")
            let started = ContinuousClock.now
            model.startAndroidMemoryMonitoring()
            try require(model.isMonitoringMemory, "ready Start must immediately enter monitoring")
            try await wait { !model.memorySamples.isEmpty }
            let duration = started.duration(to: .now).components
            firstSampleMilliseconds.append(Int(duration.seconds * 1_000 + duration.attoseconds / 1_000_000_000_000_000))
            try require(model.memorySamples.allSatisfy {
                $0.deviceIdentity == device.identity && $0.applicationID == "dev.example.fixture"
                    && $0.source == .androidMeminfo && $0.processID == 101
            }, "fixture sample attribution changed")
            model.stopMemoryMonitoring()
            try require(!model.isMonitoringMemory && model.memorySamples.isEmpty,
                        "Stop must synchronously clear monitoring and samples")
            for _ in 0..<100 { await Task.yield() }
            try require(model.memorySamples.isEmpty, "late sample published after Stop")
        }
        try require(await runner.calls == 0, "fixture interaction attempted a real host command")
        print("PASS: fixture explicit send/read and initial attributed memory sample/Stop; first sample ms \(firstSampleMilliseconds); no app, UI input, system clipboard or physical VM")
    }

    @MainActor
    static func wait(seconds: Int = 3, _ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw Failure.failed("state wait timed out") }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure.failed(message) }
    }
    enum Failure: Error { case failed(String) }
}

private actor RejectContentCommands: HostCommandRunning {
    private(set) var calls = 0
    func run(_ request: HostCommandRequest) async throws -> HostCommandResult {
        calls += 1
        throw WorkspaceInventoryChecks.Failure.failed("physical command forbidden in fixture check")
    }
}

private actor InventoryRunner: HostCommandRunning {
    private(set) var scans = 0
    private(set) var probeAttempts = 0
    private var pending: [Int: CheckedContinuation<HostCommandResult, Never>] = [:]
    func run(_ request: HostCommandRequest) async throws -> HostCommandResult {
        // iOS reports a stable diagnostic; the real discovery parser still executes.
        if request.arguments.first == "devicectl" {
            return HostCommandResult(exitCode: 1, standardOutput: Data(), standardError: Data())
        }
        if request.arguments.count == 3, request.arguments.first == "-t", request.arguments.last == "get-state" {
            probeAttempts += 1
            return HostCommandResult(exitCode: 1, standardOutput: Data(), standardError: Data())
        }
        guard request.arguments == ["devices", "-l"] else {
            throw WorkspaceInventoryChecks.Failure.failed("unexpected host command")
        }
        scans += 1
        let scan = scans
        let result = await withCheckedContinuation { pending[scan] = $0 }
        return result
    }
    func release(scan: Int? = nil, name: String = "Pixel", status: String = "device", empty: Bool = false,
                 transportID: String = "1", serial: String = "inventory-test", usb: Bool = true) {
        let output = "List of devices attached\n" + (empty ? "" : "\(serial)\t\(status) \(usb ? "usb:1 " : "")model:\(name) device:test transport_id:\(transportID)\n")
        pending.removeValue(forKey: scan ?? scans)?.resume(returning: HostCommandResult(
            exitCode: 0, standardOutput: Data(output.utf8), standardError: Data()))
    }
}

private struct InventoryNoIOSMemory: IOSWorkspaceVMProviding {
    func applications(session: ConnectionSession) async throws -> [TargetApplication] { [] }
    func binding(store: DeviceSessionStore, session: ConnectionSession,
                 applicationID: String) async throws -> IOSVerifiedVMBinding {
        throw WorkspaceInventoryChecks.Failure.failed("inventory checks must never open a VM channel")
    }
}

private actor ReappearingPhoneInventory: HostCommandRunning {
    private var present = true
    private var route = "11111111-1111-4111-8111-111111111111"
    private(set) var probes = 0
    private(set) var probedRoutes: [String] = []
    private var holdingProbe = false
    private var pendingProbe: CheckedContinuation<Void, Never>?
    var hasPendingProbe: Bool { pendingProbe != nil }

    func setPresent(_ present: Bool) { self.present = present }
    func changeRoute() { route = "22222222-2222-4222-8222-222222222222" }
    func holdNextProbe() { holdingProbe = true }
    func releaseProbe() { pendingProbe?.resume(); pendingProbe = nil }

    func run(_ request: HostCommandRequest) async throws -> HostCommandResult {
        if request.arguments == ["devices", "-l"] {
            return HostCommandResult(exitCode: 0, standardOutput: Data("List of devices attached\n".utf8), standardError: Data())
        }
        if request.arguments.starts(with: ["devicectl", "list", "devices"]),
           let output = request.arguments.firstIndex(of: "--json-output") {
            let phone: [String: Any] = [
                "identifier": route,
                "hardwareProperties": ["udid": "inventory-phone-udid", "platform": "iOS", "marketingName": "Inventory iPhone"],
                "connectionProperties": ["transportType": "wired", "pairingState": "paired", "tunnelState": "connected"],
                "deviceProperties": ["name": "Inventory iPhone", "osVersionNumber": "18.3.1", "developerModeStatus": "enabled", "isLocked": false],
            ]
            try JSONSerialization.data(withJSONObject: ["result": ["devices": present ? [phone] : []]])
                .write(to: URL(fileURLWithPath: request.arguments[output + 1]))
            return HostCommandResult(exitCode: 0, standardOutput: Data(), standardError: Data())
        }
        if request.arguments.starts(with: ["devicectl", "device", "info", "details"]) {
            probes += 1
            if let device = request.arguments.firstIndex(of: "--device") {
                probedRoutes.append(request.arguments[device + 1])
            }
            if holdingProbe {
                holdingProbe = false
                await withCheckedContinuation { pendingProbe = $0 }
            }
            return HostCommandResult(exitCode: present ? 0 : 1, standardOutput: Data(), standardError: Data())
        }
        throw WorkspaceInventoryChecks.Failure.failed("unexpected external command in phone inventory checks")
    }
}
