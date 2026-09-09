import Foundation

public enum IOSFileProviderError: Error, Sendable, Equatable {
    case unsupportedScope
    case readOnlyScope
    case remoteExists
    case scopeUnavailable
    case malformedMetadata
    case transferFailed
}

public actor IOSFileProvider: DeviceFileProviding {
    private let xcrunURL: URL
    private let runner: any HostCommandRunning
    private let fileManager: FileManager

    public init(
        xcrunURL: URL,
        runner: any HostCommandRunning,
        fileManager: FileManager = .default
    ) {
        self.xcrunURL = xcrunURL
        self.runner = runner
        self.fileManager = fileManager
    }

    public func send(
        localURL: URL,
        destination: DeviceFileLocation,
        transportID: String,
        operationID: UUID,
        replaceExisting: Bool
    ) async throws -> DeviceFileReceipt {
        let domain = try domain(for: destination.scope, writing: true)
        if !replaceExisting,
           try await queryMetadata(
            location: destination,
            domain: domain,
            transportID: transportID,
            operationID: operationID
           ) != nil {
            throw IOSFileProviderError.remoteExists
        }

        let jsonURL = temporaryJSON(operationID: operationID, label: "copy-to")
        defer { try? fileManager.removeItem(at: jsonURL) }
        var arguments = [
            "devicectl", "device", "copy", "to",
            "--device", transportID,
            "--source", localURL.path,
            "--destination", destination.relativePath,
        ]
        arguments += domain.arguments
        arguments += [
            "--quiet", "--timeout", "300",
            "--json-output", jsonURL.path,
        ]
        let result = try await run(arguments, timeout: .seconds(305))
        guard result.exitCode == 0 else { throw IOSFileProviderError.transferFailed }
        guard let receipt = try await queryMetadata(
            location: destination,
            domain: domain,
            transportID: transportID,
            operationID: operationID
        ) else {
            throw IOSFileProviderError.malformedMetadata
        }
        return receipt
    }

    public func receive(
        source: DeviceFileLocation,
        localPartialURL: URL,
        transportID: String,
        operationID: UUID
    ) async throws -> DeviceFileReceipt {
        let domain = try domain(for: source.scope, writing: false)
        guard let receipt = try await queryMetadata(
            location: source,
            domain: domain,
            transportID: transportID,
            operationID: operationID
        ) else {
            throw IOSFileProviderError.scopeUnavailable
        }

        let jsonURL = temporaryJSON(operationID: operationID, label: "copy-from")
        defer { try? fileManager.removeItem(at: jsonURL) }
        // CoreDevice creates a bookmark for its destination. Keep that external tool in
        // app-owned temporary storage; the app performs publication into the user's folder.
        let staging = fileManager.temporaryDirectory.appendingPathComponent("DeviceBridgeFileReceive-" + UUID().uuidString)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: staging) }
        let receivedURL = staging.appendingPathComponent("received-file")
        var arguments = [
            "devicectl", "device", "copy", "from",
            "--device", transportID,
            "--source", source.relativePath,
            "--destination", receivedURL.path,
        ]
        arguments += domain.arguments
        arguments += [
            "--quiet", "--timeout", "300",
            "--json-output", jsonURL.path,
        ]
        let result = try await run(arguments, timeout: .seconds(305))
        try Task.checkCancellation()
        guard result.exitCode == 0,
              fileManager.fileExists(atPath: receivedURL.path) else {
            throw IOSFileProviderError.transferFailed
        }
        try fileManager.moveItem(at: receivedURL, to: localPartialURL)
        return receipt
    }

    private struct Domain {
        let type: String
        let identifier: String?

        var arguments: [String] {
            var value = ["--domain-type", type]
            if let identifier { value += ["--domain-identifier", identifier] }
            return value
        }
    }

    private func domain(for scope: DeviceFileScope, writing: Bool) throws -> Domain {
        switch scope {
        case let .iOSTemporary(identifier):
            return Domain(type: "temporary", identifier: identifier)
        case let .iOSAppData(bundleID):
            return Domain(type: "appDataContainer", identifier: bundleID)
        case let .iOSAppGroup(identifier):
            return Domain(type: "appGroupDataContainer", identifier: identifier)
        case .iOSSystemCrashLogs where writing:
            throw IOSFileProviderError.readOnlyScope
        case .iOSSystemCrashLogs:
            return Domain(type: "systemCrashLogs", identifier: nil)
        default:
            throw IOSFileProviderError.unsupportedScope
        }
    }

    private func queryMetadata(
        location: DeviceFileLocation,
        domain: Domain,
        transportID: String,
        operationID: UUID
    ) async throws -> DeviceFileReceipt? {
        let jsonURL = temporaryJSON(operationID: operationID, label: "files-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: jsonURL) }
        let path = location.relativePath as NSString
        let parent = path.deletingLastPathComponent
        var arguments = [
            "devicectl", "device", "info", "files",
            "--device", transportID,
        ]
        arguments += domain.arguments
        if !parent.isEmpty, parent != "." {
            arguments += ["--subdirectory", parent]
        }
        arguments += [
            "--no-recurse", "--quiet", "--timeout", "30",
            "--json-output", jsonURL.path,
        ]
        let result = try await run(arguments, timeout: .seconds(35))
        guard result.exitCode == 0 else { return nil }
        let data = try Data(contentsOf: jsonURL)
        let object = try JSONSerialization.jsonObject(with: data)
        guard let length = Self.findByteLength(
            named: path.lastPathComponent,
            in: object
        ) else { return nil }
        return DeviceFileReceipt(byteLength: length, sha256: nil)
    }

    private static func findByteLength(named name: String, in value: Any) -> Int64? {
        if let dictionary = value as? [String: Any] {
            let itemName = dictionary["name"] as? String
                ?? dictionary["displayName"] as? String
                ?? dictionary["filename"] as? String
            if itemName == name {
                // CoreDevice info-files places size inside the matched entry's metadata.
                // Keep the association with this name; never borrow another entry's size.
                if let metadata = dictionary["metadata"] as? [String: Any],
                   let number = metadata["size"] as? NSNumber {
                    return number.int64Value
                }
                for key in ["fileSize", "byteLength", "size"] {
                    if let number = dictionary[key] as? NSNumber { return number.int64Value }
                }
            }
            for child in dictionary.values {
                if let found = findByteLength(named: name, in: child) { return found }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let found = findByteLength(named: name, in: child) { return found }
            }
        }
        return nil
    }

    private func temporaryJSON(operationID: UUID, label: String) -> URL {
        fileManager.temporaryDirectory.appending(
            path: "devicebridge-\(operationID.uuidString)-\(label).json"
        )
    }

    private func run(
        _ arguments: [String],
        timeout: Duration
    ) async throws -> HostCommandResult {
        try await runner.run(HostCommandRequest(
            executableURL: xcrunURL,
            arguments: arguments,
            timeout: timeout,
            maximumOutputBytes: 512 * 1_024
        ))
    }
}
