import Foundation
import Testing
@testable import DeviceBridgeCore

@Suite("ADB device inventory parser")
struct ADBDeviceParserTests {
    private let observedAt = Date(timeIntervalSince1970: 1_000)

    @Test("parses USB and Wi-Fi candidates with target transport IDs")
    func parsesUSBAndWiFi() throws {
        let output = """
        List of devices attached
        USB-SERIAL device usb:17825792X product:alpha model:Pixel_9 device:alpha transport_id:15
        192.168.1.20:37123 device product:beta model:Pixel_Tablet device:beta transport_id:16

        """

        let devices = try ADBDeviceParser().parse(output, observedAt: observedAt)

        #expect(devices.count == 2)
        #expect(devices[0].id == "15")
        #expect(devices[0].kind == .usb)
        #expect(devices[0].status == .candidate)
        #expect(devices[0].metadata["model"] == "Pixel 9")
        #expect(devices[1].id == "16")
        #expect(devices[1].kind == .wifi)
        #expect(devices[1].endpoint == "192.168.1.20:37123")
    }

    @Test("keeps offline and unauthorized states distinct")
    func parsesUnavailableStates() throws {
        let output = """
        List of devices attached
        one offline transport_id:20
        two unauthorized usb:1-2 transport_id:21
        """

        let devices = try ADBDeviceParser().parse(output, observedAt: observedAt)

        #expect(devices.map(\.status) == [.offline, .unauthorized])
    }

    @Test("rejects a device row without transport ID")
    func rejectsMissingTransportID() {
        let output = "List of devices attached\nserial device model:Pixel\n"
        #expect(throws: DeviceParseError.self) {
            _ = try ADBDeviceParser().parse(output, observedAt: observedAt)
        }
    }

    @Test("deduplicates repeated transport IDs")
    func deduplicatesTransportID() throws {
        let output = """
        List of devices attached
        first device usb:1-1 transport_id:30
        first device usb:1-1 transport_id:30
        """

        let devices = try ADBDeviceParser().parse(output, observedAt: observedAt)
        #expect(devices.count == 1)
    }
}
