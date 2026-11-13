import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import DeviceBridgeCore

@Suite("HDC download sources and bounded speed sampling")
struct HDCDownloadSourcesTests {
    private func artifact(_ version: String = "5.0.0", _ architecture: HDCDownloadArchitecture = .arm64) throws
        -> HDCDownloadArtifact {
        try .init(version: version, architecture: architecture)
    }

    private func source(_ name: String, artifact: HDCDownloadArtifact) throws -> HDCDownloadSource {
        try .custom(name: name, url: URL(string: "https://downloads.example.com/\(name)")!, artifact: artifact)
    }

    @Test("official entry is browser navigation, not a guessed HDC archive")
    func officialEntry() throws {
        let official = HDCDownloadSource.officialHuaweiEntry
        #expect(official.kind == .officialEntry)
        #expect(official.requiresBrowser && official.mayRequireLogin)
        #expect(official.url.host == "developer.huawei.com")
        #expect(official.artifact == nil)
        #expect(official.expectedSHA256 == nil)
        #expect(official.verification == .unverified)
        #expect(try JSONDecoder().decode(HDCDownloadSource.self, from: JSONEncoder().encode(official)) == official)
    }

    @Test("custom HTTPS declarations and checksums round trip but remain unverified downloads")
    func customSource() throws {
        let declared = try HDCDownloadSource.custom(name: " mirror ",
            url: URL(string: "https://downloads.example.com/hdc.zip?temporary=public-fixture")!,
            artifact: artifact(), expectedSHA256: String(repeating: "AB", count: 32))
        #expect(declared.name == "mirror")
        #expect(declared.expectedSHA256 == String(repeating: "ab", count: 32))
        #expect(declared.verification == .checksumProvided)
        #expect(!declared.requiresBrowser)
        #expect(try JSONDecoder().decode(HDCDownloadSource.self, from: JSONEncoder().encode(declared)) == declared)
        #expect(try source("without-hash", artifact: artifact()).verification == .unverified)
    }

