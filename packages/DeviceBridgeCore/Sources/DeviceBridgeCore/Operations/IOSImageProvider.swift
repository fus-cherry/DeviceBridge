import Foundation
import ImageCaptureCore
import IOKit

/// One admission state for the framework session. Invalidation is terminal for this instance.
struct IOSPhotoAccessState {
    private enum Phase { case opening, waitingForUnlock, open, failed, invalid }
    private var phase = Phase.opening
    private var complete = false
    var isInvalid: Bool { phase == .invalid }
    var isReady: Bool { phase == .open && complete }
    var hasFailed: Bool { phase == .failed }
    mutating func opened(errorCode: Int?) {
        guard phase != .invalid else { return }
        phase = errorCode == nil ? .open : (errorCode == -9943 ? .waitingForUnlock : .failed)
    }
    mutating func unlocked(hasSession: Bool, restricted: Bool) {
        if phase == .waitingForUnlock && hasSession && !restricted { phase = .open }
    }
    mutating func catalogCompleted() { if phase != .invalid { complete = true } }
    mutating func invalidate() { phase = .invalid }
    func check(hasSession: Bool, restricted: Bool, original: Bool) throws {
        guard phase != .invalid else { throw PhoneImageError.stale }
        guard !restricted else { throw PhoneImageError.iosRestricted }
        guard isReady && hasSession else { throw PhoneImageError.scopeUnavailable }
        guard original else { throw PhoneImageError.representationUnavailable }
    }
}

/// Main-actor boundary for Apple objects only. The image service still owns catalog/preview publication.
@MainActor
public final class IOSImageProvider: PhoneImageProviding {
    private let identity: DeviceIdentity
    private let transportID: String
    private let discovery: IOSPhotoDiscovery
    private var connection: IOSPhotoSession?
    private var revision = 0
    private var busy = false
    private var teardown: Task<Bool, Never>?
    public init(identity: DeviceIdentity, transportID: String, discovery: IOSPhotoDiscovery = IOSPhotoDiscovery()) {
        self.identity = identity
        self.transportID = transportID
        self.discovery = discovery
    }
    public func list(source: ImageSource, transportID: String,
                     validateSession: @escaping @Sendable () async throws -> Void) async throws -> [ImageCandidate] {
        guard source == .iosUSBCameraImport, identity.platform == .iOS,
              identity.stability == .stable else { throw PhoneImageError.unsupported }
        guard transportID == self.transportID else { throw PhoneImageError.stale }
        guard !busy else { throw PhoneImageError.busy }
        busy = true
        defer { busy = false }
        await close()
        guard await teardown?.value != false else { throw PhoneImageError.iosSessionCloseFailed }
        try Task.checkCancellation()
        try await validateSession()
        let expected = revision
        let session = IOSPhotoSession(udid: identity.rawValue, discovery: discovery)
        connection = session
        do {
            let entries = try await session.open(validate: validateSession)
            try Task.checkCancellation()
            try await validateSession()
            guard revision == expected, connection === session else { throw PhoneImageError.stale }
            return entries
        } catch {
            if connection === session { await close() }
            else { _ = await session.close() }
            throw error
        }
    }
    public func receive(_ image: ImageCandidate, transportID: String, partialURL: URL,
                        validateSession: @escaping @Sendable () async throws -> Void) async throws -> DeviceFileReceipt {
        guard transportID == self.transportID, let session = connection else { throw PhoneImageError.stale }
        guard !busy else { throw PhoneImageError.busy }
        busy = true
        defer { busy = false }
        let expected = revision
        try Task.checkCancellation()
        try await validateSession()
        guard expected == revision, connection === session else { throw PhoneImageError.stale }
        try await session.receive(image, destination: partialURL, validate: validateSession)
        do {
            try Task.checkCancellation()
            try await validateSession()
            guard expected == revision, connection === session else { throw PhoneImageError.stale }
            return DeviceFileReceipt(byteLength: image.byteLength, sha256: nil)
        } catch {
            try? FileManager.default.removeItem(at: partialURL)
            throw error
        }
    }
    public func close() async {
        revision += 1
        let old = connection
        connection = nil
        if let old {
            let previous = teardown
            teardown = Task { @MainActor in
                let previousClosed = await previous?.value ?? true
                let closed = await old.close()
                return previousClosed && closed
            }
        }
        _ = await teardown?.value
    }
}

