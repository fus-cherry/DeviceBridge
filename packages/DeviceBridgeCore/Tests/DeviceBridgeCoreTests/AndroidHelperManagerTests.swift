import Foundation
import Testing
@testable import DeviceBridgeCore

@Suite("Android managed helper lifecycle")
struct AndroidHelperManagerTests {
    @Test("a new prepare cannot start while an old helper is being stopped")
    func cleanupExcludesNewPreparation() async throws {
        let runner = AndroidManagerRunner(installedVersion: 3, delayRelease: true)
        let manager = AndroidHelperManager(adbURL: URL(fileURLWithPath: "/adb"),
            apkURL: URL(fileURLWithPath: "/helper.apk"), expectedVersionCode: 3, runner: runner)
        #expect(await manager.prepare(transportID: "7").connection != nil)
        let stop = Task { await manager.stop() }
        for _ in 0..<100 {
            if await runner.requests.contains(where: { $0.arguments.contains("--remove") }) { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await manager.prepare(transportID: "7").connection == nil)
        await stop.value
        #expect(await runner.requests.filter { $0.arguments.contains("tcp:0") }.count == 1)
    }
    @Test("a covered helper times out and releases the candidate route")
    func coveredHelperTimeout() async {
        let runner = AndroidManagerRunner(installedVersion: 3, focused: false)
        let manager = AndroidHelperManager(adbURL: URL(fileURLWithPath: "/adb"),
            apkURL: URL(fileURLWithPath: "/helper.apk"), expectedVersionCode: 3, runner: runner,
            readinessTimeout: .milliseconds(250))
        let outcome = await manager.prepare(transportID: "7")
        #expect(outcome.connection == nil)
        #expect(outcome.failure?.code == .timeout)
        #expect(await runner.requests.filter { $0.arguments.contains("--remove") }.count == 1)
    }

    @Test("cancelling a readiness wait releases the forward despite task cancellation")
    func cancelledReadiness() async throws {
        let runner = AndroidManagerRunner(installedVersion: 3, readyAfter: .max)
        let manager = AndroidHelperManager(adbURL: URL(fileURLWithPath: "/adb"),
            apkURL: URL(fileURLWithPath: "/helper.apk"), expectedVersionCode: 3, runner: runner)
        let task = Task { await manager.prepare(transportID: "7") }
        for _ in 0..<100 {
            if await runner.socketProbes > 0 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await runner.socketProbes > 0)
        let concurrent = await manager.prepare(transportID: "8")
        #expect(concurrent.connection == nil)
        task.cancel()
        let result = await task.value
        #expect(result.failure?.code == .cancelled)
        #expect(await runner.requests.filter { $0.arguments.contains("--remove") }.count == 1)
    }
    @Test("prepare waits for a listening socket and focused helper before returning")
    func delayedReadiness() async {
        let runner = AndroidManagerRunner(installedVersion: 3, readyAfter: 3)
        let manager = AndroidHelperManager(adbURL: URL(fileURLWithPath: "/adb"),
            apkURL: URL(fileURLWithPath: "/helper.apk"), expectedVersionCode: 3, runner: runner)
        let outcome = await manager.prepare(transportID: "7")
        #expect(outcome.connection != nil)
        #expect(await runner.socketProbes >= 3)
        #expect(await runner.requests.contains { $0.arguments.suffix(2) == ["dumpsys", "window"] })
        await manager.stop()
    }

    @Test("stop during readiness invalidates preparation and cleans its exact forward")
    func stopDuringReadiness() async throws {
        let runner = AndroidManagerRunner(installedVersion: 3, readyAfter: .max)
        let manager = AndroidHelperManager(adbURL: URL(fileURLWithPath: "/adb"),
            apkURL: URL(fileURLWithPath: "/helper.apk"), expectedVersionCode: 3, runner: runner)
        let task = Task { await manager.prepare(transportID: "7") }
        for _ in 0..<100 {
            if await runner.socketProbes > 0 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        await manager.stop()
        let result = await task.value
        #expect(result.connection == nil)
        #expect(await runner.requests.filter { $0.arguments.contains("--remove") }.count == 1)
    }
    @Test("recovery attaches and detaches without resetting the authenticated helper")
    func recoveryLifecycle() async {
        let runner = AndroidManagerRunner(installedVersion: 3)
        let manager = AndroidHelperManager(adbURL: URL(fileURLWithPath: "/adb"),
            apkURL: URL(fileURLWithPath: "/bundle/helper.apk"), expectedVersionCode: 3, runner: runner)
        let outcome = await manager.reattach(transportID: "22")
        #expect(outcome.connection?.hostPort == 43123)
        await manager.detach()
        await manager.detach()
        #expect(await runner.requests.map(\.arguments) == [
            ["-t", "22", "forward", "tcp:0", "localabstract:device_bridge_helper"],
            ["-t", "22", "forward", "--remove", "tcp:43123"],
        ])
    }

