import DeviceBridgeCore
import Foundation
import ImageIO

/// Explicit opt-in physical acceptance through the production Workspace model and bundled sources.
/// No desktop input or content logging. Clipboard replacement requires its separate explicit opt-in.
@main
struct IOSRunnerWorkspacePhysicalCheck {
    @MainActor
    static func main() async {
        let environment = ProcessInfo.processInfo.environment
        guard environment["DEVICEBRIDGE_WORKSPACE_PHYSICAL"] == "1",
              let deviceID = environment["DEVICEBRIDGE_PHYSICAL_UDID"],
              let team = environment["DEVICEBRIDGE_PHYSICAL_TEAM"],
              let resources = environment["DEVICEBRIDGE_PHYSICAL_HELPERS"] else {
            print("SKIP: physical Workspace check requires explicit local inputs")
            return
        }
        do {
            let maximumClipboard = environment["DEVICEBRIDGE_WORKSPACE_CLIPBOARD_MAXIMUM"] == "1"
            guard !maximumClipboard || environment["DEVICEBRIDGE_WORKSPACE_CLIPBOARD_REPLACE"] == "1" else {
                throw Failure.clipboardWrite
            }
            let configuration = try IOSRunnerSourceConfiguration(
                helperResourcesURL: URL(fileURLWithPath: resources), signingTeamID: team)
            let xcrun = URL(fileURLWithPath: "/usr/bin/xcrun")
            let manager = IOSRunnerManager(xcodebuildURL: URL(fileURLWithPath: "/usr/bin/xcodebuild"),
                projectURL: configuration.projectURL, scheme: configuration.scheme,
                signingTeamID: configuration.signingTeamID, runner: PhysicalBuildDiagnosticsRunner(),
                launcher: IOSRunnerLauncher(xcrunURL: xcrun, channels: IOSRunnerChannelFactory(xcrunURL: xcrun),
                    maximumRunnerLifetime: .seconds(180)))
            let model = WorkspaceViewModel(arguments: [], iosRunnerFactory: { _ in manager })
            do {
                model.start()
                try await wait(seconds: 20) { !model.isRefreshing }
                guard let device = model.devices.first(where: { $0.identity.rawValue == deviceID }),
                      device.candidates.contains(where: { $0.id == device.preferredTransportID && $0.kind == .usb }) else {
                    throw Failure.deviceUnavailable
                }
                print("Physical Workspace: selected USB device discovered")
                model.select(device.identity)
                try await wait(seconds: 370) { !model.isSelecting && model.isScreenshotReady }
                guard model.isScreenshotReady, model.isClipboardReady else {
                    print("Physical Workspace: readiness \(model.screenshotReadinessDetail ?? "unavailable")")
                    throw Failure.preparation
                }
                print("Physical Workspace: authenticated screenshot and clipboard capabilities ready")
                let memoryApplication = environment["DEVICEBRIDGE_WORKSPACE_COEXIST_APP"]
                let memoryPID = environment["DEVICEBRIDGE_WORKSPACE_COEXIST_PID"].flatMap(Int.init)
                if let memoryApplication {
                    guard let memoryPID, memoryPID > 0,
                          environment["DEVICEBRIDGE_WORKSPACE_CLIPBOARD_REPLACE"] != "1" else { throw Failure.memoryAdmission }
                    try await wait(seconds: 25) { model.targetApplications.contains { $0.applicationID == memoryApplication } }
                    model.selectedMemoryApplicationID = memoryApplication
                    try await wait(seconds: 70) { model.canStartIOSMemory }
                    guard model.selectedMemoryApplication?.processID == memoryPID else { throw Failure.memoryAdmission }
                    model.startFlutterMemoryMonitoring()
                    try await wait(seconds: 25) { model.memorySamples.count >= 3 || !model.isMonitoringMemory }
                    guard model.isMonitoringMemory, model.memorySamples.count >= 3 else { throw Failure.memoryAdmission }
                    print("Physical Workspace: exact native VM sampling active alongside signed screenshot runner")
                }
                let readyAt = model.lastSuccessfulCommandAt
                try await wait(seconds: 15) { model.lastSuccessfulCommandAt != readyAt }
                guard model.isScreenshotReady, model.isConnectionMaintained else { throw Failure.heartbeat }
                if environment["DEVICEBRIDGE_WORKSPACE_CLIPBOARD_REPLACE"] == "1" {
                    // Disposable fixture replacement, not an original clipboard backup/restore.
                    // The unit is 12 UTF-8 bytes; 87,381 units + four fresh ASCII bytes = 1 MiB.
                    let text = maximumClipboard
                        ? String(repeating: "你好 📋\n", count: 87_381) + String(UUID().uuidString.prefix(4))
                        : "DeviceBridge Workspace round trip 📋\n实机完整内容 " + UUID().uuidString
                    guard !maximumClipboard || text.utf8.count == 1_048_576 else { throw Failure.clipboardWrite }
                    model.clipboardText = text
                    model.requestClipboardSend()
                    try await wait(seconds: 35) { !model.isClipboardBusy }
                    guard model.clipboardFeedback == "Sent" else { throw Failure.clipboardWrite }
                    model.clipboardText = ""
                    model.requestClipboardRead()
                    try await wait(seconds: 35) { !model.isClipboardBusy }
                    guard model.clipboardFeedback == "Read", model.clipboardText == text else { throw Failure.clipboardRead }
                    print("Physical Workspace: explicit clipboard WRITE/READ matched the complete disposable fixture")
                    if maximumClipboard { print("Physical Workspace: exact 1 MiB UTF-8 Unicode boundary passed without truncation") }
                }
                model.requestScreenshotCapture()
                try await wait(seconds: 35) { !model.isCapturingScreenshot }
                guard let artifact = model.currentScreenshotArtifact,
                      artifact.sourceDevice == device.identity else { throw Failure.capture }
                let data = try Data(contentsOf: artifact.sessionURL)
                guard let image = CGImageSourceCreateWithData(data as CFData, nil),
                      CGImageSourceGetStatus(image) == .statusComplete,
                      CGImageSourceCreateImageAtIndex(image, 0, nil) != nil else { throw Failure.capture }
                let export = artifact.sessionURL.deletingLastPathComponent().appendingPathComponent("acceptance-export.png")
                defer { try? FileManager.default.removeItem(at: export) }
                model.saveCurrentScreenshot(to: export)
                guard try Data(contentsOf: export) == data else { throw Failure.export }
                print("Physical Workspace: explicit screenshot decoded and exact export verified")
                if let memoryApplication, let memoryPID {
                    let captureFinished = Date()
                    try await wait(seconds: 20) {
                        model.memorySamples.filter { $0.capturedAt > captureFinished }.count >= 3 || !model.isMonitoringMemory
                    }
                    guard model.isMonitoringMemory,
                          model.memorySamples.filter({ $0.capturedAt > captureFinished }).count >= 3,
                          model.memorySamples.allSatisfy({ $0.applicationID == memoryApplication
                              && $0.processID == memoryPID && $0.deviceIdentity == device.identity }) else { throw Failure.memoryContinuity }
                    print("Physical Workspace: attributed native memory continued after actual screenshot capture")
                }
                model.stop()
                await manager.stop()
                guard !model.isScreenshotReady, !model.isClipboardReady,
                      model.currentScreenshotArtifact == nil else { throw Failure.shutdown }
                try await wait(seconds: 10) { !FileManager.default.fileExists(atPath: artifact.sessionURL.path) }
                print("PASS: physical Workspace bundled-source build, authenticated preparation, renewal, screenshot, exact export and Stop")
            } catch {
                model.stop()
                await manager.stop()
                throw error
            }
        } catch let failure as Failure {
            print("FAIL: physical Workspace stage \(failure.rawValue)")
            exit(1)
        } catch {
            print("FAIL: physical Workspace local setup or artifact validation")
            exit(1)
        }
    }

