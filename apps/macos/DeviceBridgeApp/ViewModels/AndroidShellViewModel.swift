import Combine
import DeviceBridgeCore
import Foundation

struct AndroidShellOperation: Identifiable, Sendable {
    enum Phase: String, Sendable { case running, cancelling, draining }
    let id: UUID
    let origin: DeviceOperationOrigin
    let session: ConnectionSession
    let command: String
    let startedAt: Date
    var phase: Phase
}

/// Owns the current execution and bounded session history. Changing panes never changes this owner.
@MainActor
final class AndroidShellViewModel: ObservableObject {
    @Published var command = ""
    @Published private(set) var history = AndroidShellHistory()
    @Published private(set) var selectedResultID: UUID?
    @Published private(set) var pageIndex = 0
    @Published private(set) var failure: OperationFailure?
    @Published private(set) var session: ConnectionSession?
    @Published private var active: AndroidShellOperation?
    private var service: (any AndroidShellExecuting)?
    private var task: Task<Void, Never>?

    var currentOperation: AndroidShellOperation? {
        active?.session == session && active?.phase != .draining ? active : nil
    }
    var isBusy: Bool { active != nil }
    var canRun: Bool { session != nil && service != nil && !isBusy && AndroidShellInput.validate(command) == nil }
    var selectedResult: AndroidShellExecution? { history.entries.first { $0.id == selectedResultID } }
    var outputPage: AndroidShellOutputPage? { selectedResult.map { .init(execution: $0, index: pageIndex) } }
    var statusText: String {
        if let active {
            switch active.phase {
            case .running: return "Running…"
            case .cancelling: return "Cancelling…"
            case .draining: return "Cleaning up…"
            }
        }
        return session == nil ? "Not connected" : "Ready"
    }

    func bind(session: ConnectionSession, service: any AndroidShellExecuting) {
        if self.session != session { invalidate() }
        self.session = session
        self.service = service
    }

    @discardableResult
    func run(origin: DeviceOperationOrigin = .ui, operationID: UUID = UUID(), command suppliedCommand: String? = nil) -> UUID? {
        guard !isBusy, let session, let service else { return nil }
        let originalCommand = suppliedCommand ?? command
        if let invalid = AndroidShellInput.validate(originalCommand) { failure = invalid; return nil }
        let operation = AndroidShellOperation(id: operationID, origin: origin, session: session,
            command: originalCommand, startedAt: Date(), phase: .running)
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        active = operation
        failure = nil
        task = Task { [weak self] in
            let outcome = await service.run(command: originalCommand, session: session, operationID: operationID,
                origin: origin, startedAt: operation.startedAt, deadline: deadline)
            guard let self, self.active?.id == operationID else { return }
            let phase = self.active?.phase
            // The executor only returns after socket cleanup. Even an invalidated session holds this slot until now.
            self.active = nil
            self.task = nil
            guard self.session == session, phase != .draining else { return }
            guard case let .execution(candidate) = outcome, candidate.session == session,
                  candidate.id == operationID else {
                self.failure = OperationFailure(code: .disconnected, safeMessage: "The device connection changed.")
                return
            }
            let result: AndroidShellExecution
            if phase == .cancelling || Task.isCancelled {
                result = AndroidShellExecution(id: candidate.id, origin: candidate.origin, session: candidate.session,
                    command: candidate.command, startedAt: candidate.startedAt, finishedAt: candidate.finishedAt,
                    stdout: candidate.stdout, stderr: candidate.stderr, completion: .cancelled,
                    outputTruncated: candidate.outputTruncated)
            } else { result = candidate }
            self.history.append(result)
            self.selectedResultID = result.id
            self.pageIndex = 0
        }
        return operationID
    }

    func cancel() {
        guard active != nil, active?.phase == .running else { return }
        active?.phase = .cancelling
        task?.cancel()
    }

    func selectResult(_ id: UUID) {
        guard history.entries.contains(where: { $0.id == id }) else { return }
        selectedResultID = id
        pageIndex = 0
    }
    func fillFromHistory(_ id: UUID) {
        guard !isBusy, let result = history.entries.first(where: { $0.id == id }) else { return }
        command = result.command
    }
    func setPage(_ index: Int) {
        guard let result = selectedResult else { return }
        pageIndex = AndroidShellOutputPage(execution: result, index: index).index
    }
    func clearHistory() { history.clear(); selectedResultID = nil; pageIndex = 0 }

    func setUnavailable(_ message: String) {
        invalidate()
        failure = OperationFailure(code: .unsupported, safeMessage: message)
    }

    func invalidate() {
        if active != nil { active?.phase = .draining; task?.cancel() }
        // Keep only the resource owner until cleanup; no old device content is exposed by currentOperation.
        session = nil
        service = nil
        command = ""
        failure = nil
        clearHistory()
    }
}
