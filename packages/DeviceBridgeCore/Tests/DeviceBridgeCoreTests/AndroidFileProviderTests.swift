import Foundation
import Testing
@testable import DeviceBridgeCore

@Suite("Android scoped file provider")
struct AndroidFileProviderTests {
    @Test("shared send stages, verifies, and publishes through the selected transport")
    func sharedSend() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "android-file-provider-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appending(path: "payload.bin")
        try Data("payload".utf8).write(to: source)
        let metadata = try FileIntegrity.metadata(for: source)
        let runner = AndroidFileCommandRunner(payload: Data(), metadata: metadata)
        let provider = AndroidFileProvider(
            adbURL: URL(fileURLWithPath: "/sdk/adb"),
            runner: runner
        )
        let location = try DeviceFileLocation(
            scope: .androidSharedDownloads,
            relativePath: "fixtures/payload.bin"
        )

        let receipt = try await provider.send(
            localURL: source,
            destination: location,
            transportID: "7",
            operationID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            replaceExisting: false
        )
        let requests = await runner.requests

        #expect(receipt == DeviceFileReceipt(
            byteLength: metadata.byteLength,
            sha256: metadata.sha256
        ))
        #expect(requests.allSatisfy { Array($0.arguments.prefix(2)) == ["-t", "7"] })
        #expect(requests.contains { $0.arguments.contains("push") })
        #expect(requests.contains { $0.arguments.suffix(2) == [
            "/sdcard/Download/.devicebridge.partial.11111111-1111-1111-1111-111111111111",
            "/sdcard/Download/fixtures/payload.bin",
        ] })
    }

    @Test("debuggable app receive uses run-as and writes exact stdout bytes")
    func appReceive() async throws {
        let payload = Data("private fixture".utf8)
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "android-file-receive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let partial = directory.appending(path: ".partial")
        let temporary = directory.appending(path: "hash-source")
        try payload.write(to: temporary)
        let metadata = try FileIntegrity.metadata(for: temporary)
        let runner = AndroidFileCommandRunner(payload: payload, metadata: metadata)
        let provider = AndroidFileProvider(
            adbURL: URL(fileURLWithPath: "/adb"),
            runner: runner
        )
        let source = try DeviceFileLocation(
            scope: .androidAppData(packageID: "dev.example.debug"),
            relativePath: "files/export.bin"
        )

        let receipt = try await provider.receive(
            source: source,
            localPartialURL: partial,
            transportID: "9",
            operationID: UUID()
        )
        let requests = await runner.requests

        #expect(try Data(contentsOf: partial) == payload)
        #expect(receipt.sha256 == metadata.sha256)
        #expect(requests.contains { $0.arguments == [
            "-t", "9", "exec-out", "run-as", "dev.example.debug", "cat", "files/export.bin",
        ] })
    }

    @Test("iOS scope is rejected before invoking ADB")
    func rejectsWrongPlatform() async throws {
        let runner = AndroidFileCommandRunner(
            payload: Data(),
            metadata: FileIntegrityMetadata(byteLength: 0, sha256: String(repeating: "0", count: 64))
        )
        let provider = AndroidFileProvider(
            adbURL: URL(fileURLWithPath: "/adb"),
            runner: runner
        )
        let location = try DeviceFileLocation(
            scope: .iOSTemporary(identifier: "dev.debugutility"),
            relativePath: "file.txt"
        )

        await #expect(throws: AndroidFileProviderError.unsupportedScope) {
            try await provider.receive(
                source: location,
                localPartialURL: URL(fileURLWithPath: "/tmp/unused"),
                transportID: "1",
                operationID: UUID()
            )
        }
        #expect(await runner.requests.isEmpty)
    }
}

private actor AndroidFileCommandRunner: HostCommandRunning {
    private(set) var requests: [HostCommandRequest] = []
    let payload: Data
    let metadata: FileIntegrityMetadata

    init(payload: Data, metadata: FileIntegrityMetadata) {
        self.payload = payload
        self.metadata = metadata
    }

    func run(_ request: HostCommandRequest) async throws -> HostCommandResult {
        requests.append(request)
        let arguments = request.arguments
        if arguments.contains("test") {
            return HostCommandResult(exitCode: 1, standardOutput: Data(), standardError: Data())
        }
        if arguments.contains("stat") {
            return HostCommandResult(
                exitCode: 0,
                standardOutput: Data("\(metadata.byteLength)\n".utf8),
                standardError: Data()
            )
        }
        if arguments.contains("sha256sum") {
            return HostCommandResult(
                exitCode: 0,
                standardOutput: Data("\(metadata.sha256)  file\n".utf8),
                standardError: Data()
            )
        }
        if arguments.contains("cat") {
            return HostCommandResult(exitCode: 0, standardOutput: payload, standardError: Data())
        }
        return HostCommandResult(exitCode: 0, standardOutput: Data("1 file pushed\n".utf8), standardError: Data())
    }
}
