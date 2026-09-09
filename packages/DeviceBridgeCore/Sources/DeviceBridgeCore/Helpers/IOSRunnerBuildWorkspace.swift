import Foundation
import CryptoKit
import Darwin

/// Exclusively claimed incremental compiler inputs. Launchers only receive immutable snapshots.
/// Persistent reuse transfers ownership only after success; interrupted writers stay quarantined.
public actor IOSRunnerBuildWorkspace {
    private let root: URL
    private var workspace: URL
    private let reuseCompletedWorkspaces: Bool
    private var building = false

    public init(rootDirectoryURL: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("DeviceBridgeIncrementalBuilds", isDirectory: true),
        reuseCompletedWorkspaces: Bool = false) {
        root = rootDirectoryURL
        workspace = rootDirectoryURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
        self.reuseCompletedWorkspaces = reuseCompletedWorkspaces
    }

    func run(_ request: HostCommandRequest, runner: any HostCommandRunning,
             snapshot: IOSRunnerBuildProducts) async throws -> HostCommandResult {
        let deadline = ContinuousClock.now.advanced(by: request.timeout)
        while building {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw HostCommandError.timedOut }
            try await Task.sleep(for: .milliseconds(20))
        }
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw HostCommandError.timedOut }
        building = true
        defer { building = false }
        do {
            guard request.arguments.filter({ $0 == "-derivedDataPath" }).count == 1,
                  let index = request.arguments.firstIndex(of: "-derivedDataPath"),
                  index + 1 < request.arguments.count,
                  request.arguments[index + 1] == snapshot.derivedDataDirectoryURL.path else {
                throw HostCommandError.launchFailed
            }
            var arguments = request.arguments
            let claim = try claimWorkspace(request: request, derivedDataIndex: index + 1,
                expectedTeam: snapshot.expectedTeamIdentifier)
            arguments[index + 1] = claim.directory.path
            try Task.checkCancellation()
            let result = try await runner.run(HostCommandRequest(executableURL: request.executableURL,
                arguments: arguments, environment: request.environment,
                timeout: ContinuousClock.now.duration(to: deadline), maximumOutputBytes: request.maximumOutputBytes))
            // Keep admission held until the actual external command returns, even after cancellation.
            try Task.checkCancellation()
            guard result.exitCode == 0 else {
                workspace = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
                return result
            }
            let source = claim.directory
            // Copying can be expensive; await its real completion before releasing admission.
            let staging = try await Task.detached {
                try Self.copySnapshot(from: source, to: snapshot)
            }.value
            defer { try? FileManager.default.removeItem(at: staging) }
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw HostCommandError.timedOut }
            try FileManager.default.moveItem(at: staging, to: snapshot.productsDirectoryURL)
            // No await after the final cancellation check. This actor relinquishes all writer
            // rights; even its own next build must reacquire a claim before touching this path.
            releaseCompletedClaim(claim)
            return result
        } catch {
            // Failed/cancelled commands may leave descendant writers; never admit their directory again.
            workspace = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
            throw error
        }
    }

    private enum BuildClaim {
        case local(URL)
        case persistent(directory: URL, marker: URL)
        var directory: URL {
            switch self {
            case let .local(directory), let .persistent(directory, _): directory
            }
        }
    }

    private struct BuildInputs: Encodable {
        let executable: String
        let arguments: [String]
        let environment: [String: String]?
        let expectedTeam: String
    }

    private func claimWorkspace(request: HostCommandRequest, derivedDataIndex: Int,
                                expectedTeam: String) throws -> BuildClaim {
        guard reuseCompletedWorkspaces else { return .local(workspace) }
        var arguments = request.arguments
        arguments[derivedDataIndex] = "<per-launch-derived-data>"
        let inputs = BuildInputs(executable: request.executableURL.path, arguments: arguments,
            environment: request.environment, expectedTeam: expectedTeam)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let key = SHA256.hash(data: try encoder.encode(inputs)).map { String(format: "%02x", $0) }.joined()
        let fm = FileManager.default
        guard (try? root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            throw HostCommandError.launchFailed
        }
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Keep the same path spelling for the first and reclaimed build. Foundation enumeration
        // can yield /private/var while resolvingSymlinksInPath normalizes that alias to /var.
        let bucket = root.standardizedFileURL.resolvingSymlinksInPath()
            .appendingPathComponent(key, isDirectory: true)
        try fm.createDirectory(at: bucket, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard try root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true,
              try bucket.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw HostCommandError.launchFailed
        }
        let candidates = try fm.contentsOfDirectory(at: bucket,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        for candidate in candidates.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard UUID(uuidString: candidate.lastPathComponent) != nil,
                  let values = try? candidate.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true else { continue }
            let directory = candidate.standardizedFileURL.resolvingSymlinksInPath()
            let available = directory.appendingPathComponent(".available")
            guard let marker = try? available.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  marker.isRegularFile == true, marker.isSymbolicLink != true else { continue }
            let owned = directory.appendingPathComponent(".claimed-" + UUID().uuidString)
            // Same-directory POSIX rename is the cross-process linearization point. Only one
            // contender can remove .available. Failed/crashed claims are never scavenged.
            if rename(available.path, owned.path) == 0 {
                return .persistent(directory: directory, marker: owned)
            }
        }
        let directory = bucket.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let marker = directory.appendingPathComponent(".claimed-" + UUID().uuidString)
        try Data().write(to: marker, options: .withoutOverwriting)
        return .persistent(directory: directory, marker: marker)
    }

    private func releaseCompletedClaim(_ claim: BuildClaim) {
        guard case let .persistent(directory, marker) = claim else { return }
        let available = directory.appendingPathComponent(".available")
        guard !FileManager.default.fileExists(atPath: available.path) else { return }
        // Cache publication is advisory. If it fails, keep the claim quarantined while the
        // already-published immutable launch snapshot remains usable.
        _ = rename(marker.path, available.path)
    }

    private static func copySnapshot(from workspace: URL, to snapshot: IOSRunnerBuildProducts) throws -> URL {
        let fm = FileManager.default
        let source = workspace.appendingPathComponent("Build/Products", isDirectory: true)
        let configurations = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "xctestrun" }
        guard configurations.count == 1, let configuration = configurations.first else {
            throw HostCommandError.launchFailed
        }
        let parent = snapshot.productsDirectoryURL.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent("snapshot-" + UUID().uuidString, isDirectory: true)
        do {
            let apps = staging.appendingPathComponent("Debug-iphoneos", isDirectory: true)
            try fm.createDirectory(at: apps, withIntermediateDirectories: true)
            for name in ["DeviceBridgeRunnerUITests-Runner.app", "DeviceBridgeHost.app"] {
                let app = source.appendingPathComponent("Debug-iphoneos/" + name)
                try rejectSymlinks(app)
                try fm.copyItem(at: app, to: apps.appendingPathComponent(name))
            }
            try rejectSymlinks(configuration)
            let data = try IOSRunnerTestConfiguration.readBoundedData(from: configuration)
            let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
            let relocated = try relocate(plist, workspace: workspace, source: source, destination: snapshot.productsDirectoryURL)
            let encoded = try PropertyListSerialization.data(fromPropertyList: relocated, format: .binary, options: 0)
            guard encoded.count <= 1_048_576 else { throw HostCommandError.launchFailed }
            try encoded.write(to: staging.appendingPathComponent(configuration.lastPathComponent))
            return staging
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    private static func rejectSymlinks(_ url: URL) throws {
        guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw HostCommandError.launchFailed
        }
        if let entries = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
            for case let child as URL in entries {
                guard try child.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                    throw HostCommandError.launchFailed
                }
            }
        }
    }

    private static func relocate(_ value: Any, workspace: URL, source: URL, destination: URL) throws -> Any {
        if let text = value as? String {
            if text.hasPrefix("/") {
                let path = URL(fileURLWithPath: text).standardizedFileURL.resolvingSymlinksInPath().path
                let productsPath = source.standardizedFileURL.resolvingSymlinksInPath().path
                let workspacePath = workspace.standardizedFileURL.resolvingSymlinksInPath().path
                if path == productsPath || path.hasPrefix(productsPath + "/") {
                    return destination.path + path.dropFirst(productsPath.count)
                }
                guard path != workspacePath, !path.hasPrefix(workspacePath + "/") else {
                    throw HostCommandError.launchFailed
                }
            }
            guard !text.contains(workspace.path) else { throw HostCommandError.launchFailed }
            return text
        }
        if let list = value as? [Any] {
            return try list.map { try relocate($0, workspace: workspace, source: source, destination: destination) }
        }
        if let dictionary = value as? [String: Any] {
            return try dictionary.mapValues { try relocate($0, workspace: workspace, source: source, destination: destination) }
        }
        return value
    }
}
