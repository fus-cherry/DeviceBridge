import Foundation

public enum AndroidFileProviderError: Error, Sendable, Equatable {
    case unsupportedScope
    case scopeUnavailable
    case remoteExists
    case transferFailed
    case malformedMetadata
}

public actor AndroidFileProvider: DeviceFileProviding {
    private let adbURL: URL
    private let runner: any HostCommandRunning

    public init(adbURL: URL, runner: any HostCommandRunning) {
        self.adbURL = adbURL
        self.runner = runner
    }

    public func send(
        localURL: URL,
        destination: DeviceFileLocation,
        transportID: String,
        operationID: UUID,
        replaceExisting: Bool
    ) async throws -> DeviceFileReceipt {
        switch destination.scope {
        case .androidSharedDownloads:
            return try await sendShared(
                localURL: localURL,
                relativePath: destination.relativePath,
                transportID: transportID,
                operationID: operationID,
                replaceExisting: replaceExisting
            )
        case let .androidAppData(packageID):
            return try await sendAppData(
                localURL: localURL,
                packageID: packageID,
                relativePath: destination.relativePath,
                transportID: transportID,
                operationID: operationID,
                replaceExisting: replaceExisting
            )
        default:
            throw AndroidFileProviderError.unsupportedScope
        }
    }

    public func receive(
        source: DeviceFileLocation,
        localPartialURL: URL,
        transportID: String,
        operationID: UUID
    ) async throws -> DeviceFileReceipt {
        switch source.scope {
        case .androidSharedDownloads:
            let remote = sharedPath(source.relativePath)
            let receipt = try await metadata(
                prefix: ["-t", transportID, "shell"],
                remotePath: remote
            )
            let result = try await command(
                ["-t", transportID, "pull", remote, localPartialURL.path],
                timeout: .seconds(300)
            )
            guard result.exitCode == 0 else { throw AndroidFileProviderError.transferFailed }
            return receipt
        case let .androidAppData(packageID):
            let prefix = ["-t", transportID, "shell", "run-as", packageID]
            let receipt = try await metadata(prefix: prefix, remotePath: source.relativePath)
            let result = try await command(
                [
                    "-t", transportID, "exec-out", "run-as", packageID,
                    "cat", source.relativePath,
                ],
                timeout: .seconds(300),
                maximumOutputBytes: 600 * 1_024 * 1_024
            )
            guard result.exitCode == 0 else { throw AndroidFileProviderError.scopeUnavailable }
            try result.standardOutput.write(to: localPartialURL)
            return receipt
        default:
            throw AndroidFileProviderError.unsupportedScope
        }
    }

    private func sendShared(
        localURL: URL,
        relativePath: String,
        transportID: String,
        operationID: UUID,
        replaceExisting: Bool
    ) async throws -> DeviceFileReceipt {
        let final = sharedPath(relativePath)
        let stage = "/sdcard/Download/.devicebridge.partial.\(operationID.uuidString)"
        try await ensureReplacementAllowed(
            prefix: ["-t", transportID, "shell"],
            path: final,
            replaceExisting: replaceExisting
        )
        try await createParent(
            prefix: ["-t", transportID, "shell"],
            path: final
        )
        let push = try await command(
            ["-t", transportID, "push", localURL.path, stage],
            timeout: .seconds(300)
        )
        guard push.exitCode == 0 else { throw AndroidFileProviderError.transferFailed }
        do {
            let receipt = try await metadata(
                prefix: ["-t", transportID, "shell"],
                remotePath: stage
            )
            let publish = try await command(["-t", transportID, "shell", "mv", stage, final])
            guard publish.exitCode == 0 else { throw AndroidFileProviderError.transferFailed }
            return receipt
        } catch {
            _ = try? await command(["-t", transportID, "shell", "rm", "-f", stage])
            throw error
        }
    }

    private func sendAppData(
        localURL: URL,
        packageID: String,
        relativePath: String,
        transportID: String,
        operationID: UUID,
        replaceExisting: Bool
    ) async throws -> DeviceFileReceipt {
        let appPrefix = ["-t", transportID, "shell", "run-as", packageID]
        let hostStage = "/data/local/tmp/devicebridge.\(operationID.uuidString)"
        let appStage = ".devicebridge.partial.\(operationID.uuidString)"
        try await ensureReplacementAllowed(
            prefix: appPrefix,
            path: relativePath,
            replaceExisting: replaceExisting
        )
        try await createParent(prefix: appPrefix, path: relativePath)
        let push = try await command(
            ["-t", transportID, "push", localURL.path, hostStage],
            timeout: .seconds(300)
        )
        guard push.exitCode == 0 else { throw AndroidFileProviderError.transferFailed }
        let copy = try await command(appPrefix + ["cp", hostStage, appStage])
        guard copy.exitCode == 0 else {
            _ = try? await command(["-t", transportID, "shell", "rm", "-f", hostStage])
            throw AndroidFileProviderError.scopeUnavailable
        }
        do {
            let receipt = try await metadata(prefix: appPrefix, remotePath: appStage)
            let publish = try await command(appPrefix + ["mv", appStage, relativePath])
            guard publish.exitCode == 0 else { throw AndroidFileProviderError.transferFailed }
            _ = try? await command(["-t", transportID, "shell", "rm", "-f", hostStage])
            return receipt
        } catch {
            _ = try? await command(appPrefix + ["rm", "-f", appStage])
            _ = try? await command(["-t", transportID, "shell", "rm", "-f", hostStage])
            throw error
        }
    }

    private func ensureReplacementAllowed(
        prefix: [String],
        path: String,
        replaceExisting: Bool
    ) async throws {
        guard !replaceExisting else { return }
        let result = try await command(prefix + ["test", "-e", path])
        if result.exitCode == 0 { throw AndroidFileProviderError.remoteExists }
    }

    private func createParent(prefix: [String], path: String) async throws {
        let parent = (path as NSString).deletingLastPathComponent
        guard !parent.isEmpty, parent != "." else { return }
        let result = try await command(prefix + ["mkdir", "-p", parent])
        guard result.exitCode == 0 else { throw AndroidFileProviderError.scopeUnavailable }
    }

    private func metadata(prefix: [String], remotePath: String) async throws -> DeviceFileReceipt {
        let lengthResult = try await command(prefix + ["stat", "-c", "%s", remotePath])
        guard lengthResult.exitCode == 0,
              let byteLength = Int64(
                lengthResult.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines)
              ) else {
            throw AndroidFileProviderError.malformedMetadata
        }
        let hashResult = try await command(prefix + ["sha256sum", remotePath])
        let hash = hashResult.exitCode == 0
            ? hashResult.standardOutputString.split(whereSeparator: \Character.isWhitespace).first.map(String.init)
            : nil
        return DeviceFileReceipt(byteLength: byteLength, sha256: hash)
    }

    private func sharedPath(_ relativePath: String) -> String {
        "/sdcard/Download/\(relativePath)"
    }

    private func command(
        _ arguments: [String],
        timeout: Duration = .seconds(30),
        maximumOutputBytes: Int = 256 * 1_024
    ) async throws -> HostCommandResult {
        try await runner.run(HostCommandRequest(
            executableURL: adbURL,
            arguments: arguments,
            timeout: timeout,
            maximumOutputBytes: maximumOutputBytes
        ))
    }
}
