import DeviceBridgeCore
import DeviceBridgeProtocol
import Foundation

@main
struct IOSRunnerWorkspaceChecks {
    @MainActor
    static func main() async throws {
        try await informationBindingLoss()
        try await preparationPresentation()
        try await overlappingContentActions()
        try await unsupportedAndFirstUseBoundaries()
        try await clipboardBinding()
        let channel = WorkspacePhoneChannel()
        let manager = WorkspacePhoneManager(channel: channel)
        let inventory = WorkspacePhoneInventory()
        let model = WorkspaceViewModel(arguments: [], runner: inventory, iosScreenshotRunnerFactory: { _ in manager })
        defer { model.stop() }
        model.start()
        try await wait { !model.isRefreshing && model.devices.count == 1 }
        model.clipboardText = "Previous device text must not survive a new selection"
        model.select(model.devices[0].identity)
        try require(model.clipboardText.isEmpty, "selection must synchronously clear the previous device clipboard text")
        try await wait { !model.isSelecting }
        try require(await manager.device == nil, "selection must not prepare or foreground the iOS runner")
        try require(await channel.contentRequests == 0, "selection must not read phone content")
        model.requestScreenshotCapture()
        try await wait { !model.isCapturingScreenshot && model.currentScreenshotArtifact != nil }
        try require(model.isScreenshotReady, "qualified screenshot must be usable independently of clipboard")
        try require(model.clipboardReadinessText == "Available on demand",
            "screenshot qualification must leave clipboard independently available on demand")
        try require(await manager.device == "workspace-test-udid", "launch must use stable UDID, not CoreDevice route ID")
        let artifact = try model.currentScreenshotArtifact.unwrap("explicit capture did not publish an artifact")
        try require(try Data(contentsOf: artifact.sessionURL) == WorkspacePhoneChannel.png,
            "preview must retain the exact screenshot bytes")
        try require(artifact.sourceDevice == model.selectedDeviceIdentity, "screenshot attributed to wrong device")
        try await wait(seconds: 12) { await channel.heartbeats >= 2 }
        try require(await channel.contentRequests == 1, "heartbeat must not read content")
        await channel.holdCapture()
        model.requestScreenshotCapture()
        try await wait { await channel.hasPendingCapture }
        model.stopIOSRunner()
        try require(!model.isScreenshotReady, "Stop must synchronously invalidate screenshot readiness")
        try require(model.isFileTransferReady, "explicit runner Stop must preserve independent file service")
        await channel.releaseCapture()
        try await wait { await manager.stops > 0 }
        try require(model.currentScreenshotArtifact == nil, "late screenshot published after Stop")
        try await wait { !FileManager.default.fileExists(atPath: artifact.sessionURL.path) }

        let routeChannel = WorkspacePhoneChannel(clipboardAvailable: true)
        let routeManager = WorkspacePhoneManager(channel: routeChannel)
        let routeClipboardManager = WorkspacePhoneManager(channel: routeChannel)
        let routeInventory = WorkspacePhoneInventory()
        let routeModel = WorkspaceViewModel(arguments: [], runner: routeInventory,
            iosScreenshotRunnerFactory: { _ in routeManager },
            iosClipboardHostFactory: { _ in routeClipboardManager })
        defer { routeModel.stop() }
        routeModel.start()
        try await wait { !routeModel.isRefreshing && routeModel.devices.count == 1 }
        routeModel.select(routeModel.devices[0].identity)
        try await wait { !routeModel.isSelecting }
        routeModel.reconnectIOSPreparation(.screenshot)
        routeModel.reconnectIOSPreparation(.clipboard)
        try await wait { routeModel.isScreenshotReady && routeModel.clipboardReadiness == .ready }
        try require(routeModel.isClipboardReady, "route check must start with a qualified clipboard")
        await routeInventory.changeRoute()
        routeModel.requestRefresh()
        try await wait { !routeModel.isRefreshing }
        try require(!routeModel.isScreenshotReady, "inventory route replacement retained stale screenshot channel")
        try require(!routeModel.isClipboardReady, "inventory route replacement retained stale clipboard channel")
        try await wait { await routeManager.stops > 0 }

        let failedChannel = WorkspacePhoneChannel(clipboardAvailable: true)
        let failedManager = WorkspacePhoneManager(channel: failedChannel)
        let failedClipboardManager = WorkspacePhoneManager(channel: failedChannel)
        let failedModel = WorkspaceViewModel(arguments: [], runner: WorkspacePhoneInventory(),
            iosScreenshotRunnerFactory: { _ in failedManager },
            iosClipboardHostFactory: { _ in failedClipboardManager })
        defer { failedModel.stop() }
        failedModel.start()
        try await wait { !failedModel.isRefreshing && failedModel.devices.count == 1 }
        failedModel.select(failedModel.devices[0].identity)
        try await wait { !failedModel.isSelecting }
        failedModel.reconnectIOSPreparation(.screenshot)
        failedModel.reconnectIOSPreparation(.clipboard)
        try await wait { failedModel.isScreenshotReady && failedModel.clipboardReadiness == .ready }
        await failedChannel.failNextClipboard(.permissionDenied)
        failedModel.requestClipboardRead()
        try await wait { !failedModel.isClipboardBusy }
        try require(failedModel.clipboardRecoveryAction != nil, "failure must establish advice before heartbeat invalidation")
        await failedChannel.failHeartbeat()
        try await wait(seconds: 12) { !failedModel.isScreenshotReady }
        try require(!failedModel.isClipboardReady, "failed heartbeat retained clipboard readiness")
        try require(failedModel.clipboardRecoveryAction == nil, "failed heartbeat retained stale recovery advice")
        try require(failedModel.isFileTransferReady, "runner failure disabled independently available file service")
        try require(!failedModel.isConnectionMaintained, "expired channel still advertised maintenance")
        try await wait { await failedManager.stops > 0 }
        print("PASS: iOS Workspace screenshot isolation, exact capture, stable device binding, metadata-only 10-second renewal, route invalidation, failed heartbeat, Stop and late completion")
    }

