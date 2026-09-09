import Darwin
import Foundation
import Testing
@testable import DeviceBridgeCore

struct IOSUSBLoopbackProxyTests {
    @Test(arguments: [false, true])
    func transportReadDeadlineMustOutlastThePeerLease(shortDeadline: Bool) async throws {
        let server = try MuxServer { listener in
            try muxInventory(listener)
            let fd = try muxAccept(listener)
            defer { Darwin.close(fd) }
            let request = try muxRequest(fd)
            try muxSend(fd, body: ["MessageType": "Result", "Number": 0], tag: request.tag)
            Thread.sleep(forTimeInterval: 0.15) // Scaled runner idle lease.
            if !shortDeadline {
                #expect(shutdown(fd, SHUT_WR) == 0)
                #expect(try muxReadToEOF(fd))
            }
        }
        let usb = try await IOSUSBMuxConnection.connect(hardwareUDID: "PUBLIC-TARGET", port: 12345, socketPath: server.path, timeout: 2)
        let proxy = try await IOSUSBLoopbackProxy.listen(usb: usb, usbReadTimeout: shortDeadline ? 0.04 : 0.5)
        let port = try #require(await proxy.port)
        try await proxyClient(port: port) { fd in
            let eof = try muxReadToEOF(fd)
            #expect(eof)
            _ = shutdown(fd, SHUT_WR)
        }
        let completion = await proxy.waitForCompletion()
        #expect(completion == (shortDeadline ? .failed(.usbRead(.timedOut)) : .clean))
        try await server.finish()
    }

    @Test(arguments: [false, true])
    func eitherHalfClosePreservesTheOtherDirection(phoneClosesFirst: Bool) async throws {
        let server = try MuxServer { listener in
            try muxInventory(listener)
            let fd = try muxAccept(listener)
            defer { Darwin.close(fd) }
            let request = try muxRequest(fd)
            try muxSend(fd, body: ["MessageType": "Result", "Number": 0], tag: request.tag)
            if phoneClosesFirst {
                try muxWrite(fd, Data("pong".utf8))
                #expect(shutdown(fd, SHUT_WR) == 0)
            }
            #expect(try muxRead(fd, count: 4) == Data("ping".utf8))
            #expect(try muxReadToEOF(fd))
            if !phoneClosesFirst {
                try muxWrite(fd, Data("pong".utf8))
                #expect(shutdown(fd, SHUT_WR) == 0)
            }
        }
        let usb = try await IOSUSBMuxConnection.connect(hardwareUDID: "PUBLIC-TARGET", port: 12345, socketPath: server.path, timeout: 2)
        do {
            let proxy = try await IOSUSBLoopbackProxy.listen(usb: usb, startupTimeout: .seconds(2), teardownTimeout: .seconds(1))
            let port = try #require(await proxy.port)
            try await proxyClient(port: port) { fd in
                if phoneClosesFirst {
                    #expect(try muxRead(fd, count: 4) == Data("pong".utf8))
                    #expect(try muxReadToEOF(fd))
                }
                try muxWrite(fd, Data("ping".utf8))
                #expect(shutdown(fd, SHUT_WR) == 0)
                if !phoneClosesFirst {
                    #expect(try muxRead(fd, count: 4) == Data("pong".utf8))
                    #expect(try muxReadToEOF(fd))
                }
            }
            let completion = await proxy.waitForCompletion()
            #expect(completion == .clean)
            await proxy.close()
            await proxy.close()
        } catch {
            await usb.close()
            throw error
        }
        try await server.finish()
    }

