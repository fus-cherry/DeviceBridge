import XCTest
import Darwin
import Security
import DeviceBridgeSecureChannel
import DeviceBridgeTLSProbeSupport
import UIKit

final class RunnerSmokeTests: XCTestCase {
    /// Read-only on the general board. Copy only into a disposable named board to characterize
    /// UIKit serialization; retain no personal values, types, sizes or hashes in diagnostics.
    @MainActor
    func testPhysicalClipboardSnapshotAudit() throws {
        guard ProcessInfo.processInfo.environment["DEVICEBRIDGE_SNAPSHOT_AUDIT"] == "1" else {
            throw XCTSkip("Read-only snapshot audit is not opted in")
        }
        let runner = XCUIApplication(bundleIdentifier: "dev.debugutility.DeviceBridgeRunnerUITests.xctrunner")
        runner.activate()
        guard runner.wait(for: .runningForeground, timeout: 5) else {
            throw XCTSkip("Runner foreground unavailable for read-only audit")
        }
        defer { if runner.state == .runningForeground { XCUIDevice.shared.press(.home) } }
        print(UIApplication.shared.applicationState == .active
            ? "Snapshot audit: UIApplication is active" : "Snapshot audit: UIApplication is not active")
        print(UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive })
            ? "Snapshot audit: an active foreground scene exists" : "Snapshot audit: no active foreground scene")
        guard UIApplication.shared.applicationState == .active else {
            throw XCTSkip("UIKit is not active; no system clipboard content read attempted")
        }
        let source = UIPasteboard.general
        let before = source.changeCount
        let snapshot = source.items
        let metadataEmpty = source.numberOfItems == 0 && source.types.isEmpty
            && (source.types(forItemSet: nil) ?? []).allSatisfy({ $0.isEmpty })
            && !source.hasStrings && !source.hasImages && !source.hasURLs && !source.hasColors
        if snapshot.isEmpty {
            print(metadataEmpty ? "Snapshot audit: public content metadata consistently reports empty"
                : "Snapshot audit: empty snapshot conflicts with public content metadata")
        }
        let countMatches = snapshot.count == source.numberOfItems
        let representationsPresent = snapshot.allSatisfy({ !$0.isEmpty })
        let revisionMatches = before == source.changeCount
        guard !snapshot.isEmpty, countMatches, representationsPresent, revisionMatches else {
            if snapshot.isEmpty { print("Snapshot audit: items API returned no backup") }
            if !countMatches { print("Snapshot audit: returned items do not match item metadata") }
            if !representationsPresent { print("Snapshot audit: an item has no backed-up representations") }
            if !revisionMatches { print("Snapshot audit: clipboard changed during snapshot read") }
            throw XCTSkip("Snapshot is unavailable or unstable; no general write attempted")
        }
        print("Snapshot audit: complete backup available")
        let clone = UIPasteboard.withUniqueName()
        defer { UIPasteboard.remove(withName: clone.name) }
        clone.setItems(snapshot, options: [.localOnly: true])
        let objectsMatch = NSArray(array: clone.items).isEqual(to: snapshot)
        print(objectsMatch ? "Snapshot audit: object restoration matches" : "Snapshot audit: object restoration differs")
        var bytesMatch = true
        let types = source.types(forItemSet: nil) ?? []
        let clonedTypes = clone.types(forItemSet: nil) ?? []
        if types.count != snapshot.count || clonedTypes.count != types.count { bytesMatch = false }
        for (index, itemTypes) in types.enumerated() {
            if !clonedTypes.indices.contains(index) || Set(clonedTypes[index]) != Set(itemTypes) {
                bytesMatch = false; continue
            }
            for type in itemTypes {
                let item = IndexSet(integer: index)
                let original = source.data(forPasteboardType: type, inItemSet: item)
                let copied = clone.data(forPasteboardType: type, inItemSet: item)
                if original == nil || copied == nil || original != copied { bytesMatch = false }
            }
        }
        print(bytesMatch ? "Snapshot audit: serialized representations match" : "Snapshot audit: serialized representations differ or are unavailable")
        XCTAssertTrue(before == source.changeCount, "General clipboard must remain unchanged during the read-only audit")
    }

    /// Host-side public activation avoids XCTest's async-test quiescence wait. The public ready
    /// record is only experiment synchronization, never authentication or a content mailbox.
    @MainActor
    func testPhysicalExternalForegroundClipboardRead() async throws {
        guard let raw = ProcessInfo.processInfo.environment["DEVICEBRIDGE_EXTERNAL_FOREGROUND_PROBE"],
              let probe = UUID(uuidString: raw) else {
            throw XCTSkip("External foreground clipboard characterization is not opted in")
        }
        let runner = XCUIApplication(bundleIdentifier: "dev.debugutility.DeviceBridgeRunnerUITests.xctrunner")
        let originalPID = ProcessInfo.processInfo.processIdentifier
        XCUIDevice.shared.press(.home)
        defer { XCUIDevice.shared.press(.home) }
        let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        let directory = documents.appendingPathComponent("DeviceBridgeBootstrap", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let record = try ManagedRunnerRecord.publish(Data("foreground-ready".utf8),
            at: directory.appendingPathComponent(probe.uuidString + ".foreground"))
        defer {
            do { try record.removeOwned() }
            catch { XCTFail("Public foreground-probe record cleanup failed") }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while runner.state != .runningForeground, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        guard runner.state == .runningForeground else {
            XCTFail("Host did not activate the exact running runner within the bound")
            return
        }
        XCTAssertTrue(ProcessInfo.processInfo.processIdentifier == originalPID, "Host activation must not restart the runner")
        let activeDeadline = min(deadline, ContinuousClock.now.advanced(by: .seconds(5)))
        while UIApplication.shared.applicationState != .active, ContinuousClock.now < activeDeadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        let applicationActive = UIApplication.shared.applicationState == .active
        print(applicationActive ? "Foreground audit: UIApplication became active"
            : "Foreground audit: UIApplication remained inactive after settlement")
        guard applicationActive else {
            XCTFail("XCTest foreground alone does not establish an active UIKit application")
            return
        }
        if ProcessInfo.processInfo.environment["DEVICEBRIDGE_METADATA_ONLY"] == "1" {
            let board = UIPasteboard.general
            let before = board.changeCount
            let empty = board.numberOfItems == 0 && board.types.isEmpty
                && (board.types(forItemSet: nil) ?? []).allSatisfy(\.isEmpty)
                && !board.hasStrings && !board.hasImages && !board.hasURLs && !board.hasColors
            let stable = board.changeCount == before
            print(empty ? "Foreground audit: metadata consistently empty while active"
                : "Foreground audit: metadata reports content while active")
            print(stable ? "Foreground audit: metadata revision stable" : "Foreground audit: metadata revision changed")
            print("Foreground audit: no clipboard content read or write attempted")
            return
        }
        if ProcessInfo.processInfo.environment["DEVICEBRIDGE_READ_WAIT_AUDIT"] == "1" {
            try await observePhysicalClipboardReadWait()
            return
        }
        let result = await ClipboardCommands().read()
        if result.status == .actionRequired {
            throw XCTSkip("Phone clipboard text or user paste permission unavailable; no approval or write attempted")
        }
        XCTAssertTrue(result.status == .success && result.text != nil, "Real foreground text read must succeed")
    }

    /// A bounded diagnostic, not permission handling. Only fixed classifications are retained.
    /// The uncooperative OS read may outlive cancellation; the owning test process must be reaped.
    @MainActor
    private func observePhysicalClipboardReadWait() async throws {
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let labels = ["Allow Paste", "允许粘贴", "允許貼上"]
        let board = UIPasteboard.general
        let revisionBefore = board.changeCount
        let textAdvertisedBefore = board.hasStrings
        func pastePromptExists() -> Bool {
            system.alerts.buttons.matching(NSPredicate(format: "label IN %@", labels)).firstMatch.exists
        }
        let existedBefore = pastePromptExists()
        print(existedBefore ? "Read wait audit: paste prompt existed before read"
            : "Read wait audit: no recognized paste prompt before read")
        var result: ClipboardCommandResult?
        let reading = Task { @MainActor in result = await ClipboardCommands().read() }
        defer { reading.cancel() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(12))
        var promptObserved = false
        while result == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .seconds(1))
            if pastePromptExists() { promptObserved = true; break }
        }
        print("Read wait audit: main actor remained responsive")
        print(promptObserved ? "Read wait audit: recognized paste prompt while read pending"
            : "Read wait audit: no recognized paste prompt observed while waiting")
        print(UIApplication.shared.applicationState == .active
            ? "Read wait audit: UIKit still active" : "Read wait audit: UIKit no longer active")
        guard let result else {
            print("Read wait audit: read not completed; cancelled without approval or write")
            throw XCTSkip("Read requires unresolved OS completion; no content or permission claim")
        }
        print(result.status == .success ? "Read wait audit: read returned success"
            : "Read wait audit: read returned a non-success status")
        guard result.status == .success, let text = result.text, !text.isEmpty else {
            print("Read wait audit: positive text was not returned")
            throw XCTSkip("Positive-text read not established; no write permitted by this audit")
        }
        guard textAdvertisedBefore, board.hasStrings, board.changeCount == revisionBefore else {
            print("Read wait audit: text metadata was absent or changed")
            throw XCTSkip("Stable text metadata not established; no write permitted by this audit")
        }
        guard UIApplication.shared.applicationState == .active else {
            print("Read wait audit: active state was lost before qualification")
            throw XCTSkip("Active read not established; no write permitted by this audit")
        }
        print("Read wait audit: positive text returned with stable active metadata")
        // The nonempty predicate prevents an empty/redacted success from qualifying READ.
        // Never log text, length, hash, item types or app names; never enable a WRITE fixture here.
    }

    /// Read-only opt-in: never logs text, writes a fixture, or approves the paste prompt.
    @MainActor
    func testPhysicalClipboardReadWhileForeground() async throws {
        guard ProcessInfo.processInfo.environment["DEVICEBRIDGE_CLIPBOARD_READ_PROBE"] == "1" else {
            throw XCTSkip("Read-only phone clipboard characterization is not opted in")
        }
        let runner = XCUIApplication(bundleIdentifier: "dev.debugutility.DeviceBridgeRunnerUITests.xctrunner")
        XCUIDevice.shared.press(.home)
        defer { XCUIDevice.shared.press(.home) }
        runner.activate()
        guard runner.wait(for: .runningForeground, timeout: 5) else {
            XCTFail("The exact runner did not become foreground")
            return
        }
        let result = await ClipboardCommands().read()
        if result.status == .actionRequired {
            throw XCTSkip("Phone clipboard text or user paste permission is unavailable; no approval or write attempted")
        }
        XCTAssertTrue(result.status == .success, "Foreground clipboard read must succeed")
        XCTAssertTrue(result.text != nil, "Successful clipboard read must contain a textual value")
        // Deliberately no value, count, hash, item metadata, or content-bearing assertion.
    }

    /// Characterizes the real runner, not the Host app. No pasteboard access or alert approval.
    @MainActor
    func testPhysicalRunnerForegroundRoundTrip() throws {
        guard ProcessInfo.processInfo.environment["DEVICEBRIDGE_FOREGROUND_PROBE"] == "1" else {
            throw XCTSkip("Phone foreground characterization is not opted in")
        }
        let runnerID = "dev.debugutility.DeviceBridgeRunnerUITests.xctrunner"
        XCTAssertTrue(Bundle.main.bundleIdentifier == runnerID, "The test must execute inside the exact runner")
        let originalPID = ProcessInfo.processInfo.processIdentifier
        let runner = XCUIApplication(bundleIdentifier: runnerID)
        XCUIDevice.shared.press(.home)
        defer { XCUIDevice.shared.press(.home) }
        XCTAssertTrue(runner.wait(for: .runningBackground, timeout: 5), "Home must background the existing runner")
        runner.activate()
        XCTAssertTrue(runner.wait(for: .runningForeground, timeout: 5), "The existing runner must become foreground")
        XCTAssertTrue(ProcessInfo.processInfo.processIdentifier == originalPID, "Activation must not restart the test process")
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(runner.wait(for: .runningBackground, timeout: 5), "The runner must return to background")
    }

    @MainActor
    func testManagedChannel() async throws {
        try await runManagedChannel(clipboardHandler: nil)
    }

    /// Only the host's separately opted-in physical test selects this entry. Restored content
    /// stays inside the phone; the normal managed entry never substitutes this probe accessor.
    @MainActor
    func testManagedClipboardWriteWithRestoration() async throws {
        guard ProcessInfo.processInfo.environment["DEVICEBRIDGE_MANAGED_WRITE_PROBE"] == "1" else {
            throw XCTSkip("Preserving general-pasteboard write test is not opted in")
        }
        let probe = PreservingClipboardWriteProbe(pasteboard: .general)
        try await runManagedChannel(clipboardHandler: ActiveClipboardHandler(
            commands: ClipboardCommands(clipboard: probe)))
        let restored = await probe.outcome == .restored
        XCTAssertTrue(restored, "The physical write must complete and original items must be restored")
    }

    @MainActor
    private func runManagedChannel(clipboardHandler: (any IOSRunnerClipboardHandling)?) async throws {
        let entered = ContinuousClock.now
        let environment = ProcessInfo.processInfo.environment
        guard let rawLaunch = environment["DEVICEBRIDGE_PUBLIC_LAUNCH"],
              let rawCertificate = environment["DEVICEBRIDGE_PUBLIC_HOST_CERTIFICATE"],
              let rawLifetime = environment["DEVICEBRIDGE_PUBLIC_MAXIMUM_LIFETIME"] else {
            throw XCTSkip("Managed channel public configuration is not present")
        }
        do {
            let configuration = try ManagedRunnerConfiguration(launch: rawLaunch, certificate: rawCertificate, lifetime: rawLifetime)
            let deadline = entered.advanced(by: configuration.maximumLifetime)
            try Task.checkCancellation()
            // The background runner is intentionally limited to screenshot and device metadata.
            // Clipboard uses the separately installed foreground DeviceBridgeHost application.
            XCUIDevice.shared.press(.home)
            let identity = try EphemeralTLSIdentity.create()
            let publicBytes = try PublicBootstrapRecord.encode(launchID: configuration.launchID,
                hostCertificateDER: configuration.hostCertificateDER, runnerCertificateDER: identity.certificateDER,
                helperBuild: IOSRunnerSessionServer.helperBuild)
            let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true)
            let directory = documents.appendingPathComponent("DeviceBridgeBootstrap", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let recordURL = directory.appendingPathComponent(configuration.launchID.uuidString + ".json")
            let remaining = try ManagedRunnerConfiguration.remainingSeconds(until: deadline)
            let listener = try await PinnedTLSFrameStream.listen(localPort: 49872, identity: identity,
                peerCertificateDER: configuration.hostCertificateDER,
                acceptTimeout: min(60, remaining), handshakeTimeout: min(10, remaining))
            // Accept timeout starts when the listener becomes ready; this absolute timer also
            // bounds publication/accept against the original test-entry deadline.
            let expiry = Task {
                do { try await Task.sleep(until: deadline, clock: .continuous); await listener.close() }
                catch { }
            }
            var record: ManagedRunnerRecord?
            var completed = false
            await withTaskCancellationHandler {
                do {
                    try Task.checkCancellation()
                    _ = try ManagedRunnerConfiguration.remainingSeconds(until: deadline)
                    // listen returns only after readiness; publish complete public bytes once.
                    record = try ManagedRunnerRecord.publish(publicBytes, at: recordURL)
                    let stream = try await listener.accept()
                    try Task.checkCancellation()
                    // Transfer the same absolute deadline, not a duration re-anchored after an
                    // executor delay. The entry timer also remains live until unified cleanup.
                    _ = try await IOSRunnerSessionServer.run(stream: stream, launchID: configuration.launchID,
                        maximumDeadline: deadline, clipboardHandler: clipboardHandler,
                        screenshotHandler: RunnerScreenshotHandler(), deviceInformationHandler: DeviceInformationCommands())
                    try Task.checkCancellation()
                    completed = true
                } catch { }
            } onCancel: {
                Task { await listener.close() }
            }
            expiry.cancel()
            await listener.close()
            try record?.removeOwned()
            guard completed else { throw ManagedRunnerFailure.channel }
        } catch ManagedRunnerFailure.cleanup {
            XCTFail("Managed channel public-record cleanup failed")
        } catch {
            // Never hand a session, nonce/challenge, payload or foreign error description to XCTest.
            XCTFail("Managed channel failed")
        }
    }

    func testManagedLifetimeRejectsInvalidPolicyBounds() throws {
        for value in ["", "0", "-1", "nan", "inf", "86400.1"] {
            XCTAssertThrowsError(try ManagedRunnerConfiguration.lifetime(value), "Invalid lifetime must fail")
        }
        XCTAssertTrue(try ManagedRunnerConfiguration.lifetime("1") == .seconds(1), "Valid lifetime must be retained")
        XCTAssertTrue(try ManagedRunnerConfiguration.lifetime("86400") == .seconds(86_400), "Maximum lifetime must be accepted")
    }

    func testManagedRecordDoesNotOverwriteOrRemoveAnotherRecord() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("public.json")
        let original = Data("public-fixture-original".utf8)
        let replacement = Data("public-fixture-replacement".utf8)
        let record = try ManagedRunnerRecord.publish(original, at: destination)
        XCTAssertThrowsError(try ManagedRunnerRecord.publish(replacement, at: destination), "Existing launch record must be preserved")
        XCTAssertTrue(try Data(contentsOf: destination) == original, "Publication must preserve an existing record")
        try replacement.write(to: destination)
        XCTAssertThrowsError(try record.removeOwned(), "Replacement record must not be removed")
        XCTAssertTrue(try Data(contentsOf: destination) == replacement, "Cleanup must preserve another record")
        try original.write(to: destination)
        try record.removeOwned()
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), "Owned public record must be removed")
    }

    @MainActor
    func testSecureUSBManagedIdentityProbe() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["DEVICEBRIDGE_SECURE_PROBE"] == "1",
              let rawLaunch = environment["DEVICEBRIDGE_PUBLIC_LAUNCH"], let launch = UUID(uuidString: rawLaunch),
              let rawCertificate = environment["DEVICEBRIDGE_PUBLIC_HOST_CERTIFICATE"],
              let certificate = Data(base64Encoded: rawCertificate) else {
            throw XCTSkip("Managed identity-only probe is not opted in")
        }
        // Only the designated phone goes Home. Nonce/challenge originate inside the pinned TLS
        // exchange, never in XCTest's environment, attachments or assertion diagnostics.
        XCUIDevice.shared.press(.home)
        let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let recordURL = documents.appendingPathComponent("DeviceBridgeBootstrap")
            .appendingPathComponent(launch.uuidString + ".json")
        let result = try await IOSRunnerHandshakeProbe.serve(port: 49872, launchID: launch,
            hostCertificateDER: certificate, recordURL: recordURL)
        XCTAssertEqual(result, "identity-2-exchanges")
    }

    @MainActor
    func testSecureUSBIdentityProbe() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["DEVICEBRIDGE_SECURE_PROBE"] == "1",
              let rawLaunch = environment["DEVICEBRIDGE_PUBLIC_LAUNCH"], let launch = UUID(uuidString: rawLaunch),
              let rawCertificate = environment["DEVICEBRIDGE_PUBLIC_HOST_CERTIFICATE"],
              let certificate = Data(base64Encoded: rawCertificate) else {
            throw XCTSkip("Secure identity-only probe is not opted in")
        }
        // Phone only. No UI content commands, Mac automation or secret launch environment values.
        XCUIDevice.shared.press(.home)
        let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let recordURL = documents.appendingPathComponent("DeviceBridgeBootstrap")
            .appendingPathComponent(launch.uuidString + ".json")
        let result = try await Task.detached {
            try TLSIdentityProbe(isServer: true).serve(port: 49872, launchID: launch,
                hostCertificateDER: certificate, recordURL: recordURL)
        }.value
        XCTAssertEqual(result, environment["DEVICEBRIDGE_SECURE_EXPECTED_EXIT"] ?? "tls13-31-exchanges")
    }

    // Explicitly selected by the T082 harness only; normal helper runs do not open this port.
    @MainActor
    func testUSBIdentityProbe() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["DEVICEBRIDGE_IDENTITY_PROBE"] == "1",
              let canary = environment["DEVICEBRIDGE_PUBLIC_CANARY"],
              let rawPort = environment["DEVICEBRIDGE_PROBE_PORT"], let port = UInt16(rawPort) else {
            throw XCTSkip("Identity-only physical probe is not opted in")
        }
        // This drives only the designated phone, never the Mac desktop.
        if environment["DEVICEBRIDGE_PROBE_HOME"] == "1" {
            XCUIDevice.shared.press(.home)
        }
        let result = try await Task.detached {
            try USBIdentityProbeServer.run(port: port, canary: canary)
        }.value
        XCTAssertEqual(result, environment["DEVICEBRIDGE_PROBE_EXPECTED_EXIT"] ?? "stopped")
    }

    @MainActor
    func testRunnerCanLaunchManagedHost() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["Device Bridge Runner"].waitForExistence(timeout: 5))
    }
}

