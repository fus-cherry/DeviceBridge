import Foundation
import ImageIO
import DeviceBridgeCore

/// Headless checks compiled with the production view model. No app, windows or XCTest UI runner.
@main
struct PhoneImagesModelChecks {
    @MainActor
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "image-model-checks-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = try DeviceIdentity(rawValue: "model-check", stability: .stable, platform: .android)
        let candidate = try TransportCandidate(id: "7", identity: identity, kind: .usb,
            source: .adb, status: .available, observedAt: Date())
        let store = DeviceSessionStore()
        await store.replaceInventory([DeviceRecord(identity: identity, name: "Test",
            authorization: .authorized, candidates: [candidate], preferredTransportID: "7")])
        let snapshot = try await store.select(identity)
        let provider = try ModelImageProvider()
        let service = ImageLibraryService(store: store, session: snapshot.session!, provider: provider,
            sessionDirectory: directory.appending(path: "cache"))
        let model = PhoneImagesViewModel(service: service)
        let initialReads = await provider.reads
        let initialLists = await provider.lists
        try require(initialReads == 0 && initialLists == 0, "initialization must not read")
        model.load()
        try await wait { !model.isBusy }
        guard let item = model.catalog?.items.first else { throw CheckFailure.failed("listing") }
        try require(await provider.reads == 0, "listing must not retrieve image content")

        model.select(item)
        try await wait { !model.isBusy }
        guard let firstPreview = model.preview else { throw CheckFailure.failed("initial preview") }
        // Replace an existing preview, then cancel at/after the replacement commit.
        model.select(item)
        try await wait {
            guard let committed = await service.currentPreview else { return false }
            return committed.id != firstPreview.id
        }
        model.cancel()
        try await wait { !model.isBusy }
        guard let visible = model.preview else { throw CheckFailure.failed("cancelled UI lost committed preview") }
        try require(await service.currentPreview?.id == visible.id, "UI and service preview must agree")
        let destination = directory.appending(path: "image.png")
        let originalBytes = provider.bytes
        model.export(previewID: visible.id, expectedRevision: model.revision, destination: destination, replaceExisting: false)
        try await wait { !model.isBusy }
        try require(FileManager.default.fileExists(atPath: destination.path), "export failed: \(model.feedback ?? "no feedback")")
        try require(try Data(contentsOf: destination) == originalBytes, "visible preview must remain exportable")

        // Destination appears independently before dispatch: exclusive save must not overwrite it.
        try Data("existing".utf8).write(to: destination)
        model.export(previewID: visible.id, expectedRevision: model.revision, destination: destination, replaceExisting: false)
        try await wait { !model.isBusy }
        try require(try Data(contentsOf: destination) == Data("existing".utf8), "collision changed destination")
        try require(model.replacementDestination == destination, "collision needs explicit replacement action")
        model.confirmReplacement(destination: destination, expectedRevision: model.revision)
        try await wait { !model.isBusy }
        try require(try Data(contentsOf: destination) == originalBytes, "explicit replacement failed")

        model.export(previewID: visible.id, expectedRevision: model.revision, destination: destination, replaceExisting: false)
        try await wait { !model.isBusy }
        let oldRevision = model.revision
        model.changeSource(.androidDCIM)
        try await wait { !model.isBusy }
        let staleDestination = directory.appending(path: "stale.png")
        model.export(previewID: visible.id, expectedRevision: oldRevision, destination: staleDestination, replaceExisting: false)
        model.confirmReplacement(destination: destination, expectedRevision: oldRevision)
        try require(!FileManager.default.fileExists(atPath: staleDestination.path), "stale save panel wrote a file")
        try require(model.preview == nil && model.catalog == nil, "source switch retained content")
        model.stop()
        try await wait { !model.isBusy }

