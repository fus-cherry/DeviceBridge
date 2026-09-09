import Darwin
import Foundation

public enum AgentIPCPaths {
    public static var defaultDirectory: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".devicebridge-agent", isDirectory: true) }
    public static func socketURL(in directory: URL) -> URL { directory.appendingPathComponent("agent.sock") }
    public static func lockURL(in directory: URL) -> URL { directory.appendingPathComponent("owner.lock") }
}
public enum AgentIPCError: Error, Sendable, Equatable {
    case invalidPath, unsafeDirectory, unsafeEndpoint, unsafeLock, ownerAlreadyRunning
    case unavailable, timedOut, invalidFrame, peerRejected, closed, ioFailure
}

/// A single app owner admits at most four complete request/response lifecycles. The handler
/// returns an immutable snapshot; framing and bounded encoding run outside MainActor.
public actor AgentIPCServer {
    public typealias Handler = @Sendable (AgentAPIRequest) async -> AgentAPIResponse
    private let directory: URL
    private let handler: Handler
    private var owner: AgentIPCOwner?
    private var accepting: Task<Void, Never>?
    private struct Client: Sendable { let connection: AgentIPCConnection; let task: Task<Void, Never> }
    private var clients: [UUID: Client] = [:]
    private enum Phase { case idle, running, stopping(Task<Void, Never>), stopped }
    private var phase = Phase.idle

    public init(directory: URL = AgentIPCPaths.defaultDirectory, handler: @escaping Handler) {
        self.directory = directory; self.handler = handler
    }
    public func start() throws {
        guard case .idle = phase else { throw AgentIPCError.ownerAlreadyRunning }
        let acquired = try AgentIPCOwner.acquire(directory: directory)
        owner = acquired
        phase = .running
        let listener = acquired.listener
        accepting = Task.detached { [weak self] in
            while !Task.isCancelled {
                do {
                    let client = try await AgentIPCIO.run { try listener.accept(deadline: .now + .seconds(1)) }
                    guard let self else { client.close(); break }
                    await self.admit(client)
                } catch AgentIPCError.timedOut { continue }
                catch AgentIPCAcceptFailure.resourceExhausted {
                    // A readable listener stays readable while accept cannot allocate an FD.
                    // Waiting on POLLIN would spin, so retry at most ten times per second.
                    do { try await Task.sleep(for: .milliseconds(100)) }
                    catch { break }
                } catch { break }
            }
            await self?.acceptLoopEnded()
        }
    }

    /// Terminal accept-loop event. Never await the pump here: it is the caller. Explicit
    /// stop owns its own cleanup; an unexpected exit must not strand a running lease.
    func acceptLoopEnded() {
        guard case .running = phase else { return }
        accepting?.cancel(); accepting = nil
        owner?.listener.close()
        for client in clients.values { client.connection.close(); client.task.cancel() }
        clients.removeAll()
        owner?.close(); owner = nil
        phase = .stopped
    }

    private func admit(_ connection: AgentIPCConnection) {
        guard case .running = phase, clients.count < 4 else { connection.close(); return }
        do { try connection.validatePeer() } catch { connection.close(); return }
        let id = UUID(), handler = self.handler
        // Admission precedes any complete request allocation or invocation of the handler.
        let task = Task.detached { [weak self] in
            do {
                let readDeadline = ContinuousClock.now + .seconds(5)
                let bytes = try await AgentIPCIO.run {
                    try connection.readFrame(maximumBytes: AgentAPIWire.maximumRequestBytes, deadline: readDeadline)
                }
                try Task.checkCancellation()
                let response: AgentAPIResponse
                do {
                    let request = try AgentAPIWire.decodeRequest(bytes)
                    response = await handler(request)
                } catch { response = AgentAPIWire.rejection(error, requestID: AgentAPIWire.requestID(in: bytes)) }
                try Task.checkCancellation()
                let encoded: Data
                do { encoded = try AgentAPIWire.encodeResponse(response) }
                catch { encoded = try AgentAPIWire.encodeResponse(AgentAPIWire.rejection(error, requestID: response.requestID)) }
                try Task.checkCancellation()
                let frame = try AgentIPCConnection.frame(encoded, maximumBytes: AgentAPIWire.maximumResponseBytes)
                let writeDeadline = ContinuousClock.now + .seconds(5)
                try await AgentIPCIO.run { try connection.write(frame, deadline: writeDeadline) }
            } catch { /* A disconnected query never cancels an already accepted business operation. */ }
            connection.close()
            await self?.finished(id)
        }
        clients[id] = Client(connection: connection, task: task)
    }
    private func finished(_ id: UUID) { clients.removeValue(forKey: id) }

    public func stop() async {
        switch phase {
        case .stopped: return
        case .stopping(let cleanup): await cleanup.value; return
        default: break
        }
        let lease = owner
        let pump = accepting
        accepting = nil
        pump?.cancel(); lease?.listener.close()
        for client in clients.values { client.connection.close(); client.task.cancel() }
        clients.removeAll()
        let cleanup = Task {
            await pump?.value
            // Connections close before unlocking. A late handler cannot encode or reuse them.
            lease?.close()
        }
        phase = .stopping(cleanup)
        await cleanup.value
        owner = nil
        phase = .stopped
    }
    deinit {
        accepting?.cancel()
        for client in clients.values { client.connection.close(); client.task.cancel() }
        owner?.close()
    }
}

