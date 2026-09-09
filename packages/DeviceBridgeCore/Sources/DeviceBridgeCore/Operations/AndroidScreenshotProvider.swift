import Foundation

public enum AndroidScreenshotProviderError: Error, Sendable, Equatable {
    case captureFailed
    case emptyOutput
}

public struct AndroidScreenshotProvider: ScreenshotProviding {
    private let adbURL: URL
    private let runner: any HostCommandRunning

    public init(adbURL: URL, runner: any HostCommandRunning) {
        self.adbURL = adbURL
        self.runner = runner
    }

    public func capture(transportID: String) async throws -> ScreenshotCapturePayload {
        let result = try await runner.run(HostCommandRequest(
            executableURL: adbURL,
            arguments: ["-t", transportID, "exec-out", "screencap", "-p"],
            timeout: .seconds(15),
            maximumOutputBytes: 64 * 1_024 * 1_024
        ))
        guard result.exitCode == 0 else {
            throw AndroidScreenshotProviderError.captureFailed
        }
        guard !result.standardOutput.isEmpty else {
            throw AndroidScreenshotProviderError.emptyOutput
        }
        return ScreenshotCapturePayload(data: result.standardOutput, capturedAt: Date())
    }
}
