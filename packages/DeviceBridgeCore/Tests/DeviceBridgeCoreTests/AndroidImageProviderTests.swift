import Foundation
import Testing
@testable import DeviceBridgeCore

@Suite("Android image provider")
struct AndroidImageProviderTests {
    @Test("a growing source is rejected before its bytes are written locally")
    func growingOriginal() async throws {
        let runner = ImageCommandRunner(growingRead: true)
        let provider = AndroidImageProvider(adbURL: URL(fileURLWithPath: "/adb"), runner: runner)
        let directory = FileManager.default.temporaryDirectory.appending(path: "image-growth-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let partial = directory.appending(path: "partial")
        let item = try #require(try AndroidImageParser.parse(ImageCommandRunner.listing, source: .androidPictures).first)
        await #expect(throws: PhoneImageError.sourceChanged) { try await provider.receive(item, transportID: "7", partialURL: partial) }
        #expect(!FileManager.default.fileExists(atPath: partial.path))
        #expect(await runner.requests.first { $0.arguments.contains("head") }?.arguments.contains("5") == true)
    }
    @Test("invalidation during checksum prevents the subsequent original read")
    func invalidationBeforeRead() async throws {
        let runner = ImageCommandRunner(suspendChecksum: true)
        let provider = AndroidImageProvider(adbURL: URL(fileURLWithPath: "/adb"), runner: runner)
        let directory = FileManager.default.temporaryDirectory.appending(path: "image-invalidation-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let item = try #require(try AndroidImageParser.parse(ImageCommandRunner.listing, source: .androidPictures).first)
        let validity = ImageRequestValidity()
        let task = Task {
            try await provider.receive(item, transportID: "7", partialURL: directory.appending(path: "partial"),
                                       validateSession: { try validity.check() })
        }
        while !(await runner.checksumPending) { await Task.yield() }
        validity.invalidate()
        await runner.resumeChecksum()
        await #expect(throws: PhoneImageError.stale) { try await task.value }
        #expect(!(await runner.requests.contains { $0.arguments.contains("head") || $0.arguments.contains("pull") }))
    }
    @Test("original pull returns verified source metadata and removes changed partial files")
    func receiveOriginal() async throws {
        for changed in [false, true] {
            let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: directory) }
            let partial = directory.appending(path: "image.partial")
            let runner = ImageCommandRunner(changeAfterPull: changed)
            let provider = AndroidImageProvider(adbURL: URL(fileURLWithPath: "/adb"), runner: runner)
            let item = try #require(try AndroidImageParser.parse(ImageCommandRunner.listing, source: .androidPictures).first)
            if changed {
                await #expect(throws: PhoneImageError.sourceChanged) {
                    try await provider.receive(item, transportID: "7", partialURL: partial)
                }
                #expect(!FileManager.default.fileExists(atPath: partial.path))
            } else {
                let receipt = try await provider.receive(item, transportID: "7", partialURL: partial)
                #expect(receipt.byteLength == 4)
                #expect(receipt.sha256 == "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08")
                #expect(try Data(contentsOf: partial) == Data("test".utf8))
                #expect(await runner.requests.contains { $0.arguments.contains("head") && $0.arguments.contains("5") })
                #expect(await runner.requests.first { $0.arguments.contains("head") }?.arguments.last == "/storage/emulated/0/Pictures/a.png")
            }
        }
    }
    @Test("a denied source cannot become an empty catalog")
    func deniedList() async {
        let provider = AndroidImageProvider(adbURL: URL(fileURLWithPath: "/adb"), runner: ImageCommandRunner(deny: true))
        await #expect(throws: PhoneImageError.scopeUnavailable) {
            try await provider.list(source: .androidPictures, transportID: "7")
        }
    }
    @Test("listing uses the captured target and fixed scope")
    func targetedList() async throws {
        let runner = ImageCommandRunner()
        let provider = AndroidImageProvider(adbURL: URL(fileURLWithPath: "/adb"), runner: runner)
        let items = try await provider.list(source: .androidPictures, transportID: "7")
        #expect(items.count == 1)
        #expect(await runner.requests.allSatisfy { $0.arguments.prefix(2) == ["-t", "7"] })
        #expect(await runner.requests.contains { $0.arguments.contains("find") && $0.arguments.contains("/sdcard/Pictures") })
    }
    @Test("out-of-scope canonical files never reach pull")
    func symlinkEscape() async throws {
        let runner = ImageCommandRunner(escape: true)
        let provider = AndroidImageProvider(adbURL: URL(fileURLWithPath: "/adb"), runner: runner)
        let candidate = try #require(try AndroidImageParser.parse(ImageCommandRunner.listing, source: .androidPictures).first)
        await #expect(throws: PhoneImageError.scopeUnavailable) {
            try await provider.receive(candidate, transportID: "7", partialURL: URL(fileURLWithPath: "/unused"))
        }
        #expect(!(await runner.requests.contains { $0.arguments.contains("head") || $0.arguments.contains("pull") }))
    }
}

private actor ImageCommandRunner: HostCommandRunning {
    static let listing = Data("4\0100\0/sdcard/Pictures/a.png\0".utf8)
    var requests: [HostCommandRequest] = []
    let deny: Bool
    let escape: Bool
    let changeAfterPull: Bool
    var pulled = false
    var suspendChecksum: Bool
    let growingRead: Bool
    var checksumContinuation: CheckedContinuation<Void, Never>?
    var checksumPending: Bool { checksumContinuation != nil }
    func resumeChecksum() { checksumContinuation?.resume(); checksumContinuation = nil }
    init(deny: Bool = false, escape: Bool = false, changeAfterPull: Bool = false, suspendChecksum: Bool = false, growingRead: Bool = false) {
        self.deny = deny; self.escape = escape; self.changeAfterPull = changeAfterPull
        self.suspendChecksum = suspendChecksum
        self.growingRead = growingRead
    }
    func run(_ request: HostCommandRequest) async throws -> HostCommandResult {
        requests.append(request)
        let args = request.arguments
        let output: Data
        if args.contains("realpath") {
            let root = args.last == "'/sdcard/Pictures'"
            output = Data((root ? "/storage/emulated/0/Pictures\n" : escape ? "/data/private.png\n" : "/storage/emulated/0/Pictures/a.png\n").utf8)
        } else if args.contains("find") { output = Self.listing }
        else if args.contains("stat") { output = Data("4 \(pulled && changeAfterPull ? 200 : 100) 42 81a4\n".utf8) }
        else if args.contains("sha256sum") {
            if suspendChecksum {
                suspendChecksum = false
                await withCheckedContinuation { checksumContinuation = $0 }
            }
            output = Data("9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08  a.png\n".utf8)
        }
        else if args.contains("head") {
            pulled = true
            output = Data((growingRead ? "test!" : "test").utf8)
        }
        else { output = Data() }
        return HostCommandResult(exitCode: deny ? 1 : 0, standardOutput: output, standardError: Data())
    }
}