    @MainActor
    static func informationBindingLoss() async throws {
        let channel = WorkspacePhoneChannel(clipboardAvailable: true)
        let screenshotManager = WorkspacePhoneManager(channel: channel)
        let model = WorkspaceViewModel(arguments: [], runner: WorkspacePhoneInventory(),
            iosScreenshotRunnerFactory: { _ in screenshotManager })
        defer { model.stop() }
        model.start()
        try await wait { !model.isRefreshing && model.devices.count == 1 }
        model.select(model.devices[0].identity)
        try await wait { !model.isSelecting }
        try require(await screenshotManager.device == nil, "selection must keep the runner dormant")
        model.reconnectIOSPreparation(.screenshot)
        try await wait { model.screenshotReadiness == .ready && model.deviceInformation.canRead }
        try require(model.deviceInformation.report == nil, "selection must not automatically collect parameters")
        model.deviceInformation.read()
        try await wait { !model.deviceInformation.isBusy }
        let report = try model.deviceInformation.report.unwrap("information read did not publish")
        try require(report.deviceName == "Test iPhone", "runner metadata replaced CoreDevice device name")
        try require(report.sections.flatMap(\.fields).contains { $0.id == "screen.physicalWidth" && $0.value == .integer(1170) },
            "runtime screen field was not merged")
        await channel.holdInformation()
        model.deviceInformation.read()
        try await wait { await channel.hasPendingInformation }
        model.deviceInformation.cancel()
        await channel.loseInformationBinding()
        try await wait { !model.isScreenshotReady }
        try require(model.clipboardReadinessText == "Available on demand",
            "screenshot binding loss must not invalidate the independent clipboard owner")
        try require(await channel.hasPendingInformation, "fixture must retain cleanup while readiness is withdrawn")
        await channel.releaseInformation()
        try await wait { !model.deviceInformation.isBusy }
        try require(model.deviceInformation.operation?.state == .cancelled,
            "late metadata overwrote cancellation")
        try require(model.deviceInformation.report?.id == report.id,
            "failed refresh replaced the last complete snapshot")
        print("PASS: metadata publication, no automatic read, CoreDevice naming, binding loss before pending cleanup and cancellation")
    }

