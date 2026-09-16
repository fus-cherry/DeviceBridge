import UIKit
import XCTest
import DeviceBridgeProtocol
import DeviceBridgeSecureChannel

@MainActor
protocol RunnerForegroundControlling: AnyObject {
    func isRunnerForeground() -> Bool
}

@MainActor
final class XCTestRunnerForegroundController: RunnerForegroundControlling {
    private static let runnerID = "dev.debugutility.DeviceBridgeRunnerUITests.xctrunner"
    private let runner = XCUIApplication(bundleIdentifier: runnerID)

    func isRunnerForeground() -> Bool {
        Self.permitsClipboard(bundleIdentifier: Bundle.main.bundleIdentifier,
            applicationState: UIApplication.shared.applicationState, runnerState: runner.state)
    }

    static func permitsClipboard(bundleIdentifier: String?, applicationState: UIApplication.State,
                                 runnerState: XCUIApplication.State) -> Bool {
        bundleIdentifier == runnerID && applicationState == .active && runnerState == .runningForeground
    }

}

/// One MainActor operation owns admission and publication. The host activates the existing runner
/// only for an explicit request; this adapter neither switches to Home nor approves prompts.
@MainActor
final class RunnerClipboardHandler: IOSRunnerClipboardHandling {
    private let commands: ClipboardCommands
    private let foreground: any RunnerForegroundControlling
    private var operationID: UUID?

    init(commands: ClipboardCommands = ClipboardCommands(),
         foreground: any RunnerForegroundControlling = XCTestRunnerForegroundController()) {
        self.commands = commands
        self.foreground = foreground
    }

    func handle(_ request: HelperRequest) async -> HelperResult {
        guard operationID == nil else {
            return failure(request, .failure, "clipboard.busy", "Another clipboard action is still active.")
        }
        let id = UUID()
        operationID = id
        let remaining = request.expiresAt.timeIntervalSinceNow
        let seconds = remaining.isFinite ? max(0, min(30, remaining)) : 0
        let context = ClipboardAccessContext(expiresAt: request.expiresAt,
            deadline: ContinuousClock.now.advanced(by: .seconds(seconds)), isForeground: { [weak self] in
                guard let self, self.operationID == id else { return false }
                return self.foreground.isRunnerForeground()
            })
        // An OS read can remain suspended after cancellation. Its independent deadline still
        // invalidates ownership without joining that read's eventual return.
        let expiry = Task { @MainActor [weak self] in
            do { try await Task.sleep(until: context.deadline, clock: .continuous) }
            catch { return }
            self?.finish(id)
        }
        defer { expiry.cancel(); finish(id) }
        return await withTaskCancellationHandler {
            do {
                // CoreDevice launch completion precedes the visible foreground transition.
                // Wait only for that state (never activate or approve anything), within both
                // the original request budget and a short settlement bound.
                let settlement = min(context.deadline, ContinuousClock.now.advanced(by: .seconds(2)))
                while !context.isForeground() {
                    try context.check()
                    guard ContinuousClock.now < settlement else { throw ClipboardAccessError.notForeground }
                    try await Task.sleep(for: .milliseconds(50))
                }
                try await context.authorize()
                let result: ClipboardCommandResult
                switch request.action {
                case .clipboardRead where request.payload.isEmpty:
                    result = await commands.read(context: context)
                case .clipboardWrite:
                    guard case .string(let text) = request.payload["text"],
                          Set(request.payload.keys).isSubset(of: ["text", "sensitive"]),
                          request.payload["sensitive"] == nil || request.payload["sensitive"]?.boolValue != nil else {
                        return failure(request, .invalid, "clipboard.invalid", "The clipboard request is invalid.")
                    }
                    result = await commands.write(text, context: context)
                default:
                    return failure(request, .invalid, "clipboard.invalid", "The clipboard request is invalid.")
                }
                try await context.authorize()
                guard operationID == id else { throw CancellationError() }
                return map(result, request: request)
            } catch is CancellationError {
                return failure(request, .cancelled, "clipboard.interrupted", "Clipboard access was interrupted.")
            } catch ClipboardAccessError.expired {
                return failure(request, .expired, "clipboard.expired", "The clipboard request expired.")
            } catch {
                return failure(request, .actionRequired, "clipboard.foreground_required", "Keep the managed runner visible to access the clipboard.")
            }
        } onCancel: {
            // Task.cancel() calls this synchronously on the server's executor. Only enqueue
            // ownership cleanup here.
            Task { @MainActor [weak self] in self?.finish(id) }
        }
    }

