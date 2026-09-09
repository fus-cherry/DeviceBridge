import DeviceBridgeProtocol
import Foundation
import Testing
@testable import DeviceBridgeCore

@Suite("iOS managed runner lifecycle")
struct IOSRunnerManagerTests {
    @Test("reconnect reuses Xcode intermediates while launch products remain isolated")
    func incrementalReconnect() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = IOSManagerCommandRunner(exitCode: 0, writesProducts: true)
        let launcher = IOSLauncherFixture()
        let workspace = IOSRunnerBuildWorkspace(rootDirectoryURL: root.appendingPathComponent("incremental"))
        func makeSharedManager() -> IOSRunnerManager {
            IOSRunnerManager(xcodebuildURL: URL(fileURLWithPath: "/xcodebuild"),
            projectURL: URL(fileURLWithPath: "/runner.xcodeproj"), scheme: "Runner", signingTeamID: "TEAM",
            runner: runner, launcher: launcher, buildRootDirectoryURL: root.appendingPathComponent("launches"),
            buildWorkspace: workspace)
        }
        let previous = makeSharedManager()
        _ = await previous.prepare(deviceIdentifier: "ios-target")
        await previous.stop()
        let manager = makeSharedManager()
        _ = await manager.prepare(deviceIdentifier: "ios-target")
        let requests = await runner.requests
        let paths = requests.compactMap { request -> String? in
            guard let index = request.arguments.firstIndex(of: "-derivedDataPath") else { return nil }
            return request.arguments[index + 1]
        }
        #expect(paths.count == 2)
        #expect(paths.first == paths.last)
        let products = await launcher.startedBuildProducts
        #expect(products.count == 2)
        #expect(products.first?.derivedDataDirectoryURL != products.last?.derivedDataDirectoryURL)
        let first = try #require(products.first)
        let last = try #require(products.last)
        #expect(try String(contentsOf: first.productsDirectoryURL.appendingPathComponent("Debug-iphoneos/DeviceBridgeHost.app/binary"), encoding: .utf8) == "1")
        #expect(try String(contentsOf: last.productsDirectoryURL.appendingPathComponent("Debug-iphoneos/DeviceBridgeHost.app/binary"), encoding: .utf8) == "2")
        await manager.stop()
    }
    @Test("missing signing team is action-required without running Xcode")
    func signingRequired() async {
        let runner = IOSManagerCommandRunner(exitCode: 0)
        let launcher = IOSLauncherFixture()
        let manager = IOSRunnerManager(
            xcodebuildURL: URL(fileURLWithPath: "/usr/bin/xcodebuild"),
            projectURL: URL(fileURLWithPath: "/bundle/DeviceBridgeRunner.xcodeproj"),
            scheme: "DeviceBridgeRunner",
            signingTeamID: nil,
            runner: runner,
            launcher: launcher
        )

        let outcome = await manager.prepare(deviceIdentifier: "ios-target")

        #expect(outcome.failure?.code == .helperMissing)
        #expect(outcome.failure?.recoveryAction != nil)
        #expect(await manager.state == .signingRequired)
        #expect(await runner.requests.isEmpty)
    }

    @Test("existing personal signing builds Debug without portal updates before channel opening")
    func connectedLifecycle() async {
        let runner = IOSManagerCommandRunner(exitCode: 0)
        let launcher = IOSLauncherFixture()
        let manager = IOSRunnerManager(
            xcodebuildURL: URL(fileURLWithPath: "/usr/bin/xcodebuild"),
            projectURL: URL(fileURLWithPath: "/bundle/DeviceBridgeRunner.xcodeproj"),
            scheme: "DeviceBridgeRunner",
            signingTeamID: "TEAM123",
            runner: runner,
            launcher: launcher
        )

        let outcome = await manager.prepare(deviceIdentifier: "ios-target")
        let request = await runner.requests.first
        let products = await launcher.startedBuildProducts.first

        #expect(outcome.channel != nil)
        #expect(await manager.state == .connected)
        #expect(request?.arguments == [
            "build-for-testing",
            "-quiet",
            "-project", "/bundle/DeviceBridgeRunner.xcodeproj",
            "-scheme", "DeviceBridgeRunner",
            "-configuration", "Debug",
            "-derivedDataPath", products?.derivedDataDirectoryURL.path ?? "missing-build-products",
            "-destination", "id=ios-target",
            "CODE_SIGN_STYLE=Automatic",
            "DEVELOPMENT_TEAM=TEAM123",
        ])
        #expect(request?.arguments.contains("-allowProvisioningUpdates") == false)
        #expect(request?.arguments.contains("-allowProvisioningDeviceRegistration") == false)
        #expect(await launcher.startedDeviceIdentifiers == ["ios-target"])
        let launches = await launcher.startedLaunches
        #expect(products?.launchID == launches.first?.id)
        #expect(products?.expectedTeamIdentifier == "TEAM123")
        #expect(products?.derivedDataDirectoryURL.lastPathComponent == launches.first?.id.uuidString)
        #expect(products?.productsDirectoryURL.lastPathComponent == "Products")

        await manager.stop()
        await manager.stop()
        #expect(await manager.state == .stopped)
        #expect(await launcher.stoppedDeviceIdentifiers == ["ios-target"])
    }

    @Test("build and channel failures remain non-ready")
    func failures() async {
        let buildFailureManager = IOSRunnerManager(
            xcodebuildURL: URL(fileURLWithPath: "/xcodebuild"),
            projectURL: URL(fileURLWithPath: "/runner.xcodeproj"),
            scheme: "Runner",
            signingTeamID: "TEAM",
            runner: IOSManagerCommandRunner(exitCode: 65),
            launcher: IOSLauncherFixture()
        )
        let channelFailureManager = IOSRunnerManager(
            xcodebuildURL: URL(fileURLWithPath: "/xcodebuild"),
            projectURL: URL(fileURLWithPath: "/runner.xcodeproj"),
            scheme: "Runner",
            signingTeamID: "TEAM",
            runner: IOSManagerCommandRunner(exitCode: 0),
            launcher: IOSLauncherFixture(shouldFail: true)
        )

        #expect(await buildFailureManager.prepare(deviceIdentifier: "one").failure?.code == .helperMissing)
        #expect(await buildFailureManager.state == .failed)
        #expect(await channelFailureManager.prepare(deviceIdentifier: "two").failure?.code == .helperMissing)
        #expect(await channelFailureManager.state == .actionRequired)
    }

    @Test("stop during build rejects late success without launching")
    func stopDuringBuild() async {
        let gate = IOSLifecycleGate()
        let runner = IOSManagerCommandRunner(exitCode: 0, firstRunGate: gate)
        let launcher = IOSLauncherFixture()
        let manager = makeManager(runner: runner, launcher: launcher)
        let preparing = Task { await manager.prepare(deviceIdentifier: "ios-target") }
        await gate.waitUntilEntered()
        await manager.stop()
        await gate.release()

        let outcome = await preparing.value
        #expect(outcome.channel == nil)
        #expect(outcome.failure?.code == .cancelled)
        #expect(await manager.state == .stopped)
        #expect(await launcher.startedDeviceIdentifiers.isEmpty)
        #expect(await runner.observedCancellation)
    }

    @Test("stop during channel opening disposes a late channel")
    func stopDuringLaunch() async {
        let gate = IOSLifecycleGate()
        let launcher = IOSLauncherFixture(firstStartGate: gate)
        let manager = makeManager(launcher: launcher)
        let preparing = Task { await manager.prepare(deviceIdentifier: "ios-target") }
        await gate.waitUntilEntered()
        await manager.stop()
        await gate.release()

        let outcome = await preparing.value
        #expect(outcome.channel == nil)
        #expect(outcome.failure?.code == .cancelled)
        #expect(await manager.state == .stopped)
        #expect(await launcher.stoppedDeviceIdentifiers.contains("ios-target"))
    }

    @Test("concurrent preparation does not build or launch a second runner")
    func singleFlight() async {
        let gate = IOSLifecycleGate()
        let runner = IOSManagerCommandRunner(exitCode: 0, firstRunGate: gate)
        let launcher = IOSLauncherFixture()
        let manager = makeManager(runner: runner, launcher: launcher)
        let preparing = Task { await manager.prepare(deviceIdentifier: "ios-target") }
        await gate.waitUntilEntered()

        let duplicate = await manager.prepare(deviceIdentifier: "other-target")
        #expect(duplicate.channel == nil)
        #expect(duplicate.failure != nil)
        #expect(await runner.requests.count == 1)
        await gate.release()
        #expect(await preparing.value.channel != nil)
        #expect(await launcher.startedDeviceIdentifiers == ["ios-target"])
        await manager.stop()
    }

    @Test("caller cancellation cannot publish a successful launch")
    func cancelDuringLaunch() async {
        let gate = IOSLifecycleGate()
        let launcher = IOSLauncherFixture(firstStartGate: gate)
        let manager = makeManager(launcher: launcher)
        let preparing = Task { await manager.prepare(deviceIdentifier: "ios-target") }
        await gate.waitUntilEntered()
        preparing.cancel()
        await gate.release()

        let outcome = await preparing.value
        #expect(outcome.channel == nil)
        #expect(outcome.failure?.code == .cancelled)
        #expect(await manager.state == .stopped)
        #expect(await launcher.stoppedDeviceIdentifiers.contains("ios-target"))
    }

    @Test("an old failed build cannot overwrite a newer connected session")
    func lateBuildFailure() async {
        let gate = IOSLifecycleGate()
        let runner = IOSManagerCommandRunner(exitCode: 0, firstRunGate: gate, firstExitCode: 65)
        let launcher = IOSLauncherFixture()
        let manager = makeManager(runner: runner, launcher: launcher)
        let old = Task { await manager.prepare(deviceIdentifier: "old-target") }
        await gate.waitUntilEntered()
        await manager.stop()
        #expect(await manager.prepare(deviceIdentifier: "new-target").channel != nil)
        await gate.release()

        #expect(await old.value.failure?.code == .cancelled)
        #expect(await manager.state == .connected)
        #expect(await launcher.startedDeviceIdentifiers == ["new-target"])
        await manager.stop()
    }

    @Test("late cleanup on the same device cannot close the replacement launch")
    func sameDeviceReplacement() async throws {
        let gate = IOSLifecycleGate()
        let launcher = IOSLauncherFixture(firstStartGate: gate)
        let manager = makeManager(launcher: launcher)
        let old = Task { await manager.prepare(deviceIdentifier: "same-target") }
        await gate.waitUntilEntered()
        let oldLaunch = try #require(await launcher.startedLaunches.first)
        await manager.stop()
        #expect(await manager.prepare(deviceIdentifier: "same-target").channel != nil)
        let newLaunch = try #require(await launcher.startedLaunches.last)
        #expect(oldLaunch.id != newLaunch.id)
        let products = await launcher.startedBuildProducts
        #expect(products.count == 2)
        #expect(products.first?.launchID == oldLaunch.id)
        #expect(products.last?.launchID == newLaunch.id)
        #expect(products.first?.derivedDataDirectoryURL != products.last?.derivedDataDirectoryURL)
        await gate.release()

        #expect(await old.value.failure?.code == .cancelled)
        #expect(await manager.state == .connected)
        #expect(await launcher.stoppedLaunches.allSatisfy { $0 == oldLaunch })
        await manager.stop()
        #expect(await launcher.stoppedLaunches.last == newLaunch)
    }

    @Test("a slow stop cannot overwrite the next session after cleanup")
    func delayedStop() async {
        let gate = IOSLifecycleGate()
        let launcher = IOSLauncherFixture(firstStopGate: gate)
        let manager = makeManager(launcher: launcher)
        #expect(await manager.prepare(deviceIdentifier: "old-target").channel != nil)
        let stopping = Task { await manager.stop() }
        await gate.waitUntilEntered()
        #expect(await manager.prepare(deviceIdentifier: "new-target").channel != nil)
        await gate.release()
        await stopping.value

        #expect(await manager.state == .connected)
        await manager.stop()
    }

    @Test("a failed partial launch is cleaned and can be retried")
    func failedLaunchCleanup() async {
        let launcher = IOSLauncherFixture(shouldFail: true)
        let manager = makeManager(launcher: launcher)
        #expect(await manager.prepare(deviceIdentifier: "ios-target").failure != nil)
        #expect(await launcher.stoppedLaunches == launcher.startedLaunches)
        #expect(await manager.prepare(deviceIdentifier: "ios-target").failure != nil)
        #expect(await launcher.startedLaunches.count == 2)
        #expect(await launcher.stoppedLaunches == launcher.startedLaunches)
    }

    private func makeManager(
        runner: IOSManagerCommandRunner = IOSManagerCommandRunner(exitCode: 0),
        launcher: IOSLauncherFixture = IOSLauncherFixture()
    ) -> IOSRunnerManager {
        IOSRunnerManager(
            xcodebuildURL: URL(fileURLWithPath: "/xcodebuild"),
            projectURL: URL(fileURLWithPath: "/runner.xcodeproj"),
            scheme: "Runner", signingTeamID: "TEAM", runner: runner, launcher: launcher
        )
    }
}

