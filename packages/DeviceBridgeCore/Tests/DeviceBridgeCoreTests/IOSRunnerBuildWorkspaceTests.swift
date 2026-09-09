import Foundation
import Testing
@testable import DeviceBridgeCore

@Suite("iOS incremental build ownership")
struct IOSRunnerBuildWorkspaceTests {
    @Test("completed inputs survive actor recreation while launch snapshots remain immutable")
    func persistentReuse() async throws {
        let fixture = BuildWorkspaceFixture()
        defer { fixture.remove() }
        let root = fixture.root.appendingPathComponent("cache")
        let first = IOSRunnerBuildWorkspace(rootDirectoryURL: root, reuseCompletedWorkspaces: true)
        let runner = BuildWorkspaceRunner()
        let a = fixture.products(), b = fixture.products()
        _ = try await first.run(fixture.request(a), runner: runner, snapshot: a)
        let restarted = IOSRunnerBuildWorkspace(rootDirectoryURL: root, reuseCompletedWorkspaces: true)
        _ = try await restarted.run(fixture.request(b), runner: runner, snapshot: b)
        let paths = await runner.paths
        #expect(paths.first == paths.last)
        #expect(try Data(contentsOf: a.productsDirectoryURL.appendingPathComponent("Debug-iphoneos/DeviceBridgeHost.app/binary")) == Data("1".utf8))
        #expect(try Data(contentsOf: b.productsDirectoryURL.appendingPathComponent("Debug-iphoneos/DeviceBridgeHost.app/binary")) == Data("2".utf8))
    }

    @Test("every actor reacquires ownership, including the actor that last released the workspace")
    func persistentExclusiveClaims() async throws {
        let fixture = BuildWorkspaceFixture()
        defer { fixture.remove() }
        let root = fixture.root.appendingPathComponent("cache")
        let first = IOSRunnerBuildWorkspace(rootDirectoryURL: root, reuseCompletedWorkspaces: true)
        let second = IOSRunnerBuildWorkspace(rootDirectoryURL: root, reuseCompletedWorkspaces: true)
        let ordinary = BuildWorkspaceRunner(), gate = BuildWorkspaceGate()
        let held = BuildWorkspaceRunner(gate: gate)
        let a = fixture.products(), b = fixture.products(), c = fixture.products()
        _ = try await first.run(fixture.request(a), runner: ordinary, snapshot: a)
        let work = Task { try await second.run(fixture.request(b), runner: held, snapshot: b) }
        await gate.waitForEntry()
        let heldPaths = await held.paths, originalPaths = await ordinary.paths
        #expect(heldPaths.first == originalPaths.first)
        _ = try await first.run(fixture.request(c), runner: ordinary, snapshot: c)
        #expect(await ordinary.paths.last != held.paths.first)
        await gate.release()
        #expect(try await work.value.exitCode == 0)
    }

    @Test("cancelled late success is never offered to another process")
    func persistentCancelledClaim() async throws {
        let fixture = BuildWorkspaceFixture()
        defer { fixture.remove() }
        let root = fixture.root.appendingPathComponent("cache")
        let first = IOSRunnerBuildWorkspace(rootDirectoryURL: root, reuseCompletedWorkspaces: true)
        let gate = BuildWorkspaceGate(), runner = BuildWorkspaceRunner(gate: nil)
        let held = BuildWorkspaceRunner(gate: gate)
        let a = fixture.products(), b = fixture.products()
        let task = Task { try await first.run(fixture.request(a), runner: held, snapshot: a) }
        await gate.waitForEntry()
        task.cancel()
        await gate.release()
        await #expect(throws: CancellationError.self) { try await task.value }
        let restarted = IOSRunnerBuildWorkspace(rootDirectoryURL: root, reuseCompletedWorkspaces: true)
        _ = try await restarted.run(fixture.request(b), runner: runner, snapshot: b)
        #expect(await held.paths.first != runner.paths.first)
        #expect(!FileManager.default.fileExists(atPath: a.productsDirectoryURL.path))
    }

