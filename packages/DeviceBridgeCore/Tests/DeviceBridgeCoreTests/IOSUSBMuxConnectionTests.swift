import Darwin
import Foundation
import Testing
@testable import DeviceBridgeCore

@Suite("Native exact USB usbmux connection")
struct IOSUSBMuxConnectionTests {
    @Test("peer write EOF preserves the host write direction")
    func peerHalfClose() async throws {
        let server = try MuxServer { listener in
            try muxInventory(listener)
            let fd = try muxAccept(listener)
            defer { Darwin.close(fd) }
            let request = try muxRequest(fd)
            try muxSend(fd, body: ["MessageType": "Result", "Number": 0], tag: request.tag)
            #expect(shutdown(fd, SHUT_WR) == 0)
            #expect(try muxRead(fd, count: 4) == Data("ping".utf8))
            #expect(try muxReadToEOF(fd))
        }
        let connection = try await IOSUSBMuxConnection.connect(hardwareUDID: "PUBLIC-TARGET", port: 12345, socketPath: server.path, timeout: 1)
        #expect(try await connection.readChunk(maxBytes: 4, timeout: 1) == nil)
        #expect(try await connection.readChunk(maxBytes: 4, timeout: 1) == nil)
        try await connection.write(Data("ping".utf8), timeout: 1)
        try await connection.finishWriting()
        try await connection.finishWriting()
        await connection.close()
        await connection.close()
        try await server.finish()
    }

    @Test("host write EOF preserves remaining peer bytes and clean read EOF")
    func hostHalfClose() async throws {
        let server = try MuxServer { listener in
            try muxInventory(listener)
            let fd = try muxAccept(listener)
            defer { Darwin.close(fd) }
            let request = try muxRequest(fd)
            try muxSend(fd, body: ["MessageType": "Result", "Number": 0], tag: request.tag)
            #expect(try muxReadToEOF(fd))
            try muxWrite(fd, Data("tail".utf8))
            #expect(shutdown(fd, SHUT_WR) == 0)
        }
        let connection = try await IOSUSBMuxConnection.connect(hardwareUDID: "PUBLIC-TARGET", port: 12345, socketPath: server.path, timeout: 1)
        try await connection.finishWriting()
        try await connection.finishWriting()
        var received = Data()
        while let chunk = try await connection.readChunk(maxBytes: 4, timeout: 1) { received.append(chunk) }
        #expect(received == Data("tail".utf8))
        await connection.close()
        await connection.close()
        try await server.finish()
    }