public struct AgentIPCClient: Sendable {
    private let directory: URL
    public init(directory: URL = AgentIPCPaths.defaultDirectory) { self.directory = directory }
    public func send(_ request: AgentAPIRequest) async throws -> AgentAPIResponse {
        try Task.checkCancellation()
        try AgentIPCIdentity.validateDirectory(directory)
        try AgentIPCIdentity.validateEndpoint(AgentIPCPaths.socketURL(in: directory))
        let connection = try AgentIPCConnection.socket()
        defer { connection.close() }
        return try await withTaskCancellationHandler {
            let connectDeadline = ContinuousClock.now + .seconds(5)
            try await AgentIPCIO.run { try connection.connect(to: AgentIPCPaths.socketURL(in: directory), deadline: connectDeadline) }
            try Task.checkCancellation(); try connection.validatePeer()
            let bytes = try AgentAPIWire.encodeRequest(request)
            let frame = try AgentIPCConnection.frame(bytes, maximumBytes: AgentAPIWire.maximumRequestBytes)
            let writeDeadline = ContinuousClock.now + .seconds(5)
            try await AgentIPCIO.run { try connection.write(frame, deadline: writeDeadline) }
            try Task.checkCancellation()
            let readDeadline = ContinuousClock.now + .seconds(5)
            let received = try await AgentIPCIO.run {
                try connection.readFrame(maximumBytes: AgentAPIWire.maximumResponseBytes, deadline: readDeadline)
            }
            try Task.checkCancellation()
            let response = try AgentAPIWire.decodeResponse(received)
            guard response.requestID == request.requestID else { throw AgentIPCError.invalidFrame }
            return response
        } onCancel: { connection.close() }
    }
}

