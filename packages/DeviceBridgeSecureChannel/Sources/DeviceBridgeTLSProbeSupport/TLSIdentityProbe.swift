import Foundation
import Network
import Security
import DeviceBridgeSecureChannel

/// Opt-in contributor experiment. Fixed public identity frames only; no device-content APIs.
/// One queue owns all mutable network state. The blocking caller must not be the main actor.
public final class TLSIdentityProbe: @unchecked Sendable {
    public enum Mode: String, Sendable { case normal, heartbeat, orphan, invalid, disconnect, partial, sustain }
    public static let helperBuild = "devicebridge-t082-mtls-v1"
    private let queue = DispatchQueue(label: "DeviceBridge.T082.mTLS")
    private let done = DispatchSemaphore(value: 0)
    private var listener: NWListener?
    private var connection: NWConnection?
    private var finished = false
    private var result = "failed"
    private var sequence: UInt32 = 1
    private var canary: Data?
    private var publicRecordURL: URL?
    private let isServer: Bool
    private let lifetimeSeconds: TimeInterval
    private var mode = Mode.normal
    private var leaseSeconds: TimeInterval = 30
    private var timer: DispatchSourceTimer?
    private var requestStarted: TimeInterval = 0
    private var latencies: [Double] = []
    private var lastReplyAt: TimeInterval?
    private var connectedAt: TimeInterval?
    private var closedAt: TimeInterval?
    public var latencyMilliseconds: [Double] { queue.sync { latencies } }
    public var idleBeforeCloseSeconds: TimeInterval { queue.sync { (closedAt ?? 0) - (lastReplyAt ?? closedAt ?? 0) } }
    public var connectedSeconds: TimeInterval { queue.sync { (closedAt ?? 0) - (connectedAt ?? closedAt ?? 0) } }

    public init(isServer: Bool, lifetimeSeconds: TimeInterval = 90) {
        self.isServer = isServer
        self.lifetimeSeconds = max(0.1, min(90, lifetimeSeconds))
    }

    public func serve(port: UInt16, launchID: UUID, hostCertificateDER: Data, recordURL: URL, leaseSeconds: TimeInterval = 30) throws -> String {
        guard isServer, port >= 1024, leaseSeconds > 0, leaseSeconds <= 30 else { throw ProbeError.invalid }
        let identity = try EphemeralTLSIdentity.create()
        let record = try PublicBootstrapRecord.encode(launchID: launchID, hostCertificateDER: hostCertificateDER,
            runnerCertificateDER: identity.certificateDER, helperBuild: Self.helperBuild)
        let parameters = try PinnedTLSParameters.make(identity: identity, peerCertificateDER: hostCertificateDER, queue: queue)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        let listener = try NWListener(using: parameters)
        queue.async { [self] in
            self.listener = listener
            self.leaseSeconds = leaseSeconds
            scheduleTimeout(seconds: 60, reason: "startupExpired")
            publicRecordURL = recordURL
            listener.newConnectionHandler = { [self] incoming in
                guard !finished, connection == nil else { incoming.cancel(); return }
                listener.cancel()
                scheduleTimeout(seconds: 10, reason: "handshakeExpired")
                start(incoming)
            }
            listener.stateUpdateHandler = { [self] state in
                guard !finished else { return }
                switch state {
                case .ready:
                    do {
                        try FileManager.default.createDirectory(at: recordURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try record.write(to: recordURL, options: .atomic)
                    } catch { finish("publicationFailed") }
                case .failed: finish("listenFailed")
                default: break
                }
            }
            listener.start(queue: queue)
        }
        return waitForCompletion()
    }

    public func exchange(port: UInt16, identity: EphemeralTLSIdentity, peerCertificateDER: Data, publicCanary: String, mode: Mode = .normal) throws -> String {
        guard !isServer, port >= 1024, publicCanary.utf8.count == 32 else { throw ProbeError.invalid }
        let parameters = try PinnedTLSParameters.make(identity: identity, peerCertificateDER: peerCertificateDER, queue: queue)
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: parameters)
        queue.async { [self] in
            canary = Data(publicCanary.utf8)
            self.mode = mode
            start(connection)
        }
        return waitForCompletion()
    }

