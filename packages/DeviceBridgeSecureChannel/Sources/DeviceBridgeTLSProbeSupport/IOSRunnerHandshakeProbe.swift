import Foundation
import DeviceBridgeSecureChannel
import DeviceBridgeProtocol

/// Opt-in identity/stop diagnostic only, not a production channel factory or content dispatcher.
/// Network lifetime belongs to PinnedTLSFrameStream; each invocation owns its public record.
public enum IOSRunnerHandshakeProbe {
    public static let helperBuild = "devicebridge-ios-identity-v1"
    public enum Failure: Error, Equatable, Sendable { case probeFailed }
    public struct Outcome: Sendable {
        public let result: String
        public let publicCanary: String
        public let latencyMilliseconds: [Double]
        public let connectedSeconds: Double
        public let idleBeforeCloseSeconds: Double
    }

    public static func serve(port: UInt16, launchID: UUID, hostCertificateDER: Data, recordURL: URL) async throws -> String {
        var listener: PinnedTLSFrameStream.Listener?
        var ownedRecord: Data?
        do {
            guard port >= 1024, recordURL.isFileURL else { throw Failure.probeFailed }
            try Task.checkCancellation()
            let identity = try EphemeralTLSIdentity.create()
            let record = try PublicBootstrapRecord.encode(launchID: launchID, hostCertificateDER: hostCertificateDER,
                runnerCertificateDER: identity.certificateDER, helperBuild: helperBuild)
            let ready = try await PinnedTLSFrameStream.listen(localPort: port, identity: identity,
                peerCertificateDER: hostCertificateDER, acceptTimeout: 60, handshakeTimeout: 10)
            listener = ready
            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: recordURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard !FileManager.default.fileExists(atPath: recordURL.path) else { throw Failure.probeFailed }
            try record.write(to: recordURL, options: .atomic)
            ownedRecord = record
            let stream = try await ready.accept()
            let session = try await IOSRunnerIdentityHandshake.acceptRunner(stream: stream, launchID: launchID,
                helperBuild: helperBuild, allowedActions: [.identity, .stop])
            let codec = HelperWireCodec()
            let stop = try codec.decodeRequest(await stream.readFrame(timeout: 10))
            try validateStop(stop, session: session, now: Date())
            let reply = HelperResult(requestID: stop.requestID, status: .success, completedAt: Date(),
                payload: stopReplyPayload(session))
            try await stream.writeFrame(codec.encode(reply), timeout: 10)
            try Task.checkCancellation()
            try validateStop(stop, session: session, now: Date())
            await ready.close()
            try removeOwnedRecord(ownedRecord, at: recordURL)
            return "identity-2-exchanges"
        } catch {
            await listener?.close()
            try? removeOwnedRecord(ownedRecord, at: recordURL)
            throw Failure.probeFailed
        }
    }

    public static func exchange(port: UInt16, launchID: UUID, identity: EphemeralTLSIdentity, peerCertificateDER: Data) async throws -> Outcome {
        var connection: PinnedTLSFrameStream?
        do {
            guard port >= 1024 else { throw Failure.probeFailed }
            let stream = try await PinnedTLSFrameStream.connect(localPort: port, identity: identity,
                peerCertificateDER: peerCertificateDER, handshakeTimeout: 10)
            connection = stream
            let connected = ContinuousClock.now
            let session = try await IOSRunnerIdentityHandshake.openHost(stream: stream, launchID: launchID,
                helperBuild: helperBuild, requiredActions: [.identity, .stop])
            guard session.allowedActions == [.identity, .stop] else { throw Failure.probeFailed }
            let identityLatency = seconds(connected.duration(to: .now)) * 1000
            // Public request identifier for log auditing; never the session nonce or challenge.
            let requestID = UUID()
            // The shared wire codec emits whole ISO8601 seconds. Keep the locally retained
            // request on that same precision for strict result timestamp validation.
            let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
            let stop = HelperRequest(requestID: requestID, sessionNonce: session.sessionNonce,
                helperDeviceID: session.helperDeviceID, action: .stop, createdAt: now,
                expiresAt: now.addingTimeInterval(10), payload: ["launchId": .string(launchID.uuidString)])
            let started = ContinuousClock.now
            let codec = HelperWireCodec()
            try await stream.writeFrame(codec.encode(stop), timeout: 10)
            let reply = try codec.decodeResult(await stream.readFrame(timeout: 10))
            try Task.checkCancellation()
            try validateStop(stop, session: session, now: Date())
            guard reply.protocolVersion == 1, reply.requestID == requestID, reply.status == .success,
                  reply.error == nil, reply.payload == stopReplyPayload(session),
                  reply.completedAt.timeIntervalSince1970.isFinite,
                  reply.completedAt >= stop.createdAt, reply.completedAt <= stop.expiresAt else { throw Failure.probeFailed }
            let stopLatency = seconds(started.duration(to: .now)) * 1000
            await stream.close()
            return Outcome(result: "identity-2-exchanges", publicCanary: requestID.uuidString,
                latencyMilliseconds: [identityLatency, stopLatency], connectedSeconds: seconds(connected.duration(to: .now)),
                idleBeforeCloseSeconds: 0)
        } catch {
            await connection?.close()
            throw Failure.probeFailed
        }
    }

    private static func validateStop(_ request: HelperRequest, session: IOSRunnerIdentityHandshake.Session, now: Date) throws {
        guard request.protocolVersion == 1, request.action == .stop,
              request.sessionNonce == session.sessionNonce, request.helperDeviceID == session.helperDeviceID,
              request.payload == ["launchId": .string(session.launchID.uuidString)],
              request.createdAt.timeIntervalSince1970.isFinite, request.expiresAt.timeIntervalSince1970.isFinite,
              abs(request.createdAt.timeIntervalSince(now)) <= 120,
              request.createdAt < request.expiresAt, request.expiresAt > now,
              request.expiresAt.timeIntervalSince(request.createdAt) <= 30 else { throw Failure.probeFailed }
    }

    private static func stopReplyPayload(_ session: IOSRunnerIdentityHandshake.Session) -> [String: JSONValue] {
        ["launchId": .string(session.launchID.uuidString), "sessionNonce": .string(session.sessionNonce),
         "helperDeviceId": .string(session.helperDeviceID)]
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    private static func removeOwnedRecord(_ record: Data?, at url: URL) throws {
        guard let record else { return }
        let file: FileHandle
        do { file = try FileHandle(forReadingFrom: url) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return }
        defer { try? file.close() }
        // Bound reads even if the trusted container's path was replaced by unrelated metadata.
        guard try file.read(upToCount: record.count + 1) == record else { return }
        try FileManager.default.removeItem(at: url)
    }
}
