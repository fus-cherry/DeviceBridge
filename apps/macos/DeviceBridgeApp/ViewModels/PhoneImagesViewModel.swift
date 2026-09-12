import Combine
import DeviceBridgeCore
import Foundation

/// UI copies only. ImageLibraryService owns the catalog, opaque locators and retained original.
@MainActor
final class PhoneImagesViewModel: ObservableObject {
    @Published private(set) var source: ImageSource = .androidPictures
    @Published private(set) var catalog: ImageCatalog?
    @Published private(set) var preview: ImagePreview?
    @Published private(set) var selectedID: UUID?
    @Published private(set) var selectedDownloadIDs: Set<UUID> = []
    @Published private(set) var batchSummary: InterfaceMessage?
    @Published private(set) var batchFailures: [String] = []
    @Published private(set) var isBusy = false
    @Published private(set) var thumbnails: [UUID: Data] = [:]
    @Published private(set) var isLoadingThumbnails = false
    @Published private(set) var thumbnailErrors: [UUID: String] = [:]
    @Published private(set) var page = 0
    static let pageSize = 24
    @Published private(set) var feedback: String?
    @Published private(set) var replacementDestination: URL?
    private(set) var revision = 0
    private let service: ImageLibraryService
    private var task: Task<Void, Never>?
    private var thumbnailTask: Task<Void, Never>?
    private var thumbnailRevision = 0
    private var thumbnailsEnabled = false
    private var thumbnailOrder: [UUID] = []
    private var stopped = false

    let sources: [ImageSource]
    init(service: ImageLibraryService, sources: [ImageSource] = [.androidPictures, .androidDCIM, .androidDownload]) {
        precondition(!sources.isEmpty)
        self.service = service
        self.sources = sources
        source = sources[0]
    }

    var pageCount: Int { max(1, ((catalog?.items.count ?? 0) + Self.pageSize - 1) / Self.pageSize) }
    var pageItems: [ImageItem] { Array((catalog?.items ?? []).dropFirst(page * Self.pageSize).prefix(Self.pageSize)) }

    func showPage(_ page: Int) {
        guard !stopped, catalog != nil else { return }
        self.page = min(max(0, page), pageCount - 1)
        thumbnailsEnabled = true
        startThumbnails()
    }

    func suspendThumbnails() {
        thumbnailsEnabled = false
        _ = cancelThumbnailWork()
    }

    private func cancelThumbnailWork() -> Task<Void, Never>? {
        thumbnailRevision += 1
        thumbnailTask?.cancel()
        isLoadingThumbnails = false
        return thumbnailTask
    }

    private func startThumbnails() {
        guard !stopped, thumbnailsEnabled, !isBusy, let catalog else { return }
        let previous = cancelThumbnailWork()
        let expected = thumbnailRevision
        let items = pageItems
        isLoadingThumbnails = true
        thumbnailTask = Task {
            await previous?.value
            guard expected == thumbnailRevision, !Task.isCancelled else { return }
            for item in items {
                guard expected == thumbnailRevision, !Task.isCancelled else { return }
                if thumbnails[item.id] != nil || thumbnailErrors[item.id] != nil { continue }
                do {
                    let bytes = try await service.thumbnail(itemID: item.id)
                    guard expected == thumbnailRevision, self.catalog?.id == catalog.id,
                          !Task.isCancelled else { return }
                    cacheThumbnail(bytes, for: item.id)
                } catch {
                    guard expected == thumbnailRevision, !Task.isCancelled else { return }
                    // Do not fill the album with failures when another feature owns the device.
                    if error as? DeviceSessionStoreError == .connectionBusy {
                        feedback = Self.message(error)
                        break
                    }
                    thumbnailErrors[item.id] = Self.message(error)
                }
            }
            guard expected == thumbnailRevision else { return }
            isLoadingThumbnails = false
        }
    }

    private func cacheThumbnail(_ bytes: Data, for id: UUID) {
        thumbnailOrder.removeAll { $0 == id }
        thumbnailOrder.append(id)
        thumbnails[id] = bytes
        // Two pages at most, additionally bounded by encoded bytes.
        while thumbnailOrder.count > 48 || thumbnails.values.reduce(0, { $0 + $1.count }) > 20 * 1_024 * 1_024 {
            thumbnails.removeValue(forKey: thumbnailOrder.removeFirst())
        }
    }

