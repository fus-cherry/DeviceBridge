import DeviceBridgeProtocol
import Foundation
import Testing
@testable import DeviceBridgeCore

@Suite("Independent selected iPhone application/process metadata")
struct IOSApplicationProcessProviderTests {
    @Test("developer app main executable is correlated through matching device-scoped JSON")
    func selectedDevice() async throws {
        let commands = ProcessMetadataCommand()
        let provider = IOSApplicationProcessProvider(commands: commands)
        let session = try processSession()
        let inventory = try await provider.load(session: session)
        #expect(inventory.session == session)
        #expect(inventory.applications.count == 1)
        let app = try #require(inventory.applications.first)
        #expect(app.target.deviceIdentity == session.deviceIdentity)
        #expect(app.target.applicationID == "dev.example.app")
        #expect(app.target.processID == 123)
        #expect(app.target.processStartIdentity == nil)
        #expect(app.target.state == .running)
        #expect(app.executableURL.path == "/private/apps/ABC/Example.app/Example")
        let requests = await commands.requests
        #expect(requests.map { $0.arguments[3] } == ["details", "apps", "processes", "details"])
        for request in requests {
            #expect(request.executableURL.path == "/usr/bin/xcrun")
            #expect(request.arguments.prefix(3) == ["devicectl", "device", "info"])
            #expect(argument("--device", request) == "11111111-1111-1111-1111-111111111111")
            #expect(request.arguments.contains("--quiet"))
            #expect(!request.arguments.contains("--include-all-apps"))
            #expect(request.maximumOutputBytes == 0)
        }
        try await expectMetadataCleanup(commands)
    }

    @Test("wrong device, changed route and unsupported trust state reject the whole snapshot", arguments: [
        "wrongDetailsID", "wrongUDID", "wrongAppsID", "wrongProcessesID", "wirelessAfter", "unpaired", "developerDisabled", "simulator", "android",
    ])
    func rejectsScope(_ variant: String) async throws {
        let commands = ProcessMetadataCommand(variant)
        let provider = IOSApplicationProcessProvider(commands: commands)
        await #expect(throws: IOSApplicationProcessProvider.Failure.self) { try await provider.load(session: processSession()) }
        try await expectMetadataCleanup(commands)
    }

    @Test("an extension, prefix lookalike or ambiguous process never becomes the main app", arguments: ["extensionOnly", "prefixOnly", "twoMainProcesses", "notDeveloper"])
    func noFalseProcess(_ variant: String) async throws {
        let commands = ProcessMetadataCommand(variant)
        let inventory = try await IOSApplicationProcessProvider(commands: commands).load(session: processSession())
        #expect(inventory.applications.isEmpty)
        try await expectMetadataCleanup(commands)
    }

    @Test("malformed metadata cannot fabricate process identity", arguments: [
        "booleanPID", "fractionalPID", "missingPID", "remoteExecutable", "traversalExecutable", "duplicateApps", "duplicateInstallation", "duplicateProcessPID", "failedEnvelope", "badJSON", "oversized", "symlink",
    ])
    func invalidMetadata(_ variant: String) async throws {
        let commands = ProcessMetadataCommand(variant)
        await #expect(throws: IOSApplicationProcessProvider.Failure.self) {
            try await IOSApplicationProcessProvider(commands: commands).load(session: processSession())
        }
        try await expectMetadataCleanup(commands)
    }

    @Test("external diagnostics are suppressed and failed output is cleaned")
    func failedCommand() async throws {
        let commands = ProcessMetadataCommand("failedCommand")
        do {
            _ = try await IOSApplicationProcessProvider(commands: commands).load(session: processSession())
            Issue.record("failed metadata command returned an inventory")
        } catch { #expect(!String(describing: error).contains("private-canary")) }
        try await expectMetadataCleanup(commands)
    }

    @Test("cancellation after file output rejects publication and cleans its directory")
    func cancelledOutput() async throws {
        let commands = ProcessMetadataCommand("hold")
        let provider = IOSApplicationProcessProvider(commands: commands)
        let session = try processSession()
        let load = Task { try await provider.load(session: session) }
        try await commands.waitUntilHeld()
        load.cancel()
        await commands.release()
        await #expect(throws: CancellationError.self) { try await load.value }
        #expect(await commands.requests.count == 1)
        try await expectMetadataCleanup(commands)
    }

    @Test("inactive or provisional sessions issue no device command", arguments: [false, true])
    func rejectsSession(_ provisional: Bool) async throws {
        let commands = ProcessMetadataCommand()
        let identity = try DeviceIdentity(rawValue: "PUBLIC-UDID", stability: provisional ? .provisional : .stable, platform: .iOS)
        let session = ConnectionSession(deviceIdentity: identity, generation: 1,
            transportID: "11111111-1111-1111-1111-111111111111", state: provisional ? .active : .disconnected, startedAt: .distantPast)
        await #expect(throws: IOSApplicationProcessProvider.Failure.self) {
            try await IOSApplicationProcessProvider(commands: commands).load(session: session)
        }
        #expect(await commands.requests.isEmpty)
    }

    @Test("cancellation does not hide a failed private-metadata cleanup")
    func failedCancelledCleanup() async throws {
        let commands = ProcessMetadataCommand("holdCleanup")
        let provider = IOSApplicationProcessProvider(commands: commands)
        let session = try processSession()
        let load = Task { try await provider.load(session: session) }
        try await commands.waitUntilHeld()
        let request = try #require(await commands.requests.first)
        let output = URL(fileURLWithPath: try #require(argument("--json-output", request)))
        let directory = output.deletingLastPathComponent()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        load.cancel()
        await commands.release()
        await #expect(throws: IOSApplicationProcessProvider.Failure.cleanupFailed) { try await load.value }
        #expect(FileManager.default.fileExists(atPath: output.path))
    }
}

