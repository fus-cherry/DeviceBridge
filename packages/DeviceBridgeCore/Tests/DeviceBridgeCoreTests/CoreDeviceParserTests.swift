import Foundation
import Testing
@testable import DeviceBridgeCore

@Suite("CoreDevice JSON parser")
struct CoreDeviceParserTests {
    private let observedAt = Date(timeIntervalSince1970: 2_000)

    @Test("maps wired and connected wireless candidates")
    func parsesWiredAndWireless() throws {
        let data = Data("""
        {
          "info": {"jsonVersion": 2},
          "result": {"devices": [
            {
              "identifier": "core-wired",
              "hardwareProperties": {"udid": "UDID-1", "platform": "iOS", "marketingName": "iPhone 16"},
              "connectionProperties": {"transportType": "wired", "pairingState": "paired", "tunnelState": "disconnected"},
              "deviceProperties": {"name": "Work iPhone", "osVersionNumber": "18.0", "developerModeStatus": "enabled"}
            },
            {
              "identifier": "core-wifi",
              "hardwareProperties": {"udid": "UDID-2", "platform": "iOS", "marketingName": "iPhone 15"},
              "connectionProperties": {"pairingState": "paired", "tunnelState": "connected"},
              "deviceProperties": {"name": "Wireless iPhone", "osVersionNumber": "17.6", "developerModeStatus": "enabled"}
            }
          ]}
        }
        """.utf8)

        let devices = try CoreDeviceParser().parse(data, observedAt: observedAt)

        #expect(devices.count == 2)
        #expect(devices[0].kind == .usb)
        #expect(devices[0].status == .candidate)
        #expect(devices[0].identity.stability == .stable)
        #expect(devices[0].metadata["name"] == "Work iPhone")
        #expect(devices[1].kind == .wifi)
        #expect(devices[1].status == .candidate)
    }

    @Test("maps unpaired, unavailable, and locked devices honestly")
    func mapsRestrictedStates() throws {
        let data = Data("""
        {"result":{"devices":[
          {"identifier":"unpaired","hardwareProperties":{"udid":"U1","platform":"iOS"},"connectionProperties":{"pairingState":"unpaired","tunnelState":"connected"},"deviceProperties":{"name":"One","developerModeStatus":"enabled"}},
          {"identifier":"offline","hardwareProperties":{"udid":"U2","platform":"iOS"},"connectionProperties":{"pairingState":"paired","tunnelState":"disconnected"},"deviceProperties":{"name":"Two","developerModeStatus":"enabled"}},
          {"identifier":"locked","hardwareProperties":{"udid":"U3","platform":"iOS"},"connectionProperties":{"transportType":"wired","pairingState":"paired"},"deviceProperties":{"name":"Three","developerModeStatus":"enabled","isLocked":true}}
        ]}}
        """.utf8)

        let devices = try CoreDeviceParser().parse(data, observedAt: observedAt)
        #expect(devices.map(\.status) == [.unauthorized, .offline, .degraded])
    }

    @Test("rejects missing result devices array")
    func rejectsMalformedRoot() {
        #expect(throws: DeviceParseError.self) {
            _ = try CoreDeviceParser().parse(Data("{}".utf8), observedAt: observedAt)
        }
    }
}
