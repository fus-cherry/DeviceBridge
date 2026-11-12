/// Inventory presentation only. A discovered transport is not a successful command probe.
public struct DeviceConnectionPresentation: Equatable, Sendable {
    public let canAttemptConnection: Bool
    public let reason: String

    public init(device: DeviceRecord, failedSelectionReason: String? = nil) {
        if device.authorization == .denied {
            canAttemptConnection = false
            reason = "Device authorization denied"
        } else if device.authorization == .actionRequired {
            canAttemptConnection = false
            reason = "Device authorization required"
        } else if device.candidates.contains(where: { $0.status == .candidate || $0.status == .available }),
                  device.authorization == .authorized {
            // Discovery is enough to offer a check, never enough to declare tools ready.
            // A previous probe failure is useful advice, not a permanent retry lock.
            canAttemptConnection = true
            reason = failedSelectionReason ?? "Transport detected; connection not yet verified"
        } else {
            canAttemptConnection = false
            if device.candidates.contains(where: { $0.status == .unauthorized }) {
                reason = "Device authorization required"
            } else if device.candidates.contains(where: { $0.status == .available || $0.status == .candidate || $0.status == .probing }) {
                reason = "Connection or authorization not yet verified"
            } else if device.candidates.contains(where: { $0.status == .degraded }) {
                reason = "Device transport degraded"
            } else {
                reason = "No available device transport"
            }
        }
    }
}
