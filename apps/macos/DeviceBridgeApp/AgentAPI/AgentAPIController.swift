import CryptoKit
import DeviceBridgeCore
import DeviceBridgeProtocol
import Foundation

@MainActor
protocol AgentAPIWorkspace: AnyObject {
    var agentDevice: DeviceRecord? { get }
    var agentActionsAllowed: Bool { get }
    var deviceInformation: DeviceInformationViewModel { get }
    var androidShell: AndroidShellViewModel { get }
}

/// Owns session keys and bounded request associations. Reports and output remain in the module owners.
@MainActor
final class AgentAPIController {
    private struct Binding {
        let session: ConnectionSession
        let key: String
    }
    private struct Association {
        let method: AgentAPIRequest.Method
        let digest: Data
        let operationID: UUID
    }
    private let instanceID = UUID()
    private weak var workspace: (any AgentAPIWorkspace)?
    private var binding: Binding?
    private var associations: [UUID: Association] = [:]

    init(workspace: any AgentAPIWorkspace) { self.workspace = workspace }

    func activate(session: ConnectionSession) {
        guard binding?.session != session else { return }
        invalidate()
        binding = Binding(session: session, key: "\(instanceID.uuidString).\(UUID().uuidString)")
    }
    func invalidate() { binding = nil; associations.removeAll(keepingCapacity: false) }
    func validateSession(_ session: ConnectionSession?) {
        if binding?.session != session { invalidate() }
    }

    func handle(_ request: AgentAPIRequest) async -> AgentAPIResponse {
        let capturedKey = binding?.key
        let decision = route(request)
        // Only immutable snapshots cross this boundary. Base64 and full report conversion stay off MainActor.
        let response = await Task.detached { decision.response(requestID: request.requestID) }.value
        guard binding?.key == capturedKey else {
            return AgentAPIResponse(requestID: request.requestID,
                error: AgentAPIError(code: .staleSession, message: "The device session changed while the response was being prepared."))
        }
        return response
    }

    private func route(_ request: AgentAPIRequest) -> Decision {
        guard let workspace else { return error(.appUnavailable, "The application workspace is unavailable.") }
        if request.method == .deviceCurrent {
            guard let binding, let device = workspace.agentDevice, device.identity == binding.session.deviceIdentity else {
                return .result(["status": .string("no_active_session")])
            }
            return .result([
                "status": .string("active"), "sessionKey": .string(binding.key),
                "device": .object(Self.deviceJSON(device: device, session: binding.session)),
                "capabilities": .object([
                    "deviceInformation": .object(["available": .bool(workspace.deviceInformation.canRead && workspace.agentActionsAllowed),
                        "reason": .string(workspace.deviceInformation.statusText)]),
                    "androidShell": .object(["available": .bool(device.identity.platform == .android
                        && workspace.androidShell.session == binding.session && !workspace.androidShell.isBusy && workspace.agentActionsAllowed),
                        "reason": .string(device.identity.platform == .android ? workspace.androidShell.statusText : "Android only")])])])
        }
        guard let binding, request.params.sessionKey == binding.key else {
            return error(.staleSession, "The device session key is no longer active.")
        }
        guard workspace.agentDevice?.identity == binding.session.deviceIdentity else {
            invalidate()
            return error(.staleSession, "The device session changed.")
        }
        // A previously accepted request ID never authorizes another operation or another method.
        if let prior = associations[request.requestID] {
            guard prior.method == request.method, prior.digest == Self.digest(request) else {
                return error(.invalidRequest, "This request ID was already used with different parameters.")
            }
            return accepted(prior.operationID, key: binding.key)
        }
        switch request.method {
        case .deviceInfoRead, .androidShellRun:
            guard associations.count < 128 else {
                return error(.busy, "This session has used its 128 operation request IDs. Select the device again before starting more operations.")
            }
            guard workspace.agentActionsAllowed else { return error(.busy, "The current device connection is not ready for an operation.") }
            let id = UUID()
            if request.method == .deviceInfoRead {
                guard workspace.deviceInformation.session == binding.session else {
                    return error(.unsupportedCapability, "Device information is unavailable on this connection.")
                }
                guard !workspace.deviceInformation.isBusy else { return error(.busy, "Device information is already being read.") }
                guard workspace.deviceInformation.read(origin: .agent, operationID: id) != nil else {
                    return error(.unsupportedCapability, "Device information is unavailable on this connection.")
                }
            } else {
                guard binding.session.deviceIdentity.platform == .android,
                      workspace.androidShell.session == binding.session else {
                    return error(.unsupportedCapability, "Android Shell is unavailable on this connection.")
                }
                guard !workspace.androidShell.isBusy else { return error(.busy, "Android Shell is running or cleaning up.") }
                guard let command = request.params.command,
                      workspace.androidShell.run(origin: .agent, operationID: id, command: command) != nil else {
                    return error(.invalidRequest, "The Shell command could not be accepted.")
                }
            }
            associations[request.requestID] = Association(method: request.method, digest: Self.digest(request), operationID: id)
            return accepted(id, key: binding.key)
        case .operationGet, .operationCancel:
            guard let id = request.params.operationID,
                  let association = associations.values.first(where: { $0.operationID == id }) else {
                return error(.operationNotFound, "No Agent operation with this ID belongs to the current session.")
            }
            if association.method == .deviceInfoRead {
                guard let operation = workspace.deviceInformation.operation, operation.id == id, operation.origin == .agent else {
                    return error(.resultUnavailable, "This information result was replaced by a later read.")
                }
                if request.method == .operationCancel, !operation.isTerminal { workspace.deviceInformation.cancel() }
                guard let current = workspace.deviceInformation.operation else { return error(.resultUnavailable, "The result is unavailable.") }
                let report = workspace.deviceInformation.report.flatMap { $0.id == current.reportID ? $0 : nil }
                return .information(current, report, binding.key)
            }
            if let operation = workspace.androidShell.currentOperation, operation.id == id, operation.origin == .agent {
                if request.method == .operationCancel { workspace.androidShell.cancel() }
                guard let current = workspace.androidShell.currentOperation else { return error(.resultUnavailable, "The result is unavailable.") }
                return .shellPending(current, binding.key)
            }
            guard let result = workspace.androidShell.history.entries.first(where: { $0.id == id && $0.origin == .agent }) else {
                return error(.resultUnavailable, "This Shell result was cleared or removed from session history.")
            }
            return .shellResult(result, binding.key)
        case .deviceCurrent:
            return error(.invalidRequest, "Invalid method dispatch.")
        }
    }

