import Darwin
import Foundation

/// Explicit user recovery only. Never called by discovery, a probe or background maintenance.
/// Restarts only this user's CoreDeviceService; no pairing, VPN or privileged daemon changes.
public struct IOSDeviceServiceRecovery: Sendable {
    private let runner: any HostCommandRunning
    public init(runner: any HostCommandRunning) { self.runner = runner }

    public func restart() async throws {
        try Task.checkCancellation()
        // A wedged service can ignore SIGTERM (observed on a physical device). The service
        // is managed by XPC and starts again on the next devicectl request.
        let result = try await runner.run(HostCommandRequest(
            executableURL: URL(fileURLWithPath: "/usr/bin/pkill"),
            arguments: ["-KILL", "-u", String(geteuid()), "-x", "CoreDeviceService"],
            timeout: .seconds(5), maximumOutputBytes: 4_096))
        try Task.checkCancellation()
        // pkill returns 1 if the service has already exited. The following probe must still
        // succeed before the caller can commit a session.
        guard result.exitCode == 0 || result.exitCode == 1 else { throw RecoveryError.restartFailed }
    }

    public enum RecoveryError: Error { case restartFailed }
}
