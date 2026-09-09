import Foundation
import Testing
@testable import DeviceBridgeCore

@Suite("Physical production image library", .serialized)
struct PhysicalImageLibraryTests {
    @Test("designated Android lists existing screenshots, previews and exports unchanged originals",
          .enabled(if: ProcessInfo.processInfo.environment["DEVICEBRIDGE_LIVE_IMAGE_LIBRARY"] == "1"))
    func androidScreenshot() async throws {
        let environment = ProcessInfo.processInfo.environment
        let path = try #require(environment["DEVICEBRIDGE_LIVE_ADB_PATH"])
        let transport = try #require(environment["DEVICEBRIDGE_LIVE_ANDROID_TRANSPORT"])
        let adb = URL(fileURLWithPath: path)
        let runner = HostCommandRunner()
        let discovered = try await AndroidDeviceDiscoveryService(adbURL: adb, runner: runner).discover(observedAt: Date())
        let devices = DeviceInventory.aggregate(discovered)
        let target = try #require(devices.first { $0.preferredTransportID == transport })
        let store = DeviceSessionStore()
        await store.replaceInventory(devices)
        let session = try #require(try await store.select(target.identity).session)
        let directory = FileManager.default.temporaryDirectory.appending(path: "devicebridge-live-images-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = ImageLibraryService(store: store, session: session,
            provider: AndroidImageProvider(adbURL: adb, runner: runner),
            sessionDirectory: directory.appending(path: "cache"))
        let catalog = try await service.load(source: .androidPictures)
        let item = try #require(catalog.items.first {
            $0.relativeDirectory.lowercased().contains("screenshots") && $0.byteLength <= 20 * 1_024 * 1_024
        }, "Requires an existing screenshot; no phone fixture is created")
        let albumThumbnail = try await service.thumbnail(itemID: item.id)
        #expect(!albumThumbnail.isEmpty)
        #expect(await service.currentPreview == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.appending(path: "cache").path).isEmpty)
        let preview: ImagePreview
        do {
            preview = try await service.preview(itemID: item.id)
        } catch {
            // Opt-in diagnostic: counts only, never paths, image bytes or hashes.
            let provider = AndroidImageProvider(adbURL: adb, runner: runner)
            let entries = try await provider.list(source: .androidPictures, transportID: transport)
            if let entry = entries.first(where: { $0.displayName == item.displayName && $0.relativeDirectory == item.relativeDirectory }) {
                let raw = try await runner.run(HostCommandRequest(executableURL: adb,
                    arguments: ["-t", transport, "exec-out", "head", "-c", String(entry.byteLength + 1), entry.path],
                    timeout: .seconds(30), maximumOutputBytes: Int(entry.byteLength) + 16_385))
                print("Image read diagnostic: expected \(entry.byteLength), stdout \(raw.standardOutput.count), stderr \(raw.standardError.count), exit \(raw.exitCode)")
            }
            throw error
        }
        let exported = try await service.export(previewID: preview.id,
            destination: directory.appending(path: "original"), replaceExisting: false)
        let metadata = try FileIntegrity.metadata(for: exported)
        // The production provider verifies remote SHA-256; the service verifies the staged export again.
        #expect(metadata.byteLength == item.byteLength)
        #expect(preview.pixelWidth > 0 && preview.pixelHeight > 0)
        #expect(!preview.thumbnailPNG.isEmpty && !preview.previewPNG.isEmpty)
        print("Production image library: \(catalog.items.count) catalog entries; \(metadata.byteLength) original bytes; \(preview.pixelWidth)x\(preview.pixelHeight); album thumbnail and preview decoded; source and export SHA-256 verified")
        await service.clear()
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "cache").path))
        print("Production image library: cache cleared; no phone images modified; camera and wireless acceptance NOT RUN")
    }
}