    @Test("invalid, credential-bearing and local URLs are not accepted", arguments: [
        "http://downloads.example.com/hdc.zip", "https://user:password@downloads.example.com/hdc.zip",
        "file:///tmp/hdc", "https://downloads.example.com/hdc.zip#fragment", "https://localhost/hdc.zip",
        "https://127.0.0.1/hdc.zip", "https://192.168.1.1/hdc.zip", "https://10.0.0.1/hdc.zip",
        "https://172.16.1.1/hdc.zip", "https://[::1]/hdc.zip", "https://sdk.local/hdc.zip",
        "https://2130706433/hdc.zip", "https://0177.0.0.1/hdc.zip", "https://0x7f000001/hdc.zip",
        "https://0x7f.0.0.1/hdc.zip",
    ])
    func invalidURLs(_ rawURL: String) throws {
        #expect(throws: HDCDownloadSourceError.invalidHTTPSURL) {
            try HDCDownloadSource.custom(name: "bad", url: URL(string: rawURL)!, artifact: artifact())
        }
    }

    @Test("version, name, hash and decoded configuration are validated")
    func invalidMetadataAndPersistence() throws {
        #expect(throws: HDCDownloadSourceError.invalidVersion) { try artifact(" \n ") }
        #expect(throws: HDCDownloadSourceError.invalidVersion) { try artifact("5.0\nforged") }
        #expect(throws: HDCDownloadSourceError.invalidName) { try source(" ", artifact: artifact()) }
        #expect(throws: HDCDownloadSourceError.invalidSHA256) {
            try HDCDownloadSource.custom(name: "mirror", url: URL(string: "https://downloads.example.com/hdc")!,
                artifact: artifact(), expectedSHA256: String(repeating: "z", count: 64))
        }
        let good = try source("persisted", artifact: artifact())
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(good)) as? [String: Any])
        json["url"] = "http://downloads.example.com/hdc.zip"
        let invalid = try JSONSerialization.data(withJSONObject: json)
        #expect(throws: HDCDownloadSourceError.invalidHTTPSURL) {
            try JSONDecoder().decode(HDCDownloadSource.self, from: invalid)
        }
        var official = try #require(JSONSerialization.jsonObject(with:
            JSONEncoder().encode(HDCDownloadSource.officialHuaweiEntry)) as? [String: Any])
        official["url"] = "https://untrusted.example.com/hdc.zip"
        let spoof = try JSONSerialization.data(withJSONObject: official)
        #expect(throws: HDCDownloadSourceError.invalidOfficialEntry) {
            try JSONDecoder().decode(HDCDownloadSource.self, from: spoof)
        }
    }

    @Test("limits cannot exceed fixed byte, time, redirect and concurrency ceilings")
    func hardLimits() {
        let configuration = HDCDownloadBenchmarkConfiguration(maximumSampleBytes: .max, timeout: 999,
            maximumConcurrentProbes: .max, maximumRedirects: .max)
        #expect(configuration.maximumSampleBytes == 1_048_576)
        #expect(configuration.timeout == 15)
        #expect(configuration.maximumConcurrentProbes == 4)
        #expect(configuration.maximumRedirects == 3)
        let invalid = HDCDownloadBenchmarkConfiguration(maximumSampleBytes: -1, timeout: .nan,
            maximumConcurrentProbes: -1, maximumRedirects: -1)
        #expect(invalid.maximumSampleBytes == 1)
        #expect(invalid.timeout.isFinite)
        #expect(invalid.maximumConcurrentProbes == 1)
        #expect(invalid.maximumRedirects == 0)
    }

    @Test("only equal version and architecture are sampled and measured successes rank by rate")
    func comparableRanking() async throws {
        let requested = try artifact()
        let slow = try source("slow", artifact: requested)
        let fast = try source("fast", artifact: requested)
        let timeout = try source("timeout", artifact: requested)
        let anotherVersion = try source("other-version", artifact: artifact("5.0.1"))
        let anotherArchitecture = try source("other-arch", artifact: artifact("5.0.0", .x86_64))
        let transport = HDCRecordingProbeTransport()
        let start = Date()
        let results = await HDCDownloadSourceBenchmarker(configuration: .init(maximumSampleBytes: 8,
            maximumConcurrentProbes: 2), transport: transport).benchmark(sources:
            [slow, .officialHuaweiEntry, anotherVersion, timeout, fast, anotherArchitecture], for: requested)
        #expect(results.count == 6)
        #expect(results[0].sourceID == fast.id)
        #expect(results[1].sourceID == slow.id)
        #expect(results[0].bytesPerSecond == 80)
        #expect(results[1].bytesPerSecond == 8)
        #expect(results[0].bytesReceived == 8)
        #expect(results[0].latency == 0.01)
        #expect(results.allSatisfy { $0.measuredAt >= start && $0.measuredAt <= Date() })
        #expect(results.first { $0.sourceID == timeout.id }?.failure == .timedOut)
        #expect(results.first { $0.sourceID == anotherVersion.id }?.failure == .artifactMismatch)
        #expect(results.first { $0.sourceID == anotherArchitecture.id }?.failure == .artifactMismatch)
        #expect(results.first { $0.sourceID == HDCDownloadSource.officialHuaweiEntry.id }?.failure == .officialEntryRequiresBrowser)
        #expect(await transport.observedPaths().sorted() == ["/fast", "/slow", "/timeout"])
        #expect(await transport.maximumActiveCount() <= 2)
    }

    @Test("cancellation stops queued probes and invalid transport samples never receive rankings")
    func cancelAndInvalidSamples() async throws {
        let requested = try artifact()
        let transport = HDCRecordingProbeTransport(delay: .seconds(5))
        let sources = try (0..<8).map { try source("cancel-\($0)", artifact: requested) }
        let task = Task {
            await HDCDownloadSourceBenchmarker(configuration: .init(maximumSampleBytes: 8,
                maximumConcurrentProbes: 2), transport: transport).benchmark(sources: sources, for: requested)
        }
        for _ in 0..<100 {
            if await transport.observedPaths().count >= 2 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        task.cancel()
        let results = await task.value
        #expect(results.count == 8)
        #expect(results.allSatisfy { $0.failure == .cancelled })
        #expect(await transport.observedPaths().count <= 2)
        let result = await HDCDownloadSourceBenchmarker(configuration: .init(maximumSampleBytes: 8),
            transport: HDCInvalidSampleTransport()).benchmark(sources: [sources[0]], for: requested)
        #expect(result.first?.failure == .invalidMeasurement)
        #expect(result.first?.bytesPerSecond == nil)
    }

    @Test("real URLSession delegate requests a small range and retains only bounded metrics")
    func streamingRange() async throws {
        let fixture = HDCProbeFixture(headers: ["Content-Range": "bytes 0-7/1000000", "Content-Length": "8"],
            chunks: [Data(repeating: 1, count: 3), Data(repeating: 2, count: 5)])
        let url = HDCProbeURLProtocol.store.register(fixture)
        defer { HDCProbeURLProtocol.store.remove(url) }
        let sample = try await makeSessionTransport().probe(.init(url: url, maximumBytes: 8, timeout: 1))
        #expect(sample.bytesReceived == 8)
        #expect(sample.duration > 0 && sample.latency >= 0 && sample.latency <= sample.duration)
        #expect(sample.finalURL == url)
        let request = try #require(HDCProbeURLProtocol.store.request(for: url))
        #expect(request.value(forHTTPHeaderField: "Range") == "bytes=0-7")
        #expect(request.value(forHTTPHeaderField: "Accept-Encoding") == "identity")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
    }

    @Test("a 200 is cancelled before its package body and never becomes a full download")
    func rejectsFullResponse() async throws {
        let url = HDCProbeURLProtocol.store.register(.init(status: 200,
            headers: ["Content-Length": "2000000"], chunks: [Data(repeating: 1, count: 2_000_000)], delay: 0.1))
        defer { HDCProbeURLProtocol.store.remove(url) }
        await #expect(throws: HDCDownloadProbeFailure.rangeUnsupported) {
            try await makeSessionTransport().probe(.init(url: url, maximumBytes: 8, timeout: 1))
        }
        try await Task.sleep(for: .milliseconds(120))
        #expect(HDCProbeURLProtocol.store.emittedBytes(for: url) == 0)
        #expect(HDCProbeURLProtocol.store.stopped(for: url))
    }

    @Test("invalid range and compressed responses are rejected before data", arguments: [
        ("bytes 0-999/1000", "identity"), ("bytes 1-7/1000", "identity"),
        ("bytes 0-7/2", "identity"), ("bytes 0-7/1000", "gzip"),
    ])
    func invalidRange(_ input: (String, String)) async throws {
        let url = HDCProbeURLProtocol.store.register(.init(headers: [
            "Content-Range": input.0, "Content-Encoding": input.1,
        ], chunks: [Data(repeating: 1, count: 8)], delay: 0.05))
        defer { HDCProbeURLProtocol.store.remove(url) }
        let expected: HDCDownloadProbeFailure = input.1 == "gzip" ? .unexpectedContentEncoding : .invalidContentRange
        await #expect(throws: expected) {
            try await makeSessionTransport().probe(.init(url: url, maximumBytes: 8, timeout: 1))
        }
        #expect(HDCProbeURLProtocol.store.emittedBytes(for: url) == 0)
    }

    @Test("truncated and oversized samples cannot be reported as complete ranges", arguments: [3, 16])
    func wrongBodySize(_ count: Int) async throws {
        let url = HDCProbeURLProtocol.store.register(.init(headers: ["Content-Range": "bytes 0-7/1000"],
            chunks: [Data(repeating: 1, count: count)]))
        defer { HDCProbeURLProtocol.store.remove(url) }
        await #expect(throws: count < 8 ? HDCDownloadProbeFailure.incompleteRange : .byteLimitExceeded) {
            try await makeSessionTransport().probe(.init(url: url, maximumBytes: 8, timeout: 1))
        }
    }

    @Test("deadline and Task cancellation close a stalled streaming request", arguments: [false, true])
    func deadlineAndCancellation(_ cancel: Bool) async throws {
        let url = HDCProbeURLProtocol.store.register(.init(headers: ["Content-Range": "bytes 0-7/1000"],
            chunks: [], neverFinishes: true))
        defer { HDCProbeURLProtocol.store.remove(url) }
        let transport = makeSessionTransport()
        let start = ContinuousClock.now
        let task = Task { try await transport.probe(.init(url: url, maximumBytes: 8, timeout: cancel ? 2 : 0.08)) }
        if cancel {
            try await Task.sleep(for: .milliseconds(20))
            task.cancel()
        }
        await #expect(throws: cancel ? HDCDownloadProbeFailure.cancelled : .timedOut) { try await task.value }
        #expect(start.duration(to: .now) < .seconds(1))
        // URLSession invalidation can deliver stopLoading after resuming the caller.
        for _ in 0..<100 {
            if HDCProbeURLProtocol.store.stopped(for: url) { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(HDCProbeURLProtocol.store.stopped(for: url))
    }

    @Test("the overall deadline does not reset when the source drips partial bytes")
    func progressiveDeadline() async throws {
        let url = HDCProbeURLProtocol.store.register(.init(headers: ["Content-Range": "bytes 0-7/1000"],
            chunks: (0..<8).map { _ in Data([1]) }, delay: 0.03))
        defer { HDCProbeURLProtocol.store.remove(url) }
        let start = ContinuousClock.now
        await #expect(throws: HDCDownloadProbeFailure.timedOut) {
            try await makeSessionTransport().probe(.init(url: url, maximumBytes: 8, timeout: 0.08))
        }
        #expect(start.duration(to: .now) < .seconds(1))
        #expect(HDCProbeURLProtocol.store.emittedBytes(for: url) < 8)
    }

    @Test("unsafe or unbounded direct transport requests never create sessions")
    func invalidTransportRequests() async {
        let transport = makeSessionTransport()
        for request in [
            HDCDownloadProbeRequest(url: URL(string: "http://downloads.example.com/hdc.zip")!, maximumBytes: 8, timeout: 1),
            HDCDownloadProbeRequest(url: URL(string: "https://downloads.example.com/hdc.zip")!, maximumBytes: .max, timeout: 1),
            HDCDownloadProbeRequest(url: URL(string: "https://downloads.example.com/hdc.zip")!, maximumBytes: 8, timeout: .infinity),
        ] {
            await #expect(throws: HDCDownloadProbeFailure.invalidRequest) { try await transport.probe(request) }
        }
    }

    #if !os(Linux)
    // swift-corelibs-foundation URLProtocol does not implement redirect callbacks.
    // These exercise URLSession's real redirect delegate on the shipping platform.
    @Test("redirects preserve Range but HTTPS downgrade and redirect loops are blocked", arguments: ["safe", "http", "limit"])
    func redirects(_ variant: String) async throws {
        let destination = HDCProbeURLProtocol.store.register(.init(headers: ["Content-Range": "bytes 0-7/1000"],
            chunks: [Data(repeating: 1, count: 8)]))
        let redirect = variant == "http" ? URL(string: "http://downloads.example.com/insecure")! : destination
        let url = HDCProbeURLProtocol.store.register(.init(status: 302, headers: [:], chunks: [], redirect: redirect))
        defer { HDCProbeURLProtocol.store.remove(url); HDCProbeURLProtocol.store.remove(destination) }
        let request = HDCDownloadProbeRequest(url: url, maximumBytes: 8, timeout: 1,
            maximumRedirects: variant == "limit" ? 0 : 3)
        if variant == "safe" {
            let sample = try await makeSessionTransport().probe(request)
            #expect(sample.finalURL == destination)
            #expect(HDCProbeURLProtocol.store.request(for: destination)?.value(forHTTPHeaderField: "Range") == "bytes=0-7")
        } else {
            await #expect(throws: variant == "http" ? HDCDownloadProbeFailure.insecureRedirect : .tooManyRedirects) {
                try await makeSessionTransport().probe(request)
            }
            #expect(HDCProbeURLProtocol.store.request(for: destination) == nil)
        }
    }
    #endif

    private func makeSessionTransport() -> URLSessionHDCDownloadProbeTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HDCProbeURLProtocol.self]
        configuration.httpAdditionalHeaders = ["Authorization": "fixture-do-not-forward", "Cookie": "fixture=not-forwarded"]
        return .init(configuration: configuration)
    }
}

