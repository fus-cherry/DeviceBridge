import DeviceBridgeProtocol
import Foundation

public enum FlutterVMServiceError: Error, Sendable, Equatable {
    case invalidURI
    case disconnected
    case malformedResponse
    case rpcFailure
}

public enum FlutterVMServiceDiscovery {
    public static func candidateURI(in text: String) -> URL? {
        guard let expression = try? NSRegularExpression(
            pattern: #"(?:http|https|ws|wss)://(?:127\.0\.0\.1|localhost):[0-9]+/[^\s\"']*"#,
            options: [.caseInsensitive]
        ) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = expression.firstMatch(in: text, range: range),
              let matchRange = Range(match.range, in: text) else { return nil }
        let raw = String(text[matchRange]).trimmingCharacters(in: CharacterSet(charactersIn: ").,;"))
        return URL(string: raw)
    }
}

public struct FlutterVMDiscoveryOutcome: Sendable, Equatable {
    public let uri: URL?
    public let failure: OperationFailure?

    public init(uri: URL? = nil, failure: OperationFailure? = nil) {
        self.uri = uri
        self.failure = failure
    }
}

public actor AndroidFlutterVMDiscovery {
    private let adbURL: URL
    private let runner: any HostCommandRunning
    private var activeTransportID: String?
    private var activeHostPort: Int?

    public init(adbURL: URL, runner: any HostCommandRunning) {
        self.adbURL = adbURL
        self.runner = runner
    }

    public func discover(transportID: String) async -> FlutterVMDiscoveryOutcome {
        if activeTransportID != nil { await stop() }
        do {
            let logs = try await command([
                "-t", transportID, "shell", "logcat", "-d", "-v", "raw", "-t", "500",
            ])
            guard logs.exitCode == 0,
                  let deviceURI = FlutterVMServiceDiscovery.candidateURI(
                    in: logs.standardOutputString
                  ),
                  let devicePort = deviceURI.port else {
                return unavailable()
            }
            let forward = try await command([
                "-t", transportID, "forward", "tcp:0", "tcp:\(devicePort)",
            ])
            guard forward.exitCode == 0,
                  let hostPort = Int(
                    forward.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines)
                  ),
                  (1...65_535).contains(hostPort),
                  var components = URLComponents(
                    url: deviceURI,
                    resolvingAgainstBaseURL: false
                  ) else {
                return unavailable()
            }
            components.host = "127.0.0.1"
            components.port = hostPort
            guard let hostURI = components.url else { return unavailable() }
            activeTransportID = transportID
            activeHostPort = hostPort
            return FlutterVMDiscoveryOutcome(uri: hostURI)
        } catch is CancellationError {
            return FlutterVMDiscoveryOutcome(failure: OperationFailure(
                code: .cancelled,
                safeMessage: "Flutter VM discovery cancelled."
            ))
        } catch {
            return unavailable()
        }
    }

    public func stop() async {
        guard let transportID = activeTransportID,
              let hostPort = activeHostPort else { return }
        activeTransportID = nil
        activeHostPort = nil
        _ = try? await command([
            "-t", transportID, "forward", "--remove", "tcp:\(hostPort)",
        ])
    }

    private func command(_ arguments: [String]) async throws -> HostCommandResult {
        try await runner.run(HostCommandRequest(
            executableURL: adbURL,
            arguments: arguments,
            timeout: .seconds(10),
            maximumOutputBytes: 1 * 1_024 * 1_024
        ))
    }

    private func unavailable() -> FlutterVMDiscoveryOutcome {
        FlutterVMDiscoveryOutcome(failure: OperationFailure(
            code: .unsupported,
            safeMessage: "No current Flutter VM Service was discovered.",
            recoveryAction: "Run a Flutter app in debug/profile mode or paste its VM Service URI."
        ))
    }
}

