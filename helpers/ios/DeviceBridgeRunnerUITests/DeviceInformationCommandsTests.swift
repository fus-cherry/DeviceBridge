import Foundation
import UIKit
import XCTest
import DeviceBridgeProtocol

final class DeviceInformationCommandsTests: XCTestCase {
    @MainActor
    func testUnknownBatteryRemainsNullAndMonitoringIsRestored() throws {
        let battery = RuntimeBatteryDouble()
        let reader = NativeDeviceRuntimeReader(battery: battery, screen: { nil })
        let information = try reader.read()
        XCTAssertNil(information.batteryLevel)
        XCTAssertEqual(information.batteryState, "unknown")
        XCTAssertNil(information.screenWidthPixels)
        XCTAssertFalse(battery.isBatteryMonitoringEnabled)
        XCTAssertEqual(battery.monitoringChanges, [true, false])
    }

    @MainActor
    func testAlreadyEnabledBatteryMonitoringRemainsEnabled() throws {
        let battery = RuntimeBatteryDouble(enabled: true, level: 0.5, state: .charging)
        let information = try NativeDeviceRuntimeReader(battery: battery, screen: { nil }).read()
        XCTAssertEqual(information.batteryLevel, 0.5)
        XCTAssertEqual(information.batteryState, "charging")
        XCTAssertTrue(battery.isBatteryMonitoringEnabled)
    }

    @MainActor
    func testScreenPixelsAndLogicalPointsHaveStablePortraitBasis() throws {
        let screen = RuntimeScreenSample(nativeBounds: CGRect(x: 0, y: 0, width: 2622, height: 1206),
            fixedBounds: CGRect(x: 0, y: 0, width: 402, height: 874), scale: 3, nativeScale: 3, maximumFramesPerSecond: 120)
        let value = try NativeDeviceRuntimeReader(battery: RuntimeBatteryDouble(), screen: { screen }).read()
        XCTAssertEqual(value.screenWidthPixels, 1206)
        XCTAssertEqual(value.screenHeightPixels, 2622)
        XCTAssertEqual(value.screenWidthPoints, 402)
        XCTAssertEqual(value.screenHeightPoints, 874)
        XCTAssertEqual(value.screenCoordinateBasis, "fixedPortrait")
    }

    @MainActor
    func testExpiredAndInvalidRequestsNeverSampleRuntime() async {
        let reader = RuntimeReaderDouble()
        let handler = DeviceInformationCommands(reader: reader)
        var request = self.request()
        request.payload = ["extra": .null]
        let invalid = await handler.handle(request)
        XCTAssertEqual(invalid.status, .invalid)
        request.payload = [:]; request.expiresAt = .distantPast
        let expired = await handler.handle(request)
        XCTAssertEqual(expired.status, .expired)
        XCTAssertEqual(reader.readCount, 0)
    }

    @MainActor
    func testCancelledRequestNeverSamplesRuntime() async {
        let reader = RuntimeReaderDouble()
        let request = self.request()
        let task = Task { @MainActor in await DeviceInformationCommands(reader: reader).handle(request) }
        task.cancel()
        let result = await task.value
        XCTAssertEqual(result.status, .cancelled)
        XCTAssertEqual(reader.readCount, 0)
    }

    private func request() -> HelperRequest {
        HelperRequest(requestID: UUID(), sessionNonce: "fixture", helperDeviceID: "fixture", action: .deviceInformation,
            createdAt: Date(), expiresAt: Date().addingTimeInterval(10), payload: [:])
    }
}

@MainActor
private final class RuntimeBatteryDouble: RuntimeBatteryReading {
    var monitoringChanges: [Bool] = []
    var isBatteryMonitoringEnabled: Bool { didSet { monitoringChanges.append(isBatteryMonitoringEnabled) } }
    let batteryLevel: Float
    let batteryState: UIDevice.BatteryState
    init(enabled: Bool = false, level: Float = -1, state: UIDevice.BatteryState = .unknown) {
        isBatteryMonitoringEnabled = enabled; batteryLevel = level; batteryState = state
    }
}
@MainActor
private final class RuntimeReaderDouble: DeviceRuntimeReading {
    private(set) var readCount = 0
    func read() throws -> DeviceRuntimeInformation { readCount += 1; throw DeviceRuntimeInformation.Failure.invalidPayload }
}
