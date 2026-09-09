import Foundation

/// Incremental framing for one persistent-connection VM HTTP response.
struct IOSVMHTTPResponse {
    enum Failure: Error, Equatable { case invalidResponse }
    private enum Phase { case headers, fixed(Int), chunkSize, chunk(Int), chunkEnd, end, terminal }
    private var phase = Phase.headers
    private var pending = Data()
    private var body = Data()
    private var wireBytes = 0
    private static let headerLimit = 16_384
    private static let bodyLimit = 1_048_576

    /// One decoder per request, never pipelined. Extra bytes are not a future response.
    mutating func append(_ bytes: Data) throws -> Data? {
        do {
            guard case .terminal = phase else { return try consume(bytes) }
            throw Failure.invalidResponse
        } catch {
            phase = .terminal
            pending.removeAll()
            body.removeAll()
            throw Failure.invalidResponse
        }
    }

    private mutating func consume(_ bytes: Data) throws -> Data? {
        // A one-byte chunk has six wire bytes; bound framing overhead as well as decoded bytes.
        guard bytes.count <= 65_536,
              wireBytes <= Self.headerLimit + Self.bodyLimit * 6 - bytes.count else { throw Failure.invalidResponse }
        wireBytes += bytes.count
        pending.append(bytes)
        while true {
            switch phase {
            case .headers:
                guard let delimiter = pending.range(of: Data("\r\n\r\n".utf8)) else {
                    guard pending.count <= Self.headerLimit else { throw Failure.invalidResponse }
                    return nil
                }
                guard pending.distance(from: pending.startIndex, to: delimiter.upperBound) <= Self.headerLimit else { throw Failure.invalidResponse }
                phase = try Self.framing(pending[..<delimiter.lowerBound])
                pending.removeSubrange(..<delimiter.upperBound)
            case let .fixed(remaining):
                let count = min(remaining, pending.count)
                body.append(pending.prefix(count))
                pending.removeFirst(count)
                if count < remaining { phase = .fixed(remaining - count); return nil }
                return try complete()
            case .chunkSize:
                guard let delimiter = pending.range(of: Data("\r\n".utf8)) else {
                    guard pending.count <= 16 else { throw Failure.invalidResponse }
                    return nil
                }
                let sizeBytes = pending[..<delimiter.lowerBound]
                guard !sizeBytes.isEmpty, sizeBytes.count <= 16,
                      sizeBytes.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
                      let text = String(data: sizeBytes, encoding: .ascii), let size = Int(text, radix: 16),
                      size <= Self.bodyLimit - body.count else { throw Failure.invalidResponse }
                pending.removeSubrange(..<delimiter.upperBound)
                phase = size == 0 ? .end : .chunk(size)
            case let .chunk(remaining):
                let count = min(remaining, pending.count)
                body.append(pending.prefix(count))
                pending.removeFirst(count)
                if count < remaining { phase = .chunk(remaining - count); return nil }
                phase = .chunkEnd
            case .chunkEnd, .end:
                guard pending.count >= 2 else { return nil }
                guard pending.prefix(2) == Data("\r\n".utf8) else { throw Failure.invalidResponse }
                pending.removeFirst(2)
                if case .end = phase { return try complete() }
                phase = .chunkSize
            case .terminal: throw Failure.invalidResponse
            }
        }
    }

    private mutating func complete() throws -> Data {
        guard pending.isEmpty else { throw Failure.invalidResponse }
        phase = .terminal
        return body
    }

    private static func framing(_ bytes: Data) throws -> Phase {
        guard bytes.allSatisfy({ $0 == 9 || $0 == 10 || $0 == 13 || (32...126).contains($0) }),
              let text = String(data: bytes, encoding: .ascii) else { throw Failure.invalidResponse }
        let lines = text.components(separatedBy: "\r\n")
        guard let status = lines.first, status.utf8.allSatisfy({ (32...126).contains($0) }),
              status == "HTTP/1.1 200" || status.hasPrefix("HTTP/1.1 200 ") else { throw Failure.invalidResponse }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw Failure.invalidResponse }
            let name = String(line[..<colon]).lowercased()
            guard !name.isEmpty, name.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }),
                  headers[name] == nil else { throw Failure.invalidResponse }
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !value.contains("\r"), !value.contains("\n") else { throw Failure.invalidResponse }
            headers[name] = value
        }
        guard headers["content-encoding"] == nil,
              headers["connection"] == nil || headers["connection"]?.lowercased() == "keep-alive" else { throw Failure.invalidResponse }
        if let encoding = headers["transfer-encoding"] {
            guard encoding.lowercased() == "chunked", headers["content-length"] == nil else { throw Failure.invalidResponse }
            return .chunkSize
        }
        guard let length = headers["content-length"], !length.isEmpty,
              length.utf8.allSatisfy({ (48...57).contains($0) }), let count = Int(length),
              count <= bodyLimit else { throw Failure.invalidResponse }
        return .fixed(count)
    }
}
