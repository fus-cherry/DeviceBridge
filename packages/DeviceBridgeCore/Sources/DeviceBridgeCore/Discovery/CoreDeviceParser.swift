import Foundation

public struct CoreDeviceParser: Sendable {
    public init() {}

    public func parse(_ data: Data, observedAt: Date) throws -> [TransportCandidate] {
        let envelope: CoreDeviceEnvelope
        do {
            envelope = try JSONDecoder().decode(CoreDeviceEnvelope.self, from: data)
        } catch {
            throw DeviceParseError.malformedInventory
        }

        return try envelope.result.devices.map { device in
            let rawIdentity = device.hardwareProperties.udid ?? device.identifier
            let identity: DeviceIdentity
            do {
                identity = try DeviceIdentity(
                    rawValue: rawIdentity,
                    stability: device.hardwareProperties.udid == nil ? .provisional : .stable,
                    platform: .iOS
                )
            } catch {
                throw DeviceParseError.invalidIdentity
            }

            let kind: TransportKind = device.connectionProperties.transportType == "wired"
                ? .usb
                : .wifi
            let status: TransportStatus
            if device.connectionProperties.pairingState != "paired" {
                status = .unauthorized
            } else if device.deviceProperties.isLocked == true
                        || device.deviceProperties.developerModeStatus == "disabled" {
                status = .degraded
            } else if kind == .wifi && device.connectionProperties.tunnelState != "connected" {
                status = .offline
            } else {
                status = .candidate
            }

            var metadata: [String: String] = [:]
            metadata["name"] = device.deviceProperties.name
            metadata["model"] = device.hardwareProperties.marketingName
            metadata["osVersion"] = device.deviceProperties.osVersionNumber
            metadata["pairingState"] = device.connectionProperties.pairingState
            metadata["tunnelState"] = device.connectionProperties.tunnelState
            metadata["developerModeStatus"] = device.deviceProperties.developerModeStatus

            return try TransportCandidate(
                id: device.identifier,
                identity: identity,
                kind: kind,
                source: .coreDevice,
                status: status,
                observedAt: observedAt,
                metadata: metadata
            )
        }
    }
}

private struct CoreDeviceEnvelope: Decodable {
    let result: Result

    struct Result: Decodable {
        let devices: [Device]
    }

    struct Device: Decodable {
        let identifier: String
        let hardwareProperties: HardwareProperties
        let connectionProperties: ConnectionProperties
        let deviceProperties: DeviceProperties
    }

    struct HardwareProperties: Decodable {
        let udid: String?
        let platform: String?
        let marketingName: String?
    }

    struct ConnectionProperties: Decodable {
        let transportType: String?
        let pairingState: String?
        let tunnelState: String?
    }

    struct DeviceProperties: Decodable {
        let name: String?
        let osVersionNumber: String?
        let developerModeStatus: String?
        let isLocked: Bool?
    }
}
