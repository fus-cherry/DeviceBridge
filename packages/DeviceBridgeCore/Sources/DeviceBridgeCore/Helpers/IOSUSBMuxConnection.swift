import Darwin
import Foundation

/// An exclusively owned USB stream permitting one pending read and one pending write.
/// A private queue owns all descriptor access; readiness sources keep both directions live.
/// Close/cancellation interrupt pending I/O. No descriptor escapes this owner.
/// usbmux success establishes a route only; callers must authenticate the runner using TLS.
public final class IOSUSBMuxConnection: @unchecked Sendable {
    public enum Failure: Error, Equatable, Sendable {
        case invalidInput, unavailable, invalidResponse, routeUnavailable, timedOut, closed, operationInProgress
    }
    private let queue: DispatchQueue
    private let state: SocketState

    private init() {
        queue = DispatchQueue(label: "DeviceBridge.USBMux", qos: .userInitiated)
        state = SocketState(queue: queue)
    }

    public static func connect(hardwareUDID: String, port: UInt16, timeout: TimeInterval = 5) async throws -> IOSUSBMuxConnection {
        try await connect(hardwareUDID: hardwareUDID, port: port, socketPath: "/var/run/usbmuxd", timeout: timeout)
    }

    // Internal endpoint injection keeps tests entirely on synthetic local UNIX sockets.
    static func connect(hardwareUDID: String, port: UInt16, socketPath: String, timeout: TimeInterval) async throws -> IOSUSBMuxConnection {
        guard !hardwareUDID.isEmpty, hardwareUDID.utf8.count <= 128,
              hardwareUDID.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }), port > 0 else { throw Failure.invalidInput }
        let deadline = try makeDeadline(timeout)
        let connection = IOSUSBMuxConnection()
        do {
            try await connection.open(path: socketPath, deadline: deadline)
            let inventory = try await connection.request(["MessageType": "ListDevices"], tag: 1, deadline: deadline)
            let handle = try selectUSB(inventory, hardwareUDID: hardwareUDID)
            await connection.retireInventory()
            // Removal between inventory and Connect fails; never retry another route.
            try await connection.open(path: socketPath, deadline: deadline)
            let response = try await connection.request(["MessageType": "Connect", "DeviceID": handle, "PortNumber": port.bigEndian], tag: 2, deadline: deadline)
            guard response["MessageType"] as? String == "Result", let result = integer(response["Number"]) else { throw Failure.invalidResponse }
            guard result == 0 else { throw Failure.routeUnavailable }
            try Task.checkCancellation()
            return connection
        } catch {
            await connection.close()
            throw error
        }
    }

    /// Returns one available chunk. EOF and I/O failures permanently close the stream.
    public func read(maxBytes: Int, timeout: TimeInterval = 5) async throws -> Data {
        guard (1...65_536).contains(maxBytes) else { throw Failure.invalidInput }
        return try await read(maxBytes: maxBytes, deadline: Self.makeDeadline(timeout))
    }

    /// Writes a complete chunk. Partial failure closes the stream; callers must not replay it.
    public func write(_ data: Data, timeout: TimeInterval = 5) async throws {
        guard (1...65_536).contains(data.count) else { throw Failure.invalidInput }
        try await write(data, deadline: Self.makeDeadline(timeout))
    }

    /// Clean read EOF returns nil without closing the write direction. The relay owner must
    /// close after both directions finish, or enforce its own bounded teardown timeout.
    /// A finite timeout up to 60 seconds permits a margin beyond the runner's 30-second lease.
    public func readChunk(maxBytes: Int, timeout: TimeInterval = 5) async throws -> Data? {
        guard (1...65_536).contains(maxBytes) else { throw Failure.invalidInput }
        return try await readChunk(maxBytes: maxBytes, deadline: Self.makeDeadline(timeout, maximum: 60))
    }

    /// Sends write EOF while preserving reads. Idempotent while the connection remains open.
    /// A pending write rejects this call without cancelling that write or closing the stream.
    public func finishWriting() async throws {
        let finished: Bool = try await perform { state, success, _ in success(try state.finishWriting()) }
        guard finished else { throw Failure.operationInProgress }
    }

    /// Returns after source cancellation handlers have released the owned descriptor.
    public func close() async {
        await withCheckedContinuation { continuation in
            queue.async { [state] in state.close { continuation.resume() } }
        }
    }

    deinit { queue.async { [state] in state.close {} } }

    private func retireInventory() async {
        await withCheckedContinuation { continuation in
            queue.async { [state] in state.retire { continuation.resume() } }
        }
    }

    private func perform<T: Sendable>(_ operation: @escaping @Sendable (SocketState, @escaping @Sendable (T) -> Void, @escaping @Sendable (Error) -> Void) throws -> Void) async throws -> T {
        do {
            try Task.checkCancellation()
            let result: T = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    queue.async { [state] in
                        do {
                            guard !state.closed else { throw Failure.closed }
                            try operation(state, { continuation.resume(returning: $0) }, { continuation.resume(throwing: $0) })
                        } catch { continuation.resume(throwing: error) }
                    }
                }
            } onCancel: { queue.async { [state] in state.close {} } }
            try Task.checkCancellation()
            return result
        } catch {
            await close()
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    private func open(path: String, deadline: UInt64) async throws {
        try await perform { state, success, failure in try state.open(path: path, deadline: deadline, success: { success(()) }, failure: failure) }
    }

    private func read(maxBytes: Int, deadline: UInt64) async throws -> Data {
        guard let bytes = try await readChunk(maxBytes: maxBytes, deadline: deadline) else {
            await close()
            throw Failure.closed
        }
        return bytes
    }

    private func readChunk(maxBytes: Int, deadline: UInt64) async throws -> Data? {
        try await perform { state, success, failure in
            try state.start(.read, deadline: deadline, failure: failure) {
                var bytes = [UInt8](repeating: 0, count: maxBytes)
                let count = recv(try state.descriptor(), &bytes, bytes.count, 0)
                if count < 0, errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { return false }
                guard count >= 0 else { throw Failure.unavailable }
                success(count == 0 ? nil : Data(bytes.prefix(count)))
                return true
            }
        }
    }

    private func write(_ data: Data, deadline: UInt64) async throws {
        try await perform { state, success, failure in
            var offset = 0 // Queue-confined, retained by this direction's readiness callback.
            try state.start(.write, deadline: deadline, failure: failure) {
                let count = try data.withUnsafeBytes { bytes in
                    send(try state.descriptor(), bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
                }
                if count < 0, errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { return false }
                guard count > 0 else { throw Failure.unavailable }
                offset += count
                guard offset == data.count else { return false }
                success(())
                return true
            }
        }
    }

    private func readExactly(_ length: Int, deadline: UInt64) async throws -> Data {
        var bytes = Data()
        while bytes.count < length { bytes.append(try await read(maxBytes: min(65_536, length - bytes.count), deadline: deadline)) }
        return bytes
    }

    private func request(_ body: [String: Any], tag: UInt32, deadline: UInt64) async throws -> [String: Any] {
        var request = body
        request["ClientVersionString"] = "DeviceBridge"
        request["ProgName"] = "DeviceBridge"
        request["kLibUSBMuxVersion"] = 3
        let payload: Data
        do { payload = try PropertyListSerialization.data(fromPropertyList: request, format: .xml, options: 0) }
        catch { throw Failure.invalidInput }
        guard payload.count <= 1_048_560 else { throw Failure.invalidInput }
        var frame = Data()
        for word: UInt32 in [UInt32(payload.count + 16), 1, 8, tag] {
            var little = word.littleEndian
            withUnsafeBytes(of: &little) { frame.append(contentsOf: $0) }
        }
        frame.append(payload)
        try await write(frame, deadline: deadline)
        let header = try await readExactly(16, deadline: deadline)
        let words = header.withUnsafeBytes { bytes in
            (0..<4).map { UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self)) }
        }
        guard (16...1_048_576).contains(words[0]), words[1] == 1, words[2] == 8, words[3] == tag else { throw Failure.invalidResponse }
        let response = try await readExactly(Int(words[0]) - 16, deadline: deadline)
        do {
            guard let dictionary = try PropertyListSerialization.propertyList(from: response, format: nil) as? [String: Any] else { throw Failure.invalidResponse }
            try Self.checkDeadline(deadline)
            return dictionary
        } catch let failure as Failure { throw failure }
        catch { throw Failure.invalidResponse }
    }

    private static func makeDeadline(_ seconds: TimeInterval, maximum: TimeInterval = 30) throws -> UInt64 {
        guard seconds.isFinite, seconds > 0, seconds <= maximum else { throw Failure.invalidInput }
        return DispatchTime.now().uptimeNanoseconds + UInt64(seconds * 1_000_000_000)
    }

    private static func checkDeadline(_ deadline: UInt64) throws {
        guard DispatchTime.now().uptimeNanoseconds < deadline else { throw Failure.timedOut }
    }

    private static func integer(_ value: Any?) -> UInt32? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              !["f", "d"].contains(String(cString: number.objCType)),
              number.int64Value >= 0, number.uint64Value <= UInt32.max else { return nil }
        return number.uint32Value
    }

    private static func canonicalUDID(_ value: String) -> String {
        // Pinned libusbmuxd spelling normalization; no prefix/case-insensitive matching.
        if value.utf8.count == 24, value.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) {
            return String(value.prefix(8)) + "-" + String(value.dropFirst(8))
        }
        return value
    }

    private static func selectUSB(_ inventory: [String: Any], hardwareUDID: String) throws -> UInt32 {
        guard let devices = inventory["DeviceList"] as? [[String: Any]], devices.count <= 1024 else { throw Failure.invalidResponse }
        var matches: [UInt32] = []
        for device in devices {
            guard let properties = device["Properties"] as? [String: Any],
                  let serial = properties["SerialNumber"] as? String, !serial.isEmpty, serial.utf8.count <= 128,
                  let type = properties["ConnectionType"] as? String,
                  let handle = integer(properties["DeviceID"]), handle > 0 else { throw Failure.invalidResponse }
            if let outerHandle = device["DeviceID"] {
                guard integer(outerHandle) == handle else { throw Failure.invalidResponse }
            }
            if canonicalUDID(serial) == canonicalUDID(hardwareUDID), type == "USB" { matches.append(handle) }
        }
        guard matches.count == 1 else { throw Failure.routeUnavailable }
        return matches[0]
    }

    /// Queue-confined state. Source lifetimes retain fd until both cancel handlers finish.
    private final class SocketState: @unchecked Sendable {
        enum Direction: CaseIterable { case read, write }
        private let queue: DispatchQueue
        private var lifetime: SocketLifetime?
        private var sources: [Direction: SourceSlot] = [:]
        private var pending: [Direction: Pending] = [:]
        private var writingFinished = false
        private(set) var closed = false

        init(queue: DispatchQueue) { self.queue = queue }

        func descriptor() throws -> Int32 {
            guard !closed, let lifetime, !lifetime.retiring else { throw Failure.closed }
            return lifetime.descriptor
        }

        func finishWriting() throws -> Bool {
            let fd = try descriptor()
            guard pending[.write] == nil else { return false }
            guard !writingFinished else { return true }
            guard shutdown(fd, SHUT_WR) == 0 else { throw Failure.unavailable }
            writingFinished = true
            return true
        }

        func close(completion: @escaping @Sendable () -> Void) {
            closed = true
            let operations = pending.values
            pending.removeAll()
            for operation in operations { operation.timer.cancel(); operation.failure(Failure.closed) }
            retire(completion: completion)
        }

        func retire(completion: @escaping @Sendable () -> Void) {
            guard let lifetime else { completion(); return }
            lifetime.completions.append(completion)
            guard !lifetime.retiring else { return }
            lifetime.retiring = true
            for slot in sources.values {
                // Balance suspension before releasing a cancelled source.
                if slot.suspended { slot.source.resume(); slot.suspended = false }
                slot.source.cancel()
            }
            sources.removeAll()
        }

        func open(path: String, deadline: UInt64, success: @escaping @Sendable () -> Void, failure: @escaping @Sendable (Error) -> Void) throws {
            guard !closed, lifetime == nil else { throw Failure.closed }
            try checkDeadline(deadline)
            var address = sockaddr_un()
            let bytes = Array(path.utf8)
            guard !bytes.isEmpty, !bytes.contains(0), bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw Failure.invalidInput }
            address.sun_family = sa_family_t(AF_UNIX)
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes + [0]) }
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw Failure.unavailable }
            var enabled: Int32 = 1
            guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0, fcntl(fd, F_SETFD, FD_CLOEXEC) == 0,
                  setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
                Darwin.close(fd)
                throw Failure.unavailable
            }
            let owner = SocketLifetime(descriptor: fd)
            lifetime = owner
            writingFinished = false
            for direction in Direction.allCases {
                let source: any DispatchSourceProtocol
                if direction == .read { source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue) }
                else { source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue) }
                source.setEventHandler { [weak self, owner] in
                    guard let self, self.lifetime === owner, !owner.retiring else { return }
                    self.advance(direction)
                }
                source.setCancelHandler { [self, owner] in
                    owner.remainingSources -= 1
                    if owner.remainingSources == 0 {
                        Darwin.close(owner.descriptor) // Exactly once after both sources relinquish fd.
                        if lifetime === owner { lifetime = nil }
                        let completions = owner.completions
                        owner.completions.removeAll()
                        for completion in completions { completion() }
                    }
                }
                sources[direction] = SourceSlot(source: source)
            }
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            if result == 0 { success(); return }
            guard errno == EINPROGRESS else { throw Failure.unavailable }
            try start(.write, deadline: deadline, failure: failure, attemptImmediately: false) {
                var error: Int32 = 0
                var length = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 else { throw Failure.unavailable }
                success()
                return true
            }
        }

        func start(_ direction: Direction, deadline: UInt64, failure: @escaping @Sendable (Error) -> Void, attemptImmediately: Bool = true, attempt: @escaping () throws -> Bool) throws {
            _ = try descriptor()
            guard direction != .write || !writingFinished else { throw Failure.closed }
            try checkDeadline(deadline)
            guard pending[direction] == nil else { throw Failure.operationInProgress }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            let operation = Pending(deadline: deadline, timer: timer, attempt: attempt, failure: failure)
            pending[direction] = operation
            timer.schedule(deadline: DispatchTime(uptimeNanoseconds: deadline))
            timer.setEventHandler { [weak self, weak operation] in
                guard let self, let operation, self.pending[direction] === operation else { return }
                self.fail(direction, error: Failure.timedOut)
            }
            timer.resume()
            if attemptImmediately { advance(direction) }
            if pending[direction] != nil, let slot = sources[direction], slot.suspended {
                slot.suspended = false
                slot.source.resume()
            }
        }

        private func advance(_ direction: Direction) {
            guard let operation = pending[direction] else { return }
            do {
                try checkDeadline(operation.deadline)
                if try operation.attempt() { remove(direction) }
            } catch { fail(direction, error: error) }
        }

        private func remove(_ direction: Direction) {
            pending.removeValue(forKey: direction)?.timer.cancel()
            if let slot = sources[direction], !slot.suspended { slot.suspended = true; slot.source.suspend() }
        }

        private func fail(_ direction: Direction, error: Error) {
            let failure = pending[direction]?.failure
            remove(direction)
            failure?(error)
            close {}
        }
    }

    // All holders below are accessed only on SocketState.queue, including source callbacks.
    private final class SocketLifetime: @unchecked Sendable {
        let descriptor: Int32
        var remainingSources = 2
        var retiring = false
        var completions: [@Sendable () -> Void] = []
        init(descriptor: Int32) { self.descriptor = descriptor }
    }

    private final class SourceSlot {
        let source: any DispatchSourceProtocol
        var suspended = true
        init(source: any DispatchSourceProtocol) { self.source = source }
    }

    private final class Pending: @unchecked Sendable {
        let deadline: UInt64
        let timer: any DispatchSourceTimer
        let attempt: () throws -> Bool
        let failure: @Sendable (Error) -> Void
        init(deadline: UInt64, timer: any DispatchSourceTimer, attempt: @escaping () throws -> Bool, failure: @escaping @Sendable (Error) -> Void) {
            self.deadline = deadline
            self.timer = timer
            self.attempt = attempt
            self.failure = failure
        }
    }
}