private actor HDCRecordingProbeTransport: HDCDownloadProbeTransport {
    private var paths: [String] = []
    private var active = 0
    private var maximumActive = 0
    private let delay: Duration

    init(delay: Duration = .milliseconds(10)) { self.delay = delay }

    func probe(_ request: HDCDownloadProbeRequest) async throws -> HDCDownloadProbeSample {
        paths.append(request.url.path)
        active += 1
        maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        try await Task.sleep(for: delay)
        if request.url.path == "/timeout" { throw HDCDownloadProbeFailure.timedOut }
        return .init(bytesReceived: request.maximumBytes, latency: 0.01,
            duration: request.url.path == "/fast" ? 0.1 : 1, finalURL: request.url)
    }

    func observedPaths() -> [String] { paths }
    func maximumActiveCount() -> Int { maximumActive }
}

private struct HDCInvalidSampleTransport: HDCDownloadProbeTransport {
    func probe(_ request: HDCDownloadProbeRequest) async throws -> HDCDownloadProbeSample {
        .init(bytesReceived: request.maximumBytes + 1, latency: -1, duration: .nan, finalURL: request.url)
    }
}

private struct HDCProbeFixture: Sendable {
    var status = 206
    var headers: [String: String]
    var chunks: [Data]
    var delay: TimeInterval = 0.01
    var neverFinishes = false
    var redirect: URL?
}

