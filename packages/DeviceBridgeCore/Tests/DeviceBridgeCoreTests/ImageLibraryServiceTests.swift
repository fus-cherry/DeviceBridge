import Foundation
import ImageIO
import Testing
@testable import DeviceBridgeCore

@Suite("Image library publication and original export")
struct ImageLibraryServiceTests {
    @Test("iOS without a remote checksum exports exact local bytes; Android still requires a source hash")
    func iosLengthOnlyExport() async throws {
        let fixture = try await ImageFixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        await fixture.provider.omitSourceHash()
        let android = try await fixture.service.load(source: .androidPictures)
        await #expect(throws: PhoneImageError.integrityMismatch) {
            try await fixture.service.preview(itemID: android.items[0].id)
        }
        let catalog = try await fixture.service.load(source: .iosUSBCameraImport)
        let preview = try await fixture.service.preview(itemID: catalog.items[0].id)
        #expect(!preview.sourceHashVerified)
        let destination = fixture.directory.appending(path: "ios-original.png")
        _ = try await fixture.service.export(previewID: preview.id, destination: destination, replaceExisting: false)
        #expect(try Data(contentsOf: destination) == fixture.provider.bytes)
    }
    @Test("album thumbnails discard originals and never replace the selected export")
    func albumThumbnail() async throws {
        let fixture = try await ImageFixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let catalog = try await fixture.service.load(source: .androidPictures)
        let thumbnail = try await fixture.service.thumbnail(itemID: catalog.items[0].id)
        #expect(!thumbnail.isEmpty)
        #expect(await fixture.service.currentPreview == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.cache.path).isEmpty)
        let selected = try await fixture.service.preview(itemID: catalog.items[0].id)
        _ = try await fixture.service.thumbnail(itemID: catalog.items[0].id)
        #expect(await fixture.service.currentPreview == selected)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.cache.path).count == 1)
        let destination = fixture.directory.appending(path: "selected.png")
        _ = try await fixture.service.export(previewID: selected.id, destination: destination, replaceExisting: false)
        #expect(try Data(contentsOf: destination) == fixture.provider.bytes)
    }

    @Test("late thumbnail after clear is discarded with its temporary original")
    func lateThumbnail() async throws {
        let fixture = try await ImageFixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let catalog = try await fixture.service.load(source: .androidPictures)
        await fixture.provider.suspendNextRead()
        let task = Task { try await fixture.service.thumbnail(itemID: catalog.items[0].id) }
        while !(await fixture.provider.isSuspended) { await Task.yield() }
        await fixture.service.clear()
        await fixture.provider.resumeRead()
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(await fixture.service.currentPreview == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.cache.path))
    }

    @Test("zero and oversized originals are rejected before a content read", arguments: [Int64(0), Int64(20 * 1_024 * 1_024 + 1)])
    func byteLimit(length: Int64) async throws {
        let fixture = try await ImageFixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        await fixture.provider.declareLength(length)
        let catalog = try await fixture.service.load(source: .androidPictures)
        await #expect(throws: PhoneImageError.limitExceeded) { try await fixture.service.preview(itemID: catalog.items[0].id) }
        #expect(await fixture.provider.reads == 0)
    }

    @Test("the 100 MP boundary cannot overflow; oversized corrupt headers cannot publish")
    func pixelLimit() async throws {
        #expect(ImageLibraryService.imageFitsPreview(width: 10_000, height: 10_000))
        #expect(!ImageLibraryService.imageFitsPreview(width: 10_001, height: 10_000))
        #expect(!ImageLibraryService.imageFitsPreview(width: Int.max, height: 2))
        let fixture = try await ImageFixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        var oversized = fixture.provider.bytes
        let dimensions: [UInt32] = [10_001, 10_000]
        for (index, dimension) in dimensions.enumerated() {
            for byte in 0..<4 { oversized[16 + index * 4 + byte] = UInt8(truncatingIfNeeded: dimension >> (24 - byte * 8)) }
        }
        var crc = UInt32.max
        for byte in oversized[12..<29] {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xedb88320 : crc >> 1 }
        }
        crc ^= UInt32.max
        for byte in 0..<4 { oversized[29 + byte] = UInt8(truncatingIfNeeded: crc >> (24 - byte * 8)) }
        await fixture.provider.replaceReadBytes(oversized)
        let catalog = try await fixture.service.load(source: .androidPictures)
        // ImageIO may reject inconsistent header/IDAT bytes before exposing their dimensions.
        do {
            _ = try await fixture.service.preview(itemID: catalog.items[0].id)
            Issue.record("Oversized corrupt header unexpectedly published")
        } catch let error as PhoneImageError {
            #expect(error == .invalidImage || error == .limitExceeded)
        }
        #expect(await fixture.service.currentPreview == nil)
    }
    @Test("a browser bound to an old generation cannot even enumerate after reconnect")
    func boundSession() async throws {
        let fixture = try await ImageFixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let identity = try #require(await fixture.store.snapshot().selectedDeviceIdentity)
        try await fixture.store.select(identity)
        await #expect(throws: PhoneImageError.stale) { try await fixture.service.load(source: .androidPictures) }
        #expect(await fixture.provider.lists == 0)
    }
    @Test("late pull after clear, disconnect or cancellation cannot publish", arguments: ["clear", "disconnect", "cancel"])
    func latePull(action: String) async throws {
        let fixture = try await ImageFixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let catalog = try await fixture.service.load(source: .androidPictures)
        await fixture.provider.suspendNextRead()
        let task = Task { try await fixture.service.preview(itemID: catalog.items[0].id) }
        while !(await fixture.provider.isSuspended) { await Task.yield() }
        if action == "clear" { await fixture.service.clear() }
        if action == "disconnect" { await fixture.store.disconnect() }
        if action == "cancel" { task.cancel() }
        await fixture.provider.resumeRead()
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(await fixture.service.currentPreview == nil)
        let retained = (try? FileManager.default.contentsOfDirectory(atPath: fixture.cache.path)) ?? []
        #expect(retained.isEmpty)
    }

    @Test("invalid image and wrong hash preserve the prior valid preview", arguments: [false, true])
    func failurePreservesPreview(wrongHash: Bool) async throws {
        let fixture = try await ImageFixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let catalog = try await fixture.service.load(source: .androidPictures)
        let preview = try await fixture.service.preview(itemID: catalog.items[0].id)
        await fixture.provider.failNextRead(wrongHash: wrongHash)
        await #expect(throws: wrongHash ? PhoneImageError.integrityMismatch : PhoneImageError.invalidImage) {
            try await fixture.service.preview(itemID: catalog.items[0].id)
        }
        #expect(await fixture.service.currentPreview == preview)
        let destination = fixture.directory.appending(path: "still-valid.png")
        _ = try await fixture.service.export(previewID: preview.id, destination: destination, replaceExisting: false)
        #expect(try Data(contentsOf: destination) == fixture.provider.bytes)
    }

    @Test("terminal export checks both session and source invalidation without touching destination", arguments: [false, true])
    func terminalGuard(disconnect: Bool) async throws {
        let fixture = try await ImageFixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let token = try await fixture.store.beginOperation(.fileReceive)
        let validity = ImageRequestValidity()
        let stage = fixture.directory.appending(path: "stage")
        let destination = fixture.directory.appending(path: "existing")
        try Data("new".utf8).write(to: stage)
        try Data("existing".utf8).write(to: destination)
        if disconnect { await fixture.store.disconnect() } else { validity.invalidate() }
        await #expect(throws: PhoneImageError.stale) {
            try await fixture.store.commitImageExport(token, validity: validity, staged: stage,
                destination: destination, replaceExisting: true)
        }
        #expect(try Data(contentsOf: destination) == Data("existing".utf8))
    }
    @Test("explicit listing only; preview decodes and export preserves original bytes")
    func originalRoundTrip() async throws {
        let fixture = try await ImageFixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        #expect(await fixture.provider.reads == 0)
        #expect(await fixture.provider.lists == 0)
        let catalog = try await fixture.service.load(source: .androidPictures)
        #expect(catalog.items.count == 1)
        #expect(await fixture.provider.reads == 0)
        let preview = try await fixture.service.preview(itemID: catalog.items[0].id)
        #expect(preview.pixelWidth == 4 && preview.pixelHeight == 3)
        #expect(!preview.thumbnailPNG.isEmpty && !preview.previewPNG.isEmpty)
        let destination = fixture.directory.appending(path: "export.png")
        _ = try await fixture.service.export(previewID: preview.id, destination: destination, replaceExisting: false)
        #expect(try Data(contentsOf: destination) == fixture.provider.bytes)
        await #expect(throws: PhoneImageError.destinationExists) {
            try await fixture.service.export(previewID: preview.id, destination: destination, replaceExisting: false)
        }
        await fixture.service.clear()
        #expect(await fixture.service.currentPreview == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.cache.path))
        #expect(FileManager.default.fileExists(atPath: destination.path))
    }

    @Test("refresh invalidates old item IDs and a disconnected session cannot export")
    func invalidation() async throws {
        let fixture = try await ImageFixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let old = try await fixture.service.load(source: .androidPictures)
        let refreshed = try await fixture.service.load(source: .androidPictures)
        await #expect(throws: PhoneImageError.stale) { try await fixture.service.preview(itemID: old.items[0].id) }
        let preview = try await fixture.service.preview(itemID: refreshed.items[0].id)
        await fixture.store.disconnect()
        let destination = fixture.directory.appending(path: "must-not-exist.png")
        await #expect(throws: (any Error).self) {
            try await fixture.service.export(previewID: preview.id, destination: destination, replaceExisting: false)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }
}

