import Foundation

public struct ScreenshotCapturePayload: Sendable, Equatable {
    public let data: Data
    public let capturedAt: Date

    public init(data: Data, capturedAt: Date) {
        self.data = data
        self.capturedAt = capturedAt
    }
}

public protocol ScreenshotProviding: Sendable {
    func capture(transportID: String) async throws -> ScreenshotCapturePayload
}

public struct ScreenshotArtifact: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let sourceDevice: DeviceIdentity
    public let operationID: UUID
    public let sessionURL: URL
    public let mediaType: String
    public let byteLength: Int
    public let pixelWidth: UInt32
    public let pixelHeight: UInt32
    public let createdAt: Date

    public init(
        id: UUID,
        sourceDevice: DeviceIdentity,
        operationID: UUID,
        sessionURL: URL,
        mediaType: String,
        byteLength: Int,
        pixelWidth: UInt32,
        pixelHeight: UInt32,
        createdAt: Date
    ) {
        self.id = id
        self.sourceDevice = sourceDevice
        self.operationID = operationID
        self.sessionURL = sessionURL
        self.mediaType = mediaType
        self.byteLength = byteLength
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.createdAt = createdAt
    }
}

public enum ScreenshotOperationOutcome: Sendable, Equatable {
    case artifact(ScreenshotArtifact)
    case failure(OperationFailure)
    case stale

    public var artifact: ScreenshotArtifact? {
        if case let .artifact(artifact) = self { return artifact }
        return nil
    }

    public var failure: OperationFailure? {
        if case let .failure(failure) = self { return failure }
        return nil
    }
}

