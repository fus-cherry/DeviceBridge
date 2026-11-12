import Foundation

/// Empty relativePath denotes the permitted scope's root, never the device filesystem root.
public struct DeviceDirectoryLocation: Sendable, Equatable {
    public let scope: DeviceFileScope
    public let relativePath: String

    public init(scope: DeviceFileScope, relativePath: String = "") throws {
        _ = try DeviceFileLocation(scope: scope, relativePath: relativePath.isEmpty ? "validation" : relativePath)
        self.scope = scope
        self.relativePath = relativePath
    }

    public var parent: DeviceDirectoryLocation? {
        guard !relativePath.isEmpty else { return nil }
        let components = relativePath.split(separator: "/").dropLast()
        return try? DeviceDirectoryLocation(scope: scope, relativePath: components.joined(separator: "/"))
    }

    public func child(named name: String) throws -> DeviceFileLocation {
        guard !name.contains("/") else { throw DeviceFileLocationError.invalidRelativePath }
        return try DeviceFileLocation(scope: scope,
            relativePath: relativePath.isEmpty ? name : relativePath + "/" + name)
    }
}

public struct DeviceFileEntry: Sendable, Equatable, Identifiable {
    public let location: DeviceFileLocation
    public let isDirectory: Bool
    public let byteLength: Int64?
    public var id: String { location.relativePath }
    public var name: String { (location.relativePath as NSString).lastPathComponent }

    public init(location: DeviceFileLocation, isDirectory: Bool, byteLength: Int64? = nil) {
        self.location = location
        self.isDirectory = isDirectory
        self.byteLength = byteLength
    }
}

/// Presentation-only filtering of the already loaded folder. Never accesses the device.
public enum DeviceFileListOrder: String, CaseIterable, Sendable {
    case name, largestFirst
}

public enum DeviceFileListPresentation {
    public static func receiveTargetHidden(in entries: [DeviceFileEntry], matching query: String,
                                           relativePath: String) -> Bool {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let target = entries.first(where: { !$0.isDirectory && $0.location.relativePath == relativePath })
        else { return false }
        return self.entries([target], matching: query).isEmpty
    }

    public static func entries(_ entries: [DeviceFileEntry], matching query: String,
                               order: DeviceFileListOrder = .name) -> [DeviceFileEntry] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.filter { term.isEmpty || $0.name.localizedCaseInsensitiveContains(term) }.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            if order == .largestFirst, !$0.isDirectory, $0.byteLength != $1.byteLength {
                // Unknown sizes remain last, rather than being confused with an empty file.
                return ($0.byteLength ?? -1) > ($1.byteLength ?? -1)
            }
            let comparison = $0.name.localizedStandardCompare($1.name)
            return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
        }
    }
}

public protocol DeviceFileBrowsing: Sendable {
    func list(directory: DeviceDirectoryLocation, transportID: String, operationID: UUID) async throws -> [DeviceFileEntry]
}

public enum DeviceDirectoryOutcome: Sendable, Equatable {
    case listed([DeviceFileEntry])
    case failure(OperationFailure)
    case stale
}

public actor DeviceFileBrowserService {
    private let store: DeviceSessionStore
    private let provider: any DeviceFileBrowsing
    private let session: ConnectionSession?
    public init(store: DeviceSessionStore, provider: any DeviceFileBrowsing, session: ConnectionSession? = nil) {
        self.store = store
        self.provider = provider
        self.session = session
    }

    public func list(directory: DeviceDirectoryLocation) async -> DeviceDirectoryOutcome {
        let token: SessionToken
        do { token = try await store.beginOperation(.fileReceive, expectedSession: session) }
        catch { return .failure(OperationFailure(code: .disconnected, safeMessage: "No available device session. Reconnect and retry.")) }
        guard token.deviceIdentity.platform == directory.scope.platform else {
            await store.finishOperation(token)
            return .failure(OperationFailure(code: .unsupported, safeMessage: "This file scope is not available on the selected device."))
        }
        do {
            let entries = try await provider.list(directory: directory, transportID: token.transportID, operationID: token.operationID)
            try Task.checkCancellation()
            let current = await store.canPublish(token)
            await store.finishOperation(token)
            guard current else { return .stale }
            return .listed(entries.sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            })
        } catch {
            let current = await store.canPublish(token)
            await store.finishOperation(token)
            guard current else { return .stale }
            if error is CancellationError || error as? HostCommandError == .cancelled {
                return .failure(OperationFailure(code: .cancelled, safeMessage: "File listing cancelled."))
            }
            if error as? HostCommandError == .timedOut {
                return .failure(OperationFailure(code: .timeout, safeMessage: "File listing timed out."))
            }
            if let failure = error as? OperationFailure { return .failure(failure) }
            return .failure(OperationFailure(code: .restricted,
                safeMessage: "Cannot list this folder. The device may deny access or the file domain may be unavailable.",
                recoveryAction: "Check the connection and choose a permitted scope. App containers require an accessible debug app."))
        }
    }
}
