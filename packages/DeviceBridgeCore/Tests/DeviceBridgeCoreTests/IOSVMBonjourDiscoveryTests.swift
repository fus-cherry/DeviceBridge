import Foundation
import Testing
@testable import DeviceBridgeCore

@Suite("Bounded iOS Bonjour candidate hints")
struct IOSVMBonjourDiscoveryTests {
    @Test("TXT auth and advertised port yield only an unverified redacted candidate")
    func candidate() throws {
        let candidate = try IOSVMBonjourDiscovery.candidate(port: 12345, txt: txt(["other=ignored", "authCode=public-canary="]))
        #expect(candidate.port == 12345)
        #expect(candidate.authenticationCode == "public-canary=")
        #expect(!String(reflecting: candidate).contains("public-canary"))
    }

    @Test("malformed, duplicate or missing TXT auth never becomes a candidate", arguments: ["truncated", "duplicate", "bareDuplicate", "missing", "empty", "newline", "oversized", "badUTF8", "privilegedPort"])
    func badTXT(_ variant: String) async throws {
        let data: Data
        switch variant {
        case "truncated": data = Data([25, 97])
        case "duplicate": data = txt(["authCode=one", "AUTHCODE=two"])
        case "bareDuplicate": data = txt(["authCode", "authCode=valid"])
        case "missing": data = txt(["other=value"])
        case "empty": data = txt(["authCode="])
        case "newline": data = txt(["authCode=hello\nworld"])
        case "oversized": data = Data(repeating: 0, count: 4097)
        case "badUTF8": data = Data([10]) + Data("authCode=".utf8) + Data([255])
        default: data = txt(["authCode=valid"])
        }
        #expect(throws: IOSVMBonjourDiscovery.Failure.invalidRecord) {
            try IOSVMBonjourDiscovery.candidate(port: variant == "privilegedPort" ? 80 : 12345, txt: data)
        }
    }

    @Test("only selected-app local Flutter hints resolve; duplicates across interfaces collapse")
    func scopedBrowse() async throws {
        let queries = BonjourQueries(mode: "scope")
        let hints = try await IOSVMBonjourDiscovery(queries: queries).discover(applicationIDs: ["dev.example.app"], duration: .milliseconds(40))
        #expect(hints.count == 1)
        #expect(hints.first?.applicationID == "dev.example.app")
        #expect(hints.first?.candidate.port == 12345)
        #expect(queries.resolvedServices().count == 2)
        #expect(queries.allCancelled())
    }

    @Test("removed services and failed resolutions do not yield old or fabricated hints", arguments: ["removed", "resolveFailure", "malformedResolution"])
    func unusableService(_ mode: String) async throws {
        let queries = BonjourQueries(mode: mode)
        let hints = try await IOSVMBonjourDiscovery(queries: queries).discover(applicationIDs: ["dev.example.app"], duration: .milliseconds(40))
        #expect(hints.isEmpty)
        #expect(queries.allCancelled())
    }

    @Test("discovery failure and candidate overflow cancel every owned query", arguments: ["browseFailure", "overflow"])
    func failedAttempt(_ mode: String) async throws {
        let queries = BonjourQueries(mode: mode)
        await #expect(throws: IOSVMBonjourDiscovery.Failure.self) {
            try await IOSVMBonjourDiscovery(queries: queries).discover(applicationIDs: ["dev.example.app"], duration: .milliseconds(40))
        }
        #expect(queries.allCancelled())
    }

    @Test("cancellation closes pending queries and rejects deliberately late callbacks")
    func cancelledAttempt() async throws {
        let queries = BonjourQueries(mode: "held")
        let task = Task { try await IOSVMBonjourDiscovery(queries: queries).discover(applicationIDs: ["dev.example.app"]) }
        try await queries.waitUntilResolving()
        task.cancel()
        queries.deliverLate()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(queries.allCancelled())
    }

    @Test("empty scope and pre-cancelled work do not start network discovery")
    func noDiscovery() async throws {
        let queries = BonjourQueries(mode: "scope")
        #expect(try await IOSVMBonjourDiscovery(queries: queries).discover(applicationIDs: []).isEmpty)
        let gate = BonjourStartGate()
        let task = Task { await gate.wait(); return try await IOSVMBonjourDiscovery(queries: queries).discover(applicationIDs: ["dev.example.app"]) }
        task.cancel(); await gate.release()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(queries.queryCount() == 0)
    }

    @Test("a removed and re-added service rejects the previous resolution generation")
    func replacementResolution() async throws {
        let queries = BonjourQueries(mode: "readded")
        let hints = try await IOSVMBonjourDiscovery(queries: queries).discover(applicationIDs: ["dev.example.app"], duration: .milliseconds(40))
        #expect(hints.count == 1)
        #expect(hints.first?.candidate.port == 23456)
        #expect(queries.allCancelled())
    }

    @Test("window expiry disposes unresolved queries before returning and late resolution cannot resume it twice")
    func expiredPendingResolution() async throws {
        let queries = BonjourQueries(mode: "held")
        let hints = try await IOSVMBonjourDiscovery(queries: queries).discover(applicationIDs: ["dev.example.app"], duration: .milliseconds(40))
        #expect(hints.isEmpty)
        #expect(queries.resolvedServices().count == 1)
        #expect(queries.allCancelled())
        queries.deliverLate()
    }
}

