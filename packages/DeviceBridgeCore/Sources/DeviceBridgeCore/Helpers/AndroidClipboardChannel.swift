import DeviceBridgeProtocol
import Foundation

/// Each request runs as the authorized adb shell user and exits. The captured hardware identity
/// is checked on-device before content access; no Activity or long-lived clipboard connection exists.
public actor AndroidClipboardChannel: HelperRequestSending {
    public enum Failure: Error { case unverifiedDevice, installationFailed, invalidArtifact, commandFailed }
    private let adbURL: URL
    private let transportID: String
    private let identity: DeviceIdentity
    private let runner: any HostCommandRunning
    private let apkURL: URL
    private let expectedVersionCode: Int
    private var preparing = false
    private var remoteAPK: String?

    public init(adbURL: URL, transportID: String, identity: DeviceIdentity, apkURL: URL,
                expectedVersionCode: Int, runner: any HostCommandRunning) throws {
        guard identity.platform == .android,
              identity.rawValue.hasPrefix("android:hardware:") || identity.rawValue.hasPrefix("android:boot:") else { throw Failure.unverifiedDevice }
        self.adbURL = adbURL; self.transportID = transportID; self.identity = identity
        self.apkURL = apkURL; self.expectedVersionCode = expectedVersionCode; self.runner = runner
    }

    public func prepare() async throws {
        guard !preparing else { throw Failure.commandFailed }
        preparing = true
        defer { preparing = false }
        let actual = try await AndroidDeviceIdentityResolver(adbURL: adbURL, runner: runner).identity(transportID: transportID)
        guard actual == identity else { throw Failure.unverifiedDevice }
        if try await installedVersion() != expectedVersionCode {
            let installed = try await run(["install", "-r", apkURL.path], timeout: .seconds(60))
            guard installed.exitCode == 0, try await installedVersion() == expectedVersionCode else { throw Failure.installationFailed }
        }
        let path = try await run(["shell", "pm", "path", AndroidHelperManager.packageName])
        let lines = path.standardOutputString.split(whereSeparator: \.isNewline)
        guard path.exitCode == 0, let base = lines.first(where: { $0.hasPrefix("package:/data/app/") && $0.hasSuffix("/base.apk") }) else { throw Failure.invalidArtifact }
        let value = String(base.dropFirst("package:".count))
        guard !value.contains("'"), !value.contains("\n"), !value.contains("\r") else { throw Failure.invalidArtifact }
        remoteAPK = value
    }

    public func send(_ request: HelperRequest) async throws -> HelperResult {
        try Task.checkCancellation()
        guard let remoteAPK, request.helperDeviceID == identity.rawValue,
              request.action == .clipboardRead || request.action == .clipboardWrite else { throw Failure.unverifiedDevice }
        let codec = HelperWireCodec()
        let input = try HelperFrameCodec.encode(codec.encode(request))
        let result = try await runner.run(HostCommandRequest(executableURL: adbURL,
            arguments: ["-t", transportID, "shell", "-T",
                "CLASSPATH='\(remoteAPK)' app_process / dev.debugutility.helper.ShellClipboard"],
            timeout: .seconds(15), maximumOutputBytes: HelperWireCodec.maximumEnvelopeBytes + 65_536,
            standardInput: input))
        try Task.checkCancellation()
        guard result.exitCode == 0 else { throw Failure.commandFailed }
        return try codec.decodeResult(result.standardOutput)
    }

    private func installedVersion() async throws -> Int? {
        let result = try await run(["shell", "dumpsys", "package", AndroidHelperManager.packageName])
        guard result.exitCode == 0, let marker = result.standardOutputString.range(of: "versionCode=") else { return nil }
        return Int(result.standardOutputString[marker.upperBound...].prefix(while: \.isNumber))
    }

    private func run(_ arguments: [String], timeout: Duration = .seconds(10)) async throws -> HostCommandResult {
        let result = try await runner.run(HostCommandRequest(executableURL: adbURL,
            arguments: ["-t", transportID] + arguments, timeout: timeout, maximumOutputBytes: 65_536))
        try Task.checkCancellation()
        return result
    }
}
