import Darwin
import Foundation

/// Independent CoreDevice observations. A snapshot is not an atomic OS process-instance token.
public struct IOSApplicationProcessProvider: Sendable {
    public enum Failure: Error, Equatable, Sendable { case unavailable, invalidMetadata, wrongDevice, unsupportedRoute, cleanupFailed }
    public struct Application: Sendable, Equatable {
        public let target: TargetApplication
        public let installationURL: URL
        public let executableURL: URL
    }
    public struct Inventory: Sendable, Equatable {
        public let session: ConnectionSession
        public let applications: [Application]
    }
    private let xcrunURL: URL
    private let commands: any HostCommandRunning

    public init(xcrunURL: URL = URL(fileURLWithPath: "/usr/bin/xcrun"),
                commands: any HostCommandRunning = IOSRunnerPublicCopyProcessRunner()) {
        self.xcrunURL = xcrunURL
        self.commands = commands
    }

    public func load(session: ConnectionSession) async throws -> Inventory {
        try Task.checkCancellation()
        guard session.state == .active, session.deviceIdentity.platform == .iOS,
              session.deviceIdentity.stability == .stable,
              UUID(uuidString: session.transportID) != nil else { throw Failure.unsupportedRoute }
        let deadline = ContinuousClock.now + .seconds(15)
        do {
            let before: Details = try await query(.details, session: session, deadline: deadline)
            try validate(before, session: session)
            let apps: Apps = try await query(.apps, session: session, deadline: deadline)
            try requireDevice(apps.deviceIdentifier, session: session)
            let processes: Processes = try await query(.processes, session: session, deadline: deadline)
            try requireDevice(processes.deviceIdentifier, session: session)
            let applications = try correlate(apps: apps, processes: processes, session: session)
            let after: Details = try await query(.details, session: session, deadline: deadline)
            try validate(after, session: session)
            try Task.checkCancellation()
            // Caller must still compare this captured session with its current authoritative store.
            return Inventory(session: session, applications: applications)
        } catch {
            if error as? Failure == .cleanupFailed { throw Failure.cleanupFailed }
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            throw (error as? Failure) ?? Failure.invalidMetadata
        }
    }

