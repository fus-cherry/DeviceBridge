import Foundation
import Network
import Security
import DeviceBridgeProtocol

/// Mutually pinned TLS 1.3 framing over IPv4 loopback. Successful construction verifies the
/// peer certificate, not application build/device/launch identity or a session nonce.
/// One read and one write can overlap. All I/O failure, cancellation and close are terminal.
public final class PinnedTLSFrameStream: @unchecked Sendable {
    public enum Failure: Error, Equatable, Sendable {
        case invalidInput, authenticationFailed, protocolRejected, connectionFailed, timedOut, closed, operationInProgress, invalidFrameLength, truncatedFrame
    }
    public final class Listener: Sendable {
        public let port: UInt16
        private let stream: PinnedTLSFrameStream

        fileprivate init(port: UInt16, stream: PinnedTLSFrameStream) { self.port = port; self.stream = stream }

        /// Exactly one caller may claim the accepted stream. Dropping this listener afterwards
        /// leaves the returned stream alive; dropping it before acceptance closes its candidate.
        public func accept() async throws -> PinnedTLSFrameStream {
            let _: Void = try await stream.perform { owner, success, failure in
                try owner.accept(success: { success(()) }, failure: failure)
            }
            return stream
        }
        public func close() async { await stream.close() }
    }

    private let owner = Owner()
    private init() {}

    public static func connect(localPort: UInt16, identity: EphemeralTLSIdentity, peerCertificateDER: Data, handshakeTimeout: TimeInterval = 10) async throws -> PinnedTLSFrameStream {
        guard localPort > 0 else { throw Failure.invalidInput }
        let deadline = try deadline(after: handshakeTimeout)
        let stream = PinnedTLSFrameStream()
        let _: Void = try await stream.perform { owner, success, failure in
            try owner.connect(port: localPort, identity: identity, pin: peerCertificateDER,
                deadline: deadline, success: { success(()) }, failure: failure)
        }
        return stream
    }

    public static func listen(localPort: UInt16 = 0, identity: EphemeralTLSIdentity, peerCertificateDER: Data, acceptTimeout: TimeInterval = 60, handshakeTimeout: TimeInterval = 10) async throws -> Listener {
        _ = try deadline(after: acceptTimeout)
        let startupDeadline = try deadline(after: handshakeTimeout)
        let stream = PinnedTLSFrameStream()
        let port: UInt16 = try await stream.perform { owner, success, failure in
            try owner.listen(port: localPort, identity: identity, pin: peerCertificateDER,
                startupDeadline: startupDeadline, acceptTimeout: acceptTimeout, handshakeTimeout: handshakeTimeout,
                success: success, failure: failure)
        }
        return Listener(port: port, stream: stream)
    }

    /// Empty frames are preserved, matching HelperFrameCodec; application JSON validation must
    /// reject them. Partial header/body EOF fails rather than yielding a partial frame.
    public func readFrame(timeout: TimeInterval = 30) async throws -> Data {
        let deadline = try Self.deadline(after: timeout)
        return try await perform { owner, success, failure in try owner.beginRead(deadline: deadline, success: success, failure: failure) }
    }

    public func writeFrame(_ payload: Data, timeout: TimeInterval = 30) async throws {
        let deadline = try Self.deadline(after: timeout)
        guard payload.count <= HelperWireCodec.maximumEnvelopeBytes else { throw Failure.invalidFrameLength }
        let frame = try HelperFrameCodec.encode(payload)
        let _: Void = try await perform { owner, success, failure in
            try owner.beginWrite(frame, deadline: deadline, success: { success(()) }, failure: failure)
        }
    }

    /// Invalidates pending operations and submits NW.cancel on the owning queue. This does not
    /// await physical descriptor release or a graceful TLS/TCP shutdown.
    public func close() async {
        await withCheckedContinuation { continuation in
            owner.queue.async { [owner] in owner.close(); continuation.resume() }
        }
    }

    deinit { owner.queue.async { [owner] in owner.close() } }

