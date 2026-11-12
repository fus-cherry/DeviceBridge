import Foundation
import Testing
@testable import DeviceBridgeCore

@Suite("HarmonyOS mediatool media access")
struct HarmonyMediaProviderTests {
    private let root = HarmonyMediaProvider.mediaRoot
    private let hash = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"

    @Test func recursiveListingUsesCurrentUserAliasAndNeverTraversesHidden() async throws {
        let runner = HarmonyMediaRunner(listings: [
            HarmonyMediaProvider.mediaRoot: Self.row("16", directory: true) + Self.row(".hidden", directory: true),
            HarmonyMediaProvider.mediaRoot + "/16": Self.row("IMG_hello world.jpg") + Self.row("movie.mp4") + Self.row(".secret.jpg")
        ])
        let provider = makeProvider(runner)
        let images = try await provider.list(source: .harmonyMediaLibrary, transportID: "ABC:8710")
        #expect(images.map(\.displayName) == ["IMG_hello world.jpg"])
        let videos = try await provider.list(source: .harmonyMediaLibrary, mediaKind: .video, transportID: "ABC:8710")
        #expect(videos.map(\.displayName) == ["movie.mp4"])
        let requests = await runner.requests
        #expect(requests.allSatisfy { Array($0.arguments.prefix(3)) == ["-t", "ABC:8710", "shell"] })
        #expect(requests.allSatisfy { !$0.arguments.last!.contains("/.hidden") && !$0.arguments.last!.contains("/100/") })
        #expect(requests.allSatisfy { !$0.arguments.last!.contains("mediatool recv") })
    }

    @Test func diagnosticWordsInsideFilenamesAreNotCommandErrors() async throws {
        let runner = HarmonyMediaRunner(listings: [HarmonyMediaProvider.mediaRoot:
            Self.row("failed.png") + Self.row("not found.jpg") + Self.row("error: foo.jpg")])
        let images = try await makeProvider(runner).list(source: .harmonyMediaLibrary, transportID: "ABC")
        #expect(images.count == 3)
    }

