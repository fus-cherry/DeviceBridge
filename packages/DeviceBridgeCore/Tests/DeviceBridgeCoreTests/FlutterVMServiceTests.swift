import DeviceBridgeProtocol
import Foundation
import Testing
@testable import DeviceBridgeCore

@Suite("Flutter VM Service client")
struct FlutterVMServiceTests {
    @Test("unverified host or second-phone VM cannot be attributed to iOS even with matching process metadata",
          arguments: [nil, 123, 456] as [Int?])
    func rejectsUnverifiedIOSAttribution(pid: Int?) async throws {
        let transport = VMTransportDouble(responses: [
            "getVM": ["pid": .number(123), "startTime": .number(1_800_000_000_000),
                      "isolates": .array([.object(["id": .string("isolates/1")])])],
            "getMemoryUsage": ["heapUsage": .number(20_000_000)],
        ])
        let service = try FlutterVMService(
            uri: URL(string: "http://127.0.0.1:54321/synthetic-token=/")!, transport: transport)
        let target = TargetApplication(
            deviceIdentity: try DeviceIdentity(rawValue: "selected-phone", stability: .stable, platform: .iOS),
            applicationID: pid == nil ? "flutter.vm" : "dev.example.flutter",
            displayName: "Test app", processID: pid,
            processStartIdentity: pid == nil ? nil : "1800000000000", debuggable: true, state: .running)

        let outcome = await service.sample(target: target, transportID: "selected-phone-route")

        #expect(outcome.sample == nil)
        #expect(outcome.restartedTarget == nil)
        #expect(outcome.failure?.code == .unsupported)
        #expect(await transport.methods.isEmpty)
        await service.disconnect()
    }