    @Test("finishWriting rejects a pending write without truncating it or closing reads")
    func halfClosePendingWrite() async throws {
        let allowDrain = DispatchSemaphore(value: 0)
        let server = try MuxServer { listener in
            try muxInventory(listener)
            let fd = try muxAccept(listener)
            defer { Darwin.close(fd) }
            var receiveBuffer: Int32 = 4096
            setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &receiveBuffer, socklen_t(MemoryLayout<Int32>.size))
            let request = try muxRequest(fd)
            try muxSend(fd, body: ["MessageType": "Result", "Number": 0], tag: request.tag)
            #expect(allowDrain.wait(timeout: .now() + 2) == .success)
            #expect(try muxRead(fd, count: 32 * 65_536) == Data(repeating: 42, count: 32 * 65_536))
            #expect(try muxReadToEOF(fd))
            try muxWrite(fd, Data([99]))
            #expect(shutdown(fd, SHUT_WR) == 0)
        }
        let connection = try await IOSUSBMuxConnection.connect(hardwareUDID: "PUBLIC-TARGET", port: 12345, socketPath: server.path, timeout: 1)
        let writer = Task {
            for _ in 0..<32 { try await connection.write(Data(repeating: 42, count: 65_536), timeout: 2) }
        }
        try await Task.sleep(for: .milliseconds(30))
        await #expect(throws: IOSUSBMuxConnection.Failure.operationInProgress) { try await connection.finishWriting() }
        allowDrain.signal()
        try await writer.value
        try await connection.finishWriting()
        #expect(try await connection.readChunk(maxBytes: 1, timeout: 1) == Data([99]))
        #expect(try await connection.readChunk(maxBytes: 1, timeout: 1) == nil)
        await connection.close()
        try await server.finish()
    }

    @Test("existing read still fully closes on peer EOF")
    func originalReadEOF() async throws {
        let server = try MuxServer { listener in
            try muxInventory(listener)
            let fd = try muxAccept(listener)
            defer { Darwin.close(fd) }
            let request = try muxRequest(fd)
            try muxSend(fd, body: ["MessageType": "Result", "Number": 0], tag: request.tag)
            #expect(shutdown(fd, SHUT_WR) == 0)
            #expect(try muxReadToEOF(fd))
        }
        let connection = try await IOSUSBMuxConnection.connect(hardwareUDID: "PUBLIC-TARGET", port: 12345, socketPath: server.path, timeout: 1)
        await #expect(throws: IOSUSBMuxConnection.Failure.closed) { try await connection.read(maxBytes: 1, timeout: 1) }
        await #expect(throws: IOSUSBMuxConnection.Failure.closed) { try await connection.write(Data([42]), timeout: 1) }
        await connection.close()
        try await server.finish()
    }

    @Test("fragmented inventory selects exact USB handle and switches to raw bytes")
    func exactUSB() async throws {
        let server = try MuxServer { listener in
            let inventory = try muxAccept(listener)
            defer { Darwin.close(inventory) }
            let request = try muxRequest(inventory)
            #expect(request.body["MessageType"] as? String == "ListDevices")
            try muxSend(inventory, body: ["DeviceList": [muxDevice("PUBLIC-OTHER", 7), muxDevice("PUBLIC-TARGET", 9, "Network"), muxDevice("PUBLIC-TARGET", 42)]], tag: request.tag, fragmented: true)
            let tunnel = try muxAccept(listener)
            defer { Darwin.close(tunnel) }
            let connect = try muxRequest(tunnel)
            #expect(connect.body["MessageType"] as? String == "Connect")
            #expect(connect.body["DeviceID"] as? Int == 42)
            #expect(connect.body["PortNumber"] as? Int == 14640) // htons(12345)
            try muxSend(tunnel, body: ["MessageType": "Result", "Number": 0], tag: connect.tag, fragmented: true)
            #expect(try muxRead(tunnel, count: 4) == Data("ping".utf8))
            try muxWrite(tunnel, Data("pong".utf8))
            #expect(try muxReadToEOF(tunnel))
        }
        let connection = try await IOSUSBMuxConnection.connect(hardwareUDID: "PUBLIC-TARGET", port: 12345, socketPath: server.path, timeout: 2)
        try await connection.write(Data("ping".utf8), timeout: 1)
        var received = Data()
        while received.count < 4 { received.append(try await connection.read(maxBytes: 4 - received.count, timeout: 1)) }
        #expect(received == Data("pong".utf8))
        await connection.close()
        await connection.close()
        await #expect(throws: IOSUSBMuxConnection.Failure.closed) { try await connection.write(Data([1]), timeout: 1) }
        try await server.finish()
    }

    @Test("missing, wireless, duplicate and malformed routes never connect", arguments: ["missing", "wireless", "duplicate", "booleanID", "mismatchedID", "badList"])
    func rejectsRoutes(_ variant: String) async throws {
        let server = try MuxServer { listener in
            let fd = try muxAccept(listener)
            defer { Darwin.close(fd) }
            let request = try muxRequest(fd)
            var devices = [muxDevice("PUBLIC-TARGET", 42)]
            switch variant {
            case "missing": devices = [muxDevice("PUBLIC-OTHER", 42)]
            case "wireless": devices = [muxDevice("PUBLIC-TARGET", 42, "Network")]
            case "duplicate": devices.append(muxDevice("PUBLIC-TARGET", 43))
            case "booleanID": devices = [["DeviceID": true, "Properties": ["SerialNumber": "PUBLIC-TARGET", "ConnectionType": "USB", "DeviceID": true]]]
            case "mismatchedID": devices[0]["DeviceID"] = 55
            default: break
            }
            try muxSend(fd, body: ["DeviceList": variant == "badList" ? "bad" : devices], tag: request.tag)
            #expect(try muxReadToEOF(fd))
            var pollFD = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            #expect(poll(&pollFD, 1, 100) == 0)
        }
        await #expect(throws: IOSUSBMuxConnection.Failure.self) {
            try await IOSUSBMuxConnection.connect(hardwareUDID: "PUBLIC-TARGET", port: 12345, socketPath: server.path, timeout: 1)
        }
        try await server.finish()
    }

    @Test("rejects wrong header, truncated or malformed plist before connection", arguments: ["version", "kind", "tag", "shortLength", "oversize", "truncated", "badPlist", "array"])
    func rejectsFrames(_ variant: String) async throws {
        let server = try MuxServer { listener in
            let fd = try muxAccept(listener)
            defer { Darwin.close(fd) }
            let request = try muxRequest(fd)
            let body = try PropertyListSerialization.data(fromPropertyList: variant == "array" ? [] : ["DeviceList": [muxDevice("PUBLIC-TARGET", 42)]], format: .xml, options: 0)
            var words: [UInt32] = [UInt32(body.count + 16), 1, 8, request.tag]
            switch variant {
            case "version": words[1] = 0
            case "kind": words[2] = 7
            case "tag": words[3] += 1
            case "shortLength": words[0] = 15
            case "oversize": words[0] = 1_048_577
            default: break
            }
            let payload = variant == "badPlist" ? Data(repeating: 0xFF, count: body.count) : body
            try muxWrite(fd, muxHeader(words) + (variant == "truncated" ? payload.prefix(5) : payload))
        }
        await #expect(throws: IOSUSBMuxConnection.Failure.self) {
            try await IOSUSBMuxConnection.connect(hardwareUDID: "PUBLIC-TARGET", port: 12345, socketPath: server.path, timeout: 1)
        }
        try await server.finish()
    }

    @Test("nonzero and noninteger Connect results close the socket", arguments: ["refused", "boolean", "missingType"])
    func failedConnect(_ variant: String) async throws {
        let server = try MuxServer { listener in
            try muxInventory(listener)
            let fd = try muxAccept(listener)
            defer { Darwin.close(fd) }
            let request = try muxRequest(fd)
            let result: [String: Any] = variant == "missingType" ? ["Number": 0] : ["MessageType": "Result", "Number": variant == "boolean" ? false : 3]
            try muxSend(fd, body: result, tag: request.tag)
            #expect(try muxReadToEOF(fd))
        }
        await #expect(throws: IOSUSBMuxConnection.Failure.self) {
            try await IOSUSBMuxConnection.connect(hardwareUDID: "PUBLIC-TARGET", port: 12345, socketPath: server.path, timeout: 1)
        }
        try await server.finish()
    }

    @Test("inventory timeout releases its socket without blocking main actor")
    @MainActor func inventoryTimeout() async throws {
        let server = try MuxServer { listener in
            let fd = try muxAccept(listener)
            defer { Darwin.close(fd) }
            _ = try muxRequest(fd)
            #expect(try muxReadToEOF(fd))
        }
        await #expect(throws: IOSUSBMuxConnection.Failure.timedOut) {
            try await IOSUSBMuxConnection.connect(hardwareUDID: "PUBLIC-TARGET", port: 12345, socketPath: server.path, timeout: 0.05)
        }
        try await server.finish()
    }

    @Test("read deadline closes the tunnel and rejects subsequent operations")
    func readTimeout() async throws {
        let server = try MuxServer { listener in
            try muxInventory(listener)
            let fd = try muxAccept(listener)
            defer { Darwin.close(fd) }
            let request = try muxRequest(fd)
            try muxSend(fd, body: ["MessageType": "Result", "Number": 0], tag: request.tag)
            #expect(try muxReadToEOF(fd))
        }
        let connection = try await IOSUSBMuxConnection.connect(hardwareUDID: "PUBLIC-TARGET", port: 12345, socketPath: server.path, timeout: 1)
        await #expect(throws: IOSUSBMuxConnection.Failure.timedOut) { try await connection.read(maxBytes: 1, timeout: 0.05) }
        await #expect(throws: IOSUSBMuxConnection.Failure.closed) { try await connection.read(maxBytes: 1, timeout: 1) }
        await connection.close()
        try await server.finish()
    }

    @Test("only the pinned 24-digit UDID spelling normalization is accepted")
    func normalizedUDID() async throws {
        let server = try MuxServer { listener in
            let inventory = try muxAccept(listener)
            defer { Darwin.close(inventory) }
            let request = try muxRequest(inventory)
            try muxSend(inventory, body: ["DeviceList": [muxDevice("123456781234567812345678", 42)]], tag: request.tag)
            let fd = try muxAccept(listener)
            defer { Darwin.close(fd) }
            let connect = try muxRequest(fd)
            #expect(connect.body["DeviceID"] as? Int == 42)
            try muxSend(fd, body: ["MessageType": "Result", "Number": 0], tag: connect.tag)
            #expect(try muxReadToEOF(fd))
        }
        let connection = try await IOSUSBMuxConnection.connect(hardwareUDID: "12345678-1234567812345678", port: 12345, socketPath: server.path, timeout: 1)
        await connection.close()
        try await server.finish()
    }

    @Test("cancellation during pending read closes the tunnel within its deadline")
    func cancellation() async throws {
        let server = try MuxServer { listener in
            try muxInventory(listener)
            let fd = try muxAccept(listener)
            defer { Darwin.close(fd) }
            let request = try muxRequest(fd)
            try muxSend(fd, body: ["MessageType": "Result", "Number": 0], tag: request.tag)
            #expect(try muxReadToEOF(fd))
        }
        let connection = try await IOSUSBMuxConnection.connect(hardwareUDID: "PUBLIC-TARGET", port: 12345, socketPath: server.path, timeout: 1)
        let read = Task { try await connection.read(maxBytes: 1, timeout: 30) }
        try await Task.sleep(for: .milliseconds(20))
        let start = ContinuousClock.now
        read.cancel()
        await #expect(throws: CancellationError.self) { try await read.value }
        #expect(start.duration(to: .now) < .seconds(1))
        await #expect(throws: IOSUSBMuxConnection.Failure.closed) { try await connection.read(maxBytes: 1, timeout: 1) }
        try await server.finish()
    }

    @Test("dropping the exclusive owner closes the connection")
    func deinitCloses() async throws {
        let server = try MuxServer { listener in
            try muxInventory(listener)
            let fd = try muxAccept(listener)
            defer { Darwin.close(fd) }
            let request = try muxRequest(fd)
            try muxSend(fd, body: ["MessageType": "Result", "Number": 0], tag: request.tag)
            #expect(try muxReadToEOF(fd))
        }
        var connection: IOSUSBMuxConnection? = try await IOSUSBMuxConnection.connect(hardwareUDID: "PUBLIC-TARGET", port: 12345, socketPath: server.path, timeout: 1)
        #expect(connection != nil)
        connection = nil
        try await server.finish()
    }

    @Test("a stalled peer bounds writes and closes a partially written stream")
    func writeTimeout() async throws {
        let server = try MuxServer { listener in
            try muxInventory(listener)
            let fd = try muxAccept(listener)
            defer { Darwin.close(fd) }
            var receiveBuffer: Int32 = 4096
            setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &receiveBuffer, socklen_t(MemoryLayout<Int32>.size))
            let request = try muxRequest(fd)
            try muxSend(fd, body: ["MessageType": "Result", "Number": 0], tag: request.tag)
            usleep(400_000) // Deliberately withhold reads to force kernel backpressure.
            var bytes = [UInt8](repeating: 0, count: 65_536)
            while true {
                let count = recv(fd, &bytes, bytes.count, 0)
                guard count >= 0 else { throw MuxFixtureError.io }
                if count == 0 { break }
            }
        }
        let connection = try await IOSUSBMuxConnection.connect(hardwareUDID: "PUBLIC-TARGET", port: 12345, socketPath: server.path, timeout: 1)
        await #expect(throws: IOSUSBMuxConnection.Failure.timedOut) {
            for _ in 0..<128 { try await connection.write(Data(repeating: 42, count: 65_536), timeout: 0.05) }
        }
        await #expect(throws: IOSUSBMuxConnection.Failure.closed) { try await connection.write(Data([1]), timeout: 1) }
        await connection.close()
        try await server.finish()
    }

    @Test("idempotent close cannot close a subsequently allocated unrelated descriptor")
    func descriptorReuse() async throws {
        let server = try MuxServer { listener in
            try muxInventory(listener)
            let fd = try muxAccept(listener)
            defer { Darwin.close(fd) }
            let request = try muxRequest(fd)
            try muxSend(fd, body: ["MessageType": "Result", "Number": 0], tag: request.tag)
            #expect(try muxReadToEOF(fd))
        }
        let connection = try await IOSUSBMuxConnection.connect(hardwareUDID: "PUBLIC-TARGET", port: 12345, socketPath: server.path, timeout: 1)
        await connection.close()
        try await server.finish()
        var pair: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        defer { Darwin.close(pair[0]); Darwin.close(pair[1]) }
        var enabled: Int32 = 1
        setsockopt(pair[0], SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        await connection.close()
        try muxWrite(pair[0], Data([42]))
        #expect(try muxRead(pair[1], count: 1) == Data([42]))
    }

    @Test("pending read allows a concurrent write before the peer sends its reply")
    func fullDuplex() async throws {
        let server = try MuxServer { listener in
            try muxInventory(listener)
            let fd = try muxAccept(listener)
            defer { Darwin.close(fd) }
            let request = try muxRequest(fd)
            try muxSend(fd, body: ["MessageType": "Result", "Number": 0], tag: request.tag)
            #expect(try muxRead(fd, count: 4) == Data("ping".utf8))
            try muxWrite(fd, Data("pong".utf8))
            #expect(try muxReadToEOF(fd))
        }
        let connection = try await IOSUSBMuxConnection.connect(hardwareUDID: "PUBLIC-TARGET", port: 12345, socketPath: server.path, timeout: 1)
        let read = Task { try await connection.read(maxBytes: 4, timeout: 1) }
        try await Task.sleep(for: .milliseconds(20))
        try await connection.write(Data("ping".utf8), timeout: 1)
        #expect(try await read.value == Data("pong".utf8))
        await connection.close()
        try await server.finish()
    }

    @Test("close wakes a pending thirty-second read promptly")
    func promptClose() async throws {
        let server = try MuxServer { listener in
            try muxInventory(listener)
            let fd = try muxAccept(listener)
            defer { Darwin.close(fd) }
            let request = try muxRequest(fd)
            try muxSend(fd, body: ["MessageType": "Result", "Number": 0], tag: request.tag)
            #expect(try muxReadToEOF(fd))
        }
        let connection = try await IOSUSBMuxConnection.connect(hardwareUDID: "PUBLIC-TARGET", port: 12345, socketPath: server.path, timeout: 1)
        let read = Task { try await connection.read(maxBytes: 1, timeout: 30) }
        try await Task.sleep(for: .milliseconds(20))
        let start = ContinuousClock.now
        await connection.close()
        #expect(start.duration(to: .now) < .seconds(1))
        await #expect(throws: IOSUSBMuxConnection.Failure.closed) { try await read.value }
        try await server.finish()
    }

    @Test("cancellation wakes a stalled inventory request promptly")
    func cancelInventory() async throws {
        let server = try MuxServer { listener in
            let fd = try muxAccept(listener)
            defer { Darwin.close(fd) }
            _ = try muxRequest(fd)
            #expect(try muxReadToEOF(fd))
        }
        let connect = Task { try await IOSUSBMuxConnection.connect(hardwareUDID: "PUBLIC-TARGET", port: 12345, socketPath: server.path, timeout: 30) }
        try await Task.sleep(for: .milliseconds(50))
        let start = ContinuousClock.now
        connect.cancel()
        await #expect(throws: CancellationError.self) { try await connect.value }
        #expect(start.duration(to: .now) < .seconds(1))
        try await server.finish()
    }
}

