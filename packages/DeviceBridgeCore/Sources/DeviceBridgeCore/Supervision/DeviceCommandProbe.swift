import Foundation

public enum DeviceCommandProbeOutcome: Sendable, Equatable {
    case ready(checkedAt: Date)
    case unavailable(OperationFailure)

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    public var failure: OperationFailure? {
        if case let .unavailable(failure) = self { return failure }
        return nil
    }
}

public struct DeviceCommandProbe: Sendable {
    private let hdcURL: URL?
    private let adbURL: URL?
    private let xcrunURL: URL?
    private let runner: any HostCommandRunning

    public init(
        adbURL: URL?,
        xcrunURL: URL?,
        runner: any HostCommandRunning,
        hdcURL: URL? = nil
    ) {
        self.hdcURL = hdcURL
        self.adbURL = adbURL
        self.xcrunURL = xcrunURL
        self.runner = runner
    }

    public func probe(
        _ device: DeviceRecord,
        checkedAt: Date = Date()
    ) async -> DeviceCommandProbeOutcome {
        guard let transportID = device.preferredTransportID else {
            return .unavailable(OperationFailure(
                code: .disconnected,
                safeMessage: "No usable transport is available.",
                recoveryAction: "Reconnect the device and refresh."
            ))
        }

        let request: HostCommandRequest
        switch device.identity.platform {
        case .android:
            guard let adbURL else { return missingTool("ADB") }
            request = HostCommandRequest(
                executableURL: adbURL,
                arguments: ["-t", transportID, "get-state"],
                timeout: .seconds(5),
                maximumOutputBytes: 4_096
            )
        case .harmonyOS:
            guard !transportID.isEmpty, !transportID.hasPrefix("-"), !transportID.contains("\0") else {
                return .unavailable(OperationFailure(code: .disconnected, safeMessage: "No valid HDC target is selected."))
            }
            guard let hdcURL else { return missingTool("HDC") }
            request = HostCommandRequest(
                executableURL: hdcURL,
                arguments: ["-t", transportID, "shell", "echo devicebridge-ready"],
                timeout: .seconds(5), maximumOutputBytes: 4_096
            )
        case .iOS:
            guard let xcrunURL else { return missingTool("Xcode command-line tools") }
            request = HostCommandRequest(
                executableURL: xcrunURL,
                arguments: [
                    "devicectl", "device", "info", "details",
                    "--device", transportID, "--quiet", "--timeout", "5",
                ],
                timeout: .seconds(7),
                maximumOutputBytes: 64 * 1_024
            )
        }

        do {
            let result = try await runner.run(request)
            if device.identity.platform == .iOS, result.exitCode != 0,
               result.standardErrorString.contains("Command timeout of "),
               result.standardErrorString.contains(" seconds exceeded.") {
                return iosTimeout()
            }
            guard result.exitCode == 0 else {
                return .unavailable(OperationFailure(
                    code: .disconnected,
                    safeMessage: "The selected device did not accept a command.",
                    recoveryAction: "Unlock, authorize, or reconnect the device, then retry."
                ))
            }
            if device.identity.platform == .android {
                let state = result.standardOutputString
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard state == "device" else {
                    return .unavailable(OperationFailure(
                        code: .malformedOutput,
                        safeMessage: "ADB returned an unexpected readiness state.",
                        recoveryAction: "Refresh the device list and retry."
                    ))
                }
            }
            if device.identity.platform == .harmonyOS,
               result.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines) != "devicebridge-ready" {
                return .unavailable(OperationFailure(code: .disconnected, safeMessage: "HDC did not confirm shell access. Unlock and authorize the device."))
            }
            return .ready(checkedAt: checkedAt)
        } catch HostCommandError.cancelled {
            return .unavailable(OperationFailure(code: .cancelled, safeMessage: "Readiness check cancelled."))
        } catch HostCommandError.timedOut {
            if device.identity.platform == .iOS { return iosTimeout() }
            return .unavailable(OperationFailure(
                code: .timeout,
                safeMessage: "The readiness check timed out.",
                recoveryAction: "Check the connection and retry."
            ))
        } catch {
            return .unavailable(OperationFailure(
                code: .failure,
                safeMessage: "The readiness check could not run.",
                recoveryAction: "Check the host tools and reconnect the device."
            ))
        }
    }

    private func iosTimeout() -> DeviceCommandProbeOutcome {
        .unavailable(OperationFailure(
            code: .timeout,
            safeMessage: "The iPhone command check timed out. Apple's device service may be unresponsive.",
            recoveryAction: "Keep the iPhone unlocked and retry. If it still fails, use Repair connection to restart Apple's device service."
        ))
    }

    private func missingTool(_ name: String) -> DeviceCommandProbeOutcome {
        .unavailable(OperationFailure(
            code: .toolMissing,
            safeMessage: "\(name) is unavailable.",
            recoveryAction: "Install or select the required developer tools."
        ))
    }
}
