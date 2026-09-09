import Foundation
import Testing
@testable import DeviceBridgeCore

@Suite("File transfer staging and integrity")
struct FileTransferServiceTests {
    @Test("scope rejects absolute traversal and platform-mismatched identifiers")
    func scopeValidation() throws {
        #expect(throws: DeviceFileLocationError.invalidRelativePath) {
            try DeviceFileLocation(scope: .androidSharedDownloads, relativePath: "../secret")
        }
        #expect(throws: DeviceFileLocationError.invalidRelativePath) {
            try DeviceFileLocation(scope: .androidSharedDownloads, relativePath: "/absolute")
        }
        #expect(throws: DeviceFileLocationError.invalidIdentifier) {
            try DeviceFileLocation(scope: .androidAppData(packageID: "bad package"), relativePath: "files/a.txt")
        }
        #expect(try DeviceFileLocation(
            scope: .iOSAppData(bundleID: "dev.example.app"),
            relativePath: "Documents/a.txt"
        ).relativePath == "Documents/a.txt")
    }

    @Test("receive validates length and hash before atomically publishing")
    func receivePublishes() async throws {
        let fixture = try await TransferFixture.make()
        let bytes = Data("binary\0payload".utf8)
        let provider = FileProviderDouble(receiveData: bytes)
        let service = FileTransferService(store: fixture.store, provider: provider)
        let destination = fixture.directory.appending(path: "received.bin")
        let source = try DeviceFileLocation(
            scope: .androidSharedDownloads,
            relativePath: "received.bin"
        )

        let outcome = await service.receive(
            source: source,
            destinationURL: destination,
            replaceExisting: false
        )

        #expect(outcome.artifact?.localURL == destination)
        #expect(outcome.artifact?.validation == .sha256)
        #expect(try Data(contentsOf: destination) == bytes)
        #expect(try partialFiles(in: fixture.directory).isEmpty)
    }

    @Test("integrity mismatch and cancellation remove partial output")
    func failedReceiveCleansPartial() async throws {
        let fixture = try await TransferFixture.make()
        let source = try DeviceFileLocation(
            scope: .androidSharedDownloads,
            relativePath: "bad.bin"
        )
        let mismatch = FileProviderDouble(
            receiveData: Data("actual".utf8),
            reportedHash: String(repeating: "0", count: 64)
        )
        let cancelled = FileProviderDouble(receiveData: Data(), cancelReceive: true)

        let mismatchOutcome = await FileTransferService(
            store: fixture.store,
            provider: mismatch
        ).receive(
            source: source,
            destinationURL: fixture.directory.appending(path: "bad.bin"),
            replaceExisting: false
        )
        let cancelledOutcome = await FileTransferService(
            store: fixture.store,
            provider: cancelled
        ).receive(
            source: source,
            destinationURL: fixture.directory.appending(path: "cancelled.bin"),
            replaceExisting: false
        )

        #expect(mismatchOutcome.failure?.code == .integrityMismatch)
        #expect(cancelledOutcome.failure?.code == .cancelled)
        #expect(try partialFiles(in: fixture.directory).isEmpty)
    }

    @Test("existing destination requires explicit replacement")
    func replacementConfirmation() async throws {
        let fixture = try await TransferFixture.make()
        let destination = fixture.directory.appending(path: "existing.txt")
        try Data("old".utf8).write(to: destination)
        let provider = FileProviderDouble(receiveData: Data("new".utf8))
        let service = FileTransferService(store: fixture.store, provider: provider)
        let source = try DeviceFileLocation(
            scope: .androidSharedDownloads,
            relativePath: "existing.txt"
        )

        let outcome = await service.receive(
            source: source,
            destinationURL: destination,
            replaceExisting: false
        )

        #expect(outcome.failure?.code == .restricted)
        #expect(try Data(contentsOf: destination) == Data("old".utf8))
        #expect(await provider.receiveCount == 0)
    }

    @Test("device switch rejects a late send receipt")
    func switchRejectsLateSend() async throws {
        let fixture = try await TransferFixture.make(includeSecondDevice: true)
        let provider = SuspendingFileProvider()
        let service = FileTransferService(store: fixture.store, provider: provider)
        let local = fixture.directory.appending(path: "send.txt")
        try Data("send data".utf8).write(to: local)
        let destination = try DeviceFileLocation(
            scope: .androidSharedDownloads,
            relativePath: "send.txt"
        )

        let task = Task { await service.send(sourceURL: local, destination: destination) }
        while !(await provider.hasSend) { await Task.yield() }
        _ = try await fixture.store.select(fixture.second!.identity)
        await provider.resumeSend()

        #expect(await task.value == .stale)
    }

    private func partialFiles(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.contains(".partial.") }
    }
}

