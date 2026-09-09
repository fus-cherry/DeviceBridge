import DeviceBridgeProtocol
import Foundation
import Testing
@testable import DeviceBridgeCore

struct IOSRunnerLauncherTests {
    @Test func exactProductsAndPublicBootstrapReachOnlyTheManagedTest() async throws {
        let c = try LauncherContext()
        defer { c.removeFixtures() }
        _ = try await c.start()
        let request = try #require(c.processes.requests.first)
        #expect(request.executableURL.path == "/usr/bin/xcrun")
        let configuration = c.products.derivedDataDirectoryURL.appendingPathComponent("DeviceBridgeLaunch/start.xctestrun")
        #expect(request.arguments == ["xcodebuild", "test-without-building", "-xctestrun", configuration.path,
            "-destination", "id=synthetic-phone",
            "-only-testing:DeviceBridgeRunnerUITests/RunnerSmokeTests/testManagedChannel",
            "-parallel-testing-enabled", "NO"])
        #expect(request.environment["TEST_RUNNER_DEVICEBRIDGE_PUBLIC_LAUNCH"] == c.launch.id.uuidString)
        #expect(request.environment["TEST_RUNNER_DEVICEBRIDGE_PUBLIC_HOST_CERTIFICATE"] == c.candidate.publicHostCertificateDER.base64EncodedString())
        #expect(request.environment["TEST_RUNNER_DEVICEBRIDGE_PUBLIC_MAXIMUM_LIFETIME"].flatMap(Double.init) == 60)
        #expect(request.environment["UNRELATED_SECRET"] == nil)
        #expect(request.environment["TEST_RUNNER_SESSION_NONCE"] == nil)
        #expect(request.environment["PATH"] == "/usr/bin:/bin")
        #expect(try Data(contentsOf: configuration) == Data("synthetic-configuration".utf8))
        await c.launcher.stop(launch: c.launch)
        await c.launcher.stop(launch: c.launch)
        #expect(await c.process.stops >= 1)
        #expect(await c.candidate.closes >= 1)
        #expect(!FileManager.default.fileExists(atPath: configuration.deletingLastPathComponent().path))
    }

    @Test func rejectedArtifactsNeverStartAProcess() async throws {
        let c = try LauncherContext(rejectArtifacts: true)
        defer { c.removeFixtures() }
        await #expect(throws: (any Error).self) { try await c.start() }
        #expect(c.processes.requests.isEmpty)
    }

    @Test func stoppedValidationCannotLaterStart() async throws {
        let gate = LauncherGate()
        let c = try LauncherContext(artifactGate: gate)
        defer { c.removeFixtures() }
        let start = Task { try await c.start() }
        await gate.entered()
        await c.launcher.stop(launch: c.launch)
        await gate.release()
        await #expect(throws: (any Error).self) { try await start.value }
        #expect(c.processes.requests.isEmpty)
    }

    @Test func lateOpenAfterStopCannotPublishAChannel() async throws {
        let gate = LauncherGate()
        let c = try LauncherContext(openGate: gate)
        defer { c.removeFixtures() }
        let start = Task { try await c.start() }
        await gate.entered()
        await c.launcher.stop(launch: c.launch)
        await gate.release()
        await #expect(throws: (any Error).self) { try await start.value }
        #expect(await c.process.stops >= 1)
        #expect(await c.candidate.closes >= 1)
    }

    @Test func startupTimeoutClosesTheBlockedChannelAndChild() async throws {
        let gate = LauncherGate()
        // Allow admission under a busy full suite, then prove timeout cleanup at the open boundary.
        // The separate blocked-validation test covers expiry before a process is created.
        let c = try LauncherContext(openGate: gate, releaseOnClose: true, startupTimeout: .seconds(1))
        defer { c.removeFixtures() }
        await #expect(throws: (any Error).self) { try await c.start() }
        #expect(await c.process.stops >= 1)
        #expect(await c.candidate.closes >= 1)
    }

    @Test func earlyChildExitCannotBecomeConnected() async throws {
        let gate = LauncherGate()
        let c = try LauncherContext(openGate: gate, releaseOnClose: true, initialExit: .exited(65))
        defer { c.removeFixtures() }
        await #expect(throws: (any Error).self) { try await c.start() }
        #expect(await c.candidate.closes >= 1)
    }

    @Test func callerCancellationClosesStartupWithoutSeparateStop() async throws {
        let gate = LauncherGate()
        let c = try LauncherContext(openGate: gate, releaseOnClose: true)
        defer { c.removeFixtures() }
        let start = Task { try await c.start() }
        await gate.entered()
        start.cancel()
        await #expect(throws: CancellationError.self) { try await start.value }
        #expect(await c.process.stops >= 1)
        #expect(await c.candidate.closes >= 1)
    }

    @Test func duplicateAttemptCannotStartASecondProcess() async throws {
        let gate = LauncherGate()
        let c = try LauncherContext(openGate: gate)
        defer { c.removeFixtures() }
        let first = Task { try await c.start() }
        await gate.entered()
        await #expect(throws: (any Error).self) { try await c.start() }
        #expect(c.processes.requests.count == 1)
        await gate.release()
        _ = try await first.value
        await c.launcher.stop(launch: c.launch)
    }

    @Test func failedGeneratedDirectoryCleanupCanBeRetried() async throws {
        let c = try LauncherContext()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: c.products.derivedDataDirectoryURL.path)
            c.removeFixtures()
        }
        _ = try await c.start()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: c.products.derivedDataDirectoryURL.path)
        await c.launcher.stop(launch: c.launch)
        #expect(await c.launcher.hasPendingCleanup(launch: c.launch))
        #expect(await c.process.stops >= 1)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: c.products.derivedDataDirectoryURL.path)
        await c.launcher.stop(launch: c.launch)
        #expect(await c.launcher.hasPendingCleanup(launch: c.launch) == false)
        #expect(!FileManager.default.fileExists(atPath: c.products.derivedDataDirectoryURL.appendingPathComponent("DeviceBridgeLaunch").path))
    }

    @Test(arguments: [false, true])
    func preexistingDirectoryOrSymlinkIsNeverAdopted(useSymlink: Bool) async throws {
        let c = try LauncherContext()
        defer { c.removeFixtures() }
        let target = c.products.derivedDataDirectoryURL.appendingPathComponent("DeviceBridgeLaunch")
        let original = useSymlink ? c.root.appendingPathComponent("untouched") : target
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false)
        let sentinel = original.appendingPathComponent("start.xctestrun")
        let bytes = Data("do-not-replace-or-remove".utf8)
        try bytes.write(to: sentinel)
        if useSymlink { try FileManager.default.createSymbolicLink(at: target, withDestinationURL: original) }
        await #expect(throws: (any Error).self) { try await c.start() }
        await c.launcher.stop(launch: c.launch)
        #expect(c.processes.requests.isEmpty)
        #expect(try Data(contentsOf: sentinel) == bytes)
    }

    @Test(arguments: [false, true])
    func blockedValidationDoesNotBlockTimeoutOrCancellation(cancel: Bool) async throws {
        let gate = LauncherGate()
        let c = try LauncherContext(artifactGate: gate, startupTimeout: .milliseconds(40))
        defer { c.removeFixtures() }
        let completion = LauncherCompletion()
        let start = Task {
            do { _ = try await c.start(); await completion.finish(false) }
            catch { await completion.finish(true) }
        }
        await gate.entered()
        if cancel { start.cancel() }
        try await Task.sleep(for: .milliseconds(150))
        #expect(await completion.failed == true)
        #expect(c.processes.requests.isEmpty)
        await gate.release()
        await start.value
        #expect(c.processes.requests.isEmpty)
    }

    @Test func samePhoneReplacementSurvivesOldLateCleanup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DeviceBridgeReplacement-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let old = IOSRunnerLaunch(deviceIdentifier: "same-synthetic-phone")
        let new = IOSRunnerLaunch(deviceIdentifier: "same-synthetic-phone")
        let products = [old, new].map { IOSRunnerBuildProducts(launchID: $0.id, rootDirectoryURL: root, expectedTeamIdentifier: "TESTTEAM00") }
        for product in products { try FileManager.default.createDirectory(at: product.derivedDataDirectoryURL, withIntermediateDirectories: true) }
        let gate = LauncherGate()
        let oldCandidate = LauncherCandidate(gate: gate, releaseOnClose: false)
        let newCandidate = LauncherCandidate(gate: nil, releaseOnClose: false)
        let oldProcess = LauncherProcess(exit: nil)
        let newProcess = LauncherProcess(exit: nil)
        let launcher = IOSRunnerLauncher(xcrunURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
            channels: ReplacementChannels(candidates: [old.id: oldCandidate, new.id: newCandidate]),
            maximumRunnerLifetime: .seconds(60), startupTimeout: .seconds(2),
            artifacts: LauncherArtifacts(reject: false, gate: nil),
            processes: ReplacementProcesses(processes: [old.id: oldProcess, new.id: newProcess]), environment: [:])
        let oldStart = Task { try await launcher.installStartAndOpen(launch: old, projectURL: root, scheme: "fixture", buildProducts: products[0]) }
        await gate.entered()
        await launcher.stop(launch: old)
        _ = try await launcher.installStartAndOpen(launch: new, projectURL: root, scheme: "fixture", buildProducts: products[1])
        await gate.release()
        await #expect(throws: (any Error).self) { try await oldStart.value }
        #expect(await newProcess.exitStatus() == nil)
        #expect(await newCandidate.closes == 0)
        #expect(FileManager.default.fileExists(atPath: products[1].derivedDataDirectoryURL.appendingPathComponent("DeviceBridgeLaunch/start.xctestrun").path))
        await launcher.stop(launch: new)
    }

    @Test func childStopDoesNotWaitForSlowChannelCleanup() async throws {
        let gate = LauncherGate()
        let c = try LauncherContext(closeGate: gate)
        defer { c.removeFixtures() }
        _ = try await c.start()
        let stop = Task { await c.launcher.stop(launch: c.launch) }
        await gate.entered()
        try await Task.sleep(for: .milliseconds(20))
        #expect(await c.process.stops >= 1)
        await gate.release()
        await stop.value
    }
}

