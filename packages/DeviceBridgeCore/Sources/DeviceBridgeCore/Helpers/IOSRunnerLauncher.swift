import Foundation
import Darwin

/// Actual filesystem/signature boundary; fixtures do not qualify signed installation.
public protocol IOSRunnerArtifactsLoading: Sendable {
    func load(launch: IOSRunnerLaunch, products: IOSRunnerBuildProducts) async throws -> IOSRunnerSignedArtifacts
}

public struct IOSRunnerArtifactLoader: IOSRunnerArtifactsLoading {
    public init() {}
    public func load(launch: IOSRunnerLaunch, products: IOSRunnerBuildProducts) async throws -> IOSRunnerSignedArtifacts {
        try await Task.detached { try IOSRunnerSignedArtifacts.load(launch: launch, products: products) }.value
    }
}

public protocol IOSRunnerProcessOwning: Sendable {
    func exitStatus() async -> IOSRunnerProcess.Exit?
    func stop() async
}

extension IOSRunnerProcess: IOSRunnerProcessOwning {}

public struct IOSRunnerProcessRequest: Sendable {
    public let executableURL: URL
    public let arguments: [String]
    public let environment: [String: String]
    public let maximumLifetime: Duration
}

public protocol IOSRunnerProcessStarting: Sendable {
    func start(_ request: IOSRunnerProcessRequest) throws -> any IOSRunnerProcessOwning
}

public struct IOSRunnerProcessStarter: IOSRunnerProcessStarting {
    public init() {}
    public func start(_ request: IOSRunnerProcessRequest) throws -> any IOSRunnerProcessOwning {
        try IOSRunnerProcess.start(executableURL: request.executableURL, arguments: request.arguments,
            environment: request.environment, lifetime: request.maximumLifetime)
    }
}

/// Owns fresh in-memory TLS identity, exact-device bootstrap/proxy and handshake resources.
/// Public certificate metadata alone may enter Xcode's environment; no nonce/private key may do so.
public protocol IOSRunnerChannelCandidate: Sendable {
    var publicHostCertificateDER: Data { get }
    func open(launch: IOSRunnerLaunch, process: any IOSRunnerProcessOwning) async throws -> any HelperRequestSending
    /// Idempotent and closes in-flight I/O so an interrupted open can finish; late work stays invalid.
    func close() async
}

public protocol IOSRunnerChannelPreparing: Sendable {
    func prepare(launch: IOSRunnerLaunch) throws -> any IOSRunnerChannelCandidate
}

