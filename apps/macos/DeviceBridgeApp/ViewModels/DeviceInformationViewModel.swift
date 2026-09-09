import Combine
import DeviceBridgeCore
import Foundation

struct DeviceInformationOperation: Identifiable, Sendable {
    enum State: String, Sendable { case running, cancelling, completed, cancelled, failed }
    let id: UUID
    let origin: DeviceOperationOrigin
    let session: ConnectionSession
    let startedAt: Date
    var state: State
    var finishedAt: Date?
    var failure: OperationFailure?
    var reportID: UUID?

    var isTerminal: Bool { state == .completed || state == .cancelled || state == .failed }
}

/// One report and one most recent operation. UI and Agent use the same synchronous admission.
@MainActor
final class DeviceInformationViewModel: ObservableObject {
    @Published private(set) var report: DeviceInformationReport?
    @Published private(set) var operation: DeviceInformationOperation?
    @Published private(set) var session: ConnectionSession?
    private var device: DeviceRecord?
    private var service: (any DeviceInformationReading)?
    private var task: Task<Void, Never>?
    private var revision = 0

    init() {}
    init(device: DeviceRecord, session: ConnectionSession, service: any DeviceInformationReading) {
        bind(device: device, session: session, service: service)
    }

    var isBusy: Bool { operation.map { !$0.isTerminal } ?? false }
    var canRead: Bool { session != nil && service != nil && !isBusy }
    var isShowingPreviousReport: Bool { report != nil && operation?.reportID != report?.id }
    var statusText: String {
        switch operation?.state {
        case .running: "Reading…"
        case .cancelling: "Cancelling…"
        case .completed: report?.isPartial == true ? "Partially available" : "Read"
        case .cancelled: "Cancelled"
        case .failed: "Read failed"
        case nil: session == nil ? "Not connected" : "Not read yet"
        }
    }

    func bind(device: DeviceRecord, session: ConnectionSession, service: any DeviceInformationReading) {
        if self.session != session { invalidate() }
        self.device = device
        self.session = session
        self.service = service
    }

    /// A newly ready runner changes the next explicit read; it does not replace a visible snapshot.
    func updateService(_ service: any DeviceInformationReading) { self.service = service }

    @discardableResult
    func read(origin: DeviceOperationOrigin = .ui, operationID: UUID = UUID()) -> UUID? {
        guard canRead, let device, let session, let service else { return nil }
        let revision = revision
        operation = DeviceInformationOperation(id: operationID, origin: origin, session: session,
            startedAt: Date(), state: .running)
        task = Task { [weak self] in
            let outcome = await service.read(device: device, session: session, operationID: operationID)
            guard let self, self.revision == revision, self.session == session,
                  self.operation?.id == operationID else { return }
            self.task = nil
            self.operation?.finishedAt = Date()
            // Cancellation wins even if a provider returns a candidate after cancellation.
            if self.operation?.state == .cancelling || Task.isCancelled {
                self.operation?.state = .cancelled
                self.operation?.reportID = nil
                return
            }
            switch outcome {
            case let .report(candidate) where candidate.session == session:
                self.report = candidate
                self.operation?.state = .completed
                self.operation?.reportID = candidate.id
            case let .failure(failure):
                self.operation?.state = failure.code == .cancelled ? .cancelled : .failed
                self.operation?.failure = failure
            case .stale, .report:
                self.operation?.state = .failed
                self.operation?.failure = OperationFailure(code: .disconnected,
                    safeMessage: "The device connection changed.", recoveryAction: "Reconnect the device and refresh.")
            }
        }
        return operationID
    }

    func cancel() {
        guard isBusy, operation?.state != .cancelling else { return }
        operation?.state = .cancelling
        task?.cancel()
    }

    func invalidate() {
        revision += 1
        task?.cancel()
        task = nil
        report = nil
        operation = nil
        session = nil
        device = nil
        service = nil
    }
}
