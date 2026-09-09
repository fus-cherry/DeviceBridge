import Foundation

public enum HelperFrameError: Error, Sendable, Equatable {
    case invalidHeader
    case invalidLength
    case envelopeTooLarge
}

public enum HelperFrameCodec {
    public static func encode(_ payload: Data) throws -> Data {
        guard payload.count <= HelperWireCodec.maximumEnvelopeBytes else {
            throw HelperFrameError.envelopeTooLarge
        }
        var length = UInt32(payload.count).bigEndian
        var frame = withUnsafeBytes(of: &length) { Data($0) }
        frame.append(payload)
        return frame
    }

    public static func decode(_ frame: Data) throws -> Data {
        guard frame.count >= 4 else { throw HelperFrameError.invalidHeader }
        let header = frame.prefix(4)
        let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length <= HelperWireCodec.maximumEnvelopeBytes else {
            throw HelperFrameError.envelopeTooLarge
        }
        guard frame.count == 4 + Int(length) else { throw HelperFrameError.invalidLength }
        return frame.dropFirst(4)
    }
}

public enum JSONValue: Codable, Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value") }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    public var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    public var boolValue: Bool? {
        if case let .bool(value) = self { return value }
        return nil
    }
}

public enum HelperAction: String, Codable, Hashable, Sendable {
    case identity
    case clipboardRead = "clipboard.read"
    case clipboardWrite = "clipboard.write"
    case screenshotCapture = "screenshot.capture"
    case deviceInformation = "device.info"
    case fileHash = "file.hash"
    case keepAliveStart = "keepAlive.start"
    case keepAliveRenew = "keepAlive.renew"
    case keepAliveStop = "keepAlive.stop"
    case keepAliveStatus = "keepAlive.status"
    case stop
}

public struct HelperRequest: Codable, Hashable, Sendable {
    public var protocolVersion: Int
    public var requestID: UUID
    public var sessionNonce: String
    public var helperDeviceID: String
    public var action: HelperAction
    public var createdAt: Date
    public var expiresAt: Date
    public var payload: [String: JSONValue]

    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case requestID = "requestId"
        case sessionNonce
        case helperDeviceID = "helperDeviceId"
        case action
        case createdAt
        case expiresAt
        case payload
    }

    public init(
        protocolVersion: Int = 1,
        requestID: UUID,
        sessionNonce: String,
        helperDeviceID: String,
        action: HelperAction,
        createdAt: Date,
        expiresAt: Date,
        payload: [String: JSONValue]
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.sessionNonce = sessionNonce
        self.helperDeviceID = helperDeviceID
        self.action = action
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.payload = payload
    }
}

public enum HelperResultStatus: String, Codable, Hashable, Sendable {
    case success
    case actionRequired
    case permissionDenied
    case cancelled
    case expired
    case invalid
    case failure
}

public struct HelperErrorPayload: Codable, Hashable, Sendable {
    public let code: String
    public let message: String
    public let recoveryAction: String?

    public init(code: String, message: String, recoveryAction: String? = nil) {
        self.code = code
        self.message = message
        self.recoveryAction = recoveryAction
    }
}

public struct HelperResult: Codable, Hashable, Sendable {
    public let protocolVersion: Int
    public let requestID: UUID
    public let status: HelperResultStatus
    public let completedAt: Date
    public let payload: [String: JSONValue]?
    public let error: HelperErrorPayload?

    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case requestID = "requestId"
        case status
        case completedAt
        case payload
        case error
    }

    public init(
        protocolVersion: Int = 1,
        requestID: UUID,
        status: HelperResultStatus,
        completedAt: Date,
        payload: [String: JSONValue]? = nil,
        error: HelperErrorPayload? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.status = status
        self.completedAt = completedAt
        self.payload = payload
        self.error = error
    }

    public var isStructurallyValid: Bool {
        if status == .success { return error == nil }
        return payload == nil && error != nil
    }
}

public struct HelperWireCodec: Sendable {
    /// Complete clipboard text must fit; platform services must never truncate to this limit.
    public static let maximumClipboardUTF8Bytes = 1_048_576

    // JSON can expand one control byte into six ASCII bytes (\\u0000).
    public static let maximumEnvelopeBytes = 6 * maximumClipboardUTF8Bytes + 64 * 1_024

    public init() {}

    public func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }

    public func decodeRequest(_ data: Data) throws -> HelperRequest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(HelperRequest.self, from: data)
    }

    public func decodeResult(_ data: Data) throws -> HelperResult {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(HelperResult.self, from: data)
    }
}

public enum HelperRequestValidationError: String, Sendable, Equatable {
    case unsupportedVersion
    case replayed
    case nonceMismatch
    case deviceMismatch
    case expired
    case invalidTimestamp
    case envelopeTooLarge
}

public enum HelperRequestValidationResult: Sendable, Equatable {
    case accepted
    case rejected(HelperRequestValidationError)
}

public actor HelperRequestValidator {
    private let sessionNonce: String
    private let helperDeviceID: String
    private var completedRequestIDs: Set<UUID> = []

    public init(sessionNonce: String, helperDeviceID: String) {
        self.sessionNonce = sessionNonce
        self.helperDeviceID = helperDeviceID
    }

    public func validate(
        _ request: HelperRequest,
        encodedByteCount: Int,
        now: Date
    ) -> HelperRequestValidationResult {
        guard encodedByteCount <= HelperWireCodec.maximumEnvelopeBytes else {
            return .rejected(.envelopeTooLarge)
        }
        guard request.protocolVersion == 1 else { return .rejected(.unsupportedVersion) }
        guard !completedRequestIDs.contains(request.requestID) else { return .rejected(.replayed) }
        guard request.sessionNonce == sessionNonce else { return .rejected(.nonceMismatch) }
        guard request.helperDeviceID == helperDeviceID else { return .rejected(.deviceMismatch) }
        guard request.createdAt <= request.expiresAt,
              request.createdAt <= now.addingTimeInterval(120) else {
            return .rejected(.invalidTimestamp)
        }
        guard request.expiresAt >= now else { return .rejected(.expired) }
        return .accepted
    }

    public func markCompleted(_ requestID: UUID) {
        completedRequestIDs.insert(requestID)
    }
}