/// Blocking POSIX readiness is kept off Swift's cooperative pool. The server has one accept
/// operation and at most four connection operations; there is no unbounded request queue.
private enum AgentIPCIO {
    static func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do { continuation.resume(returning: try work()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}

private enum AgentIPCAcceptFailure: Error { case resourceExhausted }

/// Every data syscall holds the descriptor lock. Readiness polling is only a hint; after a
/// concurrent close it can never authorize I/O on a newly reused file descriptor number.
final class AgentIPCConnection: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32
    init(descriptor: Int32) throws {
        self.descriptor = descriptor
        let flags = fcntl(descriptor, F_GETFL)
        var yes: Int32 = 1
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0,
              fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0,
              setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            Darwin.close(descriptor); self.descriptor = -1; throw AgentIPCError.ioFailure
        }
    }
    static func socket() throws -> AgentIPCConnection {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AgentIPCError.unavailable }
        return try AgentIPCConnection(descriptor: fd)
    }
    static func connect(socketURL: URL, deadline: ContinuousClock.Instant) throws -> AgentIPCConnection {
        let connection = try socket()
        do { try connection.connect(to: socketURL, deadline: deadline); return connection }
        catch { connection.close(); throw error }
    }
    func connect(to url: URL, deadline: ContinuousClock.Instant) throws {
        var address = try Self.address(url)
        let result = try withDescriptor { fd in
            withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
        }
        if result != 0 {
            guard errno == EINPROGRESS || errno == EAGAIN || errno == EWOULDBLOCK else { throw AgentIPCError.unavailable }
            try wait(Int16(POLLOUT), deadline: deadline)
            var error: Int32 = 0, length = socklen_t(MemoryLayout<Int32>.size)
            let result = try withDescriptor { getsockopt($0, SOL_SOCKET, SO_ERROR, &error, &length) }
            guard result == 0, error == 0 else { throw AgentIPCError.unavailable }
        }
    }
    static func listen(socketURL: URL) throws -> AgentIPCConnection {
        var address = try address(socketURL)
        let listener = try socket()
        do {
            try listener.withDescriptor { fd in
                let result = withUnsafePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
                }
                guard result == 0, Darwin.listen(fd, 4) == 0 else { throw AgentIPCError.unavailable }
            }
            return listener
        } catch { listener.close(); throw error }
    }
    func accept(deadline: ContinuousClock.Instant) throws -> AgentIPCConnection {
        while true {
            try check(deadline)
            let fd = try withDescriptor { Darwin.accept($0, nil, nil) }
            if fd >= 0 {
                // A peer can disconnect before accepted-socket configuration (Darwin may
                // return EINVAL). That client is already closed by init; keep the listener.
                do { return try AgentIPCConnection(descriptor: fd) }
                catch { continue }
            }
            if errno == EINTR || errno == ECONNABORTED { continue }
            if errno == EMFILE || errno == ENFILE { throw AgentIPCAcceptFailure.resourceExhausted }
            guard errno == EAGAIN || errno == EWOULDBLOCK else { throw AgentIPCError.closed }
            try wait(Int16(POLLIN), deadline: deadline)
        }
    }
    func validatePeer() throws {
        var user: uid_t = 0, group: gid_t = 0
        guard try withDescriptor({ getpeereid($0, &user, &group) }) == 0 else { throw AgentIPCError.peerRejected }
        try AgentIPCIdentity.validateUser(user)
    }
    static func frame(_ bytes: Data, maximumBytes: Int) throws -> Data {
        guard !bytes.isEmpty, bytes.count <= maximumBytes, bytes.count <= Int(UInt32.max) else { throw AgentIPCError.invalidFrame }
        var length = UInt32(bytes.count).bigEndian
        var frame = withUnsafeBytes(of: &length) { Data($0) }; frame.append(bytes); return frame
    }
    func readFrame(maximumBytes: Int, deadline: ContinuousClock.Instant) throws -> Data {
        guard maximumBytes > 0 else { throw AgentIPCError.invalidFrame }
        let header = try readExactly(4, deadline: deadline)
        let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length > 0, UInt64(length) <= UInt64(maximumBytes) else { throw AgentIPCError.invalidFrame }
        return try readExactly(Int(length), deadline: deadline)
    }
    private func readExactly(_ count: Int, deadline: ContinuousClock.Instant) throws -> Data {
        var data = Data(count: count), offset = 0
        while offset < count {
            try check(deadline)
            let read = try withDescriptor { fd in
                data.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!.advanced(by: offset), count - offset) }
            }
            if read > 0 { offset += read; continue }
            if read == 0 { throw AgentIPCError.closed }
            if errno == EINTR { continue }
            guard errno == EAGAIN || errno == EWOULDBLOCK else { throw AgentIPCError.ioFailure }
            try wait(Int16(POLLIN), deadline: deadline)
        }
        try check(deadline)
        return data
    }
    func write(_ data: Data, deadline: ContinuousClock.Instant) throws {
        var offset = 0
        while offset < data.count {
            try check(deadline)
            let written = try withDescriptor { fd in
                data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: offset), data.count - offset) }
            }
            if written > 0 { offset += written; continue }
            if written == 0 { throw AgentIPCError.closed }
            if errno == EINTR { continue }
            guard errno == EAGAIN || errno == EWOULDBLOCK else { throw AgentIPCError.ioFailure }
            try wait(Int16(POLLOUT), deadline: deadline)
        }
        try check(deadline)
    }
    private func wait(_ events: Int16, deadline: ContinuousClock.Instant) throws {
        try check(deadline)
        let fd = try withDescriptor { $0 }
        let remaining = ContinuousClock.now.duration(to: deadline).components
        let milliseconds = Int(max(1, min(50, ceil((Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18) * 1000))))
        var pollDescriptor = pollfd(fd: fd, events: events, revents: 0)
        let result = Darwin.poll(&pollDescriptor, 1, Int32(milliseconds))
        if result < 0, errno != EINTR { throw AgentIPCError.ioFailure }
        if pollDescriptor.revents & Int16(POLLNVAL) != 0 { throw AgentIPCError.closed }
        try check(deadline)
    }
    private func check(_ deadline: ContinuousClock.Instant) throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw AgentIPCError.timedOut }
        _ = try withDescriptor { $0 }
    }
    private func withDescriptor<T>(_ body: (Int32) throws -> T) throws -> T {
        try lock.withLock {
            guard descriptor >= 0 else { throw AgentIPCError.closed }
            return try body(descriptor)
        }
    }
    func close() {
        lock.withLock {
            guard descriptor >= 0 else { return }
            let fd = descriptor; descriptor = -1
            _ = Darwin.shutdown(fd, SHUT_RDWR); Darwin.close(fd)
        }
    }
    deinit { close() }
    private static func address(_ url: URL) throws -> sockaddr_un {
        let path = url.path
        var address = sockaddr_un()
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard url.isFileURL, path.hasPrefix("/"), !path.utf8.contains(0), path.utf8.count < capacity else { throw AgentIPCError.invalidPath }
        address.sun_family = sa_family_t(AF_UNIX); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.initializeMemory(as: UInt8.self, repeating: 0)
            buffer.copyBytes(from: Array(path.utf8))
        }
        return address
    }
}

