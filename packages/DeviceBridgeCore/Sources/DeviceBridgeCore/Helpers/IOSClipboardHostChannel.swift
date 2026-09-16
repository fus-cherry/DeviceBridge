import Foundation
import DeviceBridgeProtocol

/// Foregrounds the dedicated clipboard app only at an explicit clipboard content boundary.
/// Identity, heartbeat and Stop never change the phone's foreground application.
public struct IOSClipboardHostChannel: IOSRunnerClipboardChannel {
    private let channel: any HelperRequestSending
    private let xcrunURL: URL
    private let deviceIdentifier: String
    private let commands: any HostCommandRunning
    private let environment: [String: String]

    init(channel: any HelperRequestSending, xcrunURL: URL, deviceIdentifier: String,
         commands: any HostCommandRunning, environment: [String: String]) {
        self.channel = channel
        self.xcrunURL = xcrunURL
        self.deviceIdentifier = deviceIdentifier
        self.commands = commands
        self.environment = environment
    }

    public func authenticatedClipboardContext() async throws -> HelperSessionContext {
        guard let clipboard = channel as? any IOSRunnerClipboardChannel else {
            throw IOSRunnerChannel.Failure.unavailable
        }
        return try await clipboard.authenticatedClipboardContext()
    }

    public func send(_ request: HelperRequest) async throws -> HelperResult {
        if request.action == .clipboardRead || request.action == .clipboardWrite {
            try Task.checkCancellation()
            let remaining = Date().distance(to: request.expiresAt)
            guard remaining.isFinite, remaining > 0 else { throw IOSRunnerChannel.Failure.unavailable }
            let result = try await commands.run(HostCommandRequest(executableURL: xcrunURL,
                arguments: ["devicectl", "device", "process", "launch", "--device", deviceIdentifier,
                    "--activate", "--quiet", IOSRunnerCodeRole.clipboardHost.bundleIdentifier],
                environment: environment, timeout: .seconds(min(5, remaining)), maximumOutputBytes: 4_096))
            try Task.checkCancellation()
            guard result.exitCode == 0 else { throw IOSRunnerChannel.Failure.unavailable }
        }
        return try await channel.send(request)
    }
}