private enum ManagedRunnerFailure: Error { case channel, cleanup }

private struct ManagedRunnerConfiguration {
    let launchID: UUID
    let hostCertificateDER: Data
    let maximumLifetime: Duration

    init(launch: String, certificate: String, lifetime: String) throws {
        guard let launchID = UUID(uuidString: launch), certificate.utf8.count <= 5464,
              let data = Data(base64Encoded: certificate), !data.isEmpty, data.count <= 4096,
              SecCertificateCreateWithData(nil, data as CFData) != nil else { throw ManagedRunnerFailure.channel }
        self.launchID = launchID
        self.hostCertificateDER = data
        self.maximumLifetime = try Self.lifetime(lifetime)
    }

    static func lifetime(_ value: String) throws -> Duration {
        guard let seconds = Double(value), seconds.isFinite, seconds > 0, seconds <= 86_400 else {
            throw ManagedRunnerFailure.channel
        }
        return .seconds(seconds)
    }

    static func remainingSeconds(until deadline: ContinuousClock.Instant) throws -> TimeInterval {
        let remaining = ContinuousClock.now.duration(to: deadline)
        guard remaining > .zero else { throw ManagedRunnerFailure.channel }
        return Double(remaining.components.seconds) + Double(remaining.components.attoseconds) / 1e18
    }
}

