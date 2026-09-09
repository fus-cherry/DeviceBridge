import DeviceBridgeProtocol
import Foundation
@preconcurrency import Network
import Testing
@testable import DeviceBridgeCore

@Suite("ADB server epoch and fixed-route boundary", .serialized)
struct ADBServerConnectionTests {
    @Test("closing during the observer handshake permanently seals the owner")
    func closeDuringBeginCannotPublishLateEpoch() async throws {
        let fake = try FakeADBServer(configuration: .init(holdObserverHandshake: true))
        try await fake.start()
        defer { fake.stop() }
        let server = try ADBServerConnection(port: fake.port)
        let opening = Task {
            try await server.beginEpoch(deadline: ContinuousClock.now.advanced(by: .seconds(2)))
        }
        try await fake.waitForRequest("host:track-devices")

        await server.close()
        await fake.observerGate.release()

        do {
            let lateEpoch = try await opening.value
            Issue.record("close allowed a late epoch to become current: \(await server.isCurrent(lateEpoch))")
        } catch let error as ADBServerConnectionError {
            #expect(error == .epochInvalidated)
        }
        await #expect(throws: ADBServerConnectionError.epochInvalidated) {
            try await server.beginEpoch(deadline: ContinuousClock.now.advanced(by: .seconds(1)))
        }
        #expect(fake.requests.filter { $0 == "host:track-devices" }.count == 1)
    }

    @Test("concurrent begin calls share one observer and one epoch")
    func concurrentBeginIsCoalesced() async throws {
        let fake = try FakeADBServer(configuration: .init(holdObserverHandshake: true))
        try await fake.start()
        defer { fake.stop() }
        let server = try ADBServerConnection(port: fake.port)
        let openings = (0..<8).map { _ in
            Task { try await server.beginEpoch(deadline: ContinuousClock.now.advanced(by: .seconds(2))) }
        }
        try await fake.waitForRequest("host:track-devices")
        try await Task.sleep(for: .milliseconds(50))

        await fake.observerGate.release()
        var epochs: [ADBServerEpoch] = []
        for opening in openings { epochs.append(try await opening.value) }

        #expect(Set(epochs).count == 1)
        #expect(fake.requests.filter { $0 == "host:track-devices" }.count == 1)
        await server.close()
    }

    @Test("an observed server disconnect permanently invalidates its epoch without reconnecting")
    func observerDisconnectInvalidatesEpoch() async throws {
        let fake = try FakeADBServer()
        try await fake.start()
        defer { fake.stop() }
        let invalidations = EpochInvalidationProbe()
        let server = try ADBServerConnection(port: fake.port) { epoch in
            Task { await invalidations.record(epoch) }
        }
        let epoch = try await server.beginEpoch(deadline: ContinuousClock.now.advanced(by: .seconds(2)))
        try await fake.waitForRequest("host:track-devices")

        fake.disconnectObserver()
        try await waitUntil { await invalidations.values.contains(epoch) }
        let requestsBeforeRun = fake.requests
        let shell = ADBShellV2Session(server: server, epoch: epoch, route: try usbRoute())
        let result = await shell.run(command: "id", deadline: ContinuousClock.now.advanced(by: .seconds(1))) { true }

        #expect(result.termination == .notStarted(.epochInvalidated))
        #expect(fake.requests == requestsBeforeRun)
        #expect(!(await server.isCurrent(epoch)))
    }

    @Test("epoch invalidation cancels an already submitted execution without replay")
    func observerDisconnectCancelsActiveExecution() async throws {
        let fake = try FakeADBServer(configuration: .init(
            shellFrames: [shellFrame(id: 1, payload: Data("partial".utf8))],
            keepShellOpen: true
        ))
        try await fake.start()
        defer { fake.stop() }
        let (server, epoch) = try await owner(for: fake)
        let shell = ADBShellV2Session(server: server, epoch: epoch, route: try usbRoute())
        let task = Task {
            await shell.run(command: "held",
                deadline: ContinuousClock.now.advanced(by: .seconds(2))) { true }
        }
        try await fake.waitForRequest("shell,v2,raw:held")

        fake.disconnectObserver()
        let result = await task.value

        #expect(result.termination == .resultUnknown)
        #expect(fake.requests.filter { $0 == "shell,v2,raw:held" }.count == 1)
        #expect(!(await server.isCurrent(epoch)))
    }

    @Test("feature gating happens before a route socket can submit shell service")
    func missingShellV2IsRejectedBeforeBinding() async throws {
        let fake = try FakeADBServer(configuration: .init(features: "cmd,stat_v2"))
        try await fake.start()
        defer { fake.stop() }
        let (server, epoch) = try await owner(for: fake)
        let shell = ADBShellV2Session(server: server, epoch: epoch, route: try usbRoute())

        let result = await shell.run(command: "id", deadline: ContinuousClock.now.advanced(by: .seconds(1))) { true }

        #expect(result.termination == .notStarted(.shellV2Unavailable))
        #expect(!fake.requests.contains(where: { $0.hasPrefix("host:tport:") }))
        #expect(!fake.requests.contains(where: { $0.hasPrefix("shell,v2,raw:") }))
    }

    @Test("smart payload lengths accept only four ASCII hexadecimal digits")
    func smartLengthIsStrictHex() async throws {
        for header in ["-001", "+001", " 001", "001 "] {
            let fake = try FakeADBServer(configuration: .init(featureLengthHeader: Data(header.utf8)))
            try await fake.start()
            let (server, epoch) = try await owner(for: fake)
            let shell = ADBShellV2Session(server: server, epoch: epoch, route: try usbRoute())

            let result = await shell.run(command: "id",
                deadline: ContinuousClock.now.advanced(by: .seconds(1))) { true }

            #expect(result.termination == .notStarted(.protocolFailure))
            #expect(!fake.requests.contains(where: { $0.hasPrefix("host:tport:") }))
            await server.close()
            fake.stop()
        }
    }

    @Test("socket cleanup waits for the local terminal state acknowledgement")
    func socketCleanupWaitsForTerminalState() async throws {
        let fake = try FakeADBServer()
        try await fake.start()
        defer { fake.stop() }
        let port = try #require(NWEndpoint.Port(rawValue: UInt16(fake.port)))
        let socket = ADBClientSocket(host: "127.0.0.1", port: port)
        try await socket.start(deadline: ContinuousClock.now.advanced(by: .seconds(1)))

        await socket.cancelAndWait()

        #expect(socket.hasReachedTerminalState)
    }

    @Test("held socket deadlines avoid scheduler coalescing slack and finish cleanup")
    func heldSocketDeadlineIsPromptAndClean() async throws {
        let fake = try FakeADBServer()
        try await fake.start()
        defer { fake.stop() }
        let port = try #require(NWEndpoint.Port(rawValue: UInt16(fake.port)))
        var overruns: [Duration] = []

        for _ in 0..<3 {
            let socket = ADBClientSocket(host: "127.0.0.1", port: port)
            try await socket.start(deadline: ContinuousClock.now.advanced(by: .seconds(1)))
            let deadline = ContinuousClock.now.advanced(by: .seconds(1))

            await #expect(throws: ADBClientSocket.Failure.timedOut) {
                _ = try await socket.readExactly(1, deadline: deadline)
            }

            overruns.append(max(.zero, deadline.duration(to: .now)))
            #expect(socket.hasReachedTerminalState)
        }

        let medianOverrun = overruns.sorted()[1]
        #expect(medianOverrun < .milliseconds(20),
                "median timeout overrun was \(medianOverrun)")
    }

    @Test("the retained execution socket rejects a changed transport ID")
    func tportResponseMustMatchCapturedTransport() async throws {
        let fake = try FakeADBServer(configuration: .init(actualTransportID: 99))
        try await fake.start()
        defer { fake.stop() }
        let (server, epoch) = try await owner(for: fake)
        let shell = ADBShellV2Session(server: server, epoch: epoch, route: try usbRoute())

        let result = await shell.run(command: "id", deadline: ContinuousClock.now.advanced(by: .seconds(1))) { true }

        #expect(result.termination == .notStarted(.routeMismatch))
        #expect(fake.requests.filter { $0 == "host:tport:serial:SERIAL-1" }.count == 1)
        #expect(!fake.requests.contains(where: { $0.hasPrefix("shell,v2,raw:") }))
    }

    @Test("Wi-Fi identity uses a second same-tuple localabstract socket and never a forward")
    func wifiIdentityUsesBoundLocalAbstractSocket() async throws {
        let context = HelperSessionContext(sessionNonce: "nonce", helperDeviceID: "device-id", helperVersion: "1.2.3")
        let fake = try FakeADBServer(configuration: .init(helperContext: context))
        try await fake.start()
        defer { fake.stop() }
        let (server, epoch) = try await owner(for: fake)
        let route = try ADBCapturedRoute(adbSerial: "192.168.1.8:5555", transportID: 42,
            sessionGeneration: 7, identityEvidence: .trustedWiFiHelper(context))
        let shell = ADBShellV2Session(server: server, epoch: epoch, route: route)

        let result = await shell.run(command: "printf ok", deadline: ContinuousClock.now.advanced(by: .seconds(2))) { true }

        #expect(result.termination == .remoteExit)
        #expect(result.exitCode == 0)
        #expect(fake.requests.filter { $0 == "host:tport:serial:192.168.1.8:5555" }.count == 2)
        #expect(fake.requests.contains("localabstract:device_bridge_helper"))
        #expect(fake.requests.filter { $0 == "shell,v2,raw:printf ok" }.count == 1)
        #expect(!fake.requests.contains(where: { $0.contains("forward") }))
        let helperRequest = try #require(fake.helperRequests.first)
        #expect(helperRequest.action == .identity)
        #expect(helperRequest.sessionNonce == context.sessionNonce)
        #expect(helperRequest.helperDeviceID == context.helperDeviceID)
    }

    @Test("mismatched Wi-Fi helper identity cannot submit a command")
    func wifiIdentityMismatchStopsBeforeShell() async throws {
        let context = HelperSessionContext(sessionNonce: "nonce", helperDeviceID: "device-id", helperVersion: "1.2.3")
        let fake = try FakeADBServer(configuration: .init(helperContext: context, helperMatches: false))
        try await fake.start()
        defer { fake.stop() }
        let (server, epoch) = try await owner(for: fake)
        let route = try ADBCapturedRoute(adbSerial: "192.168.1.8:5555", transportID: 42,
            sessionGeneration: 7, identityEvidence: .trustedWiFiHelper(context))
        let shell = ADBShellV2Session(server: server, epoch: epoch, route: route)

        let result = await shell.run(command: "id", deadline: ContinuousClock.now.advanced(by: .seconds(2))) { true }

        #expect(result.termination == .notStarted(.identityMismatch))
        #expect(!fake.requests.contains(where: { $0.hasPrefix("shell,v2,raw:") }))
        #expect(!fake.requests.contains(where: { $0.contains("forward") }))
    }

    private func owner(for fake: FakeADBServer) async throws -> (ADBServerConnection, ADBServerEpoch) {
        let server = try ADBServerConnection(port: fake.port)
        let epoch = try await server.beginEpoch(deadline: ContinuousClock.now.advanced(by: .seconds(2)))
        return (server, epoch)
    }
}

