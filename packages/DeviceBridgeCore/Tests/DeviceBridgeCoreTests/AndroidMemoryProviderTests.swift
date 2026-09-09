import Foundation
import Testing
@testable import DeviceBridgeCore

@Suite("Android process and meminfo provider")
struct AndroidMemoryProviderTests {
    @Test("advancing elapsed time does not restart a process with stable kernel start ticks")
    func ignoresElapsedTime() async throws {
        let runner = AndroidMemoryCommandRunner(pid: 100, startIdentity: "5224")
        let provider = AndroidMemoryProvider(adbURL: URL(fileURLWithPath: "/adb"), runner: runner)
        let device = try DeviceIdentity(rawValue: "android", stability: .stable, platform: .android)
        let apps = await provider.discover(deviceIdentity: device, transportID: "8")
        let target = try #require(apps.first)
        #expect(target.processStartIdentity == "5224")
        #expect(await provider.sample(target: target, transportID: "8").sample != nil)
        #expect(await provider.sample(target: target, transportID: "8").sample != nil)
    }

    @Test("same PID with different kernel start ticks is a restart")
    func detectsPIDReuse() async throws {
        let runner = AndroidMemoryCommandRunner(pid: 100, startIdentity: "6000")
        let provider = AndroidMemoryProvider(adbURL: URL(fileURLWithPath: "/adb"), runner: runner)
        let target = TargetApplication(
            deviceIdentity: try DeviceIdentity(rawValue: "android", stability: .stable, platform: .android),
            applicationID: "dev.example.app", displayName: "Example", processID: 100,
            processStartIdentity: "5224", debuggable: nil, state: .running)
        let outcome = await provider.sample(target: target, transportID: "8")
        #expect(outcome.restartedTarget?.processStartIdentity == "6000")
        #expect(!(await runner.requests.contains { $0.arguments.contains("dumpsys") }))
    }
    @Test("modern meminfo parses PSS and RSS as bytes")
    func parsesModernMeminfo() throws {
        let output = """
        ** MEMINFO in pid 123 [dev.example.app] **
        App Summary
        TOTAL PSS:   12,345   TOTAL RSS:   23,456   TOTAL SWAP PSS: 42
        """

        let metrics = try AndroidMemoryParser.parseMeminfo(output)

        #expect(metrics.pssBytes == Int64(12_345 * 1_024))
        #expect(metrics.rssBytes == Int64(23_456 * 1_024))
    }

    @Test("missing RSS remains unavailable and malformed output fails")
    func missingAndMalformedFields() throws {
        let pssOnly = try AndroidMemoryParser.parseMeminfo("TOTAL PSS: 321\n")
        #expect(pssOnly.pssBytes == Int64(321 * 1_024))
        #expect(pssOnly.rssBytes == nil)
        #expect(throws: AndroidMemoryProviderError.malformedMeminfo) {
            try AndroidMemoryParser.parseMeminfo("No memory totals here")
        }
    }

    @Test("process discovery keeps app-like processes but never treats elapsed time as identity")
    func discoversProcesses() throws {
        let output = """
          100 dev.example.one 00:17
          101 dev.example.one:worker 00:12
          202 system_server 03:00
          303 dev.example.two 01:05
        """

        let apps = try AndroidMemoryParser.parseProcesses(output)

        #expect(apps.map(\.applicationID) == ["dev.example.one", "dev.example.two"])
        #expect(apps.map(\.processID) == [100, 303])
        #expect(apps.allSatisfy { $0.processStartIdentity == nil })
    }

    @Test("stat parser ignores malformed, truncated and nonnumeric identities")
    func malformedStartTicks() {
        #expect(AndroidMemoryParser.parseStartTicks("100 (truncated) S 0 0\nnot a stat line").isEmpty)
        let prefix = "100 (a name (nested)) S " + Array(repeating: "0", count: 18).joined(separator: " ")
        #expect(AndroidMemoryParser.parseStartTicks(prefix + " nope").isEmpty)
        #expect(AndroidMemoryParser.parseStartTicks(prefix + " 5224")[100] == "5224")
    }

    @Test("PID change returns restarted before publishing memory")
    func detectsRestart() async throws {
        let runner = AndroidMemoryCommandRunner(pid: 101, startIdentity: "6000")
        let provider = AndroidMemoryProvider(
            adbURL: URL(fileURLWithPath: "/adb"),
            runner: runner
        )
        let target = TargetApplication(
            deviceIdentity: try DeviceIdentity(rawValue: "android", stability: .stable, platform: .android),
            applicationID: "dev.example.app",
            displayName: "dev.example.app",
            processID: 100,
            processStartIdentity: "00:20",
            debuggable: nil,
            state: .running
        )

        let outcome = await provider.sample(target: target, transportID: "8")

        #expect(outcome.restartedTarget?.processID == 101)
        #expect(outcome.sample == nil)
        #expect(!(await runner.requests.contains { $0.arguments.contains("dumpsys") }))
    }

    @Test("stable PID publishes source-labelled memory and timestamp")
    func samplesStableProcess() async throws {
        let runner = AndroidMemoryCommandRunner(
            pid: 100,
            startIdentity: "5224",
            meminfo: "TOTAL PSS: 10 TOTAL RSS: 20\n"
        )
        let provider = AndroidMemoryProvider(
            adbURL: URL(fileURLWithPath: "/adb"),
            runner: runner
        )
        let device = try DeviceIdentity(rawValue: "android", stability: .stable, platform: .android)
        let target = TargetApplication(
            deviceIdentity: device,
            applicationID: "dev.example.app",
            displayName: "dev.example.app",
            processID: 100,
            processStartIdentity: "5224",
            debuggable: nil,
            state: .running
        )

        let outcome = await provider.sample(target: target, transportID: "8")

        #expect(outcome.sample?.source == .androidMeminfo)
        #expect(outcome.sample?.deviceIdentity == device)
        #expect(outcome.sample?.pssBytes == Int64(10 * 1_024))
        #expect(outcome.sample?.rssBytes == Int64(20 * 1_024))
    }
}

private actor AndroidMemoryCommandRunner: HostCommandRunning {
    private(set) var requests: [HostCommandRequest] = []
    let pid: Int
    let startIdentity: String
    let meminfo: String

    init(pid: Int, startIdentity: String, meminfo: String = "TOTAL PSS: 1 TOTAL RSS: 2\n") {
        self.pid = pid
        self.startIdentity = startIdentity
        self.meminfo = meminfo
    }

    func run(_ request: HostCommandRequest) async throws -> HostCommandResult {
        requests.append(request)
        let output: String
        if request.arguments.contains("pidof") { output = "\(pid)\n" }
        else if request.arguments.contains("ps") { output = "\(pid) dev.example.app 00:\(requests.count)\n" }
        else if request.arguments.joined(separator: " ").contains("/stat") {
            output = "\(pid) (app name (worker)) S " + Array(repeating: "0", count: 18).joined(separator: " ") + " \(startIdentity) 0 0\n"
        }
        else if request.arguments.contains("dumpsys") { output = meminfo }
        else { output = "" }
        return HostCommandResult(exitCode: 0, standardOutput: Data(output.utf8), standardError: Data())
    }
}