@Suite struct IOSUSBMuxLeaseDeadlineTests {
    @Test func chunkReadCanAllowAFiniteLeaseTeardownMargin() async throws {
        let server = try MuxServer { listener in
            try muxInventory(listener)
            let fd = try muxAccept(listener)
            defer { Darwin.close(fd) }
            let request = try muxRequest(fd)
            try muxSend(fd, body: ["MessageType": "Result", "Number": 0], tag: request.tag)
        }
        let usb = try await IOSUSBMuxConnection.connect(hardwareUDID: "PUBLIC-TARGET", port: 12345, socketPath: server.path, timeout: 2)
        do {
            for invalid in [0.0, -1, 60.01, .infinity, .nan] {
                await #expect(throws: IOSUSBMuxConnection.Failure.invalidInput) {
                    try await usb.readChunk(maxBytes: 1, timeout: invalid)
                }
            }
            let eof = try await usb.readChunk(maxBytes: 1, timeout: 35)
            #expect(eof == nil)
            await usb.close()
            try await server.finish()
        } catch { await usb.close(); try await server.finish(); throw error }
    }
}

final class MuxServer: @unchecked Sendable {
    let path: String
    private let task: Task<Void, Error>

    init(serve: @escaping @Sendable (Int32) throws -> Void) throws {
        path = "/tmp/dbmux-\(UUID().uuidString)"
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw MuxFixtureError.io }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(listener, 4) == 0 else { Darwin.close(listener); throw MuxFixtureError.io }
        let socketPath = path
        task = Task {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                DispatchQueue.global().async {
                    defer { Darwin.close(listener); unlink(socketPath) }
                    do { try serve(listener); continuation.resume() }
                    catch { continuation.resume(throwing: error) }
                }
            }
        }
    }

    func finish() async throws { try await task.value }
}