/// One browser per workspace: ICC did not rediscover cameras after browser stop/recreation in-process.
/// This owner also serializes native session handoff across different selected-device providers.
@MainActor
public final class IOSPhotoDiscovery: NSObject, @preconcurrency ICDeviceBrowserDelegate {
    private var closeFailed = false
    func recordClose(acknowledged: Bool) { if !acknowledged { closeFailed = true } }
    func checkTeardown() throws { if closeFailed { throw PhoneImageError.iosSessionCloseFailed } }
    fileprivate let browser = ICDeviceBrowser()
    private weak var currentSession: IOSPhotoSession?
    private var revision = 0
    private var started = false
    public override init() { super.init() }
    fileprivate func prepare(_ session: IOSPhotoSession) async throws {
        try checkTeardown()
        revision += 1
        let expected = revision
        if let previous = currentSession, previous !== session {
            guard await previous.close() else { throw PhoneImageError.iosSessionCloseFailed }
        }
        guard revision == expected else { throw PhoneImageError.stale }
        try checkTeardown()
        currentSession = session
        if !started {
            browser.delegate = self
            browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue:
                ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue)!
            browser.start()
            started = true
        }
    }
    fileprivate func owns(_ session: IOSPhotoSession) -> Bool { started && currentSession === session }
    public func stop() {
        revision += 1
        browser.stop()
        browser.delegate = nil
        started = false
    }
    public func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {}
    public func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        currentSession?.didRemove(device)
    }
}

