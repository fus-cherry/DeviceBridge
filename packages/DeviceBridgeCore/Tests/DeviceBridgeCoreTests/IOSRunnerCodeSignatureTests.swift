import Foundation
import Testing
@testable import DeviceBridgeCore

struct IOSRunnerCodeSignatureTests {
    @Test func invalidExpectationsAndForeignCodeCannotPass() throws {
        let checker = IOSRunnerCodeSignatureChecker()
        for team in ["", "SHORT", "TEAM\" or true", "AAAAAAAAAA"] {
            #expect(throws: (any Error).self) {
                try checker.verify(at: URL(fileURLWithPath: "/usr/bin/true"), role: .runner, expectedTeamIdentifier: team)
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DEVICEBRIDGE_SIGNED_PRODUCTS"] != nil))
    func existingPersonalSignedProductsPassAndWrongIdentityFails() throws {
        let environment = ProcessInfo.processInfo.environment
        let rootPath = try #require(environment["DEVICEBRIDGE_SIGNED_PRODUCTS"])
        let team = try #require(environment["DEVICEBRIDGE_EXPECTED_TEAM"])
        let root = URL(fileURLWithPath: rootPath)
        let checker = IOSRunnerCodeSignatureChecker()
        let paths: [(IOSRunnerCodeRole, String)] = [
            (.runner, "Debug-iphoneos/DeviceBridgeRunnerUITests-Runner.app"),
            (.tests, "Debug-iphoneos/DeviceBridgeRunnerUITests-Runner.app/PlugIns/DeviceBridgeRunnerUITests.xctest"),
            (.host, "Debug-iphoneos/DeviceBridgeHost.app"),
            (.clipboardHost, "Debug-iphoneos/DeviceBridgeClipboardHost.app"),
        ]
        for (role, relative) in paths {
            let url = root.appendingPathComponent(relative)
            let signature = try checker.verify(at: url, role: role, expectedTeamIdentifier: team)
            // Assertions deliberately cannot render personal Team/certificate contents on failure.
            let correctTeam = signature.teamIdentifier == team
            let correctBundle = signature.bundleIdentifier == role.bundleIdentifier
            #expect(correctTeam)
            #expect(correctBundle)
            #expect(!signature.leafCertificateDER.isEmpty)
            #expect(throws: (any Error).self) {
                try checker.verify(at: url, role: role, expectedTeamIdentifier: "AAAAAAAAAA")
            }
            #expect(throws: (any Error).self) {
                try checker.verify(at: url, role: role == .host ? .tests : .host, expectedTeamIdentifier: team)
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DEVICEBRIDGE_SIGNED_PRODUCTS"] != nil))
    func modifiedSignedResourceIsRejected() throws {
        let environment = ProcessInfo.processInfo.environment
        let rootPath = try #require(environment["DEVICEBRIDGE_SIGNED_PRODUCTS"])
        let team = try #require(environment["DEVICEBRIDGE_EXPECTED_TEAM"])
        let original = URL(fileURLWithPath: rootPath).appendingPathComponent("Debug-iphoneos/DeviceBridgeHost.app")
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("DeviceBridgeSignatureTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let copy = temporary.appendingPathComponent("Host.app")
        try FileManager.default.copyItem(at: original, to: copy)
        let checker = IOSRunnerCodeSignatureChecker()
        _ = try checker.verify(at: copy, role: .host, expectedTeamIdentifier: team)
        let infoURL = copy.appendingPathComponent("Info.plist")
        var info = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: infoURL), format: nil) as? [String: Any])
        info["DeviceBridgeTamperCanary"] = "public-test-only"
        try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0).write(to: infoURL)
        #expect(throws: (any Error).self) {
            try checker.verify(at: copy, role: .host, expectedTeamIdentifier: team)
        }
        // The control is never edited: it must remain valid after the tampered copy fails.
        _ = try checker.verify(at: original, role: .host, expectedTeamIdentifier: team)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DEVICEBRIDGE_SIGNED_PRODUCTS"] != nil))
    func ownedSignedConfigurationLoadsAndTamperedOrForeignArtifactsFail() throws {
        let environment = ProcessInfo.processInfo.environment
        let rootPath = try #require(environment["DEVICEBRIDGE_SIGNED_PRODUCTS"])
        let team = try #require(environment["DEVICEBRIDGE_EXPECTED_TEAM"])
        let original = URL(fileURLWithPath: rootPath)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("DeviceBridgeArtifactsTest-\(UUID().uuidString)")
        let launch = IOSRunnerLaunch(deviceIdentifier: "synthetic-phone")
        let products = IOSRunnerBuildProducts(launchID: launch.id, rootDirectoryURL: temporary, expectedTeamIdentifier: team)
        let destination = products.productsDirectoryURL.appendingPathComponent("Debug-iphoneos")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        for name in ["DeviceBridgeRunnerUITests-Runner.app", "DeviceBridgeHost.app",
                     "DeviceBridgeClipboardHost.app"] {
            try FileManager.default.copyItem(at: original.appendingPathComponent("Debug-iphoneos/" + name),
                to: destination.appendingPathComponent(name))
        }
        let runs = try FileManager.default.contentsOfDirectory(at: original, includingPropertiesForKeys: nil).filter { $0.pathExtension == "xctestrun" }
        #expect(runs.count == 1)
        let source = try #require(runs.first)
        try FileManager.default.copyItem(at: source, to: products.productsDirectoryURL.appendingPathComponent(source.lastPathComponent))
        let checked = try IOSRunnerSignedArtifacts.load(launch: launch, products: products)
        #expect(checked.configuration.launchID == launch.id)
        #expect(checked.configuration.runnerApplicationURL.deletingLastPathComponent().path == destination.path)
        #expect(throws: (any Error).self) {
            try IOSRunnerSignedArtifacts.load(launch: IOSRunnerLaunch(deviceIdentifier: "synthetic-phone"), products: products)
        }
        let wrongTeam = IOSRunnerBuildProducts(launchID: launch.id, rootDirectoryURL: temporary, expectedTeamIdentifier: "AAAAAAAAAA")
        #expect(throws: (any Error).self) { try IOSRunnerSignedArtifacts.load(launch: launch, products: wrongTeam) }
        let host = destination.appendingPathComponent("DeviceBridgeHost.app")
        let heldHost = temporary.appendingPathComponent("HeldHost.app")
        try FileManager.default.moveItem(at: host, to: heldHost)
        try FileManager.default.createSymbolicLink(at: host, withDestinationURL: heldHost)
        #expect(throws: (any Error).self) { try IOSRunnerSignedArtifacts.load(launch: launch, products: products) }
        try FileManager.default.removeItem(at: host)
        try FileManager.default.moveItem(at: heldHost, to: host)
        try Data("broken sealed plist".utf8).write(to: host.appendingPathComponent("Info.plist"))
        #expect(throws: (any Error).self) { try IOSRunnerSignedArtifacts.load(launch: launch, products: products) }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DEVICEBRIDGE_STARTUP_DEVICE"] != nil))
    func exactSignedProductsStartOnOptedInPhysicalPhone() async throws {
        let environment = ProcessInfo.processInfo.environment
        let rootPath = try #require(environment["DEVICEBRIDGE_SIGNED_PRODUCTS"])
        let team = try #require(environment["DEVICEBRIDGE_EXPECTED_TEAM"])
        let device = try #require(environment["DEVICEBRIDGE_STARTUP_DEVICE"])
        let original = URL(fileURLWithPath: rootPath)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("DeviceBridgePhysicalStartup-\(UUID().uuidString)")
        let launch = IOSRunnerLaunch(deviceIdentifier: device)
        let products = IOSRunnerBuildProducts(launchID: launch.id, rootDirectoryURL: temporary, expectedTeamIdentifier: team)
        let destination = products.productsDirectoryURL.appendingPathComponent("Debug-iphoneos")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        for name in ["DeviceBridgeRunnerUITests-Runner.app", "DeviceBridgeHost.app",
                     "DeviceBridgeClipboardHost.app"] {
            try FileManager.default.copyItem(at: original.appendingPathComponent("Debug-iphoneos/" + name),
                to: destination.appendingPathComponent(name))
        }
        let runs = try FileManager.default.contentsOfDirectory(at: original, includingPropertiesForKeys: nil).filter { $0.pathExtension == "xctestrun" }
        let source = try #require(runs.count == 1 ? runs.first : nil)
        try FileManager.default.copyItem(at: source, to: products.productsDirectoryURL.appendingPathComponent(source.lastPathComponent))
        let artifacts = try IOSRunnerSignedArtifacts.load(launch: launch, products: products)
        let configurationURL = products.derivedDataDirectoryURL.appendingPathComponent("startup.xctestrun")
        try artifacts.configuration.configurationData.write(to: configurationURL, options: .atomic)
        let resultURL = products.derivedDataDirectoryURL.appendingPathComponent("startup.xcresult")
        // No inherited TEST_RUNNER variables, secrets or desktop automation; phone-only startup label.
        let allowed = ["PATH", "HOME", "TMPDIR", "DEVELOPER_DIR", "LANG", "LC_ALL"]
        let childEnvironment = environment.filter { allowed.contains($0.key) }
        let process = try IOSRunnerProcess.start(executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["xcodebuild", "test-without-building", "-xctestrun", configurationURL.path,
                "-destination", "id=" + launch.deviceIdentifier,
                "-only-testing:DeviceBridgeRunnerUITests/RunnerSmokeTests/testRunnerCanLaunchManagedHost",
                "-parallel-testing-enabled", "NO", "-resultBundlePath", resultURL.path],
            environment: childEnvironment, lifetime: .seconds(60))
        let exit = await withTaskCancellationHandler {
            await process.waitForExit()
        } onCancel: {
            Task { await process.stop() }
        }
        try Task.checkCancellation()
        #expect(exit.code == 0)
        let summary = try await HostCommandRunner().run(HostCommandRequest(
            executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["xcresulttool", "get", "test-results", "summary", "--path", resultURL.path],
            timeout: .seconds(10), maximumOutputBytes: 65_536))
        let object = try #require(JSONSerialization.jsonObject(with: summary.standardOutput) as? [String: Any])
        // Never render a complete result object: it contains device/signing metadata.
        let passed = object["passedTests"] as? Int
        let failed = object["failedTests"] as? Int
        let skipped = object["skippedTests"] as? Int
        #expect(summary.exitCode == 0 && passed == 1 && failed == 0 && skipped == 0)
        _ = try IOSRunnerSignedArtifacts.load(launch: launch, products: products)
    }
}
