import DeviceBridgeProtocol
import Foundation
import ImageIO
import Testing
@testable import DeviceBridgeCore

/// Explicit opt-in only. No fixture runner or desktop UI events. Mutations have a separate gate.
@Suite("Physical device checks", .serialized)
struct PhysicalDeviceTests {
    private let runner = HostCommandRunner()
    private var environment: [String: String] { ProcessInfo.processInfo.environment }

    @Test("physical Android discovery, command readiness and PNG capture",
          .enabled(if: ProcessInfo.processInfo.environment["DEVICEBRIDGE_LIVE_ANDROID_TRANSPORT"] != nil))
    func androidScreenshot() async throws {
        let (adb, transport, device) = try await androidTarget()
        let probe = await DeviceCommandProbe(adbURL: adb, xcrunURL: nil, runner: runner).probe(device)
        #expect(probe.isReady)
        let payload = try await AndroidScreenshotProvider(adbURL: adb, runner: runner)
            .capture(transportID: transport)
        let source = try #require(CGImageSourceCreateWithData(payload.data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width > 0 && image.height > 0)
        // Screen bytes remain in memory; never print, attach, or persist the phone's content.
        print("Physical Android: decoded screenshot \(image.width)x\(image.height)")
    }

    @Test("physical Android memory remains sampleable across the monitoring interval",
          .enabled(if: ProcessInfo.processInfo.environment["DEVICEBRIDGE_LIVE_ANDROID_TRANSPORT"] != nil))
    func androidMemoryContinuity() async throws {
        let (adb, transport, device) = try await androidTarget()
        let provider = AndroidMemoryProvider(adbURL: adb, runner: runner)
        let applications = await provider.discover(deviceIdentity: device.identity, transportID: transport)
        // A known running system process avoids launching or inspecting a personal application.
        let target = try #require(applications.first { $0.applicationID == "com.android.systemui" })
        let first = await provider.sample(target: target, transportID: transport)
        #expect(first.sample != nil, "Initial real-device memory sample must succeed")
        try await Task.sleep(for: .seconds(3))
        let next = await provider.sample(target: target, transportID: transport)
        if let changed = next.restartedTarget {
            print("Physical Android: restart reported; PID unchanged = \(changed.processID == target.processID), identity changed = \(changed.processStartIdentity != target.processStartIdentity)")
        }
        #expect(next.sample != nil, "An unchanged running process must remain sampleable after 3 seconds")
    }

    @Test("physical iOS discovery and target-specific command readiness",
          .enabled(if: ProcessInfo.processInfo.environment["DEVICEBRIDGE_LIVE_IOS_TRANSPORT"] != nil))
    func iosReadiness() async throws {
        let transport = try #require(environment["DEVICEBRIDGE_LIVE_IOS_TRANSPORT"])
        let xcrun = URL(fileURLWithPath: "/usr/bin/xcrun")
        let candidates = try await IOSDeviceDiscoveryService(xcrunURL: xcrun, runner: runner)
            .discover(observedAt: Date())
        let matches = DeviceInventory.aggregate(candidates).filter { $0.preferredTransportID == transport }
        let device = try #require(matches.first)
        let outcome = await DeviceCommandProbe(adbURL: nil, xcrunURL: xcrun, runner: runner).probe(device)
        #expect(outcome.isReady)
    }