func usbRoute() throws -> ADBCapturedRoute {
    try ADBCapturedRoute(adbSerial: "SERIAL-1", transportID: 42, sessionGeneration: 7,
        identityEvidence: .uniqueUSBSerial)
}

func waitUntil(_ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while !(await condition()) {
        guard ContinuousClock.now < deadline else { throw FakeADBFailure.timedOut }
        try await Task.sleep(for: .milliseconds(5))
    }
}

private actor EpochInvalidationProbe {
    private(set) var values: [ADBServerEpoch] = []
    func record(_ epoch: ADBServerEpoch) { values.append(epoch) }
}

struct FakeADBConfiguration: Sendable {
    var holdObserverHandshake = false
    var actualTransportID: UInt64 = 42
    var features = "shell_v2,cmd,stat_v2"
    var featureLengthHeader: Data?
    var helperContext: HelperSessionContext?
    var helperMatches = true
    var shellFrames: [Data] = [shellFrame(id: 3, payload: Data([0]))]
    var keepShellOpen = false
    var disconnectAfterTport = false
    var disconnectAfterShellFrames = false
    var fragmentResponses = true
}

enum FakeADBFailure: Error {
    case listenerFailed
    case connectionClosed
    case malformedRequest
    case timedOut
}

final class FakeADBServer: @unchecked Sendable {
    let observerGate = FakeADBObserverGate()
    private let listener: NWListener
    private let configuration: FakeADBConfiguration
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var observer: NWConnection?
    private var recordedRequests: [String] = []
    private var recordedHelperRequests: [HelperRequest] = []
    private var recordedCloseStdin: [Data] = []
    private var holdWaiters: [CheckedContinuation<Void, Never>] = []
    private var stopped = false