public actor ScreenshotService {
    private let store: DeviceSessionStore
    private let provider: any ScreenshotProviding
    private let sessionDirectory: URL
    private let fileManager: FileManager
    public private(set) var currentArtifact: ScreenshotArtifact?

    public init(
        store: DeviceSessionStore,
        provider: any ScreenshotProviding,
        sessionDirectory: URL,
        fileManager: FileManager = .default
    ) {
        self.store = store
        self.provider = provider
        self.sessionDirectory = sessionDirectory
        self.fileManager = fileManager
    }

    public func capture() async -> ScreenshotOperationOutcome {
        let token: SessionToken
        do {
            token = try await store.beginOperation(.screenshot)
        } catch DeviceSessionStoreError.connectionBusy {
            return .failure(OperationFailure(code: .failure, safeMessage: "Connection check in progress. Retry shortly."))
        } catch {
            return .failure(OperationFailure(
                code: .disconnected,
                safeMessage: "No active device session is available.",
                recoveryAction: "Select a command-ready device."
            ))
        }

        let payload: ScreenshotCapturePayload
        do {
            payload = try await provider.capture(transportID: token.transportID)
        } catch IOSRunnerChannel.ScreenshotFailure.status(let status) {
            await store.finishOperation(token)
            switch status {
            case .permissionDenied:
                return .failure(OperationFailure(code: .permissionDenied,
                    safeMessage: "Screenshot access was denied on the iPhone."))
            case .actionRequired:
                return .failure(OperationFailure(code: .restricted,
                    safeMessage: "The iPhone cannot currently capture this screen.",
                    recoveryAction: "Unlock the device and retry."))
            case .cancelled:
                return .failure(OperationFailure(code: .cancelled,
                    safeMessage: "Screenshot capture cancelled."))
            case .expired:
                return .failure(OperationFailure(code: .timeout,
                    safeMessage: "Screenshot capture timed out.",
                    recoveryAction: "Check the device connection and retry."))
            case .invalid:
                return .failure(OperationFailure(code: .malformedOutput,
                    safeMessage: "The iPhone returned an invalid screenshot response."))
            case .failure, .success:
                // A success status without verified image bytes is never a successful capture.
                return .failure(OperationFailure(code: .failure,
                    safeMessage: "The selected device could not capture a screenshot.",
                    recoveryAction: "Unlock the device and retry."))
            }
        } catch IOSRunnerChannel.Failure.invalidReply {
            await store.finishOperation(token)
            return .failure(OperationFailure(code: .malformedOutput,
                safeMessage: "The iPhone returned an invalid screenshot response."))
        } catch IOSRunnerChannel.Failure.unavailable {
            await store.finishOperation(token)
            return .failure(OperationFailure(code: .disconnected,
                safeMessage: "The iPhone debugging channel closed. Select the device again."))
        } catch is CancellationError {
            await store.finishOperation(token)
            return .failure(OperationFailure(code: .cancelled, safeMessage: "Screenshot capture cancelled."))
        } catch HostCommandError.cancelled {
            await store.finishOperation(token)
            return .failure(OperationFailure(code: .cancelled, safeMessage: "Screenshot capture cancelled."))
        } catch HostCommandError.timedOut {
            await store.finishOperation(token)
            return .failure(OperationFailure(
                code: .timeout,
                safeMessage: "Screenshot capture timed out.",
                recoveryAction: "Check the device connection and retry."
            ))
        } catch {
            await store.finishOperation(token)
            return .failure(OperationFailure(
                code: .failure,
                safeMessage: "The selected device could not capture a screenshot.",
                recoveryAction: "Unlock the device and retry."
            ))
        }

        guard await store.canPublish(token) else {
            await store.finishOperation(token)
            return .stale
        }

        let partialURL = sessionDirectory.appending(
            path: "screenshot.partial.\(token.operationID.uuidString)"
        )
        do {
            try fileManager.createDirectory(
                at: sessionDirectory,
                withIntermediateDirectories: true
            )
            try payload.data.write(to: partialURL, options: .atomic)

            guard let dimensions = Self.pngDimensions(payload.data) else {
                try? fileManager.removeItem(at: partialURL)
                await store.finishOperation(token)
                return .failure(OperationFailure(
                    code: .malformedOutput,
                    safeMessage: "The screenshot provider returned an invalid PNG.",
                    recoveryAction: "Retry after unlocking the device."
                ))
            }

            guard await store.canPublish(token) else {
                try? fileManager.removeItem(at: partialURL)
                await store.finishOperation(token)
                return .stale
            }

            let artifactID = UUID()
            let finalURL = sessionDirectory.appending(path: "screenshot-\(artifactID.uuidString).png")
            try fileManager.moveItem(at: partialURL, to: finalURL)

            guard await store.canPublish(token) else {
                try? fileManager.removeItem(at: finalURL)
                await store.finishOperation(token)
                return .stale
            }

            let artifact = ScreenshotArtifact(
                id: artifactID,
                sourceDevice: token.deviceIdentity,
                operationID: token.operationID,
                sessionURL: finalURL,
                mediaType: "image/png",
                byteLength: payload.data.count,
                pixelWidth: dimensions.width,
                pixelHeight: dimensions.height,
                createdAt: payload.capturedAt
            )
            currentArtifact = artifact
            await store.finishOperation(token)
            return .artifact(artifact)
        } catch is CancellationError {
            try? fileManager.removeItem(at: partialURL)
            await store.finishOperation(token)
            return .failure(OperationFailure(code: .cancelled, safeMessage: "Screenshot capture cancelled."))
        } catch {
            try? fileManager.removeItem(at: partialURL)
            await store.finishOperation(token)
            return .failure(OperationFailure(
                code: .failure,
                safeMessage: "The screenshot could not be staged safely.",
                recoveryAction: "Check available disk space and retry."
            ))
        }
    }

    public func clearSessionArtifacts() {
        currentArtifact = nil
        try? fileManager.removeItem(at: sessionDirectory)
    }

    private static func pngDimensions(_ data: Data) -> (width: UInt32, height: UInt32)? {
        let bytes = [UInt8](data)
        let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
        guard bytes.count >= 24,
              Array(bytes[0..<8]) == signature,
              Array(bytes[12..<16]) == Array("IHDR".utf8) else { return nil }

        func uint32(at offset: Int) -> UInt32 {
            bytes[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        }
        let width = uint32(at: 16)
        let height = uint32(at: 20)
        guard width > 0, height > 0 else { return nil }
        return (width, height)
    }
}
