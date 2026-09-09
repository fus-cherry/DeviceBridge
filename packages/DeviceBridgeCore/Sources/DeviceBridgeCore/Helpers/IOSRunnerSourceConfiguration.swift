import Foundation

public enum IOSRunnerSourceConfigurationError: Error, Sendable, Equatable {
    case signingTeamRequired
    case bundleMissing
    case invalidManifest
    case unsafePath
    case sourcesMissing
}

/// Local build inputs only. This does not attest signing, installation, or channel readiness.
public struct IOSRunnerSourceConfiguration: Sendable {
    public let projectURL: URL
    public let scheme: String
    public let signingTeamID: String

    /// `helperResourcesURL` is the app's `Contents/Resources/Helpers` directory.
    public init(helperResourcesURL: URL, signingTeamID: String?) throws {
        guard let team = signingTeamID?.trimmingCharacters(in: .whitespacesAndNewlines), !team.isEmpty else {
            throw IOSRunnerSourceConfigurationError.signingTeamRequired
        }
        guard helperResourcesURL.isFileURL else { throw IOSRunnerSourceConfigurationError.bundleMissing }
        let helpers = helperResourcesURL.standardizedFileURL.resolvingSymlinksInPath()
        guard Self.isDirectory(helpers) else { throw IOSRunnerSourceConfigurationError.bundleMissing }
        let manifestURL = try Self.contained(helpers.appendingPathComponent("manifest.json"), in: helpers)
        guard Self.isRegularFile(manifestURL) else { throw IOSRunnerSourceConfigurationError.bundleMissing }
        let manifest: Manifest
        do {
            manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        } catch {
            throw IOSRunnerSourceConfigurationError.invalidManifest
        }
        let scheme = manifest.ios.scheme.trimmingCharacters(in: .whitespacesAndNewlines)
        guard manifest.schemaVersion == 1, !scheme.isEmpty else {
            throw IOSRunnerSourceConfigurationError.invalidManifest
        }
        let source = try Self.relative(manifest.ios.directory, in: helpers)
        let project = try Self.relative(manifest.ios.project, in: source)
        let projectFile = try Self.contained(project.appendingPathComponent("project.pbxproj"), in: source)
        guard project.pathExtension == "xcodeproj", Self.isRegularFile(projectFile) else {
            throw IOSRunnerSourceConfigurationError.sourcesMissing
        }

        // The project uses ../../packages; SecureChannel in turn imports its Protocol sibling.
        // Check these declared source roots, without enumerating arbitrary package source files.
        let packages = try Self.contained(
            project.deletingLastPathComponent().appendingPathComponent("../../packages"), in: source)
        for name in ["DeviceBridgeSecureChannel", "DeviceBridgeProtocol"] {
            let package = packages.appendingPathComponent(name)
            let packageManifest = try Self.contained(package.appendingPathComponent("Package.swift"), in: source)
            let sources = try Self.contained(package.appendingPathComponent("Sources"), in: source)
            guard Self.isRegularFile(packageManifest), Self.isDirectory(sources) else {
                throw IOSRunnerSourceConfigurationError.sourcesMissing
            }
        }
        self.projectURL = project
        self.scheme = scheme
        self.signingTeamID = team
    }

    private static func relative(_ path: String, in root: URL) throws -> URL {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains(":"), !path.contains("\0"),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw IOSRunnerSourceConfigurationError.unsafePath
        }
        return try contained(root.appendingPathComponent(path), in: root)
    }

    private static func contained(_ url: URL, in root: URL) throws -> URL {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        guard resolved.path.hasPrefix(rootPath + "/") else {
            throw IOSRunnerSourceConfigurationError.unsafePath
        }
        return resolved
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    private struct Manifest: Decodable {
        let schemaVersion: Int
        let ios: IOS

        struct IOS: Decodable {
            let directory: String
            let project: String
            let scheme: String
        }
    }
}
