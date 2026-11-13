import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum HDCDownloadArchitecture: String, Codable, CaseIterable, Sendable {
    case arm64
    case x86_64
}

public enum HDCDownloadSourceError: Error, Equatable, Sendable {
    case invalidName
    case invalidHTTPSURL
    case invalidVersion
    case invalidSHA256
    case invalidOfficialEntry
}

/// Equality intentionally requires the exact declared version and architecture. A faster
/// endpoint for another SDK version must never win a comparison for the requested tool.
public struct HDCDownloadArtifact: Codable, Hashable, Sendable {
    public let version: String
    public let architecture: HDCDownloadArchitecture

    public init(version: String, architecture: HDCDownloadArchitecture) throws {
        let version = version.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !version.isEmpty, version.utf8.count <= 128,
              !version.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw HDCDownloadSourceError.invalidVersion
        }
        self.version = version
        self.architecture = architecture
    }

    private enum CodingKeys: String, CodingKey { case version, architecture }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(version: values.decode(String.self, forKey: .version),
                      architecture: values.decode(HDCDownloadArchitecture.self, forKey: .architecture))
    }
}

public enum HDCDownloadSourceKind: String, Codable, Sendable {
    case officialEntry
    case custom
}

/// A configured hash is not proof of publisher identity, a signature, or a verified
/// download. Sampling never verifies a full archive and never makes it executable.
public enum HDCDownloadSourceVerification: String, Codable, Sendable {
    case unverified
    case checksumProvided
}

public struct HDCDownloadSource: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let name: String
    public let url: URL
    public let kind: HDCDownloadSourceKind
    public let artifact: HDCDownloadArtifact?
    public let expectedSHA256: String?

    /// This is a navigation entry, not an invented archive URL. Huawei may require
    /// browser login, SDK selection, and acceptance of its own download terms.
    public static let officialHuaweiEntry = HDCDownloadSource(
        id: UUID(uuidString: "79B5012A-AC79-42E0-8419-0B09F510A018")!,
        name: "Huawei Developer downloads",
        url: URL(string: "https://developer.huawei.com/consumer/cn/download/")!,
        kind: .officialEntry, artifact: nil, expectedSHA256: nil)

    public var requiresBrowser: Bool { kind == .officialEntry }
    public var mayRequireLogin: Bool { kind == .officialEntry }
    public var verification: HDCDownloadSourceVerification {
        expectedSHA256 == nil ? .unverified : .checksumProvided
    }

    public static func custom(id: UUID = UUID(), name: String, url: URL,
                              artifact: HDCDownloadArtifact,
                              expectedSHA256: String? = nil) throws -> Self {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf8.count <= 256,
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw HDCDownloadSourceError.invalidName
        }
        guard isPermittedHTTPSURL(url) else { throw HDCDownloadSourceError.invalidHTTPSURL }
        let hash = expectedSHA256?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let hash {
            guard hash.utf8.count == 64, hash.utf8.allSatisfy({
                (48...57).contains($0) || (97...102).contains($0)
            }) else { throw HDCDownloadSourceError.invalidSHA256 }
        }
        return Self(id: id, name: name, url: url, kind: .custom,
                    artifact: artifact, expectedSHA256: hash)
    }

    private init(id: UUID, name: String, url: URL, kind: HDCDownloadSourceKind,
                 artifact: HDCDownloadArtifact?, expectedSHA256: String?) {
        self.id = id
        self.name = name
        self.url = url
        self.kind = kind
        self.artifact = artifact
        self.expectedSHA256 = expectedSHA256
    }

    private enum CodingKeys: String, CodingKey { case id, name, url, kind, artifact, expectedSHA256 }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try values.decode(HDCDownloadSourceKind.self, forKey: .kind)
        if kind == .officialEntry {
            // Do not allow a persisted custom URL to masquerade as our official entry.
            let official = Self.officialHuaweiEntry
            guard try values.decode(UUID.self, forKey: .id) == official.id,
                  try values.decode(String.self, forKey: .name) == official.name,
                  try values.decode(URL.self, forKey: .url) == official.url,
                  try values.decodeIfPresent(HDCDownloadArtifact.self, forKey: .artifact) == nil,
                  try values.decodeIfPresent(String.self, forKey: .expectedSHA256) == nil else {
                throw HDCDownloadSourceError.invalidOfficialEntry
            }
            self = official
        } else {
            self = try Self.custom(id: values.decode(UUID.self, forKey: .id),
                                   name: values.decode(String.self, forKey: .name),
                                   url: values.decode(URL.self, forKey: .url),
                                   artifact: values.decode(HDCDownloadArtifact.self, forKey: .artifact),
                                   expectedSHA256: values.decodeIfPresent(String.self, forKey: .expectedSHA256))
        }
    }
}