private struct ReplacementChannels: IOSRunnerChannelPreparing {
    let candidates: [UUID: LauncherCandidate]
    func prepare(launch: IOSRunnerLaunch) throws -> any IOSRunnerChannelCandidate {
        guard let candidate = candidates[launch.id] else { throw IOSRunnerLaunchError.channelUnavailable }
        return candidate
    }
}

private struct ReplacementProcesses: IOSRunnerProcessStarting {
    let processes: [UUID: LauncherProcess]
    func start(_ request: IOSRunnerProcessRequest) throws -> any IOSRunnerProcessOwning {
        guard let raw = request.environment["TEST_RUNNER_DEVICEBRIDGE_PUBLIC_LAUNCH"],
              let id = UUID(uuidString: raw), let process = processes[id] else { throw IOSRunnerLaunchError.channelUnavailable }
        return process
    }
}

private actor LauncherCompletion {
    var failed: Bool?
    func finish(_ failed: Bool) { self.failed = failed }
}

private struct LauncherContext: Sendable {
    let root: URL
    let launch = IOSRunnerLaunch(deviceIdentifier: "synthetic-phone")
    let products: IOSRunnerBuildProducts
    let process: LauncherProcess
    let processes: LauncherProcesses
    let candidate: LauncherCandidate
    let launcher: IOSRunnerLauncher

