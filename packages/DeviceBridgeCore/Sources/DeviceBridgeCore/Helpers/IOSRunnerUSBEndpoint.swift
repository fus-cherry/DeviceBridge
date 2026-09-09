import Foundation
import DeviceBridgeSecureChannel

public protocol IOSRunnerUSBConnecting: Sendable {
    func connect(hardwareUDID: String, port: UInt16) async throws -> IOSUSBMuxConnection
}

public struct IOSRunnerUSBConnector: IOSRunnerUSBConnecting {
    public init() {}
    public func connect(hardwareUDID: String, port: UInt16) async throws -> IOSUSBMuxConnection {
        try await IOSUSBMuxConnection.connect(hardwareUDID: hardwareUDID, port: port)
    }
}

/// Owns the exact public-container copy → certificate validation → USB → loopback path for one
/// immutable launch. A returned endpoint is only a candidate for TLS; it never publishes readiness.
public actor IOSRunnerUSBEndpoint {
    public struct PinnedEndpoint: Sendable {
        public let port: UInt16
        public let runnerCertificateDER: Data
        init(port: UInt16, runnerCertificateDER: Data) {
            self.port = port; self.runnerCertificateDER = runnerCertificateDER
        }
    }
    private enum Phase {
        case idle
        case opening(CheckedContinuation<PinnedEndpoint, any Error>, ContinuousClock.Instant)
        case ready
        case closing(Task<Void, Never>)
        case closed
    }
    private let launch: IOSRunnerLaunch
    private let hostCertificateDER: Data
    private let helperBuild: String
    private let reader: any IOSRunnerPublicRecordReading
    private let usbConnector: any IOSRunnerUSBConnecting
    private let startupTimeout: Duration
    private var phase = Phase.idle
    private var work: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var usb: IOSUSBMuxConnection?
    private var proxy: IOSUSBLoopbackProxy?

    public init(launch: IOSRunnerLaunch, hostCertificateDER: Data, helperBuild: String,
                reader: any IOSRunnerPublicRecordReading, usb: any IOSRunnerUSBConnecting = IOSRunnerUSBConnector(),
                startupTimeout: Duration = .seconds(60)) {
        self.launch = launch
        self.hostCertificateDER = hostCertificateDER
        self.helperBuild = helperBuild
        self.reader = reader
        self.usbConnector = usb
        self.startupTimeout = startupTimeout
    }

    public func open(process: any IOSRunnerProcessOwning) async throws -> PinnedEndpoint {
        try Task.checkCancellation()
        guard case .idle = phase, startupTimeout > .zero, startupTimeout <= .seconds(60) else {
            throw IOSRunnerLaunchError.channelUnavailable
        }
        do {
            let result = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    phase = .opening(continuation, ContinuousClock.now.advanced(by: startupTimeout))
                    timer = Task {
                        do { try await Task.sleep(for: startupTimeout) }
                        catch { return }
                        await terminate(IOSRunnerLaunchError.channelUnavailable)
                    }
                    work = Task { await openOwnedRoute(process: process) }
                }
            } onCancel: { Task { await self.close() } }
            try Task.checkCancellation()
            guard case .ready = phase else { throw CancellationError() }
            return result
        } catch { await close(); throw error }
    }

    public func close() async { await terminate(CancellationError()) }

    // A deterministic test barrier for abandoned read-only copy work. Production stop never waits
    // for an injected uncooperative reader; it cancels the real owned copy process and invalidates.
    func drainOpeningWork() async { await work?.value }

    private func openOwnedRoute(process: any IOSRunnerProcessOwning) async {
        defer { work = nil }
        do {
            var publicRecord: Data
            while true {
                try await requireOpeningAndLiveChild(process)
                do { publicRecord = try await reader.read(launch: launch); break }
                catch IOSRunnerPublicRecordReader.Failure.copyUnavailable {
                    try await requireOpeningAndLiveChild(process)
                    try await Task.sleep(for: .milliseconds(300))
                }
            }
            try await requireOpeningAndLiveChild(process)
            let certificate = try PublicBootstrapRecord.validate(publicRecord, launchID: launch.id,
                hostCertificateDER: hostCertificateDER, helperBuild: helperBuild)
            let connected = try await usbConnector.connect(hardwareUDID: launch.deviceIdentifier, port: 49872)
            do { try requireOpening() }
            catch { await connected.close(); throw error }
            usb = connected
            try await requireOpeningAndLiveChild(process)
            let listening = try await IOSUSBLoopbackProxy.listen(usb: connected)
            do { try requireOpening() }
            catch { await listening.close(); throw error }
            proxy = listening
            try await requireOpeningAndLiveChild(process)
            guard let port = await listening.port else { throw IOSRunnerLaunchError.channelUnavailable }
            try await requireOpeningAndLiveChild(process)
            guard case let .opening(continuation, _) = phase else { throw CancellationError() }
            timer?.cancel(); timer = nil
            phase = .ready
            continuation.resume(returning: PinnedEndpoint(port: port, runnerCertificateDER: certificate))
        } catch {
            await terminate(error is CancellationError ? CancellationError() : IOSRunnerLaunchError.channelUnavailable)
        }
    }

    private func requireOpeningAndLiveChild(_ process: any IOSRunnerProcessOwning) async throws {
        try requireOpening()
        guard await process.exitStatus() == nil else { throw IOSRunnerLaunchError.channelUnavailable }
        try requireOpening()
    }

    private func requireOpening() throws {
        try Task.checkCancellation()
        guard case let .opening(_, deadline) = phase else { throw CancellationError() }
        guard ContinuousClock.now < deadline else { throw IOSRunnerLaunchError.channelUnavailable }
    }

    private func terminate(_ error: any Error) async {
        let continuation: CheckedContinuation<PinnedEndpoint, any Error>?
        switch phase {
        case .closed: return
        case let .closing(cleanup): await cleanup.value; return
        case let .opening(pending, _): continuation = pending
        default: continuation = nil
        }
        work?.cancel()
        timer?.cancel(); timer = nil
        let oldProxy = proxy; proxy = nil
        let oldUSB = usb; usb = nil
        let cleanup = Task {
            async let proxyClosed: Void? = oldProxy?.close()
            await oldUSB?.close()
            _ = await proxyClosed
            continuation?.resume(throwing: error)
        }
        phase = .closing(cleanup) // Invalidate before any cleanup await or late copy can return.
        await cleanup.value
        phase = .closed
    }

    deinit {
        work?.cancel(); timer?.cancel()
        let oldProxy = proxy
        let oldUSB = usb
        Task { await oldProxy?.close(); await oldUSB?.close() }
    }
}