    private func correlate(apps: Apps, processes: Processes, session: ConnectionSession) throws -> [Application] {
        guard apps.apps.count <= 4096, processes.runningProcesses.count <= 16_384 else { throw Failure.invalidMetadata }
        var processIDs = Set<Int>()
        let running = try processes.runningProcesses.map { process -> (Int, URL) in
            guard process.processIdentifier > 0, process.processIdentifier <= Int(Int32.max),
                  processIDs.insert(process.processIdentifier).inserted else { throw Failure.invalidMetadata }
            return (process.processIdentifier, try Self.fileURL(process.executable))
        }
        var identifiers = Set<String>()
        var installations = Set<String>()
        var applications: [Application] = []
        for app in apps.apps {
            guard identifiers.insert(app.bundleIdentifier).inserted else { throw Failure.invalidMetadata }
            guard app.builtByDeveloper else { continue }
            guard !app.bundleIdentifier.isEmpty, app.bundleIdentifier.utf8.count <= 256,
                  app.bundleIdentifier.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46].contains($0) }),
                  !app.name.isEmpty, app.name.utf8.count <= 1024,
                  !app.name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw Failure.invalidMetadata }
            let installed = try Self.fileURL(app.url)
            guard installed.pathExtension == "app", installations.insert(installed.path).inserted else { throw Failure.invalidMetadata }
            // Main executables live directly in the .app, not in PlugIns or prefix-lookalike paths.
            let matches = running.filter { $0.1.deletingLastPathComponent().path == installed.path }
            guard matches.count == 1, let process = matches.first else { continue }
            let target = TargetApplication(deviceIdentity: session.deviceIdentity, applicationID: app.bundleIdentifier,
                displayName: app.name, processID: process.0, processStartIdentity: nil, debuggable: true, state: .running)
            applications.append(Application(target: target, installationURL: installed, executableURL: process.1))
        }
        return applications.sorted { $0.target.applicationID < $1.target.applicationID }
    }

    private func validate(_ details: Details, session: ConnectionSession) throws {
        try requireDevice(details.identifier, session: session)
        guard details.hardwareProperties.udid == session.deviceIdentity.rawValue else { throw Failure.wrongDevice }
        guard details.hardwareProperties.platform == "iOS", details.hardwareProperties.reality == "physical",
              details.connectionProperties.transportType == "wired", details.connectionProperties.pairingState == "paired",
              details.deviceProperties.developerModeStatus == "enabled" else { throw Failure.unsupportedRoute }
    }

    private func requireDevice(_ identifier: String, session: ConnectionSession) throws {
        guard let returned = UUID(uuidString: identifier), returned == UUID(uuidString: session.transportID) else { throw Failure.wrongDevice }
    }

    private static func fileURL(_ raw: String) throws -> URL {
        guard raw.utf8.count <= 16_384, let components = URLComponents(string: raw),
              components.scheme == "file", components.host == nil || components.host == "",
              components.user == nil, components.password == nil, components.port == nil,
              components.query == nil, components.fragment == nil else { throw Failure.invalidMetadata }
        let path = components.path
        guard path.hasPrefix("/"), path.utf8.count <= 4096, !path.contains("//"),
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { throw Failure.invalidMetadata }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    private enum Query: String { case details, apps, processes }

    private func query<Result: Decodable>(_ kind: Query, session: ConnectionSession,
                                          deadline: ContinuousClock.Instant) async throws -> Result {
        try Task.checkCancellation()
        let remaining = ContinuousClock.now.duration(to: deadline)
        guard remaining > .zero else { throw Failure.unavailable }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DeviceBridgeProcessMetadata-\(UUID().uuidString)")
        guard mkdir(directory.path, 0o700) == 0 else { throw Failure.unavailable }
        let output = directory.appendingPathComponent("result.json")
        do {
            // Existing exit-only process-group boundary discards output and escalates stalled children.
            let result = try await commands.run(HostCommandRequest(executableURL: xcrunURL,
                arguments: ["devicectl", "device", "info", kind.rawValue, "--device", session.transportID,
                    "--quiet", "--json-output", output.path, "--timeout", "5"],
                timeout: min(.seconds(8), remaining), maximumOutputBytes: 0))
            try Task.checkCancellation()
            guard result.exitCode == 0, ContinuousClock.now < deadline else { throw Failure.unavailable }
            let envelope = try JSONDecoder().decode(Envelope<Result>.self, from: Self.readOutput(output))
            guard envelope.info.outcome == "success" else { throw Failure.invalidMetadata }
            try FileManager.default.removeItem(at: directory)
            return envelope.result
        } catch {
            do { try FileManager.default.removeItem(at: directory) }
            catch let cleanup as CocoaError where cleanup.code == .fileNoSuchFile { }
            catch { throw Failure.cleanupFailed }
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            throw (error as? Failure) ?? Failure.invalidMetadata
        }
    }

    private static func readOutput(_ url: URL) throws -> Data {
        let limit = 4_194_304
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw Failure.invalidMetadata }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size > 0, info.st_size <= limit else { throw Failure.invalidMetadata }
        var bytes = [UInt8](repeating: 0, count: limit + 1)
        var count = 0
        while count < bytes.count {
            let size = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!.advanced(by: count), $0.count - count) }
            if size == 0 { break }
            if size < 0 {
                if errno == EINTR { continue }
                throw Failure.invalidMetadata
            }
            count += size
        }
        guard count > 0, count <= limit else { throw Failure.invalidMetadata }
        return Data(bytes.prefix(count))
    }

    private struct Envelope<Result: Decodable>: Decodable {
        let info: Info
        let result: Result
        struct Info: Decodable { let outcome: String }
    }
    private struct Details: Decodable {
        let identifier: String
        let hardwareProperties: Hardware
        let connectionProperties: Connection
        let deviceProperties: Device
        struct Hardware: Decodable { let udid: String; let platform: String; let reality: String }
        struct Connection: Decodable { let transportType: String; let pairingState: String }
        struct Device: Decodable { let developerModeStatus: String }
    }
    private struct Apps: Decodable {
        let deviceIdentifier: String
        let apps: [App]
        struct App: Decodable { let bundleIdentifier: String; let name: String; let builtByDeveloper: Bool; let url: String }
    }
    private struct Processes: Decodable {
        let deviceIdentifier: String
        let runningProcesses: [Process]
        struct Process: Decodable { let processIdentifier: Int; let executable: String }
    }
}
