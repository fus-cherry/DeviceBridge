import Darwin
import Foundation
import Testing
import DeviceBridgeProtocol
@testable import DeviceBridgeCore

struct AgentIPCTests {
    @Test func privateEndpointRoundTripsOneRequestAndRetainsFixedLockFile() async throws {
        let directory = try ipcTestDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let server = AgentIPCServer(directory: directory) { AgentAPIResponse(requestID: $0.requestID, result: ["state": .string("ready")]) }
        try await server.start()
        let socket = AgentIPCPaths.socketURL(in: directory), lock = AgentIPCPaths.lockURL(in: directory)
        #expect(try ipcMode(directory) == 0o700)
        #expect(try ipcMode(socket) == 0o600)
        #expect(try ipcMode(lock) == 0o600)
        let inode = try ipcInode(lock)
        let request = try AgentAPIRequest(requestID: UUID(), method: .deviceCurrent)
        #expect(try await AgentIPCClient(directory: directory).send(request).result == ["state": .string("ready")])
        await server.stop()
        #expect(!FileManager.default.fileExists(atPath: socket.path))
        #expect(try ipcInode(lock) == inode)
        let next = AgentIPCServer(directory: directory) { AgentAPIResponse(requestID: $0.requestID, result: [:]) }
        try await next.start(); await next.stop()
        #expect(try ipcInode(lock) == inode)
    }

    @Test func secondOwnerCannotReplaceLiveEndpointAndOldOwnerCannotUnlinkReplacement() async throws {
        let directory = try ipcTestDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let first = AgentIPCServer(directory: directory) { AgentAPIResponse(requestID: $0.requestID, result: ["owner": .number(1)]) }
        let second = AgentIPCServer(directory: directory) { AgentAPIResponse(requestID: $0.requestID, result: ["owner": .number(2)]) }
        try await first.start()
        let socket = AgentIPCPaths.socketURL(in: directory), inode = try ipcInode(socket)
        await #expect(throws: AgentIPCError.ownerAlreadyRunning) { try await second.start() }
        #expect(try ipcInode(socket) == inode)
        let request = try AgentAPIRequest(requestID: UUID(), method: .deviceCurrent)
        #expect(try await AgentIPCClient(directory: directory).send(request).result?["owner"] == .number(1))
        try FileManager.default.moveItem(at: socket, to: directory.appendingPathComponent("old.sock"))
        try Data("replacement".utf8).write(to: socket)
        await first.stop()
        #expect(try Data(contentsOf: socket) == Data("replacement".utf8))
    }

