import Foundation
import CryptoKit
import Network
import Security

/// T082 local TLS feasibility test only, never a production content provider.
enum TLSPSKProbe {
    static func exchange(mismatchedKey: Bool) -> Bool {
        let pair = Pair()
        pair.queue.async { pair.start(mismatchedKey: mismatchedKey) }
        if pair.done.wait(timeout: .now() + 8) == .timedOut {
            pair.queue.sync { pair.finish(false) }
        }
        return pair.queue.sync { pair.success }
    }

    // All mutable connection/lifecycle fields have one serial queue writer.
    private final class Pair: @unchecked Sendable {
        let queue = DispatchQueue(label: "DeviceBridge.T082.TLS")
        let done = DispatchSemaphore(value: 0)
        var success = false
        private var finished = false
        private var listener: NWListener?
        private var client: NWConnection?
        private var server: NWConnection?
        private let payload = Data("DeviceBridge-public-identity-only".utf8)

        func start(mismatchedKey: Bool) {
            do {
                let key = SymmetricKey(size: .bits256)
                let serverParameters = Self.parameters(key: key)
                serverParameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
                let listener = try NWListener(using: serverParameters)
                self.listener = listener
                listener.newConnectionHandler = { [self] connection in
                    guard server == nil, !finished else { connection.cancel(); return }
                    server = connection
                    connection.stateUpdateHandler = { [self] state in
                        switch state {
                        case .ready:
                            guard Self.isTLS13(connection) else { finish(false); return }
                            connection.receive(minimumIncompleteLength: payload.count, maximumLength: payload.count) { [self] data, _, _, error in
                                guard !finished, error == nil, data == payload else { finish(false); return }
                                connection.send(content: payload, completion: .contentProcessed { [self] error in
                                    if error != nil { finish(false) }
                                })
                            }
                        case .failed(let error):
                            print("TLS probe server error: \(error)")
                            finish(false)
                        default: break
                        }
                    }
                    connection.start(queue: queue)
                }
                listener.stateUpdateHandler = { [self] state in
                    switch state {
                    case .ready:
                        guard let port = listener.port else { finish(false); return }
                        let clientKey = mismatchedKey ? SymmetricKey(size: .bits256) : key
                        let connection = NWConnection(host: "127.0.0.1", port: port, using: Self.parameters(key: clientKey))
                        client = connection
                        connection.stateUpdateHandler = { [self] state in
                            switch state {
                            case .ready:
                                guard Self.isTLS13(connection) else { finish(false); return }
                                connection.send(content: payload, completion: .contentProcessed { [self] error in
                                    guard error == nil else { finish(false); return }
                                    connection.receive(minimumIncompleteLength: payload.count, maximumLength: payload.count) { [self] data, _, _, error in
                                        finish(error == nil && data == payload)
                                    }
                                })
                            case .failed(let error):
                                print("TLS probe client error: \(error)")
                                finish(false)
                            default: break
                            }
                        }
                        connection.start(queue: queue)
                    case .failed(let error):
                        print("TLS probe listener error: \(error)")
                        finish(false)
                    default: break
                    }
                }
                listener.start(queue: queue)
            } catch {
                print("TLS probe setup error: \(error)")
                finish(false)
            }
        }

        private static func parameters(key: SymmetricKey) -> NWParameters {
            let tls = NWProtocolTLS.Options()
            let options = tls.securityProtocolOptions
            sec_protocol_options_set_min_tls_protocol_version(options, .TLSv13)
            sec_protocol_options_set_max_tls_protocol_version(options, .TLSv13)
            sec_protocol_options_set_tls_tickets_enabled(options, false)
            sec_protocol_options_set_tls_resumption_enabled(options, false)
            sec_protocol_options_set_tls_false_start_enabled(options, false)
            let psk = key.withUnsafeBytes { DispatchData(bytes: $0) }
            let identity = Data("DeviceBridge-T082-public-psk-identity".utf8).withUnsafeBytes { DispatchData(bytes: $0) }
            sec_protocol_options_add_pre_shared_key(options, psk as __DispatchData, identity as __DispatchData)
            // PSK-only: no certificates, trust overrides, anonymous mode or fallback.
            return NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        }

        private static func isTLS13(_ connection: NWConnection) -> Bool {
            guard let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else { return false }
            return sec_protocol_metadata_get_negotiated_tls_protocol_version(metadata.securityProtocolMetadata) == .TLSv13
                && !sec_protocol_metadata_get_early_data_accepted(metadata.securityProtocolMetadata)
        }

        func finish(_ result: Bool) {
            dispatchPrecondition(condition: .onQueue(queue))
            guard !finished else { return }
            finished = true
            success = result
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
}
