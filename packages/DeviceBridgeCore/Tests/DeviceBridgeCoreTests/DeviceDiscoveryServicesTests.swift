import Foundation
import Testing
@testable import DeviceBridgeCore

@Suite("Device discovery services")
struct DeviceDiscoveryServicesTests {
    @Test("Android discovery verifies identity without starting a mobile app")
    func androidDiscovery() async throws {
        let runner = RecordingCommandRunner { request in
            if request.arguments.last == "ro.serialno" {
                return HostCommandResult(exitCode: 0, standardOutput: Data("PHONE-123\n".utf8), standardError: Data())
            }
            return HostCommandResult(
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
        #expect(requests.count == 2)
        #expect(devices[0].identity.stability == .stable)
        #expect(devices[0].metadata["hardwareSerial"] == "PHONE-123")
        #expect(requests[1].arguments == ["-t", "7", "shell", "getprop", "ro.serialno"])
        #expect(requests[0].executableURL.path == "/sdk/platform-tools/adb")
        #expect(requests[0].arguments == ["devices", "-l"])
    }

    @Test("USB and wireless routes merge only after hardware identity agrees")
    func mergesVerifiedRoutes() async throws {
        let runner = RecordingCommandRunner { request in
            let output = request.arguments == ["devices", "-l"] ? """
            USB-SERIAL device usb:1-1 model:Phone transport_id:1
            adb-phone (3)._adb-tls-connect._tcp device model:Phone transport_id:2
            192.168.1.2:5555 device model:Phone transport_id:3
            192.168.1.3:5555 device model:Phone transport_id:4
            """ : (request.arguments[1] == "4" ? "unknown\n" : "PHONE-123\n")
            return HostCommandResult(exitCode: 0, standardOutput: Data(output.utf8), standardError: Data())
        }
        let candidates = try await AndroidDeviceDiscoveryService(adbURL: URL(fileURLWithPath: "/adb"), runner: runner).discover(observedAt: Date())
        let devices = DeviceInventory.aggregate(candidates)
        #expect(devices.count == 2)
        let merged = try #require(devices.first { $0.identity.stability == .stable })
        #expect(merged.candidates.count == 3)
        #expect(merged.preferredTransportID == "1")
    }

    @Test("a serial-less emulator merges aliases only for the verified kernel boot")
    func emulatorIdentity() async throws {
        let boot = "824e061b-c117-4b3f-a40c-39a91c8e34e2"
        let runner = RecordingCommandRunner { request in
            let output: String
            if request.arguments == ["devices", "-l"] {
                output = "127.0.0.1:16384 device transport_id:1\nlocalhost:16384 device transport_id:2\n"
            } else if request.arguments.last == "ro.serialno" { output = "\n" }
            else { output = boot + "\n" }
            return HostCommandResult(exitCode: 0, standardOutput: Data(output.utf8), standardError: Data())
        }
        let candidates = try await AndroidDeviceDiscoveryService(adbURL: URL(fileURLWithPath: "/adb"), runner: runner).discover(observedAt: Date())
        let records = DeviceInventory.aggregate(candidates)
        #expect(records.count == 1)
        #expect(records[0].identity.rawValue == "android:boot:\(boot)")
        #expect(records[0].identity.stability == .provisional)
        #expect(records[0].candidates.count == 2)
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