public protocol VMServiceRPCTransport: Sendable {
    func request(
        method: String,
        parameters: [String: JSONValue]
    ) async throws -> [String: JSONValue]
    func close() async
}

public enum VMServiceRedirectPolicy: Sendable {
    /// Existing URI-only clients may use the VM's DDS middleware handoff.
    case follow
    /// A device-owned endpoint must not silently leave its verified route.
    case reject
}

public actor URLSessionVMServiceTransport: VMServiceRPCTransport {
    private let webSocketURL: URL
    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private var nextID = 1
    private var isClosed = false

    public init(webSocketURL: URL, redirects: VMServiceRedirectPolicy = .follow) {
        self.webSocketURL = webSocketURL
        // Owned-route callers reject redirects and must separately verify any DDS handoff.
        // Preserve existing Android/manual URI behavior until that binding path is qualified.
        self.session = URLSession(configuration: .ephemeral,
            delegate: VMServiceRedirectDelegate(policy: redirects), delegateQueue: nil)
    }

    public func request(
        method: String,
        parameters: [String: JSONValue]
    ) async throws -> [String: JSONValue] {
        guard !isClosed else { throw FlutterVMServiceError.disconnected }
        let task = activeTask()
        let id = nextID
        nextID += 1
        let payload = RPCRequest(id: id, method: method, params: parameters)
        let data = try JSONEncoder().encode(payload)
        guard let string = String(data: data, encoding: .utf8) else {
            throw FlutterVMServiceError.malformedResponse
        }
        try await task.send(.string(string))
        while true {
            let message = try await task.receive()
            let responseData: Data
            switch message {
            case let .string(text): responseData = Data(text.utf8)
            case let .data(data): responseData = data
            @unknown default: throw FlutterVMServiceError.malformedResponse
            }
            let response = try JSONDecoder().decode(RPCResponse.self, from: responseData)
            guard response.id == id else { continue }
            guard response.error == nil, let result = response.result else {
                throw FlutterVMServiceError.rpcFailure
            }
            return result
        }
    }

    public func close() async {
        isClosed = true
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session.invalidateAndCancel()
    }

    deinit { session.invalidateAndCancel() }

    private func activeTask() -> URLSessionWebSocketTask {
        if let task { return task }
        let task = session.webSocketTask(with: webSocketURL)
        task.resume()
        self.task = task
        return task
    }

    private struct RPCRequest: Encodable {
        let jsonrpc = "2.0"
        let id: Int
        let method: String
        let params: [String: JSONValue]
    }

    private struct RPCResponse: Decodable {
        let id: Int?
        let result: [String: JSONValue]?
        let error: JSONValue?
    }
}

private final class VMServiceRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    private let policy: VMServiceRedirectPolicy
    init(policy: VMServiceRedirectPolicy) { self.policy = policy }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(policy == .follow ? request : nil)
    }
}