    init(rejectArtifacts: Bool = false, artifactGate: LauncherGate? = nil, openGate: LauncherGate? = nil, closeGate: LauncherGate? = nil,
         releaseOnClose: Bool = false, startupTimeout: Duration = .seconds(2), initialExit: IOSRunnerProcess.Exit? = nil) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("DeviceBridgeLauncherFixture-\(UUID().uuidString)")
        products = IOSRunnerBuildProducts(launchID: launch.id, rootDirectoryURL: root, expectedTeamIdentifier: "TESTTEAM00")
        try FileManager.default.createDirectory(at: products.derivedDataDirectoryURL, withIntermediateDirectories: true)
        process = LauncherProcess(exit: initialExit)
        processes = LauncherProcesses(process: process)
        candidate = LauncherCandidate(gate: openGate, releaseOnClose: releaseOnClose, closeGate: closeGate)
        launcher = IOSRunnerLauncher(xcrunURL: URL(fileURLWithPath: "/usr/bin/xcrun"), channels: LauncherChannels(candidate: candidate),
            maximumRunnerLifetime: .seconds(60), startupTimeout: startupTimeout,
            artifacts: LauncherArtifacts(reject: rejectArtifacts, gate: artifactGate), processes: processes,
            environment: ["PATH": "/usr/bin:/bin", "UNRELATED_SECRET": "public-fixture-only", "TEST_RUNNER_SESSION_NONCE": "must-not-forward"])
    }

    func start() async throws -> any HelperRequestSending {
        try await launcher.installStartAndOpen(launch: launch, projectURL: URL(fileURLWithPath: "/unused/project.xcodeproj"),
            scheme: "Unused", buildProducts: products)
    }
    func removeFixtures() { try? FileManager.default.removeItem(at: root) }
}

