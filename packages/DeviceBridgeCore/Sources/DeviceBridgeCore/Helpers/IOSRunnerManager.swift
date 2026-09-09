import Foundation

public enum IOSRunnerState: String, Sendable, Equatable {
    case idle
    case signingRequired
    case building
    case starting
    case connected
    case actionRequired
    case failed
    case stopped
}

public enum IOSRunnerLaunchError: Error, Sendable, Equatable {
    case channelUnavailable
}

/// Resource ownership for one runner attempt, including reconnects to the same device.
public struct IOSRunnerLaunch: Sendable, Equatable {
    public let id: UUID
    public let deviceIdentifier: String

    public init(id: UUID = UUID(), deviceIdentifier: String) {
        self.id = id
        self.deviceIdentifier = deviceIdentifier
    }
}

public protocol IOSRunnerChannelLaunching: Sendable {
    /// Return only after a content-free identity/version/nonce handshake succeeds.
    func installStartAndOpen(
        launch: IOSRunnerLaunch,
        projectURL: URL,
        scheme: String,
        buildProducts: IOSRunnerBuildProducts
    ) async throws -> any HelperRequestSending

    /// Idempotently close only this attempt's resources, including partially opened channels.
    /// An interrupted open may return late; a second stop must reclaim those late resources.
    func stop(launch: IOSRunnerLaunch) async
}

public struct IOSRunnerPreparationOutcome: Sendable {
    public let channel: (any HelperRequestSending)?
    public let failure: OperationFailure?

    public init(channel: (any HelperRequestSending)? = nil, failure: OperationFailure? = nil) {
        self.channel = channel
        self.failure = failure
    }
}

public protocol IOSRunnerManaging: Sendable {
    func prepare(deviceIdentifier: String) async -> IOSRunnerPreparationOutcome
    func stop() async
    /// Read-only presentation; this observation never grants channel readiness.
    func preparationState() async -> IOSRunnerState?
}

public extension IOSRunnerManaging {
    func preparationState() async -> IOSRunnerState? { nil }
}

