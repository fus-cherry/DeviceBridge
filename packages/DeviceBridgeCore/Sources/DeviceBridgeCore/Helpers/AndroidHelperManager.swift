import Foundation

public struct AndroidHelperConnection: Sendable, Equatable {
    public let transportID: String
    public let hostPort: Int

    public init(transportID: String, hostPort: Int) {
        self.transportID = transportID
        self.hostPort = hostPort
    }
}

public struct AndroidHelperPreparationOutcome: Sendable, Equatable {
    public let connection: AndroidHelperConnection?
    public let failure: OperationFailure?

    public init(connection: AndroidHelperConnection? = nil, failure: OperationFailure? = nil) {
        self.connection = connection
        self.failure = failure
    }
}

public actor AndroidHelperManager {
    public static let packageName = "dev.debugutility.helper"
    public static let componentName = "dev.debugutility.helper/.MainActivity"
    public static let socketName = "device_bridge_helper"
    public static let requestKeepAlivePermissionAction =
        "dev.debugutility.helper.action.REQUEST_KEEPALIVE_PERMISSION"

    private let adbURL: URL
    private let apkURL: URL
    private let expectedVersionCode: Int
    private let runner: any HostCommandRunning
    private let readinessTimeout: Duration
    private var activeConnection: AndroidHelperConnection?
    private var preparing = false
    private var releasing = false
    private var generation: UInt64 = 0

    public init(
        adbURL: URL,
        apkURL: URL,
        expectedVersionCode: Int,
        runner: any HostCommandRunning,
        readinessTimeout: Duration = .seconds(10)
    ) {
        self.adbURL = adbURL
        self.apkURL = apkURL
        self.expectedVersionCode = expectedVersionCode
        self.runner = runner
        self.readinessTimeout = readinessTimeout
    }

    public func prepare(transportID: String) async -> AndroidHelperPreparationOutcome {
        guard !preparing, !releasing else { return connectionFailure() }
        preparing = true
        defer { preparing = false }
        if let activeConnection, activeConnection.transportID == transportID {
            return AndroidHelperPreparationOutcome(connection: activeConnection)
        }
        // Account for our own stop, but not an additional stop/detach while it awaits cleanup.
        let attempt = activeConnection == nil ? generation : generation &+ 1
        if activeConnection != nil { await stop() }
        guard isCurrent(attempt) else { return cancelledPreparation() }

        let installedVersion = await detectVersion(transportID: transportID)
        guard isCurrent(attempt) else { return cancelledPreparation() }
        guard let installedVersion else {
            let inventory = await run(arguments: packageDetailsArguments(transportID: transportID))
            guard isCurrent(attempt) else { return cancelledPreparation() }
            guard inventory?.exitCode == 0 else {
                return connectionFailure()
            }
            guard await install(transportID: transportID) else { return installFailure() }
            guard isCurrent(attempt) else { return cancelledPreparation() }
            guard await detectVersion(transportID: transportID) == expectedVersionCode else {
                return installFailure()
            }
            return await startAndForward(transportID: transportID, attempt: attempt)
        }

        if installedVersion != expectedVersionCode {
            guard await install(transportID: transportID) else { return installFailure() }
            guard isCurrent(attempt) else { return cancelledPreparation() }
            guard await detectVersion(transportID: transportID) == expectedVersionCode else {
                return installFailure()
            }
        }
        return await startAndForward(transportID: transportID, attempt: attempt)
    }

    public func stop() async {
        generation &+= 1
        guard let connection = activeConnection else { return }
        activeConnection = nil
        releasing = true
        defer { releasing = false }
        await release(connection, stopHelper: true)
    }

    /// Release the old route without stopping a helper that is being resumed on another route.
    public func detach() async {
        generation &+= 1
        guard let connection = activeConnection else { return }
        activeConnection = nil
        releasing = true
        defer { releasing = false }
        let request = HostCommandRequest(executableURL: adbURL, arguments: [
            "-t", connection.transportID, "forward", "--remove", "tcp:\(connection.hostPort)"
        ], timeout: .seconds(3), maximumOutputBytes: 4_096)
        let runner = runner
        _ = await Task.detached { try? await runner.run(request) }.value
    }

    /// Only for a route whose existing helper identity has been verified. The caller must
    /// authenticate the returned channel with the existing nonce before publishing readiness.
    public func reattach(transportID: String) async -> AndroidHelperPreparationOutcome {
        guard !preparing, !releasing, activeConnection == nil else { return connectionFailure() }
        preparing = true
        defer { preparing = false }
        let attempt = generation
        guard let result = await run(arguments: ["-t", transportID, "forward", "tcp:0",
            "localabstract:\(Self.socketName)"]), result.exitCode == 0,
              let port = Int(result.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1...65_535).contains(port) else {
            return connectionFailure()
        }
        let connection = AndroidHelperConnection(transportID: transportID, hostPort: port)
        guard isCurrent(attempt) else {
            await release(connection, stopHelper: false)
            return cancelledPreparation()
        }
        activeConnection = connection
        if Task.isCancelled { await detach(); return connectionFailure() }
        return AndroidHelperPreparationOutcome(connection: connection)
    }

    /// This may foreground the helper and is only called from the user's explicit Wi-Fi
    /// maintenance action. Ordinary connection and clipboard preparation never request it.
    public func requestKeepAliveNotificationPermission(transportID: String) async -> Bool {
        guard let result = await run(arguments: [
            "-t", transportID,
            "shell", "am", "start",
            "-a", Self.requestKeepAlivePermissionAction,
            "-n", Self.componentName,
        ]) else { return false }
        return result.exitCode == 0
    }

    private func detectVersion(transportID: String) async -> Int? {
        guard let result = await run(arguments: packageDetailsArguments(transportID: transportID)),
              result.exitCode == 0 else { return nil }
        guard let marker = result.standardOutputString.range(of: "versionCode=") else { return nil }
        let suffix = result.standardOutputString[marker.upperBound...]
        let digits = suffix.prefix(while: \Character.isNumber)
        return Int(digits)
    }

    private func packageDetailsArguments(transportID: String) -> [String] {
        ["-t", transportID, "shell", "dumpsys", "package", Self.packageName]
    }

    private func install(transportID: String) async -> Bool {
        guard let result = await run(arguments: [
            "-t", transportID, "install", "-r", apkURL.path,
        ]) else { return false }
        return result.exitCode == 0
            && result.standardOutputString.localizedCaseInsensitiveContains("success")
    }

    private func startAndForward(transportID: String, attempt: UInt64) async -> AndroidHelperPreparationOutcome {
        guard isCurrent(attempt) else { return cancelledPreparation() }
        guard let reset = await run(arguments: [
            "-t", transportID,
            "shell", "am", "force-stop", Self.packageName,
        ]), reset.exitCode == 0 else {
            return AndroidHelperPreparationOutcome(failure: OperationFailure(
                code: .helperMissing,
                safeMessage: "The previous Android helper session could not be reset.",
                recoveryAction: "Unlock the device and retry."
            ))
        }
        guard isCurrent(attempt) else { return cancelledPreparation() }

        guard let forward = await run(arguments: [
            "-t", transportID,
            "forward", "tcp:0", "localabstract:\(Self.socketName)",
        ]), forward.exitCode == 0,
              let hostPort = Int(forward.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1...65_535).contains(hostPort) else {
            return AndroidHelperPreparationOutcome(failure: OperationFailure(
                code: .failure,
                safeMessage: "The Android helper channel could not be created.",
                recoveryAction: "Reconnect the device and retry."
            ))
        }

        // This local candidate owns the forward until readiness commits it below.
        // stop/detach invalidate the generation; only this attempt cleans its candidate.
        let connection = AndroidHelperConnection(transportID: transportID, hostPort: hostPort)
        guard isCurrent(attempt) else {
            await release(connection, stopHelper: true)
            return cancelledPreparation()
        }

        guard let start = await run(arguments: [
            "-t", transportID,
            "shell", "am", "start", "-n", Self.componentName,
        ]), start.exitCode == 0 else {
            await release(connection, stopHelper: true)
            return AndroidHelperPreparationOutcome(failure: OperationFailure(
                code: .helperMissing,
                safeMessage: "The Android helper could not be started.",
                recoveryAction: "Unlock the device and open the helper."
            ))
        }

        guard await waitUntilReady(transportID: transportID, attempt: attempt), isCurrent(attempt) else {
            let cancelled = !isCurrent(attempt)
            await release(connection, stopHelper: true)
            if cancelled { return cancelledPreparation() }
            return AndroidHelperPreparationOutcome(failure: OperationFailure(
                code: .timeout,
                safeMessage: "The Android helper did not become ready in time.",
                recoveryAction: "Unlock the device, resolve any permission dialog, and retry with the helper visible."
            ))
        }
        activeConnection = connection
        return AndroidHelperPreparationOutcome(connection: connection)
    }

    private func isCurrent(_ attempt: UInt64) -> Bool {
        attempt == generation && !Task.isCancelled
    }

    private func cancelledPreparation() -> AndroidHelperPreparationOutcome {
        AndroidHelperPreparationOutcome(failure: OperationFailure(
            code: .cancelled, safeMessage: "Android helper preparation cancelled."
        ))
    }

    private func waitUntilReady(transportID: String, attempt: UInt64) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: readinessTimeout)
        while isCurrent(attempt), clock.now < deadline {
            do {
                let sockets = try await runner.run(HostCommandRequest(executableURL: adbURL,
                    arguments: ["-t", transportID, "shell", "cat", "/proc/net/unix"],
                    timeout: min(.seconds(2), clock.now.duration(to: deadline)), maximumOutputBytes: 2 * 1_024 * 1_024))
                guard isCurrent(attempt), clock.now < deadline else { return false }
                let listening = sockets.exitCode == 0 && sockets.standardOutputString
                    .split(whereSeparator: \.isNewline).contains { line in
                        let fields = line.split(whereSeparator: \.isWhitespace)
                        return fields.count >= 8 && fields[3] == "00010000"
                            && fields.last == "@\(Self.socketName)"
                    }
                if listening {
                    let windows = try await runner.run(HostCommandRequest(executableURL: adbURL,
                        arguments: ["-t", transportID, "shell", "dumpsys", "window"],
                        timeout: min(.seconds(2), clock.now.duration(to: deadline)), maximumOutputBytes: 2 * 1_024 * 1_024))
                    guard isCurrent(attempt), clock.now < deadline else { return false }
                    if windows.exitCode == 0 && windows.standardOutputString.split(whereSeparator: \.isNewline)
                        .contains(where: { $0.contains("mCurrentFocus=") && $0.contains(" \(Self.packageName)/") }) {
                        return true
                    }
                }
                try await Task.sleep(for: min(.milliseconds(200), clock.now.duration(to: deadline)))
            } catch {
                // A denied probe or lost transport is not evidence of readiness.
                return false
            }
        }
        return false
    }

    private func release(_ connection: AndroidHelperConnection, stopHelper: Bool) async {
        let runner = runner
        let adbURL = adbURL
        // Cleanup must run even when the caller's task has been cancelled.
        await Task.detached {
            _ = try? await runner.run(HostCommandRequest(executableURL: adbURL,
                arguments: ["-t", connection.transportID, "forward", "--remove", "tcp:\(connection.hostPort)"],
                timeout: .seconds(3), maximumOutputBytes: 4_096))
            if stopHelper {
                _ = try? await runner.run(HostCommandRequest(executableURL: adbURL,
                    arguments: ["-t", connection.transportID, "shell", "am", "force-stop", Self.packageName],
                    timeout: .seconds(3), maximumOutputBytes: 4_096))
            }
        }.value
    }

    private func run(arguments: [String]) async -> HostCommandResult? {
        do {
            return try await runner.run(HostCommandRequest(
                executableURL: adbURL,
                arguments: arguments,
                timeout: .seconds(15),
                maximumOutputBytes: 64 * 1_024
            ))
        } catch {
            return nil
        }
    }

    private func connectionFailure() -> AndroidHelperPreparationOutcome {
        AndroidHelperPreparationOutcome(failure: OperationFailure(
            code: .disconnected,
            safeMessage: "The Android device did not accept helper commands.",
            recoveryAction: "Unlock, authorize, or reconnect the device."
        ))
    }

    private func installFailure() -> AndroidHelperPreparationOutcome {
        AndroidHelperPreparationOutcome(failure: OperationFailure(
            code: .helperMissing,
            safeMessage: "The compatible Android helper could not be installed.",
            recoveryAction: "Allow app installation over USB and retry."
        ))
    }
}