    @Test func supportedEmptyDirectoryDiffersFromUnsupportedVersion() async throws {
        let supported = HarmonyMediaRunner(listings: [:])
        #expect(try await makeProvider(supported).list(source: .harmonyMediaLibrary, transportID: "ABC").isEmpty)
        let old = HarmonyMediaRunner(mode: .oldVersion)
        await #expect(throws: OperationFailure.self) {
            try await makeProvider(old).list(source: .harmonyMediaLibrary, transportID: "ABC")
        }
        #expect(await old.requests.count == 2) // UID/tool probe then help, never an empty inventory.
    }

    @Test func rootOrUnauthorizedShellCannotExposeHiddenMedia() async throws {
        let runner = HarmonyMediaRunner(mode: .unauthorized)
        await #expect(throws: OperationFailure.self) {
            try await makeProvider(runner).list(source: .harmonyMediaLibrary, transportID: "ABC")
        }
        #expect(await runner.requests.count == 1)
        #expect(await runner.requests.first!.arguments.last!.contains("test \"$(id -u)\" = 2000"))
        #expect(await runner.requests.first!.arguments.last!.contains("= 0") == false)
    }

    @Test func eachSuccessfulCommandChecksSessionBeforeAndAfter() async throws {
        let gate = HarmonyMediaSessionGate()
        let runner = HarmonyMediaRunner(listings: [:])
        _ = try await makeProvider(runner).list(source: .harmonyMediaLibrary, transportID: "ABC",
            validateSession: { try await gate.validate() })
        #expect(await gate.checks == runner.requests.count * 2)
    }

    @Test func targetAndSourceValidationRunBeforeCommands() async throws {
        let runner = HarmonyMediaRunner()
        for target in ["", "-x", "ABC;id", "bad target", "ABC\n"] {
            await #expect(throws: PhoneImageError.self) {
                try await makeProvider(runner).list(source: .harmonyMediaLibrary, transportID: target)
            }
        }
        await #expect(throws: PhoneImageError.unsupported) {
            try await makeProvider(runner).list(source: .androidDCIM, transportID: "ABC")
        }
        #expect(await runner.requests.isEmpty)
    }

    @Test func strictParserPreservesSpacesAndRejectsAmbiguousRows() throws {
        let zone = TimeZone(secondsFromGMT: 8 * 3_600)!
        let parsed = try HarmonyMediaProvider.parseListing(Data(Self.row("普通 image.jpg").utf8), timeZone: zone)
        #expect(parsed.first?.name == "普通 image.jpg")
        #expect(parsed.first?.length == 5)
        for text in ["Permission denied\n", "total 0\n", Self.row("bad'quote.jpg"), Self.row("a\nb.jpg"),
                     Self.row("../escape.jpg"), Self.row(" IMG.jpg"), Self.row("IMG.jpg "),
                     Self.row("a.jpg") + Self.row("a.jpg"), Self.row("link.jpg").replacingOccurrences(of: "-rw-rw----", with: "lrwxrwxrwx"),
                     Self.row("a.jpg").replacingOccurrences(of: "2025-05-28", with: "2025-02-31")] {
            #expect(throws: PhoneImageError.self) { try HarmonyMediaProvider.parseListing(Data(text.utf8), timeZone: zone) }
        }
    }

    @Test func traversalDepthIsBounded() async throws {
        var listings: [String: String] = [:]
        var path = root
        for _ in 0..<10 { listings[path] = Self.row("next", directory: true); path += "/next" }
        let runner = HarmonyMediaRunner(listings: listings)
        await #expect(throws: PhoneImageError.limitExceeded) {
            try await makeProvider(runner).list(source: .harmonyMediaLibrary, transportID: "ABC")
        }
        #expect(await runner.requests.count <= 11)
    }

    @Test func selectedExportVerifiesSnapshotAndCleansOnlyOwnStage() async throws {
        let directory = try localDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let partial = directory.appendingPathComponent("local ' \nimage.jpg")
        let runner = HarmonyMediaRunner()
        let receipt = try await makeProvider(runner).receive(candidate(), transportID: "ABC", partialURL: partial)
        #expect(receipt == DeviceFileReceipt(byteLength: 5, sha256: hash))
        #expect(try Data(contentsOf: partial) == Data("hello".utf8))
        let requests = await runner.requests
        let recv = try #require(requests.first { $0.arguments.last!.contains("mediatool recv ") })
        #expect(recv.arguments.last!.contains(root + "/16/image.jpg"))
        #expect(recv.arguments.last!.contains("/payload.bin'"))
        #expect(!recv.arguments.last!.contains("recv all"))
        #expect(requests.filter { $0.arguments.last!.contains("mediatool recv ") }.count == 1)
        #expect(requests.allSatisfy { !$0.arguments.contains("file") }) // No uncapped hdc file recv.
        let cleanup = try #require(requests.last?.arguments.last)
        #expect(cleanup.contains("rmdir '/data/local/tmp/.devicebridge-media-"))
        #expect(!cleanup.contains(root))
        #expect(!cleanup.contains("rm -r"))
        #expect(requests.filter { $0.arguments.last!.contains("DBMEDIA_CHUNK") }.allSatisfy { $0.maximumOutputBytes == 6 * 1_024 * 1_024 })
    }

    @Test(arguments: ["\n", "\r\n"])
    func base64LineWrappingIsAcceptedWithoutUnicodeCharacterAmbiguity(separator: String) async throws {
        let directory = try localDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = HarmonyMediaRunner(mode: .wrappedBase64(separator))
        let partial = directory.appendingPathComponent("partial")
        let receipt = try await makeProvider(runner).receive(candidate(), transportID: "ABC", partialURL: partial)
        #expect(receipt.sha256 == hash)
        #expect(try Data(contentsOf: partial) == Data("hello".utf8))
    }

    @Test func multiChunkVideoIsStreamedAndHashVerified() async throws {
        let directory = try localDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = Data(repeating: 42, count: 4 * 1_024 * 1_024 + 17)
        let input = directory.appendingPathComponent("input")
        try data.write(to: input)
        let metadata = try FileIntegrity.metadata(for: input)
        let runner = HarmonyMediaRunner(bytes: data, hash: metadata.sha256,
            listings: [root + "/16": Self.row("movie.mp4", size: data.count)])
        let image = candidate(name: "movie.mp4", size: Int64(data.count))
        let partial = directory.appendingPathComponent("movie.mp4")
        let receipt = try await makeProvider(runner).receive(image, transportID: "ABC", partialURL: partial)
        #expect(receipt.sha256 == metadata.sha256)
        #expect(try FileIntegrity.metadata(for: partial) == metadata)
        #expect(await runner.requests.filter { $0.arguments.last!.contains("DBMEDIA_CHUNK") }.count == 2)
    }

    @Test(arguments: ["recvFailure", "stageEscape", "badHash", "badChunk", "sourceChanged"])
    func exportFailuresNeverPublishAndCleanGeneratedStage(scenario: String) async throws {
        let directory = try localDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = HarmonyMediaRunner(mode: .failure(scenario))
        let partial = directory.appendingPathComponent("partial")
        do {
            _ = try await makeProvider(runner).receive(candidate(), transportID: "ABC", partialURL: partial)
            Issue.record("Expected export failure")
        } catch { }
        #expect(!FileManager.default.fileExists(atPath: partial.path))
        let cleanup = try #require(await runner.requests.last?.arguments.last)
        #expect(cleanup.contains("rmdir "))
        #expect(!cleanup.contains(root))
    }

    @Test func cancellationCleansOnlyCapturedTargetStage() async throws {
        let directory = try localDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = HarmonyMediaRunner(mode: .cancelChunk)
        let partial = directory.appendingPathComponent("partial")
        let provider = makeProvider(runner)
        let image = candidate()
        let task = Task { try await provider.receive(image, transportID: "ABC", partialURL: partial) }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: partial.path))
        #expect(await runner.requests.last!.arguments.last!.contains("rmdir "))
        #expect(await runner.requests.allSatisfy { $0.arguments[1] == "ABC" })
    }

    @Test func staleSessionStopsReadAndDoesNotCleanAgainstAnotherSession() async throws {
        let directory = try localDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = HarmonyMediaSessionGate()
        let runner = HarmonyMediaRunner(gate: gate)
        let partial = directory.appendingPathComponent("partial")
        await #expect(throws: PhoneImageError.stale) {
            try await makeProvider(runner).receive(candidate(), transportID: "ABC", partialURL: partial,
                validateSession: { try await gate.validate() })
        }
        #expect(!FileManager.default.fileExists(atPath: partial.path))
        #expect(await runner.requests.last!.arguments.last!.contains("DBMEDIA_CHUNK"))
        #expect(await runner.requests.allSatisfy { !$0.arguments.last!.contains("rmdir ") })
    }

    @Test func sessionInvalidationDuringCleanupRemovesPublishedPartial() async throws {
        let directory = try localDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = HarmonyMediaSessionGate()
        let runner = HarmonyMediaRunner(mode: .invalidateCleanup, gate: gate)
        let partial = directory.appendingPathComponent("partial")
        await #expect(throws: PhoneImageError.stale) {
            try await makeProvider(runner).receive(candidate(), transportID: "ABC", partialURL: partial,
                validateSession: { try await gate.validate() })
        }
        #expect(!FileManager.default.fileExists(atPath: partial.path))
        #expect(await runner.requests.last!.arguments.last!.contains("rmdir "))
    }

    @Test func cancellationDuringCleanupRemovesPublishedPartial() async throws {
        let directory = try localDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pause = HarmonyMediaCleanupPause()
        let runner = HarmonyMediaRunner(cleanupPause: pause)
        let partial = directory.appendingPathComponent("partial")
        let provider = makeProvider(runner)
        let image = candidate()
        let task = Task { try await provider.receive(image, transportID: "ABC", partialURL: partial) }
        await pause.waitUntilStarted()
        #expect(FileManager.default.fileExists(atPath: partial.path))
        task.cancel()
        await pause.resume()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: partial.path))
    }

    @Test func malformedHiddenOrOversizedSelectionsNeverRunCommands() async throws {
        let runner = HarmonyMediaRunner()
        for path in [root + "/../secret.jpg", root + "/.hidden/image.jpg", root + "/16/a'quote.jpg", "/data/private/a.jpg"] {
            let image = ImageCandidate(source: .harmonyMediaLibrary, path: path, byteLength: 5, modifiedAt: candidate().modifiedAt)
            await #expect(throws: PhoneImageError.self) {
                try await makeProvider(runner).receive(image, transportID: "ABC", partialURL: URL(fileURLWithPath: "/tmp/unused"))
            }
        }
        await #expect(throws: PhoneImageError.limitExceeded) {
            try await makeProvider(runner).receive(candidate(size: 20 * 1_024 * 1_024 + 1), transportID: "ABC", partialURL: URL(fileURLWithPath: "/tmp/unused"))
        }
        #expect(await runner.requests.isEmpty)
    }

    private func makeProvider(_ runner: HarmonyMediaRunner) -> HarmonyMediaProvider {
        HarmonyMediaProvider(hdcURL: URL(fileURLWithPath: "/hdc"), runner: runner)
    }
    private func candidate(name: String = "image.jpg", size: Int64 = 5) -> ImageCandidate {
        let formatter = ISO8601DateFormatter()
        return ImageCandidate(source: .harmonyMediaLibrary, path: root + "/16/" + name, byteLength: size,
                              modifiedAt: formatter.date(from: "2025-05-28T12:34:00Z")!)
    }
    fileprivate static func row(_ name: String, directory: Bool = false, size: Int = 5) -> String {
        "\(directory ? "drwxrwx--x" : "-rw-rw----") 1 user_data_rw user_data_rw \(size) 2025-05-28 20:34 \(name)\n"
    }
    private func localDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: "/tmp/harmony-media-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }
}