private func processSession() throws -> ConnectionSession {
    ConnectionSession(deviceIdentity: try DeviceIdentity(rawValue: "PUBLIC-UDID", stability: .stable, platform: .iOS),
        generation: 1, transportID: "11111111-1111-1111-1111-111111111111", state: .active, startedAt: .distantPast)
}

private func argument(_ name: String, _ request: HostCommandRequest) -> String? {
    guard let index = request.arguments.firstIndex(of: name), index + 1 < request.arguments.count else { return nil }
    return request.arguments[index + 1]
}

private func expectMetadataCleanup(_ commands: ProcessMetadataCommand) async throws {
    for request in await commands.requests {
        let path = try #require(argument("--json-output", request))
        #expect(!FileManager.default.fileExists(atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path))
    }
}

/// The external command boundary writes synthetic CoreDevice JSON to the real owned directory.
private actor ProcessMetadataCommand: HostCommandRunning {
    private let variant: String
    private(set) var requests: [HostCommandRequest] = []
    private var held: CheckedContinuation<Void, Never>?
    init(_ variant: String = "valid") { self.variant = variant }
    func run(_ request: HostCommandRequest) async throws -> HostCommandResult {
        requests.append(request)
        let output = URL(fileURLWithPath: try #require(argument("--json-output", request)))
        let attributes = try FileManager.default.attributesOfItem(atPath: output.deletingLastPathComponent().path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        let kind = request.arguments[3]
        let id = "11111111-1111-1111-1111-111111111111"
        var result: [String: Any]
        switch kind {
        case "details":
            result = ["identifier": variant == "wrongDetailsID" ? "22222222-2222-2222-2222-222222222222" : id,
                "hardwareProperties": ["udid": variant == "wrongUDID" ? "PUBLIC-OTHER" : "PUBLIC-UDID",
                    "platform": variant == "android" ? "Android" : "iOS", "reality": variant == "simulator" ? "simulated" : "physical"],
                "connectionProperties": ["transportType": variant == "wirelessAfter" && requests.count == 4 ? "wireless" : "wired",
                    "pairingState": variant == "unpaired" ? "unpaired" : "paired"],
                "deviceProperties": ["developerModeStatus": variant == "developerDisabled" ? "disabled" : "enabled"]]
        case "apps":
            let app: [String: Any] = ["bundleIdentifier": "dev.example.app", "name": "Example", "builtByDeveloper": variant != "notDeveloper",
                "url": "file:///private/apps/ABC/Example.app/"]
            var apps = variant == "duplicateApps" ? [app, app] : [app]
            if ["duplicateInstallation", "duplicateProcessPID"].contains(variant) {
                var other = app
                other["bundleIdentifier"] = "dev.example.other"
                if variant == "duplicateProcessPID" { other["url"] = "file:///private/apps/DEF/Other.app/" }
                apps.append(other)
            }
            result = ["deviceIdentifier": variant == "wrongAppsID" ? "22222222-2222-2222-2222-222222222222" : id,
                "apps": apps]
        case "processes":
            var process: [String: Any] = ["processIdentifier": 123, "executable": "file:///private/apps/ABC/Example.app/Example"]
            switch variant {
            case "extensionOnly": process["executable"] = "file:///private/apps/ABC/Example.app/PlugIns/Share.appex/Share"
            case "prefixOnly": process["executable"] = "file:///private/apps/ABC/Example.app.evil/Example"
            case "remoteExecutable": process["executable"] = "https://foreign.invalid/private/apps/ABC/Example.app/Example"
            case "traversalExecutable": process["executable"] = "file:///private/apps/ABC/Other.app/../Example.app/Example"
            case "booleanPID": process["processIdentifier"] = true
            case "fractionalPID": process["processIdentifier"] = 123.5
            case "missingPID": process["processIdentifier"] = nil
            default: break
            }
            var processes = [process]
            if variant == "twoMainProcesses" { processes.append(["processIdentifier": 456, "executable": "file:///private/apps/ABC/Example.app/Other"]) }
            if variant == "duplicateProcessPID" { processes.append(["processIdentifier": 123, "executable": "file:///private/apps/DEF/Other.app/Other"]) }
            result = ["deviceIdentifier": variant == "wrongProcessesID" ? "22222222-2222-2222-2222-222222222222" : id,
                "runningProcesses": processes]
        default: throw IOSApplicationProcessProvider.Failure.invalidMetadata
        }
        let envelope: [String: Any] = ["info": ["outcome": variant == "failedEnvelope" ? "failed" : "success"], "result": result]
        let data = variant == "badJSON" ? Data("invalid".utf8) : variant == "oversized" ? Data(repeating: 32, count: 4_194_305)
            : try JSONSerialization.data(withJSONObject: envelope)
        if variant == "symlink" {
            let other = output.deletingLastPathComponent().appendingPathComponent("other.json")
            try data.write(to: other)
            try FileManager.default.createSymbolicLink(at: output, withDestinationURL: other)
        } else { try data.write(to: output) }
        if variant == "holdCleanup" { try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: output.deletingLastPathComponent().path) }
        if variant == "hold" || variant == "holdCleanup" { await withCheckedContinuation { held = $0 } }
        return HostCommandResult(exitCode: variant == "failedCommand" ? 1 : 0,
            standardOutput: Data(), standardError: Data("private-canary".utf8))
    }
    func release() { held?.resume(); held = nil }
    func waitUntilHeld() async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while held == nil {
            guard ContinuousClock.now < deadline else { throw IOSApplicationProcessProvider.Failure.invalidMetadata }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}
