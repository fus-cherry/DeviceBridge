import Foundation

/// Installs and owns the normal foreground clipboard Host. Unlike an xctrunner activation, this
/// process has an independent lifecycle and cannot replace the background screenshot session.
public actor IOSClipboardHostLauncher: IOSRunnerChannelLaunching {
    private let xcrunURL: URL
    private let artifacts: any IOSRunnerArtifactsLoading
    private let processes: any IOSRunnerProcessStarting
    private let commands: any HostCommandRunning
    private let channels: any IOSRunnerChannelPreparing
    private let environment: [String: String]
    private let startupTimeout: Duration
    private let maximumLifetime: Duration
    private var attempts: [UUID: Attempt] = [:]

    private final class Attempt {
        enum Phase { case preparing, opening, connected, stopping }
        var phase = Phase.preparing
        var candidate: (any IOSRunnerChannelCandidate)?
        var process: (any IOSRunnerProcessOwning)?
    }

    public init(xcrunURL: URL, channels: any IOSRunnerChannelPreparing,
                maximumLifetime: Duration, startupTimeout: Duration = .seconds(60),
                artifacts: any IOSRunnerArtifactsLoading = IOSRunnerArtifactLoader(),
                processes: any IOSRunnerProcessStarting = IOSRunnerProcessStarter(),
                commands: any HostCommandRunning = HostCommandRunner(),
                environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.xcrunURL = xcrunURL
        self.channels = channels
        self.maximumLifetime = maximumLifetime
        self.startupTimeout = startupTimeout
        self.artifacts = artifacts
        self.processes = processes
        self.commands = commands
        let allowed = ["PATH", "HOME", "TMPDIR", "DEVELOPER_DIR", "LANG", "LC_ALL"]
        self.environment = environment.filter { allowed.contains($0.key) }
    }

    public func installStartAndOpen(launch: IOSRunnerLaunch, projectURL: URL, scheme: String,
                                   buildProducts: IOSRunnerBuildProducts) async throws -> any HelperRequestSending {
        try Task.checkCancellation()
        guard launch.id == buildProducts.launchID, attempts[launch.id] == nil,
              startupTimeout > .zero, maximumLifetime > startupTimeout else {
            throw IOSRunnerLaunchError.channelUnavailable
        }
        let attempt = Attempt()
        attempts[launch.id] = attempt
        let deadline = ContinuousClock.now.advanced(by: startupTimeout)
        do {
            let verified = try await loadArtifacts(launch: launch, products: buildProducts, deadline: deadline)
            try requireCurrent(attempt, launch: launch)
            let remaining = try remaining(until: deadline)
            let installed = try await commands.run(HostCommandRequest(executableURL: xcrunURL,
                arguments: ["devicectl", "device", "install", "app", "--device", launch.deviceIdentifier,
                    "--quiet", verified.configuration.clipboardApplicationURL.path],
                timeout: remaining, maximumOutputBytes: 4_096))
            try requireCurrent(attempt, launch: launch)
            guard installed.exitCode == 0 else { throw IOSRunnerLaunchError.channelUnavailable }

            let candidate = try channels.prepare(launch: launch)
            attempt.candidate = candidate
            guard !candidate.publicHostCertificateDER.isEmpty,
                  candidate.publicHostCertificateDER.count <= 4_096 else {
                throw IOSRunnerLaunchError.channelUnavailable
            }
            let lifetime = maximumLifetime.components
            let publicEnvironment = [
                "DEVICEBRIDGE_PUBLIC_LAUNCH": launch.id.uuidString,
                "DEVICEBRIDGE_PUBLIC_HOST_CERTIFICATE": candidate.publicHostCertificateDER.base64EncodedString(),
                "DEVICEBRIDGE_PUBLIC_MAXIMUM_LIFETIME":
                    String(Double(lifetime.seconds) + Double(lifetime.attoseconds) / 1e18),
            ]
            let environmentData = try JSONSerialization.data(withJSONObject: publicEnvironment, options: [.sortedKeys])
            guard let encodedEnvironment = String(data: environmentData, encoding: .utf8) else {
                throw IOSRunnerLaunchError.channelUnavailable
            }
            let process = try processes.start(IOSRunnerProcessRequest(executableURL: xcrunURL,
                arguments: ["devicectl", "device", "process", "launch", "--device", launch.deviceIdentifier,
                    "--activate", "--terminate-existing", "--console", "--environment-variables", encodedEnvironment,
                    IOSRunnerCodeRole.clipboardHost.bundleIdentifier],
                environment: environment, maximumLifetime: maximumLifetime))
            attempt.process = process
            attempt.phase = .opening
            let channel = try await open(candidate, process: process, launch: launch, deadline: deadline)
            try requireCurrent(attempt, launch: launch)
            guard await process.exitStatus() == nil, ContinuousClock.now < deadline else {
                throw IOSRunnerLaunchError.channelUnavailable
            }
            attempt.phase = .connected
            return IOSClipboardHostChannel(channel: channel, xcrunURL: xcrunURL,
                deviceIdentifier: launch.deviceIdentifier, commands: commands, environment: environment)
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
    }

    private func requireCurrent(_ attempt: Attempt, launch: IOSRunnerLaunch) throws {
        try Task.checkCancellation()
        guard attempts[launch.id] === attempt, attempt.phase != .stopping else { throw CancellationError() }
    }

    private func remaining(until deadline: ContinuousClock.Instant) throws -> Duration {
        let value = ContinuousClock.now.duration(to: deadline)
        guard value > .zero else { throw IOSRunnerLaunchError.channelUnavailable }
        return value
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
        async let channelClosed: Void? = candidate?.close()
        await process?.stop()
        _ = await channelClosed
        if attempts[launch.id] === attempt { attempts.removeValue(forKey: launch.id) }
    }
}
