import Foundation
import Testing
@testable import DeviceBridgeCore

@Suite("HarmonyOS verified debug file sending")
struct HarmonyFileSendTests {
    @Test func verifiedSendUsesOnlySafeAliasesAndCapturedTarget() async throws {
        let (url, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = HarmonySendRunner()
        let receipt = try await send(url, runner: runner, name: "nested/hello ' $(touch BAD);\n.txt")
        #expect(receipt == DeviceFileReceipt(byteLength: 5, sha256: try FileIntegrity.metadata(for: url).sha256))
        let requests = await runner.requests
        #expect(requests.allSatisfy { Array($0.arguments.prefix(2)) == ["-t", "ABC:8710"] })
        let transfer = try #require(requests.first { $0.arguments.contains("send") })
        #expect(transfer.arguments[4].hasPrefix("/tmp/devicebridge-send-"))
        #expect(transfer.arguments[5].hasPrefix("/data/local/tmp/.devicebridge-send-"))
        #expect(!transfer.arguments[4].contains(" "))
        #expect(!transfer.arguments[5].contains(" "))
        #expect(!FileManager.default.fileExists(atPath: transfer.arguments[4]))
        let commit = try #require(requests.first { $0.arguments.last?.contains("DBSEND_COMMITTED") == true }?.arguments.last)
        #expect(commit.contains("ln -T "))
        #expect(!commit.contains("mv -fT"))
        #expect(commit.contains("hello '\\'' $(touch BAD);\n.txt'"))
        #expect(commit.contains("sha256sum"))
        #expect(commit.contains("test ! -L"))
        #expect(await runner.aliasContents == Data("hello".utf8))
    }

    @Test func explicitReplaceUsesNonDirectoryRenameAfterFileGuard() async throws {
        let (url, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = HarmonySendRunner()
        _ = try await send(url, runner: runner, replace: true)
        let commit = try #require(await runner.requests.first { $0.arguments.last?.contains("DBSEND_COMMITTED") == true }?.arguments.last)
        #expect(commit.contains("mv -fT "))
        #expect(commit.contains("test -f '/data/local/tmp/file.txt'"))
        #expect(commit.contains("test ! -L '/data/local/tmp/file.txt'"))
    }

    @Test func sharedScopeAndMalformedTargetsNeverInvokeHDC() async throws {
        let runner = HarmonySendRunner()
        let provider = HarmonyFileProvider(hdcURL: URL(fileURLWithPath: "/hdc"), runner: runner)
        for scope in [DeviceFileScope.harmonySharedDocuments, .androidSharedDownloads] {
            await #expect(throws: OperationFailure.self) {
                try await provider.send(localURL: URL(fileURLWithPath: "/unused"),
                    destination: DeviceFileLocation(scope: scope, relativePath: "file.txt"),
                    transportID: "ABC", operationID: UUID(), replaceExisting: false)
            }
        }
        for target in ["", "-t", "bad target", "a;b", "a\n", "a\0b", "$(id)"] {
            await #expect(throws: OperationFailure.self) {
                try await provider.send(localURL: URL(fileURLWithPath: "/unused"),
                    destination: DeviceFileLocation(scope: .harmonyDebugFiles, relativePath: "file.txt"),
                    transportID: target, operationID: UUID(), replaceExisting: false)
            }
        }
        #expect(await runner.requests.isEmpty)
    }

