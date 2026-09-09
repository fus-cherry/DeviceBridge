import Foundation
import Network
import Security

public enum PinnedTLSParameters {
    public static func make(identity: EphemeralTLSIdentity?, peerCertificateDER: Data, queue: DispatchQueue) throws -> NWParameters {
        guard !peerCertificateDER.isEmpty, peerCertificateDER.count <= 4096,
              SecCertificateCreateWithData(nil, peerCertificateDER as CFData) != nil else {
            throw NSError(domain: "DeviceBridgePeerCertificate", code: 1)
        }
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv13)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv13)
        sec_protocol_options_set_tls_tickets_enabled(options, false)
        sec_protocol_options_set_tls_resumption_enabled(options, false)
        sec_protocol_options_set_tls_false_start_enabled(options, false)
        // Crucial on listeners: a verify callback alone does not request a client certificate.
        sec_protocol_options_set_peer_authentication_required(options, true)
        if let identity {
            guard let localIdentity = sec_identity_create(identity.identity) else {
                throw NSError(domain: "DeviceBridgeTLSIdentity", code: 1)
            }
            sec_protocol_options_set_local_identity(options, localIdentity)
        }
        sec_protocol_options_set_verify_block(options, { _, trust, complete in
            let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
            let chain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate]
            // Only the actual leaf can satisfy the pin; other chain entries confer no trust.
            let accepted = chain?.first.map { SecCertificateCopyData($0) as Data == peerCertificateDER } ?? false
            complete(accepted)
        }, queue)
        return NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
    }
}