private struct ImageFixture {
    let store: DeviceSessionStore
    let provider: ImageProviderDouble
    let service: ImageLibraryService
    let directory: URL
    let cache: URL
    static func make() async throws -> Self {
        let identity = try DeviceIdentity(rawValue: "image-test", stability: .stable, platform: .android)
        let transport = try TransportCandidate(id: "7", identity: identity, kind: .usb,
                                              source: .adb, status: .available, observedAt: Date())
        let store = DeviceSessionStore()
        await store.replaceInventory([DeviceRecord(identity: identity, name: "Test phone",
            authorization: .authorized, candidates: [transport], preferredTransportID: "7")])
        let session = try #require(try await store.select(identity).session)
        let directory = FileManager.default.temporaryDirectory.appending(path: "image-tests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let cache = directory.appending(path: "cache")
        let provider = try ImageProviderDouble()
        return Self(store: store, provider: provider,
            service: ImageLibraryService(store: store, session: session, provider: provider, sessionDirectory: cache),
            directory: directory, cache: cache)
    }
}

private actor ImageProviderDouble: PhoneImageProviding {
    let bytes: Data
    var reads = 0
    var lists = 0
    private var shouldSuspend = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var failure: Bool?
    private var declaredLength: Int64?
    private var replacementBytes: Data?
    private var missingSourceHash = false
    func omitSourceHash() { missingSourceHash = true }
    func declareLength(_ length: Int64) { declaredLength = length }
    func replaceReadBytes(_ data: Data) { replacementBytes = data }
    var isSuspended: Bool { continuation != nil }
    func suspendNextRead() { shouldSuspend = true }
    func resumeRead() { continuation?.resume(); continuation = nil }
    func failNextRead(wrongHash: Bool) { failure = wrongHash }
    init() throws {
        let context = try #require(CGContext(data: nil, width: 4, height: 3, bitsPerComponent: 8,
            bytesPerRow: 16, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let output = NSMutableData()
        let encoder = try #require(CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(encoder, image, nil)
        try #require(CGImageDestinationFinalize(encoder))
        bytes = output as Data
    }
    func list(source: ImageSource, transportID: String,
              validateSession: @escaping @Sendable () async throws -> Void) async throws -> [ImageCandidate] {
        lists += 1
        return [ImageCandidate(source: source, path: (source.root ?? "/ios") + "/photo.png", byteLength: declaredLength ?? Int64(bytes.count), modifiedAt: Date())]
    }
    func receive(_ image: ImageCandidate, transportID: String, partialURL: URL,
                 validateSession: @escaping @Sendable () async throws -> Void) async throws -> DeviceFileReceipt {
        reads += 1
        if shouldSuspend {
            shouldSuspend = false
            await withCheckedContinuation { continuation = $0 }
        }
        let failure = failure
        self.failure = nil
        try (replacementBytes ?? (failure == false ? Data(repeating: 0, count: bytes.count) : bytes)).write(to: partialURL)
        let metadata = try FileIntegrity.metadata(for: partialURL)
        return DeviceFileReceipt(byteLength: metadata.byteLength, sha256: missingSourceHash ? nil : (failure == true ? "wrong" : metadata.sha256))
    }
}
