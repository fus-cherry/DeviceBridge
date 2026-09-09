import CryptoKit
import Foundation

public enum DeviceFileScope: Sendable, Equatable {
    case androidSharedDownloads
    case androidAppData(packageID: String)
    case iOSTemporary(identifier: String)
    case iOSAppData(bundleID: String)
    case iOSAppGroup(identifier: String)
    case iOSSystemCrashLogs

    public var platform: DevicePlatform {
        switch self {
        case .androidSharedDownloads, .androidAppData: .android
        case .iOSTemporary, .iOSAppData, .iOSAppGroup, .iOSSystemCrashLogs: .iOS
        }
    }
}

public enum DeviceFileLocationError: Error, Sendable, Equatable {
    case invalidRelativePath
    case invalidIdentifier
}

public struct DeviceFileLocation: Sendable, Equatable {
    public let scope: DeviceFileScope
    public let relativePath: String

    public init(scope: DeviceFileScope, relativePath: String) throws {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.contains("\0"),
              !relativePath.contains("\\"),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw DeviceFileLocationError.invalidRelativePath
        }
        switch scope {
        case let .androidAppData(packageID),
             let .iOSAppData(packageID),
             let .iOSAppGroup(packageID),
             let .iOSTemporary(packageID):
            guard Self.isValidIdentifier(packageID) else {
                throw DeviceFileLocationError.invalidIdentifier
            }
        case .androidSharedDownloads, .iOSSystemCrashLogs:
            break
        }
        self.scope = scope
        self.relativePath = relativePath
    }

    private static func isValidIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.first?.isLetter == true || value.first?.isNumber == true else { return false }
        return value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-" || $0 == "_"
        }
    }
}

public struct FileIntegrityMetadata: Sendable, Equatable {
    public let byteLength: Int64
    public let sha256: String

    public init(byteLength: Int64, sha256: String) {
        self.byteLength = byteLength
        self.sha256 = sha256
    }
}

public enum FileIntegrity {
    public static func metadata(for url: URL) throws -> FileIntegrityMetadata {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var length: Int64 = 0
        while try autoreleasepool(invoking: {
            // FileHandle's Foundation buffers otherwise survive the whole hashing operation,
            // retaining file-sized memory even though each individual read is bounded.
            guard let chunk = try handle.read(upToCount: 1_024 * 1_024), !chunk.isEmpty else { return false }
            hasher.update(data: chunk)
            length += Int64(chunk.count)
            return true
        }) {
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return FileIntegrityMetadata(byteLength: length, sha256: digest)
    }
}

public struct DeviceFileReceipt: Sendable, Equatable {
    public let byteLength: Int64
    public let sha256: String?

    public init(byteLength: Int64, sha256: String?) {
        self.byteLength = byteLength
        self.sha256 = sha256
    }
}

public protocol DeviceFileProviding: Sendable {
    func send(
        localURL: URL,
        destination: DeviceFileLocation,
        transportID: String,
        operationID: UUID,
        replaceExisting: Bool
    ) async throws -> DeviceFileReceipt

    func receive(
        source: DeviceFileLocation,
        localPartialURL: URL,
        transportID: String,
        operationID: UUID
    ) async throws -> DeviceFileReceipt
}

public enum FileTransferDirection: Sendable, Equatable {
    case hostToDevice
    case deviceToHost
}

public enum FileValidationLevel: Sendable, Equatable {
    case length
    case sha256
}

public struct TransferArtifact: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let sourceDevice: DeviceIdentity
    public let operationID: UUID
    public let direction: FileTransferDirection
    public let localURL: URL
    public let deviceLocation: DeviceFileLocation
    public let byteLength: Int64
    public let sha256: String
    public let validation: FileValidationLevel
    public let completedAt: Date
}

public enum FileTransferOutcome: Sendable, Equatable {
    case transferred(TransferArtifact)
    case failure(OperationFailure)
    case stale

