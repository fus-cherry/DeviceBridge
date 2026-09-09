import AppKit
import DeviceBridgeCore
import Foundation

@main
struct IOSImagesPhysicalChecks {
    enum Failure: Error { case failed(String) }
    @MainActor static func main() async {
        do { try await run() }
        catch { print("FAILED: \(error)"); exit(2) }
    }
    @MainActor static func run() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        guard let transport = ProcessInfo.processInfo.environment["DEVICEBRIDGE_LIVE_IOS_TRANSPORT"],
              ProcessInfo.processInfo.environment["DEVICEBRIDGE_LIVE_IOS_WORKSPACE_IMAGES"] == "1" else {
            throw Failure.failed("Explicit designated phone and content opt-in required")
        }
        let model = WorkspaceViewModel(arguments: [])
        model.start()
        defer { model.stop() }
        try await wait { !model.isRefreshing && !model.devices.isEmpty }
        guard let target = model.devices.first(where: {
            $0.identity.platform == .iOS && $0.preferredTransportID == transport
                && $0.candidates.contains { $0.id == transport && $0.kind == .usb }
        }) else { throw Failure.failed("Designated USB iPhone unavailable") }
        model.select(target.identity)
        try await wait { !model.isSelecting }
        guard let images = model.imageBrowser else {
            throw Failure.failed("Production workspace has no iOS image browser")
        }
        images.load()
        try await wait { !images.isBusy }
        guard let catalog = images.catalog, catalog.source == .iosUSBCameraImport,
              catalog.sourceDevice == target.identity else {
            throw Failure.failed("Production catalog failed: \(images.feedback ?? "no catalog")")
        }
        print("Workspace iOS catalog loaded: \(catalog.items.count) images; correct device/source")
        images.showPage(0)
        try await wait { !images.isLoadingThumbnails }
        guard images.thumbnailErrors.isEmpty, images.thumbnails.count == images.pageItems.count else {
            throw Failure.failed("Visible album page did not produce all reference thumbnails")
        }
        print("Workspace album page: \(images.thumbnails.count) decoded thumbnails")
        images.suspendThumbnails()
        let directory = FileManager.default.temporaryDirectory.appending(path: "devicebridge-ios-workspace-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        for suffix in ["png", "jpg", "heic"] {
            guard let item = catalog.items.first(where: {
                ($0.displayName as NSString).pathExtension.lowercased() == suffix && $0.byteLength <= 20 * 1_024 * 1_024
            }) else { throw Failure.failed("Missing reference sample format") }
            images.select(item)
            try await wait { !images.isBusy }
            guard let preview = images.preview, preview.item.id == item.id,
                  !preview.previewPNG.isEmpty, !preview.thumbnailPNG.isEmpty else {
                throw Failure.failed("Production preview failed: \(images.feedback ?? "no preview")")
            }
            let destination = directory.appending(path: "sample.\(suffix)")
            images.export(previewID: preview.id, expectedRevision: images.revision,
                          destination: destination, replaceExisting: false)
            try await wait { !images.isBusy }
            guard FileManager.default.fileExists(atPath: destination.path),
                  try FileIntegrity.metadata(for: destination).byteLength == item.byteLength else {
                throw Failure.failed("Production export failed")
            }
            print("Workspace \(suffix): preview \(preview.pixelWidth)x\(preview.pixelHeight); exported \(item.byteLength) bytes; feedback=\(images.feedback ?? "none")")
        }
        // Use real presentation cancellation, then invalidate the old browser by reselection.
        if let item = catalog.items.first {
            images.select(item)
            try await Task.sleep(for: .milliseconds(100))
            images.cancel()
            try await wait { !images.isBusy }
        }
        images.load()
        try await wait { !images.isBusy }
        guard images.catalog?.source == .iosUSBCameraImport else {
            throw Failure.failed("Refresh after cancellation/close failed: \(images.feedback ?? "no catalog")")
        }
        model.select(target.identity)
        try await wait { !model.isSelecting }
        try await wait { !images.isBusy }
        guard images.catalog == nil, images.preview == nil, model.imageBrowser !== images,
              model.imageBrowser?.catalog == nil else { throw Failure.failed("Reselection retained old image state") }
        guard let replacement = model.imageBrowser else { throw Failure.failed("Missing replacement browser") }
        replacement.load()
        try await wait { !replacement.isBusy }
        guard replacement.catalog?.sourceDevice == target.identity else {
            throw Failure.failed("Photo discovery after reselection failed: \(replacement.feedback ?? "no catalog")")
        }
        replacement.stop()
        try await wait { !replacement.isBusy }
        print("PASS: real workspace -> image model -> provider -> preview/export; cancellation/reselection cleared old browser; no desktop input or phone writes")
    }
    @MainActor static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<900 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw Failure.failed("Bounded workspace wait timed out")
    }
}