    @Test("failed build and snapshot claims stay unavailable after restart", arguments: ["exit", "missing", "multiple", "symlink", "external", "oversized"])
    func persistentFailure(_ mode: String) async throws {
        let fixture = BuildWorkspaceFixture()
        defer { fixture.remove() }
        let root = fixture.root.appendingPathComponent("cache")
        let first = IOSRunnerBuildWorkspace(rootDirectoryURL: root, reuseCompletedWorkspaces: true)
        let runner = BuildWorkspaceRunner(firstFailure: mode)
        let a = fixture.products(), b = fixture.products()
        do {
            let result = try await first.run(fixture.request(a), runner: runner, snapshot: a)
            #expect(mode == "exit" && result.exitCode != 0)
        } catch { #expect(mode != "exit") }
        let restarted = IOSRunnerBuildWorkspace(rootDirectoryURL: root, reuseCompletedWorkspaces: true)
        _ = try await restarted.run(fixture.request(b), runner: runner, snapshot: b)
        #expect(await runner.paths.first != runner.paths.last)
    }

    @Test("build input keys separate team, device, project and explicit environment", arguments: ["team", "device", "project", "environment", "empty-environment"])
    func persistentInputKey(_ change: String) async throws {
        let fixture = BuildWorkspaceFixture()
        defer { fixture.remove() }
        let root = fixture.root.appendingPathComponent("cache")
        let workspace = IOSRunnerBuildWorkspace(rootDirectoryURL: root, reuseCompletedWorkspaces: true)
        let runner = BuildWorkspaceRunner()
        let a = fixture.products(), b = fixture.products()
        _ = try await workspace.run(fixture.request(a), runner: runner, snapshot: a)
        let original = fixture.request(b)
        var arguments = original.arguments
        var environment: [String: String]?
        switch change {
        case "team": arguments += ["DEVELOPMENT_TEAM=OTHER"]
        case "device": arguments += ["-destination", "id=other"]
        case "project": arguments += ["-project", "/other/project.xcodeproj"]
        case "environment": environment = ["SDKROOT": "/different/sdk"]
        default: environment = [:]
        }
        let changed = HostCommandRequest(executableURL: original.executableURL, arguments: arguments,
            environment: environment, timeout: original.timeout)
        _ = try await workspace.run(changed, runner: runner, snapshot: b)
        #expect(await runner.paths.first != runner.paths.last)
    }

    @Test("cancelled writer drains before the next build and cannot publish")
    func cancelledWriter() async throws {
        let fixture = BuildWorkspaceFixture()
        defer { fixture.remove() }
        let workspace = IOSRunnerBuildWorkspace(rootDirectoryURL: fixture.root.appendingPathComponent("inputs"))
        let gate = BuildWorkspaceGate()
        let runner = BuildWorkspaceRunner(gate: gate)
        let a = fixture.products(), b = fixture.products()
        let first = Task { try await workspace.run(fixture.request(a), runner: runner, snapshot: a) }
        await gate.waitForEntry()
        first.cancel()
        let next = Task { try await workspace.run(fixture.request(b), runner: runner, snapshot: b) }
        try await Task.sleep(for: .milliseconds(60))
        #expect(await runner.paths.count == 1)
        await gate.release()
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(try await next.value.exitCode == 0)
        let paths = await runner.paths
        #expect(paths.count == 2)
        #expect(paths.first != paths.last)
        #expect(!FileManager.default.fileExists(atPath: a.productsDirectoryURL.path))
        #expect(FileManager.default.fileExists(atPath: b.productsDirectoryURL.path))
    }

    @Test("cancelling a queued build neither runs Xcode nor discards the active workspace")
    func cancelledWaiter() async throws {
        let fixture = BuildWorkspaceFixture()
        defer { fixture.remove() }
        let workspace = IOSRunnerBuildWorkspace(rootDirectoryURL: fixture.root.appendingPathComponent("inputs"))
        let gate = BuildWorkspaceGate(), runner = BuildWorkspaceRunner()
        let heldRunner = BuildWorkspaceRunner(gate: gate)
        let a = fixture.products(), b = fixture.products(), c = fixture.products()
        let first = Task { try await workspace.run(fixture.request(a), runner: heldRunner, snapshot: a) }
        await gate.waitForEntry()
        let cancelled = Task { try await workspace.run(fixture.request(b), runner: runner, snapshot: b) }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(await runner.paths.isEmpty)
        await gate.release()
        _ = try await first.value
        _ = try await workspace.run(fixture.request(c), runner: runner, snapshot: c)
        #expect(await heldRunner.paths.first == runner.paths.first)
        #expect(!FileManager.default.fileExists(atPath: b.productsDirectoryURL.path))
    }

    @Test("failed build or snapshot rotates inputs and never publishes partial products", arguments: ["exit", "missing", "multiple", "symlink", "external", "oversized"])
    func failedPublication(_ mode: String) async throws {
        let fixture = BuildWorkspaceFixture()
        defer { fixture.remove() }
        let workspace = IOSRunnerBuildWorkspace(rootDirectoryURL: fixture.root.appendingPathComponent("inputs"))
        let runner = BuildWorkspaceRunner(firstFailure: mode)
        let first = fixture.products(), next = fixture.products()
        do {
            let result = try await workspace.run(fixture.request(first), runner: runner, snapshot: first)
            #expect(mode == "exit" && result.exitCode != 0)
        } catch {
            #expect(mode != "exit")
        }
        #expect(!FileManager.default.fileExists(atPath: first.productsDirectoryURL.path))
        #expect(try await workspace.run(fixture.request(next), runner: runner, snapshot: next).exitCode == 0)
        #expect(await runner.paths.first != runner.paths.last)
        let buildParent = first.productsDirectoryURL.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: buildParent.path) {
            #expect(try FileManager.default.contentsOfDirectory(atPath: buildParent.path).isEmpty)
        }
    }