public actor IOSRunnerManager: IOSRunnerManaging {
    public private(set) var state: IOSRunnerState = .idle
    public func preparationState() -> IOSRunnerState? { state }

    private let xcodebuildURL: URL
    private let projectURL: URL
    private let scheme: String
    private let signingTeamID: String?
    private let runner: any HostCommandRunning
    private let launcher: any IOSRunnerChannelLaunching
    private let buildRootDirectoryURL: URL
    private let buildWorkspace: IOSRunnerBuildWorkspace?
    private var currentLaunch: IOSRunnerLaunch?
    private var preparationTask: Task<IOSRunnerPreparationOutcome, Never>?
    private var activeChannel: (any HelperRequestSending)?

    public init(
        xcodebuildURL: URL,
        projectURL: URL,
        scheme: String,
        signingTeamID: String?,
        runner: any HostCommandRunning,
        launcher: any IOSRunnerChannelLaunching,
        buildRootDirectoryURL: URL = FileManager.default.temporaryDirectory.appendingPathComponent("DeviceBridgeRunnerBuilds", isDirectory: true),
        buildWorkspace: IOSRunnerBuildWorkspace? = nil
    ) {
        self.xcodebuildURL = xcodebuildURL
        self.projectURL = projectURL
        self.scheme = scheme
        self.signingTeamID = signingTeamID
        self.runner = runner
        self.launcher = launcher
        self.buildRootDirectoryURL = buildRootDirectoryURL
        self.buildWorkspace = buildWorkspace
    }

    public func prepare(deviceIdentifier: String) async -> IOSRunnerPreparationOutcome {
        guard !Task.isCancelled else { return cancelledOutcome() }
        guard preparationTask == nil else {
            return IOSRunnerPreparationOutcome(failure: OperationFailure(
                code: .helperMissing,
                safeMessage: "The iOS runner is already being prepared.",
                recoveryAction: "Wait for preparation to finish, or stop it before retrying."
            ))
        }
        if state == .connected,
           currentLaunch?.deviceIdentifier == deviceIdentifier,
           let activeChannel {
            return IOSRunnerPreparationOutcome(channel: activeChannel)
        }

        guard let signingTeamID,
              !signingTeamID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            state = .signingRequired
            return IOSRunnerPreparationOutcome(failure: OperationFailure(
                code: .helperMissing,
                safeMessage: "The iOS runner needs a development signing team.",
                recoveryAction: "Choose an Apple development team in Settings."
            ))
        }

        let previousLaunch = currentLaunch
        let launch = IOSRunnerLaunch(deviceIdentifier: deviceIdentifier)
        currentLaunch = launch
        activeChannel = nil
        state = .building
        let work = Task {
            await self.buildAndOpen(launch: launch, previousLaunch: previousLaunch, signingTeamID: signingTeamID)
        }
        preparationTask = work
        let outcome = await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }

        guard currentLaunch == launch else { return cancelledOutcome() }
        if Task.isCancelled {
            await stop()
            return cancelledOutcome()
        }
        preparationTask = nil
        if outcome.channel == nil { currentLaunch = nil }
        return outcome
    }

    private func buildAndOpen(
        launch: IOSRunnerLaunch,
        previousLaunch: IOSRunnerLaunch?,
        signingTeamID: String
    ) async -> IOSRunnerPreparationOutcome {
        if let previousLaunch {
            await launcher.stop(launch: previousLaunch)
        }
        guard isCurrent(launch) else { return cancel(launch) }

        let buildProducts = IOSRunnerBuildProducts(launchID: launch.id, rootDirectoryURL: buildRootDirectoryURL,
            expectedTeamIdentifier: signingTeamID)

        let result: HostCommandResult
        do {
            let request = HostCommandRequest(
                executableURL: xcodebuildURL,
                arguments: [
                    "build-for-testing",
                    "-quiet",
                    "-project", projectURL.path,
                    "-scheme", scheme,
                    "-configuration", "Debug",
                    "-derivedDataPath", buildProducts.derivedDataDirectoryURL.path,
                    "-destination", "id=\(launch.deviceIdentifier)",
                    "CODE_SIGN_STYLE=Automatic",
                    "DEVELOPMENT_TEAM=\(signingTeamID)",
                ],
                timeout: .seconds(300),
                maximumOutputBytes: 2 * 1_024 * 1_024
            )
            if let buildWorkspace {
                result = try await buildWorkspace.run(request, runner: runner, snapshot: buildProducts)
            } else {
                result = try await runner.run(request)
            }
        } catch {
            guard isCurrent(launch), !(error is CancellationError),
                  (error as? HostCommandError) != .cancelled else { return cancel(launch) }
            state = .failed
            return buildFailure()
        }
        guard isCurrent(launch) else { return cancel(launch) }
        guard result.exitCode == 0 else {
            state = .failed
            return buildFailure()
        }

        state = .starting
        do {
            let channel = try await launcher.installStartAndOpen(
                launch: launch,
                projectURL: projectURL,
                scheme: scheme,
                buildProducts: buildProducts
            )
            guard isCurrent(launch) else {
                let outcome = cancel(launch)
                await launcher.stop(launch: launch)
                return outcome
            }
            activeChannel = channel
            state = .connected
            return IOSRunnerPreparationOutcome(channel: channel)
        } catch {
            let cancelled = !isCurrent(launch) || error is CancellationError
                || (error as? HostCommandError) == .cancelled
            if cancelled { _ = cancel(launch) }
            // A failed launch can still own a process or channel. Dispose it before returning.
            await launcher.stop(launch: launch)
            guard !cancelled, isCurrent(launch) else { return cancel(launch) }
            state = .actionRequired
            return IOSRunnerPreparationOutcome(failure: OperationFailure(
                code: .helperMissing,
                safeMessage: "The iOS runner was built but its device channel is not ready.",
                recoveryAction: "Unlock the device, confirm trust prompts, and retry."
            ))
        }
    }

    public func stop() async {
        let launch = currentLaunch
        currentLaunch = nil
        preparationTask?.cancel()
        preparationTask = nil
        activeChannel = nil
        if state != .idle { state = .stopped }
        if let launch { await launcher.stop(launch: launch) }
        // Do not publish after the await: a newer preparation may now own state.
    }

    private func isCurrent(_ launch: IOSRunnerLaunch) -> Bool {
        currentLaunch == launch && !Task.isCancelled
    }

    private func cancel(_ launch: IOSRunnerLaunch) -> IOSRunnerPreparationOutcome {
        if currentLaunch == launch {
            activeChannel = nil
            state = .stopped
        }
        return cancelledOutcome()
    }

    private func cancelledOutcome() -> IOSRunnerPreparationOutcome {
        IOSRunnerPreparationOutcome(failure: OperationFailure(
            code: .cancelled,
            safeMessage: "iOS runner preparation was cancelled."
        ))
    }

    private func buildFailure() -> IOSRunnerPreparationOutcome {
        IOSRunnerPreparationOutcome(failure: OperationFailure(
            code: .helperMissing,
            safeMessage: "The compatible iOS runner could not be built or signed.",
            recoveryAction: "Check Xcode signing, Developer Mode, and device trust."
        ))
    }
}
