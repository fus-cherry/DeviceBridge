import Foundation
import ImageIO
import Darwin

public actor ImageLibraryService {
    private let store: DeviceSessionStore
    private let session: ConnectionSession
    private let provider: any PhoneImageProviding
    private let directory: URL
    private var locators: [UUID: ImageCandidate] = [:]
    private var original: URL?
    private var originalReceipt: DeviceFileReceipt?
    private var busy = false
    private var request: ImageRequestValidity?
    private var listingTask: Task<[ImageCandidate], Error>?
    private var receivingTask: Task<DeviceFileReceipt, Error>?
    public private(set) var catalog: ImageCatalog?
    public private(set) var currentPreview: ImagePreview?
    public init(store: DeviceSessionStore, session: ConnectionSession, provider: any PhoneImageProviding, sessionDirectory: URL) {
        self.store = store
        self.session = session
        self.provider = provider
        directory = sessionDirectory
    }

    public func load(source: ImageSource) async throws -> ImageCatalog {
        guard !busy else { throw PhoneImageError.busy }
        await clear()
        try Task.checkCancellation()
        guard !busy else { throw PhoneImageError.busy }
        let validity = beginRequest()
        defer { endRequest() }
        let token = try await store.beginOperation(.fileReceive)
        do {
            try await check(token, validity)
            let worker = Task {
                try await provider.list(source: source, transportID: token.transportID,
                    validateSession: { [store] in
                        guard await store.canPublish(token) else { throw PhoneImageError.stale }
                        try validity.check()
                    })
            }
            listingTask = worker
            let candidates = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: { worker.cancel() }
            try await check(token, validity)
            var mapping: [UUID: ImageCandidate] = [:]
            let items = candidates.map { candidate in
                let id = UUID()
                mapping[id] = candidate
                return ImageItem(id: id, displayName: candidate.displayName,
                    relativeDirectory: candidate.relativeDirectory, byteLength: candidate.byteLength,
                    modifiedAt: candidate.modifiedAt)
            }
            let result = ImageCatalog(id: UUID(), sourceDevice: token.deviceIdentity,
                sessionGeneration: token.sessionGeneration, source: source, items: items)
            locators = mapping
            catalog = result
            await store.finishOperation(token)
            // Publication is committed. Cancellation during reservation release is too late
            // to turn this success into failure; UI reconciles from authoritative state.
            return result
        } catch {
            await store.finishOperation(token)
            throw error
        }
    }

    public func thumbnail(itemID: UUID) async throws -> Data {
        try await readImage(itemID: itemID, retainOriginal: false).thumbnailPNG
    }

    public func preview(itemID: UUID) async throws -> ImagePreview {
        try await readImage(itemID: itemID, retainOriginal: true)
    }

    /// One bounded read/verification path. Album reads never become the selected export source.
    private func readImage(itemID: UUID, retainOriginal: Bool) async throws -> ImagePreview {
        guard !busy else { throw PhoneImageError.busy }
        guard let catalog, let locator = locators[itemID],
              let item = catalog.items.first(where: { $0.id == itemID }) else { throw PhoneImageError.stale }
        guard item.byteLength > 0, item.byteLength <= 20 * 1_024 * 1_024 else { throw PhoneImageError.limitExceeded }
        let validity = beginRequest()
        defer { endRequest() }
        let token = try await store.beginOperation(.fileReceive)
        let partial = directory.appending(path: UUID().uuidString + ".partial")
        do {
            try await check(token, validity, catalog: catalog)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let worker = Task {
                try await provider.receive(locator, transportID: token.transportID, partialURL: partial,
                    validateSession: { [store] in
                        guard await store.canPublish(token) else { throw PhoneImageError.stale }
                        try validity.check()
                    })
            }
            receivingTask = worker
            let receipt = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: { worker.cancel() }
            try await check(token, validity, catalog: catalog)
            let actual = try FileIntegrity.metadata(for: partial)
            guard actual.byteLength == item.byteLength, receipt.byteLength == actual.byteLength,
                  receipt.sha256 == actual.sha256 || (catalog.source == .iosUSBCameraImport && receipt.sha256 == nil)
                else { throw PhoneImageError.integrityMismatch }
            let decoded = try Self.decode(partial, includePreview: retainOriginal)
            try await check(token, validity, catalog: catalog)
            let result = ImagePreview(id: UUID(), catalogID: catalog.id, item: item,
                pixelWidth: decoded.width, pixelHeight: decoded.height, mediaType: decoded.type,
                thumbnailPNG: decoded.thumbnail, previewPNG: decoded.preview,
                sourceHashVerified: receipt.sha256 != nil)
            if retainOriginal {
                if let original { try? FileManager.default.removeItem(at: original) }
                original = partial
                originalReceipt = DeviceFileReceipt(byteLength: actual.byteLength, sha256: actual.sha256)
                currentPreview = result
            } else {
                try FileManager.default.removeItem(at: partial)
            }
            await store.finishOperation(token)
            return result
        } catch {
            try? FileManager.default.removeItem(at: partial)
            await store.finishOperation(token)
            throw error
        }
    }

    public func export(previewID: UUID, destination: URL, replaceExisting: Bool) async throws -> URL {
        guard !busy else { throw PhoneImageError.busy }
        guard let catalog, currentPreview?.id == previewID, let original, let originalReceipt else {
            throw PhoneImageError.stale
        }
        let validity = beginRequest()
        defer { endRequest() }
        let token = try await store.beginOperation(.fileReceive)
        // Stage next to the user's destination so the final rename is atomic on one volume.
        let staged = destination.deletingLastPathComponent().appending(path: ".devicebridge-image-\(UUID()).partial")
        defer { try? FileManager.default.removeItem(at: staged) }
        do {
            try await check(token, validity, catalog: catalog)
            try FileManager.default.copyItem(at: original, to: staged)
            let metadata = try FileIntegrity.metadata(for: staged)
            guard metadata.byteLength == originalReceipt.byteLength,
                  metadata.sha256 == originalReceipt.sha256 else { throw PhoneImageError.integrityMismatch }
            try await check(token, validity, catalog: catalog)
            try await store.commitImageExport(token, validity: validity, staged: staged,
                                               destination: destination, replaceExisting: replaceExisting)
            await store.finishOperation(token)
            return destination
        } catch {
            await store.finishOperation(token)
            throw error
        }
    }

    public func clear() async {
        request?.invalidate()
        listingTask?.cancel()
        receivingTask?.cancel()
        locators.removeAll()
        catalog = nil
        currentPreview = nil
        originalReceipt = nil
        if let original { try? FileManager.default.removeItem(at: original) }
        original = nil
        if !busy { try? FileManager.default.removeItem(at: directory) }
        await provider.close()
    }

    private func beginRequest() -> ImageRequestValidity {
        request?.invalidate()
        let next = ImageRequestValidity()
        request = next
        busy = true
        return next
    }

    private func endRequest() {
        listingTask = nil
        receivingTask = nil
        busy = false
        if catalog == nil { try? FileManager.default.removeItem(at: directory) }
    }

    private func check(_ token: SessionToken, _ validity: ImageRequestValidity,
                       catalog expected: ImageCatalog? = nil) async throws {
        guard token.deviceIdentity == session.deviceIdentity,
              token.sessionGeneration == session.generation,
              token.transportID == session.transportID,
              await store.canPublish(token) else { throw PhoneImageError.stale }
        try validity.check()
        if let expected {
            guard catalog?.id == expected.id, token.deviceIdentity == expected.sourceDevice,
                  token.sessionGeneration == expected.sessionGeneration else { throw PhoneImageError.stale }
        }
    }

    /// ImageIO runs on this service actor, never on the UI actor. Original bytes are not re-encoded.
    private static func decode(_ url: URL, includePreview: Bool) throws -> (width: Int, height: Int, type: String, thumbnail: Data, preview: Data) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetStatus(source) == .statusComplete,
              let type = CGImageSourceGetType(source),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { throw PhoneImageError.invalidImage }
        guard imageFitsPreview(width: width, height: height) else { throw PhoneImageError.limitExceeded }
        func png(maximum: Int) throws -> Data {
            try Task.checkCancellation()
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximum,
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary) else { throw PhoneImageError.invalidImage }
            let bytes = NSMutableData()
            guard let encoder = CGImageDestinationCreateWithData(bytes, "public.png" as CFString, 1, nil) else {
                throw PhoneImageError.invalidImage
            }
            CGImageDestinationAddImage(encoder, image, nil)
            guard CGImageDestinationFinalize(encoder) else { throw PhoneImageError.invalidImage }
            return bytes as Data
        }
        return try (width, height, type as String, png(maximum: 320), includePreview ? png(maximum: 2_048) : Data())
    }

    static func imageFitsPreview(width: Int, height: Int) -> Bool {
        width > 0 && height > 0 && width <= 100_000_000 / height
    }
}