    @MainActor
    static func preparationPresentation() async throws {
        let manager = WorkspacePreparingManager()
        let model = WorkspaceViewModel(arguments: [], runner: WorkspacePhoneInventory(), iosScreenshotRunnerFactory: { _ in manager })
        defer { model.stop() }
        model.start()
        try await wait { !model.isRefreshing && model.devices.count == 1 }
        model.select(model.devices[0].identity)
        try await wait { !model.isSelecting }
        try require(!model.isCapturingScreenshot && model.screenshotReadiness != .preparing,
            "selection must publish on-demand availability without beginning preparation")
        model.requestScreenshotCapture()
        try await wait { await manager.entered }
        try require(model.screenshotReadinessText == "Preparing…", "normal iOS preparation must not be shown as Action required")
        try require(model.clipboardReadiness == .availableOnDemand(
            "The iOS clipboard Host starts only after an explicit clipboard action."),
            "screenshot preparation must not mutate clipboard lifecycle state")
        try require(!model.isScreenshotReady && !model.isClipboardReady,
            "the current screenshot action must temporarily exclude a clipboard content action")
        try require(model.isFileTransferReady, "screenshot preparation must preserve independent file access")
        try require(model.iosRunnerPreparation?.state == .preparing(.building), "screenshot progress must begin in the build stage")
        await manager.setPreparationState(.starting)
        try await wait { model.iosRunnerPreparation?.state == .preparing(.starting) }
        await manager.holdNextObservation()
        try await wait { await manager.observationHeld }
        model.stopIOSRunner()
        try require(model.iosRunnerPreparation?.state == .stopped, "Stop must immediately end visible preparation")
        await manager.releaseObservation()
        await manager.release()
        try await wait { await manager.stops > 0 }
        try await Task.sleep(for: .milliseconds(300))
        try require(!model.isScreenshotReady && model.isClipboardReady, "late screenshot preparation after Stop cannot grant screenshot readiness or revoke clipboard admission")
        try require(model.iosRunnerPreparation?.state == .stopped, "late progress observation must not undo Stop")
        try require(model.iosRunnerPreparation?.finishedAt != nil, "stopped progress must freeze elapsed time")

        let next = WorkspacePreparingManager()
        let success = WorkspaceViewModel(arguments: [], runner: WorkspacePhoneInventory(), iosScreenshotRunnerFactory: { _ in next })
        defer { success.stop() }
        success.start()
        try await wait { !success.isRefreshing && success.devices.count == 1 }
        success.select(success.devices[0].identity)
        try await wait { !success.isSelecting }
        success.requestScreenshotCapture()
        try await wait { await next.entered }
        await next.setPreparationState(.connected)
        try await Task.sleep(for: .milliseconds(300))
        try require(success.iosRunnerPreparation?.isPreparing == true, "manager connected observation must not finish before authenticated binding")
        await next.release()
        try await wait { success.isScreenshotReady }
        try require(success.iosRunnerPreparation?.state == .ready && success.iosRunnerPreparation?.finishedAt != nil,
            "authenticated binding must finish screenshot progress")
        print("PASS: true preparation stages, no premature readiness, frozen completion, cancellation and stale observer rejection")
    }

    @MainActor
    static func overlappingContentActions() async throws {
        let channel = WorkspacePhoneChannel(clipboardAvailable: true)
        let screenshotManager = WorkspacePhoneManager(channel: channel)
        let clipboardManager = WorkspacePhoneManager(channel: channel)
        let model = WorkspaceViewModel(arguments: [], runner: WorkspacePhoneInventory(),
            iosScreenshotRunnerFactory: { _ in screenshotManager },
            iosClipboardHostFactory: { _ in clipboardManager })
        defer { model.stop() }
        model.start()
        try await wait { !model.isRefreshing && model.devices.count == 1 }
        model.select(model.devices[0].identity)
        try await wait { !model.isSelecting }
        model.reconnectIOSPreparation(.screenshot)
        model.reconnectIOSPreparation(.clipboard)
        try await wait { model.screenshotReadiness == .ready && model.clipboardReadiness == .ready }
        await channel.holdRead()
        model.requestClipboardRead()
        try await wait { await channel.hasPendingRead }
        model.requestScreenshotCapture()
        try require(!model.isCapturingScreenshot, "iOS screenshot must not enter the shared content slot during a clipboard read")
        await channel.releaseRead()
        try await wait { !model.isClipboardBusy }
        await channel.holdCapture()
        model.requestScreenshotCapture()
        try await wait { await channel.hasPendingCapture }
        model.requestClipboardRead()
        try require(!model.isClipboardBusy, "iOS clipboard read must not enter the shared content slot during a screenshot")
        model.requestClipboardSend()
        try require(!model.isClipboardBusy, "keyboard send must obey the same iOS content admission gate")
        await channel.releaseCapture()
        try await wait { !model.isCapturingScreenshot }
        try require(await channel.contentRequests == 2, "overlapping content must be rejected before reaching the channel")
        print("PASS: iOS clipboard and screenshot use independent admission gates without blocking metadata")
    }

