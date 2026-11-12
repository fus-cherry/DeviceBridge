import Foundation
import Testing
@testable import DeviceBridgeCore

@Suite("HDC verified transfer session contract")
struct HarmonyTransferSessionTests {
    @Test func publicDocumentLocationUsesExplicitOSUserAndFreshFolder() throws {
        let id = UUID(uuidString: "A1B2C3D4-1111-2222-3333-444455556666")!
        let location = try DeviceFileLocation.harmonyUserDocument(userID: "101", fileName: "测试 app.apk", transferID: id)
        #expect(location.scope == .harmonyUserDocuments(userID: "101"))
        #expect(location.scope.platform == .harmonyOS)
        #expect(location.relativePath == "DeviceBridge-A1B2C3D4-1111-2222-3333-444455556666/测试 app.apk")
        let other = try DeviceFileLocation.harmonyUserDocument(userID: "101", fileName: "测试 app.apk")
        #expect(location.relativePath != other.relativePath)
        #expect(try DeviceDirectoryLocation(scope: .harmonyUserDocuments(userID: "101")).relativePath.isEmpty)
    }

    @Test(arguments: ["", "0", "99", "0100", "+100", "-100", "100/../../other", "100;touch pwned", "100\n", "2147483648", "主用户"])
    func publicDocumentUserIDMustBeExplicitCanonicalDecimal(userID: String) {
        #expect(throws: DeviceFileLocationError.invalidIdentifier) {
            try DeviceFileLocation.harmonyUserDocument(userID: userID, fileName: "file.apk")
        }
        #expect(throws: DeviceFileLocationError.invalidIdentifier) {
            try DeviceDirectoryLocation(scope: .harmonyUserDocuments(userID: userID))
        }
    }

    @Test(arguments: ["", ".", "..", "../x.apk", "folder/x.apk", "x\0.apk", "x\\.apk"])
    func publicDocumentFilenameCannotEscape(fileName: String) {
        #expect(throws: DeviceFileLocationError.invalidRelativePath) {
            try DeviceFileLocation.harmonyUserDocument(userID: "100", fileName: fileName)
        }
    }

    @Test func sourceMutationFailsBeforeRemoteCommands() async throws {
        let (store, session, _) = try await setup()
        let file = try fixture()
        defer { try? FileManager.default.removeItem(at: file) }
        let runner = InvalidatingTransferRunner()
        let underlying = HarmonyFileProvider(hdcURL: URL(fileURLWithPath: "/hdc"), runner: runner)
        let service = FileTransferService(store: store,
            provider: MutatingVerifiedProvider(provider: underlying), session: session)
        let outcome = await service.send(sourceURL: file,
            destination: try DeviceFileLocation(scope: .harmonyDebugFiles, relativePath: "sample.apk"))
        guard case let .failure(failure) = outcome else { Issue.record("Expected mutation rejection"); return }
        #expect(failure.code == .integrityMismatch)
        #expect(failure.safeMessage.contains("no file was sent"))
        #expect(await runner.requests.isEmpty)
        #expect((await store.snapshot()).activeOperationIDs.isEmpty)
    }

    @Test func sessionInvalidationDuringTransferPreventsCommit() async throws {
        let (store, session, other) = try await setup()
        let file = try fixture()
        defer { try? FileManager.default.removeItem(at: file) }
        let runner = InvalidatingTransferRunner {
            _ = try await store.select(other.identity)
        }
        let service = FileTransferService(store: store,
            provider: HarmonyFileProvider(hdcURL: URL(fileURLWithPath: "/hdc"), runner: runner), session: session)
        let outcome = await service.send(sourceURL: file,
            destination: try DeviceFileLocation(scope: .harmonyDebugFiles, relativePath: "sample.apk"))
        #expect(outcome == .stale)
        let requests = await runner.requests
        #expect(requests.contains { $0.arguments.contains("send") })
        #expect(!requests.contains { $0.arguments.last?.contains("DBSEND_COMMITTED") == true })
        #expect(requests.contains { $0.arguments.last?.contains("rmdir") == true })
        #expect(requests.allSatisfy { Array($0.arguments.prefix(2)) == ["-t", "ABC"] })
        #expect((await store.snapshot()).activeOperationIDs.isEmpty)
    }

    private func fixture() throws -> URL {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".apk")
        try Data("original".utf8).write(to: file)
        return file
    }

    private func setup() async throws -> (DeviceSessionStore, ConnectionSession, DeviceRecord) {
        func device(_ name: String) throws -> DeviceRecord {
            let identity = try DeviceIdentity(rawValue: name, stability: .provisional, platform: .harmonyOS)
            let transport = try TransportCandidate(id: name, identity: identity, kind: .usb,
                source: .hdc, status: .available, observedAt: Date())
            return DeviceRecord(identity: identity, name: name, authorization: .authorized,
                candidates: [transport], preferredTransportID: name)
        }
        let first = try device("ABC"), other = try device("Other")
        let store = DeviceSessionStore()
        await store.replaceInventory([first, other])
        _ = try await store.select(first.identity)
        return (store, try #require(await store.snapshot().session), other)
    }
}

private struct MutatingVerifiedProvider: DeviceFileVerifiedSending {
    let provider: HarmonyFileProvider
    func sendVerified(localURL: URL, destination: DeviceFileLocation, transportID: String,
                      operationID: UUID, replaceExisting: Bool, expectedMetadata: FileIntegrityMetadata,
                      validateSession: @escaping @Sendable () async throws -> Void) async throws -> DeviceFileReceipt {
        try Data("changed!".utf8).write(to: localURL)
        return try await provider.sendVerified(localURL: localURL, destination: destination,
            transportID: transportID, operationID: operationID, replaceExisting: replaceExisting,
            expectedMetadata: expectedMetadata, validateSession: validateSession)
    }
    func send(localURL: URL, destination: DeviceFileLocation, transportID: String,
              operationID: UUID, replaceExisting: Bool) async throws -> DeviceFileReceipt {
        Issue.record("Service must use verified contract")
        throw HostCommandError.launchFailed
    }
    func receive(source: DeviceFileLocation, localPartialURL: URL, transportID: String,
                 operationID: UUID) async throws -> DeviceFileReceipt { throw HostCommandError.launchFailed }
}

private actor InvalidatingTransferRunner: HostCommandRunning {
    private(set) var requests: [HostCommandRequest] = []
    let invalidate: (@Sendable () async throws -> Void)?
    init(invalidate: (@Sendable () async throws -> Void)? = nil) { self.invalidate = invalidate }
    func run(_ request: HostCommandRequest) async throws -> HostCommandResult {
        requests.append(request)
        let result: String
        let script = request.arguments.last ?? ""
        if request.arguments.contains("send") {
            try await invalidate?()
            result = "FileTransfer finish"
        } else if script.contains("DBSEND_READY") { result = "DBSEND_READY" }
        else if script.contains("DBSEND_VERIFIED") { result = "DBSEND_VERIFIED" }
        else if script.contains("DBSEND_COMMITTED") { result = "DBSEND_COMMITTED" }
        else if script.contains("rmdir") { result = "" }
        else { result = "/data/local/tmp\n\0/data/local/tmp\n\0" }
        return HostCommandResult(exitCode: 0, standardOutput: Data(result.utf8), standardError: Data())
    }
}
