@testable import DeviceBridgeCore
import DeviceBridgeProtocol
import Foundation

/// Real Workspace admission, synthetic inventory only; no windows or device commands.
@main
struct IOSMemoryAdmissionChecks {
    @MainActor
    static func main() async {
        do { try await runChecks() }
        catch { FileHandle.standardError.write(Data("FAIL: Workspace memory check did not complete\n".utf8)); exit(1) }
    }

    @MainActor
    static func runChecks() async throws {
        let model = WorkspaceViewModel(arguments: ["--fixture-devices"])
        defer { model.stop() }
        model.start()
        try await wait { !model.isRefreshing }
        let phone = model.devices.first { $0.identity.platform == .iOS }!
        model.select(phone.identity)
        try await wait { !model.isSelecting && model.canDiscoverMemory }
        model.vmServiceURIText = "http://127.0.0.1:54321/synthetic-unverified=/"
        model.startFlutterMemoryMonitoring()
        // Check synchronously before a scheduled monitor can perform network I/O.
        guard !model.isMonitoringMemory, model.memorySamples.isEmpty else {
            print("FAIL: unverified iOS candidate started a device memory monitor")
            exit(1)
        }
        guard model.memoryFeedback != nil else {
            print("FAIL: rejected iOS attach needs an actionable explanation")
            exit(1)
        }
        guard !model.canAttachFlutterVM else {
            print("FAIL: iOS attach button admitted an unverified candidate")
            exit(1)
        }
        let android = model.devices.first { $0.identity.platform == .android }!
        model.select(android.identity)
        try await wait { !model.isSelecting && model.canAttachFlutterVM }
        guard model.canAttachFlutterVM else {
            print("FAIL: iOS admission gate disabled existing Android attach")
            exit(1)
        }
        model.stop()
        guard !model.canAttachFlutterVM else {
            print("FAIL: stopped workspace admits VM attachment")
            exit(1)
        }
        try await verifiedIOSLifecycle()
        try await cancelledIOSDiscovery()
        try await screenshotPreparationDoesNotBlockMemory()
        try await staleMemoryCallbackInvalidatesReadiness()
        print("PASS: manual iOS VM candidate cannot start monitoring or publish a device sample")
    }

    @MainActor
    static func verifiedIOSLifecycle() async throws {
        let provider = WorkspaceVMFixture()
        let model = WorkspaceViewModel(arguments: ["--fixture-devices"], iosMemoryProvider: provider)
        defer { model.stop() }
        model.start()
        try await wait { !model.isRefreshing }
        let phone = model.devices.first { $0.identity.platform == .iOS }!
        model.select(phone.identity)
        try await wait { model.targetApplications.count == 2 && !model.isSelecting }
        try require(!model.canStartIOSMemory && !model.isMonitoringMemory, "ambiguous app inventory was marked ready")
        model.selectedMemoryApplicationID = "dev.example.one"
        try await wait { model.canStartIOSMemory }
        try require(await provider.contentRequests == 0, "discovery read memory automatically")
        model.vmServiceURIText = "http://127.0.0.1:54321/synthetic-unverified=/"
        model.startFlutterMemoryMonitoring()
        try await wait { !model.memorySamples.isEmpty }
        try require(model.memorySamples.allSatisfy { $0.applicationID == "dev.example.one" && $0.deviceIdentity == phone.identity }, "sample attribution changed")
        model.stopMemoryMonitoring()
        try require(!model.isMonitoringMemory && !model.canStartIOSMemory && model.memorySamples.isEmpty, "Stop retained readiness or trend")
        try await waitAsync { await provider.allClosed }
        let oldRequests = await provider.contentRequests
        model.retryIOSMemoryDiscovery()
        try await wait { model.canStartIOSMemory }
        try require(await provider.contentRequests == oldRequests, "retry restarted sampling")
        model.selectedMemoryApplicationID = "dev.example.two"
        try await wait { model.canStartIOSMemory }
        model.startFlutterMemoryMonitoring()
        try await wait { !model.memorySamples.isEmpty }
        try require(model.memorySamples.allSatisfy { $0.applicationID == "dev.example.two" }, "old application series leaked")
        model.stop()
        try require(!model.canStartIOSMemory && model.memorySamples.isEmpty, "workspace Stop retained VM state")
        try await waitAsync { await provider.allClosed }
        print("PASS: verified iOS app selection, explicit samples, Stop, retry and app replacement")
    }

