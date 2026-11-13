// Local keychain lookup only. No trust evaluation, export, signing or network API.
import Foundation
import Security

func probe() -> String {
    let args = CommandLine.arguments
    guard args.count == 3, args[2].range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil else {
        return "probe_invalid_input"
    }
    var keychain: SecKeychain?
    guard SecKeychainOpen(args[1], &keychain) == errSecSuccess, let keychain else { return "probe_keychain_unavailable" }
    let query: [String: Any] = [
        kSecClass as String: kSecClassIdentity,
        kSecMatchSearchList as String: [keychain],
        kSecMatchLimit as String: kSecMatchLimitAll,
        kSecReturnRef as String: true,
        kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
    ]
    var found: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &found)
    if status == errSecItemNotFound { return "probe_no_identity" }
    guard status == errSecSuccess, let identities = found as? [SecIdentity] else { return "probe_lookup_failed" }
    var matches = 0
    for identity in identities {
        var certificate: SecCertificate?
        var privateKey: SecKey?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
              SecIdentityCopyPrivateKey(identity, &privateKey) == errSecSuccess,
              privateKey != nil, let certificate,
              let summary = SecCertificateCopySubjectSummary(certificate) as String? else { return "probe_lookup_failed" }
        // A local named certificate/key pair, not a trust or Apple authenticity claim.
        if summary.hasPrefix("Developer ID Application: "), summary.hasSuffix(" (" + args[2] + ")") { matches += 1 }
    }
    if matches == 1 { return "probe_matching_named_developer_id_private_key" }
    return matches == 0 ? "probe_no_matching_named_developer_id_private_key" : "probe_ambiguous_matching_identities"
}
print(probe())