/// A short synchronous invalidation/commit boundary, not another owner of image state.
/// clear() and the terminal rename serialize on this lock; no lock is held across an await.
final class ImageRequestValidity: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true
    func invalidate() { lock.withLock { valid = false } }
    func check() throws {
        try lock.withLock {
            try Task.checkCancellation()
            guard valid else { throw PhoneImageError.stale }
        }
    }
    func commit(staged: URL, destination: URL, replaceExisting: Bool) throws {
        try lock.withLock {
            try Task.checkCancellation()
            guard valid else { throw PhoneImageError.stale }
            let flags = replaceExisting ? UInt32(0) : UInt32(RENAME_EXCL)
            guard renamex_np(staged.path, destination.path, flags) == 0 else {
                if errno == EEXIST { throw PhoneImageError.destinationExists }
                throw CocoaError(.fileWriteUnknown)
            }
        }
    }
}

extension DeviceSessionStore {
    /// Device invalidation cannot interleave between the token check and the terminal rename.
    func commitImageExport(_ token: SessionToken, validity: ImageRequestValidity,
                           staged: URL, destination: URL, replaceExisting: Bool) throws {
        guard canPublish(token) else { throw PhoneImageError.stale }
        try validity.commit(staged: staged, destination: destination, replaceExisting: replaceExisting)
    }
}