public actor FlutterVMService: MemorySampling, CustomStringConvertible {
    private let transport: any VMServiceRPCTransport
    private var isDisconnected = false

    public nonisolated var description: String { "FlutterVMService(<redacted:vm-uri>)" }

    public init(
        uri: URL,
        transport: (any VMServiceRPCTransport)? = nil
    ) throws {
        guard let webSocketURL = Self.webSocketURL(from: uri) else {
            throw FlutterVMServiceError.invalidURI
        }
        self.transport = transport ?? URLSessionVMServiceTransport(webSocketURL: webSocketURL)
    }

    public func sample(
        target: TargetApplication,
        transportID: String
    ) async -> MemoryProviderOutcome {
        guard !isDisconnected else { return disconnectedOutcome() }
        // A loopback URI and matching PID do not prove a selected iPhone route.
        // T113 must supply independently verified route/process ownership before
        // iOS can enter this sampler; until then reject before any RPC.
        guard target.deviceIdentity.platform != .iOS else {
            return .failure(OperationFailure(
                code: .unsupported,
                safeMessage: "This VM connection has not been verified for the selected iPhone.",
                recoveryAction: "iOS memory requires a verified device and app connection; a manual URI is not sufficient."
            ))
        }
        do {
            let vm = try await transport.request(method: "getVM", parameters: [:])
            guard let pid = Self.integer(vm["pid"]),
                  let isolateID = Self.firstIsolateID(vm["isolates"]) else {
                throw FlutterVMServiceError.malformedResponse
            }
            let startIdentity = Self.integer(vm["startTime"]).map(String.init)
            if (target.processID != nil && target.processID != pid)
                || (target.processStartIdentity != nil
                    && startIdentity != nil
                    && target.processStartIdentity != startIdentity) {
                return .restarted(TargetApplication(
                    deviceIdentity: target.deviceIdentity,
                    applicationID: target.applicationID,
                    displayName: target.displayName,
                    processID: pid,
                    processStartIdentity: startIdentity,
                    debuggable: true,
                    state: .restarted
                ))
            }

            let usage = try await transport.request(
                method: "getMemoryUsage",
                parameters: ["isolateId": .string(isolateID)]
            )
            guard let heapUsage = Self.integer(usage["heapUsage"]) else {
                throw FlutterVMServiceError.malformedResponse
            }
            return .sample(MemorySample(
                deviceIdentity: target.deviceIdentity,
                applicationID: target.applicationID,
                processID: pid,
                processStartIdentity: startIdentity,
                capturedAt: Date(),
                source: .flutterVMService,
                rssBytes: Self.integer(vm["_currentRSS"] ?? vm["currentRSS"]).map(Int64.init),
                heapUsedBytes: Int64(heapUsage),
                externalBytes: Self.integer(usage["externalUsage"]).map(Int64.init)
            ))
        } catch is CancellationError {
            return .failure(OperationFailure(code: .cancelled, safeMessage: "VM memory sampling cancelled."))
        } catch {
            return .failure(OperationFailure(
                code: .failure,
                safeMessage: "The Flutter VM Service did not return usable memory data.",
                recoveryAction: "Confirm the debug/profile VM Service URI and retry."
            ))
        }
    }

    public func collectGarbage(isolateID: String) async -> Bool {
        guard !isDisconnected else { return false }
        do {
            _ = try await transport.request(
                method: "getAllocationProfile",
                parameters: [
                    "isolateId": .string(isolateID),
                    "gc": .bool(true),
                ]
            )
            return true
        } catch {
            return false
        }
    }

    public func disconnect() async {
        guard !isDisconnected else { return }
        isDisconnected = true
        await transport.close()
    }

    private static func webSocketURL(from uri: URL) -> URL? {
        guard let host = uri.host?.lowercased(),
              host == "127.0.0.1" || host == "localhost",
              uri.port != nil,
              var components = URLComponents(url: uri, resolvingAgainstBaseURL: false) else {
            return nil
        }
        switch components.scheme?.lowercased() {
        case "http": components.scheme = "ws"
        case "https": components.scheme = "wss"
        case "ws", "wss": break
        default: return nil
        }
        if !components.path.hasSuffix("/ws") {
            if !components.path.hasSuffix("/") { components.path += "/" }
            components.path += "ws"
        }
        return components.url
    }

    private static func firstIsolateID(_ value: JSONValue?) -> String? {
        guard case let .array(isolates)? = value,
              case let .object(first)? = isolates.first else { return nil }
        return first["id"]?.stringValue
    }

    private static func integer(_ value: JSONValue?) -> Int? {
        guard case let .number(number)? = value,
              number.isFinite,
              number.rounded() == number,
              number >= Double(Int.min), number <= Double(Int.max) else { return nil }
        return Int(number)
    }

    private func disconnectedOutcome() -> MemoryProviderOutcome {
        .failure(OperationFailure(
            code: .disconnected,
            safeMessage: "The Flutter VM Service session is disconnected."
        ))
    }
}