private func isPermittedHTTPSURL(_ url: URL) -> Bool {
    guard url.scheme?.lowercased() == "https", let rawHost = url.host, !rawHost.isEmpty,
          url.user == nil, url.password == nil, url.fragment == nil else { return false }
    let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".[]"))
    guard host != "localhost", !host.hasSuffix(".localhost"), !host.hasSuffix(".local"),
          !host.contains(":"), !host.isEmpty else { return false }
    let labels = host.split(separator: ".", omittingEmptySubsequences: false)
    if labels.contains(where: { $0.hasPrefix("0x") }), labels.allSatisfy({ label in
        label.allSatisfy(\.isNumber) || (label.hasPrefix("0x") && !label.dropFirst(2).isEmpty
            && label.dropFirst(2).allSatisfy(\.isHexDigit))
    }) { return false }
    // Literal IPv4 targets in local/private/reserved networks are not download
    // mirrors. IPv6 literals are disallowed above. This is not a DNS-rebinding
    // defense; no credentials/cookies are sent to any hostname in the first place.
    if host.allSatisfy({ $0.isNumber || $0 == "." }) {
        let pieces = host.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 4, pieces.allSatisfy({
            guard let value = Int($0) else { return false }
            return (0...255).contains(value) && String(value) == $0
        }), let first = Int(pieces[0]), let second = Int(pieces[1]) else { return false }
        guard first != 0, first != 10, first != 127, first < 224,
              !(first == 100 && (64...127).contains(second)),
              !(first == 169 && second == 254),
              !(first == 172 && (16...31).contains(second)),
              !(first == 192 && second == 168),
              !(first == 198 && (18...19).contains(second)) else { return false }
    }
    return true
}

public enum HDCDownloadProbeFailure: Error, Equatable, Sendable {
    case officialEntryRequiresBrowser
    case artifactMismatch
    case invalidRequest
    case nonHTTPResponse
    case insecureRedirect
    case tooManyRedirects
    case rangeUnsupported
    case invalidContentRange
    case unexpectedContentEncoding
    case authenticationRequired
    case httpStatus(Int)
    case timedOut
    case cancelled
    case emptyResponse
    case incompleteRange
    case byteLimitExceeded
    case invalidMeasurement
    case networkError(Int)
    case transportFailed

    /// Safe for display: deliberately excludes URLs, signed queries and server error text.
    public var message: String {
        switch self {
        case .officialEntryRequiresBrowser: "Open the official download page in your browser."
        case .artifactMismatch: "Only the same HDC version and architecture can be compared."
        case .invalidRequest: "The bounded sample request is invalid."
        case .nonHTTPResponse: "The source did not return an HTTP response."
        case .insecureRedirect: "The source redirected to a non-HTTPS or credential-bearing URL."
        case .tooManyRedirects: "The source exceeded the redirect limit."
        case .rangeUnsupported: "The source does not support byte-range sampling; its response body was not accepted."
        case .invalidContentRange: "The source returned an invalid or oversized byte range."
        case .unexpectedContentEncoding: "The source did not return an uncompressed byte range."
        case .authenticationRequired: "This source requires authentication; open it in your browser."
        case .httpStatus(let status): "The source returned HTTP \(status)."
        case .timedOut: "The source exceeded the sample time limit."
        case .cancelled: "The speed test was cancelled."
        case .emptyResponse: "The source returned no sample bytes."
        case .incompleteRange: "The source ended before the promised sample range was received."
        case .byteLimitExceeded: "The source exceeded the sample byte limit."
        case .invalidMeasurement: "The sample transport returned an invalid measurement."
        case .networkError(let code): "The sample request failed (network error \(code))."
        case .transportFailed: "The sample request failed."
        }
    }
}

public struct HDCDownloadBenchmarkConfiguration: Equatable, Sendable {
    public static let hardMaximumSampleBytes = 1_048_576
    public static let hardMaximumTimeout: TimeInterval = 15
    public static let hardMaximumConcurrentProbes = 4
    public static let hardMaximumRedirects = 3

