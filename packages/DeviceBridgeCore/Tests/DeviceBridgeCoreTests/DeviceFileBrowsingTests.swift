import Foundation
import Testing
@testable import DeviceBridgeCore

@Suite("Scoped directory browsing")
struct DeviceFileBrowsingTests {
    @Test("a browser bound to an old session never lists a newly selected device")
    func boundSession() async throws {
        let store = DeviceSessionStore()
        func device(_ name: String) throws -> DeviceRecord {
            let identity = try DeviceIdentity(rawValue: name, stability: .stable, platform: .android)
            let transport = try TransportCandidate(id: name, identity: identity, kind: .usb,
                source: .adb, status: .available, observedAt: Date())
            return DeviceRecord(identity: identity, name: name, authorization: .authorized,
                candidates: [transport], preferredTransportID: name)
        }
        let first = try device("first")
        let second = try device("second")
        await store.replaceInventory([first, second])
        _ = try await store.select(first.identity)
        let session = try #require(await store.snapshot().session)
        let runner = DirectoryRunner(data: Data())
        let provider = AndroidFileProvider(adbURL: URL(fileURLWithPath: "/adb"), runner: runner)
        let service = DeviceFileBrowserService(store: store, provider: provider, session: session)
        _ = try await store.select(second.identity)
        let outcome = await service.list(directory: try DeviceDirectoryLocation(scope: .androidSharedDownloads))
        guard case .failure = outcome else { Issue.record("Expected stale-session rejection"); return }
        #expect(await runner.requests.isEmpty)
    }

    @Test("root and child navigation keep safe relative paths")
    func navigation() throws {
        let root = try DeviceDirectoryLocation(scope: .androidSharedDownloads)
        #expect(root.parent == nil)
        let nested = try DeviceDirectoryLocation(scope: root.scope, relativePath: "folder/sub")
        #expect(nested.parent?.relativePath == "folder")
        #expect(try nested.child(named: "a b.txt").relativePath == "folder/sub/a b.txt")
        #expect(throws: DeviceFileLocationError.invalidRelativePath) { try root.child(named: "../outside") }
        #expect(throws: DeviceFileLocationError.invalidRelativePath) { try root.child(named: "..") }
        #expect(throws: DeviceFileLocationError.invalidRelativePath) { try DeviceDirectoryLocation(scope: root.scope, relativePath: "/") }
    }

    @Test("Android NUL listing preserves unusual names and directory flags")
    func androidListing() async throws {
        let runner = DirectoryRunner(data: Data("d\0folder\0f\0a b;'$x\n.txt\0".utf8))
        let provider = AndroidFileProvider(adbURL: URL(fileURLWithPath: "/adb"), runner: runner)
        let directory = try DeviceDirectoryLocation(scope: .androidSharedDownloads, relativePath: "parent's $folder")
        let entries = try await provider.list(directory: directory, transportID: "42", operationID: UUID())
        #expect(entries.count == 2)
        #expect(entries[0].isDirectory)
        #expect(entries[1].name == "a b;'$x\n.txt")
        #expect(entries[1].location.relativePath == "parent's $folder/a b;'$x\n.txt")
        #expect(await runner.requests.first?.arguments.prefix(3) == ["-t", "42", "shell"])
    }

    @Test("listing executes safely in a real shell and rejects linked directories")
    func realShellListing() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appending(path: "empty"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let name = "a b;'$x\n.txt"
        try Data("file".utf8).write(to: root.appending(path: name))
        try FileManager.default.createSymbolicLink(at: root.appending(path: "escape"), withDestinationURL: root.deletingLastPathComponent())
        let provider = AndroidFileProvider(adbURL: URL(fileURLWithPath: "/adb"), runner: LocalDirectoryShellRunner(root: root))
        let directory = try DeviceDirectoryLocation(scope: .androidAppData(packageID: "dev.test"))
        let entries = try await provider.list(directory: directory, transportID: "1", operationID: UUID())
        #expect(Set(entries.map(\.name)) == Set(["empty", name]))
        #expect(try await provider.list(directory: DeviceDirectoryLocation(scope: directory.scope, relativePath: "empty"),
            transportID: "1", operationID: UUID()).isEmpty)
        await #expect(throws: AndroidFileProviderError.scopeUnavailable) {
            try await provider.list(directory: DeviceDirectoryLocation(scope: directory.scope, relativePath: "escape"),
                transportID: "1", operationID: UUID())
        }
        // Execute-only directories can be entered but cannot be enumerated.
        let unreadable = root.appending(path: "empty")
        try FileManager.default.setAttributes([.posixPermissions: 0o111], ofItemAtPath: unreadable.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: unreadable.path) }
        // Root can still read mode-0111 directories, so only assert denial when
        // the executing account actually lacks permission.
        if !FileManager.default.isReadableFile(atPath: unreadable.path) {
            await #expect(throws: AndroidFileProviderError.scopeUnavailable) {
                try await provider.list(directory: DeviceDirectoryLocation(scope: directory.scope, relativePath: "empty"),
                    transportID: "1", operationID: UUID())
            }
        }
    }

    @Test("empty Android directory succeeds; unsafe or truncated output fails")
    func androidMalformed() async throws {
        let directory = try DeviceDirectoryLocation(scope: .androidSharedDownloads)
        for data in [Data("f\0../outside\0".utf8), Data("f\0cut-off".utf8)] {
            let provider = AndroidFileProvider(adbURL: URL(fileURLWithPath: "/adb"), runner: DirectoryRunner(data: data))
            await #expect(throws: AndroidFileProviderError.malformedMetadata) {
                try await provider.list(directory: directory, transportID: "1", operationID: UUID())
            }
        }
        let provider = AndroidFileProvider(adbURL: URL(fileURLWithPath: "/adb"), runner: DirectoryRunner(data: Data()))
        #expect(try await provider.list(directory: directory, transportID: "1", operationID: UUID()).isEmpty)
    }
}

