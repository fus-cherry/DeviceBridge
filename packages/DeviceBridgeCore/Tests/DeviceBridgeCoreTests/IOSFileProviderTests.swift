import Foundation
import Testing
@testable import DeviceBridgeCore

@Suite("iOS CoreDevice file provider")
struct IOSFileProviderTests {
    @Test("physical CoreDevice nested metadata supports receive and prevents unconfirmed overwrite")
    func physicalNestedMetadata() async throws {
        // Captured info-files result shape, sanitized to generated fixture identities.
        // Ignoring metadata.size breaks receive and allows an existing destination to be overwritten.
        let json = """
        {"result":{"deviceIdentifier":"test-device","domain":"temporary",
        "domainIdentifier":"dev.debugutility.test","files":[{
          "metadata":{"extendedAttributes":{},"lastModDate":"2026-09-08T07:28:09.000Z",
            "ownerGid":20,"ownerUid":501,"permissions":420,"size":7},
          "name":"export.txt","relativePath":"export.txt",
          "resources":{"isDirectory":false,"isHidden":false,"isReadable":true,
            "isSymbolicLink":false,"isWritable":true}
        }]}}
        """
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = IOSFileCommandRunner(fileName: "export.txt", byteLength: 7,
            receivedData: Data("content".utf8), metadataJSON: json)
        let provider = IOSFileProvider(xcrunURL: URL(fileURLWithPath: "/usr/bin/xcrun"), runner: runner)
        let location = try DeviceFileLocation(scope: .iOSTemporary(identifier: "dev.debugutility.test"),
            relativePath: "export.txt")
        await #expect(throws: IOSFileProviderError.remoteExists) {
            try await provider.send(localURL: directory.appending(path: "unused"), destination: location,
                transportID: "test-device", operationID: UUID(), replaceExisting: false)
        }
        #expect(await runner.requests.allSatisfy { !$0.arguments.contains("copy") })
        let partial = directory.appending(path: "partial")
        let receipt = try await provider.receive(source: location, localPartialURL: partial,
            transportID: "test-device", operationID: UUID())
        #expect(receipt == DeviceFileReceipt(byteLength: 7, sha256: nil))
        #expect(try Data(contentsOf: partial) == Data("content".utf8))
    }

    @Test("app-container send uses exact CoreDevice domain and JSON metadata")
    func appContainerSend() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ios-file-provider-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appending(path: "fixture.bin")
        try Data(repeating: 0x31, count: 12).write(to: source)
        let runner = IOSFileCommandRunner(fileName: "fixture.bin", byteLength: 12)
        let provider = IOSFileProvider(
            xcrunURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
            runner: runner
        )
        let location = try DeviceFileLocation(
            scope: .iOSAppData(bundleID: "dev.example.app"),
            relativePath: "Documents/fixture.bin"
        )

        let receipt = try await provider.send(
            localURL: source,
            destination: location,
            transportID: "core-device-id",
            operationID: UUID(),
            replaceExisting: true
        )
        let requests = await runner.requests

        #expect(receipt == DeviceFileReceipt(byteLength: 12, sha256: nil))
        #expect(requests.contains { request in
            request.arguments.starts(with: ["devicectl", "device", "copy", "to"])
                && request.arguments.contains("--domain-type")
                && request.arguments.contains("appDataContainer")
                && request.arguments.contains("--domain-identifier")
                && request.arguments.contains("dev.example.app")
        })
    }

    @Test("receive keeps CoreDevice bookmarks in owned temporary storage before app publication")
    func temporaryReceive() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ios-file-receive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let partial = directory.appending(path: ".partial")
        let runner = IOSFileCommandRunner(
            fileName: "export.txt",
            byteLength: 7,
            receivedData: Data("content".utf8)
        )
        let provider = IOSFileProvider(
            xcrunURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
            runner: runner
        )
        let source = try DeviceFileLocation(
            scope: .iOSTemporary(identifier: "dev.debugutility.session"),
            relativePath: "export.txt"
        )

        let receipt = try await provider.receive(
            source: source,
            localPartialURL: partial,
            transportID: "core-device-id",
            operationID: UUID()
        )

        #expect(receipt.byteLength == 7)
        #expect(try Data(contentsOf: partial) == Data("content".utf8))
        #expect(await runner.requests.contains { request in
            request.arguments.starts(with: ["devicectl", "device", "copy", "from"])
                && !request.arguments.contains(partial.path)
                && request.arguments.contains("temporary")
        })
        let copy = try #require(await runner.requests.first { $0.arguments.contains("from") })
        let index = try #require(copy.arguments.firstIndex(of: "--destination"))
        #expect(!FileManager.default.fileExists(atPath: copy.arguments[index + 1]))
    }

    @Test("cancelled late copy never reaches the caller partial file")
    func cancelledCopy() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = IOSFileCommandRunner(fileName: "public.txt", byteLength: 7,
            receivedData: Data("content".utf8), cancelAfterCopy: true)
        let provider = IOSFileProvider(xcrunURL: URL(fileURLWithPath: "/xcrun"), runner: runner)
        let partial = directory.appendingPathComponent("partial")
        let source = try DeviceFileLocation(scope: .iOSTemporary(identifier: "dev.public"), relativePath: "public.txt")
        let task = Task { try await provider.receive(source: source, localPartialURL: partial,
            transportID: "test-device", operationID: UUID()) }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: partial.path))
        let copy = try #require(await runner.requests.first { $0.arguments.contains("from") })
        let index = try #require(copy.arguments.firstIndex(of: "--destination"))
        #expect(!FileManager.default.fileExists(atPath: copy.arguments[index + 1]))
    }

    @Test("Android and read-only crash-log destinations are rejected before copy")
    func restrictedScopes() async throws {
        let runner = IOSFileCommandRunner(fileName: "x", byteLength: 1)
        let provider = IOSFileProvider(
            xcrunURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
            runner: runner
        )
        let android = try DeviceFileLocation(
            scope: .androidSharedDownloads,
            relativePath: "x"
        )
        let crash = try DeviceFileLocation(scope: .iOSSystemCrashLogs, relativePath: "x")

        await #expect(throws: IOSFileProviderError.unsupportedScope) {
            try await provider.receive(
                source: android,
                localPartialURL: URL(fileURLWithPath: "/tmp/x"),
                transportID: "id",
                operationID: UUID()
            )
        }
        await #expect(throws: IOSFileProviderError.readOnlyScope) {
            try await provider.send(
                localURL: URL(fileURLWithPath: "/tmp/x"),
                destination: crash,
                transportID: "id",
                operationID: UUID(),
                replaceExisting: false
            )
        }
    }
}