    public let maximumSampleBytes: Int
    public let timeout: TimeInterval
    public let maximumConcurrentProbes: Int
    public let maximumRedirects: Int

    public init(maximumSampleBytes: Int = 262_144, timeout: TimeInterval = 4,
                maximumConcurrentProbes: Int = 2, maximumRedirects: Int = 3) {
        self.maximumSampleBytes = min(max(maximumSampleBytes, 1), Self.hardMaximumSampleBytes)
        self.timeout = timeout.isFinite ? min(max(timeout, 0.05), Self.hardMaximumTimeout) : 4
        self.maximumConcurrentProbes = min(max(maximumConcurrentProbes, 1), Self.hardMaximumConcurrentProbes)
        self.maximumRedirects = min(max(maximumRedirects, 0), Self.hardMaximumRedirects)
    }
}

public struct HDCDownloadProbeRequest: Sendable {
    public let url: URL
    public let maximumBytes: Int
    public let timeout: TimeInterval
    public let maximumRedirects: Int

    public init(url: URL, maximumBytes: Int, timeout: TimeInterval, maximumRedirects: Int = 3) {
        self.url = url
        self.maximumBytes = maximumBytes
        self.timeout = timeout
        self.maximumRedirects = maximumRedirects
    }

    fileprivate var isValid: Bool {
        isPermittedHTTPSURL(url) && (1...HDCDownloadBenchmarkConfiguration.hardMaximumSampleBytes).contains(maximumBytes)
            && timeout.isFinite && (0.05...HDCDownloadBenchmarkConfiguration.hardMaximumTimeout).contains(timeout)
            && (0...HDCDownloadBenchmarkConfiguration.hardMaximumRedirects).contains(maximumRedirects)
    }
}

/// Metrics only. No archive bytes are retained or made available to an executable path.
public struct HDCDownloadProbeSample: Sendable {
    public let bytesReceived: Int
    public let latency: TimeInterval
    /// Total monotonic elapsed time, including connection and first-response latency.
    public let duration: TimeInterval
    public let finalURL: URL

    public init(bytesReceived: Int, latency: TimeInterval, duration: TimeInterval, finalURL: URL) {
        self.bytesReceived = bytesReceived
        self.latency = latency
        self.duration = duration
        self.finalURL = finalURL
    }
}

public protocol HDCDownloadProbeTransport: Sendable {
    func probe(_ request: HDCDownloadProbeRequest) async throws -> HDCDownloadProbeSample
}

public struct HDCDownloadBenchmarkResult: Identifiable, Equatable, Sendable {
    public var id: UUID { sourceID }
    public let sourceID: UUID
    public let artifact: HDCDownloadArtifact
    public let measuredAt: Date
    public let bytesReceived: Int
    public let bytesPerSecond: Double?
    public let latency: TimeInterval?
    public let duration: TimeInterval?
    public let failure: HDCDownloadProbeFailure?

    public var succeeded: Bool { failure == nil && bytesPerSecond != nil }
}

public struct HDCDownloadSourceBenchmarker: Sendable {
    public let configuration: HDCDownloadBenchmarkConfiguration
    private let transport: any HDCDownloadProbeTransport

    public init(configuration: HDCDownloadBenchmarkConfiguration = .init(),
                transport: any HDCDownloadProbeTransport = URLSessionHDCDownloadProbeTransport()) {
        self.configuration = configuration
        self.transport = transport
    }

