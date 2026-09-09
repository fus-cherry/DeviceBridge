import DeviceBridgeProtocol
import Foundation
import Network

public enum TCPHelperChannelError: Error, Sendable, Equatable {
    case invalidPort
    case connectionFailed
    case connectionClosed
    case timedOut
}

public actor TCPHelperChannel: HelperRequestSending {
    private let port: NWEndpoint.Port
    private let codec = HelperWireCodec()
    private let timeout: Duration

    public init(hostPort: Int, timeout: Duration = .seconds(30)) throws {
        guard let port = NWEndpoint.Port(rawValue: UInt16(exactly: hostPort) ?? 0), hostPort > 0 else {
            throw TCPHelperChannelError.invalidPort
        }
        self.port = port
        self.timeout = timeout
    }

    public func send(_ request: HelperRequest) async throws -> HelperResult {
        try await withThrowingTaskGroup(of: HelperResult.self) { group in
            group.addTask { try await self.exchange(request) }
            group.addTask {
                try await Task.sleep(for: self.timeout)
                throw TCPHelperChannelError.timedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw TCPHelperChannelError.connectionClosed }
            return result
        }
    }

    private func exchange(_ request: HelperRequest) async throws -> HelperResult {
        try Task.checkCancellation()
        let payload = try codec.encode(request)
        let frame = try HelperFrameCodec.encode(payload)
        let connection = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        defer { connection.cancel() }

        return try await withTaskCancellationHandler {
            try await start(connection)
            try await send(frame, over: connection)
            let header = try await receiveExactly(4, from: connection)
            let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard length <= HelperWireCodec.maximumEnvelopeBytes else {
                connection.cancel()
                throw HelperFrameError.envelopeTooLarge
            }
            let response = try await receiveExactly(Int(length), from: connection)
            connection.cancel()
            if Task.isCancelled { throw CancellationError() }
            return try codec.decodeResult(response)
        } onCancel: {
            connection.cancel()
        }
    }

    private func start(_ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { continuation in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.stateUpdateHandler = nil
                    continuation.resume()
                case .failed, .cancelled:
                    connection.stateUpdateHandler = nil
                    continuation.resume(throwing: TCPHelperChannelError.connectionFailed)
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
    }

    private func send(_ data: Data, over connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { continuation in
            connection.send(content: data, completion: .contentProcessed { error in
                if error == nil { continuation.resume() }
                else { continuation.resume(throwing: TCPHelperChannelError.connectionFailed) }
            })
        }
    }

    private func receiveExactly(_ count: Int, from connection: NWConnection) async throws -> Data {
        var result = Data()
        while result.count < count {
            let remaining = count - result.count
            let chunk = try await receive(maximumLength: remaining, from: connection)
            guard !chunk.isEmpty else { throw TCPHelperChannelError.connectionClosed }
            result.append(chunk)
        }
        return result
    }

    private func receive(maximumLength: Int, from connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(
                minimumIncompleteLength: 1,
                maximumLength: maximumLength
            ) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(throwing: TCPHelperChannelError.connectionClosed)
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }
}