    private func clearThumbnails() {
        thumbnailsEnabled = false
        thumbnails.removeAll()
        thumbnailOrder.removeAll()
        thumbnailErrors.removeAll()
        page = 0
    }

    func changeSource(_ source: ImageSource) {
        guard sources.contains(source) else { return }
        self.source = source
        reset()
    }

    func load() {
        guard !stopped else { return }
        revision += 1
        let expected = revision
        let previous = task
        previous?.cancel()
        let previousThumbnail = cancelThumbnailWork()
        clearThumbnails()
        catalog = nil
        replacementDestination = nil
        preview = nil
        selectedID = nil
        selectedDownloadIDs.removeAll()
        batchSummary = nil
        batchFailures = []
        feedback = nil
        isBusy = true
        let source = source
        task = Task {
            await previousThumbnail?.value
            await previous?.value
            guard revision == expected, !Task.isCancelled else { return }
            await service.clear()
            guard revision == expected, !Task.isCancelled else { return }
            do {
                let result = try await service.load(source: source)
                guard revision == expected, !Task.isCancelled else { return }
                catalog = result
                feedback = result.items.isEmpty ? "No images in this shared folder." : nil
            } catch {
                guard revision == expected else { return }
                feedback = Self.message(error)
            }
            isBusy = false
            startThumbnails()
        }
    }

    func select(_ item: ImageItem) {
        guard !stopped, catalog?.items.contains(where: { $0.id == item.id }) == true else { return }
        revision += 1
        let expected = revision
        let previous = task
        previous?.cancel()
        let previousThumbnail = cancelThumbnailWork()
        selectedID = item.id
        replacementDestination = nil
        feedback = nil
        isBusy = true
        task = Task {
            // Drain cancellation before the next read: at most one transfer/decode per browser.
            await previousThumbnail?.value
            await previous?.value
            guard revision == expected, !Task.isCancelled else { return }
            do {
                let result = try await service.preview(itemID: item.id)
                guard revision == expected, !Task.isCancelled else { return }
                preview = result
                cacheThumbnail(result.thumbnailPNG, for: item.id)
            } catch {
                let committed = await service.currentPreview
                guard revision == expected else { return }
                preview = committed?.catalogID == catalog?.id ? committed : nil
                feedback = Self.message(error)
            }
            isBusy = false
            startThumbnails()
        }
    }

    func toggleDownload(_ item: ImageItem) {
        guard !stopped, !isBusy, catalog?.items.contains(where: { $0.id == item.id }) == true else { return }
        if !selectedDownloadIDs.insert(item.id).inserted { selectedDownloadIDs.remove(item.id) }
    }

    func selectPageForDownload() {
        guard !stopped, !isBusy else { return }
        selectedDownloadIDs.formUnion(pageItems.map(\.id))
    }

    func clearDownloadSelection() {
        guard !stopped, !isBusy else { return }
        selectedDownloadIDs.removeAll()
    }

    // The model owns selection and serial orchestration; the service retains one original at
    // a time and owns verified, exclusive file commits. Never buffer an entire selection.
    func exportSelected(expectedRevision: Int, itemIDs: Set<UUID>, directory: URL) {
        guard !stopped, !isBusy, revision == expectedRevision,
              !itemIDs.isEmpty, itemIDs == selectedDownloadIDs, let catalog else { return }
        let items = catalog.items.filter { itemIDs.contains($0.id) }
        guard items.count == itemIDs.count else { return }
        isBusy = true
        feedback = nil
        replacementDestination = nil
        batchFailures = []
        batchSummary = InterfaceMessage("Saved {0} of {1} · skipped or failed {2}",
            arguments: ["0", String(items.count), "0"])
        let previousThumbnail = cancelThumbnailWork()
        task = Task {
            await previousThumbnail?.value
            guard revision == expectedRevision, !Task.isCancelled else { return }
            var saved = 0
            for item in items {
                guard revision == expectedRevision, !Task.isCancelled else { return }
                do {
                    let original = try await service.preview(itemID: item.id)
                    guard revision == expectedRevision, !Task.isCancelled else { return }
                    preview = original
                    selectedID = item.id
                    _ = try await service.export(previewID: original.id,
                        destination: directory.appendingPathComponent(item.displayName), replaceExisting: false)
                    guard revision == expectedRevision, !Task.isCancelled else { return }
                    saved += 1
                } catch {
                    let committed = await service.currentPreview
                    guard revision == expectedRevision, !Task.isCancelled else { return }
                    preview = committed?.catalogID == catalog.id ? committed : nil
                    batchFailures.append(item.displayName)
                    feedback = Self.message(error)
                }
                batchSummary = InterfaceMessage("Saved {0} of {1} · skipped or failed {2}",
                    arguments: [String(saved), String(items.count), String(batchFailures.count)])
            }
            isBusy = false
            startThumbnails()
        }
    }

