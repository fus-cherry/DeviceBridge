import DeviceBridgeProtocol
import Foundation
import Testing
@testable import DeviceBridgeCore

@Suite("Android recovery command boundary")
struct AndroidConnectionTransportTests {
    @Test("hardware-bound recovery verifies the other route without starting a helper")
    func hardwareRecovery() async throws {
        let runner = RecoveryCommandFixture()
        let identity = try DeviceIdentity(rawValue: "android:hardware:PHONE-123", stability: .stable, platform: .android)
        let selected = try TransportCandidate(id: "11", identity: identity, kind: .usb, source: .adb,
            status: .candidate, observedAt: Date(), metadata: ["hardwareSerial": "PHONE-123"])
        let transport = AndroidConnectionTransport(adbURL: URL(fileURLWithPath: "/adb"), runner: runner,
            context: nil, selectedCandidate: selected)
        #expect(try await transport.verifyIdentity(candidate()))
        #expect(await runner.requests.map(\.arguments) == [["-t", "11", "shell", "getprop", "ro.serialno"]])
    }
    @Test("recovery preserves spaces in the selected mDNS instance name")
    func spacedServiceName() async throws {
        let runner = RecoveryCommandFixture()
        await runner.setMDNS("""
        adb-phone (3) _adb-tls-connect._tcp. 192.168.1.2:41000
        adb-phone (4) _adb-tls-connect._tcp. 192.168.1.3:42000
        """)
        let candidate = try candidate(serial: "adb-phone (3)._adb-tls-connect._tcp")
        let transport = AndroidConnectionTransport(adbURL: URL(fileURLWithPath: "/adb"), runner: runner,
            context: nil, selectedCandidate: candidate)
        #expect(try await transport.recoveryEndpoints(for: candidate) == ["192.168.1.2:40000", "192.168.1.2:41000"])
    }
    @Test("failed mDNS lookup retains the known endpoint")
    func mdnsFailureFallback() async throws {
        let runner = RecoveryCommandFixture()
        await runner.failMDNS()
        let candidate = try candidate()
        let transport = AndroidConnectionTransport(adbURL: URL(fileURLWithPath: "/adb"), runner: runner,
            context: nil, selectedCandidate: candidate)
        #expect(try await transport.recoveryEndpoints(for: candidate) == ["192.168.1.2:40000"])
        try await transport.connect(endpoint: "192.168.1.2:40000")
    }

    @Test("mDNS uses only the selected service and validates local address endpoints")
    func endpoints() async throws {
        let runner = RecoveryCommandFixture()
        await runner.setMDNS("""
        List of discovered mdns services
        selected _adb-tls-connect._tcp. 192.168.1.2:41000
        other _adb-tls-connect._tcp. 192.168.1.3:42000
        selected _adb-tls-pairing._tcp. 192.168.1.2:43000
        """)
        let candidate = try candidate(serial: "selected._adb-tls-connect._tcp")
        let transport = AndroidConnectionTransport(adbURL: URL(fileURLWithPath: "/adb"), runner: runner,
            context: nil, selectedCandidate: candidate)
        #expect(try await transport.recoveryEndpoints(for: candidate) == ["192.168.1.2:40000", "192.168.1.2:41000"])
        for bad in ["-H", "8.8.8.8:5555", "host.example:5555", "192.168.1.2:0", "192.168.1.2:65536", "192.168.1.2:5555;id"] {
            do { try await transport.connect(endpoint: bad); Issue.record("Invalid endpoint accepted") } catch {}
        }
        try await transport.connect(endpoint: "192.168.1.2:41000")
        #expect(await runner.requests.last?.arguments == ["connect", "192.168.1.2:41000"])
    }

