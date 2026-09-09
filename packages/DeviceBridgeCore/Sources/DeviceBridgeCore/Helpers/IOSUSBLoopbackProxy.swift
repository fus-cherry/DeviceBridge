import Foundation
import Network

/// One host-loopback client relayed to one already selected USB stream. Bytes must be authenticated
/// by the caller's TLS layer; this proxy does not itself authorize device-content requests.
public actor IOSUSBLoopbackProxy {
    public enum Failure: Sendable, Equatable {
        case listener, stream(Int32?), hostToUSB, usbToHost, usbRead(IOSUSBMuxConnection.Failure)
        case usbWrite(IOSUSBMuxConnection.Failure), usbFinishWriting(IOSUSBMuxConnection.Failure), timeout
    }
    public enum Completion: Sendable, Equatable { case clean, cancelled, failed(Failure) }
    public private(set) var port: UInt16?
    private enum Phase { case starting, listening, relaying, closing, closed(Completion) }
    private enum Direction: Hashable { case hostToUSB, usbToHost }
    private var phase = Phase.starting
    private let usb: IOSUSBMuxConnection
    private let listener: NWListener
    private var connection: NWConnection?
    private let networkQueue = DispatchQueue(label: "DeviceBridge.USBLoopback")
    private let startupTimeout: Duration
    private let teardownTimeout: Duration
    private let usbReadTimeout: TimeInterval
    private var startup: CheckedContinuation<Void, any Error>?
    private var completions: [CheckedContinuation<Completion, Never>] = []
    private var pumps: [Task<Void, Never>] = []
    private var ended: Set<Direction> = []
    private var timer: Task<Void, Never>?
    private var timerID: UUID?
    private var firstStreamFailure: Failure?
    private var drainStarted = false

    private init(usb: IOSUSBMuxConnection, listener: NWListener, startupTimeout: Duration, teardownTimeout: Duration,
                 usbReadTimeout: TimeInterval) {
        self.usb = usb
        self.listener = listener
        self.startupTimeout = startupTimeout
        self.teardownTimeout = teardownTimeout
        self.usbReadTimeout = usbReadTimeout
    }

    public static func listen(usb: IOSUSBMuxConnection, startupTimeout: Duration = .seconds(10),
                              teardownTimeout: Duration = .seconds(5), usbReadTimeout: TimeInterval = 35) async throws -> IOSUSBLoopbackProxy {
        do {
            try Task.checkCancellation()
            guard startupTimeout > .zero, startupTimeout <= .seconds(60),
                  teardownTimeout > .zero, teardownTimeout <= .seconds(30),
                  usbReadTimeout.isFinite, usbReadTimeout > 0, usbReadTimeout <= 60 else { throw IOSRunnerLaunchError.channelUnavailable }
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            let listener = try NWListener(using: parameters, on: .any)
            let proxy = IOSUSBLoopbackProxy(usb: usb, listener: listener, startupTimeout: startupTimeout,
                                           teardownTimeout: teardownTimeout, usbReadTimeout: usbReadTimeout)
            do {
                try await withTaskCancellationHandler {
                    try await proxy.begin()
                } onCancel: { Task { await proxy.close() } }
                try Task.checkCancellation()
                return proxy
            } catch { await proxy.close(); throw error }
        } catch { await usb.close(); throw error }
    }

    public func close() async {
        await terminate(.cancelled)
        _ = await waitForCompletion()
    }

    public func waitForCompletion() async -> Completion {
        if case let .closed(result) = phase { return result }
        return await withCheckedContinuation { completions.append($0) }
    }

    private func begin() async throws {
        guard case .starting = phase else { throw IOSRunnerLaunchError.channelUnavailable }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: Task { await self.listenerReady() }
            case .failed: Task { await self.terminate(.failed(.listener)) }
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            Task { await self.accept(connection) }
        }
        scheduleTimeout(startupTimeout)
        listener.start(queue: networkQueue)
        try await withCheckedThrowingContinuation { startup = $0 }
    }

    private func listenerReady() {
        guard case .starting = phase, let bound = listener.port, bound.rawValue > 0 else { return }
        port = bound.rawValue
        phase = .listening
        scheduleTimeout(startupTimeout)
        startup?.resume()
        startup = nil
    }

    private func accept(_ incoming: NWConnection) {
        guard case .listening = phase, connection == nil else { incoming.cancel(); return }
        phase = .relaying
        connection = incoming
        listener.cancel() // Exactly one loopback client; no later peer can replace it.
        incoming.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: Task { await self.startPumps() }
            case let .failed(error):
                let code: Int32? = if case let .posix(value) = error { value.rawValue } else { nil }
                Task { await self.streamFailed(.stream(code)) }
            default: break
            }
        }
        incoming.start(queue: networkQueue)
    }

    private func startPumps() {
        guard case .relaying = phase, pumps.isEmpty, let connection else { return }
        timer?.cancel(); timerID = nil
        pumps = [
            Task { await forwardHostToUSB(connection) },
            Task { await forwardUSBToHost(connection) },
        ]
    }

    private func streamFailed(_ failure: Failure) async {
        guard case .relaying = phase else { return }
        guard !pumps.isEmpty else { await terminate(.failed(failure)); return }
        // State updates and I/O callbacks arrive independently. Only the two error-free
        // EOF → opposite write-close barriers can establish a clean relay completion.
        // A state failure never suppresses an operation error or grants extra drain time.
        if firstStreamFailure == nil { firstStreamFailure = failure }
        beginDrain()
    }

    private func beginDrain() {
        guard !drainStarted else { return }
        drainStarted = true
        scheduleTimeout(teardownTimeout)
    }

    private func forwardHostToUSB(_ connection: NWConnection) async {
        do {
            while true {
                try Task.checkCancellation()
                let chunk = try await Self.receive(connection)
                if let data = chunk.data, !data.isEmpty {
                    do { try await usb.write(data, timeout: 30) }
                    catch let failure as IOSUSBMuxConnection.Failure {
                        await terminate(.failed(.usbWrite(failure))); return
                    }
                }
                if chunk.end {
                    do { try await usb.finishWriting() }
                    catch let failure as IOSUSBMuxConnection.Failure {
                        await terminate(.failed(.usbFinishWriting(failure))); return
                    }
                    await directionEnded(.hostToUSB)
                    return
                }
                guard chunk.data?.isEmpty == false else { throw IOSRunnerLaunchError.channelUnavailable }
            }
        } catch { await terminate(.failed(.hostToUSB)) }
    }

    private func forwardUSBToHost(_ connection: NWConnection) async {
        do {
            while true {
                try Task.checkCancellation()
                // The transport read deadline must outlast the runner's 30-second idle lease.
                // Otherwise the host can close first and hide the peer's orderly lease exit.
                guard let data = try await usb.readChunk(maxBytes: 16_384, timeout: usbReadTimeout) else {
                    try await Self.send(nil, over: connection, final: true)
                    await directionEnded(.usbToHost)
                    return
                }
                try await Self.send(data, over: connection)
            }
        } catch let failure as IOSUSBMuxConnection.Failure {
            await terminate(.failed(.usbRead(failure)))
        } catch { await terminate(.failed(.usbToHost)) }
    }

    private func directionEnded(_ direction: Direction) async {
        guard case .relaying = phase else { return }
        ended.insert(direction)
        if ended.count == 2 { await terminate(.clean) }
        else { beginDrain() }
    }

    private func scheduleTimeout(_ duration: Duration) {
        timer?.cancel()
        let id = UUID()
        timerID = id
        timer = Task {
            do { try await Task.sleep(for: duration); await expire(id) }
            catch { }
        }
    }

    private func expire(_ id: UUID) async {
        guard timerID == id else { return }
        await terminate(.failed(firstStreamFailure ?? .timeout))
    }

    private func terminate(_ result: Completion) async {
        switch phase { case .closing, .closed: return; default: break }
        phase = .closing // Invalidate before any resource cleanup suspends.
        timer?.cancel(); timer = nil; timerID = nil
        startup?.resume(throwing: IOSRunnerLaunchError.channelUnavailable); startup = nil
        listener.cancel()
        connection?.cancel()
        for task in pumps { task.cancel() }
        await usb.close()
        connection = nil
        pumps.removeAll()
        phase = .closed(result)
        let pending = completions; completions.removeAll()
        for continuation in pending { continuation.resume(returning: result) }
    }

    private struct Read: Sendable { let data: Data?; let end: Bool }

    private static func receive(_ connection: NWConnection) async throws -> Read {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, end, error in
                if error != nil { continuation.resume(throwing: IOSRunnerLaunchError.channelUnavailable) }
                else { continuation.resume(returning: Read(data: data, end: end)) }
            }
        }
    }

    private static func send(_ data: Data?, over connection: NWConnection, final: Bool = false) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, contentContext: final ? .finalMessage : .defaultMessage, isComplete: true,
                completion: .contentProcessed { error in
                    if error != nil { continuation.resume(throwing: IOSRunnerLaunchError.channelUnavailable) }
                    else { continuation.resume() }
                })
        }
    }
}