    func export(previewID: UUID, expectedRevision: Int, destination: URL, replaceExisting: Bool) {
        guard !stopped, !isBusy, revision == expectedRevision, preview?.id == previewID else { return }
        isBusy = true
        feedback = nil
        replacementDestination = nil
        let previousThumbnail = cancelThumbnailWork()
        task = Task {
            await previousThumbnail?.value
            guard revision == expectedRevision, !Task.isCancelled else { return }
            do {
                _ = try await service.export(previewID: previewID, destination: destination, replaceExisting: replaceExisting)
                guard revision == expectedRevision, !Task.isCancelled else { return }
                feedback = preview?.sourceHashVerified == true ? "Original exported · SHA-256 verified"
                    : "Original format exported · local copy verified; device checksum unavailable"
            } catch {
                guard revision == expectedRevision else { return }
                feedback = Self.message(error)
                if error as? PhoneImageError == .destinationExists { replacementDestination = destination }
            }
            isBusy = false
            startThumbnails()
        }
    }

    func cancel() {
        revision += 1
        isBusy = true // Cancellation reconciliation must drain before another action can start.
        let expected = revision
        let previous = task
        previous?.cancel()
        thumbnailsEnabled = false
        let previousThumbnail = cancelThumbnailWork()
        replacementDestination = nil
        task = Task {
            await previousThumbnail?.value
            await previous?.value
            let committed = await service.currentPreview
            guard revision == expected else { return }
            preview = committed?.catalogID == catalog?.id ? committed : nil
            isBusy = false
            feedback = "Image operation cancelled."
        }
    }

    func stop() { stopped = true; reset() }

    func confirmReplacement(destination: URL, expectedRevision: Int) {
        guard revision == expectedRevision, replacementDestination == destination, let preview else { return }
        export(previewID: preview.id, expectedRevision: revision, destination: destination, replaceExisting: true)
    }

    private func reset() {
        revision += 1
        let expected = revision
        let previous = task
        previous?.cancel()
        let previousThumbnail = cancelThumbnailWork()
        clearThumbnails()
        catalog = nil
        replacementDestination = nil
        preview = nil
        selectedID = nil
        selectedDownloadIDs.removeAll()
        batchSummary = nil
        batchFailures = []
        feedback = nil
        isBusy = true
        task = Task {
            await previousThumbnail?.value
            await previous?.value
            await service.clear()
            guard revision == expected else { return }
            isBusy = false
        }
    }

    private static func message(_ error: any Error) -> String {
        switch error {
        case PhoneImageError.limitExceeded: "Image limit exceeded (20 MiB / 100 MP, or folder scan limit)."
        case PhoneImageError.invalidImage: "This image is damaged or its format cannot be decoded."
        case PhoneImageError.integrityMismatch, PhoneImageError.sourceChanged:
            "The original changed or verification failed. Refresh and retry."
        case PhoneImageError.destinationExists: "A file already exists at this destination."
        case PhoneImageError.stale: "The image session changed. Load images again."
        case PhoneImageError.iosRestricted: "Unlock the iPhone and allow USB photo access, then load images again."
        case PhoneImageError.iosSessionCloseFailed: "The iPhone did not confirm closing its photo session. Reconnect its cable and restart DeviceBridge."
        case PhoneImageError.identityMismatch: "Cannot match the selected iPhone to a USB photo device. Reconnect its cable and retry."
        case PhoneImageError.representationUnavailable: "The iPhone did not provide original-format media. Conversion is not exported as an original."
        case PhoneImageError.busy, DeviceSessionStoreError.connectionBusy:
            "Connection or image operation in progress. Retry shortly."
        case is CancellationError, HostCommandError.cancelled: "Image operation cancelled."
        case HostCommandError.timedOut: "Image access timed out. Check the connection and retry."
        case HostCommandError.outputLimitExceeded: "Image limit exceeded (20 MiB / 100 MP, or folder scan limit)."
        default: "Cannot read this image source. Check device authorization and connection."
        }
    }
}
