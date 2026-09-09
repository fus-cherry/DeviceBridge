import Foundation
import Security
import CryptoKit
import X509
import SwiftASN1

/// T082 candidate; not wired to production device capabilities until physical qualification.
public struct EphemeralTLSIdentity: @unchecked Sendable {
    public let certificateDER: Data
    public let identity: SecIdentity

    public static func create() throws -> Self {
        let key = P256.Signing.PrivateKey()
        let name = try DistinguishedName { CommonName("DeviceBridge ephemeral peer") }
        let now = Date()
        let certificate = try Certificate(
            version: .v3,
            serialNumber: .init(),
            publicKey: .init(key.publicKey),
            notValidBefore: now.addingTimeInterval(-60),
            notValidAfter: now.addingTimeInterval(3600),
            issuer: name,
            subject: name,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: Certificate.Extensions {
                Critical(BasicConstraints.notCertificateAuthority)
                Critical(KeyUsage(digitalSignature: true))
                try ExtendedKeyUsage([.clientAuth, .serverAuth])
            },
            issuerPrivateKey: .init(key)
        )
        var serializer = DER.Serializer()
        try serializer.serialize(certificate)
        let der = Data(serializer.serializedBytes)
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits: 256,
            kSecAttrIsPermanent: false,
        ]
        guard let secKey = SecKeyCreateWithData(key.x963Representation as CFData, attributes as CFDictionary, nil),
              let secCertificate = SecCertificateCreateWithData(nil, der as CFData),
              let identity = SecIdentityCreate(nil, secCertificate, secKey) else {
            throw NSError(domain: "DeviceBridgeEphemeralIdentity", code: 1)
        }
        return Self(certificateDER: der, identity: identity)
    }
}