private actor DirectoryRunner: HostCommandRunning {
    let data: Data
    private(set) var requests: [HostCommandRequest] = []
    init(data: Data) { self.data = data }
    func run(_ request: HostCommandRequest) async throws -> HostCommandResult {
        requests.append(request)
        return HostCommandResult(exitCode: 0, standardOutput: data, standardError: Data())
    }
}

private struct LocalDirectoryShellRunner: HostCommandRunning {
    let root: URL
    func run(_ request: HostCommandRequest) async throws -> HostCommandResult {
        // Remove adb transport + shell + run-as package, preserving the actual
        // quoted command operands that Android's remote shell would parse.
        let script = "cd " + AndroidFileProvider.shellQuote(root.path) + " && " + request.arguments.dropFirst(5).joined(separator: " ")
        return try await HostCommandRunner().run(HostCommandRequest(
            executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script], timeout: .seconds(5)))
    }
}

@Suite("Loaded folder presentation")
struct DeviceFileListPresentationTests {
    private func entry(_ name: String, directory: Bool = false, size: Int64? = nil) throws -> DeviceFileEntry {
        DeviceFileEntry(location: try DeviceFileLocation(scope: .androidSharedDownloads, relativePath: name),
                        isDirectory: directory, byteLength: size)
    }

    @Test func hiddenReceiveTargetOnlyWarnsForFilteredLoadedFile() throws {
        let entries = try [entry("report.pdf"), entry("folder", directory: true)]
        #expect(DeviceFileListPresentation.receiveTargetHidden(in: entries, matching: "photo", relativePath: "report.pdf"))
        for (query, path) in [("REPORT", "report.pdf"), ("  ", "report.pdf"), ("photo", "manual/path"), ("photo", "folder"), ("photo", "")] {
            #expect(!DeviceFileListPresentation.receiveTargetHidden(in: entries, matching: query, relativePath: path))
        }
    }

    @Test func trimsQueryAndIgnoresCase() throws {
        let entries = try [entry("Report.PDF"), entry("photo.jpg")]
        #expect(DeviceFileListPresentation.entries(entries, matching: "  pdf \n").map(\.name) == ["Report.PDF"])
        #expect(DeviceFileListPresentation.entries(entries, matching: " ").count == 2)
    }

    @Test func unicodeAndNoMatches() throws {
        let entries = try [entry("旅行照片.png"), entry("报告.pdf")]
        #expect(DeviceFileListPresentation.entries(entries, matching: "照片").map(\.name) == ["旅行照片.png"])
        #expect(DeviceFileListPresentation.entries(entries, matching: "missing").isEmpty)
        #expect(DeviceFileListPresentation.entries([], matching: "").isEmpty)
    }

    @Test func directoriesStayFirstAndNamesSortNaturally() throws {
        let entries = try [entry("file10.txt"), entry("zfolder", directory: true), entry("file2.txt")]
        #expect(DeviceFileListPresentation.entries(entries, matching: "").map(\.name) == ["zfolder", "file2.txt", "file10.txt"])
    }

    @Test func sizeSortKeepsUnknownLastAndDoesNotChangeOriginals() throws {
        let entries = try [entry("unknown"), entry("zero", size: 0), entry("large", size: 500), entry("folder", directory: true)]
        #expect(DeviceFileListPresentation.entries(entries, matching: "", order: .largestFirst).map(\.name) == ["folder", "large", "zero", "unknown"])
        #expect(entries.map(\.name) == ["unknown", "zero", "large", "folder"])
    }

    @Test func filtersDoNotMatchParentPathsOrAlterIdentity() throws {
        let item = try entry("parent/leaf.txt", size: 9)
        #expect(DeviceFileListPresentation.entries([item], matching: "parent").isEmpty)
        #expect(DeviceFileListPresentation.entries([item], matching: "leaf") == [item])
    }
}
