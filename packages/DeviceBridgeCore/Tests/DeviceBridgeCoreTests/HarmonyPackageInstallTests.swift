import Foundation
import Testing
@testable import DeviceBridgeCore

@Suite("HDC native HAP installation")
struct HarmonyPackageInstallTests {
    @Test func sendsOnlySafeSnapshotToCapturedTarget() async throws {
        let file = try PackageFixture(name: "测试 \"' $name\n.HAP")
        defer { file.remove() }
        let runner = PackageRunner()
        let installer = HDCPackageInstaller(hdcURL: URL(fileURLWithPath: "/hdc"), runner: runner)
        let receipt = try await installer.install(packageURL: file.url, transportID: "192.0.2.4:8710",
            operationID: UUID(), replaceExisting: true, validateSession: {})
        #expect(receipt.fileName == file.url.lastPathComponent)
        #expect(receipt.byteLength == 7)
        let request = try #require(await runner.requests.first)
        #expect(Array(request.arguments.prefix(4)) == ["-t", "192.0.2.4:8710", "install", "-r"])
        let alias = try #require(request.arguments.last)
        #expect(alias.hasPrefix("/tmp/devicebridge-hdc-install-"))
        #expect(alias.hasSuffix("/package.hap"))
        #expect(!alias.contains(" ") && !alias.contains("'") && !alias.contains("\n"))
        #expect(await runner.snapshot == Data("PK\u{3}\u{4}hap".utf8))
        #expect(!FileManager.default.fileExists(atPath: alias))
        #expect(request.timeout == .seconds(300))
        #expect(request.maximumOutputBytes == 256 * 1_024)
    }

    @Test(arguments: ["apk", "hsp", "app", "txt"])
    func rejectsUnsupportedPackagesBeforeAnyCommand(ext: String) async throws {
        let file = try PackageFixture(name: "package." + ext)
        defer { file.remove() }
        let runner = PackageRunner()
        let installer = HDCPackageInstaller(hdcURL: URL(fileURLWithPath: "/hdc"), runner: runner)
        do {
            _ = try await installer.install(packageURL: file.url, transportID: "ABC", operationID: UUID(),
                replaceExisting: true, validateSession: {})
            Issue.record("Unsupported extension was installed")
        } catch let failure as OperationFailure {
            #expect(failure.code == .unsupported)
            if ext == "apk" { #expect(failure.safeMessage.contains("only copies")) }
        }
        #expect(await runner.requests.isEmpty)
    }

    @Test func requiresExplicitReplacementAcknowledgment() async throws {
        let file = try PackageFixture()
        defer { file.remove() }
        let runner = PackageRunner()
        let installer = HDCPackageInstaller(hdcURL: URL(fileURLWithPath: "/hdc"), runner: runner)
        await #expect(throws: OperationFailure.self) {
            try await installer.install(packageURL: file.url, transportID: "ABC", operationID: UUID(),
                replaceExisting: false, validateSession: {})
        }
        #expect(await runner.requests.isEmpty)
    }

