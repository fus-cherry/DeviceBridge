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
            "'/sdcard/Download/.devicebridge.partial.11111111-1111-1111-1111-111111111111'",
            "'/sdcard/Download/fixtures/payload.bin'",
        ] })
    }

    @Test("debuggable app receive uses bounded binary run-as chunks")
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
        let read = try #require(requests.first { $0.arguments.contains("exec-out") })
        #expect(read.arguments.prefix(6) == ["-t", "9", "exec-out", "run-as", "dev.example.debug", "sh"])
        #expect(read.arguments.last?.contains("2>/dev/null") == true)

    }

    @Test("large app files are read in bounded chunks")
    func boundedReceive() async throws {
        let payload = Data(repeating: 0xAB, count: 2 * 1_024 * 1_024 + 31)
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appending(path: "original")
        try payload.write(to: original)
        let runner = AndroidFileCommandRunner(payload: payload, metadata: try FileIntegrity.metadata(for: original))
        let provider = AndroidFileProvider(adbURL: URL(fileURLWithPath: "/adb"), runner: runner)
        let source = try DeviceFileLocation(scope: .androidAppData(packageID: "dev.test"), relativePath: "files/a b;$x'c")
        let partial = directory.appending(path: "partial")
        _ = try await provider.receive(source: source, localPartialURL: partial, transportID: "1", operationID: UUID())
        #expect(try Data(contentsOf: partial) == payload)
        let reads = await runner.requests.filter { $0.arguments.contains("exec-out") }
        #expect(reads.count == 3)
        #expect(reads.allSatisfy { $0.maximumOutputBytes <= 1_114_112 })
        #expect(reads[0].arguments.last?.contains("2>/dev/null") == true)
    }

    @Test("remote shell quoting keeps dd diagnostics out of binary stdout")
    func realShellRead() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appending(path: "a b;'$x.bin")
        let payload = Data([0, 255, 10, 13, 65])
        try payload.write(to: path)
        let inner = ["dd", "if=" + path.path, "bs=1048576", "skip=0", "count=1"]
            .map(AndroidFileProvider.shellQuote).joined(separator: " ") + " 2>/dev/null"
        // ADB exec-out leaves its first command raw and escapes each following
        // operand itself, before the remote shell and sh -c parse them.
        let outer = "sh " + ["-c", inner].map(AndroidFileProvider.shellQuote).joined(separator: " ")
        let result = try await HostCommandRunner().run(HostCommandRequest(
            executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", outer], timeout: .seconds(5)))
        #expect(result.exitCode == 0)
        #expect(result.standardOutput == payload)
        #expect(result.standardError.isEmpty)
    }

    @Test("unavailable read paths stop before metadata or file transfer")
    func rejectsUnavailableRead() async throws {
        for scope in [DeviceFileScope.androidSharedDownloads, .androidAppData(packageID: "dev.test")] {
            let runner = AndroidFileCommandRunner(payload: Data(),
                metadata: FileIntegrityMetadata(byteLength: 0, sha256: String(repeating: "a", count: 64)),
                denyReadGuard: true)
            let provider = AndroidFileProvider(adbURL: URL(fileURLWithPath: "/adb"), runner: runner)
            await #expect(throws: AndroidFileProviderError.scopeUnavailable) {
                try await provider.receive(source: DeviceFileLocation(scope: scope, relativePath: "escape/file"),
                    localPartialURL: URL(fileURLWithPath: "/tmp/unused"), transportID: "1", operationID: UUID())
            }
            #expect(await runner.requests.count == 1)
        }
    }

    @Test("escaped checksum filenames preserve the digest; malformed hashes fail")
    func escapedChecksum() async throws {
        let digest = String(repeating: "a", count: 64)
        for hash in ["\\" + digest, "not-a-digest"] {
            let runner = AndroidFileCommandRunner(payload: Data(),
                metadata: FileIntegrityMetadata(byteLength: 0, sha256: hash))
            let provider = AndroidFileProvider(adbURL: URL(fileURLWithPath: "/adb"), runner: runner)
            let source = try DeviceFileLocation(scope: .androidSharedDownloads, relativePath: "line\nname.txt")
            if hash.hasPrefix("\\") {
                let receipt = try await provider.receive(source: source,
                    localPartialURL: URL(fileURLWithPath: "/tmp/unused"), transportID: "1", operationID: UUID())
                #expect(receipt.sha256 == digest)
            } else {
                await #expect(throws: AndroidFileProviderError.malformedMetadata) {
                    try await provider.receive(source: source, localPartialURL: URL(fileURLWithPath: "/tmp/unused"),
                        transportID: "1", operationID: UUID())
                }
                #expect(await runner.requests.allSatisfy { !$0.arguments.contains("pull") })
            }
        }
    }

    @Test("read guards reject intermediate and final symlinks and nonregular files")
    func realShellScopeGuards() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory.appending(path: "scope"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let scope = directory.appending(path: "scope")
        try Data("outside".utf8).write(to: directory.appending(path: "secret"))
        try Data("inside".utf8).write(to: scope.appending(path: "a b;'$x\n.bin"))
        try FileManager.default.createSymbolicLink(at: scope.appending(path: "escape"), withDestinationURL: directory)
        try FileManager.default.createSymbolicLink(at: scope.appending(path: "link"), withDestinationURL: directory.appending(path: "secret"))
        for (path, isDirectory, expected) in [("escape/secret", false, 2), ("link", false, 2),
            ("escape", true, 2), ("", false, 2), ("", true, 0), ("a b;'$x\n.bin", false, 0)] {
            let script = AndroidFileProvider.readPathGuard(root: scope.path, relativePath: path, directory: isDirectory)
            let result = try await HostCommandRunner().run(HostCommandRequest(
                executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script], timeout: .seconds(5)))
            #expect(result.exitCode == Int32(expected))
        }
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
    let denyReadGuard: Bool

    init(payload: Data, metadata: FileIntegrityMetadata, denyReadGuard: Bool = false) {
        self.payload = payload
        self.metadata = metadata
        self.denyReadGuard = denyReadGuard
    }

    func run(_ request: HostCommandRequest) async throws -> HostCommandResult {
        requests.append(request)
        let arguments = request.arguments.map { value in
            value.hasPrefix("'") && value.hasSuffix("'") ? String(value.dropFirst().dropLast()) : value
        }
        if denyReadGuard && arguments.contains("sh") {
            return HostCommandResult(exitCode: 2, standardOutput: Data(), standardError: Data())
        }
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
        if arguments.contains("exec-out") {
            // exec-out takes raw operands; ADB itself performs their escaping.
            let script = request.arguments.last ?? ""
            let skip = script.components(separatedBy: "skip=").last.flatMap { Int($0.prefix(while: { $0.isNumber })) } ?? 0
            let start = min(skip * 1_024 * 1_024, payload.count)
            let end = min(start + 1_024 * 1_024, payload.count)
            return HostCommandResult(exitCode: 0, standardOutput: payload.subdata(in: start..<end), standardError: Data())
        }
        return HostCommandResult(exitCode: 0, standardOutput: Data("1 file pushed\n".utf8), standardError: Data())
    }
}