    private func finish(_ id: UUID) {
        guard operationID == id else { return }
        operationID = nil
    }

    private func map(_ result: ClipboardCommandResult, request: HelperRequest) -> HelperResult {
        if result.status == .success {
            let payload: [String: JSONValue]
            if request.action == .clipboardRead {
                guard let text = result.text else {
                    return failure(request, .invalid, "clipboard.invalid", "The clipboard response is invalid.")
                }
                payload = [
                    "text": .string(text),
                    "foregroundDisposition": .string("runnerRemainsForeground"),
                ]
            } else {
                payload = [
                    "written": .bool(true),
                    "foregroundDisposition": .string("runnerRemainsForeground"),
                ]
            }
            return HelperResult(requestID: request.requestID, status: .success, completedAt: Date(), payload: payload)
        }
        // Only fixed local messages cross the wire, never an OS error or rejected content.
        switch result.status {
        case .permissionDenied:
            return failure(request, .permissionDenied, "clipboard.denied", "Clipboard access was denied on the device.")
        case .cancelled:
            return failure(request, .cancelled, "clipboard.interrupted", "Clipboard access was interrupted.")
        case .expired:
            return failure(request, .expired, "clipboard.expired", "The clipboard request expired.")
        case .actionRequired:
            return failure(request, .actionRequired, "clipboard.unavailable", "Keep the runner visible and confirm any paste prompt on the device.")
        case .failure, .invalid:
            let status: HelperResultStatus = result.status == .invalid ? .invalid : .failure
            if result.code == "clipboard.too_large" {
                return failure(request, status, "clipboard.too_large", "Clipboard text exceeds 1 MiB (UTF-8). Nothing was truncated or transferred.")
            }
            if result.code == "clipboard.write_unverified" {
                return failure(request, status, "clipboard.write_unverified", "The clipboard write could not be verified.")
            }
            return failure(request, status, "clipboard.failed", "The clipboard action failed.")
        case .success:
            return failure(request, .invalid, "clipboard.invalid", "The clipboard response is invalid.")
        }
    }

    private func failure(_ request: HelperRequest, _ status: HelperResultStatus,
                         _ code: String, _ message: String) -> HelperResult {
        HelperResult(requestID: request.requestID, status: status, completedAt: Date(),
            error: HelperErrorPayload(code: code, message: message))
    }
}

enum ClipboardCommandStatus: String, Sendable {
    case success
    case actionRequired
    case permissionDenied
    case cancelled
    case invalid
    case failure
    case expired
}

enum ClipboardAccessError: Error {
    case denied
    case interrupted
    case tooLarge
    case expired
    case notForeground
    case unverified
}

struct ClipboardAccessContext: Sendable {
    let expiresAt: Date
    let deadline: ContinuousClock.Instant
    let isForeground: @MainActor @Sendable () -> Bool

    init(expiresAt: Date = Date().addingTimeInterval(30),
         deadline: ContinuousClock.Instant = .now.advanced(by: .seconds(30)),
         isForeground: @escaping @MainActor @Sendable () -> Bool = { true }) {
        self.expiresAt = expiresAt
        self.deadline = deadline
        self.isForeground = isForeground
    }

    func check() throws {
        try Task.checkCancellation()
        guard Date() < expiresAt, ContinuousClock.now < deadline else { throw ClipboardAccessError.expired }
    }

    func authorize() async throws {
        try check()
        guard await isForeground() else { throw ClipboardAccessError.notForeground }
        // Actor queueing and the foreground query consume the same captured budget.
        try check()
    }
}

struct ClipboardCommandResult: Sendable {
    let status: ClipboardCommandStatus
    let text: String?
    let code: String?
    let safeMessage: String?

    static func success(text: String? = nil) -> ClipboardCommandResult {
        ClipboardCommandResult(status: .success, text: text, code: nil, safeMessage: nil)
    }

    static func cancelled() -> ClipboardCommandResult {
        ClipboardCommandResult(status: .cancelled, text: nil, code: "clipboard.interrupted",
            safeMessage: "Clipboard access was interrupted.")
    }
}

