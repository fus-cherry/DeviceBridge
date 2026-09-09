import Foundation
import ImageIO
import Testing
@testable import DeviceBridgeCore

/// Planning feasibility probe, NOT a production image-provider or UI acceptance test.
/// Opt-in reads only the designated phone, logs aggregate metadata, and removes local copies.
@Suite("Physical phone-image access feasibility", .serialized)
struct PhysicalImageAccessProbeTests {
    @Test("Android shared images can be discovered, pulled unchanged and decoded on the Mac",
          .enabled(if: ProcessInfo.processInfo.environment["DEVICEBRIDGE_LIVE_IMAGE_PROBE"] == "1"))
    func androidExistingImages() async throws {
        try await probeAndroidImages(requireCamera: false)
    }

    @Test("Android camera-photo and screenshot acceptance requires both existing fixtures",
          .enabled(if: ProcessInfo.processInfo.environment["DEVICEBRIDGE_LIVE_CAMERA_IMAGE_PROBE"] == "1"))
    func androidCameraAndScreenshot() async throws {
        try await probeAndroidImages(requireCamera: true)
    }

    private func probeAndroidImages(requireCamera: Bool) async throws {
        let environment = ProcessInfo.processInfo.environment
        let path = try #require(environment["DEVICEBRIDGE_LIVE_ADB_PATH"])
        let transport = try #require(environment["DEVICEBRIDGE_LIVE_ANDROID_TRANSPORT"])
        let adb = URL(fileURLWithPath: path)
        let runner = HostCommandRunner()
        let inventory = try await AndroidDeviceDiscoveryService(adbURL: adb, runner: runner)
            .discover(observedAt: Date())
        let targetPresent = DeviceInventory.aggregate(inventory).contains { $0.preferredTransportID == transport }
        try #require(targetPresent, "The designated phone must be present")

        struct Entry {
            let path: String
            let bytes: Int64
            let modified: Double
        }
        var entries: [Entry] = []
        let extensions = Set(["jpg", "jpeg", "png", "heic", "heif", "webp", "gif", "avif", "bmp"])
        for root in ["/sdcard/DCIM", "/sdcard/Pictures", "/sdcard/Download"] {
            // Fixed roots and fixed quoted format: never interpolate a discovered filename into find.
            let listing = try await runner.run(HostCommandRequest(executableURL: adb,
                arguments: ["-t", transport, "shell", "find", root, "-type", "f",
                            "-printf", "'%s\\0%T@\\0%p\\0'"],
                timeout: .seconds(20), maximumOutputBytes: 4 * 1_024 * 1_024))
            try #require(listing.exitCode == 0, "An unreadable source must not become a successful empty album")
            let fields = listing.standardOutput.split(separator: 0, omittingEmptySubsequences: false)
            try #require(fields.last?.isEmpty == true && (fields.count - 1) % 3 == 0)
            var count = 0
            for offset in stride(from: 0, to: fields.count - 1, by: 3) {
                let remote = try #require(String(data: Data(fields[offset + 2]), encoding: .utf8))
                let inScope = remote.hasPrefix(root + "/")
                try #require(inScope, "Image metadata must remain inside the selected root")
                guard extensions.contains((remote as NSString).pathExtension.lowercased()) else { continue }
                let bytes = try #require(Int64(String(decoding: fields[offset], as: UTF8.self)))
                let modified = try #require(Double(String(decoding: fields[offset + 1], as: UTF8.self)))
                entries.append(Entry(path: remote, bytes: bytes, modified: modified))
                count += 1
            }
            print("Image feasibility: \((root as NSString).lastPathComponent) image entries = \(count)")
        }
        let eligible = entries.filter { $0.bytes > 0 && $0.bytes <= 20 * 1_024 * 1_024 }
            .sorted { $0.modified > $1.modified }
        let photo = eligible.first { $0.path.hasPrefix("/sdcard/DCIM/Camera/") }
        if requireCamera {
            try #require(photo != nil, "Camera-photo acceptance requires an existing camera image")
        }
        let screenshotCandidate = eligible.first { $0.path.lowercased().contains("/screenshots/") }
        let screenshot = try #require(screenshotCandidate,
                                      "Requires one existing screenshot on the designated test phone")
        let localDirectory = FileManager.default.temporaryDirectory
            .appending(path: "devicebridge-image-probe-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: localDirectory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: localDirectory) }
        // A missing camera fixture is reported separately, never relabel a screenshot as a photo.
        let selected = photo.map { [($0, "camera image"), (screenshot, "screenshot")] }
            ?? [(screenshot, "screenshot")]
        if photo == nil { print("Image feasibility: camera-image fixture unavailable; camera acceptance NOT RUN") }
        for (index, selection) in selected.enumerated() {
            let (entry, label) = selection
            let local = localDirectory.appending(path: "\(index).partial")
            // adb pull uses its file-sync protocol; the path is a single argv element.
            let pull = try await runner.run(HostCommandRequest(executableURL: adb,
                arguments: ["-t", transport, "pull", entry.path, local.path],
                timeout: .seconds(30), maximumOutputBytes: 16 * 1_024))
            try #require(pull.exitCode == 0, "Selected image retrieval must succeed")
            let quoted = "'" + entry.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
            let hash = try await runner.run(HostCommandRequest(executableURL: adb,
                arguments: ["-t", transport, "shell", "sha256sum", quoted],
                timeout: .seconds(10), maximumOutputBytes: 16 * 1_024))
            let remoteHash = hash.standardOutputString.split(whereSeparator: \.isWhitespace).first.map(String.init)
            let actual = try FileIntegrity.metadata(for: local)
            let matches = hash.exitCode == 0 && actual.byteLength == entry.bytes && actual.sha256 == remoteHash
            try #require(matches, "Original length and SHA-256 must match without logging the digest")
            let source = try #require(CGImageSourceCreateWithURL(local as CFURL, nil))
            let thumbnail = try #require(CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 320,
            ] as CFDictionary))
            try #require(thumbnail.width > 0 && thumbnail.height > 0)
            print("Image feasibility: \(label), original bytes = \(actual.byteLength), hash matched, thumbnail = \(thumbnail.width)x\(thumbnail.height)")
        }
        try FileManager.default.removeItem(at: localDirectory)
        print("Image feasibility: local probe copies removed; no phone files changed")
    }
}
