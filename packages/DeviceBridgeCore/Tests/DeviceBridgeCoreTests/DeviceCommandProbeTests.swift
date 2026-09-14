import Darwin
import Foundation
import Testing
@testable import DeviceBridgeCore

@Suite("Target-specific device command probe")
struct DeviceCommandProbeTests {
    @Test("Android readiness requires a targeted get-state command")
    func androidReadiness() async throws {
        let runner = ProbeRecordingRunner { _ in
            HostCommandResult(exitCode: 0, standardOutput: Data("device\n".utf8), standardError: Data())
        }
        let probe = DeviceCommandProbe(
            adbURL: URL(fileURLWithPath: "/sdk/adb"),
            xcrunURL: nil,
            runner: runner
        )

        let outcome = await probe.probe(try device(platform: .android, transportID: "7"))
        let request = await runner.requests.first

        #expect(outcome.isReady)
        #expect(request?.executableURL.path == "/sdk/adb")
        #expect(request?.arguments == ["-t", "7", "get-state"])
    }

    @Test("iOS readiness uses a bounded target-specific devicectl command")
    func iosReadiness() async throws {
        let runner = ProbeRecordingRunner { _ in
            HostCommandResult(exitCode: 0, standardOutput: Data(), standardError: Data())
        }
        let probe = DeviceCommandProbe(
            adbURL: nil,
            xcrunURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
            runner: runner
        )

        let outcome = await probe.probe(try device(platform: .iOS, transportID: "core-42"))
        let request = await runner.requests.first

        #expect(outcome.isReady)
        #expect(request?.arguments == [
            "devicectl", "device", "info", "details",
            "--device", "core-42", "--quiet", "--timeout", "5",
        ])
    }

    @Test("nonzero and malformed probe results never become ready")
    func failuresStayUnavailable() async throws {
        let nonzeroRunner = ProbeRecordingRunner { _ in
            HostCommandResult(exitCode: 1, standardOutput: Data(), standardError: Data("offline".utf8))
        }
        let malformedRunner = ProbeRecordingRunner { _ in
            HostCommandResult(exitCode: 0, standardOutput: Data("unknown".utf8), standardError: Data())
        }

        let nonzero = await DeviceCommandProbe(
            adbURL: URL(fileURLWithPath: "/adb"),
            xcrunURL: nil,
            runner: nonzeroRunner
        ).probe(try device(platform: .android, transportID: "8"))
        let malformed = await DeviceCommandProbe(
            adbURL: URL(fileURLWithPath: "/adb"),
            xcrunURL: nil,
            runner: malformedRunner
        ).probe(try device(platform: .android, transportID: "9"))

        #expect(nonzero.failure?.code == .disconnected)
        #expect(malformed.failure?.code == .malformedOutput)
    }

    @Test("command cancellation is preserved")
    func cancellation() async throws {
        let runner = ProbeRecordingRunner { _ in throw HostCommandError.cancelled }
        let outcome = await DeviceCommandProbe(
            adbURL: URL(fileURLWithPath: "/adb"),
            xcrunURL: nil,
            runner: runner
        ).probe(try device(platform: .android, transportID: "10"))

        #expect(outcome.failure?.code == .cancelled)
    }

    @Test("devicectl's own timeout is not reported as missing trust")
    func iosToolTimeout() async throws {
        let runner = ProbeRecordingRunner { _ in
            HostCommandResult(exitCode: 2, standardOutput: Data(), standardError:
                Data("ERROR: Command timeout of 5.0 seconds exceeded. Assuming command got stuck and aborting.".utf8))
        }
        let outcome = await DeviceCommandProbe(adbURL: nil,
            xcrunURL: URL(fileURLWithPath: "/usr/bin/xcrun"), runner: runner)
            .probe(try device(platform: .iOS, transportID: "core-timeout"))
        #expect(outcome.failure?.code == .timeout)
        #expect(outcome.failure?.recoveryAction?.contains("Repair connection") == true)
        #expect(await runner.requests.count == 1) // No automatic service restart.
    }

    @Test("host timeout offers the same iOS recovery without changing Android failures")
    func iosHostTimeout() async throws {
        let runner = ProbeRecordingRunner { _ in throw HostCommandError.timedOut }
        let outcome = await DeviceCommandProbe(adbURL: nil,
            xcrunURL: URL(fileURLWithPath: "/usr/bin/xcrun"), runner: runner)
            .probe(try device(platform: .iOS, transportID: "core-timeout"))
        #expect(outcome.failure?.code == .timeout)
        #expect(outcome.failure?.recoveryAction?.contains("Repair connection") == true)
    }

    @Test("explicit service recovery targets only the current user's exact service", arguments: [Int32(0), 1, 2])
    func serviceRecovery(exitCode: Int32) async throws {
        let runner = ProbeRecordingRunner { _ in
            HostCommandResult(exitCode: exitCode, standardOutput: Data(), standardError: Data())
        }
        do {
            try await IOSDeviceServiceRecovery(runner: runner).restart()
            #expect(exitCode == 0 || exitCode == 1)
        } catch {
            #expect(exitCode == 2)
        }
        let requests = await runner.requests
        #expect(requests.count == 1)
        #expect(requests.first?.executableURL.path == "/usr/bin/pkill")
        #expect(requests.first?.arguments == ["-KILL", "-u", String(geteuid()), "-x", "CoreDeviceService"])
    }

    private func device(platform: DevicePlatform, transportID: String) throws -> DeviceRecord {
        let identity = try DeviceIdentity(
            rawValue: "identity-\(platform.rawValue)",
            stability: .stable,
            platform: platform
        )
        let candidate = try TransportCandidate(
            id: transportID,
            identity: identity,
            kind: .usb,
            source: platform == .android ? .adb : .coreDevice,
            status: .candidate,
            observedAt: Date(timeIntervalSince1970: 1)
        )
        return DeviceRecord(
            identity: identity,
            name: "Fixture",
            authorization: .authorized,
            candidates: [candidate],
            preferredTransportID: transportID
        )
    }
}

private actor ProbeRecordingRunner: HostCommandRunning {
    private(set) var requests: [HostCommandRequest] = []
    private let handler: @Sendable (HostCommandRequest) throws -> HostCommandResult

    init(handler: @escaping @Sendable (HostCommandRequest) throws -> HostCommandResult) {
        self.handler = handler
    }

    func run(_ request: HostCommandRequest) async throws -> HostCommandResult {
        requests.append(request)
        return try handler(request)
    }
}
