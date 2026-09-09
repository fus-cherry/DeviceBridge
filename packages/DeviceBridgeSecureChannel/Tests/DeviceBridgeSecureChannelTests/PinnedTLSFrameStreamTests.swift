import Foundation
import Network
import Testing
@testable import DeviceBridgeSecureChannel

@Suite("Authenticated local TLS frame stream")
struct PinnedTLSFrameStreamTests {
    @Test("late listener-ready cannot replace an expired startup deadline before its timer runs", arguments: [100_000_000, 101_000_000])
    func expiredStartupTransition(callbackTime: Int) throws {
        var deadline = TLSLifecycleDeadline()
        try deadline.advance(to: DispatchTime(uptimeNanoseconds: 100_000_000), at: DispatchTime(uptimeNanoseconds: 10_000_000))
        #expect(throws: PinnedTLSFrameStream.Failure.timedOut) {
            try deadline.advance(to: DispatchTime(uptimeNanoseconds: 200_000_000), at: DispatchTime(uptimeNanoseconds: UInt64(callbackTime)))
        }
        #expect(deadline.current == DispatchTime(uptimeNanoseconds: 100_000_000))
    }

    @Test("late incoming connection cannot replace an expired accept deadline before its timer runs", arguments: [200_000_000, 201_000_000])
    func expiredAcceptTransition(callbackTime: Int) throws {
        var deadline = TLSLifecycleDeadline()
        try deadline.advance(to: DispatchTime(uptimeNanoseconds: 100_000_000), at: DispatchTime(uptimeNanoseconds: 10_000_000))
        try deadline.advance(to: DispatchTime(uptimeNanoseconds: 200_000_000), at: DispatchTime(uptimeNanoseconds: 90_000_000))
        #expect(throws: PinnedTLSFrameStream.Failure.timedOut) {
            try deadline.advance(to: DispatchTime(uptimeNanoseconds: 300_000_000), at: DispatchTime(uptimeNanoseconds: UInt64(callbackTime)))
        }
        #expect(deadline.current == DispatchTime(uptimeNanoseconds: 200_000_000))
    }

    @Test("a backpressured frame write has a deadline while reads remain independent")
    func writeDeadline() async throws {
        let (client, server) = try await pair()
        let writing = Task {
            let payload = Data(repeating: 42, count: 6_356_992)
            for _ in 0..<8 { try await client.writeFrame(payload, timeout: 0.2) }
        }
        try await server.writeFrame(Data("duplex".utf8), timeout: 1)
        #expect(try await client.readFrame(timeout: 1) == Data("duplex".utf8))
        await #expect(throws: PinnedTLSFrameStream.Failure.timedOut) { try await writing.value }
        await #expect(throws: PinnedTLSFrameStream.Failure.closed) { try await client.readFrame(timeout: 1) }
        await client.close(); await server.close()
    }

    @Test("dropping the stream owner closes the peer connection")
    func deinitCloses() async throws {
        var peers: (PinnedTLSFrameStream?, PinnedTLSFrameStream) = try await pair()
        peers.0 = nil
        await #expect(throws: PinnedTLSFrameStream.Failure.closed) { try await peers.1.readFrame(timeout: 1) }
        await peers.1.close()
    }

    @Test("invalid deadlines never start an endpoint", arguments: [0.0, -1.0, Double.infinity, Double.nan, 61.0])
    func invalidDeadlines(timeout: Double) async throws {
        let identity = try EphemeralTLSIdentity.create()
        await #expect(throws: PinnedTLSFrameStream.Failure.invalidInput) {
            try await PinnedTLSFrameStream.connect(localPort: 12345, identity: identity, peerCertificateDER: identity.certificateDER, handshakeTimeout: timeout)
        }
        await #expect(throws: PinnedTLSFrameStream.Failure.invalidInput) {
            try await PinnedTLSFrameStream.listen(identity: identity, peerCertificateDER: identity.certificateDER, acceptTimeout: timeout)
        }
    }

    @Test("invalid certificate input fails before reserving a handshake continuation")
    func invalidPin() async throws {
        let identity = try EphemeralTLSIdentity.create()
        await #expect(throws: PinnedTLSFrameStream.Failure.invalidInput) {
            try await PinnedTLSFrameStream.connect(localPort: 12345, identity: identity, peerCertificateDER: Data([1]), handshakeTimeout: 1)
        }
    }

    @Test("silent plaintext peers time out or cancel during TLS handshake")
    func blockedHandshake() async throws {
        let identity = try EphemeralTLSIdentity.create()
        let peerIdentity = try EphemeralTLSIdentity.create()
        let peer = try RawFrameTLSPeer(identity: peerIdentity, pin: identity.certificateDER, chunks: [], finish: false, usesTLS: false)
        let port = try await peer.start()
        defer { peer.close() }
        await #expect(throws: PinnedTLSFrameStream.Failure.timedOut) {
            try await PinnedTLSFrameStream.connect(localPort: port, identity: identity, peerCertificateDER: peerIdentity.certificateDER, handshakeTimeout: 0.05)
        }
        let other = try RawFrameTLSPeer(identity: peerIdentity, pin: identity.certificateDER, chunks: [], finish: false, usesTLS: false)
        let otherPort = try await other.start()
        defer { other.close() }
        let connecting = Task { try await PinnedTLSFrameStream.connect(localPort: otherPort, identity: identity, peerCertificateDER: peerIdentity.certificateDER, handshakeTimeout: 30) }
        try await Task.sleep(for: .milliseconds(20))
        let started = ContinuousClock.now
        connecting.cancel()
        await #expect(throws: CancellationError.self) { try await connecting.value }
        #expect(started.duration(to: .now) < .seconds(1))
    }

    @Test("a second network client cannot replace the accepted stream")
    func oneClient() async throws {
        let host = try EphemeralTLSIdentity.create()
        let peer = try EphemeralTLSIdentity.create()
        let listener = try await PinnedTLSFrameStream.listen(identity: peer, peerCertificateDER: host.certificateDER, acceptTimeout: 2, handshakeTimeout: 2)
        async let connecting = PinnedTLSFrameStream.connect(localPort: listener.port, identity: host, peerCertificateDER: peer.certificateDER, handshakeTimeout: 2)
        let server = try await listener.accept()
        let client = try await connecting
        await #expect(throws: PinnedTLSFrameStream.Failure.self) {
            try await PinnedTLSFrameStream.connect(localPort: listener.port, identity: host, peerCertificateDER: peer.certificateDER, handshakeTimeout: 0.1)
        }
        try await client.writeFrame(Data([42]), timeout: 1)
        #expect(try await server.readFrame(timeout: 1) == Data([42]))
        await client.close(); await server.close(); await listener.close()
    }

    @Test("mutual pins support independent pending reads and writes after listener release")
    func duplex() async throws {
        let (client, server) = try await pair()
        let clientRead = Task { try await client.readFrame(timeout: 2) }
        let serverRead = Task { try await server.readFrame(timeout: 2) }
        try await client.writeFrame(Data("request".utf8), timeout: 2)
        #expect(try await serverRead.value == Data("request".utf8))
        try await server.writeFrame(Data("reply".utf8), timeout: 2)
        #expect(try await clientRead.value == Data("reply".utf8))
        try await client.writeFrame(Data(), timeout: 2)
        #expect(try await server.readFrame(timeout: 2) == Data())
        await client.close()
        await client.close()
        await server.close()
    }

    @Test("wrong server pin is an explicit certificate rejection")
    func wrongServerPin() async throws {
        let host = try EphemeralTLSIdentity.create()
        let peer = try EphemeralTLSIdentity.create()
        let wrong = try EphemeralTLSIdentity.create()
        let listener = try await PinnedTLSFrameStream.listen(identity: peer, peerCertificateDER: host.certificateDER, acceptTimeout: 2, handshakeTimeout: 2)
        await #expect(throws: PinnedTLSFrameStream.Failure.authenticationFailed) {
            try await PinnedTLSFrameStream.connect(localPort: listener.port, identity: host, peerCertificateDER: wrong.certificateDER, handshakeTimeout: 2)
        }
        await listener.close()
    }

    @Test("wrong client pin never yields an authenticated accepted stream")
    func wrongClientPin() async throws {
        let host = try EphemeralTLSIdentity.create()
        let peer = try EphemeralTLSIdentity.create()
        let wrong = try EphemeralTLSIdentity.create()
        let listener = try await PinnedTLSFrameStream.listen(identity: peer, peerCertificateDER: wrong.certificateDER, acceptTimeout: 2, handshakeTimeout: 2)
        let client = Task { try await PinnedTLSFrameStream.connect(localPort: listener.port, identity: host, peerCertificateDER: peer.certificateDER, handshakeTimeout: 2) }
        await #expect(throws: PinnedTLSFrameStream.Failure.authenticationFailed) { try await listener.accept() }
        if let stream = try? await client.value { await stream.close() }
        await listener.close()
    }

    @Test("TLS records may split and coalesce frame boundaries", arguments: [false, true])
    func frameBoundaries(fragmented: Bool) async throws {
        let bytes = Data([0, 0, 0, 3, 65, 66, 67, 0, 0, 0, 2, 68, 69])
        let (stream, peer) = try await rawPeer(chunks: fragmented ? bytes.map { Data([$0]) } : [bytes], finish: false)
        defer { peer.close() }
        #expect(try await stream.readFrame(timeout: 2) == Data("ABC".utf8))
        #expect(try await stream.readFrame(timeout: 2) == Data("DE".utf8))
        await stream.close()
    }

    @Test("partial header or payload EOF is a truncated frame", arguments: [Data([0, 0]), Data([0, 0, 0, 5, 65, 66])])
    func truncatedFrame(bytes: Data) async throws {
        let (stream, peer) = try await rawPeer(chunks: [bytes], finish: true)
        defer { peer.close() }
        await #expect(throws: PinnedTLSFrameStream.Failure.truncatedFrame) { try await stream.readFrame(timeout: 2) }
        await #expect(throws: PinnedTLSFrameStream.Failure.closed) { try await stream.writeFrame(Data([42]), timeout: 1) }
        await stream.close()
    }

    @Test("oversized header fails without waiting for a body")
    func oversizedFrame() async throws {
        let (stream, peer) = try await rawPeer(chunks: [Data([0, 97, 0, 1])], finish: false)
        defer { peer.close() }
        await #expect(throws: PinnedTLSFrameStream.Failure.invalidFrameLength) { try await stream.readFrame(timeout: 2) }
        await stream.close()
    }

    @Test("blocked read cancellation immediately invalidates the stream")
    func cancellation() async throws {
        let (client, server) = try await pair()
        let reading = Task { try await client.readFrame(timeout: 30) }
        try await Task.sleep(for: .milliseconds(20))
        let started = ContinuousClock.now
        reading.cancel()
        await #expect(throws: CancellationError.self) { try await reading.value }
        #expect(started.duration(to: .now) < .seconds(1))
        await #expect(throws: PinnedTLSFrameStream.Failure.closed) { try await client.writeFrame(Data([1]), timeout: 1) }
        await client.close()
        await server.close()
    }

    @Test("read and idle accept deadlines remain timeouts, never authentication failures")
    func deadlines() async throws {
        let (client, server) = try await pair()
        await #expect(throws: PinnedTLSFrameStream.Failure.timedOut) { try await client.readFrame(timeout: 0.03) }
        await client.close()
        await server.close()
        let a = try EphemeralTLSIdentity.create()
        let b = try EphemeralTLSIdentity.create()
        let listener = try await PinnedTLSFrameStream.listen(identity: a, peerCertificateDER: b.certificateDER, acceptTimeout: 0.03, handshakeTimeout: 1)
        await #expect(throws: PinnedTLSFrameStream.Failure.timedOut) { try await listener.accept() }
        await listener.close()
    }

    @Test("explicit close unblocks pending read and idle accept exactly once")
    func closePending() async throws {
        let (client, server) = try await pair()
        let reading = Task { try await client.readFrame(timeout: 30) }
        try await Task.sleep(for: .milliseconds(20))
        await client.close()
        await #expect(throws: PinnedTLSFrameStream.Failure.closed) { try await reading.value }
        await client.close()
        await server.close()
        let a = try EphemeralTLSIdentity.create()
        let b = try EphemeralTLSIdentity.create()
        let listener = try await PinnedTLSFrameStream.listen(identity: a, peerCertificateDER: b.certificateDER)
        let accepting = Task { try await listener.accept() }
        await listener.close()
        await #expect(throws: PinnedTLSFrameStream.Failure.closed) { try await accepting.value }
    }

    private func pair() async throws -> (PinnedTLSFrameStream, PinnedTLSFrameStream) {
        let host = try EphemeralTLSIdentity.create()
        let peer = try EphemeralTLSIdentity.create()
        let listener = try await PinnedTLSFrameStream.listen(identity: peer, peerCertificateDER: host.certificateDER, acceptTimeout: 2, handshakeTimeout: 2)
        async let client = PinnedTLSFrameStream.connect(localPort: listener.port, identity: host, peerCertificateDER: peer.certificateDER, handshakeTimeout: 2)
        let server = try await listener.accept()
        return try await (client, server)
    }

    private func rawPeer(chunks: [Data], finish: Bool) async throws -> (PinnedTLSFrameStream, RawFrameTLSPeer) {
        let host = try EphemeralTLSIdentity.create()
        let peer = try EphemeralTLSIdentity.create()
        let server = try RawFrameTLSPeer(identity: peer, pin: host.certificateDER, chunks: chunks, finish: finish)
        let port = try await server.start()
        do {
            let client = try await PinnedTLSFrameStream.connect(localPort: port, identity: host, peerCertificateDER: peer.certificateDER, handshakeTimeout: 2)
            return (client, server)
        } catch { server.close(); throw error }
    }
}