    @Test(arguments: ["directoryPermissions", "directorySymlink", "endpointSymlink", "lockSymlink", "endpointRegular"])
    func unsafeFilesystemObjectsAreRejectedWithoutRemovingTheirTargets(_ variant: String) async throws {
        let base = try ipcTestDirectory(); defer { try? FileManager.default.removeItem(at: base) }
        let directory = base.appendingPathComponent("agent"), target = base.appendingPathComponent("protected")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try Data("untouched".utf8).write(to: target)
        switch variant {
        case "directoryPermissions": try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        case "directorySymlink":
            try FileManager.default.removeItem(at: directory)
            try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: base)
        case "endpointSymlink": try FileManager.default.createSymbolicLink(at: AgentIPCPaths.socketURL(in: directory), withDestinationURL: target)
        case "lockSymlink": try FileManager.default.createSymbolicLink(at: AgentIPCPaths.lockURL(in: directory), withDestinationURL: target)
        case "endpointRegular": try Data("ordinary file".utf8).write(to: AgentIPCPaths.socketURL(in: directory))
        default: break
        }
        let server = AgentIPCServer(directory: directory) { AgentAPIResponse(requestID: $0.requestID, result: [:]) }
        await #expect(throws: (any Error).self) { try await server.start() }
        #expect(try Data(contentsOf: target) == Data("untouched".utf8))
        await server.stop()
    }

    @Test func freeLifecycleLockAllowsRemovingOnlyVerifiedStaleSocket() async throws {
        let directory = try ipcTestDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let stale = try AgentIPCConnection.listen(socketURL: AgentIPCPaths.socketURL(in: directory))
        #expect(chmod(AgentIPCPaths.socketURL(in: directory).path, 0o600) == 0)
        stale.close()
        let server = AgentIPCServer(directory: directory) { AgentAPIResponse(requestID: $0.requestID, result: [:]) }
        try await server.start()
        #expect(try await AgentIPCClient(directory: directory).send(AgentAPIRequest(requestID: UUID(), method: .deviceCurrent)).result == [:])
        await server.stop()
    }

    @Test func fragmentedFrameIsReassembledAndPipelinedSecondRequestIsNeverDispatched() async throws {
        let directory = try ipcTestDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let calls = IPCHandlerCalls()
        let server = AgentIPCServer(directory: directory) { request in
            await calls.record(); return AgentAPIResponse(requestID: request.requestID, result: [:])
        }
        try await server.start()
        let connection = try AgentIPCConnection.connect(socketURL: AgentIPCPaths.socketURL(in: directory), deadline: .now + .seconds(1))
        let request = try AgentAPIRequest(requestID: UUID(), method: .deviceCurrent)
        let frame = try AgentIPCConnection.frame(AgentAPIWire.encodeRequest(request), maximumBytes: AgentAPIWire.maximumRequestBytes)
        try connection.write(Data(frame.prefix(2)), deadline: .now + .seconds(1))
        try connection.write(Data(frame.dropFirst(2)) + frame, deadline: .now + .seconds(1))
        let response = try AgentAPIWire.decodeResponse(connection.readFrame(maximumBytes: AgentAPIWire.maximumResponseBytes, deadline: .now + .seconds(2)))
        #expect(response.requestID == request.requestID)
        #expect(await calls.count == 1)
        #expect(throws: (any Error).self) { try connection.readFrame(maximumBytes: 100, deadline: .now + .seconds(1)) }
        connection.close(); await server.stop()
    }

    @Test func fifthClientIsRefusedBeforeHandlerAndCapacityReturnsAfterClose() async throws {
        let directory = try ipcTestDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let calls = IPCHandlerCalls()
        let server = AgentIPCServer(directory: directory) { request in
            await calls.record(); return AgentAPIResponse(requestID: request.requestID, result: [:])
        }
        try await server.start()
        var stalled: [AgentIPCConnection] = []
        for _ in 0..<4 { stalled.append(try AgentIPCConnection.connect(socketURL: AgentIPCPaths.socketURL(in: directory), deadline: .now + .seconds(1))) }
        let request = try AgentAPIRequest(requestID: UUID(), method: .deviceCurrent)
        await #expect(throws: (any Error).self) { try await AgentIPCClient(directory: directory).send(request) }
        #expect(await calls.count == 0)
        for connection in stalled { connection.close() }
        try await Task.sleep(for: .milliseconds(200))
        #expect(try await AgentIPCClient(directory: directory).send(request).requestID == request.requestID)
        await server.stop()
    }

    @Test func peersClosingBeforeAdmissionCannotStopTheListener() async throws {
        let directory = try ipcTestDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let server = AgentIPCServer(directory: directory) { AgentAPIResponse(requestID: $0.requestID, result: [:]) }
        try await server.start()
        try await Task.detached {
            for _ in 0..<32 {
                let peer = try AgentIPCConnection.connect(socketURL: AgentIPCPaths.socketURL(in: directory), deadline: .now + .seconds(1))
                peer.close()
                // Keep this an early-disconnect test, below the separately tested admission limit.
                try await Task.sleep(for: .milliseconds(5))
            }
        }.value
        // Wait for the four bounded read lifecycles to observe EOF before testing service.
        try await Task.sleep(for: .milliseconds(200))
        let request = try AgentAPIRequest(requestID: UUID(), method: .deviceCurrent)
        #expect(try await AgentIPCClient(directory: directory).send(request).requestID == request.requestID)
        await server.stop()
    }

    @Test func descriptorPressureRecoversInIsolatedProcess() async throws {
        let directory = try ipcTestDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        try Data([0]).write(to: directory.appendingPathComponent("phase"))
        try Data([0]).write(to: directory.appendingPathComponent("control"))
        async let exchange: Void = ipcDriveDescriptorPressure(directory: directory)
        await #expect(processExitsWith: .success) { [directory = directory as URL] in
            try await ipcDescriptorPressureChild(directory: directory)
        }
        try await exchange
        #expect(!FileManager.default.fileExists(atPath: AgentIPCPaths.socketURL(in: directory).path))
        let next = AgentIPCServer(directory: directory) { AgentAPIResponse(requestID: $0.requestID, result: [:]) }
        try await next.start(); await next.stop()
    }

    @Test func terminalAcceptLoopEventClosesClientsAndReleasesTheOwnerLease() async throws {
        let directory = try ipcTestDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let server = AgentIPCServer(directory: directory) { AgentAPIResponse(requestID: $0.requestID, result: [:]) }
        try await server.start()
        let stalled = try AgentIPCConnection.connect(socketURL: AgentIPCPaths.socketURL(in: directory), deadline: .now + .seconds(1))
        defer { stalled.close() }
        await server.acceptLoopEnded()
        #expect(throws: (any Error).self) { try stalled.readFrame(maximumBytes: 100, deadline: .now + .seconds(1)) }
        #expect(!FileManager.default.fileExists(atPath: AgentIPCPaths.socketURL(in: directory).path))
        let next = AgentIPCServer(directory: directory) { AgentAPIResponse(requestID: $0.requestID, result: [:]) }
        try await next.start()
        await server.stop()
        #expect(try await AgentIPCClient(directory: directory).send(AgentAPIRequest(requestID: UUID(), method: .deviceCurrent)).result == [:])
        await next.stop()
    }

    @Test func readAndWriteHaveAbsoluteDeadlinesAndOversizedHeaderAllocatesNoBody() throws {
        var descriptors: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        let first = try AgentIPCConnection(descriptor: descriptors[0]), second = try AgentIPCConnection(descriptor: descriptors[1])
        defer { first.close(); second.close() }
        #expect(throws: AgentIPCError.timedOut) { try first.readFrame(maximumBytes: 100, deadline: .now + .milliseconds(40)) }
        try second.write(Data([0x7f, 0xff, 0xff, 0xff]), deadline: .now + .seconds(1))
        #expect(throws: AgentIPCError.invalidFrame) { try first.readFrame(maximumBytes: 100, deadline: .now + .seconds(1)) }
        #expect(throws: AgentIPCError.timedOut) { try first.write(Data(repeating: 65, count: 2 * 1024 * 1024), deadline: .now + .milliseconds(40)) }
    }

    @Test func peerAndFilesystemUserChecksRejectAnotherUser() throws {
        try AgentIPCIdentity.validateUser(geteuid())
        #expect(throws: AgentIPCError.peerRejected) { try AgentIPCIdentity.validateUser(geteuid() == 0 ? 1 : 0) }
    }

    @Test func disconnectAfterAcceptanceDoesNotCancelHandler() async throws {
        let directory = try ipcTestDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let gate = IPCHandlerGate()
        let server = AgentIPCServer(directory: directory) { request in
            await gate.pause()
            await gate.recordCompletion(cancelled: Task.isCancelled)
            return AgentAPIResponse(requestID: request.requestID, result: [:])
        }
        try await server.start()
        let connection = try AgentIPCConnection.connect(socketURL: AgentIPCPaths.socketURL(in: directory), deadline: .now + .seconds(1))
        let request = try AgentAPIRequest(requestID: UUID(), method: .deviceCurrent)
        try connection.write(AgentIPCConnection.frame(AgentAPIWire.encodeRequest(request), maximumBytes: AgentAPIWire.maximumRequestBytes), deadline: .now + .seconds(1))
        try await gate.waitForEntry()
        connection.close()
        await gate.resume()
        try await gate.waitForCompletion()
        #expect(await gate.wasCancelled == false)
        await server.stop()
    }

    @Test func stopReleasesLeaseWhileHandlerIsSuspendedAndLateCompletionCannotTouchNextOwner() async throws {
        let directory = try ipcTestDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let gate = IPCHandlerGate()
        let first = AgentIPCServer(directory: directory) { request in
            await gate.pause()
            await gate.recordCompletion(cancelled: Task.isCancelled)
            return AgentAPIResponse(requestID: request.requestID, result: ["owner": .number(1)])
        }
        try await first.start()
        let request = try AgentAPIRequest(requestID: UUID(), method: .deviceCurrent)
        let pending = Task { try await AgentIPCClient(directory: directory).send(request) }
        try await gate.waitForEntry()
        async let stopOne: Void = first.stop()
        async let stopTwo: Void = first.stop()
        _ = await (stopOne, stopTwo)
        await #expect(throws: (any Error).self) { try await pending.value }
        let second = AgentIPCServer(directory: directory) { AgentAPIResponse(requestID: $0.requestID, result: ["owner": .number(2)]) }
        try await second.start()
        let inode = try ipcInode(AgentIPCPaths.socketURL(in: directory))
        await gate.resume()
        try await gate.waitForCompletion()
        await first.stop()
        #expect(await gate.wasCancelled == true)
        #expect(try ipcInode(AgentIPCPaths.socketURL(in: directory)) == inode)
        #expect(try await AgentIPCClient(directory: directory).send(request).result?["owner"] == .number(2))
        await second.stop()
    }

    @Test func oversizedHandlerResponseBecomesStructuredFailureOutsideHandler() async throws {
        let directory = try ipcTestDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let server = AgentIPCServer(directory: directory) { request in
            AgentAPIResponse(requestID: request.requestID, result: ["text": .string(String(repeating: "x", count: 2 * 1024 * 1024))])
        }
        try await server.start()
        let result = try await AgentIPCClient(directory: directory).send(AgentAPIRequest(requestID: UUID(), method: .deviceCurrent))
        #expect(result.error?.code == .responseTooLarge)
        await server.stop()
    }
}
private actor IPCHandlerCalls { private(set) var count = 0; func record() { count += 1 } }
private func ipcTestDirectory() throws -> URL {
    // Keep sockaddr_un paths short, unique, and disconnected from the real app endpoint.
    let directory = URL(fileURLWithPath: "/tmp/db-agent-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    return directory
}
private func ipcMode(_ url: URL) throws -> Int { (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber).intValue }
private func ipcInode(_ url: URL) throws -> UInt64 { (try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as! NSNumber).uint64Value }

private actor IPCHandlerGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var entered = false
    private var completed = false
    private(set) var wasCancelled = false
    func pause() async {
        await withCheckedContinuation { continuation in self.continuation = continuation; entered = true }
    }
    func resume() { continuation?.resume(); continuation = nil }
    func recordCompletion(cancelled: Bool) { wasCancelled = cancelled; completed = true }
    func waitForEntry() async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !entered { guard ContinuousClock.now < deadline else { throw AgentIPCError.timedOut }; try await Task.sleep(for: .milliseconds(1)) }
    }
    func waitForCompletion() async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !completed { guard ContinuousClock.now < deadline else { throw AgentIPCError.timedOut }; try await Task.sleep(for: .milliseconds(1)) }
    }
}

