import DeviceBridgeProtocol
import AppKit
import DeviceBridgeCore
import Combine
import Foundation
import Security

enum CapabilityReadiness: Equatable {
    case idle
    case availableOnDemand(String)
    case preparing
    case ready
    case actionRequired(String)
}

struct CapabilityActionPresentation: Equatable {
    let statusText: String
    let detail: String?
    let canStart: Bool
}

private struct SessionCapabilityState: Equatable {
    let selectionRevision: Int
    let readiness: CapabilityReadiness
}

/// A clicked candidate is visible immediately; only DeviceSessionStore can commit a connection.
enum DeviceSelectionPresentation {
    case checking(DeviceRecord)
    case failed(DeviceRecord, OperationFailure)

    var device: DeviceRecord {
        switch self {
        case let .checking(device), let .failed(device, _): device
        }
    }
    var isChecking: Bool {
        if case .checking = self { return true }
        return false
    }
}

/// A display-only projection of the current selected session. It cannot authorize device actions.
struct IOSPreparationPresentation {
    enum Owner: String, Identifiable { case clipboard, screenshot; var id: String { rawValue } }
    enum Stage: Int { case building = 1, starting = 2 }
    enum State: Equatable {
        case preparing(Stage)
        case ready
        case failed(Stage, String, String?)
        case stopped
    }
    let id = UUID()
    let owner: Owner
    let startedAt = ContinuousClock.now
    var state: State = .preparing(.building)
    private(set) var finishedAt: ContinuousClock.Instant?

    init(owner: Owner) { self.owner = owner }

    var isPreparing: Bool {
        if case .preparing = state { return true }
        return false
    }
    var stage: Stage {
        switch state {
        case let .preparing(stage), let .failed(stage, _, _): stage
        case .ready: .starting
        case .stopped: .building
        }
    }
    var elapsedSeconds: Int { max(0, Int(startedAt.duration(to: finishedAt ?? .now).components.seconds)) }
    mutating func finish(_ state: State) {
        self.state = state
        finishedAt = .now
    }
}

/// Device-facing metadata boundary. Workspace remains the selection and publication owner.
protocol IOSWorkspaceVMProviding: Sendable {
    func applications(session: ConnectionSession) async throws -> [TargetApplication]
    func binding(store: DeviceSessionStore, session: ConnectionSession, applicationID: String) async throws -> IOSVerifiedVMBinding
}

struct NativeIOSWorkspaceVMProvider: IOSWorkspaceVMProviding {
    func applications(session: ConnectionSession) async throws -> [TargetApplication] {
        try await IOSApplicationProcessProvider().load(session: session).applications.map(\.target)
    }
    func binding(store: DeviceSessionStore, session: ConnectionSession, applicationID: String) async throws -> IOSVerifiedVMBinding {
        try await IOSFlutterVMDiscovery(sessionStore: store).discover(session: session, applicationID: applicationID)
    }
}

@MainActor
final class WorkspaceViewModel: ObservableObject, AgentAPIWorkspace {
    @Published private(set) var devices: [DeviceRecord] = []
    @Published private(set) var selectedDeviceIdentity: DeviceIdentity?
    @Published private(set) var isRefreshing = false
    @Published private(set) var isSelecting = false
    @Published private(set) var deviceSelection: DeviceSelectionPresentation?
    @Published private(set) var connectionHealth: ConnectionHealthState = .starting
    @Published private(set) var lastSuccessfulCommandAt: Date?
    @Published private(set) var diagnostics: [String] = []
    @Published private var clipboardCapabilityState = SessionCapabilityState(
        selectionRevision: 0, readiness: .idle)
    @Published var clipboardText = ""
    @Published private(set) var clipboardFeedback: String?
    @Published private(set) var clipboardRecoveryAction: String?
    @Published private(set) var isClipboardBusy = false
    @Published private var screenshotCapabilityState = SessionCapabilityState(
        selectionRevision: 0, readiness: .idle)
    @Published private(set) var iosRunnerPreparation: IOSPreparationPresentation?
    @Published private(set) var iosClipboardPreparation: IOSPreparationPresentation?
    @Published private(set) var currentScreenshotArtifact: ScreenshotArtifact?
    @Published private(set) var screenshotFeedback: String?
    @Published private(set) var isCapturingScreenshot = false
    @Published private var fileTransferCapabilityState = SessionCapabilityState(
        selectionRevision: 0, readiness: .idle)
    @Published private(set) var fileTransferFeedback: InterfaceMessage?
    @Published private(set) var latestTransferArtifact: TransferArtifact?
    @Published private(set) var isTransferringFile = false
    @Published private(set) var imageBrowser: PhoneImagesViewModel?
    @Published private var memoryCapabilityState = SessionCapabilityState(
        selectionRevision: 0, readiness: .idle)
    @Published private(set) var targetApplications: [TargetApplication] = []
    @Published var selectedMemoryApplicationID: String? {
        didSet {
            if oldValue != selectedMemoryApplicationID, iosMemorySession != nil { prepareIOSMemoryBinding() }
        }
    }
    @Published var vmServiceURIText = ""
    @Published private(set) var memorySamples: [MemorySample] = []
    @Published private(set) var memoryFeedback: InterfaceMessage?
    @Published private(set) var isMonitoringMemory = false
    @Published private(set) var androidKeepAliveState: AndroidKeepAliveControllerState = .idle

    private lazy var agentController = AgentAPIController(workspace: self)
    private var agentIPCServer: AgentIPCServer?
    private var agentIPCStartupTask: Task<Void, Never>?
    private var agentIPCCleanupTask: Task<Void, Never>?
    private enum AndroidCommandOwner {
        case preparing(id: UUID, server: ADBServerConnection)
        case ready(AndroidDeviceCommandBinding)

        var id: UUID {
            switch self {
            case let .preparing(id, _): id
            case let .ready(binding): binding.id
            }
        }
        var server: ADBServerConnection {
            switch self {
            case let .preparing(_, server): server
            case let .ready(binding): binding.server
            }
        }
    }
    private var androidCommandOwner: AndroidCommandOwner?
    private var androidCommandBinding: AndroidDeviceCommandBinding? {
        guard case let .ready(binding) = androidCommandOwner else { return nil }
        return binding
    }
    let androidShell = AndroidShellViewModel()
    private var shellObservation: AnyCancellable?
    let deviceInformation = DeviceInformationViewModel()
    private var informationObservation: AnyCancellable?
    private var informationRunnerChannel: (any IOSRunnerDeviceInformationChannel)?
    private var informationRunnerLaunchID: UUID?

    private let store = DeviceSessionStore()
    private let iosPhotoDiscovery = IOSPhotoDiscovery()
    private let runner: any HostCommandRunning
    private let arguments: [String]
    private let iosScreenshotRunnerFactory: (@Sendable (URL) throws -> any IOSRunnerManaging)?
    private let iosClipboardHostFactory: (@Sendable (URL) throws -> any IOSRunnerManaging)?
    private let iosMemoryProvider: any IOSWorkspaceVMProviding
    private let usesFixtureMemory: Bool
    private var hasStarted = false
    private var refreshTask: Task<Void, Never>?
    private var refreshRevision = 0
    private var selectionTask: Task<Void, Never>?
    private var clipboardOperationTask: Task<Void, Never>?
    private var screenshotOperationTask: Task<Void, Never>?
    private var fileTransferTask: Task<Void, Never>?
    private var memoryPreparationTask: Task<Void, Never>?
    private var memoryPreparationRevision = 0
    private var iosMemorySession: ConnectionSession?
    private var iosMemoryBinding: IOSVerifiedVMBinding?
    private var iosMemoryTask: Task<Void, Never>?
    private var iosMemoryCleanupTask: Task<Void, Never>?
    private var iosMemoryRevision = 0
    private var keepAliveActionTask: Task<Void, Never>?
    private var keepAliveObservationTask: Task<Void, Never>?
    private var adbURL: URL?
    private var xcrunURL: URL?
    private var androidHelperManager: AndroidHelperManager?
    private var iosRunnerManager: (any IOSRunnerManaging)?
    private var iosClipboardManager: (any IOSRunnerManaging)?
    private let iosRunnerBuildWorkspace = IOSRunnerBuildWorkspace(
        rootDirectoryURL: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dev.debugutility.DeviceBridge/IOSRunnerBuilds-v1", isDirectory: true),
        reuseCompletedWorkspaces: true)
    private var iosRunnerSession: ConnectionSession?
    private var iosClipboardSession: ConnectionSession?
    private var iosRunnerHeartbeatTask: Task<Void, Never>?
    private var iosClipboardHeartbeatTask: Task<Void, Never>?
    private var iosRunnerPreparationObservationTask: Task<Void, Never>?
    private var iosClipboardPreparationObservationTask: Task<Void, Never>?
    private var iosRunnerCleanupTask: Task<Void, Never>?
    private var iosClipboardCleanupTask: Task<Void, Never>?
    private var clipboardService: ClipboardService?
    private var screenshotService: ScreenshotService?
    private var fileTransferService: FileTransferService?
    private var osMemorySampler: (any MemorySampling)?
    private var flutterVMDiscovery: AndroidFlutterVMDiscovery?
    private var flutterVMService: FlutterVMService?
    private var memoryMonitor: MemoryMonitor?
    private var discoveredVMURI: URL?
    private var androidKeepAliveController: AndroidKeepAliveController?
    @Published private(set) var isConnectionMaintained = false
    @Published private(set) var connectionRecoveryCount = 0
    @Published private(set) var connectionRecoveryAttempt = 0
    private var maintenance: ConnectionMaintenance?
    private var maintenanceTask: Task<Void, Never>?
    private var inventoryLoopTask: Task<Void, Never>?
    private var helperContext: HelperSessionContext?
    private var selectionRevision = 0
    private(set) var clipboardExportGeneration = 0
    private var fixtureRecoveryTransport: WorkspaceRecoveryTransport?

    private(set) var clipboardReadiness: CapabilityReadiness {
        get { clipboardCapabilityState.selectionRevision == selectionRevision
            ? clipboardCapabilityState.readiness : .idle }
        set { clipboardCapabilityState = SessionCapabilityState(
            selectionRevision: selectionRevision, readiness: newValue) }
    }

    private(set) var screenshotReadiness: CapabilityReadiness {
        get { screenshotCapabilityState.selectionRevision == selectionRevision
            ? screenshotCapabilityState.readiness : .idle }
        set { screenshotCapabilityState = SessionCapabilityState(
            selectionRevision: selectionRevision, readiness: newValue) }
    }

    private(set) var fileTransferReadiness: CapabilityReadiness {
        get { fileTransferCapabilityState.selectionRevision == selectionRevision
            ? fileTransferCapabilityState.readiness : .idle }
        set { fileTransferCapabilityState = SessionCapabilityState(
            selectionRevision: selectionRevision, readiness: newValue) }
    }

    private(set) var memoryReadiness: CapabilityReadiness {
        get { memoryCapabilityState.selectionRevision == selectionRevision
            ? memoryCapabilityState.readiness : .idle }
        set { memoryCapabilityState = SessionCapabilityState(
            selectionRevision: selectionRevision, readiness: newValue) }
    }

    init(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        runner: any HostCommandRunning = HostCommandRunner(),
        iosScreenshotRunnerFactory: (@Sendable (URL) throws -> any IOSRunnerManaging)? = nil,
        iosClipboardHostFactory: (@Sendable (URL) throws -> any IOSRunnerManaging)? = nil,
        iosMemoryProvider: (any IOSWorkspaceVMProviding)? = nil
    ) {
        self.arguments = arguments
        self.runner = runner
        self.iosScreenshotRunnerFactory = iosScreenshotRunnerFactory
        self.iosClipboardHostFactory = iosClipboardHostFactory
        self.iosMemoryProvider = iosMemoryProvider ?? NativeIOSWorkspaceVMProvider()
        usesFixtureMemory = arguments.contains("--fixture-devices") && iosMemoryProvider == nil
        shellObservation = androidShell.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
        informationObservation = deviceInformation.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
        if arguments.contains("--fixture-devices") {
            devices = Self.fixtureDevices()
        }
    }

