import Foundation

public struct HarmonyPackageInstallReceipt: Sendable, Equatable {
    public let fileName: String
    public let byteLength: Int64
}

public enum HarmonyPackageInstallOutcome: Sendable, Equatable {
    case installed(HarmonyPackageInstallReceipt)
    case failure(OperationFailure)
    case stale
}

public protocol HarmonyPackageInstalling: Sendable {
    func install(packageURL: URL, transportID: String, operationID: UUID,
                 replaceExisting: Bool,
                 validateSession: @escaping @Sendable () async throws -> Void) async throws -> HarmonyPackageInstallReceipt
}

/// HDC installs native packages, not Android APKs. This first slice intentionally
/// accepts one HAP; HSP and API-version-dependent APP bundles require other flows.
public actor HDCPackageInstaller: HarmonyPackageInstalling {
    public static let maximumPackageBytes: Int64 = 512 * 1_024 * 1_024
    public static let apkUnsupportedMessage = "APK files cannot be installed natively through HDC on HarmonyOS NEXT. Send file only copies the APK; third-party compatibility support varies."
    public static let interruptedMessage = "Installation was interrupted. It may already have completed on the device. Check the device before retrying."
    private let hdcURL: URL
    private let runner: any HostCommandRunning

    public init(hdcURL: URL, runner: any HostCommandRunning) {
        self.hdcURL = hdcURL
        self.runner = runner
    }

    public func install(packageURL: URL, transportID: String, operationID: UUID,
                        replaceExisting: Bool,
                        validateSession: @escaping @Sendable () async throws -> Void) async throws -> HarmonyPackageInstallReceipt {
        try Task.checkCancellation()
        guard packageURL.isFileURL else { throw unreadablePackage() }
        let kind = packageURL.pathExtension.lowercased()
        if kind == "apk" {
            throw OperationFailure(code: .unsupported, safeMessage: Self.apkUnsupportedMessage)
        }
        guard kind == "hap" else {
            throw OperationFailure(code: .unsupported, safeMessage: "Choose one signed HarmonyOS HAP package. APK, HSP and APP installation are not supported by this action.")
        }
        // HDC's bundle manager may update by default even without -r. Never imply
        // omitting the flag protects an existing app. The UI discloses this first.
        guard replaceExisting else {
            throw OperationFailure(code: .restricted, safeMessage: "Confirm installation or update first. HDC may replace an installed app with the same bundle ID.")
        }
        let allowedTarget = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-[]%")
        guard !transportID.isEmpty, !transportID.hasPrefix("-"),
              transportID.unicodeScalars.allSatisfy({ allowedTarget.contains($0) }) else {
            throw OperationFailure(code: .disconnected, safeMessage: "No valid HDC target is selected.")
        }
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: packageURL.path) }
        catch { throw unreadablePackage() }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber,
              size.int64Value > 0, size.int64Value <= Self.maximumPackageBytes else {
            throw unreadablePackage()
        }
        try await validateSession()
        // HDC re-parses argv internally. A private snapshot with a generated ASCII
        // pathname avoids quote/newline/option interpretation and source mutation.
        let staging = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("devicebridge-hdc-install-" + UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        } catch { throw unreadablePackage() }
        defer { try? FileManager.default.removeItem(at: staging) }
        let snapshot = staging.appendingPathComponent("package.hap")
        do { try FileManager.default.copyItem(at: packageURL, to: snapshot) }
        catch { throw unreadablePackage() }
        let snapshotAttributes = try FileManager.default.attributesOfItem(atPath: snapshot.path)
        guard snapshotAttributes[.type] as? FileAttributeType == .typeRegular,
              let snapshotSize = snapshotAttributes[.size] as? NSNumber,
              snapshotSize.int64Value > 0,
              snapshotSize.int64Value <= Self.maximumPackageBytes else { throw unreadablePackage() }
        try Task.checkCancellation()
        try await validateSession()
        let result = try await runner.run(HostCommandRequest(
            executableURL: hdcURL,
            arguments: ["-t", transportID, "install", "-r", snapshot.path],
            timeout: .seconds(300), maximumOutputBytes: 256 * 1_024
        ))
        try Task.checkCancellation()
        guard Self.isConfirmedSuccess(result) else {
            throw OperationFailure(code: .failure,
                safeMessage: "HDC did not confirm installation. Check package signing, device authorization, storage and version compatibility.",
                recoveryAction: "Use a signed HAP allowed on this device. Do not uninstall an existing app to work around a signing error.")
        }
        return HarmonyPackageInstallReceipt(fileName: packageURL.lastPathComponent,
                                            byteLength: snapshotSize.int64Value)
    }

    static func isConfirmedSuccess(_ result: HostCommandResult) -> Bool {
        guard result.exitCode == 0 else { return false }
        let output = (result.standardOutputString + "\n" + result.standardErrorString).lowercased()
        // AppMod finish and host exit zero only mean the queue/connection ended.
        // Require the bundle manager success message and fail closed on errors.
        guard !["[fail]", "[error]", "failed", "failure", "error:", "errorcode", "permission denied", "unauthorized"]
            .contains(where: output.contains) else { return false }
        return output.split(whereSeparator: \.isNewline).contains { line in
            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if text == "install bundle successfully." || text == "install bundle successfully"
                || text == "msg:install bundle successfully." || text == "msg:install bundle successfully"
                || text == "msg: install bundle successfully." || text == "msg: install bundle successfully" { return true }
            // Huawei/current HDC prepend the package path; OpenHarmony 4/5 also
            // includes queuesize. Read the final message field, never the path.
            guard text.hasPrefix("[info]app install path:") || text.hasPrefix("app install path:"),
                  let range = text.range(of: "msg:", options: .backwards) else { return false }
            let message = text[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            return message == "install bundle successfully." || message == "install bundle successfully"
        }
    }

    private func unreadablePackage() -> OperationFailure {
        OperationFailure(code: .restricted,
            safeMessage: "Choose a readable, nonempty HAP file no larger than 512 MiB.")
    }
}