    /// Cancelling the calling Task cancels in-flight requests and does not start queued
    /// probes. Nonmatching versions/architectures and official landing pages never hit
    /// the transport. Their explicit failures remain visible after ranked successes.
    public func benchmark(sources: [HDCDownloadSource], for artifact: HDCDownloadArtifact) async
        -> [HDCDownloadBenchmarkResult] {
        var results: [HDCDownloadBenchmarkResult] = []
        var candidates: [HDCDownloadSource] = []
        for source in sources {
            if source.requiresBrowser {
                results.append(Self.failed(source, artifact, .officialEntryRequiresBrowser))
            } else if source.artifact != artifact {
                results.append(Self.failed(source, artifact, .artifactMismatch))
            } else {
                candidates.append(source)
            }
        }
        let configuration = self.configuration
        let transport = self.transport
        let measured = await withTaskGroup(of: HDCDownloadBenchmarkResult.self) { group in
            var next = 0
            var collected: [HDCDownloadBenchmarkResult] = []
            while next < min(configuration.maximumConcurrentProbes, candidates.count), !Task.isCancelled {
                let source = candidates[next]
                group.addTask { await Self.measure(source, artifact, configuration, transport) }
                next += 1
            }
            while let result = await group.next() {
                collected.append(result)
                if Task.isCancelled {
                    group.cancelAll()
                } else if next < candidates.count {
                    let source = candidates[next]
                    group.addTask { await Self.measure(source, artifact, configuration, transport) }
                    next += 1
                }
            }
            while next < candidates.count {
                collected.append(Self.failed(candidates[next], artifact, .cancelled))
                next += 1
            }
            return collected
        }
        results.append(contentsOf: measured)
        return results.sorted { left, right in
            if left.succeeded != right.succeeded { return left.succeeded }
            if left.bytesPerSecond != right.bytesPerSecond {
                return (left.bytesPerSecond ?? -1) > (right.bytesPerSecond ?? -1)
            }
            if left.latency != right.latency {
                return (left.latency ?? .infinity) < (right.latency ?? .infinity)
            }
            return left.sourceID.uuidString < right.sourceID.uuidString
        }
    }

    private static func failed(_ source: HDCDownloadSource, _ artifact: HDCDownloadArtifact,
                               _ failure: HDCDownloadProbeFailure, at date: Date = Date()) -> HDCDownloadBenchmarkResult {
        .init(sourceID: source.id, artifact: artifact, measuredAt: date, bytesReceived: 0,
              bytesPerSecond: nil, latency: nil, duration: nil, failure: failure)
    }

    private static func measure(_ source: HDCDownloadSource, _ artifact: HDCDownloadArtifact,
                                _ configuration: HDCDownloadBenchmarkConfiguration,
                                _ transport: any HDCDownloadProbeTransport) async -> HDCDownloadBenchmarkResult {
        let date = Date()
        do {
            try Task.checkCancellation()
            let sample = try await transport.probe(.init(url: source.url,
                maximumBytes: configuration.maximumSampleBytes, timeout: configuration.timeout,
                maximumRedirects: configuration.maximumRedirects))
            try Task.checkCancellation()
            guard sample.bytesReceived > 0, sample.bytesReceived <= configuration.maximumSampleBytes,
                  sample.duration.isFinite, sample.duration > 0,
                  sample.latency.isFinite, sample.latency >= 0, sample.latency <= sample.duration,
                  isPermittedHTTPSURL(sample.finalURL),
                  (Double(sample.bytesReceived) / sample.duration).isFinite else {
                return failed(source, artifact, .invalidMeasurement, at: date)
            }
            return .init(sourceID: source.id, artifact: artifact, measuredAt: date,
                         bytesReceived: sample.bytesReceived,
                         bytesPerSecond: Double(sample.bytesReceived) / sample.duration,
                         latency: sample.latency, duration: sample.duration, failure: nil)
        } catch is CancellationError {
            return failed(source, artifact, .cancelled, at: date)
        } catch let error as HDCDownloadProbeFailure {
            return failed(source, artifact, error, at: date)
        } catch {
            return failed(source, artifact, .transportFailed, at: date)
        }
    }
}

// Internal, read-only audit events allow deterministic tests of the actual response
// disposition and accepted byte counters. Production never installs an observer.
enum HDCDownloadProbeEvent: Equatable, Sendable {
    enum Disposition: Equatable, Sendable { case allow, cancel }
    case responseDisposition(Disposition)
    case finished(bytesAccepted: Int, failure: HDCDownloadProbeFailure?)
}

/// Uses streaming URLSession delegate callbacks rather than data(for:), rejects a
/// 200 before accepting a body, and retains only counters. The byte ceiling applies
/// to accepted sample bytes, not bytes a server has already emitted or URLSession/
/// the network stack may have prefetched before delivering the response callback.
/// Such in-flight bytes are discarded, never retained as a package. The copied configuration
/// is immutable here; each probe owns its session, deadline and cancellation state.
public final class URLSessionHDCDownloadProbeTransport: HDCDownloadProbeTransport, @unchecked Sendable {
    private let configuration: URLSessionConfiguration
    private let observe: (@Sendable (HDCDownloadProbeEvent) -> Void)?