/// The run task alone owns this public record. The runner container is trusted: matching bytes
/// plus O_NOFOLLOW avoids accidental deletion, but does not claim an adversarial TOCTOU guarantee.
private struct ManagedRunnerRecord {
    let url: URL
    let bytes: Data

    static func publish(_ bytes: Data, at destination: URL) throws -> Self {
        guard !bytes.isEmpty, bytes.count <= 8192 else { throw ManagedRunnerFailure.channel }
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        let fd = open(staging.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw ManagedRunnerFailure.channel }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try file.write(contentsOf: bytes)
            try file.close()
            // NSData's atomic/withoutOverwriting options cannot be combined. The exclusive
            // rename publishes the completed staging file atomically and never replaces a launch.
            guard renamex_np(staging.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
                throw ManagedRunnerFailure.channel
            }
            return Self(url: destination, bytes: bytes)
        } catch {
            try? file.close()
            // Only this call created this staging name; no launch file is removed on failure.
            guard unlink(staging.path) == 0 || errno == ENOENT else { throw ManagedRunnerFailure.cleanup }
            throw ManagedRunnerFailure.channel
        }
    }

    func removeOwned() throws {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if fd < 0 {
            if errno == ENOENT { return }
            throw ManagedRunnerFailure.cleanup
        }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size == bytes.count else { throw ManagedRunnerFailure.cleanup }
        var actual = Data()
        while actual.count <= bytes.count {
            let chunk = try file.read(upToCount: bytes.count + 1 - actual.count) ?? Data()
            if chunk.isEmpty { break }
            actual.append(chunk)
        }
        guard actual == bytes else { throw ManagedRunnerFailure.cleanup }
        guard unlink(url.path) == 0 || errno == ENOENT else { throw ManagedRunnerFailure.cleanup }
    }
}
