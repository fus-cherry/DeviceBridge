import Foundation
import Security

public enum IOSRunnerCodeRole: Sendable, CaseIterable {
    case runner, tests, host

    var bundleIdentifier: String {
        switch self {
        case .runner: "dev.debugutility.DeviceBridgeRunnerUITests.xctrunner"
        case .tests: "dev.debugutility.DeviceBridgeRunnerUITests"
        case .host: "dev.debugutility.DeviceBridgeHost"
        }
    }
}

public struct IOSRunnerCodeSignature: Sendable {
    public let teamIdentifier: String
    public let bundleIdentifier: String
    public let leafCertificateDER: Data
}

/// Offline local signature validation only; not profile authorization, installation or readiness.
public struct IOSRunnerCodeSignatureChecker: Sendable {
    public init() {}

    public func verify(at url: URL, role: IOSRunnerCodeRole, expectedTeamIdentifier: String) throws -> IOSRunnerCodeSignature {
        // Only this validated Team and fixed tool-owned bundle IDs enter the requirement grammar.
        guard url.isFileURL, expectedTeamIdentifier.utf8.count == 10,
              expectedTeamIdentifier.utf8.allSatisfy({ (65...90).contains($0) || (48...57).contains($0) }) else {
            throw Failure.invalidExpectation
        }
        let expression = "anchor apple generic and certificate leaf[subject.OU] = \"\(expectedTeamIdentifier)\" and identifier \"\(role.bundleIdentifier)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(expression as CFString, SecCSFlags(rawValue: 0), &requirement) == errSecSuccess,
              let requirement else { throw Failure.invalidExpectation }
        var code: SecStaticCode?
        let openStatus = SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(rawValue: 0), &code)
        guard openStatus == errSecSuccess, let code else { throw Failure.invalidSignature(openStatus) }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
            .union(.considerExpiration).union(.noNetworkAccess)
        let status = SecStaticCodeCheckValidity(code, flags, requirement)
        guard status == errSecSuccess else { throw Failure.invalidSignature(status) }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [String: Any],
              let team = values[kSecCodeInfoTeamIdentifier as String] as? String,
              let identifier = values[kSecCodeInfoIdentifier as String] as? String,
              let certificates = values[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certificates.first,
              team == expectedTeamIdentifier, identifier == role.bundleIdentifier else { throw Failure.missingFacts }
        return IOSRunnerCodeSignature(teamIdentifier: team, bundleIdentifier: identifier,
            leafCertificateDER: SecCertificateCopyData(leaf) as Data)
    }

    private enum Failure: Error { case invalidExpectation, invalidSignature(OSStatus), missingFacts }
}