    public init(configuration: URLSessionConfiguration = .ephemeral) {
        self.configuration = configuration.copy() as! URLSessionConfiguration
        self.observe = nil
    }

    // The observer has no ability to change dispositions, deadlines, or limits.
    init(configuration: URLSessionConfiguration,
         observe: @escaping @Sendable (HDCDownloadProbeEvent) -> Void) {
        self.configuration = configuration.copy() as! URLSessionConfiguration
        self.observe = observe
    }

    public func probe(_ request: HDCDownloadProbeRequest) async throws -> HDCDownloadProbeSample {
        guard request.isValid else { throw HDCDownloadProbeFailure.invalidRequest }
        let operation = HDCBoundedProbeOperation(request: request,
            configuration: configuration.copy() as! URLSessionConfiguration, observe: observe)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                operation.start(continuation)
            }
        } onCancel: {
            operation.cancel()
        }
    }
}

// Internal for deterministic delegate-order tests; not part of the package API.
final class HDCBoundedProbeOperation: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let request: HDCDownloadProbeRequest
    private let configuration: URLSessionConfiguration
    private let observe: (@Sendable (HDCDownloadProbeEvent) -> Void)?
    private let lock = NSLock()
    private var continuation: CheckedContinuation<HDCDownloadProbeSample, any Error>?
    private var completed: Result<HDCDownloadProbeSample, any Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var deadline: DispatchWorkItem?
    private var startedAt: TimeInterval = 0
    private var responseAt: TimeInterval?
    private var expectedBytes: Int?
    private var receivedBytes = 0
    private var redirects = 0
    private var finalURL: URL

    init(request: HDCDownloadProbeRequest, configuration: URLSessionConfiguration,
         observe: (@Sendable (HDCDownloadProbeEvent) -> Void)? = nil) {
        self.request = request
        self.configuration = configuration
        self.observe = observe
        self.finalURL = request.url
    }

    func start(_ continuation: CheckedContinuation<HDCDownloadProbeSample, any Error>) {
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpAdditionalHeaders = [:]
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = request.timeout
        configuration.timeoutIntervalForResource = request.timeout
        configuration.httpMaximumConnectionsPerHost = 1
        #if !os(Linux)
        configuration.waitsForConnectivity = false
        #endif
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        let task = session.dataTask(with: sampleRequest(request.url))
        let deadline = DispatchWorkItem { [weak self] in self?.finish(.failure(HDCDownloadProbeFailure.timedOut)) }
        lock.lock()
        if let completed {
            lock.unlock()
            session.invalidateAndCancel()
            continuation.resume(with: completed)
            return
        }
        self.continuation = continuation
        self.session = session
        self.task = task
        self.deadline = deadline
        startedAt = ProcessInfo.processInfo.systemUptime
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + request.timeout, execute: deadline)
        task.resume()
    }

    func cancel() { finish(.failure(HDCDownloadProbeFailure.cancelled)) }

    // Read-only test diagnostic, including after late callbacks on a finished probe.
    var acceptedByteCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return receivedBytes
    }

    private func sampleRequest(_ url: URL) -> URLRequest {
        var result = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                timeoutInterval: request.timeout)
        result.httpMethod = "GET"
        result.httpShouldHandleCookies = false
        result.setValue("bytes=0-\(request.maximumBytes - 1)", forHTTPHeaderField: "Range")
        result.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        return result
    }

    private func finish(_ result: Result<HDCDownloadProbeSample, any Error>) {
        lock.lock()
        guard completed == nil else { lock.unlock(); return }
        completed = result
        let continuation = self.continuation
        let task = self.task
        let session = self.session
        let deadline = self.deadline
        let bytesAccepted = receivedBytes
        self.continuation = nil
        self.task = nil
        self.session = nil
        self.deadline = nil
        lock.unlock()
        deadline?.cancel()
        task?.cancel()
        session?.invalidateAndCancel()
        let failure: HDCDownloadProbeFailure?
        switch result {
        case .success: failure = nil
        case .failure(let error): failure = (error as? HDCDownloadProbeFailure) ?? .transportFailed
        }
        observe?(.finished(bytesAccepted: bytesAccepted, failure: failure))
        continuation?.resume(with: result)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        #if !os(Linux)
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            // Never override the platform's TLS certificate validation.
            completionHandler(.performDefaultHandling, nil)
            return
        }
        #endif
        // Download probes do not log in or draw credentials/client identities from
        // the user's account. An authenticated download belongs in their browser.
        completionHandler(.cancelAuthenticationChallenge, nil)
        finish(.failure(HDCDownloadProbeFailure.authenticationRequired))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let url = newRequest.url, isPermittedHTTPSURL(url) else {
            completionHandler(nil)
            finish(.failure(HDCDownloadProbeFailure.insecureRedirect))
            return
        }
        lock.lock()
        redirects += 1
        let permitted = completed == nil && redirects <= request.maximumRedirects
        lock.unlock()
        guard permitted else {
            completionHandler(nil)
            finish(.failure(HDCDownloadProbeFailure.tooManyRedirects))
            return
        }
        // Construct afresh, preserving the range but never forwarding cookies or
        // Authorization headers to a different host.
        completionHandler(sampleRequest(url))
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        let validation = validate(response)
        guard case .success(let expected) = validation else {
            completionHandler(.cancel)
            observe?(.responseDisposition(.cancel))
            if case .failure(let error) = validation { finish(.failure(error)) }
            return
        }
        lock.lock()
        let active = completed == nil
        if active {
            expectedBytes = expected
            responseAt = ProcessInfo.processInfo.systemUptime
            finalURL = response.url ?? request.url
        }
        lock.unlock()
        completionHandler(active ? .allow : .cancel)
        observe?(.responseDisposition(active ? .allow : .cancel))
    }

    private func validate(_ response: URLResponse) -> Result<Int, HDCDownloadProbeFailure> {
        guard let response = response as? HTTPURLResponse else { return .failure(.nonHTTPResponse) }
        guard let url = response.url, isPermittedHTTPSURL(url) else { return .failure(.insecureRedirect) }
        guard response.statusCode == 206 else {
            if response.statusCode == 200 { return .failure(.rangeUnsupported) }
            if [401, 403].contains(response.statusCode) { return .failure(.authenticationRequired) }
            return .failure(.httpStatus(response.statusCode))
        }
        let encoding = response.value(forHTTPHeaderField: "Content-Encoding")?.lowercased()
        guard encoding == nil || encoding == "identity" else { return .failure(.unexpectedContentEncoding) }
        guard let header = response.value(forHTTPHeaderField: "Content-Range")?.lowercased(),
              header.hasPrefix("bytes ") else { return .failure(.invalidContentRange) }
        let components = header.dropFirst(6).split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2 else { return .failure(.invalidContentRange) }
        let range = components[0].split(separator: "-", omittingEmptySubsequences: false)
        guard range.count == 2, range[0] == "0", let end = Int(range[1]), end >= 0,
              end < request.maximumBytes else { return .failure(.invalidContentRange) }
        let count = end + 1
        guard components[1] == "*" || (Int(components[1]).map { $0 >= count } ?? false),
              response.expectedContentLength < 0 || response.expectedContentLength == Int64(count) else {
            return .failure(.invalidContentRange)
        }
        return .success(count)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard completed == nil else { lock.unlock(); return }
        guard let expectedBytes, let responseAt else {
            lock.unlock()
            finish(.failure(HDCDownloadProbeFailure.invalidContentRange))
            return
        }
        guard data.count <= expectedBytes - receivedBytes else {
            lock.unlock()
            finish(.failure(HDCDownloadProbeFailure.byteLimitExceeded))
            return
        }
        receivedBytes += data.count
        let complete = receivedBytes == expectedBytes
        let sample = HDCDownloadProbeSample(bytesReceived: receivedBytes,
            latency: max(responseAt - startedAt, 0),
            duration: max(ProcessInfo.processInfo.systemUptime - startedAt, 0.000001), finalURL: finalURL)
        lock.unlock()
        if complete { finish(.success(sample)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error = error as? URLError {
            switch error.code {
            case .cancelled: finish(.failure(HDCDownloadProbeFailure.cancelled))
            case .timedOut: finish(.failure(HDCDownloadProbeFailure.timedOut))
            default: finish(.failure(HDCDownloadProbeFailure.networkError(error.code.rawValue)))
            }
        } else if error != nil {
            finish(.failure(HDCDownloadProbeFailure.transportFailed))
        } else {
            lock.lock()
            let empty = receivedBytes == 0
            lock.unlock()
            finish(.failure(empty ? HDCDownloadProbeFailure.emptyResponse : .incompleteRange))
        }
    }
}
