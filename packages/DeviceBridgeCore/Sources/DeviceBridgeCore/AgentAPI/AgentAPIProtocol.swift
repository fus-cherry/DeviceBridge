import Foundation
import DeviceBridgeProtocol

public struct AgentAPIRequest: Sendable, Equatable {
    public enum Method: String, Sendable, CaseIterable {
        case deviceCurrent = "device.current"
        case deviceInfoRead = "device.info.read"
        case androidShellRun = "android.shell.run"
        case operationGet = "operation.get"
        case operationCancel = "operation.cancel"
    }
    public struct Parameters: Sendable, Equatable {
        public let sessionKey: String?
        public let command: String?
        public let operationID: UUID?
    }
    public let requestID: UUID
    public let method: Method
    public let params: Parameters

    public init(requestID: UUID, method: Method, sessionKey: String? = nil, command: String? = nil, operationID: UUID? = nil) throws {
        if let sessionKey {
            guard !sessionKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  sessionKey.utf8.count <= 512, !sessionKey.utf8.contains(0) else { throw AgentAPIWire.Failure.invalidRequest }
        }
        switch method {
        case .deviceCurrent:
            guard sessionKey == nil, command == nil, operationID == nil else { throw AgentAPIWire.Failure.invalidRequest }
        case .deviceInfoRead:
            guard sessionKey != nil, command == nil, operationID == nil else { throw AgentAPIWire.Failure.invalidRequest }
        case .androidShellRun:
            guard sessionKey != nil, let command, AndroidShellInput.validate(command) == nil, operationID == nil else { throw AgentAPIWire.Failure.invalidRequest }
        case .operationGet, .operationCancel:
            guard sessionKey != nil, command == nil, operationID != nil else { throw AgentAPIWire.Failure.invalidRequest }
        }
        self.requestID = requestID; self.method = method
        params = Parameters(sessionKey: sessionKey, command: command, operationID: operationID)
    }
}

public enum AgentAPIErrorCode: String, Sendable, Equatable {
    case unsupportedVersion = "unsupported_version", invalidRequest = "invalid_request", appUnavailable = "app_unavailable"
    case noActiveSession = "no_active_session", staleSession = "stale_session", unsupportedCapability = "unsupported_capability"
    case busy, operationNotFound = "operation_not_found", resultUnavailable = "result_unavailable"
    case requestTooLarge = "request_too_large", responseTooLarge = "response_too_large", internalError = "internal_error"
}
public struct AgentAPIError: Sendable, Equatable {
    public let code: AgentAPIErrorCode
    public let message: String
    public let recoveryAction: String?
    public init(code: AgentAPIErrorCode, message: String, recoveryAction: String? = nil) {
        self.code = code; self.message = message; self.recoveryAction = recoveryAction
    }
}
public struct AgentAPIResponse: Sendable, Equatable {
    private enum Body: Sendable, Equatable { case result([String: JSONValue]), error(AgentAPIError) }
    public let requestID: UUID?
    private let body: Body
    public var result: [String: JSONValue]? { if case .result(let value) = body { value } else { nil } }
    public var error: AgentAPIError? { if case .error(let value) = body { value } else { nil } }
    public init(requestID: UUID?, result: [String: JSONValue]) { self.requestID = requestID; body = .result(result) }
    public init(requestID: UUID?, error: AgentAPIError) { self.requestID = requestID; body = .error(error) }
}

/// CLI and IPC use the same strict v1 JSON contract. No decoder may default missing params
/// into an operation, and shell text is validated without changing its original bytes.
public enum AgentAPIWire {
    public static let maximumRequestBytes = 128 * 1024
    public static let maximumResponseBytes = 2 * 1024 * 1024
    public enum Failure: Error, Sendable, Equatable {
        case unsupportedVersion, invalidRequest, invalidResponse, requestTooLarge, responseTooLarge
    }

    public static func decodeRequest(_ data: Data) throws -> AgentAPIRequest {
        guard data.count <= maximumRequestBytes else { throw Failure.requestTooLarge }
        guard let root = try? JSONDecoder().decode([String: JSONValue].self, from: data),
              Set(root.keys) == ["apiVersion", "requestID", "method", "params"],
              case .number(let version) = root["apiVersion"], version.isFinite, version.rounded(.towardZero) == version else { throw Failure.invalidRequest }
        guard version == 1 else { throw Failure.unsupportedVersion }
        guard let id = uuid(root["requestID"]), let raw = root["method"]?.stringValue,
              let method = AgentAPIRequest.Method(rawValue: raw), case .object(let params) = root["params"] else { throw Failure.invalidRequest }
        let expected: Set<String>
        switch method {
        case .deviceCurrent: expected = []
        case .deviceInfoRead: expected = ["sessionKey"]
        case .androidShellRun: expected = ["sessionKey", "command"]
        case .operationGet, .operationCancel: expected = ["sessionKey", "operationID"]
        }
        guard Set(params.keys) == expected,
              params["sessionKey"] == nil || params["sessionKey"]?.stringValue != nil,
              params["command"] == nil || params["command"]?.stringValue != nil,
              params["operationID"] == nil || uuid(params["operationID"]) != nil else { throw Failure.invalidRequest }
        return try AgentAPIRequest(requestID: id, method: method, sessionKey: params["sessionKey"]?.stringValue,
            command: params["command"]?.stringValue, operationID: uuid(params["operationID"]))
    }