private struct LauncherArtifacts: IOSRunnerArtifactsLoading {
    let reject: Bool
    let gate: LauncherGate?
    func load(launch: IOSRunnerLaunch, products: IOSRunnerBuildProducts) async throws -> IOSRunnerSignedArtifacts {
        if let gate { await gate.wait() }
        if reject { throw IOSRunnerLaunchError.channelUnavailable }
        let runner = products.productsDirectoryURL.appendingPathComponent("Debug-iphoneos/DeviceBridgeRunnerUITests-Runner.app")
        return IOSRunnerSignedArtifacts(configuration: IOSRunnerTestConfiguration(launchID: launch.id,
            runnerApplicationURL: runner, testBundleURL: runner.appendingPathComponent("PlugIns/DeviceBridgeRunnerUITests.xctest"),
            targetApplicationURL: products.productsDirectoryURL.appendingPathComponent("Debug-iphoneos/DeviceBridgeHost.app"),
            configurationData: Data("synthetic-configuration".utf8)))
    }
}

private final class LauncherProcesses: IOSRunnerProcessStarting, @unchecked Sendable {
    private let lock = NSLock()
    private var captured: [IOSRunnerProcessRequest] = []
    let process: LauncherProcess
    init(process: LauncherProcess) { self.process = process }
    var requests: [IOSRunnerProcessRequest] { lock.withLock { captured } }
    func start(_ request: IOSRunnerProcessRequest) throws -> any IOSRunnerProcessOwning {
        lock.withLock { captured.append(request) }
        return process
    }
}

private actor LauncherProcess: IOSRunnerProcessOwning {
    var stops = 0
    var exit: IOSRunnerProcess.Exit?
    init(exit: IOSRunnerProcess.Exit?) { self.exit = exit }
    func exitStatus() -> IOSRunnerProcess.Exit? { exit }
    func stop() { stops += 1; exit = .signaled(15) }
}

private struct LauncherChannels: IOSRunnerChannelPreparing {
    let candidate: LauncherCandidate
    func prepare(launch: IOSRunnerLaunch) throws -> any IOSRunnerChannelCandidate { candidate }
}

private actor LauncherCandidate: IOSRunnerChannelCandidate {
    nonisolated let publicHostCertificateDER = Data("synthetic-public-certificate".utf8)
    let gate: LauncherGate?
    let releaseOnClose: Bool
    let closeGate: LauncherGate?
    var closes = 0
    init(gate: LauncherGate?, releaseOnClose: Bool, closeGate: LauncherGate? = nil) {
        self.gate = gate; self.releaseOnClose = releaseOnClose; self.closeGate = closeGate
    }
    func open(launch: IOSRunnerLaunch, process: any IOSRunnerProcessOwning) async throws -> any HelperRequestSending {
        if let gate { await gate.wait() }
        return LauncherChannel()
    }
    func close() async {
        closes += 1
        if let closeGate { await closeGate.wait() }
        if releaseOnClose { await gate?.release() }
    }
}

private struct LauncherChannel: HelperRequestSending {
    func send(_ request: HelperRequest) async throws -> HelperResult { throw IOSRunnerLaunchError.channelUnavailable }
}

private actor LauncherGate {
    private var isEntered = false
    private var released = false
    private var entries: [CheckedContinuation<Void, Never>] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func entered() async {
        if isEntered { return }
        await withCheckedContinuation { entries.append($0) }
    }
    func wait() async {
        isEntered = true
        let current = entries; entries.removeAll()
        for continuation in current { continuation.resume() }
        if !released { await withCheckedContinuation { waiters.append($0) } }
    }
    func release() {
        released = true
        let current = waiters; waiters.removeAll()
        for continuation in current { continuation.resume() }
    }
}
