import DeviceBridgeCore
import DeviceBridgeProtocol
import Foundation

/// Exercises the app's shared signing factory and real Core manager/cache with synthetic
/// build products only. No Xcode process, signing identity, certificate, or device is used.
@main
struct IOSRunnerOwnerSigningChecks {
    static func main() async throws {
        let fixture = try OwnerSigningFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "iosSigningTeamID")
        defaults.set("9Y3KFUUCJG", forKey: "iosSigningTeamID")
        defer {
            if let previous { defaults.set(previous, forKey: "iosSigningTeamID") }
            else { defaults.removeObject(forKey: "iosSigningTeamID") }
        }
        try require(defaults.string(forKey: "iosSigningTeamID") == "9Y3KFUUCJG",
                    "legacy preference must actually exist before testing the owner configuration")
        try require(IOSRunnerOwnerConfiguration.developmentTeamIdentifier == "5F6294RLX4",
                    "app owner development team changed unexpectedly")

        let runner = OwnerSigningBuildRunner()
        let cache = fixture.root.appendingPathComponent("cache")
        let launches = fixture.root.appendingPathComponent("launches")
        let legacyLauncher = OwnerSigningLauncher()
        // Seed a completed, otherwise-identical cache under the old team. Core's generic
        // team parameter is intentionally preserved and must not become the app constant.
        let legacyConfiguration = try IOSRunnerSourceConfiguration(helperResourcesURL: fixture.helpers,
            signingTeamID: "9Y3KFUUCJG")
        let legacy = IOSRunnerManager(xcodebuildURL: URL(fileURLWithPath: "/usr/bin/xcodebuild"),
            projectURL: legacyConfiguration.projectURL, scheme: legacyConfiguration.scheme,
            signingTeamID: legacyConfiguration.signingTeamID,
            runner: runner, launcher: legacyLauncher, buildRootDirectoryURL: launches,
            buildWorkspace: IOSRunnerBuildWorkspace(rootDirectoryURL: cache, reuseCompletedWorkspaces: true))
        try require(await legacy.prepare(deviceIdentifier: "owner-signing-test").channel != nil,
                    "old-team cache fixture did not complete its synthetic build")
        await legacy.stop()

        var newLaunchers: [OwnerSigningLauncher] = []
        for role in ["screenshot", "clipboard"] {
            let launcher = OwnerSigningLauncher()
            newLaunchers.append(launcher)
            let manager = try IOSRunnerOwnerConfiguration.manager(helperResourcesURL: fixture.helpers,
                runner: runner, launcher: launcher,
                buildWorkspace: IOSRunnerBuildWorkspace(rootDirectoryURL: cache, reuseCompletedWorkspaces: true),
                buildRootDirectoryURL: launches)
            let outcome = await manager.prepare(deviceIdentifier: "owner-signing-test")
            try require(outcome.channel != nil && outcome.failure == nil,
                        "\(role) factory did not reach its synthetic launcher")
            let teams = await launcher.expectedTeams
            try require(teams == ["5F6294RLX4"],
                        "\(role) signed-product verification expected the persisted legacy team")
            await manager.stop()
        }
        let requests = await runner.requests
        try require(requests.count == 3, "expected one old-team and two app-owner builds")
        try require(requests[0].arguments.contains("DEVELOPMENT_TEAM=9Y3KFUUCJG"),
                    "legacy fixture must seed a genuinely different team cache key")
        for request in requests.dropFirst() {
            try require(request.arguments.filter { $0.hasPrefix("DEVELOPMENT_TEAM=") } == ["DEVELOPMENT_TEAM=5F6294RLX4"],
                        "app helper xcodebuild request did not use exactly the owner team")
        }
        let paths = try requests.map { request in
            guard let index = request.arguments.firstIndex(of: "-derivedDataPath"),
                  request.arguments.indices.contains(index + 1) else { throw Failure.failed("build path missing") }
            return request.arguments[index + 1]
        }
        try require(paths[0] != paths[1], "owner build reused the old team's completed compiler inputs")
        try require(paths[1] == paths[2], "matching owner inputs must remain incrementally reusable across helper roles")
        let firstSnapshots = await newLaunchers[0].snapshots
        let secondSnapshots = await newLaunchers[1].snapshots
        try require(firstSnapshots.count == 1 && secondSnapshots.count == 1
                        && firstSnapshots[0] != secondSnapshots[0],
                    "shared compiler inputs must not merge distinct immutable launch snapshots")
        try require(defaults.string(forKey: "iosSigningTeamID") == "9Y3KFUUCJG",
                    "ignoring old preferences must not silently rewrite them")
        try require(!IOSRunnerOwnerConfiguration.signingRecoveryMessage.contains("Settings"),
                    "recovery points to a removed Team ID preference")
        print("PASS: real legacy UserDefaults ignored; screenshot/clipboard factory builds use DEVELOPMENT_TEAM=5F6294RLX4 and expectedTeam; old-team cache isolated, matching owner cache reused; no actual signing or device")
    }

    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure.failed(message) }
    }
    enum Failure: Error { case failed(String) }
}