    @Test("physical Android Unicode clipboard round trip with text restoration",
          .enabled(if: ProcessInfo.processInfo.environment["DEVICEBRIDGE_LIVE_ANDROID_MUTATIONS"] == "1"))
    func androidClipboard() async throws {
        let (adb, transport, device) = try await androidTarget()
        let package = try await runner.run(HostCommandRequest(executableURL: adb,
            arguments: ["-t", transport, "shell", "dumpsys", "package", AndroidHelperManager.packageName],
            timeout: .seconds(10)))
        // This test must not install/update a helper as a side effect.
        try #require(package.exitCode == 0 && package.standardOutputString.contains("versionCode=3 "))
        let manager = AndroidHelperManager(adbURL: adb,
            apkURL: URL(fileURLWithPath: "/nonexistent/no-test-install.apk"),
            expectedVersionCode: 3, runner: runner)
        do {
            let preparation = await manager.prepare(transportID: transport)
            let connection = try #require(preparation.connection)
            let channel = PhysicalDiagnosticChannel(base: try TCPHelperChannel(
                hostPort: connection.hostPort, timeout: .seconds(5)))
            let auth = await HelperSessionAuthenticator(channel: channel).authenticate(sessionNonce: UUID().uuidString)
            let context = try #require(auth.context)
            let windows = try await runner.run(HostCommandRequest(executableURL: adb,
                arguments: ["-t", transport, "shell", "dumpsys", "window"],
                timeout: .seconds(5), maximumOutputBytes: 2 * 1_024 * 1_024))
            let focus = windows.standardOutputString.split(separator: "\n")
                .filter { $0.contains("mCurrentFocus=") }.joined()
            try #require(!focus.isEmpty, "Window diagnostics must include current focus")
            let helperFocused = focus.contains(AndroidHelperManager.packageName)
            let permissionFocused = focus.localizedCaseInsensitiveContains("permission")
            print("Physical helper: focused = \(helperFocused), permission UI focused = \(permissionFocused)")
            try #require(helperFocused, "Do not overwrite clipboard while a dialog or another app covers the helper")
            let store = DeviceSessionStore()
            await store.replaceInventory([device])
            _ = try await store.select(device.identity)
            let service = ClipboardService(store: store, channel: channel,
                sessionNonce: context.sessionNonce, helperDeviceID: context.helperDeviceID)
            let original = await service.read()
            let originalText = try #require(original.snapshot).text
            // Only text can be restored by this protocol; use a dedicated test phone.
            let marker = "DeviceBridge 实机 clipboard 👋 \(UUID().uuidString)"
            let write = await service.write(marker)
            if case .written = write {} else { Issue.record("Physical clipboard write did not succeed") }
            let read = await service.read()
            let matches = read.snapshot?.text == marker
            #expect(matches, "Real-device clipboard must return the exact Unicode test text")
            let restoration = await service.write(originalText)
            if case .written = restoration {} else { Issue.record("Original clipboard text restoration failed") }
            let restored = await service.read()
            let restoredMatches = restored.snapshot?.text == originalText
            #expect(restoredMatches, "Original clipboard text must be restored")
            print("Physical Android: clipboard round trip = \(matches), restoration readback matched = \(restoredMatches)")
            await manager.stop()
        } catch {
            await manager.stop()
            throw error
        }
    }

    @Test("physical Android Downloads file send/receive and SHA-256",
          .enabled(if: ProcessInfo.processInfo.environment["DEVICEBRIDGE_LIVE_ANDROID_MUTATIONS"] == "1"))
    func androidFileRoundTrip() async throws {
        let (adb, transport, _) = try await androidTarget()
        let operation = UUID()
        let name = "devicebridge-live-\(operation.uuidString).bin"
        let directory = FileManager.default.temporaryDirectory.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "source.bin")
        let received = directory.appending(path: "received.bin")
        try Data((0..<65_536).map { UInt8($0 % 251) }).write(to: source)
        let expected = try FileIntegrity.metadata(for: source)
        let provider = AndroidFileProvider(adbURL: adb, runner: runner)
        let location = try DeviceFileLocation(scope: .androidSharedDownloads, relativePath: name)
        func cleanup() async throws {
            let result = try await runner.run(HostCommandRequest(executableURL: adb, arguments: [
                "-t", transport, "shell", "rm", "-f", "/sdcard/Download/\(name)",
                "/sdcard/Download/.devicebridge.partial.\(operation.uuidString)"
            ], timeout: .seconds(10)))
            try #require(result.exitCode == 0, "Remove only this test's uniquely named device artifacts")
        }
        do {
            let sent = try await provider.send(localURL: source, destination: location,
                transportID: transport, operationID: operation, replaceExisting: false)
            let receipt = try await provider.receive(source: location, localPartialURL: received,
                transportID: transport, operationID: UUID())
            let actual = try FileIntegrity.metadata(for: received)
            try #require(sent.sha256 == expected.sha256 && receipt.sha256 == expected.sha256)
            try #require(actual == expected)
            try await cleanup()
            print("Physical Android: 65536-byte file round trip and SHA-256 verified; test artifacts removed")
        } catch {
            try await cleanup()
            throw error
        }
    }

    private func androidTarget() async throws -> (URL, String, DeviceRecord) {
        let transport = try #require(environment["DEVICEBRIDGE_LIVE_ANDROID_TRANSPORT"])
        let path = try #require(environment["DEVICEBRIDGE_LIVE_ADB_PATH"])
        let adb = URL(fileURLWithPath: path)
        let candidates = try await AndroidDeviceDiscoveryService(adbURL: adb, runner: runner)
            .discover(observedAt: Date())
        let matches = DeviceInventory.aggregate(candidates).filter { $0.preferredTransportID == transport }
        return (adb, transport, try #require(matches.first))
    }
}

/// Log only error types/schema keys, never wire bytes, identifiers, nonces or clipboard text.
private struct PhysicalDiagnosticChannel: HelperRequestSending {
    let base: TCPHelperChannel
    func send(_ request: HelperRequest) async throws -> HelperResult {
        do { return try await base.send(request) }
        catch {
            if case let DecodingError.dataCorrupted(context) = error {
                print("Physical helper: JSON dataCorrupted at \(context.codingPath.map(\.stringValue).joined(separator: "."))")
            } else if let transport = error as? TCPHelperChannelError {
                print("Physical helper: TCP \(transport)")
            } else {
                print("Physical helper: error type \(type(of: error))")
            }
            throw error
        }
    }
}