// Deliberately raw, mutually pinned local TLS peer to exercise malformed framing externally.
private final class RawFrameTLSPeer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "DeviceBridge.RawFrameTLS.fixture")
    private let listener: NWListener
    private let chunks: [Data]
    private let finish: Bool
    private var connection: NWConnection?

    init(identity: EphemeralTLSIdentity, pin: Data, chunks: [Data], finish: Bool, usesTLS: Bool = true) throws {
        self.chunks = chunks
        self.finish = finish
        let parameters = usesTLS ? try PinnedTLSParameters.make(identity: identity, peerCertificateDER: pin, queue: queue) : NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                listener.stateUpdateHandler = { [self] state in
                    switch state {
                    case .ready:
                        listener.stateUpdateHandler = nil
                        continuation.resume(returning: listener.port!.rawValue)
                    case .failed(let error):
                        listener.stateUpdateHandler = nil
                        continuation.resume(throwing: error)
                    default: break
                    }
                }
                listener.newConnectionHandler = { [weak self] incoming in
                    guard let self, connection == nil else { incoming.cancel(); return }
                    connection = incoming
                    listener.cancel()
                    incoming.stateUpdateHandler = { [weak self] state in
                        if case .ready = state { self?.sendChunk(0) }
                    }
                    incoming.start(queue: queue)
                }
                listener.start(queue: queue)
            }
        }
    }

    private func sendChunk(_ index: Int) {
        guard let connection else { return }
        if index == chunks.count {
            if finish {
                connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                    completion: .contentProcessed { _ in connection.cancel() })
            }
            return
        }
        connection.send(content: chunks[index], completion: .contentProcessed { [weak self] error in
            if error == nil { self?.sendChunk(index + 1) }
        })
    }

    func close() {
        queue.async { [self] in
            listener.stateUpdateHandler = nil
            listener.newConnectionHandler = nil
            listener.cancel()
            connection?.stateUpdateHandler = nil
            connection?.cancel()
            connection = nil
        }
    }
}
