import Foundation
import Security
import CryptoKit
import Testing
@testable import DeviceBridgeSecureChannel

struct EphemeralTLSIdentityTests {
    @Test func generatesUsableMatchingIdentity() throws {
        let value = try EphemeralTLSIdentity.create()
        let certificate = try #require(SecCertificateCreateWithData(nil, value.certificateDER as CFData))
        var identityCertificate: SecCertificate?
        #expect(SecIdentityCopyCertificate(value.identity, &identityCertificate) == errSecSuccess)
        let copiedCertificate = try #require(identityCertificate)
        #expect(SecCertificateCopyData(copiedCertificate) as Data == value.certificateDER)
        var key: SecKey?
        #expect(SecIdentityCopyPrivateKey(value.identity, &key) == errSecSuccess)
        let privateKey = try #require(key)
        let challenge = Data("public-identity-possession-test".utf8)
        let signature = try #require(SecKeyCreateSignature(privateKey, .ecdsaSignatureMessageX962SHA256, challenge as CFData, nil))
        let publicKey = try #require(SecCertificateCopyKey(certificate))
        #expect(SecKeyVerifySignature(publicKey, .ecdsaSignatureMessageX962SHA256, challenge as CFData, signature, nil))
    }

    @Test func freshLaunchIdentitiesCannotVerifyEachOthersProofs() throws {
        let a = try EphemeralTLSIdentity.create()
        let b = try EphemeralTLSIdentity.create()
        #expect(a.certificateDER != b.certificateDER)
        var key: SecKey?
        #expect(SecIdentityCopyPrivateKey(a.identity, &key) == errSecSuccess)
        let challenge = Data("public-cross-launch-test".utf8)
        let privateKey = try #require(key)
        let signature = try #require(SecKeyCreateSignature(privateKey, .ecdsaSignatureMessageX962SHA256, challenge as CFData, nil))
        let bCertificate = try #require(SecCertificateCreateWithData(nil, b.certificateDER as CFData))
        let bPublicKey = try #require(SecCertificateCopyKey(bCertificate))
        #expect(!SecKeyVerifySignature(bPublicKey, .ecdsaSignatureMessageX962SHA256, challenge as CFData, signature, nil))
        #expect(SecIdentityCreate(nil, bCertificate, privateKey) == nil)
    }
}
