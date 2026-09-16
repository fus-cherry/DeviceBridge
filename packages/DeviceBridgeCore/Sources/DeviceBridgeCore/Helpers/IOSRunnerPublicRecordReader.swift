import Darwin
import Foundation

/// Copies public bootstrap metadata only, from the captured phone's exact Runner namespace.
/// The caller must recheck launch/child ownership after awaiting and validate the record's
/// launch, host digest, build and certificate before using it as a TLS pin. This is not readiness.
public protocol IOSRunnerPublicRecordReading: Sendable {
    func read(launch: IOSRunnerLaunch) async throws -> Data
}

public struct IOSRunnerPublicRecordReader: IOSRunnerPublicRecordReading {
    private let xcrunURL: URL
    private let commands: any HostCommandRunning
    private let copyTimeout: Duration
    private let containerBundleIdentifier: String

    public init(xcrunURL: URL, commands: any HostCommandRunning = IOSRunnerPublicCopyProcessRunner(),
                copyTimeout: Duration = .seconds(8),
                containerBundleIdentifier: String = "dev.debugutility.DeviceBridgeRunnerUITests.xctrunner") {
        self.xcrunURL = xcrunURL
        self.commands = commands
        self.copyTimeout = copyTimeout
        self.containerBundleIdentifier = containerBundleIdentifier
    }

    public func read(launch: IOSRunnerLaunch) async throws -> Data {
        try Task.checkCancellation()
        guard !launch.deviceIdentifier.isEmpty, !launch.deviceIdentifier.contains("\0"),
              copyTimeout > .zero, copyTimeout <= .seconds(8) else { throw Failure.copyUnavailable }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DeviceBridgePublicRecord-\(UUID().uuidString)")
        guard mkdir(directory.path, 0o700) == 0 else { throw Failure.copyUnavailable }
        let destination = directory.appendingPathComponent("public.json")
        do {
            let result = try await commands.run(HostCommandRequest(executableURL: xcrunURL,
                arguments: ["devicectl", "device", "copy", "from", "--device", launch.deviceIdentifier,
                    "--domain-type", "appDataContainer", "--domain-identifier", containerBundleIdentifier,
                    "--source", "Documents/DeviceBridgeBootstrap/\(launch.id.uuidString).json",
                    "--destination", destination.path, "--timeout", "5"],
                timeout: copyTimeout, maximumOutputBytes: 0))
            try Task.checkCancellation()
            guard result.exitCode == 0 else { throw Failure.copyUnavailable }
            let data = try Self.readBoundedRegularFile(destination)
            try FileManager.default.removeItem(at: directory)
            return data
        } catch {
            // Only this call's newly created public-metadata directory is eligible for cleanup.
            let cancelled = Task.isCancelled || error is CancellationError
            do { try FileManager.default.removeItem(at: directory) }
            catch let error as CocoaError where error.code == .fileNoSuchFile { }
            catch { throw Failure.cleanupFailed }
            if cancelled { throw CancellationError() }
            throw (error as? Failure) ?? Failure.copyUnavailable
        }
    }

    private static func readBoundedRegularFile(_ url: URL) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw Failure.invalidRecord }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size > 0, info.st_size <= 8192 else { throw Failure.invalidRecord }
        var bytes = [UInt8](repeating: 0, count: 8193)
        var count = 0
        while count < bytes.count {
            let readCount = bytes.withUnsafeMutableBytes {
                Darwin.read(fd, $0.baseAddress!.advanced(by: count), $0.count - count)
            }
            if readCount == 0 { break }
            if readCount < 0 {
                if errno == EINTR { continue }
                throw Failure.invalidRecord
            }
            count += readCount
        }
        guard count > 0, count <= 8192 else { throw Failure.invalidRecord }
        return Data(bytes.prefix(count))
    }

    public enum Failure: Error, Sendable, Equatable { case copyUnavailable, invalidRecord, cleanupFailed }
}

/// Copy needs only an exit code. Discard diagnostic streams and use the owned process-group
/// boundary so a TERM-ignoring child or inherited output pipe cannot hold cleanup indefinitely.
public struct IOSRunnerPublicCopyProcessRunner: HostCommandRunning {
    public init() {}
    public func run(_ request: HostCommandRequest) async throws -> HostCommandResult {
        let allowed = ["PATH", "HOME", "TMPDIR", "DEVELOPER_DIR", "LANG", "LC_ALL"]
        let environment = ProcessInfo.processInfo.environment.filter { allowed.contains($0.key) }
        let process = try IOSRunnerProcess.start(executableURL: request.executableURL,
            arguments: request.arguments, environment: environment, lifetime: request.timeout)
        let exit = await withTaskCancellationHandler {
            await process.waitForExit()
        } onCancel: { Task { await process.stop() } }
        try Task.checkCancellation()
        guard case let .exited(code) = exit else { throw HostCommandError.timedOut }
        return HostCommandResult(exitCode: code, standardOutput: Data(), standardError: Data())
    }
}
