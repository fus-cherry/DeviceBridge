import Foundation
import DeviceBridgeSecureChannel
import DeviceBridgeTLSProbeSupport

struct HostRecord: Encodable { let launchID: UUID; let hostCertificateDER: Data }
struct PeerInput: Decodable { let port: UInt16; let record: Data }
struct Outcome: Encodable {
    let result: String
    let publicCanary: String
    let latencyMilliseconds: [Double]
    let idleBeforeCloseSeconds: Double
    let connectedSeconds: Double
}

func emit<T: Encodable>(_ value: T) throws {
    FileHandle.standardOutput.write(try JSONEncoder().encode(value) + Data([10]))
}

do {
    let argument = CommandLine.arguments.dropFirst().first ?? "normal"
    let identityMode = argument == "identity"
    let mode = TLSIdentityProbe.Mode(rawValue: argument) ?? .normal
    let identity = try EphemeralTLSIdentity.create()
    let launch = UUID()
    try emit(HostRecord(launchID: launch, hostCertificateDER: identity.certificateDER))
    guard let line = readLine(), line.utf8.count <= 16384 else { exit(1) }
    let input = try JSONDecoder().decode(PeerInput.self, from: Data(line.utf8))
    let peer = try PublicBootstrapRecord.validate(input.record, launchID: launch,
        hostCertificateDER: identity.certificateDER,
        helperBuild: identityMode ? IOSRunnerHandshakeProbe.helperBuild : TLSIdentityProbe.helperBuild)
    if identityMode {
        let outcome = try await IOSRunnerHandshakeProbe.exchange(port: input.port, launchID: launch,
            identity: identity, peerCertificateDER: peer)
        try emit(Outcome(result: outcome.result, publicCanary: outcome.publicCanary,
            latencyMilliseconds: outcome.latencyMilliseconds, idleBeforeCloseSeconds: outcome.idleBeforeCloseSeconds,
            connectedSeconds: outcome.connectedSeconds))
        exit(0)
    }
    let canary = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    let probe = TLSIdentityProbe(isServer: false)
    let result = try probe.exchange(port: input.port, identity: identity,
        peerCertificateDER: peer, publicCanary: canary, mode: mode)
    // Intentionally public diagnostic marker, returned through the parent's pipe for log auditing.
    try emit(Outcome(result: result, publicCanary: canary, latencyMilliseconds: probe.latencyMilliseconds,
        idleBeforeCloseSeconds: probe.idleBeforeCloseSeconds, connectedSeconds: probe.connectedSeconds))
    let expected: String
    switch mode {
    case .normal, .heartbeat: expected = "tls13-31-exchanges"
    case .orphan, .invalid, .partial, .sustain: expected = "peerClosed"
    case .disconnect: expected = "clientDisconnected"
    }
    exit(result == expected ? 0 : 1)
} catch {
    // Never serialize key material, raw tool output or arbitrary error descriptions.
    try? emit(["result": "probeFailed"])
    exit(1)
}