/// These checks consume OS-returned UID/stat values, never identity supplied by a client.
enum AgentIPCIdentity {
    static func validateUser(_ user: uid_t) throws { guard user == geteuid() else { throw AgentIPCError.peerRejected } }
    static func validateDirectory(_ directory: URL) throws {
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == geteuid(), info.st_mode & 0o777 == 0o700 else { throw AgentIPCError.unsafeDirectory }
    }
    static func validateEndpoint(_ endpoint: URL) throws {
        var info = stat()
        guard lstat(endpoint.path, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK,
              info.st_uid == geteuid(), info.st_mode & 0o777 == 0o600 else { throw AgentIPCError.unsafeEndpoint }
    }
}

/// The fixed lock inode remains on disk for the app lifetime and subsequent launches. Only
/// its current holder may remove an owned stale socket, and teardown compares endpoint inode.
private final class AgentIPCOwner: @unchecked Sendable {
    let listener: AgentIPCConnection
    private let lock = NSLock()
    private var directoryFD: Int32
    private var lockFD: Int32
    private let lockIdentity: FileIdentity
    private let endpointIdentity: FileIdentity
    private struct FileIdentity: Equatable { let device: dev_t; let inode: ino_t; init(_ value: stat) { device = value.st_dev; inode = value.st_ino } }