    @Test("discovery accepts only loopback VM Service URIs and diagnostics remain redacted")
    func discoveryAndRedaction() throws {
        let text = "The Dart VM service is listening on http://127.0.0.1:54321/secret-token=/"
        let uri = try #require(FlutterVMServiceDiscovery.candidateURI(in: text))

        #expect(uri.absoluteString == "http://127.0.0.1:54321/secret-token=/")
        #expect(FlutterVMServiceDiscovery.candidateURI(
            in: "http://example.com:54321/secret/"
        ) == nil)
        #expect(Redactor().redact("vm=\(uri.absoluteString)") == "vm=<redacted-vm-uri>")
    }

    @Test("getVM and getMemoryUsage publish source-specific fields")
    func samplesMemory() async throws {
        let transport = VMTransportDouble(responses: [
            "getVM": [
                "pid": .number(123),
                "startTime": .number(1_800_000_000_000),
                "_currentRSS": .number(50_000_000),
                "isolates": .array([.object(["id": .string("isolates/1")])]),
            ],
            "getMemoryUsage": [
                "heapUsage": .number(20_000_000),
                "externalUsage": .number(3_000_000),
            ],
        ])
        let service = try FlutterVMService(
            uri: URL(string: "http://127.0.0.1:54321/token=/")!,
            transport: transport
        )
        let target = try makeTarget(pid: 123, start: "1800000000000")

        let outcome = await service.sample(target: target, transportID: "unused")
        let methods = await transport.methods

        #expect(outcome.sample?.source == .flutterVMService)
        #expect(outcome.sample?.heapUsedBytes == 20_000_000)
        #expect(outcome.sample?.externalBytes == 3_000_000)
        #expect(outcome.sample?.rssBytes == 50_000_000)
        #expect(methods == ["getVM", "getMemoryUsage"])
    }

    @Test("PID or VM start identity change is reported as restarted")
    func restartDetection() async throws {
        let transport = VMTransportDouble(responses: [
            "getVM": [
                "pid": .number(456),
                "startTime": .number(1_800_000_001_000),
                "isolates": .array([.object(["id": .string("isolates/2")])]),
            ],
        ])
        let service = try FlutterVMService(
            uri: URL(string: "ws://localhost:1234/token=/ws")!,
            transport: transport
        )

        let outcome = await service.sample(
            target: try makeTarget(pid: 123, start: "1800000000000"),
            transportID: "unused"
        )

        #expect(outcome.restartedTarget?.processID == 456)
        #expect(outcome.sample == nil)
    }

    @Test("GC is explicit and disconnect prevents later RPC success")
    func gcAndDisconnect() async throws {
        let transport = VMTransportDouble(responses: [
            "getAllocationProfile": ["type": .string("AllocationProfile")],
        ])
        let service = try FlutterVMService(
            uri: URL(string: "http://127.0.0.1:1234/token=/")!,
            transport: transport
        )

        #expect(await service.collectGarbage(isolateID: "isolates/1"))
        #expect(await transport.lastParameters?["gc"]?.boolValue == true)
        await service.disconnect()
        let outcome = await service.sample(
            target: try makeTarget(pid: 1, start: nil),
            transportID: "unused"
        )

        #expect(outcome.failure?.code == .disconnected)
        #expect(await transport.closed)
    }

    @Test("Android discovery reads recent logs, forwards the device port, and removes the exact forward")
    func androidDiscoveryLifecycle() async throws {
        let runner = VMDiscoveryCommandRunner()
        let discovery = AndroidFlutterVMDiscovery(
            adbURL: URL(fileURLWithPath: "/adb"),
            runner: runner
        )

        let outcome = await discovery.discover(transportID: "12")
        let uri = try #require(outcome.uri)
        #expect(uri.absoluteString == "http://127.0.0.1:55123/auth-token=/")
        await discovery.stop()
        await discovery.stop()
        let requests = await runner.requests

        #expect(requests.contains { $0.arguments == [
            "-t", "12", "shell", "logcat", "-d", "-v", "raw", "-t", "500",
        ] })
        #expect(requests.contains { $0.arguments == [
            "-t", "12", "forward", "tcp:0", "tcp:43210",
        ] })
        #expect(requests.filter { $0.arguments == [
            "-t", "12", "forward", "--remove", "tcp:55123",
        ] }.count == 1)
    }

    private func makeTarget(pid: Int, start: String?) throws -> TargetApplication {
        TargetApplication(
            deviceIdentity: try DeviceIdentity(rawValue: "device", stability: .stable, platform: .android),
            applicationID: "dev.example.flutter",
            displayName: "Flutter App",
            processID: pid,
            processStartIdentity: start,
            debuggable: true,
            state: .running
        )
    }
}

private actor VMDiscoveryCommandRunner: HostCommandRunning {
    private(set) var requests: [HostCommandRequest] = []

    func run(_ request: HostCommandRequest) async throws -> HostCommandResult {
        requests.append(request)
        if request.arguments.contains("logcat") {
            let output = "The Dart VM service is listening on http://127.0.0.1:43210/auth-token=/\n"
            return HostCommandResult(exitCode: 0, standardOutput: Data(output.utf8), standardError: Data())
        }
        if request.arguments.contains("tcp:0") {
            return HostCommandResult(exitCode: 0, standardOutput: Data("55123\n".utf8), standardError: Data())
        }
        return HostCommandResult(exitCode: 0, standardOutput: Data(), standardError: Data())
    }
}

private actor VMTransportDouble: VMServiceRPCTransport {
    private let responses: [String: [String: JSONValue]]
    private(set) var methods: [String] = []
    private(set) var lastParameters: [String: JSONValue]?
    private(set) var closed = false

    init(responses: [String: [String: JSONValue]]) { self.responses = responses }

    func request(
        method: String,
        parameters: [String: JSONValue]
    ) async throws -> [String: JSONValue] {
        guard !closed else { throw FlutterVMServiceError.disconnected }
        methods.append(method)
        lastParameters = parameters
        guard let response = responses[method] else {
            throw FlutterVMServiceError.malformedResponse
        }
        return response
    }

    func close() async { closed = true }
}
