import Foundation
import Darwin

/// Opt-in T082 experiment only. Never accepts clipboard, screenshot, file or real nonce payloads.
enum USBIdentityProbeServer {
    private enum ProbeError: Error { case socket, timeout, closed, invalid }
    private struct Request: Decodable {
        let version: Int
        let sequence: Int
        let action: String
        let canary: String
    }

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// Owns one listener/client only; no state is published to the Mac product.
    /// This public canary is a bootstrap diagnostic, NOT authentication or a real secret.
    @discardableResult
    static func run(port: UInt16, canary: String, leaseSeconds: TimeInterval = 30) throws -> String {
        guard port >= 1024, !canary.isEmpty, canary.utf8.count <= 128,
              leaseSeconds > 0, leaseSeconds <= 30 else { throw ProbeError.invalid }
        let client: Int32
        do {
            client = try acceptLoopback(port: port, deadline: now + 60)
        } catch ProbeError.timeout {
            return "startupExpired"
        }
        defer { Darwin.close(client) }
        let hardDeadline = now + 90
        var leaseDeadline = min(hardDeadline, now + leaseSeconds)
        var sequence = 1
        do {
            while sequence <= 1024 {
                let header = try read(client, length: 4, deadline: leaseDeadline)
                let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                guard length > 0, length <= 4096 else { return "invalidRequest" }
                let body = try read(client, length: Int(length), deadline: leaseDeadline)
                guard let object = try JSONSerialization.jsonObject(with: body) as? [String: Any],
                      Set(object.keys) == ["version", "sequence", "action", "canary"] else {
                    return "invalidRequest"
                }
                let request = try JSONDecoder().decode(Request.self, from: body)
                guard request.version == 1, request.sequence == sequence, request.canary == canary,
                      request.action == "identity" || request.action == "stop" else {
                    return "invalidRequest"
                }
                let status = request.action == "stop" ? "stopped" : "identity-only"
                let response = try JSONSerialization.data(withJSONObject: [
                    "version": 1, "sequence": sequence, "status": status, "canary": canary,
                    "listener": "127.0.0.1", "probeOnly": true
                ])
                var size = UInt32(response.count).bigEndian
                let frame = withUnsafeBytes(of: &size) { Data($0) } + response
                try write(client, data: frame, deadline: min(leaseDeadline, now + 5))
                if request.action == "stop" { return "stopped" }
                sequence += 1
                leaseDeadline = min(hardDeadline, now + leaseSeconds)
            }
            return "requestLimit"
        } catch ProbeError.timeout {
            return "leaseExpired"
        } catch ProbeError.closed {
            return "peerClosed"
        } catch {
            return "invalidRequest"
        }
    }

    private static func acceptLoopback(port: UInt16, deadline: TimeInterval) throws -> Int32 {
        let listener = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { throw ProbeError.socket }
        defer { Darwin.close(listener) }
        var yes: Int32 = 1
        guard setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout.size(ofValue: yes))) == 0,
              fcntl(listener, F_SETFL, O_NONBLOCK) == 0 else { throw ProbeError.socket }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Darwin.listen(listener, 1) == 0 else { throw ProbeError.socket }
        while true {
            try wait(listener, events: Int16(POLLIN), deadline: deadline)
            let client = Darwin.accept(listener, nil, nil)
            if client < 0 {
                if errno == EAGAIN || errno == EINTR { continue }
                throw ProbeError.socket
            }
            guard fcntl(client, F_SETFL, O_NONBLOCK) == 0,
                  setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes))) == 0 else {
                Darwin.close(client)
                throw ProbeError.socket
            }
            return client // listener closes before processing this single client
        }
    }

    private static func wait(_ descriptor: Int32, events: Int16, deadline: TimeInterval) throws {
        while true {
            let remaining = deadline - now
            guard remaining > 0 else { throw ProbeError.timeout }
            var item = pollfd(fd: descriptor, events: events, revents: 0)
            let result = Darwin.poll(&item, 1, Int32(min(remaining * 1000 + 1, 60_000)))
            if result > 0 { return }
            if result == 0 { throw ProbeError.timeout }
            if errno != EINTR { throw ProbeError.socket }
        }
    }

    private static func read(_ descriptor: Int32, length: Int, deadline: TimeInterval) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: length)
        var offset = 0
        while offset < length {
            try wait(descriptor, events: Int16(POLLIN), deadline: deadline)
            let count = bytes.withUnsafeMutableBytes {
                Darwin.recv(descriptor, $0.baseAddress!.advanced(by: offset), length - offset, 0)
            }
            if count == 0 { throw ProbeError.closed }
            if count < 0 {
                if errno == EAGAIN || errno == EINTR { continue }
                throw ProbeError.socket
            }
            offset += count
        }
        return Data(bytes)
    }

    private static func write(_ descriptor: Int32, data: Data, deadline: TimeInterval) throws {
        var offset = 0
        while offset < data.count {
            try wait(descriptor, events: Int16(POLLOUT), deadline: deadline)
            let count = data.withUnsafeBytes {
                Darwin.send(descriptor, $0.baseAddress!.advanced(by: offset), data.count - offset, 0)
            }
            if count <= 0 {
                if count < 0 && (errno == EAGAIN || errno == EINTR) { continue }
                throw ProbeError.closed
            }
            offset += count
        }
    }
}
