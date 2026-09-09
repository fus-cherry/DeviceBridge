import Foundation
import Testing
import DeviceBridgeProtocol
@testable import DeviceBridgeCore

struct AgentAPITests {
    @Test func allFiveMethodsRoundTripWithTypedParametersAndOriginalCommand() throws {
        let command = "  printf 'hello\\n' | cat\nexit 7\n"
        let operation = UUID()
        let requests = [
            try AgentAPIRequest(requestID: UUID(), method: .deviceCurrent),
            try AgentAPIRequest(requestID: UUID(), method: .deviceInfoRead, sessionKey: "opaque-session"),
            try AgentAPIRequest(requestID: UUID(), method: .androidShellRun, sessionKey: "opaque-session", command: command),
            try AgentAPIRequest(requestID: UUID(), method: .operationGet, sessionKey: "opaque-session", operationID: operation),
            try AgentAPIRequest(requestID: UUID(), method: .operationCancel, sessionKey: "opaque-session", operationID: operation)
        ]
        for request in requests { #expect(try AgentAPIWire.decodeRequest(AgentAPIWire.encodeRequest(request)) == request) }
        #expect(requests[2].params.command == command)
        #expect(requests[3].params.operationID == operation)
    }
    @Test(arguments: ["unknownRoot", "unknownParam", "missingSession", "wrongMethod", "badUUID", "boolVersion", "fractionVersion", "wrongCommandType", "wrongOperationID"])
    func strictSchemaRejectsMalformedRequests(_ variant: String) throws {
        var root: [String: JSONValue] = ["apiVersion": .number(1), "requestID": .string(UUID().uuidString), "method": .string("android.shell.run"),
            "params": .object(["sessionKey": .string("session"), "command": .string("printf ok")])]
        switch variant {
        case "unknownRoot": root["extra"] = .null
        case "unknownParam": root["params"] = .object(["sessionKey": .string("session"), "command": .string("printf ok"), "extra": .null])
        case "missingSession": root["params"] = .object(["command": .string("printf ok")])
        case "wrongMethod": root["method"] = .string("device.select")
        case "badUUID": root["requestID"] = .string("not-a-uuid")
        case "boolVersion": root["apiVersion"] = .bool(true)
        case "fractionVersion": root["apiVersion"] = .number(1.5)
        case "wrongCommandType": root["params"] = .object(["sessionKey": .string("session"), "command": .number(1)])
        case "wrongOperationID": root["method"] = .string("operation.get"); root["params"] = .object(["sessionKey": .string("session"), "operationID": .string("bad")])
        default: break
        }
        #expect(throws: (any Error).self) { try AgentAPIWire.decodeRequest(JSONEncoder().encode(root)) }
    }
    @Test func versionAndInputBoundsHaveStableErrors() throws {
        let id = UUID()
        let version = Data("{\"apiVersion\":2,\"requestID\":\"\(id.uuidString)\",\"method\":\"device.current\",\"params\":{}}".utf8)
        #expect(throws: AgentAPIWire.Failure.unsupportedVersion) { try AgentAPIWire.decodeRequest(version) }
        #expect(throws: AgentAPIWire.Failure.requestTooLarge) { try AgentAPIWire.decodeRequest(Data(repeating: 32, count: 128 * 1024 + 1)) }
        #expect(throws: (any Error).self) { try AgentAPIRequest(requestID: id, method: .androidShellRun, sessionKey: "key", command: String(repeating: "界", count: 6000)) }
        #expect(throws: (any Error).self) { try AgentAPIRequest(requestID: id, method: .deviceInfoRead, sessionKey: String(repeating: "a", count: 513)) }
        #expect(throws: (any Error).self) { try AgentAPIRequest(requestID: id, method: .deviceCurrent, sessionKey: "unexpected") }
        #expect(throws: (any Error).self) { try AgentAPIRequest(requestID: id, method: .androidShellRun, sessionKey: "key", command: " \n") }
        #expect(throws: (any Error).self) { try AgentAPIRequest(requestID: id, method: .androidShellRun, sessionKey: "key", command: "echo\0secret") }
    }
    @Test func responseRoundTripsBase64WithoutLosingInvalidUTF8OrExitCode() throws {
        let bytes = Data([0xff, 0x00, 0x61]), id = UUID()
        let response = AgentAPIResponse(requestID: id, result: ["stdout": .object(["encoding": .string("base64"), "data": .string(bytes.base64EncodedString())]), "exitCode": .number(255)])
        let decoded = try AgentAPIWire.decodeResponse(AgentAPIWire.encodeResponse(response))
        #expect(decoded == response)
        #expect(decoded.result?["exitCode"] == .number(255))
        #expect(decoded.error == nil)
    }
    @Test func errorIsExclusiveAndUnknownOrAmbiguousResponseKeysAreRejected() throws {
        let id = UUID()
        let response = AgentAPIResponse(requestID: id, error: AgentAPIError(code: .busy, message: "Busy."))
        #expect(try AgentAPIWire.decodeResponse(AgentAPIWire.encodeResponse(response)) == response)
        #expect(response.result == nil)
        let root: [String: JSONValue] = ["apiVersion": .number(1), "requestID": .string(id.uuidString), "result": .object([:]),
            "error": .object(["code": .string("busy"), "message": .string("Busy.")])]
        #expect(throws: AgentAPIWire.Failure.invalidResponse) { try AgentAPIWire.decodeResponse(JSONEncoder().encode(root)) }
    }
    @Test func responseBudgetAdmitsBoundedShellBase64AndRejectsOversizedOrNonFiniteSnapshots() throws {
        let bytes = Data(repeating: 0xff, count: 1_048_576)
        let valid = AgentAPIResponse(requestID: UUID(), result: ["stdout": .object(["encoding": .string("base64"), "data": .string(bytes.base64EncodedString())])])
        #expect(try AgentAPIWire.encodeResponse(valid).count <= 2 * 1024 * 1024)
        #expect(throws: AgentAPIWire.Failure.responseTooLarge) { try AgentAPIWire.encodeResponse(AgentAPIResponse(requestID: UUID(), result: ["text": .string(String(repeating: "x", count: 2 * 1024 * 1024))])) }
        #expect(throws: AgentAPIWire.Failure.invalidResponse) { try AgentAPIWire.encodeResponse(AgentAPIResponse(requestID: UUID(), result: ["number": .number(.infinity)])) }
    }
}