/// Per-URL fixtures make parallel Swift Testing cases independent. They still run
/// through a real URLSession and its streaming/cancellation delegate, without DNS,
/// internet access, credentials, downloads to disk, or executing any fixture bytes.
private final class HDCProbeFixtureStore: @unchecked Sendable {
    private struct Entry {
        let fixture: HDCProbeFixture
        var request: URLRequest?
        var emittedBytes = 0
        var stopped = false
    }
    private let lock = NSLock()
    private var entries: [URL: Entry] = [:]

    func register(_ fixture: HDCProbeFixture) -> URL {
        let url = URL(string: "https://downloads.example.com/fixture/\(UUID().uuidString)")!
        lock.lock(); defer { lock.unlock() }
        entries[url] = .init(fixture: fixture)
        return url
    }
    func remove(_ url: URL) { lock.lock(); defer { lock.unlock() }; entries[url] = nil }
    func fixture(for request: URLRequest) -> HDCProbeFixture? {
        guard let url = request.url else { return nil }
        lock.lock(); defer { lock.unlock() }
        entries[url]?.request = request
        return entries[url]?.fixture
    }
    func request(for url: URL) -> URLRequest? { lock.lock(); defer { lock.unlock() }; return entries[url]?.request }
    func emittedBytes(for url: URL) -> Int { lock.lock(); defer { lock.unlock() }; return entries[url]?.emittedBytes ?? 0 }
    func emitted(_ bytes: Int, for url: URL) { lock.lock(); defer { lock.unlock() }; entries[url]?.emittedBytes += bytes }
    func stopped(for url: URL) -> Bool { lock.lock(); defer { lock.unlock() }; return entries[url]?.stopped ?? false }
    func stop(_ url: URL) { lock.lock(); defer { lock.unlock() }; entries[url]?.stopped = true }
}

