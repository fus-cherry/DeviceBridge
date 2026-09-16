import DeviceBridgeCore
import Foundation

/// Explicit opt-in against a designated Android emulator/device. The caller owns test data and focus.
@main
struct AndroidCapabilityPhysicalCheck {
    @MainActor
    static func main() async throws {
        let environment = ProcessInfo.processInfo.environment
        let transport = try requireValue(environment["DEVICEBRIDGE_LIVE_ANDROID_TRANSPORT"],
                                         "missing designated Android transport")
        let adbPath = try requireValue(environment["DEVICEBRIDGE_LIVE_ADB_PATH"],
                                       "missing ADB path")
        let adb = URL(fileURLWithPath: adbPath)
        let runner = HostCommandRunner()
        let initialForeground = try await focusedPackage(adb: adb, transport: transport, runner: runner)
        try require(initialForeground != AndroidHelperManager.packageName,
                    "helper was already foreground before selection")

        let model = WorkspaceViewModel(arguments: [], runner: runner)
        defer { model.stop() }
        model.start()
        try await wait(seconds: 20) {
            !model.isRefreshing && model.devices.contains { $0.preferredTransportID == transport }
        }
        let device = try requireValue(model.devices.first { $0.preferredTransportID == transport },
                                      "designated Android target was not discovered")
        model.select(device.identity)
        try await wait(seconds: 20) {
            !model.isSelecting && model.selectedDeviceIdentity == device.identity
        }
        guard case .availableOnDemand = model.clipboardReadiness else {
            throw Failure.failed("selection did not leave clipboard available on demand")
        }
        try require(model.clipboardAction.statusText == "Available on demand"
                        && model.clipboardAction.canStart,
                    "selection status and clipboard admission disagree")
        let foregroundAfterSelection = try await focusedPackage(adb: adb, transport: transport, runner: runner)
        try require(foregroundAfterSelection == initialForeground,
                    "selection replaced the emulator foreground application")

        model.requestClipboardRead()
        try await wait(seconds: 20) { !model.isClipboardBusy }
        try require(model.clipboardReadiness == .ready && model.clipboardAction.canStart,
                    "first explicit read did not leave clipboard ready")
        let foregroundAfterRead = try await focusedPackage(adb: adb, transport: transport, runner: runner)
        try require(foregroundAfterRead == AndroidHelperManager.packageName,
                    "explicit clipboard action did not foreground the managed helper")

        let marker = "DeviceBridge MuMu clipboard " + UUID().uuidString
        model.clipboardText = marker
        model.requestClipboardSend()
        try await wait(seconds: 20) { !model.isClipboardBusy }
        try require(model.clipboardFeedback == "Sent", "verified clipboard write did not succeed")
        model.clipboardText = ""
        model.requestClipboardRead()
        try await wait(seconds: 20) { !model.isClipboardBusy }
        try require(model.clipboardFeedback == "Read" && model.clipboardText == marker,
                    "clipboard Unicode round trip did not return exact text")

        model.clipboardText = ""
        model.requestClipboardSend()
        try await wait(seconds: 20) { !model.isClipboardBusy }
        try require(model.clipboardFeedback == "Sent", "explicit empty clipboard write was not verified")
        model.requestClipboardRead()
        try await wait(seconds: 20) { !model.isClipboardBusy }
        try require(model.clipboardFeedback == "Read" && model.clipboardText.isEmpty,
                    "explicit empty clipboard was confused with unavailable content")
        print("PASS: Android selection preserved foreground; clipboard helper started only on explicit action; verified text and empty round trips")
    }

    @MainActor
    private static func wait(seconds: Int, _ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw Failure.failed("state wait timed out") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private static func focusedPackage(
        adb: URL,
        transport: String,
        runner: any HostCommandRunning
    ) async throws -> String {
        let result = try await runner.run(HostCommandRequest(
            executableURL: adb,
            arguments: ["-t", transport, "shell", "dumpsys", "window"],
            timeout: .seconds(10),
            maximumOutputBytes: 2 * 1_024 * 1_024
        ))
        try require(result.exitCode == 0, "window focus query failed")
        let line = try requireValue(result.standardOutputString.split(separator: "\n").first {
            $0.contains("mCurrentFocus=")
        }, "window focus was unavailable")
        let component = try requireValue(line.split(whereSeparator: \.isWhitespace).first { $0.contains("/") },
                                         "focused component was unavailable")
        return String(component.split(separator: "/", maxSplits: 1)[0])
    }

    private static func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw Failure.failed(message) }
        return value
    }

    private static func requireValue<T>(_ value: T?, _ message: String) throws -> T {
        try require(value, message)
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure.failed(message) }
    }

    private enum Failure: Error { case failed(String) }
}