private actor IOSFileCommandRunner: HostCommandRunning {
    private(set) var requests: [HostCommandRequest] = []
    let fileName: String
    let byteLength: Int64
    let receivedData: Data
    let metadataJSON: String?
    let cancelAfterCopy: Bool

    init(fileName: String, byteLength: Int64, receivedData: Data = Data(), metadataJSON: String? = nil, cancelAfterCopy: Bool = false) {
        self.fileName = fileName
        self.byteLength = byteLength
        self.receivedData = receivedData
        self.metadataJSON = metadataJSON
        self.cancelAfterCopy = cancelAfterCopy
    }

    func run(_ request: HostCommandRequest) async throws -> HostCommandResult {
        requests.append(request)
        if request.arguments.starts(with: ["devicectl", "device", "info", "files"]),
           let outputIndex = request.arguments.firstIndex(of: "--json-output") {
            let outputURL = URL(fileURLWithPath: request.arguments[outputIndex + 1])
            let json = """
            {"result":{"items":[{"name":"\(fileName)","fileSize":\(byteLength)}]}}
            """
            try Data((metadataJSON ?? json).utf8).write(to: outputURL)
        }
        if request.arguments.starts(with: ["devicectl", "device", "copy", "from"]),
           let destinationIndex = request.arguments.firstIndex(of: "--destination") {
            try receivedData.write(
                to: URL(fileURLWithPath: request.arguments[destinationIndex + 1])
            )
            if cancelAfterCopy { withUnsafeCurrentTask { $0?.cancel() } }
        }
        return HostCommandResult(exitCode: 0, standardOutput: Data(), standardError: Data())
    }
}
