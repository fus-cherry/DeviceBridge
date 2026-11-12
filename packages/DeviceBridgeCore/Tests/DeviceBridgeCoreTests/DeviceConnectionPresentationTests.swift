import Foundation
import Testing
@testable import DeviceBridgeCore

@Suite("Device sidebar connection groups")
struct DeviceConnectionPresentationTests {
    private func device(_ authorization: AuthorizationState, _ statuses: [TransportStatus]) throws -> DeviceRecord {
        let id = try DeviceIdentity(rawValue: "device", stability: .stable, platform: .harmonyOS)
        let transports = try statuses.enumerated().map { index, status in
            try TransportCandidate(id: String(index), identity: id, kind: .usb, source: .hdc, status: status, observedAt: Date())
        }
        return DeviceRecord(identity: id, name: "Device", authorization: authorization, candidates: transports, preferredTransportID: transports.first?.id)
    }
    @Test func availableIsOnlyAnAttemptNotReady() throws {
        let value = DeviceConnectionPresentation(device: try device(.authorized, [.available]))
        #expect(value.canAttemptConnection)
        #expect(value.reason == "Transport detected; connection not yet verified")
    }
    @Test func authorizationBlocksButPreviousFailureAllowsRetry() throws {
        for auth in [AuthorizationState.denied, .actionRequired, .unknown] {
            #expect(!DeviceConnectionPresentation(device: try device(auth, [.available])).canAttemptConnection)
        }
        let value = DeviceConnectionPresentation(device: try device(.authorized, [.available]), failedSelectionReason: "Exact probe failure")
        #expect(value.canAttemptConnection, "a past failure must not hide a detected retryable device")
        #expect(value.reason == "Exact probe failure")
    }
    @Test func inactiveTransportsAreNotConnectable() throws {
        for status in [TransportStatus.offline, .removed, .degraded, .unauthorized, .probing] {
            #expect(!DeviceConnectionPresentation(device: try device(.authorized, [status])).canAttemptConnection)
        }
        #expect(!DeviceConnectionPresentation(device: try device(.authorized, [])).canAttemptConnection)
    }
    @Test func authorizationReasonsAndMixedTransports() throws {
        #expect(DeviceConnectionPresentation(device: try device(.denied, [.available])).reason == "Device authorization denied")
        #expect(DeviceConnectionPresentation(device: try device(.authorized, [.unauthorized])).reason == "Device authorization required")
        #expect(DeviceConnectionPresentation(device: try device(.authorized, [.unauthorized, .available])).canAttemptConnection)
    }
    @Test func discoveredCandidateCanBeCheckedWithoutClaimingReadiness() throws {
        let value = DeviceConnectionPresentation(device: try device(.authorized, [.candidate]))
        #expect(value.canAttemptConnection)
        #expect(value.reason == "Transport detected; connection not yet verified")
    }
    @Test func currentAuthorizationAndOfflineStatusOverrideAnOldFailure() throws {
        let unauthorized = DeviceConnectionPresentation(device: try device(.denied, [.unauthorized]), failedSelectionReason: "Old timeout")
        #expect(!unauthorized.canAttemptConnection)
        #expect(unauthorized.reason == "Device authorization denied")
        let offline = DeviceConnectionPresentation(device: try device(.authorized, [.offline]), failedSelectionReason: "Old timeout")
        #expect(!offline.canAttemptConnection)
        #expect(offline.reason == "No available device transport")
    }
    @Test func oneAvailableTransportSuffices() throws {
        #expect(DeviceConnectionPresentation(device: try device(.authorized, [.offline, .available])).canAttemptConnection)
    }
    @Test func productionDiscoveryParsersProduceCheckableNotReadyDevices() throws {
        let observed = Date()
        let android = try ADBDeviceParser().parse(
            "List of devices attached\nserial device usb:1 model:Pixel transport_id:1\n", observedAt: observed)
        let harmony = try HDCDeviceParser().parse("HDC-serial USB Connected Harmony hdc", observedAt: observed)
        let iphone = try CoreDeviceParser().parse(Data(#"{"result":{"devices":[{"identifier":"ios-route","hardwareProperties":{"udid":"ios-device"},"connectionProperties":{"transportType":"wired","pairingState":"paired"},"deviceProperties":{"name":"iPhone","developerModeStatus":"enabled"}}]}}"#.utf8), observedAt: observed)
        let devices = DeviceInventory.aggregate(android + harmony + iphone)
        #expect(devices.count == 3)
        for device in devices {
            #expect(device.authorization == .authorized)
            #expect(device.candidates.allSatisfy { $0.status == .candidate })
            #expect(DeviceConnectionPresentation(device: device).canAttemptConnection,
                    "a real discovered \(device.identity.platform) device was hidden before selection")
            #expect(DeviceConnectionPresentation(device: device).reason == "Transport detected; connection not yet verified")
        }
    }

}
