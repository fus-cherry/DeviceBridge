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
    private let adbURL: URL?
    private let xcrunURL: URL?
    private let runner: any HostCommandRunning

    public init(
        adbURL: URL?,
        xcrunURL: URL?,
        runner: any HostCommandRunning
    ) {
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
            return .ready(checkedAt: checkedAt)
        } catch HostCommandError.cancelled {
            return .unavailable(OperationFailure(code: .cancelled, safeMessage: "Readiness check cancelled."))
        } catch HostCommandError.timedOut {
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

    private func missingTool(_ name: String) -> DeviceCommandProbeOutcome {
        .unavailable(OperationFailure(
            code: .toolMissing,
            safeMessage: "\(name) is unavailable.",
            recoveryAction: "Install or select the required developer tools."
        ))
    }
}