        let albumProvider = try ModelImageProvider(itemCount: 73)
        let albumService = ImageLibraryService(store: store, session: snapshot.session!, provider: albumProvider,
            sessionDirectory: directory.appending(path: "album-cache"))
        let album = PhoneImagesViewModel(service: albumService)
        album.load()
        try await wait { !album.isBusy }
        try require(await albumProvider.reads == 0, "catalog alone must not prefetch")
        album.showPage(0)
        try await wait { !album.isLoadingThumbnails }
        try require(album.thumbnails.count == 24, "album must load exactly its first page, not the entire catalog")
        try require(await albumProvider.reads == 24, "first page read count")
        try require(album.preview == nil, "thumbnails must not select an image")
        album.showPage(0)
        try await wait { !album.isLoadingThumbnails }
        try require(await albumProvider.reads == 24, "cached thumbnails must not re-read originals")
        album.showPage(1)
        try await wait { !album.isLoadingThumbnails }
        album.showPage(2)
        try await wait { !album.isLoadingThumbnails }
        try require(album.thumbnails.count <= 48, "album cache must stay bounded across pages")
        try require(await albumProvider.reads == 72, "only visited pages may be read")
        let pageBeforeHiding = album.page
        let previewBeforeHiding = album.preview?.id
        album.suspendThumbnails()
        try require(album.page == 2 && !album.isLoadingThumbnails, "hiding the album must pause reads without resetting page")
        album.showPage(album.page)
        try await wait { !album.isLoadingThumbnails }
        try require(album.page == pageBeforeHiding && album.preview?.id == previewBeforeHiding,
                    "returning to the album must retain its page and selected preview")
        try require(await albumProvider.reads == 72, "returning to a cached page must not download originals again")
        await albumProvider.suspendNextRead()
        album.showPage(3)
        try await wait { await albumProvider.isSuspended }
        let selectedAlbumItem = album.catalog!.items[0]
        album.select(selectedAlbumItem)
        await albumProvider.resumeRead()
        try await wait { !album.isBusy && !album.isLoadingThumbnails }
        try require(album.preview?.item.id == selectedAlbumItem.id, "thumbnail work must yield to selection")
        try require(await albumService.currentPreview?.id == album.preview?.id, "album must not replace export selection")
        await albumProvider.suspendNextRead()
        album.showPage(0)
        try await wait { await albumProvider.isSuspended }
        album.changeSource(.androidDCIM)
        await albumProvider.resumeRead()
        try await wait { !album.isBusy }
        try require(album.thumbnails.isEmpty, "source switch must clear thumbnails")
        try require(!FileManager.default.fileExists(atPath: directory.appending(path: "album-cache").path),
                    "source switch must drain and remove thumbnail originals")
        album.stop()
        try await wait { !album.isBusy }
        print("PASS: image UI state — explicit reads, cancellation reconciliation, exact export, collision consent, stale save/confirmation, paged album/cache, selection priority and source cleanup; no desktop UI launched")
    }

    @MainActor
    static func wait(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw CheckFailure.failed("state wait timed out") }
            await Task.yield()
        }
    }
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw CheckFailure.failed(message) }
    }
    enum CheckFailure: Error { case failed(String) }
}

private actor ModelImageProvider: PhoneImageProviding {
    let bytes: Data
    let itemCount: Int
    var reads = 0
    var lists = 0
    private var shouldSuspend = false
    private var continuation: CheckedContinuation<Void, Never>?
    var isSuspended: Bool { continuation != nil }
    func suspendNextRead() { shouldSuspend = true }
    func resumeRead() { continuation?.resume(); continuation = nil }
    init(itemCount: Int = 1) throws {
        self.itemCount = itemCount
        let context = CGContext(data: nil, width: 4, height: 3, bitsPerComponent: 8, bytesPerRow: 16,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let output = NSMutableData()
        let encoder = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(encoder, context.makeImage()!, nil)
        guard CGImageDestinationFinalize(encoder) else { throw PhoneImagesModelChecks.CheckFailure.failed("fixture encoding") }
        bytes = output as Data
    }
    func list(source: ImageSource, transportID: String,
              validateSession: @escaping @Sendable () async throws -> Void) async throws -> [ImageCandidate] {
        try await validateSession()
        lists += 1
        let root = source == .androidPictures ? "/sdcard/Pictures" : "/sdcard/DCIM"
        let records = (0..<itemCount).map { "\(bytes.count)\0\(100)\0\(root)/photo-\($0).png\0" }.joined()
        return try AndroidImageParser.parse(Data(records.utf8), source: source)
    }
    func receive(_ image: ImageCandidate, transportID: String, partialURL: URL,
                 validateSession: @escaping @Sendable () async throws -> Void) async throws -> DeviceFileReceipt {
        try await validateSession()
        reads += 1
        if shouldSuspend {
            shouldSuspend = false
            await withCheckedContinuation { continuation = $0 }
        }
        try bytes.write(to: partialURL)
        let actual = try FileIntegrity.metadata(for: partialURL)
        return DeviceFileReceipt(byteLength: actual.byteLength, sha256: actual.sha256)
    }
}