private enum MuxFixtureError: Error { case io }

func muxAccept(_ listener: Int32) throws -> Int32 {
    var readiness = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
    guard poll(&readiness, 1, 3000) > 0 else { throw MuxFixtureError.io }
    let fd = accept(listener, nil, nil)
    guard fd >= 0 else { throw MuxFixtureError.io }
    var timeout = timeval(tv_sec: 3, tv_usec: 0)
    var enabled: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
    return fd
}

private func muxDevice(_ serial: String, _ id: Int, _ type: String = "USB") -> [String: Any] {
    ["DeviceID": id, "Properties": ["DeviceID": id, "SerialNumber": serial, "ConnectionType": type]]
}

func muxInventory(_ listener: Int32) throws {
    let fd = try muxAccept(listener)
    defer { Darwin.close(fd) }
    let request = try muxRequest(fd)
    try muxSend(fd, body: ["DeviceList": [muxDevice("PUBLIC-TARGET", 42)]], tag: request.tag)
}

func muxReadToEOF(_ fd: Int32) throws -> Bool {
    var byte: UInt8 = 0
    let count = recv(fd, &byte, 1, 0)
    guard count >= 0 else { throw MuxFixtureError.io }
    return count == 0
}

func muxRead(_ fd: Int32, count: Int) throws -> Data {
    var result = Data()
    while result.count < count {
        var buffer = [UInt8](repeating: 0, count: count - result.count)
        let size = recv(fd, &buffer, buffer.count, 0)
        guard size > 0 else { throw MuxFixtureError.io }
        result.append(contentsOf: buffer.prefix(size))
    }
    return result
}

