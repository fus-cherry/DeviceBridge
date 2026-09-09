import Foundation
import Testing
import DeviceBridgeSecureChannel
@testable import DeviceBridgeCore

struct IOSRunnerUSBEndpointTests {
    @Test func exactPublicRecordAndLiveChildProduceOnlyAPinnedUSBEndpoint() async throws {
        let host = try EphemeralTLSIdentity.create()
        let phone = try EphemeralTLSIdentity.create()
        let launch = IOSRunnerLaunch(deviceIdentifier: "PUBLIC-TARGET")
        let record = try PublicBootstrapRecord.encode(launchID: launch.id, hostCertificateDER: host.certificateDER,
            runnerCertificateDER: phone.certificateDER, helperBuild: "public-build")
        let server = try MuxServer { listener in
            try muxInventory(listener)
            let fd = try muxAccept(listener)
            defer { Darwin.close(fd) }
            let request = try muxRequest(fd)
            try muxSend(fd, body: ["MessageType": "Result", "Number": 0], tag: request.tag)
            #expect(try muxReadToEOF(fd))
        }
        let usb = EndpointUSB(socketPath: server.path)
        let reader = EndpointReader { requested in #expect(requested == launch); return record }
        let endpoint = IOSRunnerUSBEndpoint(launch: launch, hostCertificateDER: host.certificateDER,
            helperBuild: "public-build", reader: reader, usb: usb)
        let pinned = try await endpoint.open(process: EndpointProcess())
        #expect(pinned.port > 0)
        #expect(pinned.runnerCertificateDER == phone.certificateDER)
        #expect(await usb.requestedDevice == launch.deviceIdentifier)
        #expect(await usb.requestedPort == 49872)
        await endpoint.close()
        await endpoint.close()
        try await server.finish()
    }

    @Test(arguments: ["launch", "host", "build", "malformed"])
    func mismatchedPublicRecordNeverOpensUSB(mismatch: String) async throws {
        let host = try EphemeralTLSIdentity.create()
        let phone = try EphemeralTLSIdentity.create()
        let launch = IOSRunnerLaunch(deviceIdentifier: "PUBLIC-TARGET")
        let record = mismatch == "malformed" ? Data("not JSON".utf8) : try PublicBootstrapRecord.encode(
            launchID: mismatch == "launch" ? UUID() : launch.id,
            hostCertificateDER: mismatch == "host" ? phone.certificateDER : host.certificateDER,
            runnerCertificateDER: phone.certificateDER, helperBuild: mismatch == "build" ? "wrong" : "public-build")
        let usb = EndpointUSB(socketPath: nil)
        let endpoint = IOSRunnerUSBEndpoint(launch: launch, hostCertificateDER: host.certificateDER,
            helperBuild: "public-build", reader: EndpointReader { _ in record }, usb: usb)
        await #expect(throws: (any Error).self) { try await endpoint.open(process: EndpointProcess()) }
        #expect(await usb.requestedDevice == nil)
        await endpoint.close()
    }

    @Test func exitedChildCannotAuthorizeTheReturnedRecord() async throws {
        let host = try EphemeralTLSIdentity.create()
        let phone = try EphemeralTLSIdentity.create()
        let launch = IOSRunnerLaunch(deviceIdentifier: "PUBLIC-TARGET")
        let process = EndpointProcess()
        let record = try PublicBootstrapRecord.encode(launchID: launch.id, hostCertificateDER: host.certificateDER,
            runnerCertificateDER: phone.certificateDER, helperBuild: "public-build")
        let reader = EndpointReader { _ in await process.stop(); return record }
        let usb = EndpointUSB(socketPath: nil)
        let endpoint = IOSRunnerUSBEndpoint(launch: launch, hostCertificateDER: host.certificateDER,
            helperBuild: "public-build", reader: reader, usb: usb)
        await #expect(throws: (any Error).self) { try await endpoint.open(process: process) }
        #expect(await usb.requestedDevice == nil)
    }

    @Test func closeUnblocksOpeningWithoutAcceptingALateCopy() async throws {
        let host = try EphemeralTLSIdentity.create()
        let launch = IOSRunnerLaunch(deviceIdentifier: "PUBLIC-TARGET")
        let gate = EndpointGate()
        let reader = EndpointReader { _ in await gate.wait(); return Data("late".utf8) }
        let usb = EndpointUSB(socketPath: nil)
        let endpoint = IOSRunnerUSBEndpoint(launch: launch, hostCertificateDER: host.certificateDER,
            helperBuild: "public-build", reader: reader, usb: usb)
        let opening = Task { try await endpoint.open(process: EndpointProcess()) }
        while await !reader.started { await Task.yield() }
        await endpoint.close()
        await #expect(throws: CancellationError.self) { try await opening.value }
        await gate.release()
        await endpoint.drainOpeningWork()
        #expect(await usb.requestedDevice == nil)
        await #expect(throws: (any Error).self) { try await endpoint.open(process: EndpointProcess()) }
    }

    @Test(arguments: [false, true])
    func deadlineOrCallerCancellationUnblocksAStalledCopy(cancelCaller: Bool) async throws {
        let host = try EphemeralTLSIdentity.create()
        let launch = IOSRunnerLaunch(deviceIdentifier: "PUBLIC-TARGET")
        let gate = EndpointGate()
        let reader = EndpointReader { _ in await gate.wait(); return Data("late".utf8) }
        let usb = EndpointUSB(socketPath: nil)
        let endpoint = IOSRunnerUSBEndpoint(launch: launch, hostCertificateDER: host.certificateDER,
            helperBuild: "public-build", reader: reader, usb: usb,
            startupTimeout: cancelCaller ? .seconds(2) : .milliseconds(40))
        let opening = Task { try await endpoint.open(process: EndpointProcess()) }
        while await !reader.started { await Task.yield() }
        if cancelCaller { opening.cancel() }
        if cancelCaller {
            await #expect(throws: CancellationError.self) { try await opening.value }
        } else {
            await #expect(throws: IOSRunnerLaunchError.channelUnavailable) { try await opening.value }
        }
        await gate.release()
        await endpoint.drainOpeningWork()
        #expect(await usb.requestedDevice == nil)
        await endpoint.close()
    }

    @Test func closeReclaimsConnectedUSBEvenWhileChildCheckIsBlocked() async throws {
        let host = try EphemeralTLSIdentity.create()
        let phone = try EphemeralTLSIdentity.create()
        let launch = IOSRunnerLaunch(deviceIdentifier: "PUBLIC-TARGET")
        let record = try PublicBootstrapRecord.encode(launchID: launch.id, hostCertificateDER: host.certificateDER,
            runnerCertificateDER: phone.certificateDER, helperBuild: "public-build")
        let server = try MuxServer { listener in
            try muxInventory(listener)
            let fd = try muxAccept(listener)
            defer { Darwin.close(fd) }
            let request = try muxRequest(fd)
            try muxSend(fd, body: ["MessageType": "Result", "Number": 0], tag: request.tag)
            #expect(try muxReadToEOF(fd))
        }
        let gate = EndpointGate()
        let process = EndpointGatedProcess(gate: gate)
        let endpoint = IOSRunnerUSBEndpoint(launch: launch, hostCertificateDER: host.certificateDER,
            helperBuild: "public-build", reader: EndpointReader { _ in record }, usb: EndpointUSB(socketPath: server.path))
        let opening = Task { try await endpoint.open(process: process) }
        while await !process.blocked { await Task.yield() }
        await endpoint.close()
        var reclaimedBeforeChildCheckReturned = true
        do { try await server.finish() }
        catch { reclaimedBeforeChildCheckReturned = false }
        await gate.release()
        await endpoint.drainOpeningWork()
        await #expect(throws: CancellationError.self) { try await opening.value }
        #expect(reclaimedBeforeChildCheckReturned)
    }
}

private actor EndpointReader: IOSRunnerPublicRecordReading {
    let operation: @Sendable (IOSRunnerLaunch) async throws -> Data
    var started = false
    init(_ operation: @escaping @Sendable (IOSRunnerLaunch) async throws -> Data) { self.operation = operation }
    func read(launch: IOSRunnerLaunch) async throws -> Data { started = true; return try await operation(launch) }
}

private actor EndpointUSB: IOSRunnerUSBConnecting {
    let socketPath: String?
    var requestedDevice: String?
    var requestedPort: UInt16?
    init(socketPath: String?) { self.socketPath = socketPath }
    func connect(hardwareUDID: String, port: UInt16) async throws -> IOSUSBMuxConnection {
        requestedDevice = hardwareUDID; requestedPort = port
        guard let socketPath else { throw IOSUSBMuxConnection.Failure.unavailable }
        return try await IOSUSBMuxConnection.connect(hardwareUDID: hardwareUDID, port: port, socketPath: socketPath, timeout: 2)
    }
}

private actor EndpointProcess: IOSRunnerProcessOwning {
    var stopped = false
    func exitStatus() -> IOSRunnerProcess.Exit? { stopped ? .exited(0) : nil }
    func stop() { stopped = true }
}

private actor EndpointGate {
    var released = false
    var waiter: CheckedContinuation<Void, Never>?
    func wait() async { if !released { await withCheckedContinuation { waiter = $0 } } }
    func release() { released = true; waiter?.resume(); waiter = nil }
}

private actor EndpointGatedProcess: IOSRunnerProcessOwning {
    let gate: EndpointGate
    var checks = 0
    var blocked = false
    init(gate: EndpointGate) { self.gate = gate }
    func exitStatus() async -> IOSRunnerProcess.Exit? {
        checks += 1
        if checks == 3 { blocked = true; await gate.wait() }
        return nil
    }
    func stop() async { await gate.release() }
}