    @MainActor
    static func unsupportedAndFirstUseBoundaries() async throws {
        let channel = WorkspacePhoneChannel(clipboardAvailable: true)
        let manager = WorkspacePhoneManager(channel: channel)
        let wireless = WorkspaceViewModel(arguments: [],
            runner: WorkspacePhoneInventory(transportType: "network"),
            iosScreenshotRunnerFactory: { _ in manager })
        defer { wireless.stop() }
        wireless.start()
        try await wait { !wireless.isRefreshing && wireless.devices.count == 1 }
        try require(wireless.devices[0].candidates.allSatisfy { $0.kind == .wifi },
            "wireless boundary fixture must actually parse as Wi-Fi")
        wireless.select(wireless.devices[0].identity)
        try await wait { !wireless.isSelecting }
        try require(!wireless.isScreenshotReady && !wireless.isClipboardReady,
            "unsupported Wi-Fi must not publish USB capability readiness")
        try require(wireless.screenshotReadiness == .actionRequired("iOS screenshots currently require a trusted USB connection and Xcode."),
            "wireless screenshot must explain the supported USB boundary")
        try require(wireless.clipboardReadiness == .actionRequired("iOS clipboard currently requires a trusted USB connection and Xcode."),
            "wireless clipboard must explain the supported USB boundary")
        try require(await manager.device == nil, "wireless selection must not launch a USB runner")
        try require(await channel.contentRequests == 0, "unsupported selection must not access content")

        for failure in [IOSRunnerSourceConfigurationError.signingTeamRequired,
                        .bundleMissing, .invalidManifest, .sourcesMissing, .unsafePath] {
            let model = WorkspaceViewModel(arguments: [], runner: WorkspacePhoneInventory(),
                iosScreenshotRunnerFactory: { _ in throw failure })
            defer { model.stop() }
            model.start()
            try await wait { !model.isRefreshing && model.devices.count == 1 }
            model.select(model.devices[0].identity)
            try await wait { !model.isSelecting }
            model.requestScreenshotCapture()
            try await wait { !model.isCapturingScreenshot }
            let expected = failure == .signingTeamRequired
                ? "Set your existing Apple development Team ID in Settings, then retry iOS tools."
                : "The bundled iOS runner sources are missing or invalid. Rebuild the Debug app and retry."
            try require(model.screenshotReadiness == .actionRequired(expected)
                && model.clipboardReadinessText == "Available on demand",
                "screenshot preparation failure must not overwrite clipboard readiness")
            try require(!model.isScreenshotReady && model.isClipboardReady,
                "failed screenshot preparation must not publish screenshot readiness or revoke clipboard admission")
            try require(model.isFileTransferReady,
                "runner configuration failure must preserve independent file readiness")
            if case .failed = model.iosRunnerPreparation?.state { }
            else { throw Failure.failed("configuration failure must terminate the visible progress") }
        }
        print("PASS: unsupported Wi-Fi rejects USB runner launch/content; five first-use configuration failures preserve recovery advice and independent files")
    }

