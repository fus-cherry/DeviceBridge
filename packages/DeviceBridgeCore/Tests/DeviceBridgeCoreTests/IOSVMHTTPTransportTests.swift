import Darwin
import DeviceBridgeProtocol
import Foundation
import Testing
@testable import DeviceBridgeCore

@Suite("Owned persistent iOS USB VM HTTP transport")
struct IOSVMHTTPTransportTests {
    @Test("qualified native owner cannot reopen after peer EOF even with unchanged metadata")
    func qualifiedEOF() async throws {
        let server = try vmHTTPServer { fd in
            _ = try httpRequest(fd)
            try muxWrite(fd, chunkedRPC("{\"jsonrpc\":\"2.0\",\"id\":\"\",\"result\":{\"type\":\"Version\",\"major\":4,\"minor\":16}}"))
            for start in [1000, 1002] {
                _ = try httpRequest(fd)
                try muxWrite(fd, chunkedRPC("{\"jsonrpc\":\"2.0\",\"id\":\"\",\"result\":{\"type\":\"VM\",\"pid\":123,\"startTime\":\(start),\"version\":\"3.7.2 (stable)\",\"isolates\":[{\"type\":\"@Isolate\",\"id\":\"isolates/7\"}]}}"))
            }
            _ = try httpRequest(fd)
            _ = shutdown(fd, SHUT_RDWR)
            // vmHTTPServer keeps its listener open and rejects any replacement Connect.
        }
        let channel = try await IOSVMMetadataChannel.connect(hardwareUDID: "PUBLIC-TARGET", port: 12345,
            authenticationCode: "public-token=", expectedProcessID: 123, selectedIsolateID: nil,
            timeout: 2, socketPath: server.path)
        #expect(try await channel.readMetadata().processID == 123)
        await #expect(throws: (any Error).self) { try await channel.readMetadata() }
        await #expect(throws: IOSVMMetadataChannel.Failure.closed) { try await channel.readMetadata() }
        try await server.finish()
    }

    @Test("native metadata owner qualifies and renews one USB stream without memory RPC")
    func nativeMetadataOwner() async throws {
        let server = try vmHTTPServer { fd in
            #expect(try httpRequest(fd).hasPrefix("GET /public-token=/getVersion HTTP/1.1\r\n"))
            try muxWrite(fd, chunkedRPC("{\"jsonrpc\":\"2.0\",\"id\":\"\",\"result\":{\"type\":\"Version\",\"major\":4,\"minor\":16}}"))
            for start in [1000, 1001, 1000] {
                #expect(try httpRequest(fd).hasPrefix("GET /public-token=/getVM HTTP/1.1\r\n"))
                try muxWrite(fd, chunkedRPC("{\"jsonrpc\":\"2.0\",\"id\":\"\",\"result\":{\"type\":\"VM\",\"pid\":123,\"startTime\":\(start),\"version\":\"3.7.2 (stable)\",\"isolates\":[{\"type\":\"@Isolate\",\"id\":\"isolates/7\",\"name\":\"main\"}]}}"))
            }
            #expect(try muxReadToEOF(fd))
        }
        let channel = try await IOSVMMetadataChannel.connect(hardwareUDID: "PUBLIC-TARGET", port: 12345,
            authenticationCode: "public-token=", expectedProcessID: 123, selectedIsolateID: nil,
            timeout: 2, socketPath: server.path)
        #expect(try await channel.readMetadata().processID == 123)
        #expect(try await channel.readMetadata().isolateID == "isolates/7")
        await channel.close()
        await #expect(throws: IOSVMMetadataChannel.Failure.closed) { try await channel.readMetadata() }
        try await server.finish()
    }

