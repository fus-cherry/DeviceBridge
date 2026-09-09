import DeviceBridgeProtocol
import Foundation

/// Owns one USB connection, not a reusable URI. This transport alone is not a verified VM binding.
public actor IOSVMHTTPTransport: VMServiceRPCTransport {
    public enum Failure: Error, Equatable, Sendable { case invalidInput, invalidResponse, closed, timedOut, operationInProgress }
    private let connection: IOSUSBMuxConnection
    private let authenticationCode: String
    private let timeout: TimeInterval
    private var closed = false
    private var requestInProgress = false

    public static func connect(hardwareUDID: String, port: UInt16, authenticationCode: String,
                               timeout: TimeInterval = 5) async throws -> IOSVMHTTPTransport {
        try await connect(hardwareUDID: hardwareUDID, port: port, authenticationCode: authenticationCode,
                          timeout: timeout, socketPath: "/var/run/usbmuxd")
    }

    static func connect(hardwareUDID: String, port: UInt16, authenticationCode: String,
                        timeout: TimeInterval, socketPath: String) async throws -> IOSVMHTTPTransport {
        guard validAuthentication(authenticationCode), port >= 1024,
              timeout.isFinite, timeout > 0, timeout <= 30 else { throw Failure.invalidInput }
        let connection = try await IOSUSBMuxConnection.connect(hardwareUDID: hardwareUDID, port: port,
                                                               socketPath: socketPath, timeout: timeout)
        do {
            try Task.checkCancellation()
            return IOSVMHTTPTransport(connection: connection, authenticationCode: authenticationCode, timeout: timeout)
        } catch { await connection.close(); throw error }
    }

    // Ownership is transferred by discovery; do not retain a second reader/writer of this stream.
    private init(connection: IOSUSBMuxConnection, authenticationCode: String, timeout: TimeInterval) {
        self.connection = connection
        self.authenticationCode = authenticationCode
        self.timeout = timeout
    }

    public func request(method: String, parameters: [String: JSONValue]) async throws -> [String: JSONValue] {
        guard !closed else { throw Failure.closed }
        guard !requestInProgress else { throw Failure.operationInProgress }
        let path = try requestPath(method: method, parameters: parameters)
        guard timeout.isFinite, timeout > 0, timeout <= 30 else { throw Failure.invalidInput }
        requestInProgress = true
        defer { requestInProgress = false }
        let deadline = ContinuousClock.now + .seconds(timeout)
        do {
            try checkActive(deadline)
            let request = Data("GET /\(authenticationCode)/\(path) HTTP/1.1\r\nHost: 127.0.0.1\r\nAccept: application/json\r\nConnection: keep-alive\r\n\r\n".utf8)
            try await connection.write(request, timeout: remaining(deadline))
            try checkActive(deadline)
            var reader = IOSVMHTTPResponse()
            while true {
                let bytes = try await connection.read(maxBytes: 65_536, timeout: remaining(deadline))
                try checkActive(deadline)
                if let body = try reader.append(bytes) {
                    let result = try Self.result(body, method: method)
                    try checkActive(deadline)
                    return result
                }
            }
        } catch {
            // Invalidate before awaiting descriptor teardown; no replacement RPC can enter.
            closed = true
            await connection.close()
            if Task.isCancelled { throw CancellationError() }
            if let failure = error as? Failure { throw failure }
            if error as? IOSUSBMuxConnection.Failure == .timedOut { throw Failure.timedOut }
            if error is IOSUSBMuxConnection.Failure { throw Failure.closed }
            // Parser/JSON errors and server payloads never enter diagnostics.
            throw Failure.invalidResponse
        }
    }

    public func close() async {
        closed = true
        await connection.close()
    }

    private func checkActive(_ deadline: ContinuousClock.Instant) throws {
        try Task.checkCancellation()
        guard !closed else { throw Failure.closed }
        guard ContinuousClock.now < deadline else { throw Failure.timedOut }
    }

    private func remaining(_ deadline: ContinuousClock.Instant) throws -> TimeInterval {
        try checkActive(deadline)
        let duration = ContinuousClock.now.duration(to: deadline).components
        let seconds = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
        guard seconds > 0 else { throw Failure.timedOut }
        return min(seconds, 30)
    }

    private func requestPath(method: String, parameters: [String: JSONValue]) throws -> String {
        switch method {
        case "getVM", "getVersion":
            guard parameters.isEmpty else { throw Failure.invalidInput }
            return method
        case "getMemoryUsage":
            guard parameters.count == 1, let isolate = parameters["isolateId"]?.stringValue,
                  isolate.hasPrefix("isolates/"), isolate.utf8.count > 9, isolate.utf8.count <= 256,
                  isolate.utf8.allSatisfy({ Self.tokenByte($0) || $0 == 47 }),
                  let encoded = isolate.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { throw Failure.invalidInput }
            return "getMemoryUsage?isolateId=\(encoded)"
        default: throw Failure.invalidInput
        }
    }

    private static func tokenByte(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) || byte == 45 || byte == 95
    }

    private static func validAuthentication(_ code: String) -> Bool {
        !code.isEmpty && code.utf8.count <= 256 && code.utf8.allSatisfy { tokenByte($0) || $0 == 61 }
    }

    private static func result(_ body: Data, method: String) throws -> [String: JSONValue] {
        let envelope = try JSONDecoder().decode([String: JSONValue].self, from: body)
        guard envelope["jsonrpc"] == .string("2.0"), envelope["id"] == .string(""),
              envelope["error"] == nil, envelope["method"] == nil,
              case let .object(result)? = envelope["result"] else { throw Failure.invalidResponse }
        let expectedType = method == "getVM" ? "VM" : method == "getVersion" ? "Version" : "MemoryUsage"
        guard result["type"] == .string(expectedType) else { throw Failure.invalidResponse }
        return result
    }
}