    @Test(arguments: ["", "-t", "abc def", "abc\";x", "a\nb", "a\0b", "a\\b"])
    func rejectsAmbiguousTargets(target: String) async throws {
        let file = try PackageFixture()
        defer { file.remove() }
        let runner = PackageRunner()
        let installer = HDCPackageInstaller(hdcURL: URL(fileURLWithPath: "/hdc"), runner: runner)
        await #expect(throws: OperationFailure.self) {
            try await installer.install(packageURL: file.url, transportID: target, operationID: UUID(),
                replaceExisting: true, validateSession: {})
        }
        #expect(await runner.requests.isEmpty)
    }

    @Test func rejectsNonregularEmptyAndOversizedSources() async throws {
        let file = try PackageFixture()
        defer { file.remove() }
        let root = file.url.deletingLastPathComponent()
        let empty = root.appendingPathComponent("empty.hap")
        try Data().write(to: empty)
        let huge = root.appendingPathComponent("huge.hap")
        _ = FileManager.default.createFile(atPath: huge.path, contents: nil)
        let handle = try FileHandle(forWritingTo: huge)
        try handle.truncate(atOffset: UInt64(HDCPackageInstaller.maximumPackageBytes + 1))
        try handle.close()
        let dir = root.appendingPathComponent("dir.hap")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        let symlink = root.appendingPathComponent("link.hap")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: file.url)
        let runner = PackageRunner()
        let installer = HDCPackageInstaller(hdcURL: URL(fileURLWithPath: "/hdc"), runner: runner)
        for url in [empty, huge, dir, symlink, root.appendingPathComponent("missing.hap"), URL(string: "https://example.invalid/package.hap")!] {
            await #expect(throws: OperationFailure.self) {
                try await installer.install(packageURL: url, transportID: "ABC", operationID: UUID(),
                    replaceExisting: true, validateSession: {})
            }
        }
        #expect(await runner.requests.isEmpty)
    }

    @Test func rejectsUnconfirmedAndMixedFailureOutput() {
        for output in ["", "AppMod finish", "FileTransfer finish", "[Fail] install bundle successfully.",
                       "msg:install bundle successfully.\nerror: failed", "not install bundle successfully.",
                       "App install path:/tmp/install bundle successfully."] {
            #expect(!HDCPackageInstaller.isConfirmedSuccess(.init(exitCode: 0,
                standardOutput: Data(output.utf8), standardError: Data())))
        }
        #expect(!HDCPackageInstaller.isConfirmedSuccess(.init(exitCode: 1,
            standardOutput: Data("install bundle successfully.\n".utf8), standardError: Data())))
        #expect(!HDCPackageInstaller.isConfirmedSuccess(.init(exitCode: 0,
            standardOutput: Data("install bundle successfully.\n".utf8), standardError: Data("[Fail] unauthorized".utf8))))
        #expect(HDCPackageInstaller.isConfirmedSuccess(.init(exitCode: 0,
            standardOutput: Data("msg:install bundle successfully.\nAppMod finish\n".utf8), standardError: Data())))
    }

    @Test(arguments: [
        "[Info]App install path:/tmp/package.hap msg:install bundle successfully.",
        "[Info]App install path:/tmp/package.hap, queuesize:0, msg:install bundle successfully."
    ])
    func acceptsDocumentedHDCVersionOutput(output: String) {
        #expect(HDCPackageInstaller.isConfirmedSuccess(.init(exitCode: 0,
            standardOutput: Data(output.utf8), standardError: Data())))
    }

    @Test func failedCommandCleansSnapshot() async throws {
        let file = try PackageFixture()
        defer { file.remove() }
        let runner = PackageRunner(output: "AppMod finish")
        let installer = HDCPackageInstaller(hdcURL: URL(fileURLWithPath: "/hdc"), runner: runner)
        await #expect(throws: OperationFailure.self) {
            try await installer.install(packageURL: file.url, transportID: "ABC", operationID: UUID(),
                replaceExisting: true, validateSession: {})
        }
        let path = try #require(await runner.requests.first?.arguments.last)
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func sessionRecheckedAfterSnapshotBeforeLaunching() async throws {
        let file = try PackageFixture()
        defer { file.remove() }
        let runner = PackageRunner()
        let installer = HDCPackageInstaller(hdcURL: URL(fileURLWithPath: "/hdc"), runner: runner)
        let validity = PackageValidity()
        await #expect(throws: DeviceSessionStoreError.staleSession) {
            try await installer.install(packageURL: file.url, transportID: "ABC", operationID: UUID(),
                replaceExisting: true, validateSession: { try await validity.check() })
        }
        #expect(await validity.checks == 2)
        #expect(await runner.requests.isEmpty)
    }

    @Test func boundOldSessionNeverInstallsNewDevice() async throws {
        let (store, session) = try await packageSession()
        let other = try packageDevice("Other")
        await store.replaceInventory([try packageDevice("ABC"), other])
        _ = try await store.select(other.identity)
        let runner = PackageRunner()
        let service = HarmonyPackageInstallService(store: store,
            installer: HDCPackageInstaller(hdcURL: URL(fileURLWithPath: "/hdc"), runner: runner), session: session)
        let result = await service.install(packageURL: URL(fileURLWithPath: "/unused.hap"), replaceExisting: true)
        guard case .failure = result else { Issue.record("Expected rejection"); return }
        #expect(await runner.requests.isEmpty)
    }

    @Test func switchDuringInstallationDiscardsResult() async throws {
        let file = try PackageFixture()
        defer { file.remove() }
        let (store, session) = try await packageSession()
        let runner = PackageRunner(beforeReturn: {
            await store.replaceInventory([try packageDevice("ABC"), try packageDevice("Other")])
            _ = try await store.select(packageDevice("Other").identity)
        })
        let service = HarmonyPackageInstallService(store: store,
            installer: HDCPackageInstaller(hdcURL: URL(fileURLWithPath: "/hdc"), runner: runner), session: session)
        #expect(await service.install(packageURL: file.url, replaceExisting: true) == .stale)
        #expect(await runner.requests.first?.arguments[1] == "ABC")
    }

    @Test(arguments: [HostCommandError.timedOut, .cancelled, .launchFailed])
    func commandFailuresDoNotClaimInstallation(error: HostCommandError) async throws {
        let file = try PackageFixture()
        defer { file.remove() }
        let (store, session) = try await packageSession()
        let runner = PackageRunner(error: error)
        let service = HarmonyPackageInstallService(store: store,
            installer: HDCPackageInstaller(hdcURL: URL(fileURLWithPath: "/hdc"), runner: runner), session: session)
        let outcome = await service.install(packageURL: file.url, replaceExisting: true)
        guard case let .failure(failure) = outcome else { Issue.record("Expected failure"); return }
        if error == .timedOut || error == .cancelled {
            #expect(failure.safeMessage.contains("may already have completed"))
        }
        #expect((await store.snapshot()).activeOperationIDs.isEmpty)
        let alias = try #require(await runner.requests.first?.arguments.last)
        #expect(!FileManager.default.fileExists(atPath: alias))
    }

    @Test func successfullyInstalledReceiptAndOperationCleanup() async throws {
        let file = try PackageFixture()
        defer { file.remove() }
        let (store, session) = try await packageSession()
        let service = HarmonyPackageInstallService(store: store,
            installer: HDCPackageInstaller(hdcURL: URL(fileURLWithPath: "/hdc"), runner: PackageRunner()), session: session)
        guard case let .installed(receipt) = await service.install(packageURL: file.url, replaceExisting: true)
        else { Issue.record("Expected installed"); return }
        #expect(receipt.byteLength == 7)
        #expect((await store.snapshot()).activeOperationIDs.isEmpty)
    }

    @Test func duplicateInstallIsBlockedWhileCommandDrains() async throws {
        let file = try PackageFixture()
        defer { file.remove() }
        let (store, session) = try await packageSession()
        let gate = InstallGate()
        let runner = PackageRunner(beforeReturn: { await gate.pause() })
        let service = HarmonyPackageInstallService(store: store,
            installer: HDCPackageInstaller(hdcURL: URL(fileURLWithPath: "/hdc"), runner: runner), session: session)
        let first = Task { await service.install(packageURL: file.url, replaceExisting: true) }
        await gate.waitUntilEntered()
        let second = await service.install(packageURL: file.url, replaceExisting: true)
        guard case let .failure(failure) = second else {
            await gate.release(); _ = await first.value
            Issue.record("Expected duplicate rejection"); return
        }
        #expect(failure.safeMessage.contains("already in progress"))
        await gate.release()
        guard case .installed = await first.value else { Issue.record("First install did not finish"); return }
        #expect(await runner.requests.count == 1)
    }

    @Test func cancellationAfterCommandStartedDoesNotPublishSuccess() async throws {
        let file = try PackageFixture()
        defer { file.remove() }
        let (store, session) = try await packageSession()
        let gate = InstallGate()
        let runner = PackageRunner(beforeReturn: { await gate.pause() })
        let service = HarmonyPackageInstallService(store: store,
            installer: HDCPackageInstaller(hdcURL: URL(fileURLWithPath: "/hdc"), runner: runner), session: session)
        let task = Task { await service.install(packageURL: file.url, replaceExisting: true) }
        await gate.waitUntilEntered()
        task.cancel()
        await gate.release()
        guard case let .failure(failure) = await task.value else { Issue.record("Expected cancellation"); return }
        #expect(failure.code == .cancelled)
        #expect(failure.safeMessage.contains("may already have completed"))
        #expect((await store.snapshot()).activeOperationIDs.isEmpty)
        let alias = try #require(await runner.requests.first?.arguments.last)
        #expect(!FileManager.default.fileExists(atPath: alias))
    }

    @Test func serviceRejectsNonHarmonySession() async throws {
        let (store, session) = try await packageSession(platform: .android)
        let runner = PackageRunner()
        let service = HarmonyPackageInstallService(store: store,
            installer: HDCPackageInstaller(hdcURL: URL(fileURLWithPath: "/hdc"), runner: runner), session: session)
        guard case let .failure(failure) = await service.install(packageURL: URL(fileURLWithPath: "/unused.hap"), replaceExisting: true)
        else { Issue.record("Expected unsupported"); return }
        #expect(failure.code == .unsupported)
        #expect(await runner.requests.isEmpty)
    }
}