    @MainActor
    static func clipboardBinding() async throws {
        let channel = WorkspacePhoneChannel(clipboardAvailable: true)
        let manager = WorkspacePhoneManager(channel: channel)
        let model = WorkspaceViewModel(arguments: [], runner: WorkspacePhoneInventory(),
            iosClipboardHostFactory: { _ in manager })
        defer { model.stop() }
        model.start()
        try await wait { !model.isRefreshing && model.devices.count == 1 }
        model.select(model.devices[0].identity)
        try await wait { !model.isSelecting }
        try require(await manager.device == nil, "selection must not prepare the runner")
        try require(await channel.contentRequests == 0, "selection must not access clipboard content")
        model.reconnectIOSPreparation(.clipboard)
        try await wait { model.clipboardReadiness == .ready }
        try require(model.isClipboardReady, "authenticated clipboard Host must enable the selected USB session")
        try require(model.screenshotReadinessText == "Available on demand",
            "clipboard preparation must not mutate screenshot readiness")
        try require(await channel.contentRequests == 0, "preparation must not access clipboard content")
        for (status, expectedRecovery) in [
            (HelperResultStatus.permissionDenied, "Review the device clipboard privacy prompt, then retry."),
            (.expired, "Check the connection and retry.")
        ] {
            await channel.failNextClipboard(status)
            let before = await channel.contentRequests
            model.requestClipboardRead()
            try await wait { !model.isClipboardBusy }
            try require(model.clipboardRecoveryAction == expectedRecovery, "clipboard failure must publish its classified recovery action")
            try require(model.clipboardFeedback?.contains("untrusted secret") == false, "arbitrary helper error text must never reach feedback")
            try require(model.clipboardText.isEmpty, "failed read must not publish a payload")
            try await Task.sleep(for: .milliseconds(50))
            try require(await channel.contentRequests == before + 1, "failure must not silently retry clipboard access")
        }
        model.requestClipboardRead()
        try require(model.clipboardRecoveryAction == nil, "explicit retry must synchronously clear obsolete recovery")
        try await wait { !model.isClipboardBusy }
        try require(model.clipboardText == "Whole clipboard 📋\n第二行", "explicit read must publish complete Unicode content")
        try require(model.clipboardRecoveryAction == nil, "successful read must not retain failure advice")
        model.clipboardText = "Mac to phone 📱\ncomplete text"
        model.requestClipboardSend()
        try await wait { !model.isClipboardBusy }
        model.clipboardText = ""
        model.requestClipboardRead()
        try await wait { !model.isClipboardBusy }
        try require(model.clipboardText == "Mac to phone 📱\ncomplete text", "write must use the same device-bound channel")
        await channel.failNextClipboard(.permissionDenied)
        model.requestClipboardRead()
        try await wait { !model.isClipboardBusy }
        try require(model.clipboardRecoveryAction != nil, "failure must establish advice before selection invalidation")
        let sameSessionGeneration = model.clipboardExportGeneration
        model.select(model.devices[0].identity)
        try require(!model.isSelecting && model.clipboardExportGeneration == sameSessionGeneration,
            "healthy same-device selection must not recreate the session")
        try require(model.clipboardRecoveryAction != nil,
            "same-device no-op must not pretend that capability recovery occurred")
        model.requestClipboardRead()
        try await wait { !model.isClipboardBusy }
        try require(model.clipboardRecoveryAction == nil, "explicit retry must clear stale recovery advice")
        await channel.holdRead()
        model.requestClipboardRead()
        try await wait { await channel.hasPendingRead }
        let exportGeneration = model.clipboardExportGeneration
        model.stopIOSRunner()
        try require(!model.isClipboardReady && !model.isClipboardBusy, "Stop must immediately invalidate clipboard actions")
        try require(model.clipboardExportGeneration > exportGeneration, "Stop must invalidate pending clipboard exports")
        try require(model.isFileTransferReady, "clipboard Stop must preserve independent file service")
        await channel.releaseRead()
        try await wait { await manager.stops > 0 }
        try await Task.sleep(for: .milliseconds(50))
        try require(model.clipboardText.isEmpty && model.clipboardFeedback == nil, "late read must not republish after Stop")
        let requests = await channel.contentRequests
        model.requestClipboardRead()
        model.requestClipboardSend()
        try await Task.sleep(for: .milliseconds(20))
        try require(await channel.contentRequests == requests, "stopped clipboard must reject new content requests")
        print("PASS: Workspace explicit clipboard read/write, classified failure recovery without auto-retry, no automatic content access, Stop/export invalidation and late read rejection")
    }