protocol ClipboardAccessing: AnyObject, Sendable {
    func readTextValue(context: ClipboardAccessContext) async throws -> String?
    func writeTextValue(_ text: String, context: ClipboardAccessContext) async throws
}

/// A nil revision means the setter did not run. The expected revision belongs to this setter,
/// not an arbitrary later value read from a pasteboard another application may have changed.
struct ClipboardSystemWriteReceipt: Sendable {
    let expectedChangeCount: Int?
    let failure: (any Error)?
}

/// UIKit declares UIPasteboard Sendable. This actor serializes OS access away from the main
/// actor so an OS paste-permission wait cannot block XCTest's main run loop.
actor SystemClipboardAccessor: ClipboardAccessing {
    private let pasteboard: UIPasteboard

    init(pasteboard: UIPasteboard = .general) { self.pasteboard = pasteboard }

    func readTextValue(context: ClipboardAccessContext) async throws -> String? {
        try await context.authorize()
        try context.check()
        let strings = pasteboard.strings
        try context.check()
        guard let strings else { return nil }
        return try ClipboardCommands.combineTextItems(strings)
    }

    func writeTextValue(_ text: String, context: ClipboardAccessContext) async throws {
        try await context.authorize()
        let receipt = Self.performSystemWrite(text, pasteboard: pasteboard, context: context)
        if let failure = receipt.failure { throw failure }
    }

    /// The caller authorizes foreground before entering this synchronous OS boundary. Keep the
    /// setter/readback sequence free of awaits; preserve deadline checks on both sides of I/O.
    nonisolated static func performSystemWrite(_ text: String, pasteboard: UIPasteboard,
                                               context: ClipboardAccessContext) -> ClipboardSystemWriteReceipt {
        let before: Int
        do {
            try context.check()
            before = pasteboard.changeCount
            guard before < Int.max else { throw ClipboardAccessError.unverified }
            try context.check()
        } catch { return ClipboardSystemWriteReceipt(expectedChangeCount: nil, failure: error) }
        // UIKit provides no atomic foreground-check-and-set. A user/OS transition can occur
        // after the MainActor check; cancellation cannot undo an already-started setter.
        // Local-only writes keep the explicit phone action off other devices via Handoff.
        pasteboard.setItems([[UIPasteboard.typeAutomatic: text]], options: [.localOnly: true])
        do {
            try context.check()
            let matches = pasteboard.strings == [text]
            try context.check()
            guard matches else { throw ClipboardAccessError.unverified }
            return ClipboardSystemWriteReceipt(expectedChangeCount: before + 1, failure: nil)
        } catch { return ClipboardSystemWriteReceipt(expectedChangeCount: before + 1, failure: error) }
    }
}

/// Narrow command surface used by the managed XCUITest runner. The transport layer owns
/// nonce/envelope validation. UI-facing orchestration stays on the main actor; the system
/// accessor owns serialized pasteboard I/O independently.
@MainActor
final class ClipboardCommands {
    nonisolated static let maximumUTF8Bytes = 1_048_576

    nonisolated static func combineTextItems(_ items: [String]) throws -> String? {
        // No returned items is unavailable content, not an explicitly copied empty string.
        guard !items.isEmpty else { return nil }
        var result = ""
        var bytes = 0
        for (index, text) in items.enumerated() {
            let separatorBytes = index == 0 ? 0 : 1
            let textBytes = text.utf8.count
            guard textBytes <= maximumUTF8Bytes - bytes - separatorBytes else {
                throw ClipboardAccessError.tooLarge
            }
            if index > 0 { result.append("\n") }
            result.append(text)
            bytes += textBytes + separatorBytes
        }
        return result
    }

    private let clipboard: any ClipboardAccessing

    init(clipboard: any ClipboardAccessing = SystemClipboardAccessor()) {
        self.clipboard = clipboard
    }