    @Test("invalid authentication and deadline inputs never open USB", arguments: ["empty", "header", "path", "long", "zeroTimeout", "infiniteTimeout"])
    func invalidConnect(_ variant: String) async throws {
        let server = try MuxServer { listener in
            var pending = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            #expect(poll(&pending, 1, 100) == 0)
        }
        let auth = switch variant {
        case "empty": ""
        case "header": "public\r\nX: 1"
        case "path": "public/other"
        case "long": String(repeating: "x", count: 257)
        default: "public-token="
        }
        let timeout: TimeInterval = variant == "zeroTimeout" ? 0 : variant == "infiniteTimeout" ? .infinity : 2
        await #expect(throws: IOSVMHTTPTransport.Failure.invalidInput) {
            try await IOSVMHTTPTransport.connect(hardwareUDID: "PUBLIC-TARGET", port: 12345,
                authenticationCode: auth, timeout: timeout, socketPath: server.path)
        }
        try await server.finish()
    }

    @Test("three RPCs use one Connect and preserve request order and encoded isolate identity")
    func persistent() async throws {
        let server = try vmHTTPServer { fd in
            for (path, type) in [("getVM", "VM"), ("getVersion", "Version"),
                                 ("getMemoryUsage?isolateId=isolates%2F1", "MemoryUsage")] {
                #expect(try httpRequest(fd).hasPrefix("GET /public-token=/\(path) HTTP/1.1\r\n"))
                try muxWrite(fd, chunkedRPC("{\"jsonrpc\":\"2.0\",\"id\":\"\",\"result\":{\"type\":\"\(type)\",\"value\":42}}"))
            }
            #expect(try muxReadToEOF(fd))
        }
        let transport = try await makeHTTPTransport(server)
        for method in ["getVM", "getVersion", "getMemoryUsage"] {
            let parameters: [String: JSONValue] = method == "getMemoryUsage" ? ["isolateId": .string("isolates/1")] : [:]
            let result = try await transport.request(method: method, parameters: parameters)
            #expect(result["value"] == .number(42))
        }
        await transport.close()
        await transport.close()
        try await server.finish()
    }

    @Test("DDS events, errors, wrong IDs and wrong result types permanently close", arguments: [
        "{\"jsonrpc\":\"2.0\",\"method\":\"streamNotify\",\"params\":{}}",
        "{\"jsonrpc\":\"2.0\",\"id\":\"\",\"error\":{\"code\":-32603,\"message\":\"private\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"type\":\"VM\"}}",
        "{\"jsonrpc\":\"2.0\",\"result\":{\"type\":\"VM\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":\"\",\"result\":{\"type\":\"Sentinel\",\"kind\":\"Collected\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":\"\",\"result\":{\"type\":\"MemoryUsage\"}}",
        "{\"id\":\"\",\"result\":{\"type\":\"VM\"}}", "not-json",
    ])
    func invalidEnvelope(_ body: String) async throws {
        let server = try vmHTTPServer { fd in
            _ = try httpRequest(fd)
            try muxWrite(fd, chunkedRPC(body))
            #expect(try muxReadToEOF(fd))
        }
        let transport = try await makeHTTPTransport(server)
        await #expect(throws: IOSVMHTTPTransport.Failure.invalidResponse) { try await transport.request(method: "getVM", parameters: [:]) }
        await #expect(throws: IOSVMHTTPTransport.Failure.closed) { try await transport.request(method: "getVM", parameters: [:]) }
        try await server.finish()
    }

    @Test("redirect and partial response never reopen or return a sample", arguments: [
        "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:65432/secret/\r\nContent-Length: 0\r\n\r\n",
        "HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\n{",
    ])
    func failedResponse(_ wire: String) async throws {
        let server = try vmHTTPServer { fd in
            _ = try httpRequest(fd)
            try muxWrite(fd, Data(wire.utf8))
            #expect(shutdown(fd, SHUT_WR) == 0)
            #expect(try muxReadToEOF(fd))
        }
        let transport = try await makeHTTPTransport(server)
        await #expect(throws: IOSVMHTTPTransport.Failure.self) { try await transport.request(method: "getVM", parameters: [:]) }
        await #expect(throws: IOSVMHTTPTransport.Failure.closed) { try await transport.request(method: "getVM", parameters: [:]) }
        try await server.finish()
    }

    @Test("unsupported or injected methods write no bytes", arguments: ["getVM\r\nX: 1", "_collectAllGarbage", "streamListen"])
    func invalidMethod(_ method: String) async throws {
        let server = try vmHTTPServer { fd in
            let eof = try muxReadToEOF(fd)
            #expect(eof)
        }
        let transport = try await makeHTTPTransport(server)
        await #expect(throws: IOSVMHTTPTransport.Failure.invalidInput) { try await transport.request(method: method, parameters: [:]) }
        await transport.close()
        try await server.finish()
    }

    @Test("deadline covers the whole fragmented response rather than resetting per read")
    func overallDeadline() async throws {
        let server = try vmHTTPServer { fd in
            _ = try httpRequest(fd)
            let bytes = Data("HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\n".utf8)
            for byte in bytes {
                usleep(20_000)
                do { try muxWrite(fd, Data([byte])) } catch { break }
            }
        }
        let transport = try await makeHTTPTransport(server, timeout: 0.15)
        let start = ContinuousClock.now
        await #expect(throws: IOSVMHTTPTransport.Failure.timedOut) { try await transport.request(method: "getVM", parameters: [:]) }
        #expect(start.duration(to: .now) < .seconds(1))
        await #expect(throws: IOSVMHTTPTransport.Failure.closed) { try await transport.request(method: "getVM", parameters: [:]) }
        try await server.finish()
    }

    @Test("close or cancellation interrupts in-flight RPC and cannot publish late", arguments: [false, true])
    func stop(_ cancel: Bool) async throws {
        let arrived = HTTPRequestSignal()
        let server = try vmHTTPServer { fd in
            _ = try httpRequest(fd)
            arrived.mark()
            #expect(try muxReadToEOF(fd))
        }
        let transport = try await makeHTTPTransport(server)
        let request = Task { try await transport.request(method: "getVM", parameters: [:]) }
        try await arrived.wait()
        if cancel { request.cancel() } else { await transport.close() }
        do { _ = try await request.value; Issue.record("stopped RPC returned a value") }
        catch { if cancel { #expect(error is CancellationError) } }
        await #expect(throws: IOSVMHTTPTransport.Failure.closed) { try await transport.request(method: "getVM", parameters: [:]) }
        try await server.finish()
    }

    @Test("a concurrent RPC is rejected without cancelling the first")
    func singleFlight() async throws {
        let arrived = HTTPRequestSignal()
        let release = DispatchSemaphore(value: 0)
        let server = try vmHTTPServer { fd in
            _ = try httpRequest(fd)
            arrived.mark()
            #expect(release.wait(timeout: .now() + 2) == .success)
            try muxWrite(fd, chunkedRPC("{\"jsonrpc\":\"2.0\",\"id\":\"\",\"result\":{\"type\":\"VM\"}}"))
            #expect(try muxReadToEOF(fd))
        }
        let transport = try await makeHTTPTransport(server)
        let first = Task { try await transport.request(method: "getVM", parameters: [:]) }
        try await arrived.wait()
        await #expect(throws: IOSVMHTTPTransport.Failure.operationInProgress) { try await transport.request(method: "getVersion", parameters: [:]) }
        release.signal()
        #expect(try await first.value["type"] == .string("VM"))
        await transport.close()
        try await server.finish()
    }
}

private func makeHTTPTransport(_ server: MuxServer, timeout: TimeInterval = 2) async throws -> IOSVMHTTPTransport {
    try await IOSVMHTTPTransport.connect(hardwareUDID: "PUBLIC-TARGET", port: 12345,
        authenticationCode: "public-token=", timeout: timeout, socketPath: server.path)
}

private func vmHTTPServer(_ serve: @escaping @Sendable (Int32) throws -> Void) throws -> MuxServer {
    try MuxServer { listener in
        try muxInventory(listener)
        let fd = try muxAccept(listener)
        defer { Darwin.close(fd) }
        let connect = try muxRequest(fd)
        #expect(connect.body["MessageType"] as? String == "Connect")
        #expect(connect.body["DeviceID"] as? Int == 42)
        try muxSend(fd, body: ["MessageType": "Result", "Number": 0], tag: connect.tag)
        try serve(fd)
        var pending = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
        #expect(poll(&pending, 1, 50) == 0) // No second Connect, including after failure/close.
    }
}

private func httpRequest(_ fd: Int32) throws -> String {
    var bytes = Data()
    while !bytes.suffix(4).elementsEqual(Data("\r\n\r\n".utf8)), bytes.count < 16_384 { bytes.append(try muxRead(fd, count: 1)) }
    return String(decoding: bytes, as: UTF8.self)
}

private func chunkedRPC(_ body: String) -> Data {
    let bytes = Data(body.utf8)
    return Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n\(String(bytes.count, radix: 16))\r\n".utf8) + bytes + Data("\r\n0\r\n\r\n".utf8)
}

private final class HTTPRequestSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var arrived = false
    func mark() { lock.withLock { arrived = true } }
    func wait() async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !lock.withLock({ arrived }) {
            guard ContinuousClock.now < deadline else { throw IOSVMHTTPTransport.Failure.timedOut }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}
