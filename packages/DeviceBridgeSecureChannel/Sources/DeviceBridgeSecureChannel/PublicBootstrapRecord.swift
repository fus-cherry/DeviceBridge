import Foundation
import CryptoKit
import Security

/// Public metadata only. The caller must obtain it from the exact signed runner container
/// and reject the result if its owning launch was replaced while the copy was in flight.
public enum PublicBootstrapRecord {
    private struct Record: Codable {
        let version: Int
        let launchID: UUID
        let hostCertificateSHA256: Data
        let runnerCertificateDER: Data
        let helperBuild: String
    }
    private enum Invalid: Error { case record }

    public static func encode(launchID: UUID, hostCertificateDER: Data, runnerCertificateDER: Data, helperBuild: String) throws -> Data {
        let data = try JSONEncoder().encode(Record(version: 1, launchID: launchID,
            hostCertificateSHA256: Data(SHA256.hash(data: hostCertificateDER)),
            runnerCertificateDER: runnerCertificateDER, helperBuild: helperBuild))
        _ = try validate(data, launchID: launchID, hostCertificateDER: hostCertificateDER, helperBuild: helperBuild)
        return data
    }

    public static func validate(_ data: Data, launchID: UUID, hostCertificateDER: Data, helperBuild: String) throws -> Data {
        guard data.count <= 8192, !helperBuild.isEmpty, helperBuild.utf8.count <= 128,
              hostCertificateDER.count <= 4096,
              SecCertificateCreateWithData(nil, hostCertificateDER as CFData) != nil,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["version", "launchID", "hostCertificateSHA256", "runnerCertificateDER", "helperBuild"] else {
            throw Invalid.record
        }
        let record = try JSONDecoder().decode(Record.self, from: data)
        guard record.version == 1, record.launchID == launchID, record.helperBuild == helperBuild,
              record.hostCertificateSHA256 == Data(SHA256.hash(data: hostCertificateDER)),
              record.runnerCertificateDER.count <= 4096,
              SecCertificateCreateWithData(nil, record.runnerCertificateDER as CFData) != nil else {
            throw Invalid.record
        }
        return record.runnerCertificateDER
    }
}
