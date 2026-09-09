import Foundation
import Testing
@testable import DeviceBridgeCore

@Suite("Device discovery services")
struct DeviceDiscoveryServicesTests {
    @Test("Android discovery invokes ADB inventory without a shell")
    func androidDiscovery() async throws {
        let runner = RecordingCommandRunner { _ in
            HostCommandResult(
                exitCode: 0,
                standardOutput: Data("List of devices attached\nserial device usb:1-1 model:Pixel_9 transport_id:7\n".utf8),
                standardError: Data()
            )
        }
        let service = AndroidDeviceDiscoveryService(
            adbURL: URL(fileURLWithPath: "/sdk/platform-tools/adb"),
            runner: runner
        )

        let devices = try await service.discover(observedAt: Date(timeIntervalSince1970: 1))
        let requests = await runner.requests

        #expect(devices.map(\.id) == ["7"])
        #expect(requests.count == 1)
        #expect(requests[0].executableURL.path == "/sdk/platform-tools/adb")
        #expect(requests[0].arguments == ["devices", "-l"])
    }

    @Test("iOS discovery consumes only the devicectl JSON result file")
    func iosDiscoveryUsesJSONFile() async throws {
        let fixture = Data("""
        {"result":{"devices":[{"identifier":"core-1","hardwareProperties":{"udid":"UDID-1","platform":"iOS"},"connectionProperties":{"transportType":"wired","pairingState":"paired"},"deviceProperties":{"name":"iPhone","developerModeStatus":"enabled"}}]}}
        """.utf8)
        let runner = RecordingCommandRunner { request in
            let outputIndex = request.arguments.firstIndex(of: "--json-output")!
            let outputURL = URL(fileURLWithPath: request.arguments[outputIndex + 1])
            try fixture.write(to: outputURL)
            return HostCommandResult(exitCode: 0, standardOutput: Data("human text ignored".utf8), standardError: Data())
        }
        let service = IOSDeviceDiscoveryService(
            xcrunURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
            runner: runner
        )

        let devices = try await service.discover(observedAt: Date(timeIntervalSince1970: 1))
        let request = await runner.requests.first

        #expect(devices.map(\.id) == ["core-1"])
        #expect(request?.arguments.prefix(3) == ["devicectl", "list", "devices"])
        #expect(request?.arguments.contains("--json-output") == true)
    }

    @Test("nonzero discovery exit is not parsed as success")
    func nonzeroExitFails() async {
        let runner = RecordingCommandRunner { _ in
            HostCommandResult(exitCode: 1, standardOutput: Data(), standardError: Data("offline".utf8))
        }
        let service = AndroidDeviceDiscoveryService(
            adbURL: URL(fileURLWithPath: "/adb"),
            runner: runner
        )

        do {
            _ = try await service.discover(observedAt: Date())
            Issue.record("Expected discovery failure")
        } catch let error as DeviceDiscoveryError {
            #expect(error == .commandFailed(exitCode: 1))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}

private actor RecordingCommandRunner: HostCommandRunning {
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