    @MainActor
    static func wait(seconds: Int, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw Failure.timeout }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
    enum Failure: String, Error {
        case deviceUnavailable, preparation, heartbeat, capture, export, shutdown, timeout, clipboardWrite, clipboardRead, memoryAdmission, memoryContinuity
    }
}

private struct PhysicalBuildDiagnosticsRunner: HostCommandRunning {
    func run(_ request: HostCommandRequest) async throws -> HostCommandResult {
        do {
            let result = try await HostCommandRunner().run(request)
            print("Physical Workspace: signed build exit \(result.exitCode)")
            if result.exitCode != 0 {
                let output = result.standardOutputString + String(decoding: result.standardError, as: UTF8.self)
                for (label, fragment) in [
                    ("profile unavailable", "No profiles for"),
                    ("development team required", "requires a development team"),
                    ("account unavailable", "No Accounts"),
                    ("package resolution failure", "Could not resolve package dependencies"),
                    ("ineligible destination", "Unable to find a destination"),
                    ("source path missing", "does not exist")
                ] where output.contains(fragment) {
                    print("Physical Workspace: build diagnostic \(label)")
                }
            }
            return result
        } catch let failure as HostCommandError {
            switch failure {
            case .timedOut: print("Physical Workspace: build timed out")
            case .cancelled: print("Physical Workspace: build cancelled")
            case .outputLimitExceeded: print("Physical Workspace: build output quota exceeded")
            default: print("Physical Workspace: build command boundary failed")
            }
            throw failure
        }
    }
}