    @Test("snapshots relocate metadata, preserve bytes, and are independent of previous cleanup")
    func immutableProducts() async throws {
        let fixture = BuildWorkspaceFixture()
        defer { fixture.remove() }
        let workspace = IOSRunnerBuildWorkspace(rootDirectoryURL: fixture.root.appendingPathComponent("inputs"))
        let runner = BuildWorkspaceRunner()
        let a = fixture.products(), b = fixture.products()
        _ = try await workspace.run(fixture.request(a), runner: runner, snapshot: a)
        _ = try await workspace.run(fixture.request(b), runner: runner, snapshot: b)
        #expect(await runner.paths.count == 2)
        #expect(await runner.paths.first == runner.paths.last)
        #expect(try Data(contentsOf: a.productsDirectoryURL.appendingPathComponent("Debug-iphoneos/DeviceBridgeHost.app/binary")) == Data("1".utf8))
        let config = try Data(contentsOf: b.productsDirectoryURL.appendingPathComponent("Runner.xctestrun"))
        let plist = try #require(PropertyListSerialization.propertyList(from: config, format: nil) as? [String: String])
        #expect(plist["TestHostPath"] == b.productsDirectoryURL.path + "/Debug-iphoneos/DeviceBridgeHost.app")
        #expect(plist["SystemPath"] == "/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform")
        try FileManager.default.removeItem(at: a.derivedDataDirectoryURL)
        #expect(try Data(contentsOf: b.productsDirectoryURL.appendingPathComponent("Debug-iphoneos/DeviceBridgeHost.app/binary")) == Data("2".utf8))
        let other = IOSRunnerBuildWorkspace(rootDirectoryURL: fixture.root.appendingPathComponent("inputs"))
        let c = fixture.products()
        _ = try await other.run(fixture.request(c), runner: runner, snapshot: c)
        #expect(await runner.paths.first != runner.paths.last)
    }

