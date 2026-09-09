import Foundation
import Testing
@testable import DeviceBridgeCore

@Suite("Device information report contract")
struct DeviceInformationTests {
    private let sampledAt = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("invalid numbers and oversize text become unavailable rather than normal values")
    func validatesValues() {
        let source = DeviceInformationSource(kind: .adb, queriedAt: sampledAt)
        for value in [Double.nan, Double.infinity, -1, 101] {
            let field = DeviceInformationField.available(id: "battery.level", title: "Battery level",
                value: .decimal(value), unit: .percent, source: source)
            #expect(field.value == nil)
            #expect(field.unavailableReason == .invalidData)
        }
        #expect(DeviceInformationField.available(id: "name", title: "Device name",
            value: .text(String(repeating: "x", count: 1_025)), source: source).value == nil)
        #expect(DeviceInformationField.available(id: "battery.temperature", title: "Temperature",
            value: .decimal(-5), unit: .celsius, source: source).value == .decimal(-5))
        #expect(DeviceInformationField.available(id: "battery.level", title: "Battery level",
            value: .decimal(0), unit: .percent, source: source).value == .decimal(0))
    }

    @Test("report owns device and source times and copies one complete snapshot")
    func reportCopy() throws {
        let identity = try DeviceIdentity(rawValue: "DEVICE-ONE", stability: .stable, platform: .iOS)
        let session = ConnectionSession(deviceIdentity: identity, generation: 1,
            transportID: "ROUTE-ONE", state: .active, startedAt: sampledAt)
        let cached = DeviceInformationSource(kind: .coreDevice, queriedAt: sampledAt,
            freshness: .possiblyCached)
        let report = try DeviceInformationReport(deviceName: "My phone", session: session,
            queryStartedAt: sampledAt, queryFinishedAt: sampledAt.addingTimeInterval(2),
            sections: [.init(id: "screen", title: "Screen", fields: [
                .available(id: "screen.width", title: "Native width", value: .integer(1170),
                    unit: .pixels, source: cached),
                .unavailable(id: "memory.available", title: "Available memory", reason: .unsupported,
                    recoveryAction: "This platform does not provide this value.")
            ])])
        let text = report.formattedText(in: .english)
        #expect(text.contains("My phone"))
        #expect(text.contains("DEVICE-ONE"))
        #expect(text.contains("1170 px"))
        #expect(text.contains("possibly cached"))
        #expect(text.contains("Available memory"))
        #expect(report.isPartial)
        #expect(report.hasAvailableFields)
        #expect(report.sections[0].fields[0].source?.queriedAt == sampledAt)
        let data = try JSONEncoder().encode(report)
        #expect(try JSONDecoder().decode(DeviceInformationReport.self, from: data) == report)
    }

    @Test("report rejects duplicate fields and aggregate payload overflow")
    func reportLimits() throws {
        let identity = try DeviceIdentity(rawValue: "test", stability: .stable, platform: .android)
        let session = ConnectionSession(deviceIdentity: identity, generation: 1,
            transportID: "1", state: .active, startedAt: sampledAt)
        let field = DeviceInformationCatalog.unavailable("battery.level", reason: .notReturned)
        #expect(throws: DeviceInformationReportError.invalidReport) {
            try DeviceInformationReport(deviceName: "Phone", session: session,
                queryStartedAt: sampledAt, queryFinishedAt: sampledAt,
                sections: [.init(id: "a", title: "Battery", fields: [field, field])])
        }
        let source = DeviceInformationSource(kind: .adb, queriedAt: sampledAt)
        let fields = (0..<80).map { index in
            DeviceInformationField.available(id: "field-\(index)", title: "Field",
                value: .text(String(repeating: "x", count: 1_024)), source: source)
        }
        #expect(throws: DeviceInformationReportError.reportTooLarge) {
            try DeviceInformationReport(deviceName: "Phone", session: session,
                queryStartedAt: sampledAt, queryFinishedAt: sampledAt,
                sections: [.init(id: "a", title: "Fields", fields: fields)])
        }
        #expect(throws: DeviceInformationReportError.invalidReport) {
            try DeviceInformationReport(deviceName: "Phone", session: session,
                queryStartedAt: sampledAt, queryFinishedAt: sampledAt.addingTimeInterval(-1), sections: [])
        }
    }

    @Test("catalog supplies all required groups and distinguishes pixel and density concepts")
    func fieldCatalog() {
        let fields = DeviceInformationCatalog.sections.flatMap(\.fields)
        #expect(Set(DeviceInformationCatalog.sections.map(\.id)) ==
            Set(["identity", "system", "screen", "hardware", "memory", "battery", "connection"]))
        #expect(Set(fields.map(\.id)).count == fields.count)
        for id in ["screen.physicalWidth", "screen.overrideWidth", "screen.effectiveWidth",
                   "screen.physicalDensity", "screen.overrideDensity", "screen.effectiveDensity",
                   "screen.logicalWidth", "screen.nativeScale", "screen.maximumRefreshRate",
                   "memory.total", "memory.available", "storage.total", "battery.level"] {
            #expect(fields.contains { $0.id == id }, "Missing \(id)")
        }
    }
}