private struct PackageFixture {
    let url: URL
    init(name: String = "package.hap") throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hap-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        url = root.appendingPathComponent(name)
        try Data("PK\u{3}\u{4}hap".utf8).write(to: url)
    }
    func remove() { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
}

private actor PackageRunner: HostCommandRunning {
    private(set) var requests: [HostCommandRequest] = []
    private(set) var snapshot: Data?
    let output: String
    let error: HostCommandError?
    let beforeReturn: (@Sendable () async throws -> Void)?
    init(output: String = "msg:install bundle successfully.\nAppMod finish\n",
         error: HostCommandError? = nil, beforeReturn: (@Sendable () async throws -> Void)? = nil) {
        self.output = output; self.error = error; self.beforeReturn = beforeReturn
    }
    func run(_ request: HostCommandRequest) async throws -> HostCommandResult {
        requests.append(request)
        if let path = request.arguments.last { snapshot = try Data(contentsOf: URL(fileURLWithPath: path)) }
        if let beforeReturn { try await beforeReturn() }
        if let error { throw error }
        return HostCommandResult(exitCode: 0, standardOutput: Data(output.utf8), standardError: Data())
    }
}

private actor PackageValidity {
    private(set) var checks = 0
    func check() throws {
        checks += 1
        if checks == 2 { throw DeviceSessionStoreError.staleSession }
    }
}

private func packageDevice(_ id: String, platform: DevicePlatform = .harmonyOS) throws -> DeviceRecord {
    let identity = try DeviceIdentity(rawValue: id, stability: .provisional, platform: platform)
    let transport = try TransportCandidate(id: id, identity: identity, kind: .usb,
        source: platform == .harmonyOS ? .hdc : .adb, status: .available, observedAt: Date())
    return DeviceRecord(identity: identity, name: id, authorization: .authorized,
        candidates: [transport], preferredTransportID: id)
}

private func packageSession(platform: DevicePlatform = .harmonyOS) async throws -> (DeviceSessionStore, ConnectionSession) {
    let store = DeviceSessionStore()
    let device = try packageDevice("ABC", platform: platform)
    await store.replaceInventory([device])
    _ = try await store.select(device.identity)
    return (store, try #require(await store.snapshot().session))
}

private actor InstallGate {
    private var entered = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var paused: CheckedContinuation<Void, Never>?
    func pause() async {
        await withCheckedContinuation { continuation in
            paused = continuation
            entered = true
            for waiter in waiters { waiter.resume() }
            waiters.removeAll()
        }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() { paused?.resume(); paused = nil }
}