private actor IOSManagerCommandRunner: HostCommandRunning {
    private(set) var requests: [HostCommandRequest] = []
    private(set) var observedCancellation = false
    private let exitCode: Int32
    private let firstRunGate: IOSLifecycleGate?
    private let firstExitCode: Int32?
    private let writesProducts: Bool

    init(exitCode: Int32, firstRunGate: IOSLifecycleGate? = nil, firstExitCode: Int32? = nil, writesProducts: Bool = false) {
        self.exitCode = exitCode
        self.firstRunGate = firstRunGate
        self.firstExitCode = firstExitCode
        self.writesProducts = writesProducts
    }

    func run(_ request: HostCommandRequest) async throws -> HostCommandResult {
        requests.append(request)
        let first = requests.count == 1
        if first { await firstRunGate?.enter() }
        observedCancellation = observedCancellation || Task.isCancelled
        if writesProducts, let index = request.arguments.firstIndex(of: "-derivedDataPath") {
            let products = URL(fileURLWithPath: request.arguments[index + 1]).appendingPathComponent("Build/Products")
            for name in ["DeviceBridgeRunnerUITests-Runner.app", "DeviceBridgeHost.app"] {
                let app = products.appendingPathComponent("Debug-iphoneos/" + name)
                try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
                try Data(String(requests.count).utf8).write(to: app.appendingPathComponent("binary"))
            }
            let plist = ["TestHostPath": products.path + "/Debug-iphoneos/DeviceBridgeHost.app"]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: products.appendingPathComponent("Runner.xctestrun"))
        }
        return HostCommandResult(
            exitCode: first ? (firstExitCode ?? exitCode) : exitCode,
            standardOutput: Data(), standardError: Data()
        )
    }
}

