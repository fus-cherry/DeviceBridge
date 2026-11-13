import DeviceBridgeProtocol
import Foundation

public struct HarmonyClipboardCapabilities: Equatable, Sendable {
    public let canRead: Bool
    public let canWrite: Bool
    public let maximumWriteUTF8Bytes: Int
}

/// A local v1 adapter for a captured, authorized HDC route. The nonce and device
/// ID bind local requests only: testhelper is NOT an encrypted/authenticated helper
/// handshake and does not cryptographically attest the remote device or its text.
/// Construction and device selection perform no commands or clipboard reads.
/// The fixed encoding probe was verified on HarmonyOS 7 / HDC 3.2.0f /
/// testhelper 1.0.1. This is not a compatibility promise for unknown versions.
/// Base64 in HDC argv is shell-safety encoding, NOT secrecy. Never log command
/// arguments, clipboard bodies, or raw device failure output.
public actor HarmonyClipboardChannel: HelperRequestSending {
    /// Conservative CLIENT limits, not claims about every HDC/testhelper version.
    /// Complete values must fit; neither reads nor writes are ever truncated.
    public static let maximumWriteUTF8Bytes = 2_048
    public static let maximumReadUTF8Bytes = HelperWireCodec.maximumClipboardUTF8Bytes
    public static let maximumShellCommandUTF8Bytes = 4_096
    public static let maximumOperationDuration: Duration = .seconds(10)
    private static let maximumAdmittedRequests = 4_096
    private static let readPrefix = Data("Pasteboard text: ".utf8)
    private static let writeAcknowledgment = Data("Pasteboard text set successfully.\n".utf8)
    static let encodingProbeText = "DeviceBridge HDC encoding probe: '\" $() ` ; \\ \n\n\r\n"
    static var encodingProbeCommand: String {
        encodedAssignment(encodingProbeText) + "; printf '%s' \"$DB_CLIPBOARD_TEXT\""
    }

    public enum Failure: Error, Equatable, Sendable {
        case invalidBinding
        case invalidRequest
        case replayedRequest
        case requestLimitReached
        case expiredRequest
        case staleSession
        case busy
        case unsupported
        case readTooLarge
        case textTooLarge
        case containsNUL
        case malformedOutput
        case commandFailed
        case deadlineExceeded
        /// The write was dispatched, but its final state cannot be confirmed.
        /// Cancellation, lost output, and an invalid acknowledgment never imply rollback.
        case writeUnconfirmed

        public var operationFailure: OperationFailure {
            switch self {
            case .invalidBinding, .staleSession:
                .init(code: .disconnected, safeMessage: "The captured HarmonyOS session is no longer available.",
                      recoveryAction: "Select the device again. An already dispatched write may have reached the previous device; check it before retrying.")
            case .invalidRequest, .replayedRequest, .requestLimitReached:
                .init(code: .malformedOutput, safeMessage: "The HarmonyOS clipboard request was rejected.",
                      recoveryAction: "Use Retry clipboard setup before starting a new action.")
            case .expiredRequest, .deadlineExceeded:
                .init(code: .timeout, safeMessage: "The HarmonyOS clipboard action exceeded its deadline.")
            case .busy:
                .init(code: .restricted, safeMessage: "A HarmonyOS clipboard action is already in progress.")
            case .unsupported:
                .init(code: .unsupported, safeMessage: "This HDC/testhelper combination does not support the requested clipboard action.",
                      recoveryAction: "Use the tested testhelper commands or transfer a text file instead.")
            case .readTooLarge:
                .init(code: .restricted, safeMessage: "HarmonyOS clipboard text exceeds 1 MiB (UTF-8). Nothing was truncated.",
                      recoveryAction: "Use a text file to transfer larger content.")
            case .textTooLarge:
                .init(code: .restricted, safeMessage: "HarmonyOS clipboard writes are limited to 2 KiB (UTF-8) by this client. Nothing was truncated or transferred.",
                      recoveryAction: "Use a text file to transfer larger content.")
            case .containsNUL:
                .init(code: .restricted, safeMessage: "HDC clipboard text cannot contain a NUL character.")
            case .malformedOutput:
                .init(code: .malformedOutput, safeMessage: "HDC did not return a valid complete clipboard response.")
            case .commandFailed:
                .init(code: .failure, safeMessage: "The HarmonyOS clipboard command failed.")
            case .writeUnconfirmed:
                .init(code: .failure, safeMessage: "The HarmonyOS clipboard write was not confirmed. The device may already contain the new text.",
                      recoveryAction: "Check the device before retrying. No automatic retry or rollback was performed.")
            }
        }
    }

    private let hdcURL: URL
    private let expectedSession: ConnectionSession
    private let sessionNonce: String
    private let runner: any HostCommandRunning
    private let validateSession: @Sendable () async throws -> Void
    private var capabilities: HarmonyClipboardCapabilities?
    private var admittedRequestIDs: Set<UUID> = []
    private var running = false

    public init(hdcURL: URL, expectedSession: ConnectionSession, sessionNonce: String,
                runner: any HostCommandRunning,
                validateSession: @escaping @Sendable () async throws -> Void) throws {
        let target = expectedSession.transportID
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-[]%")
        guard hdcURL.isFileURL, expectedSession.state == .active,
              expectedSession.deviceIdentity.platform == .harmonyOS,
              !target.isEmpty, target.utf8.count <= 256, !target.hasPrefix("-"),
              target.unicodeScalars.allSatisfy(allowed.contains),
              !sessionNonce.isEmpty, sessionNonce.utf8.count <= 256,
              !sessionNonce.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw Failure.invalidBinding
        }
        self.hdcURL = hdcURL
        self.expectedSession = expectedSession
        self.sessionNonce = sessionNonce
        self.runner = runner
        self.validateSession = validateSession
    }

    public init(hdcURL: URL, expectedSession: ConnectionSession, sessionNonce: String,
                runner: any HostCommandRunning, store: DeviceSessionStore) throws {
        try self.init(hdcURL: hdcURL, expectedSession: expectedSession, sessionNonce: sessionNonce,
                      runner: runner, validateSession: {
            let snapshot = await store.snapshot()
            guard snapshot.session == expectedSession,
                  snapshot.selectedDeviceIdentity == expectedSession.deviceIdentity else {
                throw Failure.staleSession
            }
        })
    }

    /// Call only for an explicit clipboard action. This inspects help and tests
    /// base64/quoting with fixed NON-clipboard data; it never reads, writes or clears
    /// the pasteboard. A successful probe is scoped to this captured session.
    public func probeCapabilities() async throws -> HarmonyClipboardCapabilities {
        guard !running else { throw Failure.busy }
        running = true
        defer { running = false }
        return try await probe(deadline: ContinuousClock.now.advanced(by: Self.maximumOperationDuration))
    }

    public func send(_ request: HelperRequest) async throws -> HelperResult {
        try Task.checkCancellation()
        guard !running else { throw Failure.busy }
        try validate(request)
        guard !admittedRequestIDs.contains(request.requestID) else { throw Failure.replayedRequest }
        guard admittedRequestIDs.count < Self.maximumAdmittedRequests else { throw Failure.requestLimitReached }
        admittedRequestIDs.insert(request.requestID) // A dispatched/failed ID must never be replayed.
        running = true
        defer { running = false }
        let remaining = request.expiresAt.timeIntervalSinceNow
        let deadline = ContinuousClock.now.advanced(by: min(Self.maximumOperationDuration, .seconds(remaining)))
        try await requireCurrent(deadline)
        let capability: HarmonyClipboardCapabilities
        if let capabilities { capability = capabilities }
        else { capability = try await probe(deadline: deadline) }
        switch request.action {
        case .clipboardRead:
            guard capability.canRead else { throw Failure.unsupported }
            try await requireCurrent(deadline)
            let result: HostCommandResult
            do {
                result = try await command("testhelper get-pastedata", deadline: deadline,
                    limit: Self.maximumReadUTF8Bytes + Self.readPrefix.count + 1)
            } catch HostCommandError.outputLimitExceeded { throw Failure.readTooLarge }
            let text = try Self.parseRead(result)
            try await requireCurrent(deadline)
            return .init(requestID: request.requestID, status: .success, completedAt: Date(),
                         payload: ["text": .string(text)])
        case .clipboardWrite:
            guard capability.canWrite, let text = request.payload["text"]?.stringValue else { throw Failure.unsupported }
            let script = try Self.writeCommand(text)
            try await requireCurrent(deadline)
            // From this point, even cancellation may arrive after the device wrote.
            // There is exactly one dispatch, no post-write read, retry, clear, or undo.
            do {
                let result = try await command(script, deadline: deadline, limit: 256)
                guard result.exitCode == 0, result.standardError.isEmpty,
                      result.standardOutput == Self.writeAcknowledgment else { throw Failure.writeUnconfirmed }
                try await requireCurrent(deadline)
            } catch let failure as Failure where failure == .staleSession {
                throw failure
            } catch {
                throw Failure.writeUnconfirmed
            }
            return .init(requestID: request.requestID, status: .success, completedAt: Date(),
                         payload: ["written": .bool(true)])
        default: throw Failure.invalidRequest // Also checked before any capability command.
        }
    }

    private func validate(_ request: HelperRequest) throws {
        let now = Date()
        guard request.protocolVersion == 1, request.sessionNonce == sessionNonce,
              request.helperDeviceID == expectedSession.deviceIdentity.rawValue,
              request.action == .clipboardRead || request.action == .clipboardWrite,
              request.createdAt.timeIntervalSince1970.isFinite, request.expiresAt.timeIntervalSince1970.isFinite,
              abs(request.createdAt.timeIntervalSince(now)) <= 120,
              request.createdAt < request.expiresAt,
              request.expiresAt.timeIntervalSince(request.createdAt) <= 30 else { throw Failure.invalidRequest }
        guard request.expiresAt > now else { throw Failure.expiredRequest }
        switch request.action {
        case .clipboardRead: guard request.payload.isEmpty else { throw Failure.invalidRequest }
        case .clipboardWrite:
            guard Set(request.payload.keys) == ["text"], let text = request.payload["text"]?.stringValue else {
                throw Failure.invalidRequest
            }
            _ = try Self.writeCommand(text) // Validate before any command, including help.
        default: throw Failure.invalidRequest
        }
    }

    private func requireCurrent(_ deadline: ContinuousClock.Instant) async throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw Failure.deadlineExceeded }
        do { try await validateSession() }
        catch is CancellationError { throw CancellationError() }
        catch { throw Failure.staleSession }
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw Failure.deadlineExceeded }
    }

    private func command(_ script: String, deadline: ContinuousClock.Instant, limit: Int) async throws -> HostCommandResult {
        try Task.checkCancellation()
        let remaining = ContinuousClock.now.duration(to: deadline)
        guard remaining > .zero else { throw Failure.deadlineExceeded }
        let arguments = ["-t", expectedSession.transportID, "shell", script]
        guard arguments.joined(separator: " ").utf8.count <= Self.maximumShellCommandUTF8Bytes,
              !script.utf8.contains(0) else { throw Failure.invalidRequest }
        let result: HostCommandResult
        do {
            result = try await runner.run(.init(executableURL: hdcURL, arguments: arguments,
                timeout: min(Self.maximumOperationDuration, remaining), maximumOutputBytes: limit))
        } catch HostCommandError.timedOut { throw Failure.deadlineExceeded }
        catch HostCommandError.launchFailed { throw Failure.commandFailed }
        guard result.standardOutput.count <= limit,
              result.standardError.count <= limit - result.standardOutput.count else {
            throw HostCommandError.outputLimitExceeded
        }
        return result
    }

    private func probe(deadline: ContinuousClock.Instant) async throws -> HarmonyClipboardCapabilities {
        try await requireCurrent(deadline)
        let help: HostCommandResult
        do { help = try await command("testhelper help", deadline: deadline, limit: 16 * 1_024) }
        catch HostCommandError.outputLimitExceeded { throw Failure.unsupported }
        try await requireCurrent(deadline)
        guard help.exitCode == 0, help.standardError.isEmpty,
              let text = String(data: help.standardOutput, encoding: .utf8),
              !text.utf8.contains(0) else { throw Failure.unsupported }
        // Match help command columns, not arbitrary occurrences or user clipboard data.
        let commands = Set(text.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            line.split(whereSeparator: \.isWhitespace).first.map(String.init)
        })
        let canRead = commands.contains("get-pastedata")
        let declaresWrite = commands.contains("set-pastedata")
        var canWrite = false
        if declaresWrite {
            try await requireCurrent(deadline)
            let encoded: HostCommandResult
            do { encoded = try await command(Self.encodingProbeCommand, deadline: deadline, limit: 1_024) }
            catch HostCommandError.outputLimitExceeded { throw Failure.unsupported }
            try await requireCurrent(deadline)
            canWrite = encoded.exitCode == 0 && encoded.standardError.isEmpty
                && encoded.standardOutput == Data(Self.encodingProbeText.utf8)
        }
        let value = HarmonyClipboardCapabilities(canRead: canRead, canWrite: canWrite,
                                                maximumWriteUTF8Bytes: Self.maximumWriteUTF8Bytes)
        capabilities = value
        return value
    }

    static func parseRead(_ result: HostCommandResult) throws -> String {
        guard result.exitCode == 0, result.standardError.isEmpty else { throw Failure.commandFailed }
        let output = result.standardOutput
        guard output.count <= maximumReadUTF8Bytes + readPrefix.count + 1 else { throw Failure.readTooLarge }
        guard output.starts(with: readPrefix), output.last == 0x0A else { throw Failure.malformedOutput }
        let body = output.dropFirst(readPrefix.count).dropLast() // Exactly one protocol LF, never trim text.
        guard body.count <= maximumReadUTF8Bytes else { throw Failure.readTooLarge }
        guard !body.contains(0) else { throw Failure.containsNUL }
        guard let text = String(data: body, encoding: .utf8) else { throw Failure.malformedOutput }
        return text
    }

    static func writeCommand(_ text: String) throws -> String {
        guard text.utf8.count <= maximumWriteUTF8Bytes else { throw Failure.textTooLarge }
        guard !text.utf8.contains(0) else { throw Failure.containsNUL }
        let command = encodedAssignment(text) + "; testhelper set-pastedata \"$DB_CLIPBOARD_TEXT\""
        guard command.utf8.count <= maximumShellCommandUTF8Bytes else { throw Failure.textTooLarge }
        return command
    }

    private static func encodedAssignment(_ text: String) -> String {
        let encoded = Data(text.utf8).base64EncodedString()
        // The sentinel prevents shell command substitution stripping the user's
        // trailing LFs. Decoder failure skips sentinel and fails before testhelper.
        // Only generated Base64 reaches shell source; text is never re-evaluated.
        return "DB_CLIPBOARD_TEXT=\"$(printf '%s' '\(encoded)' | base64 -d && printf '%s' 'DBCLIP_END')\" || exit 73; DB_CLIPBOARD_TEXT=\"${DB_CLIPBOARD_TEXT%DBCLIP_END}\""
    }
}
