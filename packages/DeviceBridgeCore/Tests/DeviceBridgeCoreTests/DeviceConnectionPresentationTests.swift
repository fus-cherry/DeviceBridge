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
    @Test func authorizationAndFailureTakePrecedence() throws {
        for auth in [AuthorizationState.denied, .actionRequired, .unknown] {
            #expect(!DeviceConnectionPresentation(device: try device(auth, [.available])).canAttemptConnection)
        }
        let value = DeviceConnectionPresentation(device: try device(.authorized, [.available]), failedSelectionReason: "Exact probe failure")
        #expect(!value.canAttemptConnection)
        #expect(value.reason == "Exact probe failure")
    }
    @Test func inactiveTransportsAreNotConnectable() throws {
        for status in [TransportStatus.offline, .removed, .degraded, .unauthorized, .candidate, .probing] {
            #expect(!DeviceConnectionPresentation(device: try device(.authorized, [status])).canAttemptConnection)
        }
        #expect(!DeviceConnectionPresentation(device: try device(.authorized, [])).canAttemptConnection)
    }
    @Test func authorizationReasonsAndMixedTransports() throws {
        #expect(DeviceConnectionPresentation(device: try device(.denied, [.available])).reason == "Device authorization denied")
        #expect(DeviceConnectionPresentation(device: try device(.authorized, [.unauthorized])).reason == "Device authorization required")
        #expect(DeviceConnectionPresentation(device: try device(.authorized, [.unauthorized, .available])).canAttemptConnection)
    }
    @Test func oneAvailableTransportSuffices() throws {
        #expect(DeviceConnectionPresentation(device: try device(.authorized, [.offline, .available])).canAttemptConnection)
    }
}