/// Binds side effects and publication to the selected device session, including
/// a second session check after preparing the local package snapshot.
public actor HarmonyPackageInstallService {
    private let store: DeviceSessionStore
    private let installer: any HarmonyPackageInstalling
    private let session: ConnectionSession
    private var isInstalling = false

    public init(store: DeviceSessionStore, installer: any HarmonyPackageInstalling,
                session: ConnectionSession) {
        self.store = store
        self.installer = installer
        self.session = session
    }

    public func install(packageURL: URL, replaceExisting: Bool = false) async -> HarmonyPackageInstallOutcome {
        guard session.deviceIdentity.platform == .harmonyOS else {
            return .failure(OperationFailure(code: .unsupported,
                safeMessage: "Select a HarmonyOS device to install a HAP package."))
        }
        guard !isInstalling else {
            return .failure(OperationFailure(code: .failure, safeMessage: "An installation is already in progress."))
        }
        isInstalling = true
        defer { isInstalling = false }
        let token: SessionToken
        do {
            try Task.checkCancellation()
            token = try await store.beginOperation(.packageInstall, expectedSession: session)
        } catch is CancellationError { return interrupted() }
        catch {
            return .failure(OperationFailure(code: .disconnected,
                safeMessage: "No available device session. Reconnect and retry."))
        }
        do {
            let receipt = try await installer.install(packageURL: packageURL, transportID: token.transportID,
                operationID: token.operationID, replaceExisting: replaceExisting,
                validateSession: { [store] in
                    try Task.checkCancellation()
                    guard await store.canPublish(token) else { throw DeviceSessionStoreError.staleSession }
                })
            try Task.checkCancellation()
            guard await store.finishOperation(token) else { return .stale }
            return .installed(receipt)
        } catch {
            guard await store.finishOperation(token) else { return .stale }
            if error is CancellationError || error as? HostCommandError == .cancelled { return interrupted() }
            if error as? HostCommandError == .timedOut {
                return .failure(OperationFailure(code: .timeout,
                    safeMessage: "Installation timed out. It may already have completed on the device. Check the device before retrying."))
            }
            if let failure = error as? OperationFailure { return .failure(failure) }
            return .failure(OperationFailure(code: .failure,
                safeMessage: "HDC installation could not be completed. Check the connection and package, then retry."))
        }
    }

    private func interrupted() -> HarmonyPackageInstallOutcome {
        .failure(OperationFailure(code: .cancelled, safeMessage: HDCPackageInstaller.interruptedMessage))
    }
}