/// One actor owns launch resources; only IOSRunnerManager may publish user-visible readiness.
/// The channel factory has no default until the authenticated T084 implementation is qualified.
public actor IOSRunnerLauncher: IOSRunnerChannelLaunching {
    private let xcrunURL: URL
    private let artifacts: any IOSRunnerArtifactsLoading
    private let processes: any IOSRunnerProcessStarting
    private let channels: any IOSRunnerChannelPreparing
    private let environment: [String: String]
    private let startupTimeout: Duration
    private let maximumRunnerLifetime: Duration
    private var attempts: [UUID: Attempt] = [:]

    /// Only this launcher actor writes these fields. Removal invalidates all work after an await.
    private final class Attempt {
        enum Phase { case preparing, opening, connected, stopping }
        var phase = Phase.preparing
        var candidate: (any IOSRunnerChannelCandidate)?
        var process: (any IOSRunnerProcessOwning)?
        var directory: URL?
    }

    public init(xcrunURL: URL, channels: any IOSRunnerChannelPreparing,
                maximumRunnerLifetime: Duration, startupTimeout: Duration = .seconds(60),
                artifacts: any IOSRunnerArtifactsLoading = IOSRunnerArtifactLoader(),
                processes: any IOSRunnerProcessStarting = IOSRunnerProcessStarter(),
                environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.xcrunURL = xcrunURL
        self.channels = channels
        self.maximumRunnerLifetime = maximumRunnerLifetime
        self.startupTimeout = startupTimeout
        self.artifacts = artifacts
        self.processes = processes
        let allowed = ["PATH", "HOME", "TMPDIR", "DEVELOPER_DIR", "LANG", "LC_ALL"]
        self.environment = environment.filter { allowed.contains($0.key) }
    }

    public func installStartAndOpen(launch: IOSRunnerLaunch, projectURL: URL, scheme: String,
                                   buildProducts: IOSRunnerBuildProducts) async throws -> any HelperRequestSending {
        try Task.checkCancellation()
        guard launch.id == buildProducts.launchID, attempts[launch.id] == nil,
              startupTimeout > .zero, maximumRunnerLifetime > startupTimeout else {
            throw IOSRunnerLaunchError.channelUnavailable
        }
        let attempt = Attempt()
        attempts[launch.id] = attempt
        let deadline = ContinuousClock.now.advanced(by: startupTimeout)
        do {
            let verified = try await loadArtifacts(launch: launch, products: buildProducts, deadline: deadline)
            try requireCurrent(attempt, launch: launch)
            guard verified.configuration.launchID == launch.id, ContinuousClock.now < deadline else {
                throw IOSRunnerLaunchError.channelUnavailable
            }
            let candidate = try channels.prepare(launch: launch)
            attempt.candidate = candidate
            guard !candidate.publicHostCertificateDER.isEmpty, candidate.publicHostCertificateDER.count <= 4096 else {
                throw IOSRunnerLaunchError.channelUnavailable
            }
            let directory = buildProducts.derivedDataDirectoryURL.appendingPathComponent("DeviceBridgeLaunch", isDirectory: true)
            // This directory is newly owned, never an overwrite or cleanup target selected by search.
            guard mkdir(directory.path, 0o700) == 0 else { throw IOSRunnerLaunchError.channelUnavailable }
            attempt.directory = directory
            let configuration = directory.appendingPathComponent("start.xctestrun")
            try verified.configuration.configurationData.write(to: configuration, options: .atomic)
            var publicEnvironment = environment
            publicEnvironment["TEST_RUNNER_DEVICEBRIDGE_PUBLIC_LAUNCH"] = launch.id.uuidString
            publicEnvironment["TEST_RUNNER_DEVICEBRIDGE_PUBLIC_HOST_CERTIFICATE"] = candidate.publicHostCertificateDER.base64EncodedString()
            let lifetime = maximumRunnerLifetime.components
            publicEnvironment["TEST_RUNNER_DEVICEBRIDGE_PUBLIC_MAXIMUM_LIFETIME"] =
                String(Double(lifetime.seconds) + Double(lifetime.attoseconds) / 1e18)
            let process = try processes.start(IOSRunnerProcessRequest(executableURL: xcrunURL,
                arguments: ["xcodebuild", "test-without-building", "-xctestrun", configuration.path,
                    "-destination", "id=" + launch.deviceIdentifier,
                    "-only-testing:DeviceBridgeRunnerUITests/RunnerSmokeTests/testManagedChannel",
                    "-parallel-testing-enabled", "NO"],
                environment: publicEnvironment, maximumLifetime: maximumRunnerLifetime))
            attempt.process = process
            attempt.phase = .opening
            let channel = try await open(candidate, process: process, launch: launch, deadline: deadline)
            try requireCurrent(attempt, launch: launch)
            guard await process.exitStatus() == nil else { throw IOSRunnerLaunchError.channelUnavailable }
            try requireCurrent(attempt, launch: launch)
            guard ContinuousClock.now < deadline else { throw IOSRunnerLaunchError.channelUnavailable }
            attempt.phase = .connected
            return channel
        } catch {
            attempt.phase = .stopping
            await finishCleanup(attempt, launch: launch)
            throw error is CancellationError ? CancellationError() : IOSRunnerLaunchError.channelUnavailable
        }
    }

    public func stop(launch: IOSRunnerLaunch) async {
        guard let attempt = attempts[launch.id] else { return }
        attempt.phase = .stopping
        await finishCleanup(attempt, launch: launch)
        // Never publish or mutate another attempt after cleanup awaits.
    }

    public func hasPendingCleanup(launch: IOSRunnerLaunch) -> Bool { attempts[launch.id]?.phase == .stopping }

    private func requireCurrent(_ attempt: Attempt, launch: IOSRunnerLaunch) throws {
        try Task.checkCancellation()
        guard attempts[launch.id] === attempt, attempt.phase != .stopping else { throw CancellationError() }
    }

    private func loadArtifacts(launch: IOSRunnerLaunch, products: IOSRunnerBuildProducts,
                               deadline: ContinuousClock.Instant) async throws -> IOSRunnerSignedArtifacts {
        let result = IOSRunnerArtifactResult()
        let loader = artifacts
        let work = Task {
            do { await result.resolve(.success(try await loader.load(launch: launch, products: products))) }
            catch { await result.resolve(.failure(error)) }
        }
        let timer = Task {
            do {
                try await Task.sleep(until: deadline, clock: .continuous)
                await result.resolve(.failure(IOSRunnerLaunchError.channelUnavailable))
            } catch { }
        }
        defer { work.cancel(); timer.cancel() }
        return try await withTaskCancellationHandler {
            try await result.value()
        } onCancel: {
            Task { await result.resolve(.failure(CancellationError())) }
        }
    }

    private func open(_ candidate: any IOSRunnerChannelCandidate, process: any IOSRunnerProcessOwning,
                      launch: IOSRunnerLaunch, deadline: ContinuousClock.Instant) async throws -> any HelperRequestSending {
        try await withThrowingTaskGroup(of: (any HelperRequestSending).self) { group in
            group.addTask { try await candidate.open(launch: launch, process: process) }
            group.addTask {
                try await Task.sleep(until: deadline, clock: .continuous)
                throw IOSRunnerLaunchError.channelUnavailable
            }
            group.addTask {
                while true {
                    try Task.checkCancellation()
                    guard await process.exitStatus() == nil else { throw IOSRunnerLaunchError.channelUnavailable }
                    try await Task.sleep(for: .milliseconds(10))
                }
            }
            do {
                guard let result = try await group.next() else { throw IOSRunnerLaunchError.channelUnavailable }
                group.cancelAll()
                return result
            } catch {
                group.cancelAll()
                // Closing the channel's I/O is what unblocks an interrupted open; cancellation alone
                // does not guarantee foreign APIs observe it. Stop the owned child before scope exit.
                async let channelClosed: Void = candidate.close()
                await process.stop()
                await channelClosed
                throw error
            }
        }
    }

    private func finishCleanup(_ attempt: Attempt, launch: IOSRunnerLaunch) async {
        let candidate = attempt.candidate
        let process = attempt.process
        let directory = attempt.directory
        async let channelClosed: Void? = candidate?.close()
        await process?.stop()
        _ = await channelClosed
        if let directory {
            // Generated configuration contains public bootstrap only. Keep no unrelated build files.
            do { try FileManager.default.removeItem(at: directory) }
            catch let error as CocoaError where error.code == .fileNoSuchFile { }
            catch { return } // Retain the stopping attempt for an explicit cleanup retry.
        }
        if attempts[launch.id] === attempt { attempts.removeValue(forKey: launch.id) }
    }
}

/// Only read-only artifact validation may finish after this result resolves. It cannot launch code.
/// This owner lets startup stop waiting on blocked filesystem/security APIs without accepting late data.
actor IOSRunnerArtifactResult {
    private var resolved: Result<IOSRunnerSignedArtifacts, any Error>?
    private var continuation: CheckedContinuation<IOSRunnerSignedArtifacts, any Error>?

    func resolve(_ result: Result<IOSRunnerSignedArtifacts, any Error>) {
        guard resolved == nil else { return }
        resolved = result
        continuation?.resume(with: result)
        continuation = nil
    }

    func value() async throws -> IOSRunnerSignedArtifacts {
        if let resolved { return try resolved.get() }
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
}
