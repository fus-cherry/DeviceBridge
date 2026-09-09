import Darwin
import DeviceBridgeCore
import Foundation

/// Isolated process regression: hashing must not retain one allocation per file chunk.
/// 256 MiB sparse zero fixture, independent SHA-256 oracle, <64 MiB additional peak RSS.
@main struct FileIntegrityMemoryCheck {
    static func main() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("hash-memory-\(UUID().uuidString).bin")
        guard FileManager.default.createFile(atPath: file.path, contents: nil) else { exit(2) }
        defer { try? FileManager.default.removeItem(at: file) }
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 268_435_456)
        try handle.close()
        var before = rusage()
        guard getrusage(RUSAGE_SELF, &before) == 0 else { exit(2) }
        let metadata = try FileIntegrity.metadata(for: file)
        var after = rusage()
        guard getrusage(RUSAGE_SELF, &after) == 0 else { exit(2) }
        let growth = after.ru_maxrss - before.ru_maxrss // Darwin reports bytes.
        guard metadata.byteLength == 268_435_456,
              metadata.sha256 == "a6d72ac7690f53be6ae46ba88506bd97302a093f7108472bd9efc3cefda06484" else {
            print("FAIL: exact length or independent SHA-256 oracle"); exit(1)
        }
        print("Observed additional peak RSS bytes: \(growth)")
        guard growth < 67_108_864 else {
            print("FAIL: chunked hashing retained file-sized memory"); exit(1)
        }
        print("PASS: real FileIntegrity exact digest with bounded additional peak RSS")
    }
}
