import Foundation

/// The fixed device.info schema. Null represents unavailable sampling, never an invented zero.
/// Integers are limited to JSONValue's exactly representable Double range before conversion.
public struct DeviceRuntimeInformation: Sendable, Equatable {
    public enum Failure: Error, Sendable, Equatable { case invalidPayload }
    public static let maximumPayloadBytes = 64 * 1024
    public let payload: [String: JSONValue]
    public let systemName: String
    public let systemVersion: String
    public let modelIdentifier: String
    public let processorCount: Int
    public let physicalMemoryBytes: UInt64
    public let screenWidthPixels: Int?
    public let screenHeightPixels: Int?
    public let screenWidthPoints: Double?
    public let screenHeightPoints: Double?
    public let screenCoordinateBasis: String?
    public let screenScale: Double?
    public let screenNativeScale: Double?
    public let maximumFramesPerSecond: Int?
    public let totalStorageBytes: Int64?
    public let availableStorageBytes: Int64?
    public let batteryLevel: Double?
    public let batteryState: String

    public init(payload: [String: JSONValue]) throws {
        let keys: Set<String> = ["systemName", "systemVersion", "modelIdentifier", "processorCount", "physicalMemoryBytes",
            "screenWidthPixels", "screenHeightPixels", "screenWidthPoints", "screenHeightPoints", "screenCoordinateBasis",
            "screenScale", "screenNativeScale", "maximumFramesPerSecond", "totalStorageBytes", "availableStorageBytes",
            "batteryLevel", "batteryState"]
        guard Set(payload.keys) == keys else { throw Failure.invalidPayload }
        func string(_ key: String, nullable: Bool = false) throws -> String? {
            if nullable, payload[key] == .null { return nil }
            guard case .string(let value) = payload[key], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  value.utf8.count <= 1024 else { throw Failure.invalidPayload }
            return value
        }
        func number(_ key: String, nullable: Bool = false, integer: Bool = false, zero: Bool = false) throws -> Double? {
            if nullable, payload[key] == .null { return nil }
            guard case .number(let value) = payload[key], value.isFinite,
                  zero ? value >= 0 : value > 0,
                  value <= 9_007_199_254_740_991,
                  !integer || value.rounded(.towardZero) == value else { throw Failure.invalidPayload }
            return value
        }
        systemName = try string("systemName")!
        systemVersion = try string("systemVersion")!
        modelIdentifier = try string("modelIdentifier")!
        processorCount = Int(try number("processorCount", integer: true)!)
        physicalMemoryBytes = UInt64(try number("physicalMemoryBytes", integer: true)!)
        screenWidthPixels = try number("screenWidthPixels", nullable: true, integer: true).map(Int.init)
        screenHeightPixels = try number("screenHeightPixels", nullable: true, integer: true).map(Int.init)
        screenWidthPoints = try number("screenWidthPoints", nullable: true)
        screenHeightPoints = try number("screenHeightPoints", nullable: true)
        screenCoordinateBasis = try string("screenCoordinateBasis", nullable: true)
        if let screenCoordinateBasis, !["fixedPortrait", "currentLandscape", "currentPortrait"].contains(screenCoordinateBasis) {
            throw Failure.invalidPayload
        }
        guard (screenWidthPoints == nil && screenHeightPoints == nil) || screenCoordinateBasis != nil else {
            throw Failure.invalidPayload
        }
        screenScale = try number("screenScale", nullable: true)
        screenNativeScale = try number("screenNativeScale", nullable: true)
        maximumFramesPerSecond = try number("maximumFramesPerSecond", nullable: true, integer: true).map(Int.init)
        totalStorageBytes = try number("totalStorageBytes", nullable: true, integer: true, zero: true).map(Int64.init)
        availableStorageBytes = try number("availableStorageBytes", nullable: true, integer: true, zero: true).map(Int64.init)
        if let totalStorageBytes, let availableStorageBytes, availableStorageBytes > totalStorageBytes { throw Failure.invalidPayload }
        batteryLevel = try number("batteryLevel", nullable: true, zero: true)
        if let batteryLevel, batteryLevel > 1 { throw Failure.invalidPayload }
        batteryState = try string("batteryState")!
        guard ["unknown", "unplugged", "charging", "full"].contains(batteryState),
              let encoded = try? JSONEncoder().encode(payload), encoded.count <= Self.maximumPayloadBytes else {
            throw Failure.invalidPayload
        }
        self.payload = payload
    }
}
