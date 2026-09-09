import Foundation
import DeviceBridgeProtocol

/// Read-only metadata requires the optional capability on this authenticated runner launch.
/// Invalidation is an immediate logical event, independent of pending request cleanup.
public protocol IOSRunnerDeviceInformationChannel: HelperRequestSending {
    var launchID: UUID { get }
    func authenticatedDeviceInformationContext() async throws -> HelperSessionContext
    func registerInvalidationHandler(_ handler: @escaping @Sendable (UUID) -> Void) async
}

extension IOSRunnerChannel: IOSRunnerDeviceInformationChannel {}
