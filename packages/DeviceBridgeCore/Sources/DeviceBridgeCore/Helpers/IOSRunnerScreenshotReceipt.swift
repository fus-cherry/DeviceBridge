import Foundation
import DeviceBridgeSecureChannel

/// Used only by the channel actor. Each receipt owns one private operation directory;
/// nothing is publishable until the final length, digest and PNG checks succeed.
final class IOSRunnerScreenshotReceipt {
    enum Failure: Error { case rejected }
    private let requestID: UUID
    private let descriptor: IOSRunnerScreenshotWire.Descriptor
    private let directory: URL
    private let partial: URL
    private var file: FileHandle?
    private var received = 0
    var nextOffset: Int { received }

    init(requestID: UUID, descriptor: IOSRunnerScreenshotWire.Descriptor,
         baseDirectory: URL = FileManager.default.temporaryDirectory) throws {
        self.requestID = requestID; self.descriptor = descriptor
        directory = baseDirectory.appendingPathComponent("DeviceBridgeScreenshot-" + UUID().uuidString, isDirectory: true)
        partial = directory.appendingPathComponent("image.partial")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        do {
            guard FileManager.default.createFile(atPath: partial.path, contents: nil,
                attributes: [.posixPermissions: 0o600]) else { throw Failure.rejected }
            file = try FileHandle(forWritingTo: partial)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw Failure.rejected
        }
    }

    func append(_ chunk: IOSRunnerScreenshotWire.Chunk) throws -> Bool {
        do {
            guard let file, chunk.requestID == requestID, chunk.offset == received,
                  chunk.bytes.count <= descriptor.byteLength - received else { throw Failure.rejected }
            try file.write(contentsOf: chunk.bytes)
            received += chunk.bytes.count
            return received == descriptor.byteLength
        } catch { try? discard(); throw Failure.rejected }
    }

    func finish() throws -> Data {
        defer { try? discard() }
        guard let file, received == descriptor.byteLength else { throw Failure.rejected }
        try file.close(); self.file = nil
        let bytes = try Data(contentsOf: partial)
        try IOSRunnerScreenshotWire.validate(bytes, descriptor: descriptor)
        // Failure to remove the private screenshot is an operation failure, not successful
        // publication. Keep the exact owned path so an explicit cleanup can be retried.
        try discard()
        return bytes
    }

    func discard() throws {
        try file?.close(); file = nil
        if FileManager.default.fileExists(atPath: directory.path) {
            do { try FileManager.default.removeItem(at: directory) }
            catch { throw Failure.rejected }
        }
    }

    deinit { try? discard() }
}