    public static func encodeRequest(_ request: AgentAPIRequest) throws -> Data {
        var params: [String: JSONValue] = [:]
        if let key = request.params.sessionKey { params["sessionKey"] = .string(key) }
        if let command = request.params.command { params["command"] = .string(command) }
        if let operation = request.params.operationID { params["operationID"] = .string(operation.uuidString) }
        let data = try encoder().encode(["apiVersion": JSONValue.number(1), "requestID": .string(request.requestID.uuidString),
            "method": .string(request.method.rawValue), "params": .object(params)])
        guard data.count <= maximumRequestBytes else { throw Failure.requestTooLarge }
        return data
    }

    public static func encodeResponse(_ response: AgentAPIResponse) throws -> Data {
        var root: [String: JSONValue] = ["apiVersion": .number(1), "requestID": response.requestID.map { .string($0.uuidString) } ?? .null]
        if let result = response.result { root["result"] = .object(result) }
        else if let error = response.error {
            guard validMessage(error.message), error.recoveryAction == nil || validMessage(error.recoveryAction!) else { throw Failure.invalidResponse }
            var payload: [String: JSONValue] = ["code": .string(error.code.rawValue), "message": .string(error.message)]
            if let recovery = error.recoveryAction { payload["recoveryAction"] = .string(recovery) }
            root["error"] = .object(payload)
        } else { throw Failure.invalidResponse }
        // Reserve the response size before JSONEncoder creates a second full byte buffer.
        var budget = maximumResponseBytes
        try consume(.object(root), budget: &budget, depth: 0)
        let data = try encoder().encode(root)
        guard data.count <= maximumResponseBytes else { throw Failure.responseTooLarge }
        return data
    }

    public static func decodeResponse(_ data: Data) throws -> AgentAPIResponse {
        guard data.count <= maximumResponseBytes else { throw Failure.responseTooLarge }
        guard let root = try? JSONDecoder().decode([String: JSONValue].self, from: data), root["apiVersion"] == .number(1),
              root["requestID"] == .null || uuid(root["requestID"]) != nil else { throw Failure.invalidResponse }
        let id = uuid(root["requestID"])
        if Set(root.keys) == ["apiVersion", "requestID", "result"], case .object(let result) = root["result"] {
            let response = AgentAPIResponse(requestID: id, result: result)
            _ = try encodeResponse(response)
            return response
        }
        guard Set(root.keys) == ["apiVersion", "requestID", "error"], case .object(let error) = root["error"],
              Set(error.keys) == ["code", "message"] || Set(error.keys) == ["code", "message", "recoveryAction"],
              let code = error["code"]?.stringValue.flatMap(AgentAPIErrorCode.init(rawValue:)),
              let message = error["message"]?.stringValue, validMessage(message),
              error["recoveryAction"] == nil || error["recoveryAction"]?.stringValue.map(validMessage) == true else { throw Failure.invalidResponse }
        return AgentAPIResponse(requestID: id, error: .init(code: code, message: message, recoveryAction: error["recoveryAction"]?.stringValue))
    }

    /// Best-effort correlation for a rejected frame; it never grants request validity.
    public static func requestID(in data: Data) -> UUID? {
        guard data.count <= maximumRequestBytes, let root = try? JSONDecoder().decode([String: JSONValue].self, from: data) else { return nil }
        return uuid(root["requestID"])
    }
    public static func rejection(_ error: any Error, requestID: UUID?) -> AgentAPIResponse {
        let code: AgentAPIErrorCode
        let message: String
        switch error as? Failure {
        case .unsupportedVersion: code = .unsupportedVersion; message = "This API version is not supported."
        case .requestTooLarge: code = .requestTooLarge; message = "The request exceeds 128 KiB."
        case .responseTooLarge: code = .responseTooLarge; message = "The result exceeds the response size limit."
        case .invalidRequest: code = .invalidRequest; message = "The request does not match the v1 schema."
        default: code = .internalError; message = "The response could not be produced."
        }
        return AgentAPIResponse(requestID: requestID, error: .init(code: code, message: message))
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]; return encoder
    }
    private static func uuid(_ value: JSONValue?) -> UUID? {
        guard let raw = value?.stringValue, raw.utf8.count == 36, let id = UUID(uuidString: raw), raw.lowercased() == id.uuidString.lowercased() else { return nil }
        return id
    }
    private static func validMessage(_ value: String) -> Bool { !value.isEmpty && value.utf8.count <= 1024 }
    private static func consume(_ value: JSONValue, budget: inout Int, depth: Int) throws {
        guard depth <= 32 else { throw Failure.invalidResponse }
        func charge(_ count: Int) throws {
            guard count <= budget else { throw Failure.responseTooLarge }
            budget -= count
        }
        switch value {
        case .null: try charge(4)
        case .bool: try charge(5)
        case .number(let number):
            guard number.isFinite else { throw Failure.invalidResponse }
            try charge(24)
        case .string(let string):
            try charge(2)
            for scalar in string.unicodeScalars {
                let count: Int
                switch scalar.value {
                case 0...31, 0x2028, 0x2029: count = 6
                case 34, 92: count = 2
                default: count = scalar.utf8.count
                }
                try charge(count)
            }
        case .array(let values):
            try charge(2 + values.count)
            for value in values { try consume(value, budget: &budget, depth: depth + 1) }
        case .object(let values):
            guard values.count <= maximumResponseBytes / 4 else { throw Failure.responseTooLarge }
            try charge(2 + values.count * 2)
            for (key, value) in values {
                try consume(.string(key), budget: &budget, depth: depth + 1)
                try consume(value, budget: &budget, depth: depth + 1)
            }
        }
    }
}