    @Test("current helper is forwarded and started without reinstalling")
    func currentHelper() async throws {
        let runner = AndroidManagerRunner(installedVersion: 3)
        let manager = AndroidHelperManager(
            adbURL: URL(fileURLWithPath: "/sdk/adb"),
            apkURL: URL(fileURLWithPath: "/bundle/helper.apk"),
            expectedVersionCode: 3,
            runner: runner
        )

        let outcome = await manager.prepare(transportID: "7")
        let requests = await runner.requests

        #expect(outcome.connection?.hostPort == 43123)
        #expect(!requests.contains { $0.arguments.contains("install") })
        #expect(requests.contains { $0.arguments == [
            "-t", "7", "forward", "tcp:0", "localabstract:device_bridge_helper",
        ] })
        #expect(requests.contains { $0.arguments == [
            "-t", "7", "shell", "am", "start", "-n",
            "dev.debugutility.helper/.MainActivity",
        ] })
        let resetIndex = requests.firstIndex { $0.arguments == [
            "-t", "7", "shell", "am", "force-stop", "dev.debugutility.helper",
        ] }
        let startIndex = requests.firstIndex { $0.arguments == [
            "-t", "7", "shell", "am", "start", "-n",
            "dev.debugutility.helper/.MainActivity",
        ] }
        if let resetIndex, let startIndex {
            #expect(resetIndex < startIndex)
        } else {
            Issue.record("Expected helper reset and start commands")
        }
    }

    @Test("old helper is updated and version is verified")
    func helperUpdate() async {
        let runner = AndroidManagerRunner(installedVersion: 1)
        let manager = AndroidHelperManager(
            adbURL: URL(fileURLWithPath: "/adb"),
            apkURL: URL(fileURLWithPath: "/bundle/helper.apk"),
            expectedVersionCode: 3,
            runner: runner
        )

        let outcome = await manager.prepare(transportID: "8")
        let requests = await runner.requests

        #expect(outcome.connection != nil)
        #expect(requests.contains { $0.arguments == [
            "-t", "8", "install", "-r", "/bundle/helper.apk",
        ] })
        #expect(await runner.installedVersion == 3)
    }

    @Test("failed install returns an actionable helper outcome")
    func installFailure() async {
        let runner = AndroidManagerRunner(installedVersion: nil, failInstall: true)
        let manager = AndroidHelperManager(
            adbURL: URL(fileURLWithPath: "/adb"),
            apkURL: URL(fileURLWithPath: "/bundle/helper.apk"),
            expectedVersionCode: 3,
            runner: runner
        )

        let outcome = await manager.prepare(transportID: "9")

        #expect(outcome.failure?.code == .helperMissing)
        #expect(outcome.failure?.recoveryAction != nil)
    }

    @Test("stop removes the exact forward and force-stops the helper")
    func stopLifecycle() async {
        let runner = AndroidManagerRunner(installedVersion: 3)
        let manager = AndroidHelperManager(
            adbURL: URL(fileURLWithPath: "/adb"),
            apkURL: URL(fileURLWithPath: "/bundle/helper.apk"),
            expectedVersionCode: 3,
            runner: runner
        )
        _ = await manager.prepare(transportID: "10")

        await manager.stop()
        await manager.stop()
        let requests = await runner.requests

        #expect(requests.filter { $0.arguments == [
            "-t", "10", "forward", "--remove", "tcp:43123",
        ] }.count == 1)
        #expect(requests.filter { $0.arguments == [
            "-t", "10", "shell", "am", "force-stop", "dev.debugutility.helper",
        ] }.count == 2)
    }
}

private actor AndroidManagerRunner: HostCommandRunning {
    private(set) var requests: [HostCommandRequest] = []
    private(set) var installedVersion: Int?
    private let failInstall: Bool
    private let readyAfter: Int
    private let focused: Bool
    private let delayRelease: Bool
    private(set) var socketProbes = 0

    init(installedVersion: Int?, failInstall: Bool = false, readyAfter: Int = 1, focused: Bool = true, delayRelease: Bool = false) {
        self.installedVersion = installedVersion
        self.failInstall = failInstall
        self.readyAfter = readyAfter
        self.focused = focused
        self.delayRelease = delayRelease
    }

    func run(_ request: HostCommandRequest) async throws -> HostCommandResult {
        try Task.checkCancellation()
        requests.append(request)
        let arguments = request.arguments
        if arguments.contains("--remove"), delayRelease {
            try await Task.sleep(for: .milliseconds(250))
        }
        if arguments.contains("/proc/net/unix") {
            socketProbes += 1
            let output = socketProbes >= readyAfter ? "000: 2 0 00010000 0001 01 99 @device_bridge_helper\n" : ""
            return HostCommandResult(exitCode: 0, standardOutput: Data(output.utf8), standardError: Data())
        }
        if arguments.suffix(2) == ["dumpsys", "window"] {
            let name = focused ? "dev.debugutility.helper" : "com.android.permissioncontroller"
            return HostCommandResult(exitCode: 0,
                standardOutput: Data("mCurrentFocus=Window{abc u0 \(name)/.MainActivity}\n".utf8), standardError: Data())
        }
        if arguments.contains("dumpsys") {
            let output = installedVersion.map { "versionCode=\($0) minSdk=30\n" } ?? ""
            return HostCommandResult(exitCode: 0, standardOutput: Data(output.utf8), standardError: Data())
        }
        if arguments.contains("install") {
            if failInstall {
                return HostCommandResult(exitCode: 1, standardOutput: Data(), standardError: Data("install failed".utf8))
            }
            installedVersion = 3
            return HostCommandResult(exitCode: 0, standardOutput: Data("Success\n".utf8), standardError: Data())
        }
        if arguments.contains("tcp:0") {
            return HostCommandResult(exitCode: 0, standardOutput: Data("43123\n".utf8), standardError: Data())
        }
        return HostCommandResult(exitCode: 0, standardOutput: Data(), standardError: Data())
    }
}