    func read(context: ClipboardAccessContext = ClipboardAccessContext()) async -> ClipboardCommandResult {
        do {
            try await context.authorize()
            let value = try await clipboard.readTextValue(context: context)
            // Dismissing an iOS paste prompt can return the OS value before UIKit has
            // published active state. Hold the candidate locally until the same owner
            // is foreground again; never activate an app or repeat the system read.
            let publicationDeadline = min(context.deadline, ContinuousClock.now.advanced(by: .seconds(2)))
            while !context.isForeground() {
                try context.check()
                guard ContinuousClock.now < publicationDeadline else { throw ClipboardAccessError.notForeground }
                try await Task.sleep(for: .milliseconds(50))
            }
            try await context.authorize()
            guard let text = value else {
                return ClipboardCommandResult(
                    status: .actionRequired,
                    text: nil,
                    code: "clipboard.unavailable",
                    safeMessage: "No readable text is available. Keep the runner visible and confirm any paste prompt."
                )
            }
            guard text.utf8.count <= Self.maximumUTF8Bytes else {
                return ClipboardCommandResult(
                    status: .failure,
                    text: nil,
                    code: "clipboard.too_large",
                    safeMessage: "Clipboard text exceeds 1 MiB (UTF-8). Nothing was truncated or transferred."
                )
            }
            return .success(text: text)
        } catch is CancellationError {
            return .cancelled()
        } catch ClipboardAccessError.expired {
            return ClipboardCommandResult(status: .expired, text: nil, code: "clipboard.expired",
                safeMessage: "The clipboard request expired.")
        } catch ClipboardAccessError.notForeground {
            return ClipboardCommandResult(status: .actionRequired, text: nil, code: "clipboard.foreground_required",
                safeMessage: "Keep the managed runner visible to access the clipboard.")
        } catch ClipboardAccessError.tooLarge {
            return ClipboardCommandResult(status: .failure, text: nil, code: "clipboard.too_large",
                safeMessage: "Clipboard text exceeds 1 MiB (UTF-8). Nothing was truncated or transferred.")
        } catch ClipboardAccessError.denied {
            return ClipboardCommandResult(
                status: .permissionDenied,
                text: nil,
                code: "clipboard.denied",
                safeMessage: "Clipboard access was denied on the device."
            )
        } catch ClipboardAccessError.interrupted {
            return ClipboardCommandResult(
                status: .cancelled,
                text: nil,
                code: "clipboard.interrupted",
                safeMessage: "Clipboard access was interrupted."
            )
        } catch {
            return ClipboardCommandResult(
                status: .failure,
                text: nil,
                code: "clipboard.read_failed",
                safeMessage: "Clipboard text could not be read."
            )
        }
    }

    func write(_ text: String, context: ClipboardAccessContext = ClipboardAccessContext()) async -> ClipboardCommandResult {
        guard !Task.isCancelled else { return .cancelled() }
        guard text.utf8.count <= Self.maximumUTF8Bytes else {
            return ClipboardCommandResult(
                status: .invalid,
                text: nil,
                code: "clipboard.too_large",
                safeMessage: "Clipboard text exceeds 1 MiB (UTF-8). Nothing was truncated or transferred."
            )
        }
        do {
            try await context.authorize()
            try await clipboard.writeTextValue(text, context: context)
            try await context.authorize()
            return .success()
        } catch is CancellationError {
            // Cancellation does not prove that an already-started system setter was undone.
            return .cancelled()
        } catch ClipboardAccessError.expired {
            return ClipboardCommandResult(status: .expired, text: nil, code: "clipboard.expired",
                safeMessage: "The clipboard request expired.")
        } catch ClipboardAccessError.notForeground {
            return ClipboardCommandResult(status: .actionRequired, text: nil, code: "clipboard.foreground_required",
                safeMessage: "Keep the managed runner visible to access the clipboard.")
        } catch ClipboardAccessError.unverified {
            return ClipboardCommandResult(status: .failure, text: nil, code: "clipboard.write_unverified",
                safeMessage: "The clipboard write could not be verified.")
        } catch ClipboardAccessError.denied {
            return ClipboardCommandResult(
                status: .permissionDenied,
                text: nil,
                code: "clipboard.denied",
                safeMessage: "Clipboard access was denied on the device."
            )
        } catch ClipboardAccessError.interrupted {
            return ClipboardCommandResult(
                status: .cancelled,
                text: nil,
                code: "clipboard.interrupted",
                safeMessage: "Clipboard access was interrupted."
            )
        } catch {
            return ClipboardCommandResult(
                status: .failure,
                text: nil,
                code: "clipboard.write_failed",
                safeMessage: "Clipboard text could not be written."
            )
        }
    }
}
