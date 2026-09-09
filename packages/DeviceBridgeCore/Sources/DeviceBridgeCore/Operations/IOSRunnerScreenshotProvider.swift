import Foundation
import DeviceBridgeProtocol

/// The authenticated screenshot boundary, implemented by the owned native runner channel.
public protocol IOSRunnerScreenshotChannel: HelperRequestSending {
    func authenticatedScreenshotContext() async throws -> HelperSessionContext
    func captureScreenshot(_ request: HelperRequest) async throws -> ScreenshotCapturePayload
}

extension IOSRunnerChannel: IOSRunnerScreenshotChannel {}

/// A provider belongs to one selected transport and one authenticated runner launch.
/// Its manager owns channel shutdown; ScreenshotService owns session-token publication.
public struct IOSRunnerScreenshotProvider: ScreenshotProviding {
    private let channel: any IOSRunnerScreenshotChannel
    private let context: HelperSessionContext
    private let transportID: String

    public init(channel: any IOSRunnerScreenshotChannel, context: HelperSessionContext, transportID: String) {
        self.channel = channel
        self.context = context
        self.transportID = transportID
    }

    public func capture(transportID: String) async throws -> ScreenshotCapturePayload {
        try Task.checkCancellation()
        guard transportID == self.transportID,
              try await channel.authenticatedScreenshotContext() == context else {
            throw IOSRunnerChannel.Failure.unavailable
        }
        let now = Date()
        let request = HelperRequest(requestID: UUID(), sessionNonce: context.sessionNonce,
            helperDeviceID: context.helperDeviceID, action: .screenshotCapture, createdAt: now,
            expiresAt: now.addingTimeInterval(30), payload: [:])
        let image = try await channel.captureScreenshot(request)
        try Task.checkCancellation()
        guard try await channel.authenticatedScreenshotContext() == context else {
            throw IOSRunnerChannel.Failure.unavailable
        }
        return image
    }
}
