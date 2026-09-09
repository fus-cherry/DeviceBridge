import Foundation
import Testing
@testable import DeviceBridgeProtocol

struct DeviceRuntimeInformationTests {
    static var payload: [String: JSONValue] { [
        "systemName": .string("iOS"), "systemVersion": .string("26.6"), "modelIdentifier": .string("iPhone17,1"),
        "processorCount": .number(6), "physicalMemoryBytes": .number(8_589_934_592),
        "screenWidthPixels": .number(1206), "screenHeightPixels": .number(2622),
        "screenWidthPoints": .number(402), "screenHeightPoints": .number(874),
        "screenCoordinateBasis": .string("fixedPortrait"), "screenScale": .number(3), "screenNativeScale": .number(3),
        "maximumFramesPerSecond": .number(120), "totalStorageBytes": .number(256_000_000_000),
        "availableStorageBytes": .number(64_000_000_000), "batteryLevel": .null, "batteryState": .string("unknown")
    ] }

    @Test func validPayloadRoundTripsWithoutInventingUnknownBattery() throws {
        let value = try DeviceRuntimeInformation(payload: Self.payload)
        #expect(value.payload == Self.payload)
        #expect(value.physicalMemoryBytes == 8_589_934_592)
        #expect(value.batteryLevel == nil)
        #expect(value.screenCoordinateBasis == "fixedPortrait")
    }
    @Test func optionalSamplesRequireExplicitNull() throws {
        var payload = Self.payload
        for key in ["screenWidthPixels", "screenHeightPixels", "screenWidthPoints", "screenHeightPoints", "screenCoordinateBasis", "screenScale", "screenNativeScale", "maximumFramesPerSecond", "totalStorageBytes", "availableStorageBytes", "batteryLevel"] { payload[key] = .null }
        #expect(try DeviceRuntimeInformation(payload: payload).screenWidthPixels == nil)
        payload.removeValue(forKey: "batteryLevel")
        #expect(throws: DeviceRuntimeInformation.Failure.invalidPayload) { try DeviceRuntimeInformation(payload: payload) }
    }
    @Test func rejectsUnknownKeysInvalidTypesAndUnsafeNumbers() {
        let mutations: [(String, JSONValue)] = [
            ("extra", .null), ("systemName", .null), ("systemName", .string("")),
            ("systemVersion", .string(String(repeating: "x", count: 1025))), ("processorCount", .bool(true)),
            ("processorCount", .number(1.5)), ("processorCount", .number(0)), ("physicalMemoryBytes", .number(9_007_199_254_740_992)),
            ("physicalMemoryBytes", .number(Double(UInt64.max))), ("screenWidthPixels", .number(-1)),
            ("screenScale", .number(.infinity)), ("screenHeightPoints", .number(.nan)),
            ("screenCoordinateBasis", .string("landscape")), ("totalStorageBytes", .number(-1)),
            ("availableStorageBytes", .number(257_000_000_000)), ("batteryLevel", .number(-1)),
            ("batteryLevel", .number(1.01)), ("batteryState", .string("missing"))
        ]
        for (key, value) in mutations {
            var payload = Self.payload; payload[key] = value
            #expect(throws: DeviceRuntimeInformation.Failure.invalidPayload) { try DeviceRuntimeInformation(payload: payload) }
        }
    }
    @Test func safeIntegerBoundaryAndZeroAvailableCapacityAreAccepted() throws {
        var payload = Self.payload
        payload["physicalMemoryBytes"] = .number(9_007_199_254_740_991)
        payload["availableStorageBytes"] = .number(0)
        #expect(try DeviceRuntimeInformation(payload: payload).physicalMemoryBytes == 9_007_199_254_740_991)
    }
}