    @MainActor
    static func cancelledIOSDiscovery() async throws {
        for holdAfterBinding in [false, true] { for switchDevice in [false, true] {
            let provider = WorkspaceVMFixture(holdBinding: true, holdAfterBinding: holdAfterBinding)
            let model = WorkspaceViewModel(arguments: ["--fixture-devices"], iosMemoryProvider: provider)
            model.start()
            try await wait { !model.isRefreshing }
            model.select(model.devices.first { $0.identity.platform == .iOS }!.identity)
            try await wait { model.targetApplications.count == 2 && !model.isSelecting }
            model.selectedMemoryApplicationID = "dev.example.one"
            try await waitAsync { await provider.gate.isHeld }
            if switchDevice { model.select(model.devices.first { $0.identity.platform == .android }!.identity) }
            else { model.stopMemoryMonitoring() }
            await provider.gate.release()
            try await waitAsync { await provider.bindingFinished }
            try await waitAsync { await provider.allClosed }
            if switchDevice { try await wait { !model.isSelecting && model.canAttachFlutterVM } }
            try require(!model.canStartIOSMemory && !model.isMonitoringMemory && model.memorySamples.isEmpty, "late discovery revived invalidated iOS state")
            try require(await provider.allClosed, "late binding retained its owner")
            model.stop()
        } }
        print("PASS: Stop and device replacement reject late iOS discovery")
    }

    @MainActor
    static func staleMemoryCallbackInvalidatesReadiness() async throws {
        for stop in [false, true] {
            let provider = WorkspaceVMFixture(holdMemory: true)
            let model = WorkspaceViewModel(arguments: ["--fixture-devices"], iosMemoryProvider: provider)
            defer { model.stop() }
            model.start()
            try await wait { !model.isRefreshing }
            model.select(model.devices.first { $0.identity.platform == .iOS }!.identity)
            try await wait { model.targetApplications.count == 2 && !model.isSelecting }
            model.selectedMemoryApplicationID = "dev.example.one"
            try await wait { model.canStartIOSMemory }
            model.startFlutterMemoryMonitoring()
            try await waitAsync { await provider.gate.isHeld }
            if stop { model.stopMemoryMonitoring() }
            else { try await provider.replaceSessionGeneration() }
            await provider.gate.release()
            try await wait { !model.isMonitoringMemory }
            try await waitAsync { await provider.allClosed }
            try require(!model.canStartIOSMemory && model.memoryReadiness != .ready && model.memorySamples.isEmpty,
                "stale callback or Stop retained VM readiness")
        }
        print("PASS: in-flight Stop and store-only invalidation revoke readiness before inventory publication")
    }

