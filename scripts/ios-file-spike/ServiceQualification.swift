import DeviceBridgeCore
import Foundation

/// Real-device acceptance only. Explicitly opted in, one fresh temporary domain, no app data.
@main struct ServiceQualification {
    static let byteCount = 500_000_000

    static func main() async {
        do {
            let env = ProcessInfo.processInfo.environment
            guard env["DEVICEBRIDGE_LARGE_FILE_CHECK"] == "1",
                  let transport = env["DEVICEBRIDGE_FILE_TRANSPORT"],
                  let root = env["DEVICEBRIDGE_FILE_EVIDENCE"] else { throw Failure.preflight }
            let directory = URL(fileURLWithPath: root, isDirectory: true)
            let candidates = try await IOSDeviceDiscoveryService(
                xcrunURL: URL(fileURLWithPath: "/usr/bin/xcrun"), runner: HostCommandRunner()
            ).discover(observedAt: Date())
            let selected = candidates.filter {
                $0.id == transport && $0.kind == .usb && $0.identity.stability == .stable
                    && ($0.status == .candidate || $0.status == .available)
            }
            guard selected.count == 1, let record = DeviceInventory.aggregate(selected).first,
                  record.authorization == .authorized else { throw Failure.preflight }
            let store = DeviceSessionStore()
            await store.replaceInventory([record])
            _ = try await store.select(record.identity)
            let provider = IOSFileProvider(xcrunURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
                runner: HostCommandRunner())
            let service = FileTransferService(store: store, provider: provider)
            let domain = "dev.debugutility.largecheck." + UUID().uuidString
            let location = try DeviceFileLocation(scope: .iOSTemporary(identifier: domain), relativePath: "fixture.bin")
            try Data(domain.utf8).write(to: directory.appendingPathComponent("temporary-domain.txt"), options: .withoutOverwriting)
            let source = directory.appendingPathComponent("source.bin")
            let destination = directory.appendingPathComponent("received.bin")
            let cancelledDestination = directory.appendingPathComponent("cancelled.bin")
            let empty = directory.appendingPathComponent("empty.bin")
            try Data().write(to: empty, options: .withoutOverwriting)
            defer {
                for url in [source, destination, cancelledDestination, empty] {
                    try? FileManager.default.removeItem(at: url)
                }
            }
            // Bounded 1 MiB fixture construction; never allocate the full 500 MB in the harness.
            guard FileManager.default.createFile(atPath: source.path, contents: nil) else { throw Failure.preflight }
            let handle = try FileHandle(forWritingTo: source)
            let chunk = Data((0..<1_048_576).map { UInt8($0 % 251) })
            var remaining = byteCount
            while remaining > 0 {
                let count = min(remaining, chunk.count)
                try handle.write(contentsOf: chunk.prefix(count))
                remaining -= count
            }
            try handle.close()
            var qualificationError: (any Error)?
            do {
                let start = ContinuousClock.now
                let sent = await service.send(sourceURL: source, destination: location)
                guard let sentArtifact = sent.artifact,
                      sentArtifact.byteLength == byteCount,
                      sentArtifact.validation == .length else { throw Failure.send }
                print("PASS: service sent 500000000 bytes; duration \(start.duration(to: .now))")

                let collision = await service.send(sourceURL: empty, destination: location)
                guard collision.failure?.code == .restricted else { throw Failure.remoteCollision }
                print("PASS: remote collision rejected without replacement")

                let cancelled = Task {
                    await service.receive(source: location, destinationURL: cancelledDestination, replaceExisting: false)
                }
                // Cancel only after the real child has produced >= 1 MiB of local partial data.
                let deadline = ContinuousClock.now.advanced(by: .seconds(60))
                var observedPartial = false
                while ContinuousClock.now < deadline {
                    let partials = try partialFiles(in: directory)
                    if partials.contains(where: { url in
                        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                        return size >= 1_048_576
                    }) { observedPartial = true; break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                let cancelStart = ContinuousClock.now
                cancelled.cancel()
                let cancelledOutcome = await cancelled.value
                guard observedPartial, cancelledOutcome.failure?.code == .cancelled,
                      !FileManager.default.fileExists(atPath: cancelledDestination.path),
                      try partialFiles(in: directory).isEmpty else { throw Failure.cancellation }
                print("PASS: cancelled actual in-flight download; no final/partial publication; duration \(cancelStart.duration(to: .now))")

                let receiveStart = ContinuousClock.now
                let received = await service.receive(source: location, destinationURL: destination, replaceExisting: false)
                guard let receivedArtifact = received.artifact,
                      receivedArtifact.byteLength == byteCount,
                      receivedArtifact.sha256 == sentArtifact.sha256,
                      receivedArtifact.validation == .length,
                      try partialFiles(in: directory).isEmpty else { throw Failure.integrity }
                print("PASS: service received 500000000 bytes with matching round-trip SHA-256; duration \(receiveStart.duration(to: .now))")
                let localCollision = await service.receive(source: location, destinationURL: destination, replaceExisting: false)
                guard localCollision.failure?.code == .restricted else { throw Failure.localCollision }
                print("PASS: local destination replacement requires explicit confirmation")
            } catch { qualificationError = error }

            // CoreDevice has no delete command. Reclaim only this run's generated remote file by
            // replacing it with an empty fixture and verify its length; retain the empty namespace.
            let cleaned = try await provider.send(localURL: empty, destination: location,
                transportID: transport, operationID: UUID(), replaceExisting: true)
            guard cleaned.byteLength == 0 else { throw Failure.cleanup }
            print("PASS: owned remote fixture reduced to zero bytes; empty temporary namespace retained")
            if let qualificationError { throw qualificationError }
            print("PASS: large-file service qualification complete")
        } catch let error as Failure {
            print("FAIL: large-file qualification \(error)"); exit(1)
        } catch {
            print("FAIL: external command or local I/O; inspect owned evidence, cleanup not guaranteed"); exit(1)
        }
    }

    static func partialFiles(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
            .filter { $0.lastPathComponent.contains(".partial.") }
    }
    enum Failure: Error { case preflight, send, remoteCollision, cancellation, integrity, localCollision, cleanup }
}