    private init(listener: AgentIPCConnection, directoryFD: Int32, lockFD: Int32, lockIdentity: FileIdentity, endpointIdentity: FileIdentity) {
        self.listener = listener; self.directoryFD = directoryFD; self.lockFD = lockFD
        self.lockIdentity = lockIdentity; self.endpointIdentity = endpointIdentity
    }
    static func acquire(directory: URL) throws -> AgentIPCOwner {
        guard directory.isFileURL, directory.path.hasPrefix("/"), !directory.path.utf8.contains(0) else { throw AgentIPCError.invalidPath }
        if mkdir(directory.path, 0o700) != 0, errno != EEXIST { throw AgentIPCError.unsafeDirectory }
        try AgentIPCIdentity.validateDirectory(directory)
        let directoryFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else { throw AgentIPCError.unsafeDirectory }
        var lockFD: Int32 = -1, listener: AgentIPCConnection?, created: FileIdentity?
        var acquiredLock = false, committed = false
        defer {
            if !committed {
                listener?.close()
                if let created { removeEndpoint(directoryFD: directoryFD, identity: created) }
                if lockFD >= 0 { if acquiredLock { _ = flock(lockFD, LOCK_UN) }; Darwin.close(lockFD) }
                Darwin.close(directoryFD)
            }
        }
        var info = stat()
        guard fstat(directoryFD, &info) == 0, info.st_uid == geteuid(), info.st_mode & S_IFMT == S_IFDIR,
              info.st_mode & 0o777 == 0o700 else { throw AgentIPCError.unsafeDirectory }
        lockFD = openat(directoryFD, "owner.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard lockFD >= 0, fstat(lockFD, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(), info.st_mode & 0o777 == 0o600, info.st_nlink == 1 else { throw AgentIPCError.unsafeLock }
        let lockIdentity = FileIdentity(info)
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw AgentIPCError.ownerAlreadyRunning }
        acquiredLock = true
        guard fstatat(directoryFD, "owner.lock", &info, AT_SYMLINK_NOFOLLOW) == 0, FileIdentity(info) == lockIdentity else { throw AgentIPCError.unsafeLock }
        let existing = fstatat(directoryFD, "agent.sock", &info, AT_SYMLINK_NOFOLLOW)
        if existing == 0 {
            guard info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == geteuid() else { throw AgentIPCError.unsafeEndpoint }
            guard unlinkat(directoryFD, "agent.sock", 0) == 0 else { throw AgentIPCError.unsafeEndpoint }
        } else if errno != ENOENT { throw AgentIPCError.unsafeEndpoint }
        let bound = try AgentIPCConnection.listen(socketURL: AgentIPCPaths.socketURL(in: directory))
        listener = bound
        guard fstatat(directoryFD, "agent.sock", &info, AT_SYMLINK_NOFOLLOW) == 0,
              info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == geteuid() else { throw AgentIPCError.unsafeEndpoint }
        created = FileIdentity(info)
        guard fchmodat(directoryFD, "agent.sock", 0o600, 0) == 0 else { throw AgentIPCError.unsafeEndpoint }
        committed = true
        return AgentIPCOwner(listener: bound, directoryFD: directoryFD, lockFD: lockFD,
            lockIdentity: lockIdentity, endpointIdentity: FileIdentity(info))
    }
    func close() {
        lock.withLock {
            guard lockFD >= 0 else { return }
            listener.close()
            var current = stat()
            if fstatat(directoryFD, "owner.lock", &current, AT_SYMLINK_NOFOLLOW) == 0, FileIdentity(current) == lockIdentity {
                Self.removeEndpoint(directoryFD: directoryFD, identity: endpointIdentity)
            }
            _ = flock(lockFD, LOCK_UN); Darwin.close(lockFD); lockFD = -1
            Darwin.close(directoryFD); directoryFD = -1
        }
    }
    private static func removeEndpoint(directoryFD: Int32, identity: FileIdentity) {
        var current = stat()
        guard fstatat(directoryFD, "agent.sock", &current, AT_SYMLINK_NOFOLLOW) == 0,
              current.st_uid == geteuid(), current.st_mode & S_IFMT == S_IFSOCK, FileIdentity(current) == identity else { return }
        _ = unlinkat(directoryFD, "agent.sock", 0)
    }
    deinit { close() }
}