    @MainActor
    static func wait(seconds: Int = 3, _ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
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

private actor WorkspacePreparingManager: IOSRunnerManaging {
    private(set) var entered = false
    private(set) var stops = 0
    private var continuation: CheckedContinuation<Void, Never>?
    private var observedState: IOSRunnerState = .building
    private var holdObservation = false
    private var observation: CheckedContinuation<IOSRunnerState?, Never>?
    var observationHeld: Bool { observation != nil }
    func setPreparationState(_ value: IOSRunnerState) { observedState = value }
    func holdNextObservation() { holdObservation = true }
    func releaseObservation() { observation?.resume(returning: .starting); observation = nil }
    func preparationState() async -> IOSRunnerState? {
        if holdObservation {
            holdObservation = false
            return await withCheckedContinuation { observation = $0 }
        }
        return observedState
    }
    func prepare(deviceIdentifier: String) async -> IOSRunnerPreparationOutcome {
        entered = true
        await withCheckedContinuation { continuation = $0 }
        return IOSRunnerPreparationOutcome(channel: WorkspacePhoneChannel(clipboardAvailable: true))
    }
    func release() { continuation?.resume(); continuation = nil }
    func stop() { stops += 1 }
}

private actor WorkspacePhoneManager: IOSRunnerManaging {
    let channel: WorkspacePhoneChannel
    private(set) var device: String?
    private(set) var stops = 0
    init(channel: WorkspacePhoneChannel) { self.channel = channel }
    func prepare(deviceIdentifier: String) async -> IOSRunnerPreparationOutcome {
        device = deviceIdentifier
        return IOSRunnerPreparationOutcome(channel: channel)
    }
    func stop() { stops += 1 }
}

private actor WorkspacePhoneChannel: IOSRunnerScreenshotChannel, IOSRunnerClipboardChannel, IOSRunnerDeviceInformationChannel {
    nonisolated let launchID = UUID()
    private var informationInvalidation: (@Sendable (UUID) -> Void)?
    private var holdingInformation = false
    private var pendingInformation: CheckedContinuation<Void, Never>?
    var hasPendingInformation: Bool { pendingInformation != nil }
    func holdInformation() { holdingInformation = true }
    func releaseInformation() { pendingInformation?.resume(); pendingInformation = nil }
    func loseInformationBinding() { informationInvalidation?(launchID) }
    func authenticatedDeviceInformationContext() -> HelperSessionContext { context }
    func registerInvalidationHandler(_ handler: @escaping @Sendable (UUID) -> Void) { informationInvalidation = handler }

    static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j1ioAAAAASUVORK5CYII=")!
    private(set) var contentRequests = 0
    private(set) var heartbeats = 0
    private var holdingCapture = false
    private var pendingCapture: CheckedContinuation<Void, Never>?
    private var heartbeatFails = false
    private let clipboardAvailable: Bool
    private var clipboardText = "Whole clipboard 📋\n第二行"
    private var holdingRead = false
    private var pendingRead: CheckedContinuation<Void, Never>?
    private var nextClipboardFailure: HelperResultStatus?
    func failNextClipboard(_ status: HelperResultStatus) { nextClipboardFailure = status }
    init(clipboardAvailable: Bool = false) { self.clipboardAvailable = clipboardAvailable }
    var hasPendingRead: Bool { pendingRead != nil }
    func holdRead() { holdingRead = true }
    func releaseRead() { pendingRead?.resume(); pendingRead = nil }
    func authenticatedClipboardContext() throws -> HelperSessionContext {
        guard clipboardAvailable else { throw IOSRunnerChannel.Failure.unavailable }
        return context
    }
    var hasPendingCapture: Bool { pendingCapture != nil }
    func holdCapture() { holdingCapture = true }
    func releaseCapture() { pendingCapture?.resume(); pendingCapture = nil }
    func failHeartbeat() { heartbeatFails = true }
    var context: HelperSessionContext { HelperSessionContext(sessionNonce: "synthetic-workspace-nonce",
        helperDeviceID: launchID.uuidString, helperVersion: "1") }
    func authenticatedScreenshotContext() -> HelperSessionContext { context }
    func captureScreenshot(_ request: HelperRequest) async throws -> ScreenshotCapturePayload {
        guard request.action == .screenshotCapture, request.helperDeviceID == context.helperDeviceID,
              request.sessionNonce == context.sessionNonce else { throw IOSRunnerChannel.Failure.invalidRequest }
        contentRequests += 1
        if holdingCapture { await withCheckedContinuation { pendingCapture = $0 } }
        return ScreenshotCapturePayload(data: Self.png, capturedAt: Date())
    }
    func send(_ request: HelperRequest) async throws -> HelperResult {
        guard request.sessionNonce == context.sessionNonce,
              request.helperDeviceID == context.helperDeviceID else {
            contentRequests += 1
            throw IOSRunnerChannel.Failure.invalidRequest
        }
        if request.action == .deviceInformation {
            contentRequests += 1
            if holdingInformation { await withCheckedContinuation { pendingInformation = $0 } }
            return HelperResult(requestID: request.requestID, status: .success, completedAt: Date(), payload: [
                "systemName": .string("iOS"), "systemVersion": .string("18.3.1"), "modelIdentifier": .string("iPhone-test"),
                "processorCount": .number(6), "physicalMemoryBytes": .number(6_442_450_944),
                "screenWidthPixels": .number(1170), "screenHeightPixels": .number(2532),
                "screenWidthPoints": .number(390), "screenHeightPoints": .number(844),
                "screenCoordinateBasis": .string("fixedPortrait"), "screenScale": .number(3), "screenNativeScale": .number(3),
                "maximumFramesPerSecond": .number(60), "totalStorageBytes": .null, "availableStorageBytes": .null,
                "batteryLevel": .null, "batteryState": .string("unknown")])
        }
        if clipboardAvailable, request.action == .clipboardRead || request.action == .clipboardWrite {
            contentRequests += 1
            if let failure = nextClipboardFailure {
                nextClipboardFailure = nil
                return HelperResult(requestID: request.requestID, status: failure, completedAt: Date(),
                    error: HelperErrorPayload(code: "synthetic-failure", message: "untrusted secret must not be displayed"))
            }
            if request.action == .clipboardRead, holdingRead {
                await withCheckedContinuation { pendingRead = $0 }
            }
            if request.action == .clipboardWrite {
                guard let text = request.payload["text"]?.stringValue else { throw IOSRunnerChannel.Failure.invalidRequest }
                clipboardText = text
            }
            return HelperResult(requestID: request.requestID, status: .success, completedAt: Date(),
                payload: request.action == .clipboardRead ? ["text": .string(clipboardText)] : [:])
        }
        guard request.action == .identity else { throw IOSRunnerChannel.Failure.invalidRequest }
        heartbeats += 1
        if heartbeatFails { throw IOSRunnerChannel.Failure.unavailable }
        return HelperResult(requestID: request.requestID, status: .success, completedAt: Date(), payload: [
            "helperDeviceId": .string(context.helperDeviceID),
            "helperVersion": .string(context.helperVersion), "protocolVersions": .array([.number(1)])
        ])
    }
}

private actor WorkspacePhoneInventory: HostCommandRunning {
    private var route = "11111111-1111-4111-8111-111111111111"
    private let transportType: String
    init(transportType: String = "wired") { self.transportType = transportType }
    func changeRoute() { route = "22222222-2222-4222-8222-222222222222" }
    func run(_ request: HostCommandRequest) throws -> HostCommandResult {
        if request.arguments == ["devices", "-l"] {
            return HostCommandResult(exitCode: 0, standardOutput: Data("List of devices attached\n".utf8), standardError: Data())
        }
        if request.arguments.starts(with: ["devicectl", "list", "devices"]),
           let index = request.arguments.firstIndex(of: "--json-output") {
            let json = #"{"result":{"devices":[{"identifier":"workspace-coredevice-route","hardwareProperties":{"udid":"workspace-test-udid","platform":"iOS","marketingName":"Test iPhone"},"connectionProperties":{"transportType":"wired","pairingState":"paired","tunnelState":"connected"},"deviceProperties":{"name":"Test iPhone","osVersionNumber":"18.3.1","developerModeStatus":"enabled","isLocked":false}}]}}"#
            try Data(json.replacingOccurrences(of: "workspace-coredevice-route", with: route)
                .replacingOccurrences(of: "\"transportType\":\"wired\"", with: "\"transportType\":\"\(transportType)\"").utf8)
                .write(to: URL(fileURLWithPath: request.arguments[index + 1]))
        } else if request.arguments.starts(with: ["devicectl", "device", "info", "details"]),
                  let index = request.arguments.firstIndex(of: "--json-output") {
            let details: [String: Any] = ["info": ["outcome": "success"], "result": [
                "identifier": route,
                "hardwareProperties": ["udid": "workspace-test-udid", "platform": "iOS", "reality": "physical", "marketingName": "Test iPhone"],
                "deviceProperties": ["name": "Test iPhone", "osVersionNumber": "18.3.1"],
                "connectionProperties": ["transportType": transportType, "pairingState": "paired"]]]
            try JSONSerialization.data(withJSONObject: details).write(to: URL(fileURLWithPath: request.arguments[index + 1]))
        } else if !request.arguments.starts(with: ["devicectl", "device", "info", "details"]) {
            throw IOSRunnerWorkspaceChecks.Failure.failed("unexpected external command")
        }
        return HostCommandResult(exitCode: 0, standardOutput: Data(), standardError: Data())
    }
}

private extension Optional {
    func unwrap(_ message: String) throws -> Wrapped {
        guard let self else { throw IOSRunnerWorkspaceChecks.Failure.failed(message) }
        return self
    }
}