func muxWrite(_ fd: Int32, _ data: Data) throws {
    try data.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
            let size = send(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
            guard size > 0 else { throw MuxFixtureError.io }
            offset += size
        }
    }
}

private func muxHeader(_ words: [UInt32]) -> Data {
    words.reduce(into: Data()) { output, word in
        var little = word.littleEndian
        withUnsafeBytes(of: &little) { output.append(contentsOf: $0) }
    }
}

func muxRequest(_ fd: Int32) throws -> (body: [String: Any], tag: UInt32) {
    let header = try muxRead(fd, count: 16)
    let words = header.withUnsafeBytes { bytes in (0..<4).map { UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self)) } }
    guard words[0] >= 16, words[0] <= 1_048_576, words[1] == 1, words[2] == 8 else { throw MuxFixtureError.io }
    let body = try muxRead(fd, count: Int(words[0]) - 16)
    guard let plist = try PropertyListSerialization.propertyList(from: body, format: nil) as? [String: Any] else { throw MuxFixtureError.io }
    return (plist, words[3])
}

func muxSend(_ fd: Int32, body: [String: Any], tag: UInt32, fragmented: Bool = false) throws {
    let payload = try PropertyListSerialization.data(fromPropertyList: body, format: .xml, options: 0)
    let frame = muxHeader([UInt32(payload.count + 16), 1, 8, tag]) + payload
    if fragmented { for byte in frame { try muxWrite(fd, Data([byte])) } }
    else { try muxWrite(fd, frame) }
}