    init(configuration: FakeADBConfiguration = .init()) throws {
        self.configuration = configuration
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    var port: Int { Int(listener.port!.rawValue) }
    var requests: [String] { lock.withLock { recordedRequests } }
    var helperRequests: [HelperRequest] { lock.withLock { recordedHelperRequests } }
    var closeStdinFrames: [Data] { lock.withLock { recordedCloseStdin } }

    func start() async throws {
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.lock.withLock { self.connections.append(connection) }
            connection.start(queue: .global(qos: .userInitiated))
            Task { await self.handle(connection) }
        }
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume()
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: .global(qos: .userInitiated))
        }
    }

    func stop() {
        let state = lock.withLock { () -> ([NWConnection], [CheckedContinuation<Void, Never>]) in
            guard !stopped else { return ([], []) }
            stopped = true
            let waiters = holdWaiters
            holdWaiters.removeAll()
            return (connections, waiters)
        }
        listener.cancel()
        state.0.forEach { $0.cancel() }
        state.1.forEach { $0.resume() }
    }

    func disconnectObserver() {
        lock.withLock { observer }?.cancel()
    }

    func waitForRequest(_ request: String) async throws {
        try await waitUntil { self.requests.contains(request) }
    }

    private func handle(_ connection: NWConnection) async {
        do {
            let request = try await readSmartRequest(connection)
            record(request)
            switch request {
            case "host:track-devices":
                if configuration.holdObserverHandshake { await observerGate.wait() }
                lock.withLock { observer = connection }
                try await send(smartPayload(Data("serial\tdevice\n".utf8)), over: connection)
                await holdUntilStopped()
            case let value where value.hasPrefix("host-serial:") && value.hasSuffix(":features"):
                let payload = Data(configuration.features.utf8)
                if let header = configuration.featureLengthHeader {
                    try await send(Data("OKAY".utf8) + header + payload, over: connection)
                } else {
                    try await send(smartPayload(payload), over: connection)
                }
                connection.cancel()
            case let value where value.hasPrefix("host:tport:serial:"):
                var transport = configuration.actualTransportID.littleEndian
                var response = Data("OKAY".utf8)
                response.append(withUnsafeBytes(of: &transport) { Data($0) })
                try await send(response, over: connection)
                if configuration.disconnectAfterTport { connection.cancel(); return }
                let service = try await readSmartRequest(connection)
                record(service)
                if service.hasPrefix("localabstract:") {
                    try await serveIdentity(on: connection)
                } else if service.hasPrefix("shell,v2,raw:") {
                    try await serveShell(on: connection)
                } else {
                    try await send(Data("FAIL000Funknown service".utf8), over: connection)
                }
            default:
                try await send(Data("FAIL000Funknown request".utf8), over: connection)
            }
        } catch {
            connection.cancel()
        }
    }

    private func serveIdentity(on connection: NWConnection) async throws {
        try await send(Data("OKAY".utf8), over: connection)
        let header = try await receiveExactly(4, from: connection)
        let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let payload = try await receiveExactly(Int(length), from: connection)
        let request = try HelperWireCodec().decodeRequest(payload)
        lock.withLock { recordedHelperRequests.append(request) }
        let context = configuration.helperContext
        let result = HelperResult(requestID: request.requestID, status: .success, completedAt: request.createdAt,
            payload: [
                "helperDeviceId": .string(configuration.helperMatches ? context?.helperDeviceID ?? "device-id" : "wrong-device"),
                "helperVersion": .string(context?.helperVersion ?? "1.2.3"),
                "protocolVersions": .array([.number(1)]),
            ])
        try await send(HelperFrameCodec.encode(HelperWireCodec().encode(result)), over: connection)
        connection.cancel()
    }

    private func serveShell(on connection: NWConnection) async throws {
        try await send(Data("OKAY".utf8), over: connection)
        for frame in configuration.shellFrames { try await send(frame, over: connection) }
        if configuration.disconnectAfterShellFrames { connection.cancel(); return }
        if let close = try? await receiveExactly(5, from: connection) {
            lock.withLock { recordedCloseStdin.append(close) }
        }
        if configuration.keepShellOpen { await holdUntilStopped() }
        connection.cancel()
    }

    private func readSmartRequest(_ connection: NWConnection) async throws -> String {
        let header = try await receiveExactly(4, from: connection)
        guard let text = String(data: header, encoding: .ascii), let length = Int(text, radix: 16),
              length <= 65_535 else { throw FakeADBFailure.malformedRequest }
        let payload = try await receiveExactly(length, from: connection)
        guard let request = String(data: payload, encoding: .utf8) else { throw FakeADBFailure.malformedRequest }
        return request
    }

    private func send(_ data: Data, over connection: NWConnection) async throws {
        let chunks = configuration.fragmentResponses ? data.map { Data([$0]) } : [data]
        for chunk in chunks {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(content: chunk, completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                })
            }
        }
    }

    private func receiveExactly(_ count: Int, from connection: NWConnection) async throws -> Data {
        var result = Data()
        while result.count < count {
            let maximumLength = min(64 * 1_024, count - result.count)
            let chunk = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: maximumLength) {
                    data, _, complete, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let data, !data.isEmpty { continuation.resume(returning: data) }
                    else if complete { continuation.resume(throwing: FakeADBFailure.connectionClosed) }
                    else { continuation.resume(returning: Data()) }
                }
            }
            if chunk.isEmpty { continue }
            result.append(chunk)
        }
        return result
    }

    private func holdUntilStopped() async {
        await withCheckedContinuation { continuation in
            let resume = lock.withLock { () -> Bool in
                if stopped { return true }
                holdWaiters.append(continuation)
                return false
            }
            if resume { continuation.resume() }
        }
    }

    private func record(_ request: String) {
        lock.withLock { recordedRequests.append(request) }
    }

    private func smartPayload(_ payload: Data) -> Data {
        Data("OKAY\(String(format: "%04X", payload.count))".utf8) + payload
    }
}

actor FakeADBObserverGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if released { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        released = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

func shellFrame(id: UInt8, payload: Data) -> Data {
    var length = UInt32(payload.count).littleEndian
    var result = Data([id])
    result.append(withUnsafeBytes(of: &length) { Data($0) })
    result.append(payload)
    return result
}