    @Test("canonical product aliases relocate and dot-segment escapes cannot reference mutable inputs")
    func canonicalPaths() async throws {
        let fixture = BuildWorkspaceFixture()
        defer { fixture.remove() }
        let workspace = IOSRunnerBuildWorkspace(rootDirectoryURL: fixture.root.appendingPathComponent("inputs"))
        let runner = BuildWorkspaceRunner(firstFailure: "alias")
        let products = fixture.products()
        _ = try await workspace.run(fixture.request(products), runner: runner, snapshot: products)
        let data = try Data(contentsOf: products.productsDirectoryURL.appendingPathComponent("Runner.xctestrun"))
        let plist = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
        #expect(plist["TestHostPath"] == products.productsDirectoryURL.path + "/Debug-iphoneos/DeviceBridgeHost.app")
        let escaped = fixture.products()
        await #expect(throws: HostCommandError.self) {
            try await workspace.run(fixture.request(escaped), runner: BuildWorkspaceRunner(firstFailure: "escape"), snapshot: escaped)
        }
        #expect(!FileManager.default.fileExists(atPath: escaped.productsDirectoryURL.path))
    }
}

private struct BuildWorkspaceFixture: Sendable {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    func products() -> IOSRunnerBuildProducts {
        IOSRunnerBuildProducts(launchID: UUID(), rootDirectoryURL: root.appendingPathComponent("launches"), expectedTeamIdentifier: "TEAM")
    }
    func request(_ products: IOSRunnerBuildProducts) -> HostCommandRequest {
        HostCommandRequest(executableURL: URL(fileURLWithPath: "/xcodebuild"),
            arguments: ["build-for-testing", "-derivedDataPath", products.derivedDataDirectoryURL.path], timeout: .seconds(5))
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

private actor BuildWorkspaceRunner: HostCommandRunning {
    private(set) var paths: [String] = []
    private let gate: BuildWorkspaceGate?
    private let firstFailure: String?
    init(gate: BuildWorkspaceGate? = nil, firstFailure: String? = nil) {
        self.gate = gate; self.firstFailure = firstFailure
    }
    func run(_ request: HostCommandRequest) async throws -> HostCommandResult {
        let index = try #require(request.arguments.firstIndex(of: "-derivedDataPath"))
        let path = request.arguments[index + 1]
        paths.append(path)
        let mode = paths.count == 1 ? firstFailure : nil
        if paths.count == 1 { await gate?.enter() }
        let products = URL(fileURLWithPath: path).appendingPathComponent("Build/Products")
        let fm = FileManager.default
        for name in ["DeviceBridgeRunnerUITests-Runner.app", "DeviceBridgeHost.app"] {
            let app = products.appendingPathComponent("Debug-iphoneos/" + name)
            try fm.createDirectory(at: app, withIntermediateDirectories: true)
            try Data(String(paths.count).utf8).write(to: app.appendingPathComponent("binary"))
            if mode == "symlink" {
                try fm.createSymbolicLink(at: app.appendingPathComponent("link"), withDestinationURL: app.appendingPathComponent("binary"))
            }
        }
        var host = products.path + "/Debug-iphoneos/DeviceBridgeHost.app"
        if mode == "external" { host = path + "/Build/Intermediates.noindex/file" }
        if mode == "alias" { host = products.resolvingSymlinksInPath().path + "/Debug-iphoneos/DeviceBridgeHost.app" }
        if mode == "escape" { host = products.path + "/../Intermediates.noindex/file" }
        var plist = ["TestHostPath": host,
            "SystemPath": "/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform"]
        if mode == "oversized" { plist["LargeValidString"] = String(repeating: "x", count: 1_048_577) }
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        if mode != "missing" { try data.write(to: products.appendingPathComponent("Runner.xctestrun")) }
        if mode == "multiple" { try data.write(to: products.appendingPathComponent("OldSDK.xctestrun")) }
        return HostCommandResult(exitCode: mode == "exit" ? 65 : 0, standardOutput: Data(), standardError: Data())
    }
}

private actor BuildWorkspaceGate {
    private var entered = false
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    func enter() async {
        entered = true
        if !released { await withCheckedContinuation { waiter = $0 } }
    }
    func waitForEntry() async {
        while !entered { try? await Task.sleep(for: .milliseconds(1)) }
    }
    func release() { released = true; waiter?.resume(); waiter = nil }
}