private func txt(_ entries: [String]) -> Data {
    entries.reduce(into: Data()) { output, entry in output.append(UInt8(entry.utf8.count)); output.append(contentsOf: entry.utf8) }
}

/// Substitutes only the OS DNS-SD boundary. No test service is published on the user's network.
private final class BonjourQueries: IOSVMDNSQuerying, @unchecked Sendable {
    private let lock = NSLock()
    private let mode: String
    private var handles: [BonjourQuery] = []
    private var services: [IOSVMDNSService] = []
    private var pending: (@Sendable () -> Void)?
    init(mode: String) { self.mode = mode }
    func browse(queue: DispatchQueue, receive: @escaping @Sendable (IOSVMDNSBrowseEvent) -> Void) throws -> any IOSVMDNSQuery {
        let handle = makeHandle(queue)
        let primary = IOSVMDNSService(name: "dev.example.app", type: "_dartVmService._tcp.", domain: "local.", interface: 1)
        queue.async { [mode] in
            if mode == "browseFailure" { receive(.failed); return }
            receive(.add(primary))
            if mode == "removed" { receive(.remove(primary)); return }
            if mode == "readded" { receive(.remove(primary)); receive(.add(primary)); return }
            if mode == "overflow" {
                for i in 2...70 { receive(.add(IOSVMDNSService(name: "dev.example.app \(i)", type: primary.type, domain: primary.domain, interface: 1))) }
            }
            if mode == "scope" {
                receive(.add(primary))
                receive(.add(IOSVMDNSService(name: primary.name, type: primary.type, domain: primary.domain, interface: 2)))
                receive(.add(IOSVMDNSService(name: "dev.example.appevil", type: primary.type, domain: primary.domain, interface: 1)))
                receive(.add(IOSVMDNSService(name: primary.name, type: "_http._tcp.", domain: primary.domain, interface: 1)))
                receive(.add(IOSVMDNSService(name: primary.name, type: primary.type, domain: "foreign.invalid.", interface: 1)))
            }
        }
        return handle
    }
    func resolve(service: IOSVMDNSService, queue: DispatchQueue,
                 receive: @escaping @Sendable (Result<IOSVMDNSResolution, IOSVMBonjourDiscovery.Failure>) -> Void) throws -> any IOSVMDNSQuery {
        let handle = makeHandle(queue)
        let ordinal = lock.withLock { services.append(service); return services.count }
        let deliver: @Sendable () -> Void = { [mode] in
            queue.async {
                if mode == "resolveFailure" { receive(.failure(.unavailable)) }
                else { receive(.success(IOSVMDNSResolution(port: mode == "readded" && ordinal == 2 ? 23456 : 12345,
                    txt: mode == "malformedResolution" ? Data([255]) : txt(["authCode=public-canary="])))) }
            }
        }
        if mode == "held" { lock.withLock { pending = deliver } } else { deliver() }
        return handle
    }
    private func makeHandle(_ queue: DispatchQueue) -> BonjourQuery {
        dispatchPrecondition(condition: .onQueue(queue))
        let handle = BonjourQuery(queue: queue)
        lock.withLock { handles.append(handle) }
        return handle
    }
    func resolvedServices() -> [IOSVMDNSService] { lock.withLock { services } }
    func allCancelled() -> Bool { lock.withLock { !handles.isEmpty && handles.allSatisfy { $0.isCancelled() } } }
    func queryCount() -> Int { lock.withLock { handles.count } }
    func deliverLate() { lock.withLock { pending }?() }
    func waitUntilResolving() async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while lock.withLock({ pending == nil }) {
            guard ContinuousClock.now < deadline else { throw IOSVMBonjourDiscovery.Failure.unavailable }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}

private final class BonjourQuery: IOSVMDNSQuery, @unchecked Sendable {
    let queue: DispatchQueue
    private let lock = NSLock()
    private var cancelled = false
    init(queue: DispatchQueue) { self.queue = queue }
    func cancel() { dispatchPrecondition(condition: .onQueue(queue)); lock.withLock { cancelled = true } }
    func isCancelled() -> Bool { lock.withLock { cancelled } }
}

private actor BonjourStartGate {
    var released = false
    var waiter: CheckedContinuation<Void, Never>?
    func wait() async { if !released { await withCheckedContinuation { waiter = $0 } } }
    func release() { released = true; waiter?.resume(); waiter = nil }
}