private actor IOSLauncherFixture: IOSRunnerChannelLaunching {
    private(set) var startedBuildProducts: [IOSRunnerBuildProducts] = []
    private(set) var startedDeviceIdentifiers: [String] = []
    private(set) var stoppedDeviceIdentifiers: [String] = []
    private(set) var startedLaunches: [IOSRunnerLaunch] = []
    private(set) var stoppedLaunches: [IOSRunnerLaunch] = []
    private let shouldFail: Bool
    private let firstStartGate: IOSLifecycleGate?
    private let firstStopGate: IOSLifecycleGate?

    init(
        shouldFail: Bool = false,
        firstStartGate: IOSLifecycleGate? = nil,
        firstStopGate: IOSLifecycleGate? = nil
    ) {
        self.shouldFail = shouldFail
        self.firstStartGate = firstStartGate
        self.firstStopGate = firstStopGate
    }

    func installStartAndOpen(
        launch: IOSRunnerLaunch,
        projectURL: URL,
        scheme: String,
        buildProducts: IOSRunnerBuildProducts
    ) async throws -> any HelperRequestSending {
        startedDeviceIdentifiers.append(launch.deviceIdentifier)
        startedLaunches.append(launch)
        startedBuildProducts.append(buildProducts)
        if startedDeviceIdentifiers.count == 1 { await firstStartGate?.enter() }
        if shouldFail { throw IOSRunnerLaunchError.channelUnavailable }
        return IOSHelperChannelFixture()
    }

    func stop(launch: IOSRunnerLaunch) async {
        stoppedDeviceIdentifiers.append(launch.deviceIdentifier)
        stoppedLaunches.append(launch)
        if stoppedLaunches.count == 1 { await firstStopGate?.enter() }
    }
}

/// Deliberately ignores cancellation to model an external boundary returning late.
private actor IOSLifecycleGate {
    private var entered = false
    private var released = false
    private var entryWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func enter() async {
        entered = true
        entryWaiter?.resume()
        entryWaiter = nil
        if !released {
            await withCheckedContinuation { releaseWaiter = $0 }
        }
    }

    func waitUntilEntered() async {
        if !entered {
            await withCheckedContinuation { entryWaiter = $0 }
        }
    }

    func release() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private actor IOSHelperChannelFixture: HelperRequestSending {
    func send(_ request: HelperRequest) async throws -> HelperResult {
        HelperResult(requestID: request.requestID, status: .success, completedAt: Date())
    }
}