    private func waitForCompletion() -> String {
        // Scheduled experiment deadline independent of certificate validity/client traffic.
        // The owning harness also caps child waits: blocked system/file I/O can delay queue cleanup.
        if done.wait(timeout: .now() + lifetimeSeconds) == .timedOut { queue.sync { finish("deadlineExpired") } }
        return queue.sync { result }
    }

    private func start(_ connection: NWConnection) {
        self.connection = connection
        connection.stateUpdateHandler = { [self] state in
            guard !finished else { return }
            switch state {
            case .ready:
                connectedAt = ProcessInfo.processInfo.systemUptime
                guard let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata,
                      sec_protocol_metadata_get_negotiated_tls_protocol_version(metadata.securityProtocolMetadata) == .TLSv13,
                      !sec_protocol_metadata_get_early_data_accepted(metadata.securityProtocolMetadata) else {
                    finish("protocolRejected"); return
                }
                if isServer {
                    scheduleTimeout(seconds: leaseSeconds, reason: "leaseExpired")
                    receive()
                } else { sendRequest() }
            case .failed: finish("connectionRejected")
            default: break
            }
        }
        connection.start(queue: queue)
    }

    private func frame() -> Data {
        var number = sequence.bigEndian
        return Data("DBP1".utf8) + withUnsafeBytes(of: &number) { Data($0) } + (canary ?? Data())
    }

    private func sendRequest() {
        requestStarted = ProcessInfo.processInfo.systemUptime
        connection?.send(content: frame(), completion: .contentProcessed { [self] error in
            guard !finished, error == nil else { finish("sendFailed"); return }
            receive()
        })
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 40, maximumLength: 40) { [self] data, _, _, error in
            guard !finished else { return }
            guard error == nil, let data, data.count == 40 else { finish("peerClosed"); return }
            if isServer && canary == nil {
                let bytes = data.suffix(32)
                guard bytes.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { finish("invalidFrame"); return }
                canary = Data(bytes)
            }
            guard data == frame() else { finish("invalidFrame"); return }
            if isServer {
                // Only a complete, valid frame renews the idle lease.
                scheduleTimeout(seconds: leaseSeconds, reason: "leaseExpired")
                connection?.send(content: data, completion: .contentProcessed { [self] error in
                    guard !finished, error == nil else { finish("sendFailed"); return }
                    advance()
                })
            } else {
                latencies.append((ProcessInfo.processInfo.systemUptime - requestStarted) * 1000)
                lastReplyAt = ProcessInfo.processInfo.systemUptime
                advance()
            }
        }
    }

    private func advance() {
        if sequence == 31 { finish("tls13-31-exchanges"); return }
        sequence += 1
        if isServer { receive(); return }
        if sequence == 31 {
            switch mode {
            case .orphan: receive(); return
            case .partial:
                connection?.send(content: frame().prefix(20), completion: .contentProcessed { [self] error in
                    guard !finished, error == nil else { finish("sendFailed"); return }
                    receive()
                })
                return
            case .invalid:
                connection?.send(content: Data(repeating: 0, count: 40), completion: .contentProcessed { [self] error in
                    guard !finished, error == nil else { finish("sendFailed"); return }
                    receive()
                })
                return
            case .disconnect: finish("clientDisconnected"); return
            default: break
            }
        }
        if (mode == .heartbeat && sequence >= 24) || mode == .sustain {
            queue.asyncAfter(deadline: .now() + (mode == .sustain ? 0.05 : 5)) { [self] in
                guard !finished else { return }
                sendRequest()
            }
        } else { sendRequest() }
    }

    private func scheduleTimeout(seconds: TimeInterval, reason: String) {
        if timer == nil {
            timer = DispatchSource.makeTimerSource(queue: queue)
            timer?.resume()
        }
        timer?.setEventHandler { [self] in finish(reason) }
        timer?.schedule(deadline: .now() + seconds)
    }

    private func finish(_ status: String) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !finished else { return }
        finished = true
        closedAt = ProcessInfo.processInfo.systemUptime
        result = status
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        listener?.cancel()
        timer?.setEventHandler {}
        timer?.cancel()
        timer = nil
        if let publicRecordURL {
            do { try FileManager.default.removeItem(at: publicRecordURL) }
            catch let error as CocoaError where error.code == .fileNoSuchFile { }
            catch { result = "publicRecordCleanupFailed" }
        }
        canary = nil
        done.signal()
    }

    private enum ProbeError: Error { case invalid }
}
