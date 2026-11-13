import DeviceBridgeCore
import Foundation

/// Executes the production VM, channel and ClipboardService with synthetic process
/// responses only. It never starts HDC, reads a system clipboard, or touches a phone.
@main
struct HarmonyClipboardWorkspaceChecks {
    @MainActor static func main() async throws {
        let runner = HarmonyClipboardWorkspaceRunner()
        let model = WorkspaceViewModel(arguments: [], runner: runner,
            hdcToolResolver: { _ in .available(URL(fileURLWithPath: "/synthetic-hdc/hdc")) })
        defer { model.stop() }
        model.start()
        try await wait { !model.isRefreshing && model.devices.filter { $0.identity.platform == .harmonyOS }.count == 2 }
        let phones = model.devices.filter { $0.identity.platform == .harmonyOS }
        model.select(phones[0].identity)
        try await wait { !model.isSelecting && model.selectedDeviceIdentity == phones[0].identity }
        guard case .availableOnDemand = model.clipboardReadiness else { throw Failure.failed("Harmony clipboard must be available only on explicit demand") }
        try require(model.canStartClipboardOperation, "on-demand Harmony action must be enabled")
        let initialCounts = await runner.counts()
        try require(initialCounts.content == 0 && initialCounts.capability == 0,
                    "connecting or selecting must not probe or access clipboard")
        try require(model.clipboardText.isEmpty, "selection populated clipboard content without a read action")
        try require(model.clipboardMaximumWriteUTF8Bytes == HarmonyClipboardChannel.maximumWriteUTF8Bytes,
                    "UI limit does not match the platform channel")
        // The first synthetic help response is unavailable. It must not turn a
        // healthy selection into a disabled-control dead end or read content.
        model.requestClipboardRead()
        try await wait { !model.isClipboardBusy }
        guard case .availableOnDemand = model.clipboardReadiness else { throw Failure.failed("failed probe disabled explicit recovery") }
        try require(model.canStartClipboardOperation && model.clipboardText.isEmpty,
                    "failed probe must remain retryable without reading content")
        try require(await runner.contentCommands == 0, "failed probe accessed clipboard content")
        model.requestClipboardRead()
        try await wait { !model.isClipboardBusy }
        try require(model.clipboardFeedback == "Read" && model.clipboardText == HarmonyClipboardWorkspaceRunner.initialText,
                    "explicit read failed or trimmed the clipboard's whitespace")
        let firstReadCounts = await runner.counts()
        try require(firstReadCounts.content == 1 && firstReadCounts.capability == 3,
                    "explicit read must run capability probes once, then one content command")
        model.clipboardText = "  中文🙂 ' \" $(echo not-a-command) `literal` ; \\ \n\r\n"
        let written = model.clipboardText
        model.requestClipboardSend()
        try await wait { !model.isClipboardBusy }
        try require(model.clipboardFeedback == "Sent", "explicit Harmony write did not complete")
        model.clipboardText = ""
        model.requestClipboardRead()
        try await wait { !model.isClipboardBusy }
        try require(model.clipboardText == written && model.clipboardFeedback == "Read",
                    "production VM/channel/service synthetic round trip changed text")
        try require(await runner.capabilityCommands == 3, "prepared channel probed again unexpectedly")
        let beforeRetry = await runner.counts()
        model.retryHarmonyClipboardSetup()
        let afterRetry = await runner.counts()
        try require(model.clipboardText == written && beforeRetry == afterRetry,
                    "explicit setup reset read/wrote content or discarded the editor")
        guard case .availableOnDemand = model.clipboardReadiness else { throw Failure.failed("setup reset marked an unprobed channel Ready") }
        model.requestClipboardRead()
        try await wait { !model.isClipboardBusy }
        try require(model.clipboardText == written && model.clipboardFeedback == "Read",
                    "explicit action after setup reset did not establish a new channel")
        try require(await runner.capabilityCommands == 5, "setup reset reused the previous channel's cached capabilities")
        await runner.holdNextRead()
        model.requestClipboardRead()
        try await wait { await runner.hasPendingRead }
        model.select(phones[1].identity)
        try await wait { !model.isSelecting && model.selectedDeviceIdentity == phones[1].identity }
        await runner.releaseRead()
        for _ in 0..<100 { await Task.yield() }
        try require(model.clipboardText.isEmpty && model.clipboardFeedback == nil,
                    "late old-device clipboard response leaked into the new selection")
        guard case .availableOnDemand = model.clipboardReadiness else { throw Failure.failed("new selection inherited an old prepared clipboard channel") }
        model.hdcConfigurationDidChange()
        try require(!model.canStartClipboardOperation && model.clipboardText.isEmpty,
                    "changing HDC left a stale clipboard channel or content enabled")
        print("PASS: Harmony clipboard production workspace is explicit-only, UTF-8-preserving, platform-limited, and rejects late old-device/HDC results; synthetic commands only")
    }
    static func require(_ condition: Bool, _ message: String) throws { if !condition { throw Failure.failed(message) } }
    @MainActor static func wait(_ condition: @escaping @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while !(await condition()) {
            if ContinuousClock.now >= deadline { throw Failure.failed("synthetic Harmony workspace timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    enum Failure: Error { case failed(String) }
}

private actor HarmonyClipboardWorkspaceRunner: HostCommandRunning {
    static let initialText = "  DeviceBridge synthetic clipboard\n中文🙂\r\n\n"
    private var text = initialText
    private(set) var contentCommands = 0
    private(set) var capabilityCommands = 0
    private var holdRead = false
    private var failFirstProbe = true
    private var pending: CheckedContinuation<HostCommandResult, Never>?
    var hasPendingRead: Bool { pending != nil }
    func counts() -> (content: Int, capability: Int) { (contentCommands, capabilityCommands) }
    func holdNextRead() { holdRead = true }
    func releaseRead() { pending?.resume(returning: result("Pasteboard text: stale old device\n")); pending = nil }
    func run(_ request: HostCommandRequest) async throws -> HostCommandResult {
        if request.arguments == ["devices", "-l"] { return result("List of devices attached\n") }
        if request.arguments == ["list", "targets", "-v"] {
            return result("HDC-CLIP-1 USB Connected Clipboard One hdc\nHDC-CLIP-2 USB Connected Clipboard Two hdc\n")
        }
        if request.arguments.starts(with: ["devicectl", "list", "devices"]),
           let output = request.arguments.firstIndex(of: "--json-output") {
            try Data("{\"result\":{\"devices\":[]}}".utf8).write(to: URL(fileURLWithPath: request.arguments[output + 1]))
            return result("")
        }
        guard request.arguments.count == 4, request.arguments[0] == "-t",
              ["HDC-CLIP-1", "HDC-CLIP-2"].contains(request.arguments[1]), request.arguments[2] == "shell" else {
            return HostCommandResult(exitCode: 1, standardOutput: Data(), standardError: Data())
        }
        let script = request.arguments[3]
        if script == "echo devicebridge-ready" { return result("devicebridge-ready\n") }
        if script == "testhelper help" {
            capabilityCommands += 1
            if failFirstProbe { failFirstProbe = false; return result("Temporary testhelper failure\n") }
            return result("get-pastedata      Get pasteboard text content\nset-pastedata <text>     Set pasteboard text content\nclear-pastedata    Clear pasteboard content\n")
        }
        if script.contains("testhelper get-pastedata") {
            contentCommands += 1
            if holdRead { holdRead = false; return await withCheckedContinuation { pending = $0 } }
            return result("Pasteboard text: " + text + "\n")
        }
        if script.contains("testhelper set-pastedata") {
            contentCommands += 1
            let start = try require(script.range(of: "printf '%s' '"))
            let tail = script[start.upperBound...]
            let end = try require(tail.firstIndex(of: "'"))
            guard let bytes = Data(base64Encoded: String(tail[..<end])), let decoded = String(data: bytes, encoding: .utf8) else {
                throw HarmonyClipboardWorkspaceChecks.Failure.failed("synthetic write was not safely Base64-encoded")
            }
            text = decoded
            return result("Pasteboard text set successfully.\n")
        }
        if script.contains("DB_CLIPBOARD_TEXT") && script.contains("base64 -d") {
            capabilityCommands += 1
            return HostCommandResult(exitCode: 0, standardOutput: Data(base64Encoded: "RGV2aWNlQnJpZGdlIEhEQyBlbmNvZGluZyBwcm9iZTogJyIgJCgpIGAgOyBcIAoKDQo=")!, standardError: Data())
        }
        throw HarmonyClipboardWorkspaceChecks.Failure.failed("unexpected synthetic HDC command")
    }
    private func require<T>(_ value: T?) throws -> T {
        guard let value else { throw HarmonyClipboardWorkspaceChecks.Failure.failed("synthetic command format changed") }; return value
    }
    private func result(_ value: String) -> HostCommandResult {
        HostCommandResult(exitCode: 0, standardOutput: Data(value.utf8), standardError: Data())
    }
}