    @Test("identity verification reads metadata only and removes its exact forward")
    func identity() async throws {
        let runner = RecoveryCommandFixture()
        let channel = RecoveryIdentityFixture()
        let context = HelperSessionContext(sessionNonce: "secret", helperDeviceID: "trusted-helper", helperVersion: "0.2.0")
        let candidate = try candidate()
        let transport = AndroidConnectionTransport(adbURL: URL(fileURLWithPath: "/adb"), runner: runner,
            context: context, selectedCandidate: candidate, channelFactory: { _ in channel })
        #expect(try await transport.verifyIdentity(candidate))
        #expect(await channel.actions == [.identity])
        #expect(await runner.requests.map(\.arguments) == [
            ["-t", "11", "get-state"],
            ["-t", "11", "forward", "tcp:0", "localabstract:device_bridge_helper"],
            ["-t", "11", "forward", "--remove", "tcp:12345"],
        ])
    }

    @Test("mismatched helper and malformed replies never authorize a candidate")
    func rejectsMismatch() async throws {
        let runner = RecoveryCommandFixture()
        let context = HelperSessionContext(sessionNonce: "secret", helperDeviceID: "trusted-helper", helperVersion: "0.2.0")
        let candidate = try candidate()
        let transport = AndroidConnectionTransport(adbURL: URL(fileURLWithPath: "/adb"), runner: runner,
            context: context, selectedCandidate: candidate,
            channelFactory: { _ in RecoveryIdentityFixture(wrongIdentity: true) })
        #expect(try await !transport.verifyIdentity(candidate))
        #expect(await runner.requests.last?.arguments == ["-t", "11", "forward", "--remove", "tcp:12345"])
    }

    @Test("without an authenticated helper recovery cannot claim stable identity")
    func absentContext() async throws {
        let runner = RecoveryCommandFixture()
        let candidate = try candidate()
        let transport = AndroidConnectionTransport(adbURL: URL(fileURLWithPath: "/adb"), runner: runner,
            context: nil, selectedCandidate: candidate)
        #expect(try await !transport.verifyIdentity(candidate))
        #expect(await runner.requests.isEmpty)
    }

    private func candidate(serial: String = "192.168.1.2:40000") throws -> TransportCandidate {
        try TransportCandidate(id: "11", identity: DeviceIdentity(rawValue: "selected", stability: .provisional, platform: .android),
            kind: .wifi, source: .adb, status: .candidate, observedAt: Date(),
            metadata: ["adbSerial": serial], endpoint: "192.168.1.2:40000")
    }
}

private actor RecoveryCommandFixture: HostCommandRunning {
    private(set) var requests: [HostCommandRequest] = []
    private var mdns = ""
    private var mdnsFails = false
    func failMDNS() { mdnsFails = true }
    func setMDNS(_ value: String) { mdns = value }
    func run(_ request: HostCommandRequest) async throws -> HostCommandResult {
        requests.append(request)
        let output: String
        if request.arguments == ["mdns", "services"] {
            if mdnsFails { throw AndroidRecoveryError.commandFailed }
            output = mdns
        }
        else if request.arguments.last == "get-state" { output = "device\n" }
        else if request.arguments.last == "ro.serialno" { output = "PHONE-123\n" }
        else if request.arguments.contains("tcp:0") { output = "12345\n" }
        else { output = "" }
        return HostCommandResult(exitCode: 0, standardOutput: Data(output.utf8), standardError: Data())
    }
}

private actor RecoveryIdentityFixture: HelperRequestSending {
    private(set) var actions: [HelperAction] = []
    let wrongIdentity: Bool
    init(wrongIdentity: Bool = false) { self.wrongIdentity = wrongIdentity }
    func send(_ request: HelperRequest) async throws -> HelperResult {
        actions.append(request.action)
        return HelperResult(requestID: request.requestID, status: .success, completedAt: Date(), payload: [
            "helperDeviceId": .string(wrongIdentity ? "other-helper" : "trusted-helper"),
            "helperVersion": .string("0.2.0"), "protocolVersions": .array([.number(1)])
        ])
    }
}
