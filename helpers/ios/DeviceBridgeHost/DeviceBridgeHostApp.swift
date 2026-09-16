import Darwin
import Foundation
import Security
import SwiftUI
import DeviceBridgeSecureChannel

@main
struct DeviceBridgeHostApp: App {
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 12) {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.largeTitle)
                Text("DeviceBridge Clipboard")
                Text("Return to your previous app after the clipboard action finishes.")
                    .foregroundStyle(.secondary)
            }
            .padding()
            .task { await ClipboardHostServer.runFromEnvironment() }
            #if DEVICEBRIDGE_CLIPBOARD_SOURCE_PROBE
            .task { await ClipboardSourceProbe.run() }
            #endif
        }
    }
}

@MainActor
private enum ClipboardHostServer {
    private static var started = false

    static func runFromEnvironment() async {
        guard !started else { return }
        started = true
        let environment = ProcessInfo.processInfo.environment
        guard let rawLaunch = environment["DEVICEBRIDGE_PUBLIC_LAUNCH"],
              let launchID = UUID(uuidString: rawLaunch),
              let rawCertificate = environment["DEVICEBRIDGE_PUBLIC_HOST_CERTIFICATE"],
              rawCertificate.utf8.count <= 5_464,
              let hostCertificate = Data(base64Encoded: rawCertificate),
              !hostCertificate.isEmpty, hostCertificate.count <= 4_096,
              SecCertificateCreateWithData(nil, hostCertificate as CFData) != nil,
              let rawLifetime = environment["DEVICEBRIDGE_PUBLIC_MAXIMUM_LIFETIME"],
              let seconds = Double(rawLifetime), seconds.isFinite, seconds > 0, seconds <= 86_400 else { return }
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        do {
            let identity = try EphemeralTLSIdentity.create()
            let publicBytes = try PublicBootstrapRecord.encode(launchID: launchID,
                hostCertificateDER: hostCertificate, runnerCertificateDER: identity.certificateDER,
                helperBuild: IOSRunnerSessionServer.helperBuild)
            let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true)
            let directory = documents.appendingPathComponent("DeviceBridgeBootstrap", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let recordURL = directory.appendingPathComponent(launchID.uuidString + ".json")
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else { return }
            let timeout = Double(remaining.components.seconds) + Double(remaining.components.attoseconds) / 1e18
            let listener = try await PinnedTLSFrameStream.listen(localPort: 49_873, identity: identity,
                peerCertificateDER: hostCertificate, acceptTimeout: min(60, timeout), handshakeTimeout: min(10, timeout))
            let expiry = Task {
                do { try await Task.sleep(until: deadline, clock: .continuous); await listener.close() }
                catch { }
            }
            var record: ClipboardHostRecord?
            defer { expiry.cancel() }
            do {
                record = try ClipboardHostRecord.publish(publicBytes, at: recordURL)
                let stream = try await listener.accept()
                _ = try await IOSRunnerSessionServer.run(stream: stream, launchID: launchID,
                    maximumDeadline: deadline, clipboardHandler: ActiveClipboardHandler())
            } catch { }
            await listener.close()
            try? record?.removeOwned()
        } catch { }
    }
}

private struct ClipboardHostRecord {
    let url: URL
    let bytes: Data

    static func publish(_ bytes: Data, at destination: URL) throws -> Self {
        guard !bytes.isEmpty, bytes.count <= 8_192 else { throw RecordFailure.invalid }
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        let descriptor = open(staging.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw RecordFailure.invalid }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try file.write(contentsOf: bytes)
            try file.close()
            guard renamex_np(staging.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
                throw RecordFailure.invalid
            }
            return Self(url: destination, bytes: bytes)
        } catch {
            try? file.close()
            _ = unlink(staging.path)
            throw RecordFailure.invalid
        }
    }

    func removeOwned() throws {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else {
            if errno == ENOENT { return }
            throw RecordFailure.invalid
        }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        let actual = try file.read(upToCount: bytes.count + 1) ?? Data()
        guard actual == bytes, unlink(url.path) == 0 || errno == ENOENT else { throw RecordFailure.invalid }
    }

    private enum RecordFailure: Error { case invalid }
}