    private func accepted(_ id: UUID, key: String) -> Decision {
        .result(["state": .string("accepted"), "operationID": .string(id.uuidString),
            "origin": .string("agent"), "sessionKey": .string(key)])
    }
    private func error(_ code: AgentAPIErrorCode, _ message: String) -> Decision {
        .error(AgentAPIError(code: code, message: message))
    }
    private static func digest(_ request: AgentAPIRequest) -> Data {
        let value = request.method.rawValue + "\0" + (request.params.command ?? "")
        return Data(SHA256.hash(data: Data(value.utf8)))
    }
    private static func deviceJSON(device: DeviceRecord, session: ConnectionSession) -> [String: JSONValue] {
        ["name": .string(device.name), "identifier": .string(device.identity.rawValue),
         "platform": .string(device.identity.platform.rawValue), "transportID": .string(session.transportID),
         "generation": .number(Double(session.generation))]
    }

    private enum Decision: Sendable {
        case error(AgentAPIError)
        case result([String: JSONValue])
        case information(DeviceInformationOperation, DeviceInformationReport?, String)
        case shellPending(AndroidShellOperation, String)
        case shellResult(AndroidShellExecution, String)

        func response(requestID: UUID) -> AgentAPIResponse {
            switch self {
            case let .error(error): return AgentAPIResponse(requestID: requestID, error: error)
            case let .result(value): return AgentAPIResponse(requestID: requestID, result: value)
            case let .information(operation, report, key):
                var value = Self.operationJSON(id: operation.id, session: operation.session, key: key,
                    startedAt: operation.startedAt, state: operation.state.rawValue)
                if let finished = operation.finishedAt { value["finishedAt"] = .string(finished.ISO8601Format()) }
                if let failure = operation.failure { value["failure"] = .object(Self.failureJSON(failure)) }
                if let report {
                    do {
                        let encoder = JSONEncoder()
                        encoder.dateEncodingStrategy = .iso8601
                        let data = try encoder.encode(report)
                        guard data.count <= 64 * 1_024 else {
                            return AgentAPIResponse(requestID: requestID,
                                error: AgentAPIError(code: .responseTooLarge, message: "The information report exceeds the response limit."))
                        }
                        value["report"] = try JSONDecoder().decode(JSONValue.self, from: data)
                    } catch {
                        return AgentAPIResponse(requestID: requestID,
                            error: AgentAPIError(code: .internalError, message: "The information report could not be encoded."))
                    }
                }
                return AgentAPIResponse(requestID: requestID, result: value)
            case let .shellPending(operation, key):
                return AgentAPIResponse(requestID: requestID, result: Self.operationJSON(id: operation.id,
                    session: operation.session, key: key, startedAt: operation.startedAt, state: operation.phase.rawValue))
            case let .shellResult(result, key):
                var value = Self.operationJSON(id: result.id, session: result.session, key: key,
                    startedAt: result.startedAt, state: Self.state(result.completion))
                value["finishedAt"] = .string(result.finishedAt.ISO8601Format())
                value["command"] = .string(result.command)
                value["stdout"] = .object(["encoding": .string("base64"), "data": .string(result.stdout.base64EncodedString())])
                value["stderr"] = .object(["encoding": .string("base64"), "data": .string(result.stderr.base64EncodedString())])
                value["outputTruncated"] = .bool(result.outputTruncated)
                if let exit = result.exitCode { value["exitCode"] = .number(Double(exit)) }
                if case let .notStarted(failure) = result.completion { value["failure"] = .object(Self.failureJSON(failure)) }
                return AgentAPIResponse(requestID: requestID, result: value)
            }
        }
        private static func operationJSON(id: UUID, session: ConnectionSession, key: String,
                                          startedAt: Date, state: String) -> [String: JSONValue] {
            ["operationID": .string(id.uuidString), "origin": .string("agent"), "sessionKey": .string(key),
             "deviceIdentifier": .string(session.deviceIdentity.rawValue), "transportID": .string(session.transportID),
             "startedAt": .string(startedAt.ISO8601Format()), "state": .string(state)]
        }
        private static func failureJSON(_ failure: OperationFailure) -> [String: JSONValue] {
            var value: [String: JSONValue] = ["code": .string(failure.code.rawValue), "message": .string(failure.safeMessage)]
            if let recovery = failure.recoveryAction { value["recoveryAction"] = .string(recovery) }
            return value
        }
        private static func state(_ completion: AndroidShellCompletion) -> String {
            switch completion {
            case .remoteExit: "remoteExit"
            case .cancelled: "cancelled"
            case .timedOut: "timedOut"
            case .outputLimitExceeded: "outputLimitExceeded"
            case .connectionLost: "connectionLost"
            case .resultUnknown: "resultUnknown"
            case .protocolFailure: "protocolFailure"
            case .notStarted: "notStarted"
            }
        }
    }
}