    public var artifact: TransferArtifact? {
        if case let .transferred(artifact) = self { return artifact }
        return nil
    }

    public var failure: OperationFailure? {
        if case let .failure(failure) = self { return failure }
        return nil
    }
}

public actor FileTransferService {
    private let store: DeviceSessionStore
    private let provider: any DeviceFileProviding
    private let fileManager: FileManager

    public init(
        store: DeviceSessionStore,
        provider: any DeviceFileProviding,
        fileManager: FileManager = .default
    ) {
        self.store = store
        self.provider = provider
        self.fileManager = fileManager
    }

    public func send(
        sourceURL: URL,
        destination: DeviceFileLocation,
        replaceExisting: Bool = false
    ) async -> FileTransferOutcome {
        let sourceMetadata: FileIntegrityMetadata
        do {
            sourceMetadata = try FileIntegrity.metadata(for: sourceURL)
        } catch {
            return .failure(OperationFailure(
                code: .restricted,
                safeMessage: "The selected source file cannot be read."
            ))
        }
        let token: SessionToken
        do {
            token = try await store.beginOperation(.fileSend)
        } catch DeviceSessionStoreError.connectionBusy {
            return .failure(OperationFailure(code: .failure, safeMessage: "Connection check in progress. Retry shortly."))
        } catch {
            return disconnected()
        }
        guard token.deviceIdentity.platform == destination.scope.platform else {
            await store.finishOperation(token)
            return unsupportedScope()
        }

        do {
            let receipt = try await provider.send(
                localURL: sourceURL,
                destination: destination,
                transportID: token.transportID,
                operationID: token.operationID,
                replaceExisting: replaceExisting
            )
            guard await store.canPublish(token) else {
                await store.finishOperation(token)
                return .stale
            }
            guard let validation = Self.validate(local: sourceMetadata, remote: receipt) else {
                await store.finishOperation(token)
                return integrityFailure()
            }
            let artifact = TransferArtifact(
                id: UUID(),
                sourceDevice: token.deviceIdentity,
                operationID: token.operationID,
                direction: .hostToDevice,
                localURL: sourceURL,
                deviceLocation: destination,
                byteLength: sourceMetadata.byteLength,
                sha256: sourceMetadata.sha256,
                validation: validation,
                completedAt: Date()
            )
            await store.finishOperation(token)
            return .transferred(artifact)
        } catch {
            await store.finishOperation(token)
            return failure(for: error)
        }
    }

    public func receive(
        source: DeviceFileLocation,
        destinationURL: URL,
        replaceExisting: Bool
    ) async -> FileTransferOutcome {
        if fileManager.fileExists(atPath: destinationURL.path), !replaceExisting {
            return .failure(OperationFailure(
                code: .restricted,
                safeMessage: "A file already exists at the selected destination.",
                recoveryAction: "Choose Replace explicitly or select another destination."
            ))
        }
        let token: SessionToken
        do {
            token = try await store.beginOperation(.fileReceive)
        } catch DeviceSessionStoreError.connectionBusy {
            return .failure(OperationFailure(code: .failure, safeMessage: "Connection check in progress. Retry shortly."))
        } catch {
            return disconnected()
        }
        guard token.deviceIdentity.platform == source.scope.platform else {
            await store.finishOperation(token)
            return unsupportedScope()
        }

        let partialURL = destinationURL.deletingLastPathComponent().appending(
            path: ".\(destinationURL.lastPathComponent).partial.\(token.operationID.uuidString)"
        )
        try? fileManager.removeItem(at: partialURL)
        do {
            try fileManager.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let receipt = try await provider.receive(
                source: source,
                localPartialURL: partialURL,
                transportID: token.transportID,
                operationID: token.operationID
            )
            guard await store.canPublish(token) else {
                try? fileManager.removeItem(at: partialURL)
                await store.finishOperation(token)
                return .stale
            }
            let local = try FileIntegrity.metadata(for: partialURL)
            guard let validation = Self.validate(local: local, remote: receipt) else {
                try? fileManager.removeItem(at: partialURL)
                await store.finishOperation(token)
                return integrityFailure()
            }
            if fileManager.fileExists(atPath: destinationURL.path) {
                _ = try fileManager.replaceItemAt(destinationURL, withItemAt: partialURL)
            } else {
                try fileManager.moveItem(at: partialURL, to: destinationURL)
            }
            guard await store.canPublish(token) else {
                try? fileManager.removeItem(at: destinationURL)
                await store.finishOperation(token)
                return .stale
            }
            let artifact = TransferArtifact(
                id: UUID(),
                sourceDevice: token.deviceIdentity,
                operationID: token.operationID,
                direction: .deviceToHost,
                localURL: destinationURL,
                deviceLocation: source,
                byteLength: local.byteLength,
                sha256: local.sha256,
                validation: validation,
                completedAt: Date()
            )
            await store.finishOperation(token)
            return .transferred(artifact)
        } catch {
            try? fileManager.removeItem(at: partialURL)
            await store.finishOperation(token)
            return failure(for: error)
        }
    }

    private static func validate(
        local: FileIntegrityMetadata,
        remote: DeviceFileReceipt
    ) -> FileValidationLevel? {
        guard local.byteLength == remote.byteLength else { return nil }
        guard let remoteHash = remote.sha256 else { return .length }
        guard remoteHash.lowercased() == local.sha256 else { return nil }
        return .sha256
    }

    private func failure(for error: Error) -> FileTransferOutcome {
        if error is CancellationError || error as? HostCommandError == .cancelled {
            return .failure(OperationFailure(code: .cancelled, safeMessage: "File transfer cancelled."))
        }
        if error as? HostCommandError == .timedOut {
            return .failure(OperationFailure(code: .timeout, safeMessage: "File transfer timed out."))
        }
        if let failure = error as? OperationFailure { return .failure(failure) }
        if let androidError = error as? AndroidFileProviderError {
            switch androidError {
            case .remoteExists:
                return replacementRequired()
            case .unsupportedScope:
                return unsupportedScope()
            case .scopeUnavailable:
                return .failure(OperationFailure(
                    code: .restricted,
                    safeMessage: "The Android path is not available to ADB or run-as.",
                    recoveryAction: "Use Downloads or a debuggable app package and permitted relative path."
                ))
            case .transferFailed, .malformedMetadata:
                break
            }
        }
        if let iOSError = error as? IOSFileProviderError {
            switch iOSError {
            case .remoteExists:
                return replacementRequired()
            case .unsupportedScope:
                return unsupportedScope()
            case .readOnlyScope, .scopeUnavailable:
                return .failure(OperationFailure(
                    code: .restricted,
                    safeMessage: "The selected iOS file domain is not writable or unavailable."
                ))
            case .malformedMetadata, .transferFailed:
                break
            }
        }
        return .failure(OperationFailure(
            code: .failure,
            safeMessage: "The file transfer failed.",
            recoveryAction: "Check the permitted scope and device connection, then retry."
        ))
    }

    private func integrityFailure() -> FileTransferOutcome {
        .failure(OperationFailure(
            code: .integrityMismatch,
            safeMessage: "The transferred file failed its integrity check.",
            recoveryAction: "Retry the transfer."
        ))
    }

    private func disconnected() -> FileTransferOutcome {
        .failure(OperationFailure(
            code: .disconnected,
            safeMessage: "No active device session is available."
        ))
    }

    private func unsupportedScope() -> FileTransferOutcome {
        .failure(OperationFailure(
            code: .unsupported,
            safeMessage: "The selected file scope does not match the active device platform."
        ))
    }

    private func replacementRequired() -> FileTransferOutcome {
        .failure(OperationFailure(
            code: .restricted,
            safeMessage: "A file already exists at the device destination.",
            recoveryAction: "Choose Replace explicitly or use another relative path."
        ))
    }
}