    @Test func absentLocalClientExpiresAndClosesUSB() async throws {
        let server = try MuxServer { listener in
            try muxInventory(listener)
            let fd = try muxAccept(listener)
            defer { Darwin.close(fd) }
            let request = try muxRequest(fd)
            try muxSend(fd, body: ["MessageType": "Result", "Number": 0], tag: request.tag)
            #expect(try muxReadToEOF(fd))
        }
        let usb = try await IOSUSBMuxConnection.connect(hardwareUDID: "PUBLIC-TARGET", port: 12345, socketPath: server.path, timeout: 2)
        let proxy = try await IOSUSBLoopbackProxy.listen(usb: usb, startupTimeout: .milliseconds(100))
        #expect(await proxy.waitForCompletion() == .failed(.timeout))
        try await server.finish()
    }

    @Test func resetWithoutCleanEOFIsNeverSuccess() async throws {
        let server = try MuxServer { listener in
            try muxInventory(listener)
            let fd = try muxAccept(listener)
            defer { Darwin.close(fd) }
            let request = try muxRequest(fd)
            try muxSend(fd, body: ["MessageType": "Result", "Number": 0], tag: request.tag)
            var byte: UInt8 = 0
            while recv(fd, &byte, 1, 0) > 0 { }
        }
        let usb = try await IOSUSBMuxConnection.connect(hardwareUDID: "PUBLIC-TARGET", port: 12345, socketPath: server.path, timeout: 2)
        let proxy = try await IOSUSBLoopbackProxy.listen(usb: usb, startupTimeout: .seconds(2), teardownTimeout: .milliseconds(100))
        let port = try #require(await proxy.port)
        try await proxyClient(port: port) { fd in
            try muxWrite(fd, Data("unfinished".utf8))
            var reset = linger(l_onoff: 1, l_linger: 0)
            #expect(setsockopt(fd, SOL_SOCKET, SO_LINGER, &reset, socklen_t(MemoryLayout<linger>.size)) == 0)
        }
        let completion = await proxy.waitForCompletion()
        if case .failed = completion {} else { Issue.record("Reset must fail, not become a clean or cancelled completion") }
        await proxy.close()
        try await server.finish()
    }

    @Test func unmatchedHalfCloseHasABoundedDrainWindow() async throws {
        let server = try MuxServer { listener in
            try muxInventory(listener)
            let fd = try muxAccept(listener)
            defer { Darwin.close(fd) }
            let request = try muxRequest(fd)
            try muxSend(fd, body: ["MessageType": "Result", "Number": 0], tag: request.tag)
            try muxWrite(fd, Data([42]))
            #expect(shutdown(fd, SHUT_WR) == 0)
            #expect(try muxReadToEOF(fd))
        }
        let usb = try await IOSUSBMuxConnection.connect(hardwareUDID: "PUBLIC-TARGET", port: 12345, socketPath: server.path, timeout: 2)
        let proxy = try await IOSUSBLoopbackProxy.listen(usb: usb, startupTimeout: .seconds(2), teardownTimeout: .milliseconds(40))
        let port = try #require(await proxy.port)
        try await proxyClient(port: port) { fd in
            let received = try muxRead(fd, count: 1)
            let eof = try muxReadToEOF(fd)
            #expect(received == Data([42]))
            #expect(eof)
            Thread.sleep(forTimeInterval: 0.15) // Fixture peer deliberately leaves its write side open.
        }
        #expect(await proxy.waitForCompletion() == .failed(.timeout))
        try await server.finish()
    }

    @Test func explicitCloseReleasesAnUnusedProxy() async throws {
        let server = try MuxServer { listener in
            try muxInventory(listener)
            let fd = try muxAccept(listener)
            defer { Darwin.close(fd) }
            let request = try muxRequest(fd)
            try muxSend(fd, body: ["MessageType": "Result", "Number": 0], tag: request.tag)
            #expect(try muxReadToEOF(fd))
        }
        let usb = try await IOSUSBMuxConnection.connect(hardwareUDID: "PUBLIC-TARGET", port: 12345, socketPath: server.path, timeout: 2)
        let proxy = try await IOSUSBLoopbackProxy.listen(usb: usb)
        await proxy.close()
        await proxy.close()
        #expect(await proxy.waitForCompletion() == .cancelled)
        try await server.finish()
    }

