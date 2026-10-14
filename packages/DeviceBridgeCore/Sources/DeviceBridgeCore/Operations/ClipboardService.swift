import DeviceBridgeProtocol
import Foundation
import Darwin

public protocol HelperRequestSending: Sendable {
    func send(_ request: HelperRequest) async throws -> HelperResult
}

/// Availability requires both clipboard actions negotiated for this authenticated launch.
/// This metadata query must not access the phone's clipboard or request permission.
public protocol IOSRunnerClipboardChannel: HelperRequestSending {
    func authenticatedClipboardContext() async throws -> HelperSessionContext
}

public struct ClipboardSnapshot: Sendable, Equatable {
    public let deviceIdentity: DeviceIdentity
    public let text: String
    public let capturedAt: Date
    public let sessionGeneration: Int

    public init(
        deviceIdentity: DeviceIdentity,
        text: String,
        capturedAt: Date,
        sessionGeneration: Int
    ) {
        self.deviceIdentity = deviceIdentity
        self.text = text
        self.capturedAt = capturedAt
        self.sessionGeneration = sessionGeneration
    }

    /// Validate the captured session after a save panel returns, before any disk write.
    public func saveText(to destination: URL, currentDeviceIdentity: DeviceIdentity?, currentSessionGeneration: Int) throws -> Bool {
        guard deviceIdentity == currentDeviceIdentity,
              sessionGeneration == currentSessionGeneration else { return false }
        guard destination.isFileURL else { throw CocoaError(.fileWriteUnsupportedScheme) }
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".clipboard-\(UUID().uuidString).tmp")
        // Reserve an owned sibling exclusively, so every failure can clean up safely.
        let descriptor = staging.withUnsafeFileSystemRepresentation {
            Darwin.open($0!, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer {
            try? file.close()
            _ = staging.withUnsafeFileSystemRepresentation { Darwin.unlink($0!) }
        }
        try file.write(contentsOf: Data(text.utf8))
        try file.close()
        let published = staging.withUnsafeFileSystemRepresentation { source in
            destination.withUnsafeFileSystemRepresentation { target in
                Darwin.renamex_np(source!, target!, UInt32(RENAME_EXCL))
            }
        }
        guard published == 0 else {
            if errno == EEXIST { throw CocoaError(.fileWriteFileExists) }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return true
    }
}

public enum ClipboardOperationOutcome: Sendable, Equatable {
    case snapshot(ClipboardSnapshot)
    case written(at: Date)
    case failure(OperationFailure)
    case stale

    public var snapshot: ClipboardSnapshot? {
        if case let .snapshot(snapshot) = self { return snapshot }
        return nil
    }

    public var failure: OperationFailure? {
        if case let .failure(failure) = self { return failure }
        return nil
    }
}

public enum ClipboardForegroundDisposition: String, Sendable, Equatable {
    case clipboardHostRemainsForeground
}

public actor ClipboardService {
    /// The complete current text must fit; callers must never truncate to this limit.
    public static let maximumUTF8Bytes = HelperWireCodec.maximumClipboardUTF8Bytes

    private let store: DeviceSessionStore
    private let channel: any HelperRequestSending
    private let sessionNonce: String
    private let helperDeviceID: String
    public private(set) var currentSnapshot: ClipboardSnapshot?
    public private(set) var lastForegroundDisposition: ClipboardForegroundDisposition?

    public init(
        store: DeviceSessionStore,
        channel: any HelperRequestSending,
        sessionNonce: String,
        helperDeviceID: String
    ) {
        self.store = store
        self.channel = channel
        self.sessionNonce = sessionNonce
        self.helperDeviceID = helperDeviceID
    }

    public func read(now: Date = Date()) async -> ClipboardOperationOutcome {
        lastForegroundDisposition = nil
        let token: SessionToken
        do {
            token = try await store.beginOperation(.clipboardRead)
        } catch DeviceSessionStoreError.connectionBusy {
            return .failure(OperationFailure(code: .failure, safeMessage: "Connection check in progress. Retry shortly."))
        } catch {
            return disconnectedOutcome()
        }

        let result: HelperResult
        do {
            result = try await channel.send(makeRequest(
                token: token,
                action: .clipboardRead,
                now: now,
                payload: [:]
            ))
        } catch is CancellationError {
            await store.finishOperation(token)
            return cancelledOutcome()
        } catch HostCommandError.cancelled {
            await store.finishOperation(token)
            return cancelledOutcome()
        } catch {
            await store.finishOperation(token)
            return .failure(OperationFailure(
                code: .failure,
                safeMessage: "Clipboard helper communication failed.",
                recoveryAction: "Check the device connection and retry. If the problem persists, select another device and return."
            ))
        }

        guard await canPublishAndFinish(token) else { return .stale }
        guard validate(result, for: token) else { return malformedOutcome() }
        guard result.status == .success else { return failureOutcome(for: result) }
        guard recordForegroundDisposition(from: result) else { return malformedOutcome() }
        guard let text = result.payload?["text"]?.stringValue else {
            return malformedOutcome()
        }
        guard text.utf8.count <= Self.maximumUTF8Bytes else { return tooLargeOutcome() }

        let snapshot = ClipboardSnapshot(
            deviceIdentity: token.deviceIdentity,
            text: text,
            capturedAt: result.completedAt,
            sessionGeneration: token.sessionGeneration
        )
        currentSnapshot = snapshot
        return .snapshot(snapshot)
    }

    public func write(_ text: String, now: Date = Date()) async -> ClipboardOperationOutcome {
        lastForegroundDisposition = nil
        guard text.utf8.count <= Self.maximumUTF8Bytes else { return tooLargeOutcome() }

        let token: SessionToken
        do {
            token = try await store.beginOperation(.clipboardWrite)
        } catch DeviceSessionStoreError.connectionBusy {
            return .failure(OperationFailure(code: .failure, safeMessage: "Connection check in progress. Retry shortly."))
        } catch {
            return disconnectedOutcome()
        }

        let result: HelperResult
        do {
            result = try await channel.send(makeRequest(
                token: token,
                action: .clipboardWrite,
                now: now,
                payload: ["text": .string(text)]
            ))
        } catch is CancellationError {
            await store.finishOperation(token)
            return cancelledOutcome()
        } catch HostCommandError.cancelled {
            await store.finishOperation(token)
            return cancelledOutcome()
        } catch {
            await store.finishOperation(token)
            return .failure(OperationFailure(
                code: .failure,
                safeMessage: "Clipboard helper communication failed.",
                recoveryAction: "Check the device connection and retry. If the problem persists, select another device and return."
            ))
        }

        guard await canPublishAndFinish(token) else { return .stale }
        guard validate(result, for: token) else { return malformedOutcome() }
        guard result.status == .success else { return failureOutcome(for: result) }
        guard recordForegroundDisposition(from: result) else { return malformedOutcome() }
        guard result.payload?["written"]?.boolValue == true else { return malformedOutcome() }
        return .written(at: result.completedAt)
    }

    public func clearSnapshot() {
        currentSnapshot = nil
    }

    private func makeRequest(
        token: SessionToken,
        action: HelperAction,
        now: Date,
        payload: [String: JSONValue]
    ) -> HelperRequest {
        HelperRequest(
            requestID: token.operationID,
            sessionNonce: sessionNonce,
            helperDeviceID: helperDeviceID,
            action: action,
            createdAt: now,
            expiresAt: now.addingTimeInterval(30),
            payload: payload
        )
    }

    private func canPublishAndFinish(_ token: SessionToken) async -> Bool {
        await store.finishOperation(token)
    }

    private func recordForegroundDisposition(from result: HelperResult) -> Bool {
        guard let raw = result.payload?["foregroundDisposition"]?.stringValue else { return true }
        guard let disposition = ClipboardForegroundDisposition(rawValue: raw) else { return false }
        lastForegroundDisposition = disposition
        return true
    }

    private func validate(_ result: HelperResult, for token: SessionToken) -> Bool {
        result.protocolVersion == 1
            && result.requestID == token.operationID
            && result.isStructurallyValid
    }

    private func failureOutcome(for result: HelperResult) -> ClipboardOperationOutcome {
        if result.error?.code == "clipboard.too_large" { return tooLargeOutcome() }
        let code: OperationFailureCode
        let safeMessage: String
        let recoveryAction: String?
        switch result.status {
        case .permissionDenied:
            code = .permissionDenied
            safeMessage = "Clipboard access was denied on the device."
            recoveryAction = "Review the device clipboard privacy prompt, then retry."
        case .cancelled:
            code = .cancelled
            safeMessage = "Clipboard action cancelled."
            recoveryAction = nil
        case .actionRequired:
            code = .helperMissing
            switch result.error?.code {
            case "clipboard.unavailable":
                safeMessage = "No readable text was returned by the device."
                recoveryAction = "Copy text on the device and review any paste prompt, then retry."
            case "clipboard.foreground_required":
                safeMessage = "The clipboard helper could not enter the foreground."
                recoveryAction = "Unlock the device, keep the managed helper visible, and retry."
            case "clipboard.write_unverified":
                safeMessage = "The device did not confirm the clipboard write."
                recoveryAction = "Keep the managed helper visible and retry."
            default:
                safeMessage = "The managed clipboard helper needs attention."
                recoveryAction = "Unlock the device, open the managed helper, and retry."
            }
        case .expired:
            code = .malformedOutput
            safeMessage = "The clipboard request expired."
            recoveryAction = "Check the connection and retry."
        case .invalid:
            code = .malformedOutput
            safeMessage = "The clipboard helper returned an invalid response."
            recoveryAction = "Check the device connection and retry. If the problem persists, select another device and return."
        case .failure, .success:
            code = .failure
            safeMessage = "The clipboard action failed."
            recoveryAction = "Check the device connection and retry. If the problem persists, select another device and return."
        }
        return .failure(OperationFailure(
            code: code,
            safeMessage: safeMessage,
            recoveryAction: recoveryAction
        ))
    }

    private func malformedOutcome() -> ClipboardOperationOutcome {
        .failure(OperationFailure(
            code: .malformedOutput,
            safeMessage: "The clipboard helper returned an invalid response.",
            recoveryAction: "Check the device connection and retry. If the problem persists, select another device and return."
        ))
    }

    private func tooLargeOutcome() -> ClipboardOperationOutcome {
        .failure(OperationFailure(
            code: .restricted,
            safeMessage: "Clipboard text exceeds 1 MiB (UTF-8). Nothing was truncated or transferred.",
            recoveryAction: "Use a text file to transfer larger content."
        ))
    }

    private func cancelledOutcome() -> ClipboardOperationOutcome {
        .failure(OperationFailure(code: .cancelled, safeMessage: "Clipboard action cancelled."))
    }

    private func disconnectedOutcome() -> ClipboardOperationOutcome {
        .failure(OperationFailure(
            code: .disconnected,
            safeMessage: "No active device session is available.",
            recoveryAction: "Select a command-ready device."
        ))
    }
}
