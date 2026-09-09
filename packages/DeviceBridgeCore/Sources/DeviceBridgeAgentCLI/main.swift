import Darwin
import Foundation
import DeviceBridgeCore

func readInput() throws -> Data {
    var data = Data()
    while data.count <= AgentAPIWire.maximumRequestBytes {
        let chunk = try FileHandle.standardInput.read(upToCount: min(16 * 1024, AgentAPIWire.maximumRequestBytes + 1 - data.count)) ?? Data()
        if chunk.isEmpty { break }
        data.append(chunk)
    }
    guard data.count <= AgentAPIWire.maximumRequestBytes else { throw AgentAPIWire.Failure.requestTooLarge }
    return data
}

var requestID: UUID?
let response: AgentAPIResponse
var status: Int32 = 0
do {
    let data = try readInput()
    requestID = AgentAPIWire.requestID(in: data)
    let request = try AgentAPIWire.decodeRequest(data)
    response = try await AgentIPCClient().send(request)
    if response.error != nil { status = 1 }
} catch let error as AgentAPIWire.Failure {
    response = AgentAPIWire.rejection(error, requestID: requestID)
    status = 2
} catch {
    response = AgentAPIResponse(requestID: requestID, error: .init(code: .appUnavailable,
        message: "The running DeviceBridge app could not be reached."))
    status = 1
}
do {
    let encoded = try AgentAPIWire.encodeResponse(response)
    try FileHandle.standardOutput.write(contentsOf: encoded + Data([10]))
} catch {
    try? FileHandle.standardError.write(contentsOf: Data("The JSON response could not be written.\n".utf8))
    status = 1
}
exit(status)