private struct TransferFixture {
    let store: DeviceSessionStore
    let first: DeviceRecord
    let second: DeviceRecord?
    let directory: URL

    static func make(includeSecondDevice: Bool = false) async throws -> TransferFixture {
        let store = DeviceSessionStore()
        let first = try device(id: "first", transport: "transport-1")
        let second = includeSecondDevice ? try device(id: "second", transport: "transport-2") : nil
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "transfer-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        await store.replaceInventory([first, second].compactMap { $0 })
        _ = try await store.select(first.identity)
        return TransferFixture(store: store, first: first, second: second, directory: directory)
    }

    private static func device(id: String, transport: String) throws -> DeviceRecord {
        let identity = try DeviceIdentity(rawValue: id, stability: .stable, platform: .android)
        let candidate = try TransportCandidate(
            id: transport,
            identity: identity,
            kind: .usb,
            source: .adb,
            status: .available,
            observedAt: Date()
        )
        return DeviceRecord(
            identity: identity,
            name: id,
            authorization: .authorized,
            candidates: [candidate],
            preferredTransportID: transport
        )
    }
}

private actor FileProviderDouble: DeviceFileProviding {
    private let receiveData: Data
    private let reportedHash: String?
    private let cancelReceive: Bool
    private(set) var receiveCount = 0

    init(receiveData: Data, reportedHash: String? = nil, cancelReceive: Bool = false) {
        self.receiveData = receiveData
        self.reportedHash = reportedHash
        self.cancelReceive = cancelReceive
    }

    func send(
        localURL: URL,
        destination: DeviceFileLocation,
        transportID: String,
        operationID: UUID,
        replaceExisting: Bool
    ) async throws -> DeviceFileReceipt {
        let metadata = try FileIntegrity.metadata(for: localURL)
        return DeviceFileReceipt(byteLength: metadata.byteLength, sha256: metadata.sha256)
    }

    func receive(
        source: DeviceFileLocation,
        localPartialURL: URL,
        transportID: String,
        operationID: UUID
    ) async throws -> DeviceFileReceipt {
        receiveCount += 1
        if cancelReceive { throw CancellationError() }
        try receiveData.write(to: localPartialURL)
        let metadata = try FileIntegrity.metadata(for: localPartialURL)
        return DeviceFileReceipt(
            byteLength: metadata.byteLength,
            sha256: reportedHash ?? metadata.sha256
        )
    }
}

private actor SuspendingFileProvider: DeviceFileProviding {
    private var sendContinuation: CheckedContinuation<Void, Never>?
    var hasSend: Bool { sendContinuation != nil }

    func send(
        localURL: URL,
        destination: DeviceFileLocation,
        transportID: String,
        operationID: UUID,
        replaceExisting: Bool
    ) async throws -> DeviceFileReceipt {
        await withCheckedContinuation { sendContinuation = $0 }
        let metadata = try FileIntegrity.metadata(for: localURL)
        return DeviceFileReceipt(byteLength: metadata.byteLength, sha256: metadata.sha256)
    }

    func receive(
        source: DeviceFileLocation,
        localPartialURL: URL,
        transportID: String,
        operationID: UUID
    ) async throws -> DeviceFileReceipt {
        throw CancellationError()
    }

    func resumeSend() {
        sendContinuation?.resume()
        sendContinuation = nil
    }
}
