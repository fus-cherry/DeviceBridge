import Foundation
import Testing
@testable import DeviceBridgeCore

@Suite("Bounded iOS VM HTTP response framing")
struct IOSVMHTTPResponseTests {
    @Test("fragmented chunked response returns only the complete body")
    func chunked() throws {
        var reader = IOSVMHTTPResponse()
        let wire = Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Type: application/json; charset=utf-8\r\n\r\n2\r\n{\"\r\n5\r\nv\":1}\r\n0\r\n\r\n".utf8)
        for byte in wire.dropLast() { #expect(try reader.append(Data([byte])) == nil) }
        #expect(try reader.append(Data([wire.last!])) == Data("{\"v\":1}".utf8))
    }

    @Test("Content-Length response preserves UTF-8 bytes across splits")
    func contentLength() throws {
        let body = Data("{\"text\":\"中文\"}".utf8)
        let wire = Data("HTTP/1.1 200 OK\r\ncontent-length: \(body.count)\r\n\r\n".utf8) + body
        for split in 1..<wire.count {
            var reader = IOSVMHTTPResponse()
            #expect(try reader.append(wire.prefix(split)) == nil)
            #expect(try reader.append(wire.dropFirst(split)) == body)
        }
    }

    @Test("redirects, nonpersistent and ambiguous responses are rejected", arguments: [
        "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1/secret/\r\nContent-Length: 0\r\n\r\n",
        "HTTP/1.0 200 OK\r\nContent-Length: 0\r\n\r\n",
        "HTTP/1.1 200 OK\nJunk\r\nContent-Length: 0\r\n\r\n",
        "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 0\r\n\r\n",
        "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nContent-Length: 0\r\n\r\n",
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Length: 0\r\n\r\n",
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip, chunked\r\n\r\n",
        "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: 0\r\n\r\n",
        "HTTP/1.1 200 OK\r\nContent-Length: -1\r\n\r\n",
        "HTTP/1.1 200 OK\r\nContent-Length: +1\r\n\r\n",
        "HTTP/1.1 200 OK\r\nContent-Length : 0\r\n\r\n",
        "HTTP/1.1 200 OK\r\n folded: value\r\nContent-Length: 0\r\n\r\n",
        "HTTP/1.1 200 OK\r\n\r\n",
    ])
    func rejectsHeaders(_ wire: String) {
        var reader = IOSVMHTTPResponse()
        #expect(throws: IOSVMHTTPResponse.Failure.invalidResponse) { try reader.append(Data(wire.utf8)) }
    }

    @Test("malformed chunks and unsolicited extra bytes cannot complete", arguments: [
        "X\r\n", "-1\r\n", "1;extension=1\r\nx\r\n0\r\n\r\n",
        "1\r\nxXX", "0\r\nX-Trailer: value\r\n\r\n", "0\r\n\r\nextra",
    ])
    func rejectsChunks(_ tail: String) {
        var reader = IOSVMHTTPResponse()
        #expect(throws: IOSVMHTTPResponse.Failure.invalidResponse) {
            try reader.append(Data(("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" + tail).utf8))
        }
    }

    @Test("oversized headers and bodies fail before buffering the advertised body")
    func bounded() throws {
        for wire in [
            "HTTP/1.1 200 OK\r\nX-Pad: " + String(repeating: "a", count: 16_384),
            "HTTP/1.1 200 OK\r\nContent-Length: 1048577\r\n\r\n",
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n100001\r\n",
        ] {
            var reader = IOSVMHTTPResponse()
            #expect(throws: IOSVMHTTPResponse.Failure.invalidResponse) { try reader.append(Data(wire.utf8)) }
        }
        var reader = IOSVMHTTPResponse()
        _ = try reader.append(Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n100000\r\n".utf8))
        for _ in 0..<16 { #expect(try reader.append(Data(repeating: 97, count: 65_536)) == nil) }
        #expect(throws: IOSVMHTTPResponse.Failure.invalidResponse) {
            try reader.append(Data("\r\n1\r\n".utf8))
        }
    }

    @Test("a completed or failed decoder cannot accept another response")
    func terminal() throws {
        var complete = IOSVMHTTPResponse()
        #expect(try complete.append(Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}".utf8)) == Data("{}".utf8))
        #expect(throws: IOSVMHTTPResponse.Failure.invalidResponse) { try complete.append(Data([1])) }
        var failed = IOSVMHTTPResponse()
        _ = try? failed.append(Data("HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n".utf8))
        #expect(throws: IOSVMHTTPResponse.Failure.invalidResponse) {
            try failed.append(Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}".utf8))
        }
    }
}