    @MainActor
    static func screenshotPreparationDoesNotBlockMemory() async throws {
        let provider = WorkspaceVMFixture()
        let inventory = WorkspaceVMInventory()
        let runner = PausedVMRunnerManager()
        let model = WorkspaceViewModel(arguments: [], runner: inventory,
            iosRunnerFactory: { _ in runner }, iosMemoryProvider: provider)
        defer { model.stop() }
        model.start()
        try await wait { !model.isRefreshing && model.devices.count == 1 }
        model.select(model.devices[0].identity)
        try await wait { !model.isSelecting && model.targetApplications.count == 2 }
        try require(await !runner.gate.isHeld, "device selection prepared the screenshot runner")
        model.selectedMemoryApplicationID = "dev.example.one"
        try await wait { model.memoryReadiness == .ready }
        let admittedWithoutRunner = model.canStartIOSMemory
        model.requestScreenshotCapture()
        try await waitAsync { await runner.gate.isHeld }
        let admittedDuringRunnerPreparation = model.canStartIOSMemory
        await runner.gate.release()
        try await wait { !model.isCapturingScreenshot }
        try require(admittedWithoutRunner, "unrelated screenshot preparation blocked verified memory")
        try require(admittedDuringRunnerPreparation, "explicit screenshot preparation blocked verified memory")
        await inventory.changeRoute()
        model.requestRefresh()
        try await wait { !model.isRefreshing }
        try require(!model.canStartIOSMemory && !model.isMonitoringMemory, "changed route retained VM readiness")
        try await waitAsync { await provider.allClosed }
        print("PASS: selection does not prepare the runner; explicit screenshot preparation is independent; observed route replacement invalidates VM")
    }

    static func require(_ condition: Bool, _ message: String) throws {
        guard condition else {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            throw CheckFailure.assertion
        }
    }

    @MainActor
    static func waitAsync(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw CheckFailure.timeout }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @MainActor
    static func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw CheckFailure.timeout }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    enum CheckFailure: Error { case timeout, assertion }
}

/// Only external device/process/RPC boundaries are synthetic. Store, issuer, binding and monitor are real.
private actor WorkspaceVMFixture: IOSWorkspaceVMProviding {
    let gate = WorkspaceVMGate()
    let holdBinding: Bool
    let holdAfterBinding: Bool
    let holdMemory: Bool
    private var store: DeviceSessionStore?
    private var channels: [WorkspaceVMRPC] = []
    private(set) var bindingFinished = false
    init(holdBinding: Bool = false, holdAfterBinding: Bool = false, holdMemory: Bool = false) {
        self.holdBinding = holdBinding; self.holdAfterBinding = holdAfterBinding; self.holdMemory = holdMemory
    }
    func replaceSessionGeneration() async throws {
        guard let store, let identity = await store.snapshot().selectedDeviceIdentity else { throw IOSMemoryAdmissionChecks.CheckFailure.assertion }
        _ = try await store.select(identity)
    }
    var allClosed: Bool { get async { for channel in channels { if await !channel.closed { return false } }; return true } }
    var contentRequests: Int { get async { var count = 0; for channel in channels { count += await channel.contentRequests }; return count } }
    func applications(session: ConnectionSession) async throws -> [TargetApplication] {
        try await WorkspaceVMProcesses().load(session: session).applications.map(\.target)
    }
    func binding(store: DeviceSessionStore, session: ConnectionSession, applicationID: String) async throws -> IOSVerifiedVMBinding {
        defer { bindingFinished = true }
        self.store = store
        if holdBinding && !holdAfterBinding { await gate.hold() }
        let rpc = WorkspaceVMRPC(pid: applicationID == "dev.example.one" ? 700 : 701, memoryGate: holdMemory ? gate : nil)
        channels.append(rpc)
        do {
            let binding = try await IOSFlutterVMDiscovery(sessionStore: store, processes: WorkspaceVMProcesses(),
                connector: WorkspaceVMConnector(rpc: rpc)).verify(candidate: IOSVMCandidate(port: 12345,
                    authenticationCode: "synthetic-only="), session: session, applicationID: applicationID)
            if holdBinding && holdAfterBinding { await gate.hold() }
            return binding
        } catch { await rpc.close(); throw error }
    }
}

private struct WorkspaceVMProcesses: IOSApplicationProcessProviding {
    func load(session: ConnectionSession) async throws -> IOSApplicationProcessProvider.Inventory {
        let apps = ["dev.example.one", "dev.example.two"].enumerated().map { index, id in
            IOSApplicationProcessProvider.Application(target: TargetApplication(deviceIdentity: session.deviceIdentity,
                applicationID: id, displayName: id, processID: 700 + index, processStartIdentity: nil,
                debuggable: true, state: .running), installationURL: URL(fileURLWithPath: "/apps/\(id).app"),
                executableURL: URL(fileURLWithPath: "/apps/\(id).app/Runner"))
        }
        return IOSApplicationProcessProvider.Inventory(session: session, applications: apps)
    }
}