// Swift Testing owns this subprocess, including when the suite is hosted by macOS xctest.
// Both limits change only inside the child; the main test runner remains untouched.
private func ipcDescriptorPressureChild(directory: URL) async throws {
    let phase = try FileHandle(forUpdating: directory.appendingPathComponent("phase"))
    let control = try FileHandle(forReadingFrom: directory.appendingPathComponent("control"))
    defer { try? phase.close(); try? control.close() }
    let server = AgentIPCServer(directory: directory) { AgentAPIResponse(requestID: $0.requestID, result: [:]) }
    try await server.start()
    let request = try AgentAPIRequest(requestID: UUID(), method: .deviceCurrent)
    _ = try await AgentIPCClient(directory: directory).send(request)
    // Let baseline connection teardown finish before deliberately filling every free slot.
    try await Task.sleep(for: .milliseconds(100))
    var original = rlimit()
    guard getrlimit(RLIMIT_NOFILE, &original) == 0 else { throw AgentIPCError.ioFailure }
    var restricted = rlimit(rlim_cur: min(original.rlim_cur, 64), rlim_max: min(original.rlim_max, 64))
    guard setrlimit(RLIMIT_NOFILE, &restricted) == 0 else { throw AgentIPCError.ioFailure }
    var owned: [Int32] = []
    // The hard limit intentionally stays lowered until this isolated child exits.
    defer { for fd in owned { Darwin.close(fd) } }
    while true {
        let fd = open("/dev/null", O_RDONLY | O_CLOEXEC)
        if fd < 0 { break }
        owned.append(fd)
    }
    guard errno == EMFILE, !owned.isEmpty else { throw AgentIPCError.ioFailure }
    try ipcWritePhase(phase.fileDescriptor, value: 1)
    try await ipcWaitForPhase(control.fileDescriptor, value: 1, deadline: .now + .seconds(5))
    // Parent has queued peers. Keep the descriptor limit active for accept to observe it.
    try await Task.sleep(for: .milliseconds(300))
    for fd in owned { Darwin.close(fd) }
    owned.removeAll()
    try ipcWritePhase(phase.fileDescriptor, value: 2)
    try await ipcWaitForPhase(control.fileDescriptor, value: 2, deadline: .now + .seconds(3))
    // Recovery must preserve one live owner, rather than replacing the endpoint on pressure.
    let competing = AgentIPCServer(directory: directory) { AgentAPIResponse(requestID: $0.requestID, result: [:]) }
    do {
        try await competing.start()
        await competing.stop()
        throw AgentIPCError.unsafeLock
    } catch AgentIPCError.ownerAlreadyRunning { }
    await server.stop()
}