private actor HarmonyMediaCleanupPause {
    private var started = false
    private var startedWaiter: CheckedContinuation<Void, Never>?
    private var resumeWaiter: CheckedContinuation<Void, Never>?
    func pause() async {
        started = true
        startedWaiter?.resume()
        startedWaiter = nil
        await withCheckedContinuation { resumeWaiter = $0 }
    }
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startedWaiter = $0 }
    }
    func resume() { resumeWaiter?.resume(); resumeWaiter = nil }
}

private actor HarmonyMediaSessionGate {
    var active = true
    private(set) var checks = 0
    func invalidate() { active = false }
    func validate() throws { checks += 1; if !active { throw PhoneImageError.stale } }
}

private actor HarmonyMediaRunner: HostCommandRunning {
    enum Mode: Sendable { case normal, oldVersion, unauthorized, failure(String), cancelChunk, invalidateCleanup, wrappedBase64(String) }
    let mode: Mode
    let bytes: Data
    let hash: String
    let listings: [String: String]
    let gate: HarmonyMediaSessionGate?
    let cleanupPause: HarmonyMediaCleanupPause?
    private(set) var requests: [HostCommandRequest] = []
    private var listed = 0
    private var stage = ""
    init(mode: Mode = .normal, bytes: Data = Data("hello".utf8),
         hash: String = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824",
         listings: [String: String]? = nil, gate: HarmonyMediaSessionGate? = nil, cleanupPause: HarmonyMediaCleanupPause? = nil) {
        self.mode = mode; self.bytes = bytes; self.hash = hash; self.gate = gate; self.cleanupPause = cleanupPause
        self.listings = listings ?? [HarmonyMediaProvider.mediaRoot + "/16": HarmonyMediaProviderTests.row("image.jpg")]
    }
    func run(_ request: HostCommandRequest) async throws -> HostCommandResult {
        requests.append(request)
        let script = request.arguments.last!
        let output: String
        var exitCode: Int32 = 0
        if script.contains("DBMEDIA_CAP") {
            if case .unauthorized = mode { output = "" } else { output = "DBMEDIA_CAP\n+0800\n" }
        } else if script == "mediatool -h" {
            if case .oldVersion = mode { output = "mediatool recv <src> <dest>\n" }
            else { output = "command: mediatool ls -l <media-directory>\ncommand: mediatool recv <src> <dest>\n" }
            exitCode = 1 // Documented help behavior, not a capability failure.
        } else if script.contains("mediatool ls -l") {
            listed += 1
            let path = script.components(separatedBy: "'")[1]
            var value = listings[path] ?? ""
            if case .failure("sourceChanged") = mode, listed > 1 { value = value.replacingOccurrences(of: " 5 ", with: " 6 ") }
            output = value + "\nDBMEDIA_LIST_END"
        } else if script.contains("DBMEDIA_READY") {
            stage = script.components(separatedBy: "'")[1]
            output = "DBMEDIA_READY"
        } else if script.contains("mediatool recv") {
            if case .failure("recvFailure") = mode { output = "FAIL: cloud item unavailable" }
            else { output = "Table Name: Photos\n" + stage + "/payload.bin\n" }
        } else if script.contains("rmdir ") {
            if let cleanupPause { await cleanupPause.pause() }
            if case .invalidateCleanup = mode, let gate { await gate.invalidate() }
            output = ""
        } else if script.contains("stat -c '%s %Y %i %f'") {
            if case .failure("stageEscape") = mode { output = "" }
            else { output = "\(bytes.count) 1748435640 12345 81a4\n" }
        } else if script.contains("sha256sum") {
            if case .failure("badHash") = mode { output = String(repeating: "0", count: 64) + "  " + stage + "/payload.bin\n" }
            else { output = hash + "  " + stage + "/payload.bin\n" }
        } else if script.contains("DBMEDIA_CHUNK") {
            if case .cancelChunk = mode { withUnsafeCurrentTask { $0?.cancel() } }
            if case .normal = mode, let gate { await gate.invalidate() }
            let index = Int(script.components(separatedBy: "skip=")[1].split(separator: " ")[0])!
            let start = index * 4 * 1_024 * 1_024
            let end = min(bytes.count, start + 4 * 1_024 * 1_024)
            if case .failure("badChunk") = mode { output = "DBMEDIA_CHUNK\n!invalid!\nDBMEDIA_END" }
            else {
                var encoded = bytes.subdata(in: start..<end).base64EncodedString()
                if case let .wrappedBase64(separator) = mode {
                    encoded = String(encoded.prefix(4)) + separator + encoded.dropFirst(4)
                }
                output = "DBMEDIA_CHUNK\n" + encoded + "\nDBMEDIA_END"
            }
        } else { throw HostCommandError.launchFailed }
        return HostCommandResult(exitCode: exitCode, standardOutput: Data(output.utf8), standardError: Data())
    }
}

