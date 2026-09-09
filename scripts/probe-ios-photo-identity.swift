import AppKit
import DeviceBridgeCore
import ImageCaptureCore
import IOKit
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

/// T102 identity stage; a separate opt-in permits catalog-only session testing.
@MainActor
final class CameraIdentityProbe: NSObject, @preconcurrency ICDeviceBrowserDelegate {
    let browser = ICDeviceBrowser()
    var finishedLocalEnumeration = false

    func start() {
        browser.delegate = self
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue:
            ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue)!
        browser.start()
    }
    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {}
    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {}
    func deviceBrowserDidEnumerateLocalDevices(_ browser: ICDeviceBrowser) {
        finishedLocalEnumeration = true
    }
}

@MainActor
final class CameraCatalogProbe: NSObject, @preconcurrency ICCameraDeviceDelegate {
    let camera: ICCameraDevice
    var opened = false
    var complete = false
    var failed = false
    var active = true
    var closeAcknowledged = false
    var openErrorCode: Int?
    private var requestRevision = 0
    private var thumbnailResult: Result<Data, ProbeFailure>?
    private var downloadResult: Result<String, ProbeFailure>?
    init(camera: ICCameraDevice) { self.camera = camera }
    func device(_ device: ICDevice, didOpenSessionWithError error: (any Error)?) {
        recordOpen(device, error: error)
    }
    private func recordOpen(_ device: ICDevice, error: (any Error)?) {
        guard device === camera else { return }
        guard active else { if error == nil { device.requestCloseSession() }; return }
        opened = error == nil
        openErrorCode = (error as NSError?)?.code
        // Passcode-locked is a wait-for-unlock state while ICC keeps its media session open.
        // Only a later positive unlock callback plus a complete catalog may admit content.
        failed = error != nil && openErrorCode != -9943
        print("ICC callback: session open success=\(error == nil), restricted=\(camera.isAccessRestrictedAppleDevice)")
        if let error { print("ICC session error code=\((error as NSError).code); message withheld") }
    }
    func device(_ device: ICDevice, didCloseSessionWithError error: (any Error)?) {
        guard device === camera else { return }
        closeAcknowledged = error == nil
        active = false
        print("ICC callback: session close success=\(error == nil)")
    }
    func didRemove(_ device: ICDevice) { if device === camera { failed = true; active = false } }
    func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        if active && device === camera { complete = true }
        print("ICC callback: complete catalog")
    }
    func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {}
    func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {}
    func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: (any Error)?) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: (any Error)?) {}
    func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}
    func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {
        guard active, device === camera else { return }
        print("ICC callback: restriction removed, has open session=\(camera.hasOpenSession)")
        if openErrorCode == -9943 && camera.hasOpenSession && !camera.isAccessRestrictedAppleDevice {
            opened = true
        }
    }
    func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {
        if device === camera { print("ICC callback: restriction enabled") }
    }
    // ICC calls synchronous shouldGet callbacks from its worker queue. Do not read actor state
    // there. Explicit thumbnail dispatch/completion validate the session on the main actor.
    nonisolated func cameraDevice(_ camera: ICCameraDevice, shouldGetMetadataOf item: ICCameraItem) -> Bool { false }
    private func openSession() { camera.requestOpenSession() }
    private func closeSession() { camera.requestCloseSession() }

    enum ProbeFailure: Error { case failed(String) }

    private func checkSession() throws {
        guard active, opened, complete, !failed, !camera.isAccessRestrictedAppleDevice,
              camera.hasOpenSession else { throw ProbeFailure.failed("media session no longer valid") }
    }

    private func beginDownload(_ file: ICCameraFile, destination: URL, revision: Int,
                               completed: @escaping @MainActor @Sendable (Int?) -> Void = { _ in }) -> Progress? {
        let directory = destination.deletingLastPathComponent()
        return file.requestDownload(options: [.downloadsDirectoryURL: directory,
            .saveAsFilename: destination.lastPathComponent, .overwrite: false,
            .deleteAfterSuccessfulDownload: false, .sidecarFiles: false,
            .truncateAfterSuccessfulDownload: false]) { @Sendable [weak self] filename, error in
            Task { @MainActor in
                defer { completed((error as NSError?)?.code) }
                guard let self, self.active, self.requestRevision == revision else {
                    try? FileManager.default.removeItem(at: directory)
                    return
                }
                self.downloadResult = if let filename, error == nil { .success(filename) }
                    else { .failure(.failed("download request failed")) }
            }
        }
    }

    private final class CompletionFlag { var received = false; var errorCode: Int? }

    private func cancelSample(_ file: ICCameraFile) async throws {
        try checkSession()
        let directory = FileManager.default.temporaryDirectory.appending(path: "DeviceBridge-iOS-Probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        requestRevision += 1
        let completion = CompletionFlag()
        let progress = beginDownload(file, destination: directory.appending(path: "cancelled-sample.png"),
                                     revision: requestRevision) { completion.received = true; completion.errorCode = $0 }
        // Supersede before yielding: the real platform callback must not replace the newer result.
        requestRevision += 1
        downloadResult = .success("newer-result-marker")
        progress?.cancel()
        if progress == nil { camera.cancelDownload() }
        for _ in 0..<100 {
            if completion.received { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard completion.received, try downloadResult?.get() == "newer-result-marker",
              !FileManager.default.fileExists(atPath: directory.path) else {
            throw ProbeFailure.failed("cancel/late-callback isolation or cleanup not proven")
        }
        print("PASS: cancellation requested; late callback delivered, newer result retained, owned partial directory removed")
        print("Cancellation progress flag=\(progress?.isCancelled ?? false), completion error code=\(completion.errorCode.map(String.init) ?? "none")")
    }

    private func sample(_ file: ICCameraFile, index: Int) async throws {
        try checkSession()
        requestRevision += 1
        let revision = requestRevision
        thumbnailResult = nil
        file.requestThumbnailData(options: [.imageSourceThumbnailMaxPixelSize: 320,
                                            .imageSourceShouldCache: false]) { @Sendable [weak self] data, error in
            Task { @MainActor in
                guard let self, self.active, self.requestRevision == revision else { return }
                self.thumbnailResult = if let data, error == nil { .success(data) }
                    else { .failure(.failed("thumbnail request failed")) }
            }
        }
        for _ in 0..<100 {
            if thumbnailResult != nil { break }
            try checkSession()
            try await Task.sleep(for: .milliseconds(100))
        }
        try checkSession()
        guard let thumbnailResult else { throw ProbeFailure.failed("thumbnail timeout") }
        let thumbnail = try thumbnailResult.get()
        guard thumbnail.count <= 4 * 1_024 * 1_024,
              let source = CGImageSourceCreateWithData(thumbnail as CFData, nil),
              let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ProbeFailure.failed("invalid thumbnail")
        }
        print("Sample \(index): thumbnail decoded \(decoded.width)x\(decoded.height), bytes=\(thumbnail.count)")

        let directory = FileManager.default.temporaryDirectory.appending(path: "DeviceBridge-iOS-Probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        let suffix = (file.name as NSString?)?.pathExtension.lowercased() ?? "image"
        guard ["heic", "heif", "jpg", "jpeg", "png"].contains(suffix) else {
            try? FileManager.default.removeItem(at: directory)
            throw ProbeFailure.failed("sample format outside allow-list")
        }
        let destination = directory.appending(path: "sample.\(suffix)")
        downloadResult = nil
        let progress = beginDownload(file, destination: destination, revision: revision)
        defer {
            requestRevision += 1
            progress?.cancel()
            try? FileManager.default.removeItem(at: directory)
            file.flushThumbnailCache()
        }
        for _ in 0..<200 {
            if downloadResult != nil { break }
            try checkSession()
            try await Task.sleep(for: .milliseconds(100))
        }
        try checkSession()
        guard let downloadResult else { camera.cancelDownload(); throw ProbeFailure.failed("download timeout") }
        let filename = try downloadResult.get()
        guard (filename as NSString).lastPathComponent == destination.lastPathComponent,
              let size = try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber,
              size.int64Value == file.fileSize, size.int64Value <= 20 * 1_024 * 1_024 else {
            throw ProbeFailure.failed("download length or destination mismatch")
        }
        let bytes = try Data(contentsOf: destination)
        if ProcessInfo.processInfo.environment["DEVICEBRIDGE_LIVE_IOS_BOUNDED_READ"] == "1" {
            self.thumbnailResult = nil
            file.requestReadData(atOffset: 0, length: file.fileSize + 1) { @Sendable [weak self] data, error in
                Task { @MainActor in
                    guard let self, self.active, self.requestRevision == revision else { return }
                    self.thumbnailResult = if let data, error == nil { .success(data) }
                        else { .failure(.failed("bounded read unavailable")) }
                }
            }
            for _ in 0..<200 {
                if self.thumbnailResult != nil { break }
                try checkSession()
                try await Task.sleep(for: .milliseconds(100))
            }
            try checkSession()
            guard let bounded = try self.thumbnailResult?.get(), bounded == bytes else {
                throw ProbeFailure.failed("bounded read did not match original-presentation download")
            }
            print("PASS: bounded offset/length read matched original-presentation download exactly")
        }
        guard let original = CGImageSourceCreateWithData(bytes as CFData, nil),
              let type = CGImageSourceGetType(original),
              let properties = CGImageSourceCopyPropertiesAtIndex(original, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, Int64(width) * Int64(height) <= 100_000_000,
              CGImageSourceCreateThumbnailAtIndex(original, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 2048] as CFDictionary) != nil else {
            throw ProbeFailure.failed("downloaded image cannot be safely decoded")
        }
        let exported = directory.appending(path: "export.\(suffix)")
        try FileManager.default.copyItem(at: destination, to: exported)
        guard SHA256.hash(data: bytes) == SHA256.hash(data: try Data(contentsOf: exported)) else {
            throw ProbeFailure.failed("local original export differs")
        }
        print("Sample \(index): original-presentation \(type), \(width)x\(height), bytes=\(bytes.count); catalog length matched; local export SHA-256 matched")
        print("Remote SHA-256 unavailable; no claim of an unedited camera master; temporary copies removed on return")
    }

    func run() async throws {
        // The initial restriction flag is not authoritative before the open-session callbacks.
        // Explicit catalog opt-in permits opening; content still requires a complete unrestricted session.
        camera.delegate = self
        camera.mediaPresentation = .originalAssets
        openSession()
        defer { active = false; if !closeAcknowledged { closeSession() } }
        for _ in 0..<150 {
            if failed || complete { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        print("ICC catalog: session opened=\(opened), complete=\(complete), restricted=\(camera.isAccessRestrictedAppleDevice)")
        print("ICC media presentation original=\(camera.mediaPresentation == .originalAssets)")
        let catalogSucceeded = opened && complete && !failed && !camera.isAccessRestrictedAppleDevice
        var samplesSucceeded = true
        if catalogSucceeded {
            print("ICC catalog item count=\(camera.mediaFiles?.count ?? 0); names/metadata withheld; downloads=0")
            if ProcessInfo.processInfo.environment["DEVICEBRIDGE_LIVE_IOS_IMAGE_SAMPLES"] == "1" {
                let files = (camera.mediaFiles ?? []).compactMap { $0 as? ICCameraFile }.filter {
                    let suffix = ($0.name as NSString?)?.pathExtension.lowercased() ?? ""
                    return $0.fileSize > 0 && $0.fileSize <= 20 * 1_024 * 1_024
                        && ["heic", "heif", "jpg", "jpeg", "png"].contains(suffix)
                }
                print("Eligible bounded still-image samples=\(files.count)")
                print("Image formats present=\(Set(files.compactMap { ($0.name as NSString?)?.pathExtension.lowercased() }).sorted())")
                let format = ProcessInfo.processInfo.environment["DEVICEBRIDGE_LIVE_IOS_SAMPLE_FORMAT"]
                let selectedFiles = format.map { format in Array(files.filter {
                    ($0.name as NSString?)?.pathExtension.lowercased() == format
                }.prefix(1)) } ?? Array(files.prefix(2))
                if selectedFiles.isEmpty { samplesSucceeded = false }
                for (index, file) in selectedFiles.enumerated() {
                    do { try await sample(file, index: index + 1) }
                    catch { samplesSucceeded = false; print("SAMPLE FAILED: \(error)"); break }
                }
                if ProcessInfo.processInfo.environment["DEVICEBRIDGE_LIVE_IOS_CANCEL_SAMPLE"] == "1",
                   let file = files.first {
                    do { try await cancelSample(file) }
                    catch { samplesSucceeded = false; print("CANCEL SAMPLE FAILED: \(error)") }
                }
            }
        } else { print("BLOCKED: no complete unrestricted photo catalog; not an empty album") }
        active = false
        closeSession()
        for _ in 0..<50 {
            if closeAcknowledged { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        print("ICC session closed=\(!camera.hasOpenSession), close acknowledged=\(closeAcknowledged)")
        guard catalogSucceeded, samplesSucceeded, closeAcknowledged else {
            throw ProbeFailure.failed("requested catalog/sample/close checks did not all pass")
        }
    }
}

@main
struct PhotoIdentityCheck {
    @MainActor
    static func main() async {
        _ = NSApplication.shared.setActivationPolicy(.prohibited)
        guard let target = ProcessInfo.processInfo.environment["DEVICEBRIDGE_LIVE_IOS_TRANSPORT"],
              !target.isEmpty else { print("BLOCKED: explicit reference-phone transport required"); exit(2) }
        do {
            let inventory = try await IOSDeviceDiscoveryService(xcrunURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
                runner: HostCommandRunner()).discover(observedAt: Date())
            guard let device = inventory.first(where: { $0.id == target }), device.kind == .usb,
                  device.identity.stability == .stable, device.metadata["pairingState"] == "paired" else {
                print("BLOCKED: selected phone needs a paired USB route and stable hardware identity"); exit(2)
            }
            let probe = CameraIdentityProbe()
            probe.start()
            defer { probe.browser.stop(); probe.browser.delegate = nil }
            for _ in 0..<50 {
                let locations = usbLocations(for: device.identity.rawValue)
                let matches = (probe.browser.devices ?? []).filter {
                    $0 is ICCameraDevice && $0.transportType == ICDeviceTransport.transportTypeUSB.rawValue
                        && $0.usbLocationID != 0 && locations.contains($0.usbLocationID)
                }
                if probe.finishedLocalEnumeration && locations.count == 1 && matches.count == 1 { break }
                try await Task.sleep(for: .milliseconds(200))
            }
            let cameras = (probe.browser.devices ?? []).compactMap { $0 as? ICCameraDevice }
                .filter { $0.transportType == ICDeviceTransport.transportTypeUSB.rawValue }
            // Report observed equality, not an assumed correlation or authorization to open a session.
            let serialMatches = cameras.filter { $0.serialNumberString == device.identity.rawValue }.count
            let uuidMatches = cameras.filter { $0.uuidString == device.identity.rawValue }.count
            let usbLocations = usbLocations(for: device.identity.rawValue)
            let locationMatches = cameras.filter { $0.usbLocationID != 0 && usbLocations.contains($0.usbLocationID) }.count
            print("CoreDevice: paired USB reference phone present")
            print("ICC: local enumeration complete=\(probe.finishedLocalEnumeration), USB cameras=\(cameras.count)")
            print("Exact hardware UDID equality: camera serial matches=\(serialMatches), camera UUID matches=\(uuidMatches)")
            print("IOKit: USB serial matched selected UDID at \(usbLocations.count) locations; ICC location matches=\(locationMatches)")
            print("Identity stage: media sessions opened=0; entitlements/permissions changed=0")
            if !(usbLocations.count == 1 && locationMatches == 1) {
                print("BLOCKED: selected-phone identity not proven; no content access attempted")
            } else {
                print("PASS: selected-phone hardware association observed through USB serial and location")
                print("PENDING: catalog/thumbnail/original/cancellation require a separate camera-session experiment")
                if ProcessInfo.processInfo.environment["DEVICEBRIDGE_LIVE_IOS_CATALOG"] == "1",
                   let camera = cameras.first(where: { usbLocations.contains($0.usbLocationID) }) {
                    // Recheck live USB association immediately before any media-session side effect.
                    guard self.usbLocations(for: device.identity.rawValue) == usbLocations else {
                        print("BLOCKED: USB association changed before session open"); return
                    }
                    let catalogProbe = CameraCatalogProbe(camera: camera)
                    try await catalogProbe.run()
                }
            }
        } catch {
            print("BLOCKED: bounded discovery failed; raw device/tool data withheld")
            exit(2)
        }
    }

    static func usbLocations(for udid: String) -> [Int32] {
        // USB serials omit the separator in modern CoreDevice UDIDs; preserve every hex digit.
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
