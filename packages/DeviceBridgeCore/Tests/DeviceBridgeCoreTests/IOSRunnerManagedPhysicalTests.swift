import Foundation
import Testing
import DeviceBridgeProtocol
@testable import DeviceBridgeCore

struct IOSRunnerManagedPhysicalTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DEVICEBRIDGE_MANAGED_DEVICE"] != nil))
    func signedNativeLauncherMaintainsAuthenticatedPhoneSessionAndStops() async throws {
        let environment = ProcessInfo.processInfo.environment
        let sourcePath = try #require(environment["DEVICEBRIDGE_SIGNED_PRODUCTS"])
        let team = try #require(environment["DEVICEBRIDGE_EXPECTED_TEAM"])
        let device = try #require(environment["DEVICEBRIDGE_MANAGED_DEVICE"])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DeviceBridgeManagedPhysical-" + UUID().uuidString)
        let launch = IOSRunnerLaunch(deviceIdentifier: device)
        let products = IOSRunnerBuildProducts(launchID: launch.id, rootDirectoryURL: root, expectedTeamIdentifier: team)
        let resultURL = root.appendingPathComponent("managed.xcresult")
        try copySignedProducts(from: URL(fileURLWithPath: sourcePath), to: products)
        defer { try? FileManager.default.removeItem(at: root) }
        let preservingWrite = environment["DEVICEBRIDGE_MANAGED_CLIPBOARD_WRITE"] == "1"
        let replacementWrite = environment["DEVICEBRIDGE_MANAGED_CLIPBOARD_REPLACE"] == "1"
        let crossAppRead = environment["DEVICEBRIDGE_MANAGED_CLIPBOARD_CROSS_APP"] == "1"
        let multipleItems = environment["DEVICEBRIDGE_MANAGED_CLIPBOARD_MULTIPLE"] == "1"
        try #require(!multipleItems || crossAppRead)
        let pasteStopGate = environment["DEVICEBRIDGE_MANAGED_PASTE_STOP_GATE"].map { URL(fileURLWithPath: $0) }
        try #require(pasteStopGate == nil || crossAppRead)
        if let pasteStopGate { try #require(!FileManager.default.fileExists(atPath: pasteStopGate.path)) }
        let expectCrossAppText = environment["DEVICEBRIDGE_MANAGED_EXPECT_CROSS_APP"] == "1"
        let screenshotSoak = environment["DEVICEBRIDGE_MANAGED_SCREENSHOT_100"] == "1"
        try #require(!expectCrossAppText || (environment["DEVICEBRIDGE_MANAGED_CLIPBOARD_READ"] == "1"
            && !replacementWrite && !preservingWrite && !crossAppRead && !screenshotSoak
            && environment["DEVICEBRIDGE_MANAGED_SCREENSHOT"] != "1"))
        // Separately authorized destructive probe: no backup/restore claim or inherited actions.
        try #require(!replacementWrite || (!preservingWrite && !screenshotSoak
            && environment["DEVICEBRIDGE_MANAGED_SCREENSHOT"] != "1"
            && environment["DEVICEBRIDGE_MANAGED_CLIPBOARD_READ"] != "1"))
        try #require(!crossAppRead || (!replacementWrite && !preservingWrite && !screenshotSoak
            && environment["DEVICEBRIDGE_MANAGED_SCREENSHOT"] != "1"
            && environment["DEVICEBRIDGE_MANAGED_CLIPBOARD_READ"] != "1"))
        // The repeated screenshot qualification must never inherit a clipboard opt-in.
        try #require(!screenshotSoak || (environment["DEVICEBRIDGE_MANAGED_SCREENSHOT"] == "1"
            && !preservingWrite && environment["DEVICEBRIDGE_MANAGED_CLIPBOARD_READ"] != "1"))
        let processes = PhysicalRunnerProcessCapture(resultURL: resultURL, preservingWrite: preservingWrite)
        let xcrun = URL(fileURLWithPath: "/usr/bin/xcrun")
        let launcher = IOSRunnerLauncher(xcrunURL: xcrun, channels: IOSRunnerChannelFactory(xcrunURL: xcrun),
            maximumRunnerLifetime: .seconds(screenshotSoak ? 600 : 120), processes: processes)
        do {
            let opened = try await launcher.installStartAndOpen(launch: launch, projectURL: root,
                scheme: "DeviceBridgeRunner", buildProducts: products)
            guard let channel = opened as? IOSRunnerChannel else { throw IOSRunnerChannel.Failure.unavailable }
            let context = try await channel.authenticatedContext()
            let identityMatches = context.helperDeviceID == launch.id.uuidString
            #expect(identityMatches)
            let earlyStopID = if crossAppRead {
                try await runCrossAppClipboardRead(channel: channel, context: context, device: device, root: root,
                    multipleItems: multipleItems, pasteStopGate: pasteStopGate)
            } else { Optional<UUID>.none }
            if replacementWrite {
                try await runAuthorizedClipboardReplacement(channel: channel, context: context)
            }
            if preservingWrite {
                print("Physical evidence: authenticated; starting preserving encrypted clipboard write")
                let now = Date()
                let request = HelperRequest(requestID: UUID(), sessionNonce: context.sessionNonce,
                    helperDeviceID: context.helperDeviceID, action: .clipboardWrite,
                    createdAt: now, expiresAt: now.addingTimeInterval(30),
                    payload: ["text": .string(String(repeating: "DeviceBridge 实机写入验证 📋\n", count: 128))])
                let result = try await channel.send(request)
                print("Physical evidence: preserving write status " + result.status.rawValue)
                let acknowledged = result.requestID == request.requestID && result.status == .success
                    && result.payload == ["written": .bool(true)]
                #expect(acknowledged)
                if acknowledged { print("Physical evidence: encrypted write/readback and original-item restoration succeeded") }
            }
            if environment["DEVICEBRIDGE_MANAGED_SCREENSHOT"] == "1" {
                print("Physical evidence: authenticated; starting encrypted screenshot")
                let provider = IOSRunnerScreenshotProvider(channel: channel, context: context, transportID: device)
                let trials = screenshotSoak ? 100 : 1
                var durations: [Double] = []
                defer { print("Physical evidence: screenshot completed \(durations.count) of \(trials); no retries") }
                for trial in 1...trials {
                    // Identity renews the lease without a screenshot/clipboard side effect.
                    // One slow/failed content request is terminal; never hide it with a retry.
                    try #require(await HelperSessionAuthenticator(channel: channel).verifyExisting(context))
                    let started = ContinuousClock.now
                    do {
                        let screenshot = try await provider.capture(transportID: device)
                        // Full PNG/length/hash validation is production code, not a test-only decoder.
                        // Never attach, log or export the phone's screen in this opt-in evidence run.
                        let hasValidatedImage = !screenshot.data.isEmpty
                        try #require(hasValidatedImage)
                    } catch {
                        print("Physical evidence: screenshot trial \(trial) failed; aborting remaining trials")
                        throw error
                    }
                    let elapsed = started.duration(to: .now).components
                    let milliseconds = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
                    durations.append(milliseconds)
                    print(String(format: "Physical evidence: screenshot trial %d success duration_ms=%.3f", trial, milliseconds))
                }
                if screenshotSoak {
                    let sorted = durations.sorted()
                    let withinFiveSeconds = durations.filter { $0 <= 5000 }.count
                    print(String(format: "Physical evidence: screenshot latency median_ms=%.3f p95_ms=%.3f max_ms=%.3f within_5s=%d/100",
                        (sorted[49] + sorted[50]) / 2, sorted[94], sorted[99], withinFiveSeconds))
                }
                print("Physical evidence: encrypted screenshot succeeded")
            }
            if environment["DEVICEBRIDGE_MANAGED_CLIPBOARD_READ"] == "1" {
                print("Physical evidence: authenticated; starting encrypted read")
                // Explicit opt-in: read only, never print/assert the actual value or alter it.
                let now = Date()
                let request = HelperRequest(requestID: UUID(), sessionNonce: context.sessionNonce,
                    helperDeviceID: context.helperDeviceID, action: .clipboardRead,
                    createdAt: now, expiresAt: now.addingTimeInterval(30), payload: [:])
                let result = try await channel.send(request)
                print("Physical evidence: read status " + result.status.rawValue)
                if let text = result.payload?["text"]?.stringValue {
                    let isWriteFixture = text == String(repeating: "DeviceBridge 实机写入验证 📋\n", count: 128)
                    print(isWriteFixture ? "Physical evidence: prior write fixture is present"
                        : "Physical evidence: prior write fixture is absent")
                }
                if result.error?.code == "clipboard.foreground_required" {
                    print("Physical evidence: runner foreground required")
                } else if result.error?.code == "clipboard.unavailable" {
                    print("Physical evidence: system clipboard unavailable")
                }
                let readSucceeded = result.requestID == request.requestID && result.status == .success
                    && result.payload?["text"]?.stringValue != nil
                try #require(readSucceeded)
                if expectCrossAppText {
                    // Read-only follow-up after an acknowledged separate-Host source write.
                    // Exact equality rejects empty/redacted success without printing either value.
                    let matched = result.payload?["text"]?.stringValue
                        == "DeviceBridge separate Host source · 跨应用 📋\n2026-09-08"
                    print(matched ? "Physical evidence: existing cross-app source text matched"
                        : "Physical evidence: existing cross-app source text did not match")
                    try #require(matched)
                }
                print("Physical evidence: encrypted read succeeded")
            }
            let stopID: UUID
            if let earlyStopID {
                stopID = earlyStopID
            } else {
                let started = ContinuousClock.now
                // Exceed one real 30-second phone lease; metadata only after any opted-in read.
                for index in 0..<5 {
                    if index > 0 { try await Task.sleep(for: .seconds(10)) }
                    let verified = await HelperSessionAuthenticator(channel: channel).verifyExisting(context)
                    try #require(verified)
                }
                #expect(started.duration(to: .now) >= .seconds(40))
                let now = Date()
                stopID = UUID()
                let reply = try await channel.send(HelperRequest(requestID: stopID, sessionNonce: context.sessionNonce,
                    helperDeviceID: context.helperDeviceID, action: .stop, createdAt: now,
                    expiresAt: now.addingTimeInterval(5), payload: [:]))
                #expect(reply.status == .success)
            }
            guard let process = processes.process else { throw IOSRunnerChannel.Failure.unavailable }
            let exit = await withTaskCancellationHandler { await process.waitForExit() } onCancel: {
                Task { await process.stop() }
            }
            try Task.checkCancellation()
            if preservingWrite {
                let diagnostic = try await HostCommandRunner().run(HostCommandRequest(executableURL: xcrun,
                    arguments: ["xcresulttool", "get", "log", "--path", resultURL.path, "--type", "action"],
                    timeout: .seconds(10), maximumOutputBytes: 4 * 1024 * 1024))
                // Print only fixed probe classifications even when the phone test failed.
                // Never dump the action log or keep a result bundle just to recover this metadata.
                for marker in ["Preserving write outcome: failed", "Preserving write outcome: changedByAnotherWriter",
                    "Preserving write outcome: restoredAfterFailure", "consistent public-empty state", "complete readable items"] {
                    if diagnostic.standardOutput.range(of: Data(marker.utf8)) != nil {
                        print("Physical evidence: probe diagnostic " + marker)
                    }
                }
            }
            try #require(exit.code == 0)
            let summary = try await HostCommandRunner().run(HostCommandRequest(executableURL: xcrun,
                arguments: ["xcresulttool", "get", "test-results", "summary", "--path", resultURL.path],
                timeout: .seconds(10), maximumOutputBytes: 65_536))
            let object = try #require(JSONSerialization.jsonObject(with: summary.standardOutput) as? [String: Any])
            let executed = summary.exitCode == 0 && object["passedTests"] as? Int == 1
                && object["failedTests"] as? Int == 0 && object["skippedTests"] as? Int == 0
            #expect(executed)
            let log = try await HostCommandRunner().run(HostCommandRequest(executableURL: xcrun,
                arguments: ["xcresulttool", "get", "log", "--path", resultURL.path, "--type", "action"],
                timeout: .seconds(10), maximumOutputBytes: 4 * 1024 * 1024))
            try #require(log.exitCode == 0)
            if preservingWrite {
                let emptyBackup = log.standardOutput.range(of: Data("consistent public-empty state".utf8)) != nil
                let itemBackup = log.standardOutput.range(of: Data("complete readable items".utf8)) != nil
                if emptyBackup { print("Physical evidence: restored the verified public-empty clipboard state") }
                else if itemBackup { print("Physical evidence: restored the backed-up readable clipboard items") }
                else { print("Physical evidence: clipboard backup classification absent from action log") }
            }
            let noNonceInActionLog = log.standardOutput.range(of: Data(context.sessionNonce.utf8)) == nil
            let noPublicStopIDInActionLog = log.standardOutput.range(of: Data(stopID.uuidString.utf8)) == nil
            #expect(noNonceInActionLog)
            #expect(noPublicStopIDInActionLog)
            _ = try IOSRunnerSignedArtifacts.load(launch: launch, products: products)
            await launcher.stop(launch: launch)
            #expect(!(await launcher.hasPendingCleanup(launch: launch)))
        } catch {
            await launcher.stop(launch: launch)
            // All throwing production boundaries above use fixed local errors, never descriptions
            // of protocol objects, certificate subjects, device identifiers or clipboard values.
            throw error
        }
    }

    /// Requires explicit permission to replace the selected phone's current clipboard.
    /// Uses the normal production handler, not the preserving probe or a test-only setter.
    private func runAuthorizedClipboardReplacement(channel: IOSRunnerChannel, context: HelperSessionContext) async throws {
        try #require(ProcessInfo.processInfo.environment["DEVICEBRIDGE_MANAGED_CLIPBOARD_REPLACE"] == "1")
        let fixture = "DeviceBridge disposable clipboard test · 中文 📋\n" + UUID().uuidString
        defer { print("Physical evidence: replacement probe did not attempt original clipboard restoration") }
        print("Physical evidence: starting one authorized clipboard replacement; no write retry")
        let writeTime = Date()
        let write = HelperRequest(requestID: UUID(), sessionNonce: context.sessionNonce,
            helperDeviceID: context.helperDeviceID, action: .clipboardWrite, createdAt: writeTime,
            expiresAt: writeTime.addingTimeInterval(30), payload: ["text": .string(fixture)])
        let writeResult = try await channel.send(write)
        print("Physical evidence: replacement write status " + writeResult.status.rawValue)
        let acknowledged = writeResult.requestID == write.requestID && writeResult.status == .success
            && writeResult.payload == ["written": .bool(true)]
        // A non-success ACK does not prove the setter did not run. One read distinguishes
        // visible mutation from acknowledgement failure without retrying the mutation.
        let readTime = Date()
        let read = HelperRequest(requestID: UUID(), sessionNonce: context.sessionNonce,
            helperDeviceID: context.helperDeviceID, action: .clipboardRead, createdAt: readTime,
            expiresAt: readTime.addingTimeInterval(30), payload: [:])
        let readResult = try await channel.send(read)
        print("Physical evidence: replacement read status " + readResult.status.rawValue)
        let matched = readResult.requestID == read.requestID && readResult.status == .success
            && readResult.payload?["text"]?.stringValue == fixture
        print(matched ? "Physical evidence: replacement text independently matched"
            : "Physical evidence: replacement text was not independently matched")
        // Assert only booleans so XCTest diagnostics cannot interpolate the fixture or payload.
        try #require(acknowledged)
        try #require(matched)
    }

    /// Opt-in characterization: the separately compiled Host writes; the unmodified Runner reads.
    /// A fresh public receipt prevents an old matching fixture from satisfying source setup.
    private func runCrossAppClipboardRead(channel: IOSRunnerChannel, context: HelperSessionContext,
                                         device: String, root: URL, multipleItems: Bool,
                                         pasteStopGate: URL?) async throws -> UUID? {
        try #require(ProcessInfo.processInfo.environment["DEVICEBRIDGE_MANAGED_CLIPBOARD_CROSS_APP"] == "1")
        let identifier = UUID().uuidString
        let xcrun = URL(fileURLWithPath: "/usr/bin/xcrun")
        let launched = try await IOSRunnerForegroundProcessRunner(deadline: .now.advanced(by: .seconds(8)))
            .run(HostCommandRequest(executableURL: xcrun,
            arguments: ["devicectl", "device", "process", "launch", "--device", device,
                // Only our static test Host restarts so its launch arguments take effect.
                // The native Runner and the user's target app are never restarted here.
                "--activate", "--terminate-existing", "--timeout", "5", "dev.debugutility.DeviceBridgeHost",
                multipleItems ? "--devicebridge-clipboard-source-multiple" : "--devicebridge-clipboard-source", identifier],
            timeout: .seconds(8), maximumOutputBytes: 0))
        try #require(launched.exitCode == 0)
        let receipt = root.appendingPathComponent("cross-app-source-receipt")
        var sourceReady = false
        var lastStage = "unavailable"
        for _ in 0..<3 {
            try #require(await HelperSessionAuthenticator(channel: channel).verifyExisting(context))
            let copied = try await IOSRunnerForegroundProcessRunner(deadline: .now.advanced(by: .seconds(8)))
                .run(HostCommandRequest(executableURL: xcrun,
                arguments: ["devicectl", "device", "copy", "from", "--device", device,
                    "--domain-type", "appDataContainer", "--domain-identifier", "dev.debugutility.DeviceBridgeHost",
                    "--source", "Documents/DeviceBridgeClipboardProbe/" + identifier + ".ready",
                    "--destination", receipt.path, "--timeout", "5"],
                timeout: .seconds(8), maximumOutputBytes: 0))
            if copied.exitCode == 0, let data = try? Data(contentsOf: receipt) {
                for stage in ["entered", "arguments-valid", "active", "written", "source-ready"]
                    where data == Data(stage.utf8) { lastStage = stage }
                if lastStage == "source-ready" { sourceReady = true; break }
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        print("Physical evidence: separate Host source stage " + lastStage)
        print(sourceReady ? "Physical evidence: separate Host source write acknowledged"
            : "Physical evidence: separate Host source write was not acknowledged")
        try #require(sourceReady)
        let now = Date()
        let request = HelperRequest(requestID: UUID(), sessionNonce: context.sessionNonce,
            helperDeviceID: context.helperDeviceID, action: .clipboardRead, createdAt: now,
            expiresAt: now.addingTimeInterval(30), payload: [:])
        if let pasteStopGate {
            return try await stopWhilePasteIsPending(channel: channel, context: context, request: request, gate: pasteStopGate)
        }
        let result = try await channel.send(request)
        print("Physical evidence: cross-app read status " + result.status.rawValue)
        // Fixed local classifications only; never print an arbitrary remote error/message.
        for code in ["clipboard.foreground_required", "clipboard.unavailable", "clipboard.denied",
                     "clipboard.interrupted", "clipboard.expired"] where result.error?.code == code {
            print("Physical evidence: cross-app read classification " + code)
        }
        let expectedText = multipleItems ? "第一项 📋\n\nsecond\nline\nশেষ"
            : "DeviceBridge separate Host source · 跨应用 📋\n2026-09-08"
        let matched = result.requestID == request.requestID && result.status == .success
            && result.payload?["text"]?.stringValue == expectedText
        print(matched ? "Physical evidence: cross-app source text matched"
            : "Physical evidence: cross-app source text did not match")
        // Never interpolate received or expected text into test diagnostics.
        try #require(matched)
        if multipleItems { print("Physical evidence: cross-app multiple text items, empty item and ordering matched") }
        return nil
    }

    /// The external phone observer writes only a fixed marker after matching the exact test alert.
    /// No approval tap is used; Stop must work while normal system clipboard I/O remains pending.
    private func stopWhilePasteIsPending(channel: IOSRunnerChannel, context: HelperSessionContext,
                                        request: HelperRequest, gate: URL) async throws -> UUID {
        let completion = PhysicalReadCompletion()
        let read = Task {
            let result: Result<HelperResult, any Error>
            do { result = .success(try await channel.send(request)) }
            catch { result = .failure(error) }
            await completion.finish()
            return result
        }
        defer { read.cancel() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while (try? Data(contentsOf: gate)) != Data("exact-paste-prompt-observed".utf8) {
            try Task.checkCancellation()
            try #require(!(await completion.finished))
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(!(await completion.finished))
        print("Physical evidence: cross-app paste prompt observed with read still pending")
        let stoppedAt = ContinuousClock.now
        let now = Date(), stopID = UUID()
        let reply = try await channel.send(HelperRequest(requestID: stopID, sessionNonce: context.sessionNonce,
            helperDeviceID: context.helperDeviceID, action: .stop, createdAt: now,
            expiresAt: now.addingTimeInterval(5), payload: [:]))
        try #require(reply.status == .success)
        let result = await read.value
        let contentSuppressed: Bool
        switch result {
        case .failure: contentSuppressed = true
        case .success(let reply): contentSuppressed = reply.status != .success && reply.payload?["text"] == nil
        }
        try #require(contentSuppressed)
        try #require(stoppedAt.duration(to: .now) < .seconds(5))
        try #require((try? await channel.authenticatedContext()) == nil)
        print("Physical evidence: cross-app Stop acknowledged; pending read returned no content and channel is invalid")
        return stopID
    }

    private func copySignedProducts(from original: URL, to products: IOSRunnerBuildProducts) throws {
        let destination = products.productsDirectoryURL.appendingPathComponent("Debug-iphoneos")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for name in ["DeviceBridgeRunnerUITests-Runner.app", "DeviceBridgeHost.app"] {
            try FileManager.default.copyItem(at: original.appendingPathComponent("Debug-iphoneos/" + name),
                to: destination.appendingPathComponent(name))
        }
        let configurations = try FileManager.default.contentsOfDirectory(at: original, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "xctestrun" }
        guard configurations.count == 1, let source = configurations.first else { throw IOSRunnerLaunchError.channelUnavailable }
        try FileManager.default.copyItem(at: source, to: products.productsDirectoryURL.appendingPathComponent(source.lastPathComponent))
    }
}

private actor PhysicalReadCompletion {
    private(set) var finished = false
    func finish() { finished = true }
}

/// Same native production process owner, with only an owned result bundle added for this opt-in
/// evidence run. The normal launcher intentionally discards process stdout/stderr.
private final class PhysicalRunnerProcessCapture: IOSRunnerProcessStarting, @unchecked Sendable {
    private let lock = NSLock()
    private let resultURL: URL
    private let preservingWrite: Bool
    private var captured: IOSRunnerProcess?
    var process: IOSRunnerProcess? { lock.lock(); defer { lock.unlock() }; return captured }
    init(resultURL: URL, preservingWrite: Bool) {
        self.resultURL = resultURL; self.preservingWrite = preservingWrite
    }
    func start(_ request: IOSRunnerProcessRequest) throws -> any IOSRunnerProcessOwning {
        lock.lock(); defer { lock.unlock() }
        guard captured == nil else { throw IOSRunnerLaunchError.channelUnavailable }
        var arguments = request.arguments
        var environment = request.environment
        if preservingWrite {
            let normalEntry = "-only-testing:DeviceBridgeRunnerUITests/RunnerSmokeTests/testManagedChannel"
            guard arguments.filter({ $0 == normalEntry }).count == 1 else {
                throw IOSRunnerLaunchError.channelUnavailable
            }
            arguments = arguments.map { $0 == normalEntry
                ? "-only-testing:DeviceBridgeRunnerUITests/RunnerSmokeTests/testManagedClipboardWriteWithRestoration" : $0 }
            environment["TEST_RUNNER_DEVICEBRIDGE_MANAGED_WRITE_PROBE"] = "1"
        }
        let process = try IOSRunnerProcess.start(executableURL: request.executableURL,
            arguments: arguments + ["-resultBundlePath", resultURL.path],
            environment: environment, lifetime: request.maximumLifetime)
        captured = process
        return process
    }
}
