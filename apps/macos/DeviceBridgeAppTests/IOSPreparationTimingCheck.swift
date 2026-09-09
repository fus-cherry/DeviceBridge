import DeviceBridgeCore
import Foundation

/// Explicit metadata-only profiling through the production manager. Never sends content commands.
@main
struct IOSPreparationTimingCheck {
    static func main() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["DEVICEBRIDGE_IOS_PREPARATION_TIMING"] == "1",
              let device = environment["DEVICEBRIDGE_PHYSICAL_UDID"],
              let team = environment["DEVICEBRIDGE_PHYSICAL_TEAM"],
              let resources = environment["DEVICEBRIDGE_PHYSICAL_HELPERS"] else {
            print("SKIP: timing requires explicit designated-device, existing Team and bundled-source inputs")
            return
        }
        let buildOnly = environment["DEVICEBRIDGE_IOS_PREPARATION_BUILD_ONLY"] == "1"
        if !buildOnly {
            let processes = try await HostCommandRunner().run(HostCommandRequest(
                executableURL: URL(fileURLWithPath: "/bin/ps"), arguments: ["-axo", "args="],
                timeout: .seconds(5), maximumOutputBytes: 2 * 1_024 * 1_024))
            guard processes.exitCode == 0,
                  !processes.standardOutputString.split(separator: "\n").contains(where: {
                      $0.contains("DeviceBridgeLaunch/start.xctestrun") && $0.contains("id=" + device)
                  }) else {
                print("BLOCKED: an existing managed runner owns this device; stop its channel in DeviceBridge first")
                exit(2)
            }
        }
        let configuration = try IOSRunnerSourceConfiguration(
            helperResourcesURL: URL(fileURLWithPath: resources), signingTeamID: team)
        let persistentRoot = environment["DEVICEBRIDGE_IOS_PERSISTENT_BUILD_ROOT"]
        let workspace: IOSRunnerBuildWorkspace?
        if let persistentRoot {
            workspace = IOSRunnerBuildWorkspace(rootDirectoryURL: URL(fileURLWithPath: persistentRoot),
                reuseCompletedWorkspaces: true)
        } else {
            workspace = environment["DEVICEBRIDGE_IOS_INCREMENTAL_BUILD"] == "1" ? IOSRunnerBuildWorkspace() : nil
        }
        let samples = min(5, max(1, Int(environment["DEVICEBRIDGE_IOS_PREPARATION_SAMPLES"] ?? "1") ?? 1))
        for sample in 1...samples {
        let runner = TimedBuildRunner()
        let launcher = TimedPreparationLauncher(buildOnly: buildOnly)
        let manager = IOSRunnerManager(xcodebuildURL: URL(fileURLWithPath: "/usr/bin/xcodebuild"),
            projectURL: configuration.projectURL, scheme: configuration.scheme,
            signingTeamID: configuration.signingTeamID, runner: runner, launcher: launcher, buildWorkspace: workspace)
        let started = ContinuousClock.now
        let result = await manager.prepare(deviceIdentifier: device)
        let preparationSeconds = seconds(started.duration(to: .now))
        let buildSeconds = await runner.elapsedSeconds
        let launchSeconds = await launcher.elapsedSeconds
        let artifactSeconds = await launcher.artifactSeconds
        let ready = result.channel != nil
        await manager.stop()
        guard await runner.exitCode == 0, buildOnly ? await launcher.buildOnlyValidated : ready else {
            print("FAIL: preparation did not reach the required stage; no content operation performed")
            exit(1)
        }
        let observation: [String: Any] = [
            "sample": sample,
            "incremental": workspace != nil,
            "persistent_inputs": persistentRoot != nil,
            "mode": buildOnly ? "build-only" : "authenticated-preparation",
            "build_seconds": buildSeconds,
            "launch_open_seconds": launchSeconds,
            "artifact_validation_seconds": artifactSeconds,
            "preparation_seconds": preparationSeconds,
            "authenticated_ready": ready,
            "stopped": await manager.state == .stopped,
            "content_commands": 0,
        ]
        let data = try JSONSerialization.data(withJSONObject: observation, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        }
    }

    static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

private actor TimedBuildRunner: HostCommandRunning {
    private(set) var elapsedSeconds = 0.0
    private(set) var exitCode: Int32?
    func run(_ request: HostCommandRequest) async throws -> HostCommandResult {
        let started = ContinuousClock.now
        defer { elapsedSeconds = IOSPreparationTimingCheck.seconds(started.duration(to: .now)) }
        let result = try await HostCommandRunner().run(request)
        exitCode = result.exitCode
        return result
    }
}

private actor TimedArtifacts: IOSRunnerArtifactsLoading {
    private(set) var elapsedSeconds = 0.0
    func load(launch: IOSRunnerLaunch, products: IOSRunnerBuildProducts) async throws -> IOSRunnerSignedArtifacts {
        let started = ContinuousClock.now
        defer { elapsedSeconds = IOSPreparationTimingCheck.seconds(started.duration(to: .now)) }
        return try await IOSRunnerArtifactLoader().load(launch: launch, products: products)
    }
}

private actor TimedPreparationLauncher: IOSRunnerChannelLaunching {
    private let buildOnly: Bool
    private let artifacts: TimedArtifacts
    private let launcher: IOSRunnerLauncher
    private(set) var elapsedSeconds = 0.0
    var artifactSeconds: Double { get async { await artifacts.elapsedSeconds } }
    private(set) var buildOnlyValidated = false

    init(buildOnly: Bool) {
        self.buildOnly = buildOnly
        let artifacts = TimedArtifacts()
        self.artifacts = artifacts
        let xcrun = URL(fileURLWithPath: "/usr/bin/xcrun")
        launcher = IOSRunnerLauncher(xcrunURL: xcrun, channels: IOSRunnerChannelFactory(xcrunURL: xcrun),
            maximumRunnerLifetime: .seconds(180), artifacts: artifacts)
    }
    func installStartAndOpen(launch: IOSRunnerLaunch, projectURL: URL, scheme: String,
                             buildProducts: IOSRunnerBuildProducts) async throws -> any HelperRequestSending {
        if buildOnly {
            _ = try await artifacts.load(launch: launch, products: buildProducts)
            buildOnlyValidated = true
            throw IOSRunnerLaunchError.channelUnavailable
        }
        let started = ContinuousClock.now
        defer { elapsedSeconds = IOSPreparationTimingCheck.seconds(started.duration(to: .now)) }
        return try await launcher.installStartAndOpen(launch: launch, projectURL: projectURL,
            scheme: scheme, buildProducts: buildProducts)
    }
    func stop(launch: IOSRunnerLaunch) async { await launcher.stop(launch: launch) }
}
