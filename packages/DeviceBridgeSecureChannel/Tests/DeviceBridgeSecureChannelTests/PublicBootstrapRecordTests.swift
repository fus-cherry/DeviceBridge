import Foundation
import Testing
@testable import DeviceBridgeSecureChannel

struct PublicBootstrapRecordTests {
    @Test func roundTripBindsLaunchHostAndBuild() throws {
        let host = try EphemeralTLSIdentity.create()
        let runner = try EphemeralTLSIdentity.create()
        let launch = UUID()
        let record = try PublicBootstrapRecord.encode(launchID: launch, hostCertificateDER: host.certificateDER,
            runnerCertificateDER: runner.certificateDER, helperBuild: "test-build")
        #expect(try PublicBootstrapRecord.validate(record, launchID: launch, hostCertificateDER: host.certificateDER,
            helperBuild: "test-build") == runner.certificateDER)
        let decoded = try JSONSerialization.jsonObject(with: record) as? [String: Any]
        #expect(Set(decoded?.keys.map { $0 } ?? []) == ["version", "launchID", "hostCertificateSHA256", "runnerCertificateDER", "helperBuild"])
        #expect(throws: (any Error).self) {
            try PublicBootstrapRecord.validate(record, launchID: UUID(), hostCertificateDER: host.certificateDER, helperBuild: "test-build")
        }
        #expect(throws: (any Error).self) {
            try PublicBootstrapRecord.validate(record, launchID: launch, hostCertificateDER: runner.certificateDER, helperBuild: "test-build")
        }
        #expect(throws: (any Error).self) {
            try PublicBootstrapRecord.validate(record, launchID: launch, hostCertificateDER: host.certificateDER, helperBuild: "other-build")
        }
    }

    @Test func invalidSchemaVersionAndCertificateFailClosed() throws {
        let host = try EphemeralTLSIdentity.create()
        let runner = try EphemeralTLSIdentity.create()
        let launch = UUID()
        let record = try PublicBootstrapRecord.encode(launchID: launch, hostCertificateDER: host.certificateDER,
            runnerCertificateDER: runner.certificateDER, helperBuild: "test-build")
        let object = try #require(JSONSerialization.jsonObject(with: record) as? [String: Any])
        var unknown = object; unknown["unexpected"] = "public-test"
        var version = object; version["version"] = 2
        var malformed = object; malformed["runnerCertificateDER"] = Data([1, 2, 3]).base64EncodedString()
        var missing = object; missing.removeValue(forKey: "helperBuild")
        for bad in [unknown, version, malformed, missing] {
            let data = try JSONSerialization.data(withJSONObject: bad)
            #expect(throws: (any Error).self) {
                try PublicBootstrapRecord.validate(data, launchID: launch, hostCertificateDER: host.certificateDER, helperBuild: "test-build")
            }
        }
        #expect(throws: (any Error).self) {
            try PublicBootstrapRecord.validate(Data(repeating: 32, count: 8193), launchID: launch,
                hostCertificateDER: host.certificateDER, helperBuild: "test-build")
        }
    }
}