private final class HDCProbeURLProtocol: URLProtocol {
    static let store = HDCProbeFixtureStore()
    private let stateLock = NSLock()
    private var isStopped = false

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "downloads.example.com" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let fixture = Self.store.fixture(for: request), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: fixture.status, httpVersion: "HTTP/1.1", headerFields: fixture.headers)!
        if let redirect = fixture.redirect {
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: redirect), redirectResponse: response)
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        send(fixture, index: 0)
    }

    private func send(_ fixture: HDCProbeFixture, index: Int) {
        let reference = HDCWeakProbeProtocol(self)
        DispatchQueue.global().asyncAfter(deadline: .now() + fixture.delay) {
            guard let owner = reference.value else { return }
            owner.emit(fixture, index: index)
        }
    }

    private func emit(_ fixture: HDCProbeFixture, index: Int) {
        stateLock.lock()
        let stopped = isStopped
        stateLock.unlock()
        guard !stopped else { return }
        if index < fixture.chunks.count {
            if let url = request.url { Self.store.emitted(fixture.chunks[index].count, for: url) }
            client?.urlProtocol(self, didLoad: fixture.chunks[index])
            send(fixture, index: index + 1)
        } else if !fixture.neverFinishes {
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        stateLock.lock(); isStopped = true; stateLock.unlock()
        if let url = request.url { Self.store.stop(url) }
    }
}

// URLProtocol deliberately marks Sendable unavailable in FoundationNetworking.
// The weak box crosses only the fixture queue boundary, while protocol state is
// protected by its own lock; it does not pretend the entire URLProtocol is safe.
private final class HDCWeakProbeProtocol: @unchecked Sendable {
    weak var value: HDCProbeURLProtocol?
    init(_ value: HDCProbeURLProtocol) { self.value = value }
}