    @Test func resetWhileLargeReplyIsUndrainedFails() async throws {
        let server = try MuxServer { listener in
            try muxInventory(listener)
            let fd = try muxAccept(listener)
            defer { Darwin.close(fd) }
            let request = try muxRequest(fd)
            try muxSend(fd, body: ["MessageType": "Result", "Number": 0], tag: request.tag)
            // More than the socket buffers: the peer resets after only the first byte.
            do { try muxWrite(fd, Data(repeating: 42, count: 16 * 1024 * 1024)) }
            catch { } // Transport failure is expected after the downstream reset.
        }
        let usb = try await IOSUSBMuxConnection.connect(hardwareUDID: "PUBLIC-TARGET", port: 12345, socketPath: server.path, timeout: 2)
        let proxy = try await IOSUSBLoopbackProxy.listen(usb: usb, teardownTimeout: .milliseconds(100))
        let port = try #require(await proxy.port)
        try await proxyClient(port: port) { fd in
            let prefix = try muxRead(fd, count: 1)
            #expect(prefix == Data([42]))
            var reset = linger(l_onoff: 1, l_linger: 0)
            #expect(setsockopt(fd, SOL_SOCKET, SO_LINGER, &reset, socklen_t(MemoryLayout<linger>.size)) == 0)
        }
        let completion = await proxy.waitForCompletion()
        if case .failed = completion {} else { Issue.record("Undrained reset must fail") }
        await proxy.close()
        try await server.finish()
    }

    @Test func explicitCloseDuringDrainStaysCancelled() async throws {
        let server = try MuxServer { listener in
            try muxInventory(listener)
            let fd = try muxAccept(listener)
            defer { Darwin.close(fd) }
            let request = try muxRequest(fd)
            try muxSend(fd, body: ["MessageType": "Result", "Number": 0], tag: request.tag)
            #expect(shutdown(fd, SHUT_WR) == 0)
            #expect(try muxReadToEOF(fd))
        }
        let usb = try await IOSUSBMuxConnection.connect(hardwareUDID: "PUBLIC-TARGET", port: 12345, socketPath: server.path, timeout: 2)
        let proxy = try await IOSUSBLoopbackProxy.listen(usb: usb)
        let port = try #require(await proxy.port)
        // Keep the fixture's write side open until explicit cancellation completes.
        let drained = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let client = Task {
            try await proxyClient(port: port) { fd in
                defer { drained.signal() }
                let eof = try muxReadToEOF(fd)
                #expect(eof)
                drained.signal()
                #expect(release.wait(timeout: .now() + 3) == .success)
            }
        }
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { _ = drained.wait(timeout: .now() + 3); continuation.resume() }
        }
        await proxy.close()
        #expect(await proxy.waitForCompletion() == .cancelled)
        release.signal()
        try await client.value
        try await server.finish()
    }
}

private func proxyClient(port: UInt16, body: @escaping @Sendable (Int32) throws -> Void) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        DispatchQueue.global().async {
            do {
                let fd = socket(AF_INET, SOCK_STREAM, 0)
                guard fd >= 0 else { throw ProxyFixtureFailure.socket }
                defer { Darwin.close(fd) }
                var timeout = timeval(tv_sec: 2, tv_usec: 0)
                var enabled: Int32 = 1
                guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0,
                      setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0,
                      setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0 else { throw ProxyFixtureFailure.socket }
                var address = sockaddr_in()
                address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                address.sin_family = sa_family_t(AF_INET)
                address.sin_port = port.bigEndian
                address.sin_addr.s_addr = inet_addr("127.0.0.1")
                let result = withUnsafePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
                }
                guard result == 0 else { throw ProxyFixtureFailure.socket }
                try body(fd)
                continuation.resume()
            } catch { continuation.resume(throwing: error) }
        }
    }
}

private enum ProxyFixtureFailure: Error { case socket }
