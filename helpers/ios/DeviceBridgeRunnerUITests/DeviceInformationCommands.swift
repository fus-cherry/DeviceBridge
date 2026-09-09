import Foundation
import UIKit
import Darwin
import DeviceBridgeProtocol
import DeviceBridgeSecureChannel

@MainActor
protocol DeviceRuntimeReading: AnyObject {
    func read() throws -> DeviceRuntimeInformation
}

@MainActor
protocol RuntimeBatteryReading: AnyObject {
    var isBatteryMonitoringEnabled: Bool { get set }
    var batteryLevel: Float { get }
    var batteryState: UIDevice.BatteryState { get }
}
extension UIDevice: RuntimeBatteryReading {}

struct RuntimeScreenSample {
    let nativeBounds: CGRect
    let fixedBounds: CGRect
    let scale: Double
    let nativeScale: Double
    let maximumFramesPerSecond: Int
}

/// Public property sampling only: no activation, capture, clipboard or application control.
@MainActor
final class NativeDeviceRuntimeReader: DeviceRuntimeReading {
    private let battery: any RuntimeBatteryReading
    private let screen: @MainActor () -> RuntimeScreenSample?

    init(battery: any RuntimeBatteryReading = UIDevice.current,
         screen: @escaping @MainActor () -> RuntimeScreenSample? = {
             let screen = UIScreen.main
             return RuntimeScreenSample(nativeBounds: screen.nativeBounds, fixedBounds: screen.fixedCoordinateSpace.bounds,
                 scale: screen.scale, nativeScale: screen.nativeScale, maximumFramesPerSecond: screen.maximumFramesPerSecond)
         }) {
        self.battery = battery; self.screen = screen
    }

    func read() throws -> DeviceRuntimeInformation {
        let monitoring = battery.isBatteryMonitoringEnabled
        if !monitoring { battery.isBatteryMonitoringEnabled = true }
        defer { if !monitoring { battery.isBatteryMonitoringEnabled = monitoring } }
        let device = UIDevice.current
        let process = ProcessInfo.processInfo
        var machine = utsname()
        guard uname(&machine) == 0 else { throw DeviceRuntimeInformation.Failure.invalidPayload }
        let machineByteCount = MemoryLayout.size(ofValue: machine.machine)
        let model = withUnsafePointer(to: &machine.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: machineByteCount) { String(cString: $0) }
        }
        func optionalNumber(_ value: Double?, integer: Bool = false, zero: Bool = false) -> JSONValue {
            guard let value, value.isFinite, zero ? value >= 0 : value > 0,
                  value <= 9_007_199_254_740_991, !integer || value.rounded(.towardZero) == value else { return .null }
            return .number(value)
        }
        let sample = screen()
        let pixels = sample.map { $0.nativeBounds.size }
        let points = sample.map { $0.fixedBounds.size }
        // nativeBounds is natural portrait. Normalize its axes defensively; fixed points are
        // from the same screen's fixed coordinate space, never the rotating current bounds.
        let widthPixels = pixels.map { Double(min($0.width, $0.height)) }
        let heightPixels = pixels.map { Double(max($0.width, $0.height)) }
        let widthPoints = points.map { Double(min($0.width, $0.height)) }
        let heightPoints = points.map { Double(max($0.width, $0.height)) }
        let volume = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey])
        var total = volume?.volumeTotalCapacity.map { optionalNumber(Double($0), integer: true, zero: true) } ?? .null
        var available = volume?.volumeAvailableCapacity.map { optionalNumber(Double($0), integer: true, zero: true) } ?? .null
        if case .number(let t) = total, case .number(let a) = available, a > t { total = .null; available = .null }
        let level = Double(battery.batteryLevel)
        let state: String
        switch battery.batteryState {
        case .unknown: state = "unknown"
        case .unplugged: state = "unplugged"
        case .charging: state = "charging"
        case .full: state = "full"
        @unknown default: state = "unknown"
        }
        return try DeviceRuntimeInformation(payload: [
            "systemName": .string(device.systemName), "systemVersion": .string(device.systemVersion), "modelIdentifier": .string(model),
            "processorCount": .number(Double(process.processorCount)), "physicalMemoryBytes": .number(Double(process.physicalMemory)),
            "screenWidthPixels": optionalNumber(widthPixels, integer: true), "screenHeightPixels": optionalNumber(heightPixels, integer: true),
            "screenWidthPoints": optionalNumber(widthPoints), "screenHeightPoints": optionalNumber(heightPoints),
            "screenCoordinateBasis": sample == nil ? .null : .string("fixedPortrait"),
            "screenScale": optionalNumber(sample?.scale), "screenNativeScale": optionalNumber(sample?.nativeScale),
            "maximumFramesPerSecond": optionalNumber(sample.map { Double($0.maximumFramesPerSecond) }, integer: true),
            "totalStorageBytes": total, "availableStorageBytes": available,
            "batteryLevel": level <= 1 ? optionalNumber(level, zero: true) : .null, "batteryState": .string(state)
        ])
    }
}

@MainActor
final class DeviceInformationCommands: IOSRunnerDeviceInformationHandling {
    private let reader: any DeviceRuntimeReading
    init(reader: any DeviceRuntimeReading = NativeDeviceRuntimeReader()) { self.reader = reader }

    func handle(_ request: HelperRequest) async -> HelperResult {
        guard request.action == .deviceInformation, request.payload.isEmpty else {
            return failure(request, .invalid, "device_info.invalid")
        }
        let remaining = request.expiresAt.timeIntervalSinceNow
        let deadline = ContinuousClock.now.advanced(by: .seconds(remaining.isFinite ? max(0, min(30, remaining)) : 0))
        do {
            try Task.checkCancellation()
            guard remaining.isFinite, Date() < request.expiresAt, ContinuousClock.now < deadline else {
                return failure(request, .expired, "device_info.expired")
            }
            let information = try reader.read()
            try Task.checkCancellation()
            guard Date() < request.expiresAt, ContinuousClock.now < deadline else {
                return failure(request, .expired, "device_info.expired")
            }
            return HelperResult(requestID: request.requestID, status: .success, completedAt: Date(), payload: information.payload)
        } catch is CancellationError { return failure(request, .cancelled, "device_info.cancelled") }
        catch { return failure(request, .failure, "device_info.unavailable") }
    }

    private func failure(_ request: HelperRequest, _ status: HelperResultStatus, _ code: String) -> HelperResult {
        HelperResult(requestID: request.requestID, status: status, completedAt: Date(),
            error: HelperErrorPayload(code: code, message: "Device information could not be sampled."))
    }
}