#if os(Linux)
@Suite("Harmony media real shell fixtures (Linux)")
struct HarmonyMediaShellTests {
    @Test func selectedBinaryExportRunsRealStageHashChunkAndCleanupScripts() async throws {
        let root = URL(fileURLWithPath: "/tmp/harmony-media-shell-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let debugRoot = root.appendingPathComponent("debug")
        try FileManager.default.createDirectory(at: debugRoot, withIntermediateDirectories: false)
        let input = root.appendingPathComponent("input.bin")
        let bytes = Data((0..<(4 * 1_024 * 1_024 + 37)).map { UInt8($0 % 251) })
        try bytes.write(to: input)
        let expected = try FileIntegrity.metadata(for: input)
        let runner = HarmonyMediaShellRunner(debugRoot: debugRoot, input: input, length: bytes.count)
        let provider = HarmonyMediaProvider(hdcURL: URL(fileURLWithPath: "/fake-hdc"), runner: runner)
        let image = ImageCandidate(source: .harmonyMediaLibrary,
            path: HarmonyMediaProvider.mediaRoot + "/16/movie.mp4", byteLength: Int64(bytes.count),
            modifiedAt: ISO8601DateFormatter().date(from: "2025-05-28T12:34:00Z")!)
        let partial = root.appendingPathComponent("video ' \n.mp4")
        let receipt = try await provider.receive(image, transportID: "ABC", partialURL: partial)
        #expect(receipt == DeviceFileReceipt(byteLength: expected.byteLength, sha256: expected.sha256))
        #expect(try FileIntegrity.metadata(for: partial) == expected)
        #expect(try FileManager.default.contentsOfDirectory(atPath: debugRoot.path).isEmpty)
        #expect(try FileIntegrity.metadata(for: input) == expected) // Media source was not modified.
        #expect(await runner.chunks == 2)
    }
}

private actor HarmonyMediaShellRunner: HostCommandRunning {
    let debugRoot: URL
    let input: URL
    let length: Int
    private(set) var chunks = 0
    init(debugRoot: URL, input: URL, length: Int) { self.debugRoot = debugRoot; self.input = input; self.length = length }
    func run(_ request: HostCommandRequest) async throws -> HostCommandResult {
        let original = request.arguments.last!
        if original.contains("DBMEDIA_CAP") {
            return HostCommandResult(exitCode: 0, standardOutput: Data("DBMEDIA_CAP\n+0800\n".utf8), standardError: Data())
        }
        let mock = """
        mediatool() {
          case "$1" in
            -h) printf 'command: mediatool ls -l <media-directory>\\ncommand: mediatool recv <src> <dest>\\n'; return 1 ;;
            ls) printf '%s\\n' '-rw-rw---- 1 user_data_rw user_data_rw \(length) 2025-05-28 20:34 movie.mp4' ;;
            recv)
              test "$2" = '/storage/media/local/files/Photo/16/movie.mp4' || return 1
              test ! -e "$3" || return 1
              cp '\(input.path)' "$3" && printf 'Table Name: Photos\\n%s\\n' "$3" ;;
            *) return 1 ;;
          esac
        }
        """
        if original.contains("DBMEDIA_CHUNK") { chunks += 1 }
        let script = original.replacingOccurrences(of: "/data/local/tmp", with: debugRoot.path)
        let result = try await HostCommandRunner().run(HostCommandRequest(executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", mock + "\n" + script], timeout: request.timeout, maximumOutputBytes: request.maximumOutputBytes))
        return HostCommandResult(exitCode: result.exitCode,
            standardOutput: Data(result.standardOutputString.replacingOccurrences(of: debugRoot.path, with: "/data/local/tmp").utf8),
            standardError: result.standardError)
    }
}
#endif