/// Fresh media-session state per catalog; old callbacks cannot resurrect an invalidated catalog.
@MainActor
fileprivate final class IOSPhotoSession: NSObject, @preconcurrency ICCameraDeviceDelegate {
    private let udid: String
    private let discovery: IOSPhotoDiscovery
    private var browser: ICDeviceBrowser { discovery.browser }
    private var camera: ICCameraDevice?
    private var location: Int32?
    private var state = IOSPhotoAccessState()
    private var assets: [String: (ImageCandidate, ICCameraFile)] = [:]
    private var download: IOSPhotoDownload?
    private var closeAcknowledged = false
    private var teardown: Task<Bool, Never>?
    init(udid: String, discovery: IOSPhotoDiscovery) { self.udid = udid; self.discovery = discovery }

    func open(validate: @escaping @Sendable () async throws -> Void) async throws -> [ImageCandidate] {
        try await discovery.prepare(self)
        for _ in 0..<100 {
            try await validateCurrent(validate)
            let locations = Self.usbLocations(for: udid)
            let matches = (browser.devices ?? []).compactMap { $0 as? ICCameraDevice }.filter {
                $0.transportType == ICDeviceTransport.transportTypeUSB.rawValue && $0.usbLocationID != 0
                    && locations.contains($0.usbLocationID)
            }
            if locations.count == 1 && matches.count == 1 {
                camera = matches[0]; location = locations[0]; break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard let camera, let location, Self.usbLocations(for: udid) == [location] else {
            throw PhoneImageError.identityMismatch
        }
        try await validateCurrent(validate)
        camera.delegate = self
        camera.mediaPresentation = .originalAssets
        requestOpen(camera)
        for _ in 0..<300 {
            try await validateCurrent(validate)
            if state.isReady || state.hasFailed { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        if !state.isReady && !state.hasFailed && !camera.isAccessRestrictedAppleDevice {
            throw HostCommandError.timedOut
        }
        try checkContent()
        let files = (camera.mediaFiles ?? []).compactMap { $0 as? ICCameraFile }
        guard files.count <= 10_000 else { throw PhoneImageError.limitExceeded }
        var metadataBytes = 0
        for file in files {
            guard let name = file.name else { continue }
            let suffix = (name as NSString).pathExtension.lowercased()
            guard ["png", "jpg", "jpeg", "heic", "heif"].contains(suffix) else { continue }
            guard !name.contains("/"), !name.contains("\0"), !name.contains("\\"),
                  file.fileSize >= 0 else { throw PhoneImageError.malformedMetadata }
            metadataBytes += name.utf8.count + 128
            guard metadataBytes <= 4 * 1_024 * 1_024 else { throw PhoneImageError.limitExceeded }
            // The UUID is the locator; names are display data and never download destinations.
            let key = "/\(UUID())/\(name)"
            let candidate = ImageCandidate(source: .iosUSBCameraImport, path: key,
                byteLength: file.fileSize, modifiedAt: file.modificationDate ?? file.creationDate ?? .distantPast)
            assets[key] = (candidate, file)
        }
        return assets.values.map(\.0).sorted {
            $0.modifiedAt == $1.modifiedAt ? $0.displayName < $1.displayName : $0.modifiedAt > $1.modifiedAt
        }
    }

    func receive(_ image: ImageCandidate, destination: URL,
                 validate: @escaping @Sendable () async throws -> Void) async throws {
        try await validateCurrent(validate)
        try checkContent()
        guard image.source == .iosUSBCameraImport, let (original, file) = assets[image.path],
              original == image, file.fileSize == image.byteLength,
              camera?.mediaFiles?.contains(where: { $0 === file }) == true else { throw PhoneImageError.sourceChanged }
        guard image.byteLength > 0 && image.byteLength <= 20 * 1_024 * 1_024 else { throw PhoneImageError.limitExceeded }
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw PhoneImageError.destinationExists }
        let request = try IOSPhotoDownload(parent: destination.deletingLastPathComponent(),
            suffix: (image.displayName as NSString).pathExtension.lowercased())
        download = request
        defer { download = nil }
        request.progress = file.requestDownload(options: [.downloadsDirectoryURL: request.directory,
            .saveAsFilename: request.file.lastPathComponent, .overwrite: false,
            .deleteAfterSuccessfulDownload: false, .sidecarFiles: false,
            .truncateAfterSuccessfulDownload: false]) { @Sendable filename, error in
            Task { @MainActor in request.complete(filename: filename, errorCode: (error as NSError?)?.code) }
        }
        do {
            for _ in 0..<300 {
                try await validateCurrent(validate)
                try checkContent()
                try request.checkByteLimit(image.byteLength)
                if request.result != nil { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            try await validateCurrent(validate)
            try checkContent()
            guard let result = request.result else { throw HostCommandError.timedOut }
            try result.get()
            guard file.fileSize == image.byteLength,
                  (try FileManager.default.attributesOfItem(atPath: request.file.path)[.size] as? NSNumber)?.int64Value == image.byteLength else {
                throw PhoneImageError.integrityMismatch
            }
            // Same-volume exclusive move; the service does decoding/hashing off the main actor.
            try FileManager.default.moveItem(at: request.file, to: destination)
        } catch {
            if !(await request.cancelAndDrain()) { state.invalidate() }
            throw error
        }
        if !(await request.cancelAndDrain()) { state.invalidate() }
    }

    private func validateCurrent(_ validate: @Sendable () async throws -> Void) async throws {
        try Task.checkCancellation()
        guard !state.isInvalid, discovery.owns(self) else { throw PhoneImageError.stale }
        try await validate()
        try Task.checkCancellation()
        guard !state.isInvalid, discovery.owns(self) else { throw PhoneImageError.stale }
        if let location, Self.usbLocations(for: udid) != [location] {
            state.invalidate()
            throw PhoneImageError.stale
        }
    }
    private func checkContent() throws {
        guard let camera else { throw PhoneImageError.stale }
        try state.check(hasSession: camera.hasOpenSession, restricted: camera.isAccessRestrictedAppleDevice,
                        original: camera.mediaPresentation == .originalAssets)
    }
    private func requestOpen(_ camera: ICCameraDevice) { camera.requestOpenSession() }
    private func requestClose(_ camera: ICCameraDevice) { camera.requestCloseSession() }
    func close() async -> Bool {
        if let teardown { return await teardown.value }
        state.invalidate()
        assets.removeAll()
        download?.cancel()
        let task = Task { @MainActor in await self.finishClosing() }
        teardown = task
        return await task.value
    }
    private func finishClosing() async -> Bool {
        guard let camera else { return true }
        requestClose(camera)
        // Teardown must run even when the caller's task has already been cancelled.
        for _ in 0..<50 {
            if closeAcknowledged { break }
            await Task.detached { try? await Task.sleep(for: .milliseconds(100)) }.value
        }
        camera.delegate = nil
        self.camera = nil
        discovery.recordClose(acknowledged: closeAcknowledged)
        return closeAcknowledged
    }

    func device(_ device: ICDevice, didOpenSessionWithError error: (any Error)?) {
        guard device === camera else { return }
        if state.isInvalid { requestClose(camera!); return }
        state.opened(errorCode: (error as NSError?)?.code)
    }
    func device(_ device: ICDevice, didCloseSessionWithError error: (any Error)?) {
        guard device === camera else { return }
        closeAcknowledged = error == nil
        state.invalidate()
    }
    func didRemove(_ device: ICDevice) { if device === camera { state.invalidate(); download?.cancel() } }
    func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        if device === camera { state.catalogCompleted() }
    }
    func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {
        if device === camera, let camera {
            state.unlocked(hasSession: camera.hasOpenSession, restricted: camera.isAccessRestrictedAppleDevice)
        }
    }
    func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {
        if device === camera && state.isReady { state.invalidate(); download?.cancel() }
    }
    func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {}
    func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {
        if camera === self.camera { state.invalidate(); download?.cancel() }
    }
    func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {
        if camera === self.camera { state.invalidate(); download?.cancel() }
    }
    func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: (any Error)?) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: (any Error)?) {}
    func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, shouldGetMetadataOf item: ICCameraItem) -> Bool { false }

    private static func usbLocations(for udid: String) -> [Int32] {
        let canonical = udid.replacingOccurrences(of: "-", with: "").uppercased()
        guard canonical.count >= 24, canonical.allSatisfy({ $0.isHexDigit }) else { return [] }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var locations: [Int32] = []
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            func property(_ key: String) -> Any? {
                IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            guard (property("idVendor") as? NSNumber)?.intValue == 1452,
                  let serial = property("USB Serial Number") as? String,
                  serial.replacingOccurrences(of: "-", with: "").uppercased() == canonical,
                  let location = property("locationID") as? NSNumber else { continue }
            locations.append(location.int32Value)
        }
        return locations
    }
}

/// Owns one private partial directory. A late callback can clean only this request's files.
@MainActor
final class IOSPhotoDownload {
    func cancelAndDrain(timeout: Duration = .seconds(5)) async -> Bool {
        cancel()
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !finished && ContinuousClock.now < deadline {
            await Task.detached { try? await Task.sleep(for: .milliseconds(50)) }.value
        }
        return finished
    }
    func checkByteLimit(_ limit: Int64) throws {
        guard active else { throw CancellationError() }
        // ICC can use a temporary filename. Account for every file in our private directory.
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
        var count: Int64 = 0
        for file in files {
            count += Int64(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            if count > limit { cancel(); throw PhoneImageError.limitExceeded }
        }
    }
    let directory: URL
    let file: URL
    var progress: Progress?
    private var active = true
    private var finished = false
    private(set) var result: Result<Void, PhoneImageError>?
    init(parent: URL, suffix: String) throws {
        guard ["png", "jpg", "jpeg", "heic", "heif"].contains(suffix) else { throw PhoneImageError.unsupported }
        directory = parent.appending(path: "ios-download-\(UUID())")
        file = directory.appending(path: "asset.\(suffix)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
    }
    func complete(filename: String?, errorCode: Int?) {
        finished = true
        guard active else { try? FileManager.default.removeItem(at: directory); return }
        result = errorCode == nil && filename.map({ ($0 as NSString).lastPathComponent }) == file.lastPathComponent
            ? .success(()) : .failure(.scopeUnavailable)
    }
    func cancel() {
        active = false
        progress?.cancel()
        try? FileManager.default.removeItem(at: directory)
    }
}