    var agentCLIPath: String? {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/devicebridge-agent")
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled.path }
#if DEBUG
        var repository = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { repository.deleteLastPathComponent() }
        let development = repository.appendingPathComponent("packages/DeviceBridgeCore/.build/debug/devicebridge-agent")
        if FileManager.default.isExecutableFile(atPath: development.path) { return development.resolvingSymlinksInPath().path }
#endif
        return nil
    }

    var agentDevice: DeviceRecord? { selectedDevice }
    var agentActionsAllowed: Bool { hasStarted && connectionActionBlock == nil }

    func startAgentAPI() {
        guard agentIPCServer == nil, !arguments.contains("--fixture-devices") else { return }
        let controller = agentController
        let server = AgentIPCServer { [weak controller] request in
            guard let controller else {
                return AgentAPIResponse(requestID: request.requestID,
                    error: AgentAPIError(code: .appUnavailable, message: "The application workspace is unavailable."))
            }
            return await controller.handle(request)
        }
        agentIPCServer = server
        let previousCleanup = agentIPCCleanupTask
        agentIPCStartupTask = Task { [weak self] in
            await previousCleanup?.value
            guard let self, self.agentIPCServer === server, !Task.isCancelled else {
                await server.stop()
                return
            }
            do { try await server.start() }
            catch {
                guard self.agentIPCServer === server else { return }
                self.diagnostics.append("The local Agent interface is unavailable. Another app instance may already own it.")
                self.agentIPCServer = nil
            }
        }
    }

    func stopAgentAPI() {
        agentController.invalidate()
        let server = agentIPCServer
        agentIPCServer = nil
        let startup = agentIPCStartupTask
        agentIPCStartupTask = nil
        startup?.cancel()
        let previousCleanup = agentIPCCleanupTask
        agentIPCCleanupTask = Task {
            await previousCleanup?.value
            await startup?.value
            await server?.stop()
        }
    }

    var selectedDevice: DeviceRecord? {
        guard let selectedDeviceIdentity else { return nil }
        return devices.first { $0.identity == selectedDeviceIdentity }
    }

    private var connectionActionBlock: String? {
        guard selectedDeviceIdentity != nil else { return "Select a command-ready device." }
        if isSelecting { return "The device connection is still being checked." }
        switch connectionHealth {
        case .healthy, .recovered: return nil
        case .starting: return "The device connection is starting."
        case .suspect: return "The device connection is being verified."
        case .reconnecting: return "The device connection is recovering."
        case .actionRequired: return "The device connection needs attention."
        case .stopped: return "Connection maintenance is stopped."
        }
    }

    private func actionPresentation(
        for readiness: CapabilityReadiness,
        busy: Bool = false,
        conflictsWithAnotherOperation: Bool = false
    ) -> CapabilityActionPresentation {
        if let block = connectionActionBlock {
            return CapabilityActionPresentation(statusText: isSelecting ? "Connecting…" : "Action required",
                                                detail: block, canStart: false)
        }
        if case .preparing = readiness {
            return CapabilityActionPresentation(statusText: "Preparing…", detail: nil, canStart: false)
        }
        if busy || conflictsWithAnotherOperation {
            return CapabilityActionPresentation(statusText: "Working…",
                                                detail: conflictsWithAnotherOperation
                                                    ? "Another device content action is in progress." : nil,
                                                canStart: false)
        }
        switch readiness {
        case .idle:
            return CapabilityActionPresentation(statusText: "Unavailable", detail: nil, canStart: false)
        case let .availableOnDemand(detail):
            return CapabilityActionPresentation(statusText: "Available on demand", detail: detail, canStart: true)
        case .preparing:
            return CapabilityActionPresentation(statusText: "Preparing…", detail: nil, canStart: false)
        case .ready:
            return CapabilityActionPresentation(statusText: "Ready", detail: nil, canStart: true)
        case let .actionRequired(message):
            return CapabilityActionPresentation(statusText: "Action required", detail: message, canStart: false)
        }
    }

    var clipboardAction: CapabilityActionPresentation {
        actionPresentation(for: clipboardReadiness, busy: isClipboardBusy,
            conflictsWithAnotherOperation: selectedDevice?.identity.platform == .iOS && isCapturingScreenshot)
    }

    var isClipboardReady: Bool { clipboardAction.canStart }
    var canStartClipboardOperation: Bool {
        clipboardAction.canStart
    }

    var clipboardReadinessText: String { clipboardAction.statusText }
    var clipboardReadinessDetail: String? { clipboardAction.detail }

    var screenshotAction: CapabilityActionPresentation {
        actionPresentation(for: screenshotReadiness, busy: isCapturingScreenshot,
            conflictsWithAnotherOperation: selectedDevice?.identity.platform == .iOS && isClipboardBusy)
    }

    var isScreenshotReady: Bool { screenshotAction.canStart }
    var canCaptureScreenshot: Bool { screenshotAction.canStart }
    var screenshotReadinessText: String { screenshotAction.statusText }
    var screenshotReadinessDetail: String? { screenshotAction.detail }

    var fileTransferAction: CapabilityActionPresentation {
        actionPresentation(for: fileTransferReadiness, busy: isTransferringFile)
    }

    var isFileTransferReady: Bool { fileTransferAction.canStart }
    var canUseImageBrowser: Bool { connectionActionBlock == nil }
    var canUseAndroidShell: Bool { connectionActionBlock == nil }
    var canUseDeviceInformation: Bool { connectionActionBlock == nil }
    var fileTransferReadinessText: String { fileTransferAction.statusText }
    var fileTransferReadinessDetail: String? { fileTransferAction.detail }

    var memoryAction: CapabilityActionPresentation {
        actionPresentation(for: memoryReadiness, busy: isMonitoringMemory)
    }

    var memoryReadinessText: String { memoryAction.statusText }
    var memoryReadinessDetail: String? { memoryAction.detail }
    var canDiscoverMemory: Bool { connectionActionBlock == nil && !isMonitoringMemory }

    var selectedMemoryApplication: TargetApplication? {
        guard let selectedMemoryApplicationID else { return nil }
        return targetApplications.first { $0.applicationID == selectedMemoryApplicationID }
    }

    var canAttachFlutterVM: Bool {
        hasStarted && connectionActionBlock == nil && !isMonitoringMemory
            && selectedDevice?.identity.platform == .android
    }

    var canStartIOSMemory: Bool {
        guard hasStarted, connectionActionBlock == nil, !isMonitoringMemory, memoryReadiness == .ready,
              selectedDevice?.identity.platform == .iOS, let binding = iosMemoryBinding else { return false }
        return binding.session == iosMemorySession && binding.target == selectedMemoryApplication
            && binding.session.deviceIdentity == selectedDeviceIdentity
    }

    var isAndroidKeepAliveActive: Bool {
        if case .active = androidKeepAliveState { return true }
        return false
    }

    var canStartAndroidKeepAlive: Bool {
        guard androidKeepAliveController != nil else { return false }
        if case .starting = androidKeepAliveState { return false }
        return !isAndroidKeepAliveActive
    }

    var androidKeepAliveStatusText: String {
        switch androidKeepAliveState {
        case .idle:
            guard let device = selectedDevice,
                  device.identity.platform == .android,
                  let transportID = device.preferredTransportID,
                  let transport = device.candidates.first(where: { $0.id == transportID }) else {
                return "Inactive"
            }
            return transport.kind == .usb ? "Not needed on USB" : "Inactive"
        case .starting: return "Starting…"
        case .active: return "Active"
        case .stopped: return "Stopped"
        case .failed: return "Action required"
        }
    }

    func androidKeepAliveDetail(in language: InterfaceLanguage) -> String {
        switch androidKeepAliveState {
        case let .active(lease):
            return InterfaceMessage("Renews every 10 seconds · current device lease expires {0}.", arguments: [
                lease.expiresAt.formatted(.dateTime.hour().minute().second().locale(language.locale))
            ]).render(in: language)
        case let .failed(failure):
            return language.text(failure.recoveryAction ?? failure.safeMessage)
        case .idle, .starting, .stopped:
            return language.text("A visible Android notification and Wi-Fi lock reduce radio sleep; device power policy, wireless debugging, pairing, and the network can still interrupt ADB.")
        }
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        requestRefresh()
        inventoryLoopTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                guard let self, self.hasStarted else { return }
                if !self.isSelecting { self.requestRefresh(isBackground: true) }
            }
        }
    }

    func requestRefresh(isBackground: Bool = false) {
        // A manual refresh joins an in-flight poll and makes its progress visible.
        if !isBackground, !isRefreshing { isRefreshing = true }
        guard refreshTask == nil else { return }
        refreshRevision += 1
        let revision = refreshRevision
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await self.refresh(revision: revision)
            guard self.refreshRevision == revision else { return }
            if self.isRefreshing { self.isRefreshing = false }
            self.refreshTask = nil
        }
    }

    func stop() {
        stopAgentAPI()
        invalidateAndroidCommands()
        deviceInformation.invalidate()
        detachIOSRunner()
        detachIOSClipboardHost()
        invalidateIOSMemory()
        imageBrowser?.stop()
        imageBrowser = nil
        iosPhotoDiscovery.stop()
        selectionRevision += 1
        clipboardExportGeneration += 1
        let revision = selectionRevision
        inventoryLoopTask?.cancel()
        inventoryLoopTask = nil
        maintenanceTask?.cancel()
        maintenanceTask = nil
        let maintenance = maintenance
        self.maintenance = nil
        isConnectionMaintained = false
        helperContext = nil
        refreshTask?.cancel()
        refreshTask = nil
        refreshRevision += 1
        if isRefreshing { isRefreshing = false }
        selectionTask?.cancel()
        selectionTask = nil
        clipboardOperationTask?.cancel()
        clipboardOperationTask = nil
        screenshotOperationTask?.cancel()
        screenshotOperationTask = nil
        fileTransferTask?.cancel()
        fileTransferTask = nil
        cancelMemoryPreparation()
        keepAliveActionTask?.cancel()
        keepAliveActionTask = nil
        keepAliveObservationTask?.cancel()
        keepAliveObservationTask = nil
        isSelecting = false
        deviceSelection = nil
        isClipboardBusy = false
        clipboardService = nil
        clipboardReadiness = .idle
        clipboardRecoveryAction = nil
        let screenshotService = screenshotService
        self.screenshotService = nil
        screenshotReadiness = .idle
        currentScreenshotArtifact = nil
        screenshotFeedback = nil
        isCapturingScreenshot = false
        fileTransferService = nil
        fileTransferReadiness = .idle
        fileTransferFeedback = nil
        latestTransferArtifact = nil
        isTransferringFile = false
        let memoryMonitor = memoryMonitor
        self.memoryMonitor = nil
        let flutterVMDiscovery = flutterVMDiscovery
        self.flutterVMDiscovery = nil
        let flutterVMService = flutterVMService
        self.flutterVMService = nil
        osMemorySampler = nil
        discoveredVMURI = nil
        memoryReadiness = .idle
        targetApplications = []
        selectedMemoryApplicationID = nil
        vmServiceURIText = ""
        memorySamples = []
        memoryFeedback = nil
        isMonitoringMemory = false
        let keepAliveController = androidKeepAliveController
        androidKeepAliveController = nil
        androidKeepAliveState = .stopped
        connectionHealth = .stopped
        hasStarted = false
        let manager = androidHelperManager
        androidHelperManager = nil
        Task {
            await maintenance?.stop()
            if selectionRevision == revision { await store.disconnect() }
            await keepAliveController?.stop()
            await manager?.stop()
            await screenshotService?.clearSessionArtifacts()
            await memoryMonitor?.stop()
            await flutterVMDiscovery?.stop()
            await flutterVMService?.disconnect()
        }
    }

    private func refresh(revision: Int) async {
        guard !Task.isCancelled, refreshRevision == revision else { return }
        if arguments.contains("--fixture-devices") {
            await store.replaceInventory(devices)
            let snapshot = await store.snapshot()
            guard !Task.isCancelled, refreshRevision == revision else { return }
            publishInventory(snapshot)
            return
        }

        let preflight = ToolchainPreflight()
        var searchDirectories = preflight.defaultSearchDirectories(
            environment: ProcessInfo.processInfo.environment
        )
        searchDirectories.insert(
            FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Library/Android/sdk/platform-tools", directoryHint: .isDirectory),
            at: 0
        )

        var candidates: [TransportCandidate] = []
        var discoveryDiagnostics: [String] = []
        var resolvedADBURL: URL?
        var resolvedXcrunURL: URL?
        switch preflight.resolve(.adb, searchDirectories: searchDirectories) {
        case let .available(adbURL):
            resolvedADBURL = adbURL
            do {
                candidates += try await AndroidDeviceDiscoveryService(
                    adbURL: adbURL,
                    runner: runner
                ).discover(observedAt: Date())
            } catch {
                discoveryDiagnostics.append("Android discovery failed. Check ADB authorization and retry.")
            }
        case let .missing(message, _):
            discoveryDiagnostics.append(message)
        }

        guard !Task.isCancelled, refreshRevision == revision else { return }
        switch preflight.resolve(.xcrun, searchDirectories: searchDirectories) {
        case let .available(xcrunURL):
            resolvedXcrunURL = xcrunURL
            do {
                candidates += try await IOSDeviceDiscoveryService(
                    xcrunURL: xcrunURL,
                    runner: runner
                ).discover(observedAt: Date())
            } catch {
                discoveryDiagnostics.append("iOS discovery failed. Check Xcode, trust, and Developer Mode.")
            }
        case let .missing(message, _):
            discoveryDiagnostics.append(message)
        }

        guard !Task.isCancelled, refreshRevision == revision else { return }
        await store.replaceInventory(DeviceInventory.aggregate(candidates))
        let snapshot = await store.snapshot()
        guard !Task.isCancelled, refreshRevision == revision else { return }
        adbURL = resolvedADBURL
        xcrunURL = resolvedXcrunURL
        if diagnostics != discoveryDiagnostics { diagnostics = discoveryDiagnostics }
        publishInventory(snapshot)
    }

    private func publishInventory(_ snapshot: WorkspaceSnapshot) {
        agentController.validateSession(snapshot.session)
        if let binding = androidCommandBinding,
           snapshot.session != binding.session || !snapshot.devices.contains(where: { device in
               device.identity == binding.session.deviceIdentity && device.authorization == .authorized
                   && device.candidates.contains(where: { $0.id == binding.session.transportID
                       && $0.metadata["adbSerial"] == binding.route.adbSerial })
           }) {
            invalidateAndroidCommands()
        }
        if let session = androidShell.session,
           snapshot.session != session || !snapshot.devices.contains(where: {
               $0.identity == session.deviceIdentity && $0.authorization == .authorized
                   && $0.candidates.contains(where: { $0.id == session.transportID })
           }) {
            invalidateAndroidCommands()
        }
        if let session = deviceInformation.session,
           snapshot.session != session || !snapshot.devices.contains(where: {
               $0.identity == session.deviceIdentity && $0.preferredTransportID == session.transportID
                   && $0.authorization != .denied
           }) {
            deviceInformation.invalidate()
        }
        if let session = iosMemorySession,
           snapshot.session != session || !snapshot.devices.contains(where: {
               $0.identity == session.deviceIdentity && $0.preferredTransportID == session.transportID
                   && $0.authorization != .denied
           }) {
            cancelMemoryPreparation()
            invalidateIOSMemory(reason: "The iOS device route changed. Select the device again.")
        }
        if let session = iosRunnerSession,
           snapshot.session != session || !snapshot.devices.contains(where: {
               $0.identity == session.deviceIdentity && $0.preferredTransportID == session.transportID
                   && $0.authorization != .denied
           }) {
            invalidateIOSRunner(reason: "The iOS device route changed. Select the device again.")
        }
        if let session = iosClipboardSession,
           snapshot.session != session || !snapshot.devices.contains(where: {
               $0.identity == session.deviceIdentity && $0.preferredTransportID == session.transportID
                   && $0.authorization != .denied
           }) {
            invalidateIOSClipboardHost(reason: "The iOS device route changed. Select the device again.")
        }
        // The store always receives fresh observations. The UI does not display transport
        // timestamps, so timestamp-only scans must not invalidate every sidebar row.
        // Maintenance retains its selected record at the end of the store inventory;
        // preserve the discovery ordering in the sidebar regardless of that ownership.
        let presentation = snapshot.devices.sorted {
            if $0.name != $1.name { return $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return $0.identity.displaySuffix < $1.identity.displaySuffix
        }
        if !Self.sameInventoryPresentation(devices, presentation) { devices = presentation }
        if selectedDeviceIdentity != snapshot.selectedDeviceIdentity {
            selectedDeviceIdentity = snapshot.selectedDeviceIdentity
        }
    }

    private static func sameInventoryPresentation(_ lhs: [DeviceRecord], _ rhs: [DeviceRecord]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { old, new in
            old.identity == new.identity && old.name == new.name && old.model == new.model
                && old.osVersion == new.osVersion && old.authorization == new.authorization
                && old.preferredTransportID == new.preferredTransportID && old.capabilities == new.capabilities
                && old.candidates.count == new.candidates.count
                && zip(old.candidates, new.candidates).allSatisfy { previous, current in
                    previous.id == current.id && previous.identity == current.identity
                        && previous.kind == current.kind && previous.source == current.source
                        && previous.status == current.status && previous.metadata == current.metadata
                        && previous.endpoint == current.endpoint
                }
        }
    }

    var iosConnectionRepairRevision: Int? {
        guard !isSelecting, case let .failed(device, failure) = deviceSelection,
              device.identity.platform == .iOS,
              [.timeout, .disconnected, .failure].contains(failure.code) else { return nil }
        return selectionRevision
    }

    func repairIOSConnection(identity: DeviceIdentity, expectedRevision: Int) {
        guard iosConnectionRepairRevision == expectedRevision,
              deviceSelection?.device.identity == identity else { return }
        select(identity, restartingIOSService: true)
    }

    func select(_ identity: DeviceIdentity, resuming context: HelperSessionContext? = nil) {
        select(identity, resuming: context, restartingIOSService: false)
    }

    private func select(_ identity: DeviceIdentity, resuming context: HelperSessionContext? = nil,
                        restartingIOSService: Bool) {
        guard let candidate = devices.first(where: { $0.identity == identity }) else {
            diagnostics.append("The selected device is no longer available.")
            return
        }
        if context == nil, !restartingIOSService, !isSelecting,
           selectedDeviceIdentity == identity,
           connectionHealth == .healthy || connectionHealth == .recovered {
            return
        }
        deviceSelection = .checking(candidate)
        invalidateAndroidCommands()
        deviceInformation.invalidate()
        detachIOSRunner()
        detachIOSClipboardHost()
        invalidateIOSMemory()
        let previousAndroidHelper = androidHelperManager
        androidHelperManager = nil
        let previousIOSCleanup = iosRunnerCleanupTask
        let previousIOSClipboardCleanup = iosClipboardCleanupTask
        imageBrowser?.stop()
        imageBrowser = nil
        selectionRevision += 1
        clipboardExportGeneration += 1
        let revision = selectionRevision
        let previousSelection = selectionTask
        previousSelection?.cancel()
        let previousMaintenance = maintenance
        maintenanceTask?.cancel()
        maintenanceTask = nil
        maintenance = nil
        isConnectionMaintained = false
        helperContext = nil
        connectionHealth = .starting
        if context == nil { connectionRecoveryCount = 0 }
        let previousScreenshotService = screenshotService
        let previousMemoryMonitor = memoryMonitor
        let previousVMDiscovery = flutterVMDiscovery
        let previousVMService = flutterVMService
        let previousKeepAliveController = androidKeepAliveController
        clipboardOperationTask?.cancel()
        clipboardOperationTask = nil
        screenshotOperationTask?.cancel()
        screenshotOperationTask = nil
        fileTransferTask?.cancel()
        fileTransferTask = nil
        cancelMemoryPreparation()
        keepAliveActionTask?.cancel()
        keepAliveActionTask = nil
        keepAliveObservationTask?.cancel()
        keepAliveObservationTask = nil
        isClipboardBusy = false
        clipboardFeedback = nil
        clipboardRecoveryAction = nil
        clipboardText = ""
        clipboardService = nil
        clipboardReadiness = .idle
        screenshotService = nil
        screenshotReadiness = .idle
        currentScreenshotArtifact = nil
        screenshotFeedback = nil
        isCapturingScreenshot = false
        fileTransferService = nil
        fileTransferReadiness = .idle
        fileTransferFeedback = nil
        latestTransferArtifact = nil
        isTransferringFile = false
        memoryMonitor = nil
        flutterVMDiscovery = nil
        flutterVMService = nil
        osMemorySampler = nil
        discoveredVMURI = nil
        memoryReadiness = .preparing
        targetApplications = []
        selectedMemoryApplicationID = nil
        vmServiceURIText = ""
        memorySamples = []
        memoryFeedback = nil
        isMonitoringMemory = false
        androidKeepAliveController = nil
        androidKeepAliveState = .idle
        if arguments.contains("--fixture-devices") {
            selectedDeviceIdentity = identity
        }
        isSelecting = true
        selectionTask = Task { [weak self] in
            guard let self else { return }
            // Drain the cancelled selection's helper cleanup before starting a new helper.
            await previousSelection?.value
            await previousIOSCleanup?.value
            await previousIOSClipboardCleanup?.value
            await previousAndroidHelper?.stop()
            await previousMaintenance?.stop()
            await previousKeepAliveController?.stop()
            await previousScreenshotService?.clearSessionArtifacts()
            await previousMemoryMonitor?.stop()
            await previousVMDiscovery?.stop()
            await previousVMService?.disconnect()
            guard !Task.isCancelled else { return }
            defer {
                if self.selectionRevision == revision {
                    self.isSelecting = false
                    self.selectionTask = nil
                }
            }

            do {
                guard let device = self.devices.first(where: { $0.identity == identity }) else {
                    self.deviceSelection = .failed(candidate, OperationFailure(code: .disconnected,
                        safeMessage: "The selected device is no longer available.",
                        recoveryAction: "Reconnect the device and refresh."))
                    self.connectionHealth = .actionRequired
                    self.diagnostics.append("The selected device is no longer available.")
                    return
                }
                if restartingIOSService {
                    do {
                        try await IOSDeviceServiceRecovery(runner: self.runner).restart()
                    } catch {
                        guard !Task.isCancelled, selectionRevision == revision else { return }
                        self.deviceSelection = .failed(device, OperationFailure(code: .failure,
                            safeMessage: "Apple's device service could not be restarted.",
                            recoveryAction: "Close Xcode and other device tools, then try Repair connection again."))
                        self.connectionHealth = .actionRequired
                        return
                    }
                    guard !Task.isCancelled, selectionRevision == revision else { return }
                }
                if !self.arguments.contains("--fixture-devices") {
                    let outcome = await DeviceCommandProbe(
                        adbURL: self.adbURL,
                        xcrunURL: self.xcrunURL,
                        runner: self.runner
                    ).probe(device)
                    guard !Task.isCancelled else { return }
                    guard case let .ready(checkedAt) = outcome else {
                        if outcome.failure?.code != .cancelled {
                            let failure = outcome.failure ?? OperationFailure(code: .failure,
                                safeMessage: "The selected device is not command-ready.")
                            self.deviceSelection = .failed(device, failure)
                            self.connectionHealth = .actionRequired
                            self.diagnostics.append(failure.safeMessage)
                        }
                        return
                    }
                    self.lastSuccessfulCommandAt = checkedAt
                } else {
                    self.lastSuccessfulCommandAt = Date()
                }

                let snapshot = try await store.select(identity)
                guard !Task.isCancelled else { return }
                if let session = snapshot.session { await store.markCommandReady(session: session) }
                guard !Task.isCancelled, selectionRevision == revision else { return }
                let readySnapshot = await store.snapshot()
                guard !Task.isCancelled, selectionRevision == revision else { return }
                publishInventory(readySnapshot)
                deviceSelection = nil
                connectionHealth = .healthy
                if let session = readySnapshot.session {
                    bindDeviceInformation(device: device, session: session)
                    agentController.activate(session: session)
                }
                if device.identity.platform != .iOS || arguments.contains("--fixture-devices") {
                    prepareScreenshot(for: device)
                } else if let session = readySnapshot.session,
                          let route = device.candidates.first(where: { $0.id == session.transportID }),
                          route.kind == .usb {
                    screenshotReadiness = .availableOnDemand(
                        "The iOS screenshot runner starts only after an explicit screenshot action."
                    )
                } else {
                    screenshotReadiness = .actionRequired(
                        "iOS screenshots currently require a trusted USB connection and Xcode."
                    )
                }
                prepareFileTransfer(for: device, session: snapshot.session)
                startMemoryPreparation(for: device)
                if device.identity.platform == .iOS,
                   !arguments.contains("--fixture-devices"),
                   case .actionRequired = screenshotReadiness {
                    clipboardReadiness = .actionRequired(
                        "iOS clipboard currently requires a trusted USB connection and Xcode."
                    )
                } else {
                    clipboardReadiness = .availableOnDemand(
                        device.identity.platform == .iOS
                            ? "The iOS clipboard Host starts only after an explicit clipboard action."
                            : "The Android helper opens only after an explicit clipboard action."
                    )
                }
                guard !Task.isCancelled, selectionRevision == revision else { return }
                if device.identity.platform == .android, !arguments.contains("--fixture-devices"),
                   let session = readySnapshot.session {
                    await prepareAndroidCommands(device: device, session: session, revision: revision)
                }
                guard !Task.isCancelled, selectionRevision == revision else { return }
                await startConnectionMaintenance(for: device, revision: revision)
            } catch {
                guard !Task.isCancelled, selectionRevision == revision else { return }
                deviceSelection = .failed(candidate, OperationFailure(code: .disconnected,
                    safeMessage: "The selected device is no longer command-ready.",
                    recoveryAction: "Reconnect the device and refresh."))
                connectionHealth = .actionRequired
                diagnostics.append("The selected device is no longer command-ready.")
                clipboardReadiness = .actionRequired("Select a command-ready device and retry.")
            }
        }
    }

    func requestClipboardRead() {
        guard canStartClipboardOperation else { return }
        let revision = selectionRevision
        clipboardOperationTask?.cancel()
        isClipboardBusy = true
        clipboardFeedback = nil
        clipboardRecoveryAction = nil
        clipboardOperationTask = Task { [weak self] in
            guard let self else { return }
            guard let service = await self.clipboardServiceForExplicitAction(revision: revision) else {
                guard !Task.isCancelled, self.selectionRevision == revision else { return }
                self.isClipboardBusy = false
                self.clipboardOperationTask = nil
                return
            }
            let outcome = await service.read()
            let foregroundDisposition = await service.lastForegroundDisposition
            guard !Task.isCancelled, self.selectionRevision == revision else { return }
            self.applyClipboardOutcome(outcome, foregroundDisposition: foregroundDisposition)
            self.isClipboardBusy = false
            self.clipboardOperationTask = nil
        }
    }

    func requestClipboardSend() {
        guard canStartClipboardOperation else { return }
        let text = clipboardText
        let revision = selectionRevision
        clipboardOperationTask?.cancel()
        isClipboardBusy = true
        clipboardFeedback = nil
        clipboardRecoveryAction = nil
        clipboardOperationTask = Task { [weak self] in
            guard let self else { return }
            guard let service = await self.clipboardServiceForExplicitAction(revision: revision) else {
                guard !Task.isCancelled, self.selectionRevision == revision else { return }
                self.isClipboardBusy = false
                self.clipboardOperationTask = nil
                return
            }
            let outcome = await service.write(text)
            let foregroundDisposition = await service.lastForegroundDisposition
            guard !Task.isCancelled, self.selectionRevision == revision else { return }
            self.applyClipboardOutcome(outcome, foregroundDisposition: foregroundDisposition)
            self.isClipboardBusy = false
            self.clipboardOperationTask = nil
        }
    }

    func requestScreenshotCapture() {
        guard canCaptureScreenshot else { return }
        let revision = selectionRevision
        screenshotOperationTask?.cancel()
        isCapturingScreenshot = true
        screenshotFeedback = nil
        screenshotOperationTask = Task { [weak self] in
            guard let self else { return }
            guard let service = await self.screenshotServiceForExplicitAction(revision: revision) else {
                guard !Task.isCancelled, self.selectionRevision == revision else { return }
                self.isCapturingScreenshot = false
                self.screenshotOperationTask = nil
                return
            }
            let outcome = await service.capture()
            guard !Task.isCancelled, self.selectionRevision == revision else { return }
            switch outcome {
            case let .artifact(artifact):
                self.currentScreenshotArtifact = artifact
                self.screenshotFeedback = "Captured"
            case let .failure(failure):
                self.screenshotFeedback = failure.safeMessage
            case .stale:
                self.screenshotFeedback = "Device selection changed; the screenshot was discarded."
            }
            self.isCapturingScreenshot = false
            self.screenshotOperationTask = nil
        }
    }

    private func clipboardServiceForExplicitAction(revision: Int) async -> ClipboardService? {
        if let clipboardService { return clipboardService }
        guard selectionRevision == revision, let device = selectedDevice,
              let session = await store.snapshot().session,
              session.deviceIdentity == device.identity else { return nil }
        clipboardReadiness = .preparing
        if device.identity.platform == .iOS, !arguments.contains("--fixture-devices") {
            await prepareIOSClipboardHost(for: device, session: session, revision: revision)
        } else {
            await prepareClipboard(for: device)
        }
        guard !Task.isCancelled, selectionRevision == revision else { return nil }
        return clipboardService
    }

    private func screenshotServiceForExplicitAction(revision: Int) async -> ScreenshotService? {
        if let screenshotService { return screenshotService }
        guard selectionRevision == revision, let device = selectedDevice,
              device.identity.platform == .iOS,
              let session = await store.snapshot().session,
              session.deviceIdentity == device.identity else { return nil }
        screenshotReadiness = .preparing
        await prepareIOSRunner(for: device, session: session, revision: revision)
        guard !Task.isCancelled, selectionRevision == revision else { return nil }
        return screenshotService
    }

    func copyCurrentScreenshot() {
        guard let artifact = currentScreenshotArtifact,
              let data = try? Data(contentsOf: artifact.sessionURL) else {
            screenshotFeedback = "The current screenshot is no longer available."
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setData(data, forType: .png) else {
            screenshotFeedback = "The screenshot could not be copied."
            return
        }
        screenshotFeedback = "Copied"
    }

    func saveCurrentScreenshot(to destinationURL: URL) {
        guard let artifact = currentScreenshotArtifact,
              let data = try? Data(contentsOf: artifact.sessionURL) else {
            screenshotFeedback = "The current screenshot is no longer available."
            return
        }
        do {
            try data.write(to: destinationURL, options: .atomic)
            screenshotFeedback = "Saved"
        } catch {
            screenshotFeedback = "The screenshot could not be saved."
        }
    }

    func sendFile(
        sourceURL: URL,
        destination: DeviceFileLocation,
        replaceExisting: Bool
    ) {
        guard fileTransferAction.canStart else { return }
        guard let service = fileTransferService, !isTransferringFile else { return }
        fileTransferTask?.cancel()
        isTransferringFile = true
        fileTransferFeedback = nil
        fileTransferTask = Task { [weak self] in
            guard let self else { return }
            let outcome = await service.send(
                sourceURL: sourceURL,
                destination: destination,
                replaceExisting: replaceExisting
            )
            guard !Task.isCancelled else { return }
            self.applyFileTransferOutcome(outcome)
            self.isTransferringFile = false
            self.fileTransferTask = nil
        }
    }

    func receiveFile(
        source: DeviceFileLocation,
        destinationURL: URL,
        replaceExisting: Bool
    ) {
        guard fileTransferAction.canStart else { return }
        guard let service = fileTransferService, !isTransferringFile else { return }
        fileTransferTask?.cancel()
        isTransferringFile = true
        fileTransferFeedback = nil
        fileTransferTask = Task { [weak self] in
            guard let self else { return }
            let outcome = await service.receive(
                source: source,
                destinationURL: destinationURL,
                replaceExisting: replaceExisting
            )
            guard !Task.isCancelled else { return }
            self.applyFileTransferOutcome(outcome)
            self.isTransferringFile = false
            self.fileTransferTask = nil
        }
    }

    func cancelFileTransfer() {
        fileTransferTask?.cancel()
        fileTransferTask = nil
        isTransferringFile = false
        fileTransferFeedback = "Transfer cancelled"
    }

    func reportFileTransferInputError(_ message: String) {
        fileTransferFeedback = InterfaceMessage(message)
    }

    func startAndroidMemoryMonitoring() {
        guard memoryAction.canStart else { return }
        guard let provider = osMemorySampler,
              let target = selectedMemoryApplication else {
            memoryFeedback = "Select a running Android application first."
            return
        }
        startMemoryMonitor(sampler: provider, target: target)
    }

    func startFlutterMemoryMonitoring() {
        guard connectionActionBlock == nil else { return }
        if selectedDevice?.identity.platform == .iOS {
            guard canStartIOSMemory, let binding = iosMemoryBinding else {
                memoryFeedback = "iOS memory requires a verified device and app connection; a manual URI is not sufficient."
                return
            }
            startMemoryMonitor(sampler: binding, target: binding.target)
            return
        }
        guard canAttachFlutterVM else { return }
        let explicitURI = FlutterVMServiceDiscovery.candidateURI(in: vmServiceURIText)
        guard let uri = explicitURI ?? discoveredVMURI,
              let device = selectedDevice else {
            memoryFeedback = "Enter a loopback Flutter VM Service URI from a debug/profile run."
            return
        }
        do {
            let service = try FlutterVMService(uri: uri)
            flutterVMService = service
            let target = selectedMemoryApplication ?? TargetApplication(
                deviceIdentity: device.identity,
                applicationID: "flutter.vm",
                displayName: "Flutter VM",
                processID: nil,
                processStartIdentity: nil,
                debuggable: true,
                state: .running
            )
            startMemoryMonitor(sampler: service, target: target)
        } catch {
            memoryFeedback = "The Flutter VM Service URI is invalid or not loopback-forwarded."
        }
    }

    func stopMemoryMonitoring() {
        if selectedDevice?.identity.platform == .iOS {
            cancelMemoryPreparation()
            invalidateIOSMemory(reason: "Monitoring stopped. Discover the iOS VM again to reconnect.")
        }
        let monitor = memoryMonitor
        memoryMonitor = nil
        isMonitoringMemory = false
        memorySamples = []
        memoryFeedback = "Monitoring stopped"
        Task { await monitor?.stop() }
    }

    func stopAndroidConnectionMaintenance() {
        guard let controller = androidKeepAliveController else {
            androidKeepAliveState = .stopped
            return
        }
        keepAliveActionTask?.cancel()
        keepAliveObservationTask?.cancel()
        keepAliveObservationTask = nil
        androidKeepAliveState = .stopped
        keepAliveActionTask = Task { [weak self] in
            await controller.stop()
            guard !Task.isCancelled else { return }
            self?.androidKeepAliveState = await controller.state
            self?.keepAliveActionTask = nil
        }
    }

    func startAndroidConnectionMaintenance() {
        guard let controller = androidKeepAliveController, let manager = androidHelperManager,
              let transportID = selectedDevice?.preferredTransportID,
              canStartAndroidKeepAlive else { return }
        keepAliveActionTask?.cancel()
        keepAliveObservationTask?.cancel()
        keepAliveObservationTask = nil
        androidKeepAliveState = .starting
        keepAliveActionTask = Task { [weak self] in
            guard await manager.requestKeepAliveNotificationPermission(transportID: transportID) else {
                guard let self, self.androidKeepAliveController === controller else { return }
                self.androidKeepAliveState = .failed(OperationFailure(code: .failure,
                    safeMessage: "The Android notification permission screen could not be opened.",
                    recoveryAction: "Unlock the device and retry Wi-Fi maintenance."))
                self.keepAliveActionTask = nil
                return
            }
            let outcome = await controller.start()
            guard !Task.isCancelled, let self,
                  self.androidKeepAliveController === controller else {
                await controller.stop()
                return
            }
            self.androidKeepAliveState = await controller.state
            if outcome.lease != nil {
                self.observeKeepAlive(controller)
            }
            self.keepAliveActionTask = nil
        }
    }

    private func startMemoryMonitor(
        sampler: any MemorySampling,
        target: TargetApplication
    ) {
        let previous = memoryMonitor
        let monitor = MemoryMonitor(store: store, sampler: sampler)
        memoryMonitor = monitor
        memorySamples = []
        memoryFeedback = "Monitoring memory · target interval 2.5 s"
        isMonitoringMemory = true
        Task { [weak self] in
            await previous?.stop()
            guard let self, self.memoryMonitor === monitor, self.hasStarted,
                  self.connectionActionBlock == nil else { return }
            await monitor.start(target: target) { [weak self] event in
                await self?.applyMemoryEvent(event, from: monitor)
            }
            if self.memoryMonitor !== monitor || !self.hasStarted { await monitor.stop() }
        }
    }

    private func applyMemoryEvent(_ event: MemoryMonitorEvent, from monitor: MemoryMonitor) {
        guard memoryMonitor === monitor, connectionActionBlock == nil else { return }
        switch event {
        case let .sample(sample):
            memorySamples.append(sample)
            if memorySamples.count > 120 {
                memorySamples.removeFirst(memorySamples.count - 120)
            }
            memoryFeedback = nil
        case let .restarted(target):
            memorySamples = []
            isMonitoringMemory = false
            memoryFeedback = InterfaceMessage("Process restarted as PID {0}; start monitoring again.", arguments: [target.processID.map(String.init) ?? "—"])
        case .stopped:
            memorySamples = []
            isMonitoringMemory = false
            memoryFeedback = "The selected application stopped."
        case let .failure(failure):
            memoryFeedback = InterfaceMessage(failure.safeMessage)
        case let .invalidated(failure):
            invalidateIOSMemory(reason: failure.safeMessage)
            memoryMonitor = nil
            memorySamples = []
            isMonitoringMemory = false
            memoryReadiness = .actionRequired(failure.safeMessage)
            memoryFeedback = InterfaceMessage(failure.safeMessage)
        case .busy:
            break
        case .stale:
            if selectedDevice?.identity.platform == .iOS {
                invalidateIOSMemory(reason: "Verified iOS VM connection ended. Discover again before monitoring.")
            }
            memorySamples = []
            isMonitoringMemory = false
            memoryFeedback = "Device or application selection changed."
        }
    }

    private func cancelMemoryPreparation() {
        memoryPreparationRevision += 1
        memoryPreparationTask?.cancel()
        memoryPreparationTask = nil
    }

    private func startMemoryPreparation(for device: DeviceRecord) {
        cancelMemoryPreparation()
        let revision = memoryPreparationRevision
        memoryPreparationTask = Task { [weak self] in
            guard let self else { return }
            await self.prepareMemory(for: device)
            if self.memoryPreparationRevision == revision { self.memoryPreparationTask = nil }
        }
    }

    func retryIOSMemoryDiscovery() {
        guard hasStarted, connectionActionBlock == nil, !isMonitoringMemory,
              let device = selectedDevice, device.identity.platform == .iOS else { return }
        startMemoryPreparation(for: device)
    }

    /// Invalidates the sole Workspace binding writer before any asynchronous cleanup.
    private func invalidateIOSMemory(reason: String? = nil) {
        let hadIOSOwner = iosMemorySession != nil || iosMemoryTask != nil || iosMemoryBinding != nil
        iosMemoryRevision += 1
        let task = iosMemoryTask
        task?.cancel()
        iosMemoryTask = nil
        let binding = iosMemoryBinding
        iosMemoryBinding = nil
        iosMemorySession = nil
        let previousCleanup = iosMemoryCleanupTask
        let monitor = hadIOSOwner ? memoryMonitor : nil
        if hadIOSOwner {
            memoryMonitor = nil
            memorySamples = []
            isMonitoringMemory = false
        }
        if let reason { memoryReadiness = .actionRequired(reason); memoryFeedback = InterfaceMessage(reason) }
        else if hadIOSOwner { memoryReadiness = .idle }
        iosMemoryCleanupTask = Task {
            await previousCleanup?.value
            await monitor?.stop()
            await binding?.close()
            await task?.value
        }
    }

    private func iosMemoryMatches(session: ConnectionSession, revision: Int) async -> Bool {
        guard !Task.isCancelled, hasStarted, iosMemoryRevision == revision,
              iosMemorySession == session, selectedDeviceIdentity == session.deviceIdentity else { return false }
        let snapshot = await store.snapshot()
        return !Task.isCancelled && hasStarted && iosMemoryRevision == revision
            && iosMemorySession == session && selectedDeviceIdentity == session.deviceIdentity
            && snapshot.session == session && snapshot.selectedDeviceIdentity == session.deviceIdentity
    }

    private func prepareIOSMemoryApplications(for device: DeviceRecord) async {
        let selection = selectionRevision
        invalidateIOSMemory()
        let revision = iosMemoryRevision
        memoryReadiness = .preparing
        await iosMemoryCleanupTask?.value
        let snapshot = await store.snapshot()
        guard !Task.isCancelled, hasStarted, selectionRevision == selection, iosMemoryRevision == revision,
              selectedDeviceIdentity == device.identity, let session = snapshot.session,
              session.deviceIdentity == device.identity, session.state == .active else { return }
        iosMemorySession = session
        do {
            let apps = try await iosMemoryProvider.applications(session: session)
            guard await iosMemoryMatches(session: session, revision: revision) else { return }
            let available = apps.filter { $0.deviceIdentity == session.deviceIdentity && $0.state == .running && $0.debuggable == true }
            let previous = selectedMemoryApplicationID
            let selected = available.contains(where: { $0.applicationID == previous }) ? previous
                : (available.count == 1 ? available.first?.applicationID : nil)
            targetApplications = available
            memoryReadiness = .actionRequired(available.isEmpty
                ? "No running iOS debug app was found. Start a Flutter debug/profile app and retry."
                : "Select an iOS application to verify its Flutter VM connection.")
            selectedMemoryApplicationID = selected
            if previous == selected, selected != nil { prepareIOSMemoryBinding() }
        } catch {
            guard await iosMemoryMatches(session: session, revision: revision) else { return }
            memoryReadiness = .actionRequired("iOS app discovery failed. Keep the phone unlocked and connected by USB, then retry.")
        }
    }

    private func prepareIOSMemoryBinding() {
        let session = iosMemorySession
        invalidateIOSMemory()
        guard hasStarted, let session, selectedDeviceIdentity == session.deviceIdentity,
              let application = selectedMemoryApplication else {
            memoryReadiness = .actionRequired("Select an iOS application to verify its Flutter VM connection.")
            // Retain app-selection scope when the user selects the empty picker entry.
            iosMemorySession = session
            return
        }
        iosMemorySession = session
        let revision = iosMemoryRevision
        let cleanup = iosMemoryCleanupTask
        memoryReadiness = .preparing
        memoryFeedback = nil
        iosMemoryTask = Task { [weak self] in
            guard let self else { return }
            var owned: IOSVerifiedVMBinding?
            defer { if self.iosMemoryRevision == revision { self.iosMemoryTask = nil } }
            do {
                await cleanup?.value
                guard await self.iosMemoryMatches(session: session, revision: revision) else { return }
                let binding = try await self.iosMemoryProvider.binding(store: self.store, session: session,
                    applicationID: application.applicationID)
                owned = binding
                guard await self.iosMemoryMatches(session: session, revision: revision),
                      self.selectedMemoryApplication == application else { await binding.close(); return }
                guard binding.session == session, binding.target == application else { throw IOSVMBindingError.unverifiedApplication }
                self.iosMemoryBinding = binding
                self.memoryReadiness = .ready
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(10))
                    guard await self.iosMemoryMatches(session: session, revision: revision) else { throw IOSVMBindingError.staleSession }
                    if self.isMonitoringMemory { continue }
                    do { try await binding.renew() }
                    catch IOSVMBindingError.operationInProgress { continue }
                    guard await self.iosMemoryMatches(session: session, revision: revision) else { throw IOSVMBindingError.staleSession }
                }
            } catch {
                await owned?.close()
                guard !Task.isCancelled, self.hasStarted, self.iosMemoryRevision == revision else { return }
                self.iosMemoryBinding = nil
                self.memoryReadiness = .actionRequired("The iOS VM could not be verified or its connection ended. Keep the debug app running over USB and retry.")
            }
        }
    }

    private func prepareMemory(for device: DeviceRecord) async {
        guard !Task.isCancelled else { return }
        if usesFixtureMemory || (arguments.contains("--fixture-devices") && device.identity.platform == .android) {
            let target = TargetApplication(
                deviceIdentity: device.identity,
                applicationID: "dev.example.fixture",
                displayName: "Fixture Flutter App",
                processID: 101,
                processStartIdentity: "fixture-start",
                debuggable: true,
                state: .running
            )
            targetApplications = [target]
            selectedMemoryApplicationID = target.applicationID
            osMemorySampler = FixtureMemorySampler(target: target)
            memoryReadiness = .ready
            return
        }

        if device.identity.platform == .iOS {
            await prepareIOSMemoryApplications(for: device)
            return
        }

        guard device.identity.platform == .android,
              let adbURL,
              let transportID = device.preferredTransportID else {
            memoryReadiness = .actionRequired(
                "iOS memory requires a verified device and app connection; a manual URI is not sufficient."
            )
            return
        }

        let provider = AndroidMemoryProvider(adbURL: adbURL, runner: runner)
        osMemorySampler = provider
        let applications = await provider.discover(
            deviceIdentity: device.identity,
            transportID: transportID
        )
        guard !Task.isCancelled else { return }
        targetApplications = applications
        selectedMemoryApplicationID = applications.first?.applicationID

        let discovery = AndroidFlutterVMDiscovery(adbURL: adbURL, runner: runner)
        flutterVMDiscovery = discovery
        let vmOutcome = await discovery.discover(transportID: transportID)
        guard !Task.isCancelled else {
            await discovery.stop()
            return
        }
        discoveredVMURI = vmOutcome.uri
        if !applications.isEmpty || discoveredVMURI != nil {
            memoryReadiness = .ready
        } else {
            memoryReadiness = .actionRequired(
                "No running app or Flutter VM Service was found. Start a debug/profile app and retry."
            )
        }
    }

    private func prepareFileTransfer(for device: DeviceRecord, session: ConnectionSession?) {
        if device.identity.platform == .iOS, !arguments.contains("--fixture-devices"), let session,
           device.identity.stability == .stable,
           device.candidates.contains(where: { $0.id == session.transportID && $0.kind == .usb }) {
            imageBrowser = PhoneImagesViewModel(service: ImageLibraryService(store: store, session: session,
                provider: IOSImageProvider(identity: device.identity, transportID: session.transportID, discovery: iosPhotoDiscovery),
                sessionDirectory: FileManager.default.temporaryDirectory.appending(path: "devicebridge-images-\(UUID())")),
                sources: [.iosUSBCameraImport])
        }
        if device.identity.platform == .android, !arguments.contains("--fixture-devices"), let adbURL, let session {
            imageBrowser = PhoneImagesViewModel(service: ImageLibraryService(store: store, session: session,
                provider: AndroidImageProvider(adbURL: adbURL, runner: runner),
                sessionDirectory: FileManager.default.temporaryDirectory.appending(path: "devicebridge-images-\(UUID())")))
        }
        let provider: (any DeviceFileProviding)?
        if arguments.contains("--fixture-devices") {
            provider = FixtureFileProvider()
        } else {
            switch device.identity.platform {
            case .android:
                provider = adbURL.map { AndroidFileProvider(adbURL: $0, runner: runner) }
            case .iOS:
                provider = xcrunURL.map { IOSFileProvider(xcrunURL: $0, runner: runner) }
            }
        }
        guard let provider else {
            fileTransferReadiness = .actionRequired(
                "The platform file tool is unavailable."
            )
            return
        }
        fileTransferService = FileTransferService(store: store, provider: provider)
        fileTransferReadiness = .ready
    }

    private func applyFileTransferOutcome(_ outcome: FileTransferOutcome) {
        switch outcome {
        case let .transferred(artifact):
            latestTransferArtifact = artifact
            let key = artifact.validation == .sha256
                ? "Transferred · {0} bytes · SHA-256 verified" : "Transferred · {0} bytes · length verified"
            fileTransferFeedback = InterfaceMessage(key, arguments: [String(artifact.byteLength)])
        case let .failure(failure):
            fileTransferFeedback = InterfaceMessage(failure.safeMessage)
        case .stale:
            fileTransferFeedback = "Device selection changed; the transfer result was discarded."
        }
    }

    private func prepareScreenshot(for device: DeviceRecord) {
        let provider: (any ScreenshotProviding)?
        if arguments.contains("--fixture-devices") {
            provider = FixtureScreenshotProvider()
        } else if device.identity.platform == .android, let adbURL {
            provider = AndroidScreenshotProvider(adbURL: adbURL, runner: runner)
        } else {
            provider = nil
        }

        guard let provider else {
            screenshotReadiness = .actionRequired(
                "iOS screenshots need the managed runner's persistent device channel."
            )
            return
        }
        installScreenshotProvider(provider)
    }

    private func installScreenshotProvider(_ provider: any ScreenshotProviding) {
        let directory = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first!
            .appending(path: "DeviceBridge/Sessions/\(UUID().uuidString)", directoryHint: .isDirectory)
        screenshotService = ScreenshotService(
            store: store,
            provider: provider,
            sessionDirectory: directory
        )
        screenshotReadiness = .ready
    }

    /// Workspace owns the selected-session binding; the manager exclusively owns native resources.
    private func prepareAndroidCommands(device: DeviceRecord, session: ConnectionSession, revision: Int) async {
        guard let candidate = device.candidates.first(where: { $0.id == session.transportID }),
              candidate.source == .adb, let serial = candidate.metadata["adbSerial"],
              !serial.isEmpty, !["unknown", "????????????"].contains(serial.lowercased()),
              let transportID = UInt64(session.transportID), transportID > 0,
              devices.flatMap(\.candidates).filter({ $0.metadata["adbSerial"] == serial }).count == 1 else {
            androidShell.setUnavailable("This Android route cannot establish a unique device binding.")
            return
        }
        let identity: ADBRouteIdentityEvidence
        if candidate.kind == .usb { identity = .uniqueUSBSerial }
        else if let context = helperContext { identity = .trustedWiFiHelper(context) }
        else {
            androidShell.setUnavailable("Open the existing Android helper and select the device again to verify this Wi-Fi route.")
            return
        }
        let id = UUID()
        do {
            let route = try ADBCapturedRoute(adbSerial: serial, transportID: transportID,
                sessionGeneration: session.generation, identityEvidence: identity)
            let server = try ADBServerConnection { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.androidCommandOwner?.id == id else { return }
                    self.invalidateAndroidCommands()
                    self.androidShell.setUnavailable("The local Android connection ended. Select the device again.")
                }
            }
            androidCommandOwner = .preparing(id: id, server: server)
            do {
                let epoch = try await server.beginEpoch(deadline: .now.advanced(by: .seconds(5)))
                let binding = AndroidDeviceCommandBinding(id: id, session: session, server: server, epoch: epoch, route: route)
                guard !Task.isCancelled, selectionRevision == revision, await binding.isCurrent(in: store),
                      !Task.isCancelled, selectionRevision == revision,
                      androidCommandOwner?.id == id else {
                    if androidCommandOwner?.id == id { androidCommandOwner = nil }
                    await server.close()
                    return
                }
                androidCommandOwner = .ready(binding)
                deviceInformation.bind(device: device, session: session, service: DeviceInformationService(store: store,
                    provider: AndroidDeviceInformationProvider(commands: NativeAndroidInformationCommands(binding: binding, store: store))))
                let store = store
                androidShell.bind(session: session, service: AndroidShellService(store: store,
                    makeExecutor: { binding.makeExecutor() }, bindingIsCurrent: { requested in
                        guard requested == session else { return false }
                        return await binding.isCurrent(in: store)
                    }))
            } catch {
                if androidCommandOwner?.id == id { androidCommandOwner = nil }
                await server.close()
                throw error
            }
        } catch {
            guard !Task.isCancelled, selectionRevision == revision else { return }
            androidShell.setUnavailable("The local Android connection could not be prepared. Select the device again.")
        }
    }

    private func invalidateAndroidCommands() {
        agentController.invalidate()
        let owner = androidCommandOwner
        androidCommandOwner = nil
        androidShell.invalidate()
        if deviceInformation.session?.deviceIdentity.platform == .android { deviceInformation.invalidate() }
        Task { await owner?.server.close() }
    }

    private func bindDeviceInformation(device: DeviceRecord, session: ConnectionSession) {
        if arguments.contains("--fixture-devices") {
            if device.identity.platform == .android {
                androidShell.bind(session: session, service: FixtureShellExecutor())
            }
            deviceInformation.bind(device: device, session: session,
                service: DeviceInformationService(store: store, provider: FixtureInformationProvider()))
        } else if device.identity.platform == .iOS, let xcrunURL {
            let runtime = informationRunnerChannel.map {
                IOSDeviceInformationProvider.RuntimeBinding(session: session, channel: $0)
            }
            deviceInformation.bind(device: device, session: session,
                service: DeviceInformationService(store: store,
                    provider: IOSDeviceInformationProvider(xcrunURL: xcrunURL, commands: runner, runtime: runtime)))
        }
    }

    private func prepareIOSRunner(for device: DeviceRecord, session: ConnectionSession, revision: Int) async {
        guard device.identity.stability == .stable,
              let route = device.candidates.first(where: { $0.id == session.transportID }),
              route.kind == .usb, let xcrunURL else {
            screenshotReadiness = .actionRequired("iOS screenshots currently require a trusted USB connection and Xcode.")
            return
        }
        screenshotReadiness = .preparing
        iosRunnerPreparation = IOSPreparationPresentation(owner: .screenshot)
        do {
            let manager: any IOSRunnerManaging
            if let iosScreenshotRunnerFactory {
                manager = try iosScreenshotRunnerFactory(xcrunURL)
            } else {
                guard let resources = Bundle.main.resourceURL else {
                    throw IOSRunnerSourceConfigurationError.bundleMissing
                }
                let configuration = try IOSRunnerSourceConfiguration(
                    helperResourcesURL: resources.appendingPathComponent("Helpers"),
                    signingTeamID: UserDefaults.standard.string(forKey: "iosSigningTeamID"))
                manager = IOSRunnerManager(xcodebuildURL: URL(fileURLWithPath: "/usr/bin/xcodebuild"),
                    projectURL: configuration.projectURL, scheme: configuration.scheme,
                    signingTeamID: configuration.signingTeamID, runner: runner,
                    launcher: IOSRunnerLauncher(xcrunURL: xcrunURL,
                        channels: IOSRunnerChannelFactory(xcrunURL: xcrunURL),
                        maximumRunnerLifetime: .seconds(3_600)),
                    buildWorkspace: iosRunnerBuildWorkspace)
            }
            iosRunnerManager = manager
            iosRunnerSession = session
            observeIOSPreparation(manager: manager, session: session, revision: revision)
            let outcome = await manager.prepare(deviceIdentifier: device.identity.rawValue)
            guard await iosRunnerMatches(session, revision: revision) else {
                await manager.stop()
                return
            }
            guard let channel = outcome.channel as? any IOSRunnerScreenshotChannel,
                  let context = try? await channel.authenticatedScreenshotContext(),
                  await HelperSessionAuthenticator(channel: channel).verifyExisting(context) else {
                guard await iosRunnerMatches(session, revision: revision) else { return }
                invalidateIOSRunner(reason: outcome.failure?.safeMessage
                    ?? "The iOS runner did not establish an authenticated screenshot channel. Retry iOS tools.",
                    recoveryAction: outcome.failure?.recoveryAction)
                return
            }
            guard await iosRunnerMatches(session, revision: revision) else { return }
            if let metadataChannel = outcome.channel as? any IOSRunnerDeviceInformationChannel {
                let launchID = metadataChannel.launchID
                informationRunnerLaunchID = launchID
                informationRunnerChannel = metadataChannel
                // Register after assigning the binding: an already-closing channel calls back immediately.
                await metadataChannel.registerInvalidationHandler { [weak self] lostLaunchID in
                    Task { @MainActor [weak self] in
                        guard let self, self.informationRunnerLaunchID == lostLaunchID,
                              self.iosRunnerSession == session, self.selectionRevision == revision else { return }
                        self.invalidateIOSRunner(reason: "The iOS runner session ended. Retry iOS tools.")
                    }
                }
                guard await iosRunnerMatches(session, revision: revision),
                      informationRunnerLaunchID == launchID else { return }
                bindDeviceInformation(device: device, session: session)
            }
            installScreenshotProvider(IOSRunnerScreenshotProvider(channel: channel, context: context,
                transportID: session.transportID))
            isConnectionMaintained = true
            iosRunnerPreparationObservationTask?.cancel()
            iosRunnerPreparationObservationTask = nil
            iosRunnerPreparation?.finish(.ready)
            lastSuccessfulCommandAt = Date()
            iosRunnerHeartbeatTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(10)) } catch { return }
                    guard let self, await self.iosRunnerMatches(session, revision: revision) else { return }
                    let valid = await HelperSessionAuthenticator(channel: channel).verifyExisting(context)
                    guard await self.iosRunnerMatches(session, revision: revision) else { return }
                    guard valid else {
                        self.invalidateIOSRunner(reason: "The iOS runner session ended. Retry iOS tools.")
                        return
                    }
                    self.lastSuccessfulCommandAt = Date()
                }
            }
        } catch {
            guard !Task.isCancelled, selectionRevision == revision else { return }
            let message = (error as? IOSRunnerSourceConfigurationError) == .signingTeamRequired
                ? "Set your existing Apple development Team ID in Settings, then retry iOS tools."
                : "The bundled iOS runner sources are missing or invalid. Rebuild the Debug app and retry."
            screenshotReadiness = .actionRequired(message)
            let failedStage = iosRunnerPreparation?.stage ?? .building
            iosRunnerPreparation?.finish(.failed(failedStage, message, nil))
        }
    }

    private func prepareIOSClipboardHost(for device: DeviceRecord, session: ConnectionSession, revision: Int) async {
        guard device.identity.stability == .stable,
              let route = device.candidates.first(where: { $0.id == session.transportID }),
              route.kind == .usb, let xcrunURL else {
            clipboardReadiness = .actionRequired("iOS clipboard currently requires a trusted USB connection and Xcode.")
            return
        }
        clipboardReadiness = .preparing
        iosClipboardPreparation = IOSPreparationPresentation(owner: .clipboard)
        do {
            let manager: any IOSRunnerManaging
            if let iosClipboardHostFactory {
                manager = try iosClipboardHostFactory(xcrunURL)
            } else {
                guard let resources = Bundle.main.resourceURL else {
                    throw IOSRunnerSourceConfigurationError.bundleMissing
                }
                let configuration = try IOSRunnerSourceConfiguration(
                    helperResourcesURL: resources.appendingPathComponent("Helpers"),
                    signingTeamID: UserDefaults.standard.string(forKey: "iosSigningTeamID"))
                manager = IOSRunnerManager(xcodebuildURL: URL(fileURLWithPath: "/usr/bin/xcodebuild"),
                    projectURL: configuration.projectURL, scheme: configuration.scheme,
                    signingTeamID: configuration.signingTeamID, runner: runner,
                    launcher: IOSClipboardHostLauncher(xcrunURL: xcrunURL,
                        channels: IOSClipboardHostChannelFactory(xcrunURL: xcrunURL),
                        maximumLifetime: .seconds(3_600)),
                    buildWorkspace: iosRunnerBuildWorkspace)
            }
            iosClipboardManager = manager
            iosClipboardSession = session
            observeIOSClipboardPreparation(manager: manager, session: session, revision: revision)
            let outcome = await manager.prepare(deviceIdentifier: device.identity.rawValue)
            guard await iosClipboardMatches(session, revision: revision) else {
                await manager.stop()
                return
            }
            guard let channel = outcome.channel as? any IOSRunnerClipboardChannel,
                  let context = try? await channel.authenticatedClipboardContext(),
                  await HelperSessionAuthenticator(channel: channel).verifyExisting(context) else {
                guard await iosClipboardMatches(session, revision: revision) else { return }
                invalidateIOSClipboardHost(reason: outcome.failure?.safeMessage
                    ?? "The iOS clipboard Host did not establish an authenticated channel. Retry clipboard access.",
                    recoveryAction: outcome.failure?.recoveryAction)
                return
            }
            guard await iosClipboardMatches(session, revision: revision) else { return }
            clipboardService = ClipboardService(store: store, channel: channel,
                sessionNonce: context.sessionNonce, helperDeviceID: context.helperDeviceID)
            clipboardReadiness = .ready
            isConnectionMaintained = true
            iosClipboardPreparationObservationTask?.cancel()
            iosClipboardPreparationObservationTask = nil
            iosClipboardPreparation?.finish(.ready)
            lastSuccessfulCommandAt = Date()
            iosClipboardHeartbeatTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(10)) } catch { return }
                    guard let self, await self.iosClipboardMatches(session, revision: revision) else { return }
                    let valid = await HelperSessionAuthenticator(channel: channel).verifyExisting(context)
                    guard await self.iosClipboardMatches(session, revision: revision) else { return }
                    guard valid else {
                        self.invalidateIOSClipboardHost(reason: "The iOS clipboard session ended. Retry clipboard access.")
                        return
                    }
                    self.lastSuccessfulCommandAt = Date()
                }
            }
        } catch {
            guard !Task.isCancelled, selectionRevision == revision else { return }
            let message = (error as? IOSRunnerSourceConfigurationError) == .signingTeamRequired
                ? "Set your existing Apple development Team ID in Settings, then retry clipboard access."
                : "The bundled iOS clipboard Host is missing or invalid. Rebuild the app and retry."
            clipboardReadiness = .actionRequired(message)
            let failedStage = iosClipboardPreparation?.stage ?? .building
            iosClipboardPreparation?.finish(.failed(failedStage, message, nil))
        }
    }

    private func observeIOSClipboardPreparation(manager: any IOSRunnerManaging,
                                                session: ConnectionSession, revision: Int) {
        iosClipboardPreparationObservationTask?.cancel()
        let presentationID = iosClipboardPreparation?.id
        iosClipboardPreparationObservationTask = Task { [weak self] in
            while !Task.isCancelled {
                let state = await manager.preparationState()
                guard let self, await self.iosClipboardMatches(session, revision: revision),
                      self.iosClipboardPreparation?.id == presentationID,
                      self.iosClipboardPreparation?.isPreparing == true else { return }
                switch state {
                case .building: self.iosClipboardPreparation?.state = .preparing(.building)
                case .starting: self.iosClipboardPreparation?.state = .preparing(.starting)
                default: break
                }
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
        }
    }

    private func iosClipboardMatches(_ session: ConnectionSession, revision: Int) async -> Bool {
        let current = await store.snapshot().session
        return !Task.isCancelled && selectionRevision == revision
            && iosClipboardSession == session && current == session
    }

    private func observeIOSPreparation(manager: any IOSRunnerManaging, session: ConnectionSession, revision: Int) {
        iosRunnerPreparationObservationTask?.cancel()
        let presentationID = iosRunnerPreparation?.id
        iosRunnerPreparationObservationTask = Task { [weak self] in
            while !Task.isCancelled {
                let state = await manager.preparationState()
                guard let self, await self.iosRunnerMatches(session, revision: revision),
                      self.iosRunnerPreparation?.id == presentationID,
                      self.iosRunnerPreparation?.isPreparing == true else { return }
                switch state {
                case .building: self.iosRunnerPreparation?.state = .preparing(.building)
                case .starting: self.iosRunnerPreparation?.state = .preparing(.starting)
                default: break // Only the authenticated Workspace binding may finish the display.
                }
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
        }
    }

    private func iosRunnerMatches(_ session: ConnectionSession, revision: Int) async -> Bool {
        let current = await store.snapshot().session
        return !Task.isCancelled && selectionRevision == revision
            && iosRunnerSession == session && current == session
    }

    /// Synchronous invalidation precedes asynchronous native cleanup. New preparation drains it.
    private func detachIOSRunner() {
        informationRunnerLaunchID = nil
        informationRunnerChannel = nil
        if let session = deviceInformation.session, session.deviceIdentity.platform == .iOS,
           let device = selectedDevice {
            deviceInformation.cancel()
            bindDeviceInformation(device: device, session: session)
        }
        iosRunnerPreparationObservationTask?.cancel()
        iosRunnerPreparationObservationTask = nil
        iosRunnerPreparation = nil
        iosRunnerHeartbeatTask?.cancel()
        iosRunnerHeartbeatTask = nil
        iosRunnerSession = nil
        guard let manager = iosRunnerManager else { return }
        iosRunnerManager = nil
        let previous = iosRunnerCleanupTask
        iosRunnerCleanupTask = Task {
            await previous?.value
            await manager.stop()
        }
    }

    private func invalidateIOSRunner(reason: String, recoveryAction: String? = nil) {
        var presentation = iosRunnerPreparation
        let failedStage = presentation?.stage ?? .starting
        detachIOSRunner()
        presentation?.finish(.failed(failedStage, reason, recoveryAction))
        iosRunnerPreparation = presentation
        screenshotOperationTask?.cancel()
        screenshotOperationTask = nil
        let previous = screenshotService
        screenshotService = nil
        screenshotReadiness = .actionRequired(reason)
        currentScreenshotArtifact = nil
        isCapturingScreenshot = false
        isConnectionMaintained = iosClipboardManager != nil
        Task { await previous?.clearSessionArtifacts() }
    }

    private func detachIOSClipboardHost() {
        iosClipboardPreparationObservationTask?.cancel()
        iosClipboardPreparationObservationTask = nil
        iosClipboardPreparation = nil
        iosClipboardHeartbeatTask?.cancel()
        iosClipboardHeartbeatTask = nil
        iosClipboardSession = nil
        guard let manager = iosClipboardManager else { return }
        iosClipboardManager = nil
        let previous = iosClipboardCleanupTask
        iosClipboardCleanupTask = Task {
            await previous?.value
            await manager.stop()
        }
    }

    private func invalidateIOSClipboardHost(reason: String, recoveryAction: String? = nil) {
        var presentation = iosClipboardPreparation
        let failedStage = presentation?.stage ?? .starting
        detachIOSClipboardHost()
        presentation?.finish(.failed(failedStage, reason, recoveryAction))
        iosClipboardPreparation = presentation
        clipboardOperationTask?.cancel()
        clipboardOperationTask = nil
        clipboardService = nil
        clipboardReadiness = .actionRequired(reason)
        isClipboardBusy = false
        clipboardText = ""
        clipboardFeedback = nil
        clipboardRecoveryAction = nil
        clipboardExportGeneration += 1
        isConnectionMaintained = iosRunnerManager != nil
    }

    var iosPreparations: [IOSPreparationPresentation] {
        [iosClipboardPreparation, iosRunnerPreparation].compactMap { $0 }
    }

    var canStopIOSRunner: Bool { iosRunnerManager != nil || iosClipboardManager != nil }

    func canStopIOSPreparation(_ owner: IOSPreparationPresentation.Owner) -> Bool {
        switch owner {
        case .clipboard: iosClipboardManager != nil
        case .screenshot: iosRunnerManager != nil
        }
    }

    func canReconnectIOSPreparation(_ owner: IOSPreparationPresentation.Owner) -> Bool {
        let preparation = owner == .clipboard ? iosClipboardPreparation : iosRunnerPreparation
        return selectedDevice?.identity.platform == .iOS && !isSelecting
            && preparation?.isPreparing != true && !isTransferringFile && !isMonitoringMemory
    }

    func reconnectIOSPreparation(_ owner: IOSPreparationPresentation.Owner) {
        guard canReconnectIOSPreparation(owner), let device = selectedDevice else { return }
        let revision = selectionRevision
        let retryClipboard = owner == .clipboard
        if retryClipboard {
            clipboardOperationTask?.cancel()
            clipboardReadiness = .preparing
        } else {
            screenshotOperationTask?.cancel()
            screenshotReadiness = .preparing
        }
        let task = Task { [weak self] in
            guard let self, let session = await self.store.snapshot().session,
                  session.deviceIdentity == device.identity else { return }
            if retryClipboard {
                await self.prepareIOSClipboardHost(for: device, session: session, revision: revision)
            } else {
                await self.prepareIOSRunner(for: device, session: session, revision: revision)
            }
            guard self.selectionRevision == revision else { return }
            if retryClipboard { self.clipboardOperationTask = nil }
            else { self.screenshotOperationTask = nil }
        }
        if retryClipboard { clipboardOperationTask = task }
        else { screenshotOperationTask = task }
    }

    func stopIOSRunner() {
        guard canStopIOSRunner else { return }
        if isSelecting {
            selectionTask?.cancel()
            isSelecting = false
        }
        if iosRunnerManager != nil { stopIOSPreparation(.screenshot) }
        if iosClipboardManager != nil { stopIOSPreparation(.clipboard) }
    }

    func stopIOSPreparation(_ owner: IOSPreparationPresentation.Owner) {
        guard canStopIOSPreparation(owner) else { return }
        switch owner {
        case .clipboard:
            invalidateIOSClipboardHost(reason: "The iOS clipboard Host is stopped. Retry clipboard access to resume.")
            iosClipboardPreparation?.finish(.stopped)
        case .screenshot:
            invalidateIOSRunner(reason: "The iOS screenshot runner is stopped. Retry screenshot access to resume.")
            iosRunnerPreparation?.finish(.stopped)
        }
    }

    private func prepareClipboard(for device: DeviceRecord, resuming context: HelperSessionContext? = nil) async {
        clipboardReadiness = .preparing
        let previousManager = androidHelperManager
        androidHelperManager = nil
        if context != nil { await previousManager?.detach() }
        else { await previousManager?.stop() }
        guard !Task.isCancelled else { return }

        if arguments.contains("--fixture-devices") {
            let channel = FixtureHelperChannel()
            await finishClipboardPreparation(channel: channel)
            return
        }

        guard device.identity.platform == .android else {
            clipboardReadiness = .preparing
            return
        }
        guard let adbURL,
              let transportID = device.preferredTransportID,
              let artifact = Self.androidHelperArtifact() else {
            clipboardReadiness = .actionRequired(
                "Build or embed the Android helper APK, then retry the device."
            )
            return
        }

        let manager = AndroidHelperManager(
            adbURL: adbURL,
            apkURL: artifact.url,
            expectedVersionCode: artifact.versionCode,
            runner: runner
        )
        let outcome = if context != nil {
            await manager.reattach(transportID: transportID)
        } else {
            await manager.prepare(transportID: transportID)
        }
        guard !Task.isCancelled else {
            if context != nil { await manager.detach() }
            else { await manager.stop() }
            return
        }
        guard let connection = outcome.connection else {
            clipboardReadiness = .actionRequired(
                outcome.failure?.safeMessage ?? "The Android helper is not ready."
            )
            return
        }

        do {
            let channel = try TCPHelperChannel(hostPort: connection.hostPort)
            let prepared: HelperSessionContext?
            if let context {
                prepared = await HelperSessionAuthenticator(channel: channel).verifyExisting(context) ? context : nil
            } else {
                prepared = await authenticate(channel: channel)
            }
            guard !Task.isCancelled else {
                if context != nil { await manager.detach() }
                else { await manager.stop() }
                return
            }
            guard let prepared else {
                if context != nil { await manager.detach() }
                else { await manager.stop() }
                clipboardReadiness = .actionRequired(
                    "Open the Device Bridge helper on the Android device, then select the device again."
                )
                return
            }
            androidHelperManager = manager
            helperContext = prepared
            clipboardService = ClipboardService(
                store: store,
                channel: channel,
                sessionNonce: prepared.sessionNonce,
                helperDeviceID: prepared.helperDeviceID
            )
            clipboardReadiness = .ready
            await prepareAndroidKeepAlive(
                for: device,
                channel: channel,
                context: prepared
            )
        } catch {
            if context != nil { await manager.detach() }
            else { await manager.stop() }
            clipboardReadiness = .actionRequired("The Android helper channel could not be opened.")
        }
    }

    private func finishClipboardPreparation(channel: any HelperRequestSending) async {
        guard let context = await authenticate(channel: channel), !Task.isCancelled else { return }
        helperContext = context
        clipboardService = ClipboardService(
            store: store,
            channel: channel,
            sessionNonce: context.sessionNonce,
            helperDeviceID: context.helperDeviceID
        )
        clipboardReadiness = .ready
    }

    private func startConnectionMaintenance(for device: DeviceRecord, revision: Int) async {
        guard device.identity.platform == .android,
              let session = await store.snapshot().session,
              session.deviceIdentity == device.identity,
              let candidate = device.candidates.first(where: { $0.id == session.transportID }),
              !Task.isCancelled, selectionRevision == revision else { return }
        let transport: any ConnectionMaintenanceTransport
        if arguments.contains("--fixture-devices") {
            if fixtureRecoveryTransport == nil {
                fixtureRecoveryTransport = WorkspaceRecoveryTransport(injectRecovery: arguments.contains("--fixture-recovery"))
            }
            transport = fixtureRecoveryTransport!
        } else if let adbURL {
            transport = AndroidConnectionTransport(adbURL: adbURL, runner: runner,
                context: helperContext, selectedCandidate: candidate)
        } else { return }
        let controller = ConnectionMaintenance(store: store, transport: transport, device: device, session: session)
        guard await controller.activate(), !Task.isCancelled, selectionRevision == revision else {
            await controller.stop(); return
        }
        maintenance = controller
        isConnectionMaintained = true
        maintenanceTask = Task { [weak self] in
            while !Task.isCancelled {
                let delay: Duration = await controller.nextDelay
                let isFixture = self?.arguments.contains("--fixture-recovery") == true
                do { try await Task.sleep(for: isFixture ? .milliseconds(350) : delay) } catch { return }
                let update = await controller.tick()
                guard let self, !Task.isCancelled, self.selectionRevision == revision,
                      self.maintenance === controller else { return }
                if self.connectionHealth != update.health,
                   update.health == .suspect || update.health == .reconnecting || update.health == .actionRequired {
                    self.clipboardExportGeneration += 1
                }
                self.connectionHealth = update.health
                self.connectionRecoveryAttempt = update.recoveryAttempt
                if let date = update.lastSuccessfulCommandAt { self.lastSuccessfulCommandAt = date }
                if update.health == .reconnecting || update.health == .actionRequired {
                    self.cancelDisconnectedContent()
                }
                if update.health == .recovered && update.session.state == .selecting {
                    let state = await self.store.snapshot()
                    guard !Task.isCancelled, self.selectionRevision == revision,
                          state.session == update.session else { return }
                    self.publishInventory(state)
                    let context = self.helperContext
                    self.select(update.session.deviceIdentity, resuming: context)
                    self.connectionRecoveryCount += 1
                    return
                }
            }
        }
    }

    private func cancelDisconnectedContent() {
        invalidateAndroidCommands()
        deviceInformation.invalidate()
        if selectedDevice?.identity.platform == .iOS {
            invalidateIOSMemory(reason: "The iOS device route changed. Select the device again.")
        }
        imageBrowser?.stop()
        imageBrowser = nil
        clipboardOperationTask?.cancel()
        screenshotOperationTask?.cancel()
        fileTransferTask?.cancel()
        cancelMemoryPreparation()
        isClipboardBusy = false
        isCapturingScreenshot = false
        isTransferringFile = false
        clipboardText = ""
        clipboardFeedback = nil
        clipboardRecoveryAction = nil
        memorySamples = []
        isMonitoringMemory = false
        let monitor = memoryMonitor
        Task { await monitor?.stop() }
    }

    func pauseConnectionMaintenance() {
        let controller = maintenance
        maintenance = nil
        maintenanceTask?.cancel()
        maintenanceTask = nil
        isConnectionMaintained = false
        connectionHealth = .stopped
        stopAndroidConnectionMaintenance()
        Task { await controller?.stop() }
    }

    private func prepareAndroidKeepAlive(
        for device: DeviceRecord,
        channel: any HelperRequestSending,
        context: HelperSessionContext
    ) async {
        guard let transportID = device.preferredTransportID,
              let transport = device.candidates.first(where: { $0.id == transportID }),
              transport.kind == .wifi else {
            androidKeepAliveState = .idle
            return
        }

        let controller = AndroidKeepAliveController(
            store: store,
            channel: channel,
            sessionNonce: context.sessionNonce,
            helperDeviceID: context.helperDeviceID
        )
        androidKeepAliveController = controller
        androidKeepAliveState = .starting
        let outcome = await controller.start()
        guard !Task.isCancelled, androidKeepAliveController === controller else {
            await controller.stop()
            return
        }
        androidKeepAliveState = await controller.state
        guard outcome.lease != nil else { return }
        observeKeepAlive(controller)
    }

    private func observeKeepAlive(_ controller: AndroidKeepAliveController) {
        keepAliveObservationTask?.cancel()
        keepAliveObservationTask = Task { [weak self] in
            while !Task.isCancelled {
                let state = await controller.state
                guard let self, self.androidKeepAliveController === controller else { return }
                self.androidKeepAliveState = state
                if !self.isAndroidKeepAliveActive { return }
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
            }
        }
    }

    private func authenticate(
        channel: any HelperRequestSending
    ) async -> HelperSessionContext? {
        guard let nonce = Self.makeSessionNonce() else { return nil }
        for attempt in 0..<5 {
            let outcome = await HelperSessionAuthenticator(channel: channel)
                .authenticate(sessionNonce: nonce)
            if let context = outcome.context { return context }
            guard attempt < 4, !Task.isCancelled else { break }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return nil
    }

    private func applyClipboardOutcome(
        _ outcome: ClipboardOperationOutcome,
        foregroundDisposition: ClipboardForegroundDisposition?
    ) {
        clipboardRecoveryAction = nil
        switch outcome {
        case let .snapshot(snapshot):
            clipboardText = snapshot.text
            clipboardFeedback = foregroundDisposition == .clipboardHostRemainsForeground
                ? "Read · The iOS clipboard host remains foreground; return to your app when ready." : "Read"
        case .written:
            clipboardFeedback = foregroundDisposition == .clipboardHostRemainsForeground
                ? "Sent · The iOS clipboard host remains foreground; return to your app when ready." : "Sent"
        case let .failure(failure):
            clipboardFeedback = failure.safeMessage
            clipboardRecoveryAction = failure.recoveryAction
        case .stale:
            clipboardFeedback = "Device selection changed; the result was discarded."
        }
    }

    private static func makeSessionNonce() -> String? {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return nil
        }
        return Data(bytes).base64EncodedString()
    }

    private struct AndroidHelperArtifactManifest: Decodable {
        let artifact: String
        let versionCode: Int
    }

    private struct HelperArtifactManifest: Decodable {
        let schemaVersion: Int
        let android: AndroidHelperArtifactManifest
    }

    private struct AndroidHelperArtifact {
        let url: URL
        let versionCode: Int
    }

    private static func androidHelperArtifact() -> AndroidHelperArtifact? {
        let fileManager = FileManager.default
        guard let manifestURL = Bundle.main.url(
            forResource: "manifest",
            withExtension: "json",
            subdirectory: "Helpers"
        ),
            let manifestData = try? Data(contentsOf: manifestURL),
            let manifest = try? JSONDecoder().decode(HelperArtifactManifest.self, from: manifestData),
            manifest.schemaVersion == 1,
            manifest.android.versionCode > 0 else {
            return nil
        }

        if let explicitPath = ProcessInfo.processInfo.environment["DEVICE_BRIDGE_ANDROID_HELPER_APK"],
           fileManager.fileExists(atPath: explicitPath) {
            return AndroidHelperArtifact(
                url: URL(fileURLWithPath: explicitPath),
                versionCode: manifest.android.versionCode
            )
        }

        let bundled = manifestURL.deletingLastPathComponent()
            .appending(path: manifest.android.artifact)
        if fileManager.fileExists(atPath: bundled.path) {
            return AndroidHelperArtifact(
                url: bundled,
                versionCode: manifest.android.versionCode
            )
        }
#if DEBUG
        var repository = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { repository.deleteLastPathComponent() }
        let developmentAPK = repository.appending(
            path: "helpers/android/app/build/outputs/apk/debug/app-debug.apk"
        )
        if fileManager.fileExists(atPath: developmentAPK.path) {
            return AndroidHelperArtifact(
                url: developmentAPK,
                versionCode: manifest.android.versionCode
            )
        }
#endif
        return nil
    }

    private static func fixtureDevices() -> [DeviceRecord] {
        [
            fixtureDevice(name: "Android Test Device", rawID: "android-fixture", platform: .android),
            fixtureDevice(name: "iOS Test Device", rawID: "ios-fixture", platform: .iOS),
        ].compactMap { $0 }
    }

    private static func fixtureDevice(
        name: String,
        rawID: String,
        platform: DevicePlatform
    ) -> DeviceRecord? {
        guard let identity = try? DeviceIdentity(
            rawValue: rawID,
            stability: .stable,
            platform: platform
        ), let candidate = try? TransportCandidate(
            id: "\(rawID)-usb",
            identity: identity,
            kind: .usb,
            source: platform == .android ? .adb : .coreDevice,
            status: .available,
            observedAt: Date()
        ) else { return nil }

        return DeviceRecord(
            identity: identity,
            name: name,
            authorization: .authorized,
            candidates: [candidate],
            preferredTransportID: candidate.id
        )
    }
}

private actor WorkspaceRecoveryTransport: ConnectionMaintenanceTransport {
    private let injectRecovery: Bool
    private var probes = 0
    init(injectRecovery: Bool) { self.injectRecovery = injectRecovery }
    func observeCurrentRoute(_ candidate: TransportCandidate) async throws -> Bool { true }
    func probe(_ candidate: TransportCandidate) async throws -> Bool {
        probes += 1
        return !injectRecovery || probes > 2
    }
    func discover() async throws -> [TransportCandidate] {
        guard injectRecovery else { return [] }
        return [try TransportCandidate(id: "fixture-recovered-wifi",
            identity: DeviceIdentity(rawValue: "recovered-candidate", stability: .provisional, platform: .android),
            kind: .wifi, source: .adb, status: .candidate, observedAt: Date())]
    }
    func recoveryEndpoints(for candidate: TransportCandidate) async throws -> [String] { [] }
    func connect(endpoint: String) async throws {}
    func verifyIdentity(_ candidate: TransportCandidate) async throws -> Bool { injectRecovery }
}

private actor FixtureHelperChannel: HelperRequestSending {
    private let helperDeviceID = "fixture-helper"
    private var clipboardText = "Fixture device clipboard 📋"

    func send(_ request: HelperRequest) async throws -> HelperResult {
        switch request.action {
        case .identity:
            return HelperResult(
                requestID: request.requestID,
                status: .success,
                completedAt: Date(),
                payload: [
                    "helperDeviceId": .string(helperDeviceID),
                    "helperVersion": .string("fixture"),
                    "protocolVersions": .array([.number(1)]),
                ]
            )
        case .clipboardRead:
            return HelperResult(
                requestID: request.requestID,
                status: .success,
                completedAt: Date(),
                payload: ["text": .string(clipboardText)]
            )
        case .clipboardWrite:
            guard let text = request.payload["text"]?.stringValue else {
                return HelperResult(
                    requestID: request.requestID,
                    status: .invalid,
                    completedAt: Date(),
                    error: HelperErrorPayload(
                        code: "clipboard.missing_text",
                        message: "Clipboard text is missing."
                    )
                )
            }
            clipboardText = text
            return HelperResult(
                requestID: request.requestID,
                status: .success,
                completedAt: Date(),
                payload: ["written": .bool(true)]
            )
        default:
            return HelperResult(
                requestID: request.requestID,
                status: .invalid,
                completedAt: Date(),
                error: HelperErrorPayload(
                    code: "action.unsupported",
                    message: "The fixture action is unsupported."
                )
            )
        }
    }
}

private actor FixtureScreenshotProvider: ScreenshotProviding {
    func capture(transportID: String) async throws -> ScreenshotCapturePayload {
        let encoded = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9Zl1sAAAAASUVORK5CYII="
        guard let data = Data(base64Encoded: encoded) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return ScreenshotCapturePayload(data: data, capturedAt: Date())
    }
}

private actor FixtureFileProvider: DeviceFileProviding {
    func send(
        localURL: URL,
        destination: DeviceFileLocation,
        transportID: String,
        operationID: UUID,
        replaceExisting: Bool
    ) async throws -> DeviceFileReceipt {
        let metadata = try FileIntegrity.metadata(for: localURL)
        return DeviceFileReceipt(byteLength: metadata.byteLength, sha256: metadata.sha256)
    }

    func receive(
        source: DeviceFileLocation,
        localPartialURL: URL,
        transportID: String,
        operationID: UUID
    ) async throws -> DeviceFileReceipt {
        let data = Data("Fixture file from device\n".utf8)
        try data.write(to: localPartialURL)
        let metadata = try FileIntegrity.metadata(for: localPartialURL)
        return DeviceFileReceipt(byteLength: metadata.byteLength, sha256: metadata.sha256)
    }
}

private actor FixtureMemorySampler: MemorySampling {
    private let target: TargetApplication
    private var sampleNumber: Int64 = 0

    init(target: TargetApplication) {
        self.target = target
    }

    func sample(
        target requestedTarget: TargetApplication,
        transportID: String
    ) async -> MemoryProviderOutcome {
        guard requestedTarget.deviceIdentity == target.deviceIdentity,
              requestedTarget.applicationID == target.applicationID else {
            return .failure(OperationFailure(
                code: .failure,
                safeMessage: "The fixture application selection changed."
            ))
        }
        sampleNumber += 1
        return .sample(MemorySample(
            deviceIdentity: target.deviceIdentity,
            applicationID: target.applicationID,
            processID: target.processID ?? 101,
            processStartIdentity: target.processStartIdentity,
            capturedAt: Date(),
            source: .androidMeminfo,
            rssBytes: (64 + sampleNumber) * 1_024 * 1_024,
            pssBytes: (48 + sampleNumber) * 1_024 * 1_024
        ))
    }
}

private struct FixtureInformationProvider: DeviceInformationProviding {
    func read(device: DeviceRecord, session: ConnectionSession, deadline: ContinuousClock.Instant,
              validateSession: @escaping @Sendable () async throws -> Void) async throws -> DeviceInformationReport {
        try await validateSession()
        let now = Date()
        let source = DeviceInformationSource(kind: .session, queriedAt: now)
        return try DeviceInformationReport(deviceName: device.name, session: session,
            queryStartedAt: now, queryFinishedAt: now,
            sections: DeviceInformationCatalog.makeSections(values: [
                "identity.name": DeviceInformationCatalog.field("identity.name", value: .text(device.name), source: source),
                "identity.platform": DeviceInformationCatalog.field("identity.platform",
                    value: .text(device.identity.platform == .iOS ? "iOS" : "Android"), source: source)
            ]))
    }
}

private struct FixtureShellExecutor: AndroidShellExecuting {
    func run(command: String, session: ConnectionSession, operationID: UUID,
             origin: DeviceOperationOrigin, startedAt: Date, deadline: ContinuousClock.Instant) async -> AndroidShellOutcome {
        .execution(AndroidShellExecution(id: operationID, origin: origin, session: session, command: command,
            startedAt: startedAt, finishedAt: Date(), stdout: Data("Fixture output\n".utf8), stderr: Data(),
            completion: .remoteExit(0)))
    }
}