private struct OwnerSigningFixture {
    let root: URL
    var helpers: URL { root.appendingPathComponent("Helpers") }
    var source: URL { helpers.appendingPathComponent("ios-runner") }
    var project: URL { source.appendingPathComponent("helpers/ios/DeviceBridgeRunner.xcodeproj") }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("owner-signing-" + UUID().uuidString)
        for path in ["helpers/ios/DeviceBridgeRunner.xcodeproj", "packages/DeviceBridgeProtocol", "packages/DeviceBridgeSecureChannel"] {
            let directory = source.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if path.hasSuffix("xcodeproj") {
                try Data("synthetic project".utf8).write(to: directory.appendingPathComponent("project.pbxproj"))
            } else {
                try Data("synthetic package".utf8).write(to: directory.appendingPathComponent("Package.swift"))
                try FileManager.default.createDirectory(at: directory.appendingPathComponent("Sources"), withIntermediateDirectories: true)
            }
        }
        let manifest: [String: Any] = ["schemaVersion": 1, "ios": ["directory": "ios-runner",
            "project": "helpers/ios/DeviceBridgeRunner.xcodeproj", "scheme": "DeviceBridgeRunner"]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: helpers.appendingPathComponent("manifest.json"))
    }
}

private actor OwnerSigningBuildRunner: HostCommandRunning {
    private(set) var requests: [HostCommandRequest] = []
    func run(_ request: HostCommandRequest) throws -> HostCommandResult {
        guard request.arguments.first == "build-for-testing",
              let index = request.arguments.firstIndex(of: "-derivedDataPath") else {
            throw IOSRunnerOwnerSigningChecks.Failure.failed("unexpected command; real execution is forbidden")
        }
        requests.append(request)
        let products = URL(fileURLWithPath: request.arguments[index + 1]).appendingPathComponent("Build/Products")
        for name in ["DeviceBridgeRunnerUITests-Runner.app", "DeviceBridgeHost.app", "DeviceBridgeClipboardHost.app"] {
            let application = products.appendingPathComponent("Debug-iphoneos/" + name)
            try FileManager.default.createDirectory(at: application, withIntermediateDirectories: true)
            try Data("synthetic build \(requests.count)".utf8).write(to: application.appendingPathComponent("binary"))
        }
        let metadata = ["TestHostPath": products.appendingPathComponent("Debug-iphoneos/DeviceBridgeHost.app").path]
        try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0)
            .write(to: products.appendingPathComponent("Runner.xctestrun"))
        return HostCommandResult(exitCode: 0, standardOutput: Data(), standardError: Data())
    }
}

private actor OwnerSigningLauncher: IOSRunnerChannelLaunching {
    private(set) var expectedTeams: [String] = []
    private(set) var snapshots: [URL] = []
    func installStartAndOpen(launch: IOSRunnerLaunch, projectURL: URL, scheme: String,
                             buildProducts: IOSRunnerBuildProducts) throws -> any HelperRequestSending {
        expectedTeams.append(buildProducts.expectedTeamIdentifier)
        snapshots.append(buildProducts.productsDirectoryURL)
        return OwnerSigningChannel()
    }
    func stop(launch: IOSRunnerLaunch) {}
}

private struct OwnerSigningChannel: HelperRequestSending {
    func send(_ request: HelperRequest) async throws -> HelperResult {
        throw IOSRunnerOwnerSigningChecks.Failure.failed("signing configuration test must not read device content")
    }
}