    @Test func escapedCanonicalParentNeverStages() async throws {
        let (url, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = HarmonySendRunner(mode: .escapingParent)
        await #expect(throws: OperationFailure.self) { try await send(url, runner: runner) }
        #expect(await runner.requests.count == 1)
    }

    @Test func destinationConflictNeverSendsOrDeletes() async throws {
        let (url, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = HarmonySendRunner(mode: .conflict)
        await #expect(throws: OperationFailure.self) { try await send(url, runner: runner) }
        #expect(await runner.requests.count == 2)
        #expect(await runner.requests.allSatisfy { !$0.arguments.contains("send") && !$0.arguments.last!.contains("rm ") })
    }

    @Test(arguments: ["100", "101"])
    func publicMkdirDeniedWithZeroHostExitDoesNotSendOrDelete(userID: String) async throws {
        let (url, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = "/storage/media/\(userID)/local/files/Docs/Documents"
        let runner = HarmonySendRunner(mode: .setupMkdirDenied, approvedRoot: root)
        do {
            _ = try await send(url, runner: runner, name: "DeviceBridge-" + UUID().uuidString + "/file.txt",
                               scope: .harmonyUserDocuments(userID: userID))
            Issue.record("Expected public directory creation rejection")
        } catch let failure as OperationFailure {
            #expect(failure.code == .restricted)
            #expect(failure.safeMessage == "HarmonyOS denied creating a private transfer folder in the selected user's public Documents directory. No file was sent.")
            #expect(failure.recoveryAction == "You can explicitly choose HarmonyOS debug files for a temporary transfer, but that location is not guaranteed visible in the phone's file manager. DeviceBridge will not change permissions or switch destinations automatically.")
            #expect(!failure.safeMessage.contains(".devicebridge-send-"))
        }
        let requests = await runner.requests
        #expect(requests.count == 2) // Canonical parent lookup, then a denied setup only.
        let setup = try #require(requests.last?.arguments.last)
        #expect(setup.contains("test -w '" + root + "'"))
        #expect(setup.contains("'" + root + "\nx'")) // Keep the complete LF sentinel.
        #expect(setup.contains("umask 077; mkdir '" + root + "/.devicebridge-send-"))
        #expect(requests.allSatisfy { !$0.arguments.contains("send")
            && !$0.arguments.last!.contains("DBSEND_COMMITTED")
            && !$0.arguments.last!.contains("rm ") && !$0.arguments.last!.contains("rmdir ")
            && !$0.arguments.last!.contains("chmod") && !$0.arguments.last!.contains("chown")
            && !$0.arguments.last!.contains("/data/local/tmp") })
        #expect(await runner.aliasContents == nil)
    }

    @Test(arguments: ["silent", "permissionOnly", "mkdirOtherFailure", "separateLines", "contradictoryReady"])
    func publicSetupWithoutExplicitMkdirDenialDoesNotInventACause(scenario: String) async throws {
        let (url, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = switch scenario {
        case "permissionOnly": "Permission denied\n"
        case "mkdirOtherFailure": "mkdir: No space left on device\n"
        case "separateLines": "mkdir diagnostic\nPermission denied\n"
        case "contradictoryReady": "DBSEND_READY\nmkdir: Permission denied\n"
        default: ""
        }
        let runner = HarmonySendRunner(mode: .conflict,
            approvedRoot: "/storage/media/100/local/files/Docs/Documents", setupOutput: output)
        do {
            _ = try await send(url, runner: runner, name: "DeviceBridge-" + UUID().uuidString + "/file.txt",
                               scope: .harmonyUserDocuments(userID: "100"))
            Issue.record("Expected unconfirmed setup rejection")
        } catch let failure as OperationFailure {
            #expect(failure.code == .restricted)
            #expect(failure.safeMessage == "HDC did not confirm a safe private transfer folder in the selected user's public Documents directory. No file was sent.")
            #expect(failure.recoveryAction?.contains("does not change permissions or remove existing targets") == true)
        }
        #expect(await runner.requests.count == 2)
        #expect(await runner.requests.allSatisfy { !$0.arguments.contains("send") && !$0.arguments.last!.contains("rm ") })
    }

    @Test func zeroExitHDCFailureNeverCommitsAndCleansOnlyStage() async throws {
        let (url, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = HarmonySendRunner(mode: .transferFailure)
        await #expect(throws: OperationFailure.self) { try await send(url, runner: runner) }
        try await expectOnlyStageCleanup(runner)
        #expect(await runner.requests.allSatisfy { !$0.arguments.last!.contains("DBSEND_COMMITTED") })
    }

    @Test func integrityFailureNeverCommits() async throws {
        let (url, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = HarmonySendRunner(mode: .badHash)
        await #expect(throws: OperationFailure.self) { try await send(url, runner: runner) }
        try await expectOnlyStageCleanup(runner)
        #expect(await runner.requests.allSatisfy { !$0.arguments.last!.contains("DBSEND_COMMITTED") })
    }

    @Test func transferCancellationStillCleansStage() async throws {
        let (url, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = HarmonySendRunner(mode: .cancelTransfer)
        await #expect(throws: CancellationError.self) { try await send(url, runner: runner) }
        try await expectOnlyStageCleanup(runner)
        #expect(await runner.requests.allSatisfy { !$0.arguments.last!.contains("DBSEND_COMMITTED") })
    }

    @Test func commitInterruptionDoesNotClaimRollback() async throws {
        let (url, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = HarmonySendRunner(mode: .cancelCommit)
        do {
            _ = try await send(url, runner: runner)
            Issue.record("Expected interrupted commit")
        } catch let failure as OperationFailure {
            #expect(failure.safeMessage.contains("may already contain"))
        }
        try await expectOnlyStageCleanup(runner)
    }

    @Test func commitConflictNeverDeletesDestination() async throws {
        let (url, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = HarmonySendRunner(mode: .commitConflict)
        await #expect(throws: OperationFailure.self) { try await send(url, runner: runner) }
        try await expectOnlyStageCleanup(runner)
    }

    @Test func localSymlinkIsNotSent() async throws {
        let (url, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let link = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        let runner = HarmonySendRunner()
        await #expect(throws: OperationFailure.self) { try await send(link, runner: runner) }
        #expect(await runner.requests.isEmpty)
    }

    @Test func sourceMutationBeforeSnapshotNeverRunsHDC() async throws {
        let (url, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try FileIntegrity.metadata(for: url)
        // Same length, different bytes: size-only checking would miss this change.
        try Data("world".utf8).write(to: url)
        let runner = HarmonySendRunner()
        let provider = HarmonyFileProvider(hdcURL: URL(fileURLWithPath: "/hdc"), runner: runner)
        do {
            _ = try await provider.sendVerified(localURL: url,
                destination: DeviceFileLocation(scope: .harmonyDebugFiles, relativePath: "file.txt"),
                transportID: "ABC:8710", operationID: UUID(), replaceExisting: false,
                expectedMetadata: original, validateSession: {})
            Issue.record("Expected source mutation rejection")
        } catch let failure as OperationFailure {
            #expect(failure.code == .integrityMismatch)
            #expect(failure.safeMessage == "The source file changed before transfer. Select it again; no file was sent.")
        }
        #expect(await runner.requests.isEmpty)
    }

    @Test(arguments: [1, 2, 3])
    func sessionInvalidationStopsNextSideEffect(validationNumber: Int) async throws {
        let (url, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = HarmonySendRunner()
        let gate = HarmonySendSessionGate(rejectAt: validationNumber)
        let provider = HarmonyFileProvider(hdcURL: URL(fileURLWithPath: "/hdc"), runner: runner)
        do {
            _ = try await provider.sendVerified(localURL: url,
                destination: DeviceFileLocation(scope: .harmonyDebugFiles, relativePath: "file.txt"),
                transportID: "ABC:8710", operationID: UUID(), replaceExisting: false,
                expectedMetadata: FileIntegrity.metadata(for: url), validateSession: { try await gate.validate() })
            Issue.record("Expected invalidated session rejection")
        } catch let failure as OperationFailure {
            #expect(failure.code == .disconnected)
            #expect(failure.safeMessage == "Captured session is no longer active.")
        }
        let requests = await runner.requests
        #expect(requests.allSatisfy { !$0.arguments.last!.contains("DBSEND_COMMITTED") })
        if validationNumber == 1 {
            #expect(requests.count == 1) // Only canonical path lookup, no mkdir.
            #expect(requests.allSatisfy { !$0.arguments.last!.contains("DBSEND_READY") })
        } else {
            try await expectOnlyStageCleanup(runner)
        }
        if validationNumber <= 2 {
            #expect(requests.allSatisfy { !$0.arguments.contains("send") })
        } else {
            #expect(requests.contains { $0.arguments.last!.contains("DBSEND_VERIFIED") })
        }
    }

    @Test(arguments: ["100", "101"])
    func publicDocumentsStagesWithinSelectedUserRoot(userID: String) async throws {
        let (url, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = "/storage/media/\(userID)/local/files/Docs/Documents"
        let runner = HarmonySendRunner(approvedRoot: root)
        _ = try await send(url, runner: runner, name: "DeviceBridge-" + UUID().uuidString + "/file.txt", scope: .harmonyUserDocuments(userID: userID))
        let requests = await runner.requests
        let transfer = try #require(requests.first { $0.arguments.contains("send") })
        #expect(transfer.arguments[5].hasPrefix(root + "/.devicebridge-send-"))
        #expect(requests.allSatisfy { !$0.arguments.joined(separator: " ").contains("/data/local/tmp") })
        let commit = try #require(requests.first { $0.arguments.last!.contains("DBSEND_COMMITTED") }?.arguments.last)
        #expect(commit.contains("stat -c %d"))
        #expect(!commit.contains("ln -T"))
        #expect(commit.contains("if mkdir"))
        #expect(commit.contains("mv -T"))
        #expect(commit.contains("sha256sum"))
    }

    @Test(arguments: ["escapingParent", "redirectedRoot", "conflict"])
    func publicDocumentsUnsafeOrUnavailableRootNeverFallsBack(scenario: String) async throws {
        let mode: HarmonySendRunner.Mode = scenario == "escapingParent" ? .escapingParent : scenario == "redirectedRoot" ? .redirectedRoot : .conflict
        let (url, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = "/storage/media/101/local/files/Docs/Documents"
        let runner = HarmonySendRunner(mode: mode, approvedRoot: root)
        await #expect(throws: OperationFailure.self) {
            try await send(url, runner: runner, name: "DeviceBridge-" + UUID().uuidString + "/file.txt", scope: .harmonyUserDocuments(userID: "101"))
        }
        let requests = await runner.requests
        #expect(requests.allSatisfy { !$0.arguments.contains("send") })
        #expect(requests.allSatisfy { !$0.arguments.joined(separator: " ").contains("/data/local/tmp") })
        #expect(requests.allSatisfy { !$0.arguments.last!.contains("chmod") && !$0.arguments.last!.contains("chown") })
        if mode != .conflict { #expect(requests.count == 1) }
    }

    @Test func publicDocumentsRejectArbitraryFoldersAndReplacementBeforeHDC() async throws {
        let (url, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = HarmonySendRunner()
        for name in ["file.txt", "arbitrary/file.txt", "DeviceBridge-not-a-uuid/file.txt", "DeviceBridge-" + UUID().uuidString + "/sub/file.txt"] {
            await #expect(throws: OperationFailure.self) {
                try await send(url, runner: runner, name: name, scope: .harmonyUserDocuments(userID: "101"))
            }
        }
        await #expect(throws: OperationFailure.self) {
            try await send(url, runner: runner, name: "DeviceBridge-" + UUID().uuidString + "/file.txt", replace: true, scope: .harmonyUserDocuments(userID: "101"))
        }
        #expect(await runner.requests.isEmpty)
    }

    @Test func invalidUserDocumentsIDsNeverRunHDC() async throws {
        let runner = HarmonySendRunner()
        let provider = HarmonyFileProvider(hdcURL: URL(fileURLWithPath: "/hdc"), runner: runner)
        for userID in ["", "99", "0100", "-100", "2147483648", "100/../../", "100;id", "100\n"] {
            await #expect(throws: DeviceFileLocationError.self) {
                try await provider.list(directory: DeviceDirectoryLocation(scope: .harmonyUserDocuments(userID: userID)),
                    transportID: "ABC", operationID: UUID())
            }
        }
        #expect(await runner.requests.isEmpty)
    }

    @Test func publicDocumentsBrowsingAndReceivingUseExplicitUserRoot() async throws {
        let (_, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = "/storage/media/101/local/files/Docs/Documents"
        let runner = HarmonyPublicReadRunner(root: root)
        let provider = HarmonyFileProvider(hdcURL: URL(fileURLWithPath: "/hdc"), runner: runner)
        let entries = try await provider.list(directory: DeviceDirectoryLocation(scope: .harmonyUserDocuments(userID: "101")),
            transportID: "ABC", operationID: UUID())
        #expect(entries.first?.name == "file.txt")
        let partial = directory.appendingPathComponent("received '\n.txt")
        let receipt = try await provider.receive(source: DeviceFileLocation(scope: .harmonyUserDocuments(userID: "101"), relativePath: "file.txt"),
            localPartialURL: partial, transportID: "ABC", operationID: UUID())
        #expect(receipt.byteLength == 5)
        let requests = await runner.requests
        #expect(Array(requests.last!.arguments.prefix(5)) == ["-t", "ABC", "file", "recv", root + "/file.txt"])
        #expect(requests.last!.arguments.last!.hasPrefix("/tmp/devicebridge-recv-"))
        #expect(try Data(contentsOf: partial) == Data("hello".utf8))
        #expect(requests.allSatisfy { !$0.arguments.joined(separator: " ").contains("/data/local/tmp") })
    }

    @Test(arguments: ["single'quote.txt", "double\"quote.txt", "line\nfeed.txt", "return\r.txt", "tab\t.txt", "control\u{7f}.txt"])
    func receiveRejectsUnsafeCanonicalNamesBeforeTransfer(name: String) async throws {
        let runner = HarmonyPublicReadRunner(root: "/data/local/tmp", remoteName: name)
        let provider = HarmonyFileProvider(hdcURL: URL(fileURLWithPath: "/hdc"), runner: runner)
        do {
            _ = try await provider.receive(source: DeviceFileLocation(scope: .harmonyDebugFiles, relativePath: name),
                localPartialURL: URL(fileURLWithPath: "/tmp/unused"), transportID: "ABC", operationID: UUID())
            Issue.record("Expected unsupported filename")
        } catch let failure as OperationFailure {
            #expect(failure.code == .unsupported)
        }
        #expect(await runner.requests.count == 1)
        #expect(await runner.requests.allSatisfy { !$0.arguments.contains("recv") })
    }

    @Test func receiveUnicodeAndSpacesUsesSafeLocalAlias() async throws {
        let (_, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let partial = directory.appendingPathComponent("local '\"\nfile.txt")
        let name = "普通 文件.txt"
        let runner = HarmonyPublicReadRunner(root: "/data/local/tmp", remoteName: name)
        let provider = HarmonyFileProvider(hdcURL: URL(fileURLWithPath: "/hdc"), runner: runner)
        _ = try await provider.receive(source: DeviceFileLocation(scope: .harmonyDebugFiles, relativePath: name),
            localPartialURL: partial, transportID: "ABC", operationID: UUID())
        let transfer = try #require(await runner.requests.last)
        #expect(transfer.arguments[4] == "/data/local/tmp/" + name)
        #expect(transfer.arguments[5].hasPrefix("/tmp/devicebridge-recv-"))
        #expect(!transfer.arguments[5].contains(" "))
        #expect(!transfer.arguments[5].contains("'"))
        #expect(!FileManager.default.fileExists(atPath: transfer.arguments[5]))
        #expect(try Data(contentsOf: partial) == Data("hello".utf8))
    }

    @Test(arguments: ["failedOutput", "cancel", "symlink"])
    func failedOrCancelledReceiveNeverCopiesAndCleansAlias(mode: String) async throws {
        let (_, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let partial = directory.appendingPathComponent("partial")
        let runner = HarmonyPublicReadRunner(root: "/data/local/tmp", receiveMode: mode)
        let provider = HarmonyFileProvider(hdcURL: URL(fileURLWithPath: "/hdc"), runner: runner)
        let task = Task {
            try await provider.receive(source: DeviceFileLocation(scope: .harmonyDebugFiles, relativePath: "file.txt"),
                localPartialURL: partial, transportID: "ABC", operationID: UUID())
        }
        do { _ = try await task.value; Issue.record("Expected receive failure") }
        catch { }
        #expect(!FileManager.default.fileExists(atPath: partial.path))
        let alias = try #require(await runner.requests.last?.arguments.last)
        #expect(alias.hasPrefix("/tmp/devicebridge-recv-"))
        #expect(!FileManager.default.fileExists(atPath: URL(fileURLWithPath: alias).deletingLastPathComponent().path))
    }

    @Test func receiveRejectsMalformedTargetBeforeHDC() async throws {
        let runner = HarmonyPublicReadRunner(root: "/data/local/tmp")
        let provider = HarmonyFileProvider(hdcURL: URL(fileURLWithPath: "/hdc"), runner: runner)
        for target in ["bad target", "-bad", "ABC;id", "ABC\n"] {
            await #expect(throws: OperationFailure.self) {
                try await provider.receive(source: DeviceFileLocation(scope: .harmonyDebugFiles, relativePath: "file.txt"),
                    localPartialURL: URL(fileURLWithPath: "/tmp/unused"), transportID: target, operationID: UUID())
            }
        }
        #expect(await runner.requests.isEmpty)
    }

    private func expectOnlyStageCleanup(_ runner: HarmonySendRunner) async throws {
        let script = try #require(await runner.requests.last?.arguments.last)
        #expect(script.contains("rmdir '/data/local/tmp/.devicebridge-send-"))
        #expect(!script.contains("rm -r"))
        #expect(!script.contains("'/data/local/tmp/file.txt'"))
        #expect(script.contains("test ! -L"))
    }

    private func fixture() throws -> (URL, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let url = directory.appendingPathComponent("a ' file; $.txt")
        try Data("hello".utf8).write(to: url)
        return (url, directory)
    }

    private func send(_ url: URL, runner: HarmonySendRunner, name: String = "file.txt", replace: Bool = false, scope: DeviceFileScope = .harmonyDebugFiles) async throws -> DeviceFileReceipt {
        try await HarmonyFileProvider(hdcURL: URL(fileURLWithPath: "/hdc"), runner: runner).send(
            localURL: url, destination: DeviceFileLocation(scope: scope, relativePath: name),
            transportID: "ABC:8710", operationID: UUID(), replaceExisting: replace)
    }
}

private actor HarmonySendSessionGate {
    let rejectAt: Int
    private var checks = 0
    init(rejectAt: Int) { self.rejectAt = rejectAt }
    func validate() throws {
        checks += 1
        if checks == rejectAt {
            throw OperationFailure(code: .disconnected, safeMessage: "Captured session is no longer active.")
        }
    }
}

private actor HarmonySendRunner: HostCommandRunning {
    enum Mode { case success, escapingParent, redirectedRoot, conflict, setupMkdirDenied, transferFailure, badHash, cancelTransfer, cancelCommit, commitConflict }
    let mode: Mode
    let approvedRoot: String
    let setupOutput: String?
    private(set) var requests: [HostCommandRequest] = []
    private(set) var aliasContents: Data?
    init(mode: Mode = .success, approvedRoot: String = "/data/local/tmp", setupOutput: String? = nil) {
        self.mode = mode; self.approvedRoot = approvedRoot; self.setupOutput = setupOutput
    }

    func run(_ request: HostCommandRequest) async throws -> HostCommandResult {
        requests.append(request)
        let script = request.arguments.last ?? ""
        let output: String
        if request.arguments.contains("send") {
            aliasContents = try Data(contentsOf: URL(fileURLWithPath: request.arguments[4]))
            if mode == .cancelTransfer { throw CancellationError() }
            output = mode == .transferFailure ? "[Fail] permission denied" : "FileTransfer finish"
        } else if script.contains("DBSEND_READY") {
            // Parent resolution is valid; model a system policy rejecting mkdir even
            // though the generated test -w check succeeds. HDC merges this into stdout
            // with host exit 0 and empty stderr on the affected real-device version.
            output = setupOutput ?? (mode == .setupMkdirDenied
                ? "mkdir: '\(approvedRoot)/.devicebridge-send-fixture': Permission denied\n"
                : mode == .conflict ? "" : "DBSEND_READY")
        } else if script.contains("DBSEND_VERIFIED") {
            output = mode == .badHash ? "" : "DBSEND_VERIFIED"
        } else if script.contains("DBSEND_COMMITTED") {
            if mode == .cancelCommit { throw HostCommandError.cancelled }
            output = mode == .commitConflict ? "ln: File exists" : "DBSEND_COMMITTED"
        } else if script.contains("rmdir ") {
            output = ""
        } else {
            let canonicalRoot = mode == .redirectedRoot ? approvedRoot + "/redirect" : approvedRoot
            let parent = mode == .escapingParent ? "/private/escape" : (script.contains("/nested'") ? canonicalRoot + "/nested" : canonicalRoot)
            output = canonicalRoot + "\n\0" + parent + "\n\0"
        }
        return HostCommandResult(exitCode: 0, standardOutput: Data(output.utf8), standardError: Data())
    }
}

private actor HarmonyPublicReadRunner: HostCommandRunning {
    let root: String
    let remoteName: String
    let receiveMode: String
    private(set) var requests: [HostCommandRequest] = []
    init(root: String, remoteName: String = "file.txt", receiveMode: String = "success") {
        self.root = root; self.remoteName = remoteName; self.receiveMode = receiveMode
    }
    func run(_ request: HostCommandRequest) async throws -> HostCommandResult {
        requests.append(request)
        let script = request.arguments.last ?? ""
        let output: String
        if request.arguments.contains("recv") {
            let alias = URL(fileURLWithPath: request.arguments.last!)
            if receiveMode == "symlink" {
                try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
            } else {
                try Data("hello".utf8).write(to: alias)
            }
            if receiveMode == "cancel" { withUnsafeCurrentTask { $0?.cancel() } }
            output = receiveMode == "failedOutput" ? "[Fail] permission denied" : "FileTransfer finish"
        }
        else if script.contains("DBLIST") { output = "DBLIST\0f\0file.txt\0" }
        else if script.contains("stat -c %s") { output = "5\n" }
        else {
            let path = script.contains("/file.txt'") || remoteName != "file.txt" ? root + "/" + remoteName : root
            output = root + "\n\0" + path + "\n\0"
        }
        return HostCommandResult(exitCode: 0, standardOutput: Data(output.utf8), standardError: Data())
    }
}

#if os(Linux)
// Executes the actual generated POSIX shell scripts against a temporary mapped root.
// This tests shell quoting/commit/cleanup, not a real device or HDC implementation.
@Suite("Harmony send shell fixtures (Linux)")
struct HarmonySendShellTests {
    @Test func specialNamesRoundTripAndReplace() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = HarmonyShellRunner(root: root)
        let source = root.appendingPathComponent("source")
        try Data("hello".utf8).write(to: source)
        let destination = try DeviceFileLocation(scope: .harmonyDebugFiles, relativePath: "' ; $(touch INJECTED)\n.txt")
        let provider = HarmonyFileProvider(hdcURL: URL(fileURLWithPath: "/fake-hdc"), runner: runner)
        _ = try await provider.send(localURL: source, destination: destination, transportID: "ABC", operationID: UUID(), replaceExisting: false)
        let final = root.appendingPathComponent(destination.relativePath)
        #expect(try Data(contentsOf: final) == Data("hello".utf8))
        await #expect(throws: OperationFailure.self) {
            try await provider.send(localURL: source, destination: destination, transportID: "ABC", operationID: UUID(), replaceExisting: false)
        }
        try Data("replaced".utf8).write(to: source)
        _ = try await provider.send(localURL: source, destination: destination, transportID: "ABC", operationID: UUID(), replaceExisting: true)
        #expect(try Data(contentsOf: final) == Data("replaced".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix(".devicebridge-send-") && $0 != "INJECTED" })
    }

    @Test func symlinkAndDirectoryCannotBeReplaced() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        try Data("hello".utf8).write(to: source)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link").path, withDestinationPath: source.path)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("directory"), withIntermediateDirectories: false)
        let provider = HarmonyFileProvider(hdcURL: URL(fileURLWithPath: "/fake-hdc"), runner: HarmonyShellRunner(root: root))
        for name in ["link", "directory", "missing/file"] {
            await #expect(throws: OperationFailure.self) {
                try await provider.send(localURL: source, destination: DeviceFileLocation(scope: .harmonyDebugFiles, relativePath: name), transportID: "ABC", operationID: UUID(), replaceExisting: true)
            }
        }
        #expect(try Data(contentsOf: source) == Data("hello".utf8))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("missing").path))
    }

    @Test func corruptionFailsActualSHA256AndCleansStage() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        try Data("hello".utf8).write(to: source)
        let provider = HarmonyFileProvider(hdcURL: URL(fileURLWithPath: "/fake-hdc"), runner: HarmonyShellRunner(root: root, corrupt: true))
        await #expect(throws: OperationFailure.self) {
            try await provider.send(localURL: source, destination: DeviceFileLocation(scope: .harmonyDebugFiles, relativePath: "result"), transportID: "ABC", operationID: UUID(), replaceExisting: false)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["source"])
    }

    @Test(arguments: ["100", "101"])
    func publicDocumentsRoundTripUsesNewFolderWithoutHardlinks(user: String) async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        try Data("hello".utf8).write(to: source)
        let approvedRoot = "/storage/media/\(user)/local/files/Docs/Documents"
        let runner = HarmonyShellRunner(root: root, approvedRoot: approvedRoot)
        let provider = HarmonyFileProvider(hdcURL: URL(fileURLWithPath: "/fake-hdc"), runner: runner)
        let destination = try DeviceFileLocation.harmonyUserDocument(userID: user, fileName: "file '\n$(touch INJECTED).txt")
        _ = try await provider.send(localURL: source, destination: destination, transportID: "ABC", operationID: UUID(), replaceExisting: false)
        let final = root.appendingPathComponent(destination.relativePath)
        #expect(try Data(contentsOf: final) == Data("hello".utf8))
        await #expect(throws: OperationFailure.self) {
            try await provider.send(localURL: source, destination: destination, transportID: "ABC", operationID: UUID(), replaceExisting: false)
        }
        #expect(try Data(contentsOf: final) == Data("hello".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix(".devicebridge-send-") })
    }

    @Test func publicPolicyDeniedMkdirAfterRealParentChecksHasNoTransferSideEffects() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        var bytes = Data("Unicode 公共文档 🙂\n".utf8)
        bytes.append(Data(repeating: 65, count: 81 - bytes.count))
        try bytes.write(to: source)
        let existing = root.appendingPathComponent("existing-user-file.txt")
        try Data("keep existing user file".utf8).write(to: existing)
        let runner = HarmonyShellRunner(root: root,
            approvedRoot: "/storage/media/100/local/files/Docs/Documents", denyStageMkdir: true)
        let provider = HarmonyFileProvider(hdcURL: URL(fileURLWithPath: "/fake-hdc"), runner: runner)
        do {
            _ = try await provider.send(localURL: source,
                destination: DeviceFileLocation.harmonyUserDocument(userID: "100", fileName: "公共文档.txt"),
                transportID: "ABC", operationID: UUID(), replaceExisting: false)
            Issue.record("Expected simulated device-policy mkdir rejection")
        } catch let failure as OperationFailure {
            #expect(failure.safeMessage == "HarmonyOS denied creating a private transfer folder in the selected user's public Documents directory. No file was sent.")
        }
        // Only mkdir is substituted with a denial primitive. The actual generated
        // canonical/sentinel/test -d/-w/-x/no-clobber checks must pass to reach it.
        #expect(await runner.stageMkdirDenied)
        let requests = await runner.requests
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { !$0.arguments.contains("send")
            && !$0.arguments.last!.contains("DBSEND_COMMITTED")
            && !$0.arguments.last!.contains("rm ") && !$0.arguments.last!.contains("rmdir ") })
        #expect(try Data(contentsOf: source) == bytes)
        #expect(try Data(contentsOf: existing) == Data("keep existing user file".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == ["existing-user-file.txt", "source"])
    }

    @Test func existingEmptyPublicTransferFolderIsNeverRemoved() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        try Data("hello".utf8).write(to: source)
        let destination = try DeviceFileLocation.harmonyUserDocument(userID: "101", fileName: "file.txt")
        let folder = root.appendingPathComponent(destination.relativePath).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let provider = HarmonyFileProvider(hdcURL: URL(fileURLWithPath: "/fake-hdc"), runner: HarmonyShellRunner(root: root,
            approvedRoot: "/storage/media/101/local/files/Docs/Documents"))
        await #expect(throws: OperationFailure.self) {
            try await provider.send(localURL: source, destination: destination, transportID: "ABC", operationID: UUID(), replaceExisting: false)
        }
        #expect(FileManager.default.fileExists(atPath: folder.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    @Test(arguments: ["moveFailure", "filesystemMismatch"])
    func publicDocumentsFailedCommitLeavesNoOwnedEmptyFolder(scenario: String) async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        try Data("hello".utf8).write(to: source)
        let destination = try DeviceFileLocation.harmonyUserDocument(userID: "101", fileName: "file.txt")
        let runner = HarmonyShellRunner(root: root, approvedRoot: "/storage/media/101/local/files/Docs/Documents",
            failPublicMove: scenario == "moveFailure", filesystemMismatch: scenario == "filesystemMismatch")
        let provider = HarmonyFileProvider(hdcURL: URL(fileURLWithPath: "/fake-hdc"), runner: runner)
        await #expect(throws: OperationFailure.self) {
            try await provider.send(localURL: source, destination: destination, transportID: "ABC", operationID: UUID(), replaceExisting: false)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["source"])
    }

    private func makeRoot() throws -> URL {
        let root = URL(fileURLWithPath: "/tmp/harmony-shell-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }
}

private actor HarmonyShellRunner: HostCommandRunning {
    let root: URL
    let corrupt: Bool
    let approvedRoot: String
    let failPublicMove: Bool
    let filesystemMismatch: Bool
    let denyStageMkdir: Bool
    private(set) var requests: [HostCommandRequest] = []
    private(set) var stageMkdirDenied = false
    init(root: URL, corrupt: Bool = false, approvedRoot: String = "/data/local/tmp",
         failPublicMove: Bool = false, filesystemMismatch: Bool = false, denyStageMkdir: Bool = false) {
        self.root = root; self.corrupt = corrupt; self.approvedRoot = approvedRoot
        self.failPublicMove = failPublicMove; self.filesystemMismatch = filesystemMismatch
        self.denyStageMkdir = denyStageMkdir
    }
    func run(_ request: HostCommandRequest) async throws -> HostCommandResult {
        requests.append(request)
        if request.arguments.contains("send") {
            let destination = URL(fileURLWithPath: request.arguments[5].replacingOccurrences(of: approvedRoot, with: root.path))
            try FileManager.default.copyItem(atPath: request.arguments[4], toPath: destination.path)
            if corrupt { try Data("wrong".utf8).write(to: destination) }
            return HostCommandResult(exitCode: 0, standardOutput: Data("FileTransfer finish".utf8), standardError: Data())
        }
        var script = request.arguments.last!.replacingOccurrences(of: approvedRoot, with: root.path)
        let denyMkdir = denyStageMkdir && script.contains("DBSEND_READY")
        if denyMkdir {
            script = "mkdir() { printf 'mkdir: Permission denied\\n'; return 1; }; " + script
        }
        if failPublicMove { script = script.replacingOccurrences(of: "mv -T ", with: "false ") }
        if filesystemMismatch, let range = script.range(of: "stat -c %d") {
            script.replaceSubrange(range, with: "printf 1; stat -c %d")
        }
        let result = try await HostCommandRunner().run(HostCommandRequest(executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script], timeout: .seconds(5)))
        if denyMkdir { stageMkdirDenied = result.standardOutputString.contains("mkdir: Permission denied") }
        // Model the affected HDC wrapper's zero host status, not POSIX mkdir success.
        return HostCommandResult(exitCode: denyMkdir ? 0 : result.exitCode,
            standardOutput: Data(result.standardOutputString.replacingOccurrences(of: root.path, with: approvedRoot).utf8), standardError: result.standardError)
    }
}
#endif