    private func perform<T: Sendable>(_ operation: @escaping @Sendable (Owner, @escaping @Sendable (T) -> Void, @escaping @Sendable (Error) -> Void) throws -> Void) async throws -> T {
        do {
            try Task.checkCancellation()
            let value: T = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    owner.queue.async { [owner] in
                        do { try operation(owner, { continuation.resume(returning: $0) }, { continuation.resume(throwing: $0) }) }
                        catch { continuation.resume(throwing: error) }
                    }
                }
            } onCancel: { owner.queue.async { [owner] in owner.close() } }
            try Task.checkCancellation()
            return value
        } catch {
            await close()
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    private static func deadline(after seconds: TimeInterval) throws -> DispatchTime {
        guard seconds.isFinite, seconds > 0, seconds <= 60 else { throw Failure.invalidInput }
        return .now() + seconds
    }

    private static func check(_ deadline: DispatchTime) throws {
        guard DispatchTime.now() < deadline else { throw Failure.timedOut }
    }

    private static func map(_ error: NWError) -> Failure {
        if case .tls(let status) = error,
           [errSSLBadCert, errSSLXCertChainInvalid, errSSLPeerBadCert, errSSLPeerCertUnknown,
            errSSLPeerUnknownCA, errSSLCertificateRequired].contains(status) { return .authenticationFailed }
        return .connectionFailed
    }

    /// The sole lifecycle writer. Network callbacks and timers run only on this private queue.
    private final class Owner: @unchecked Sendable {
        enum Phase { case idle, listening, handshaking, ready, closed }
        let queue = DispatchQueue(label: "DeviceBridge.PinnedTLSFrames", qos: .userInitiated)
        private var phase = Phase.idle
        private var terminalFailure = Failure.closed
        private var listener: NWListener?
        private var connection: NWConnection?
        private var lifecycleTimer: DispatchSourceTimer?
        private var lifecycleGeneration: UUID?
        private var lifecycleDeadline = TLSLifecycleDeadline()
        private var listeningCompletion: (@Sendable (UInt16) -> Void)?
        private var listeningFailure: (@Sendable (Error) -> Void)?
        private var readyCompletion: (@Sendable () -> Void)?
        private var readyFailure: (@Sendable (Error) -> Void)?
        private var acceptClaimed = false
        private var reading: Read?
        private var writing: Write?

        func connect(port: UInt16, identity: EphemeralTLSIdentity, pin: Data, deadline: DispatchTime,
                     success: @escaping @Sendable () -> Void, failure: @escaping @Sendable (Error) -> Void) throws {
            guard phase == .idle else { throw Failure.closed }
            try PinnedTLSFrameStream.check(deadline)
            let parameters: NWParameters
            do { parameters = try PinnedTLSParameters.make(identity: identity, peerCertificateDER: pin, queue: queue) }
            catch { throw Failure.invalidInput }
            let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: parameters)
            // Reserve callbacks only after synchronous setup succeeds; thrown setup errors are
            // completed by perform(), while the registered callbacks belong to network lifetime.
            readyCompletion = success; readyFailure = failure
            start(connection, deadline: deadline)
        }

        func listen(port: UInt16, identity: EphemeralTLSIdentity, pin: Data, startupDeadline: DispatchTime,
                    acceptTimeout: TimeInterval, handshakeTimeout: TimeInterval,
                    success: @escaping @Sendable (UInt16) -> Void, failure: @escaping @Sendable (Error) -> Void) throws {
            guard phase == .idle else { throw Failure.closed }
            let parameters: NWParameters
            do { parameters = try PinnedTLSParameters.make(identity: identity, peerCertificateDER: pin, queue: queue) }
            catch { throw Failure.invalidInput }
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port == 0 ? .any : NWEndpoint.Port(rawValue: port)!)
            let listener = try NWListener(using: parameters)
            self.listener = listener
            phase = .listening
            listeningCompletion = success
            listeningFailure = failure
            guard scheduleLifecycle(startupDeadline) else { return }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self, self.listener === listener, phase == .listening else { return }
                switch state {
                case .ready:
                    guard let completion = listeningCompletion else { return }
                    guard let port = listener.port else { close(.connectionFailed); return }
                    guard scheduleLifecycle(.now() + acceptTimeout) else { return }
                    listeningCompletion = nil; listeningFailure = nil
                    completion(port.rawValue)
                case .failed(let error): close(PinnedTLSFrameStream.map(error))
                case .cancelled: close()
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] incoming in
                guard let self, phase == .listening, connection == nil else { incoming.cancel(); return }
                listener.stateUpdateHandler = nil; listener.newConnectionHandler = nil
                listener.cancel(); self.listener = nil
                start(incoming, deadline: .now() + handshakeTimeout)
            }
            listener.start(queue: queue)
        }

        func accept(success: @escaping @Sendable () -> Void, failure: @escaping @Sendable (Error) -> Void) throws {
            guard !acceptClaimed else { throw Failure.operationInProgress }
            acceptClaimed = true
            if phase == .closed { throw terminalFailure }
            if phase == .ready { success(); return }
            readyCompletion = success; readyFailure = failure
        }

        func start(_ connection: NWConnection, deadline: DispatchTime) {
            guard phase != .closed else { connection.cancel(); return }
            guard scheduleLifecycle(deadline) else { connection.cancel(); return }
            self.connection = connection
            phase = .handshaking
            connection.stateUpdateHandler = { [weak self] state in
                guard let self, self.connection === connection, phase != .closed else { return }
                switch state {
                case .ready:
                    guard phase == .handshaking else { return }
                    do { try lifecycleDeadline.validate(at: .now()) }
                    catch { close(.timedOut); return }
                    guard let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata,
                          sec_protocol_metadata_get_negotiated_tls_protocol_version(metadata.securityProtocolMetadata) == .TLSv13,
                          !sec_protocol_metadata_get_early_data_accepted(metadata.securityProtocolMetadata) else { close(.protocolRejected); return }
                    phase = .ready
                    lifecycleTimer?.cancel(); lifecycleTimer = nil; lifecycleGeneration = nil
                    lifecycleDeadline = TLSLifecycleDeadline()
                    let completion = readyCompletion
                    readyCompletion = nil; readyFailure = nil
                    completion?()
                case .failed(let error), .waiting(let error): close(PinnedTLSFrameStream.map(error))
                case .cancelled: close()
                default: break
                }
            }
            connection.start(queue: queue)
        }

        func beginRead(deadline: DispatchTime, success: @escaping @Sendable (Data) -> Void, failure: @escaping @Sendable (Error) -> Void) throws {
            guard phase == .ready else { throw Failure.closed }
            guard reading == nil else { throw Failure.operationInProgress }
            try PinnedTLSFrameStream.check(deadline)
            let read = Read(deadline: deadline, success: success, failure: failure)
            reading = read
            read.timer = timer(deadline: deadline) { [weak self, weak read] in
                guard let self, let read, reading === read else { return }
                close(.timedOut)
            }
            receive(read)
        }

        private func receive(_ read: Read) {
            guard phase == .ready, reading === read, let connection else { return }
            let remaining = (read.bodyLength ?? 4) - read.bytes.count
            connection.receive(minimumIncompleteLength: 1, maximumLength: min(65_536, remaining)) { [weak self, weak read] data, _, complete, error in
                guard let self, let read, reading === read, phase == .ready else { return }
                guard DispatchTime.now() < read.deadline else { close(.timedOut); return }
                if let error { close(PinnedTLSFrameStream.map(error)); return }
                if let data { read.bytes.append(data) }
                if read.bodyLength == nil, read.bytes.count == 4 {
                    let length = read.bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                    guard length <= HelperWireCodec.maximumEnvelopeBytes else { close(.invalidFrameLength); return }
                    read.bodyLength = Int(length)
                    read.bytes = Data()
                }
                if let length = read.bodyLength, read.bytes.count == length {
                    reading = nil; read.timer?.cancel()
                    read.success(read.bytes)
                } else if complete {
                    close(read.bodyLength == nil && read.bytes.isEmpty ? .closed : .truncatedFrame)
                } else if data?.isEmpty != false {
                    close(.connectionFailed)
                } else { receive(read) }
            }
        }

        func beginWrite(_ frame: Data, deadline: DispatchTime, success: @escaping @Sendable () -> Void, failure: @escaping @Sendable (Error) -> Void) throws {
            guard phase == .ready, let connection else { throw Failure.closed }
            guard writing == nil else { throw Failure.operationInProgress }
            try PinnedTLSFrameStream.check(deadline)
            let write = Write(success: success, failure: failure)
            writing = write
            write.timer = timer(deadline: deadline) { [weak self, weak write] in
                guard let self, let write, writing === write else { return }
                close(.timedOut)
            }
            connection.send(content: frame, completion: .contentProcessed { [weak self, weak write] error in
                guard let self, let write, writing === write, phase == .ready else { return }
                guard DispatchTime.now() < deadline else { close(.timedOut); return }
                if let error { close(PinnedTLSFrameStream.map(error)); return }
                writing = nil; write.timer?.cancel(); write.success()
            })
        }

        private func scheduleLifecycle(_ deadline: DispatchTime) -> Bool {
            do { try lifecycleDeadline.advance(to: deadline, at: .now()) }
            catch { close(.timedOut); return false }
            lifecycleTimer?.cancel()
            let generation = UUID()
            lifecycleGeneration = generation
            lifecycleTimer = timer(deadline: deadline) { [weak self] in
                guard let self, lifecycleGeneration == generation else { return }
                close(.timedOut)
            }
            return true
        }

        private func timer(deadline: DispatchTime, action: @escaping @Sendable () -> Void) -> DispatchSourceTimer {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: deadline)
            timer.setEventHandler(handler: action)
            timer.resume()
            return timer
        }

        func close(_ reason: Failure = .closed) {
            guard phase != .closed else { return }
            phase = .closed; terminalFailure = reason
            lifecycleGeneration = nil; lifecycleTimer?.cancel(); lifecycleTimer = nil
            lifecycleDeadline = TLSLifecycleDeadline()
            listener?.stateUpdateHandler = nil; listener?.newConnectionHandler = nil
            listener?.cancel(); listener = nil
            connection?.stateUpdateHandler = nil; connection?.cancel(); connection = nil
            let listenFailure = listeningFailure, handshakeFailure = readyFailure
            listeningCompletion = nil; listeningFailure = nil; readyCompletion = nil; readyFailure = nil
            let read = reading, write = writing
            reading = nil; writing = nil
            read?.timer?.cancel(); write?.timer?.cancel()
            listenFailure?(reason); handshakeFailure?(reason); read?.failure(reason); write?.failure(reason)
        }
    }

    // Operation identity guards discard callbacks arriving after cancellation/replacement.
    private final class Read: @unchecked Sendable {
        let deadline: DispatchTime
        let success: @Sendable (Data) -> Void
        let failure: @Sendable (Error) -> Void
        var bytes = Data()
        var bodyLength: Int?
        var timer: DispatchSourceTimer?
        init(deadline: DispatchTime, success: @escaping @Sendable (Data) -> Void, failure: @escaping @Sendable (Error) -> Void) {
            self.deadline = deadline; self.success = success; self.failure = failure
        }
    }

    private final class Write: @unchecked Sendable {
        let success: @Sendable () -> Void
        let failure: @Sendable (Error) -> Void
        var timer: DispatchSourceTimer?
        init(success: @escaping @Sendable () -> Void, failure: @escaping @Sendable (Error) -> Void) { self.success = success; self.failure = failure }
    }
}

/// Queue-confined absolute TLS phase deadline. Timer delivery is only a wake-up mechanism;
/// synchronous phase transitions must consult this value before replacing the timer.
struct TLSLifecycleDeadline {
    private(set) var current: DispatchTime?

    mutating func advance(to replacement: DispatchTime, at now: DispatchTime) throws {
        if current != nil { try validate(at: now) }
        guard now < replacement else { throw PinnedTLSFrameStream.Failure.timedOut }
        current = replacement
    }

    func validate(at now: DispatchTime) throws {
        guard let current, now < current else { throw PinnedTLSFrameStream.Failure.timedOut }
    }
}
