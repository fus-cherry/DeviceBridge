import Foundation
import Network
import Security
import Testing
@testable import DeviceBridgeSecureChannel

struct PinnedTLSParametersTests {
    @Test func mutualPinsExchangeOnlyOverTLS13() throws {
        #expect(try TLSPair.exchange(.matching) == .exchanged)
    }

    @Test(arguments: [TLSPair.Mode.wrongServer, .wrongClient, .missingClient])
    fileprivate func untrustedPeersCannotExchange(mode: TLSPair.Mode) throws {
        let outcome = try TLSPair.exchange(mode)
        #expect(outcome == .authenticationRejected)
    }
}

// A real local Network.framework connection pair. No desktop UI or phone interaction.
private final class TLSPair: @unchecked Sendable {
    enum Mode: Sendable { case matching, wrongServer, wrongClient, missingClient }
    enum Outcome: Equatable { case exchanged, authenticationRejected, failed, timeout }
    let queue = DispatchQueue(label: "DeviceBridge.TLS.test")
    let done = DispatchSemaphore(value: 0)
    var outcome = Outcome.failed
    var finished = false
    var listener: NWListener?
    var client: NWConnection?
    var server: NWConnection?
    var serverReady = false
    var mode = Mode.matching
    let payload = Data("public-TLS-identity-test".utf8)

    static func exchange(_ mode: Mode) throws -> Outcome {
        let pair = TLSPair()
        pair.mode = mode
        let serverIdentity = try EphemeralTLSIdentity.create()
        let clientIdentity = try EphemeralTLSIdentity.create()
        let wrongIdentity = try EphemeralTLSIdentity.create()
        let serverParameters = try PinnedTLSParameters.make(identity: serverIdentity,
            peerCertificateDER: mode == .wrongClient ? wrongIdentity.certificateDER : clientIdentity.certificateDER, queue: pair.queue)
        let clientParameters = try PinnedTLSParameters.make(identity: mode == .missingClient ? nil : clientIdentity,
            peerCertificateDER: mode == .wrongServer ? wrongIdentity.certificateDER : serverIdentity.certificateDER, queue: pair.queue)
        serverParameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: serverParameters)
        pair.queue.async { pair.start(listener, clientParameters: clientParameters) }
        if pair.done.wait(timeout: .now() + 10) == .timedOut {
            pair.queue.sync { pair.finish(.timeout) }
        }
        return pair.queue.sync { pair.outcome }
    }

    func start(_ listener: NWListener, clientParameters: NWParameters) {
        self.listener = listener
        listener.newConnectionHandler = { [self] connection in
            guard server == nil, !finished else { connection.cancel(); return }
            server = connection
            connection.stateUpdateHandler = { [self] state in
                guard !finished else { return }
                switch state {
                case .ready:
                    serverReady = true
                    guard Self.isTLS13(connection) else { finish(.failed); return }
                    connection.receive(minimumIncompleteLength: payload.count, maximumLength: payload.count) { [self] data, _, _, error in
                        guard !finished, error == nil, data == payload else { finish(.failed); return }
                        connection.send(content: payload, completion: .contentProcessed { [self] error in
                            if error != nil { finish(.failed) }
                        })
                    }
                case .failed(let error): fail(error)
                default: break
                }
            }
            connection.start(queue: queue)
        }
        listener.stateUpdateHandler = { [self] state in
            guard !finished else { return }
            switch state {
            case .ready:
                guard let port = listener.port else { finish(.failed); return }
                let connection = NWConnection(host: "127.0.0.1", port: port, using: clientParameters)
                client = connection
                connection.stateUpdateHandler = { [self] state in
                    guard !finished else { return }
                    switch state {
                    case .ready:
                        guard Self.isTLS13(connection) else { finish(.failed); return }
                        connection.send(content: payload, completion: .contentProcessed { [self] error in
                            guard !finished, error == nil else { finish(.failed); return }
                            connection.receive(minimumIncompleteLength: payload.count, maximumLength: payload.count) { [self] data, _, _, error in
                                finish(error == nil && data == payload ? .exchanged : .failed)
                            }
                        })
                    case .failed(let error): fail(error)
                    default: break
                    }
                }
                connection.start(queue: queue)
            case .failed: finish(.failed)
            default: break
            }
        }
        listener.start(queue: queue)
    }

    private static func isTLS13(_ connection: NWConnection) -> Bool {
        guard let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else { return false }
        return sec_protocol_metadata_get_negotiated_tls_protocol_version(metadata.securityProtocolMetadata) == .TLSv13
            && !sec_protocol_metadata_get_early_data_accepted(metadata.securityProtocolMetadata)
    }

    func fail(_ error: NWError) {
        // Only explicit certificate authentication failures qualify as negative evidence.
        // Timeouts, transport errors and other TLS failures must fail the test.
        if case .tls(let status) = error,
           [errSSLBadCert, errSSLXCertChainInvalid, errSSLPeerBadCert, errSSLPeerCertUnknown, errSSLPeerUnknownCA, errSSLCertificateRequired].contains(status),
           !((mode == .missingClient || mode == .wrongClient) && serverReady) {
            finish(.authenticationRejected)
        } else {
            print("Unexpected local TLS test error: \(error)")
            finish(.failed)
        }
    }

    func finish(_ result: Outcome) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !finished else { return }
        finished = true
        outcome = result
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        client?.stateUpdateHandler = nil
        server?.stateUpdateHandler = nil
        client?.cancel()
        server?.cancel()
        listener?.cancel()
        done.signal()
    }
}
