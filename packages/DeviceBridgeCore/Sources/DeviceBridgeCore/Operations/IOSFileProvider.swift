import Foundation
import CoreFoundation

public enum IOSFileProviderError: Error, Sendable, Equatable {
    case unsupportedScope
    case readOnlyScope
    case remoteExists
    case scopeUnavailable
    case malformedMetadata
    case transferFailed
}

public actor IOSFileProvider: DeviceFileProviding, DeviceFileBrowsing {
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

    public func list(directory: DeviceDirectoryLocation, transportID: String, operationID: UUID) async throws -> [DeviceFileEntry] {
        let domain = try domain(for: directory.scope, writing: false)
        let jsonURL = temporaryJSON(operationID: operationID, label: "listing-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: jsonURL) }
        var arguments = ["devicectl", "device", "info", "files", "--device", transportID] + domain.arguments
        if !directory.relativePath.isEmpty { arguments += ["--subdirectory", directory.relativePath] }
        arguments += ["--no-recurse", "--quiet", "--timeout", "30", "--json-output", jsonURL.path]
        let result = try await run(arguments, timeout: .seconds(35))
        guard result.exitCode == 0 else { throw IOSFileProviderError.scopeUnavailable }
        let object = try readMetadata(at: jsonURL)
        guard let root = object as? [String: Any], let result = root["result"] as? [String: Any],
              let files = (result["files"] ?? result["items"]) as? [[String: Any]] else {
            throw IOSFileProviderError.malformedMetadata
        }
        var entries: [DeviceFileEntry] = []
        var names = Set<String>()
        for file in files {
            let resources = file["resources"] as? [String: Any] ?? [:]
            if resources["isSymbolicLink"] as? Bool == true { continue }
            guard let name = (file["name"] ?? file["filename"] ?? file["displayName"]) as? String,
                  let location = try? directory.child(named: name),
                  names.insert(name).inserted,
                  let isDirectory = (resources["isDirectory"] ?? file["isDirectory"]) as? Bool else {
                throw IOSFileProviderError.malformedMetadata
            }
            entries.append(DeviceFileEntry(location: location, isDirectory: isDirectory,
                byteLength: isDirectory ? nil : Self.byteLength(in: file)))
        }
        return entries
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
        // DeviceFileLocation already validates nonempty POSIX path components.
        // Interpret the remote path directly, without host filesystem path rules.
        let components = location.relativePath.split(separator: "/")
        let parent = components.dropLast().joined(separator: "/")
        let filename = String(components.last!)
        var arguments = [
            "devicectl", "device", "info", "files",
            "--device", transportID,
        ]
        arguments += domain.arguments
        if !parent.isEmpty {
            arguments += ["--subdirectory", parent]
        }
        arguments += [
            "--no-recurse", "--quiet", "--timeout", "30",
            "--json-output", jsonURL.path,
        ]
        let result = try await run(arguments, timeout: .seconds(35))
        // A failed listing is not proof that the destination is absent. Fail closed
        // rather than silently permitting an overwrite.
        guard result.exitCode == 0 else { throw IOSFileProviderError.scopeUnavailable }
        let object = try readMetadata(at: jsonURL)
        guard let root = object as? [String: Any], let payload = root["result"] as? [String: Any],
              let files = (payload["files"] ?? payload["items"]) as? [[String: Any]] else {
            throw IOSFileProviderError.malformedMetadata
        }
        let directory = try DeviceDirectoryLocation(scope: location.scope, relativePath: parent)
        var names = Set<String>()
        var matched: [String: Any]?
        for file in files {
            guard let name = (file["name"] ?? file["filename"] ?? file["displayName"]) as? String,
                  (try? directory.child(named: name)) != nil,
                  names.insert(name).inserted else {
                throw IOSFileProviderError.malformedMetadata
            }
            if name == filename { matched = file }
        }
        guard let matched else { return nil }
        let resources = matched["resources"] as? [String: Any] ?? [:]
        guard (resources["isDirectory"] ?? matched["isDirectory"]) as? Bool != true,
              (resources["isSymbolicLink"] ?? matched["isSymbolicLink"]) as? Bool != true,
              let length = Self.byteLength(in: matched) else {
            // An existing entry without valid regular-file metadata is never "absent".
            throw IOSFileProviderError.malformedMetadata
        }
        return DeviceFileReceipt(byteLength: length, sha256: nil)
    }

    // Bound the sidecar itself: the command runner's stdout limit does not cover it.
    private func readMetadata(at url: URL) throws -> Any {
        try Task.checkCancellation()
        let limit = 4 * 1_024 * 1_024
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw IOSFileProviderError.malformedMetadata }
        do { return try JSONSerialization.jsonObject(with: data) }
        catch { throw IOSFileProviderError.malformedMetadata }
    }

    private static func byteLength(in file: [String: Any]) -> Int64? {
        let metadata = file["metadata"] as? [String: Any] ?? [:]
        guard let number = (metadata["size"] ?? file["fileSize"] ?? file["byteLength"] ?? file["size"]) as? NSNumber,
              let length = Int64(number.stringValue), length >= 0,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return length
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
        try Task.checkCancellation()
        let result = try await runner.run(HostCommandRequest(
            executableURL: xcrunURL,
            arguments: arguments,
            timeout: timeout,
            maximumOutputBytes: 512 * 1_024
        ))
        try Task.checkCancellation()
        return result
    }
}