private struct WorkspaceVMConnector: IOSVMChannelConnecting {
    let rpc: WorkspaceVMRPC
    func connect(candidate: IOSVMCandidate, session: ConnectionSession, processID: Int) async throws -> IOSVMMetadataChannel {
        IOSVMMetadataChannel(transport: rpc, expectedProcessID: processID, selectedIsolateID: nil)
    }
}

private actor WorkspaceVMRPC: VMServiceRPCTransport {
    let pid: Int
    let memoryGate: WorkspaceVMGate?
    private(set) var closed = false
    private(set) var contentRequests = 0
    init(pid: Int, memoryGate: WorkspaceVMGate? = nil) { self.pid = pid; self.memoryGate = memoryGate }
    func request(method: String, parameters: [String: JSONValue]) async throws -> [String: JSONValue] {
        guard !closed else { throw IOSVMBindingError.closed }
        switch method {
        case "getVersion": return ["type": .string("Version"), "major": .number(4), "minor": .number(16)]
        case "getVM": return ["type": .string("VM"), "pid": .number(Double(pid)), "startTime": .number(1000),
            "version": .string("3.7.2 (stable)"), "isolates": .array([.object(["type": .string("@Isolate"), "id": .string("isolates/7")])])]
        case "getMemoryUsage":
            contentRequests += 1
            await memoryGate?.hold()
            return ["type": .string("MemoryUsage"), "heapUsage": .number(1024), "externalUsage": .number(0)]
        default: throw IOSVMBindingError.unavailable
        }
    }
    func close() { closed = true }
}

private actor WorkspaceVMGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var isHeld: Bool { continuation != nil }
    func hold() async { await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

private actor PausedVMRunnerManager: IOSRunnerManaging {
    let gate = WorkspaceVMGate()
    func prepare(deviceIdentifier: String) async -> IOSRunnerPreparationOutcome {
        await gate.hold()
        return IOSRunnerPreparationOutcome(failure: OperationFailure(code: .unsupported, safeMessage: "Synthetic runner unavailable"))
    }
    func stop() {}
}

private actor WorkspaceVMInventory: HostCommandRunning {
    private var route = "synthetic-memory-route-one"
    func changeRoute() { route = "synthetic-memory-route-two" }
    func run(_ request: HostCommandRequest) throws -> HostCommandResult {
        if request.arguments == ["devices", "-l"] {
            return HostCommandResult(exitCode: 0, standardOutput: Data("List of devices attached\n".utf8), standardError: Data())
        }
        if request.arguments.starts(with: ["devicectl", "list", "devices"]),
           let index = request.arguments.firstIndex(of: "--json-output") {
            let json = #"{"result":{"devices":[{"identifier":"ROUTE","hardwareProperties":{"udid":"synthetic-memory-phone","platform":"iOS","marketingName":"Test iPhone"},"connectionProperties":{"transportType":"wired","pairingState":"paired","tunnelState":"connected"},"deviceProperties":{"name":"Test iPhone","osVersionNumber":"18.3.1","developerModeStatus":"enabled","isLocked":false}}]}}"#
            try Data(json.replacingOccurrences(of: "ROUTE", with: route).utf8)
                .write(to: URL(fileURLWithPath: request.arguments[index + 1]))
        } else if !request.arguments.starts(with: ["devicectl", "device", "info", "details"]) {
            throw IOSMemoryAdmissionChecks.CheckFailure.assertion
        }
        return HostCommandResult(exitCode: 0, standardOutput: Data(), standardError: Data())
    }
}