private func ipcDriveDescriptorPressure(directory: URL) async throws {
    let phase = try FileHandle(forReadingFrom: directory.appendingPathComponent("phase"))
    let control = try FileHandle(forUpdating: directory.appendingPathComponent("control"))
    defer { try? phase.close(); try? control.close() }
    try await ipcWaitForPhase(phase.fileDescriptor, value: 1, deadline: .now + .seconds(5))
    var triggers: [AgentIPCConnection] = []
    defer { for trigger in triggers { trigger.close() } }
    for _ in 0..<2 {
        triggers.append(try AgentIPCConnection.connect(socketURL: AgentIPCPaths.socketURL(in: directory), deadline: .now + .seconds(1)))
    }
    try ipcWritePhase(control.fileDescriptor, value: 1)
    try await ipcWaitForPhase(phase.fileDescriptor, value: 2, deadline: .now + .seconds(3))
    for trigger in triggers { trigger.close() }
    triggers.removeAll()
    let peer = try AgentIPCConnection.connect(socketURL: AgentIPCPaths.socketURL(in: directory), deadline: .now + .seconds(1))
    defer { peer.close() }
    let request = try AgentAPIRequest(requestID: UUID(), method: .deviceCurrent)
    try peer.write(AgentIPCConnection.frame(AgentAPIWire.encodeRequest(request), maximumBytes: AgentAPIWire.maximumRequestBytes), deadline: .now + .seconds(1))
    let bytes = try await Task.detached {
        try peer.readFrame(maximumBytes: AgentAPIWire.maximumResponseBytes, deadline: .now + .seconds(2))
    }.value
    #expect(try AgentAPIWire.decodeResponse(bytes).requestID == request.requestID)
    try ipcWritePhase(control.fileDescriptor, value: 2)
}

private func ipcWritePhase(_ descriptor: Int32, value: UInt8) throws {
    var value = value
    guard pwrite(descriptor, &value, 1, 0) == 1 else { throw AgentIPCError.ioFailure }
}
private func ipcWaitForPhase(_ descriptor: Int32, value: UInt8, deadline: ContinuousClock.Instant) async throws {
    while ContinuousClock.now < deadline {
        var current: UInt8 = 0
        guard pread(descriptor, &current, 1, 0) == 1 else { throw AgentIPCError.ioFailure }
        if current >= value { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw AgentIPCError.timedOut
}
