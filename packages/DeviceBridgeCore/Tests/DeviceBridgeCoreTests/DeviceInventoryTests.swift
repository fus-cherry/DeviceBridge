import Foundation
import Testing
@testable import DeviceBridgeCore

@Suite("Device inventory aggregation")
struct DeviceInventoryTests {
    @Test("stable candidates merge and a healthy wired route wins")
    func mergesStableIdentityWithWiredPreference() throws {
        let identity = try DeviceIdentity(rawValue: "stable-1", stability: .stable, platform: .iOS)
        let wifi = try candidate(id: "wifi", identity: identity, kind: .wifi, status: .available)
        let usb = try candidate(id: "usb", identity: identity, kind: .usb, status: .available)

        let records = DeviceInventory.aggregate([wifi, usb])

        #expect(records.count == 1)
        #expect(records[0].candidates.count == 2)
        #expect(records[0].preferredTransportID == "usb")
        #expect(records[0].authorization == .authorized)
    }

    @Test("provisional transports with different identities stay separate")
    func provisionalCandidatesDoNotMerge() throws {
        let one = try DeviceIdentity(rawValue: "android:usb-one", stability: .provisional, platform: .android)
        let two = try DeviceIdentity(rawValue: "android:wifi-two", stability: .provisional, platform: .android)

        let records = DeviceInventory.aggregate([
            try candidate(id: "1", identity: one, kind: .usb, status: .candidate),
            try candidate(id: "2", identity: two, kind: .wifi, status: .candidate),
        ])

        #expect(records.count == 2)
        #expect(Set(records.map(\.identity)) == [one, two])
    }

    @Test("unavailable wired route does not replace an available wireless route")
    func availableRouteWinsBeforeKind() throws {
        let identity = try DeviceIdentity(rawValue: "stable-2", stability: .stable, platform: .android)
        let offlineUSB = try candidate(id: "usb", identity: identity, kind: .usb, status: .offline)
        let liveWiFi = try candidate(id: "wifi", identity: identity, kind: .wifi, status: .available)

        let records = DeviceInventory.aggregate([offlineUSB, liveWiFi])
        #expect(records[0].preferredTransportID == "wifi")
    }

    private func candidate(
        id: String,
        identity: DeviceIdentity,
        kind: TransportKind,
        status: TransportStatus
    ) throws -> TransportCandidate {
        try TransportCandidate(
            id: id,
            identity: identity,
            kind: kind,
            source: identity.platform == .android ? .adb : .coreDevice,
            status: status,
            observedAt: Date(timeIntervalSince1970: 100),
            metadata: ["name": "Test Device"]
        )
    }
}
