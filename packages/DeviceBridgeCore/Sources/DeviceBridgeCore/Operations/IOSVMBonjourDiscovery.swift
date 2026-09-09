import Foundation
import dnssd

public struct IOSVMBonjourHint: Sendable {
    public let applicationID: String
    public let candidate: IOSVMCandidate
}

public struct IOSVMBonjourDiscovery: Sendable {
    public enum Failure: Error, Equatable, Sendable { case unavailable, invalidRecord, limitExceeded }
    private let queries: any IOSVMDNSQuerying

    public init() { queries = IOSVMNativeDNSQueries() }
    init(queries: any IOSVMDNSQuerying) { self.queries = queries }

    public func discover(applicationIDs: Set<String>, duration: Duration = .seconds(5)) async throws -> [IOSVMBonjourHint] {
        try Task.checkCancellation()
        guard applicationIDs.count <= 256, duration > .zero, duration <= .seconds(5),
              applicationIDs.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 && !$0.contains("\0") }) else { throw Failure.limitExceeded }
        guard !applicationIDs.isEmpty else { return [] }
        let attempt = IOSVMBonjourAttempt(queries: queries, applicationIDs: applicationIDs)
        let hints = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in attempt.start(duration: duration, continuation: continuation) }
        } onCancel: { attempt.cancel() }
        try Task.checkCancellation()
        return hints
    }

    static func candidate(port: UInt16, txt: Data) throws -> IOSVMCandidate {
        guard port >= 1024, !txt.isEmpty, txt.count <= 4096 else { throw Failure.invalidRecord }
        let bytes = Array(txt)
        var index = 0
        var authentication: String?
        while index < bytes.count {
            let count = Int(bytes[index]); index += 1
            guard index + count <= bytes.count else { throw Failure.invalidRecord }
            let entry = bytes[index..<(index + count)]; index += count
            let separator = entry.firstIndex(of: 61) ?? entry.endIndex
            guard String(bytes: entry[..<separator], encoding: .utf8)?.lowercased() == "authcode" else { continue }
            guard separator != entry.endIndex, authentication == nil,
                  let value = String(bytes: entry[(separator + 1)...], encoding: .utf8),
                  !value.isEmpty, value.utf8.count <= 256,
                  value.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 95, 61].contains($0) }) else { throw Failure.invalidRecord }
            authentication = value
        }
        guard let authentication else { throw Failure.invalidRecord }
        return IOSVMCandidate(port: port, authenticationCode: authentication)
    }
}

struct IOSVMDNSService: Sendable, Hashable {
    let name: String
    let type: String
    let domain: String
    let interface: UInt32
}

enum IOSVMDNSBrowseEvent: Sendable {
    case add(IOSVMDNSService), remove(IOSVMDNSService), failed
}

struct IOSVMDNSResolution: Sendable { let port: UInt16; let txt: Data }

/// All calls, callbacks and cancellation occur on the supplied serial queue. Callbacks are asynchronous.
protocol IOSVMDNSQuery: Sendable { func cancel() }
protocol IOSVMDNSQuerying: Sendable {
    func browse(queue: DispatchQueue, receive: @escaping @Sendable (IOSVMDNSBrowseEvent) -> Void) throws -> any IOSVMDNSQuery
    func resolve(service: IOSVMDNSService, queue: DispatchQueue,
                 receive: @escaping @Sendable (Result<IOSVMDNSResolution, IOSVMBonjourDiscovery.Failure>) -> Void) throws -> any IOSVMDNSQuery
}

struct IOSVMNativeDNSQueries: IOSVMDNSQuerying {
    func browse(queue: DispatchQueue, receive: @escaping @Sendable (IOSVMDNSBrowseEvent) -> Void) throws -> any IOSVMDNSQuery {
        let context = IOSVMDNSCallbacks(browse: receive)
        return try IOSVMNativeDNSQuery(queue: queue, context: context) { reference, pointer in
            DNSServiceBrowse(reference, 0, 0, "_dartVmService._tcp", "local.", iosVMBrowseReply, pointer)
        }
    }
    func resolve(service: IOSVMDNSService, queue: DispatchQueue,
                 receive: @escaping @Sendable (Result<IOSVMDNSResolution, IOSVMBonjourDiscovery.Failure>) -> Void) throws -> any IOSVMDNSQuery {
        let context = IOSVMDNSCallbacks(resolve: receive)
        return try IOSVMNativeDNSQuery(queue: queue, context: context) { reference, pointer in
            DNSServiceResolve(reference, 0, service.interface, service.name, service.type, service.domain, iosVMResolveReply, pointer)
        }
    }
}

/// The serial queue is the only writer and lifetime owner of the attempt, records and native queries.
private final class IOSVMBonjourAttempt: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.debugutility.vm-bonjour")
    private let queries: any IOSVMDNSQuerying
    private let applicationIDs: Set<String>
    private var continuation: CheckedContinuation<[IOSVMBonjourHint], any Error>?
    private var browser: (any IOSVMDNSQuery)?
    private var timer: DispatchWorkItem?
    private var records: [IOSVMDNSService: Record] = [:]
    private var additions = 0
    private var events = 0
    private var closed = false

    private struct Record {
        let applicationID: String
        let resolutionID: UUID
        var query: (any IOSVMDNSQuery)?
        var candidate: IOSVMCandidate?
    }

    init(queries: any IOSVMDNSQuerying, applicationIDs: Set<String>) { self.queries = queries; self.applicationIDs = applicationIDs }

    func start(duration: Duration, continuation: CheckedContinuation<[IOSVMBonjourHint], any Error>) {
        queue.async { [self] in
            guard !closed else { continuation.resume(throwing: CancellationError()); return }
            self.continuation = continuation
            do {
                browser = try queries.browse(queue: queue) { [weak self] event in self?.observe(event) }
                let work = DispatchWorkItem { [weak self] in self?.completeWindow() }
                timer = work
                let parts = duration.components
                let seconds = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
                queue.asyncAfter(deadline: .now() + seconds, execute: work)
            } catch { finish(.failure(IOSVMBonjourDiscovery.Failure.unavailable)) }
        }
    }

    func cancel() { queue.async { [self] in finish(.failure(CancellationError())) } }

    private func observe(_ event: IOSVMDNSBrowseEvent) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !closed else { return }
        events += 1
        guard events <= 512 else { finish(.failure(IOSVMBonjourDiscovery.Failure.limitExceeded)); return }
        switch event {
        case .failed: finish(.failure(IOSVMBonjourDiscovery.Failure.unavailable))
        case let .remove(service): records.removeValue(forKey: service)?.query?.cancel()
        case let .add(service):
            guard records[service] == nil, service.domain.lowercased() == "local.",
                  ["_dartvmservice._tcp", "_dartvmservice._tcp."].contains(service.type.lowercased()),
                  let app = applicationHint(service.name) else { return }
            additions += 1
            guard additions <= 64 else { finish(.failure(IOSVMBonjourDiscovery.Failure.limitExceeded)); return }
            let id = UUID()
            do {
                let query = try queries.resolve(service: service, queue: queue) { [weak self] result in
                    self?.resolved(result, service: service, id: id)
                }
                records[service] = Record(applicationID: app, resolutionID: id, query: query)
            } catch { } // A candidate resolution failure never proves device unavailability.
        }
    }

    private func applicationHint(_ name: String) -> String? {
        guard name.utf8.count <= 1024 else { return nil }
        if applicationIDs.contains(name) { return name }
        let matches = applicationIDs.filter { name.hasPrefix($0 + " ") || name.hasPrefix($0 + ".") }
        return matches.count == 1 ? matches.first : nil
    }

    private func resolved(_ result: Result<IOSVMDNSResolution, IOSVMBonjourDiscovery.Failure>, service: IOSVMDNSService, id: UUID) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !closed, var record = records[service], record.resolutionID == id, let query = record.query else { return }
        query.cancel()
        record.query = nil
        if case let .success(value) = result {
            record.candidate = try? IOSVMBonjourDiscovery.candidate(port: value.port, txt: value.txt)
        }
        records[service] = record
    }

    private func completeWindow() {
        var hints: [IOSVMBonjourHint] = []
        for record in records.values {
            guard let candidate = record.candidate else { continue }
            let repeated = hints.contains { $0.applicationID == record.applicationID && $0.candidate.port == candidate.port
                && $0.candidate.authenticationCode == candidate.authenticationCode }
            if !repeated { hints.append(IOSVMBonjourHint(applicationID: record.applicationID, candidate: candidate)) }
        }
        finish(.success(hints.sorted { $0.applicationID < $1.applicationID }))
    }

    private func finish(_ result: Result<[IOSVMBonjourHint], any Error>) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !closed else { return }
        closed = true
        timer?.cancel(); timer = nil
        browser?.cancel(); browser = nil
        for record in records.values { record.query?.cancel() }
        records.removeAll()
        let waiting = continuation; continuation = nil
        waiting?.resume(with: result)
    }
}

/// This boundary retains copied callback closures while C owns their unretained context pointer.
/// The owning attempt calls every operation and disposal on the same serial dispatch queue.
private final class IOSVMNativeDNSQuery: IOSVMDNSQuery, @unchecked Sendable {
    private let queue: DispatchQueue
    private let context: IOSVMDNSCallbacks
    private var reference: DNSServiceRef?

    init(queue: DispatchQueue, context: IOSVMDNSCallbacks,
         start: (UnsafeMutablePointer<DNSServiceRef?>, UnsafeMutableRawPointer) -> DNSServiceErrorType) throws {
        dispatchPrecondition(condition: .onQueue(queue))
        self.queue = queue; self.context = context
        var reference: DNSServiceRef?
        guard start(&reference, Unmanaged.passUnretained(context).toOpaque()) == kDNSServiceErr_NoError,
              let reference else { throw IOSVMBonjourDiscovery.Failure.unavailable }
        guard DNSServiceSetDispatchQueue(reference, queue) == kDNSServiceErr_NoError else {
            DNSServiceRefDeallocate(reference)
            throw IOSVMBonjourDiscovery.Failure.unavailable
        }
        self.reference = reference
    }

    func cancel() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let reference else { return }
        self.reference = nil
        DNSServiceRefDeallocate(reference)
    }
}

private final class IOSVMDNSCallbacks {
    let browse: (@Sendable (IOSVMDNSBrowseEvent) -> Void)?
    let resolve: (@Sendable (Result<IOSVMDNSResolution, IOSVMBonjourDiscovery.Failure>) -> Void)?
    init(browse: (@Sendable (IOSVMDNSBrowseEvent) -> Void)? = nil,
         resolve: (@Sendable (Result<IOSVMDNSResolution, IOSVMBonjourDiscovery.Failure>) -> Void)? = nil) {
        self.browse = browse; self.resolve = resolve
    }
}

private func iosVMBrowseReply(_ reference: DNSServiceRef?, _ flags: DNSServiceFlags, _ interface: UInt32,
                              _ error: DNSServiceErrorType, _ name: UnsafePointer<CChar>?, _ type: UnsafePointer<CChar>?,
                              _ domain: UnsafePointer<CChar>?, _ pointer: UnsafeMutableRawPointer?) {
    guard let pointer else { return }
    let context = Unmanaged<IOSVMDNSCallbacks>.fromOpaque(pointer).takeUnretainedValue()
    guard error == kDNSServiceErr_NoError, let name = iosVMDNSString(name), let type = iosVMDNSString(type),
          let domain = iosVMDNSString(domain) else { context.browse?(.failed); return }
    let service = IOSVMDNSService(name: name, type: type, domain: domain, interface: interface)
    context.browse?(flags & UInt32(kDNSServiceFlagsAdd) != 0 ? .add(service) : .remove(service))
}

private func iosVMResolveReply(_ reference: DNSServiceRef?, _ flags: DNSServiceFlags, _ interface: UInt32,
                               _ error: DNSServiceErrorType, _ fullName: UnsafePointer<CChar>?, _ host: UnsafePointer<CChar>?,
                               _ port: UInt16, _ length: UInt16, _ bytes: UnsafePointer<UInt8>?, _ pointer: UnsafeMutableRawPointer?) {
    guard let pointer else { return }
    let context = Unmanaged<IOSVMDNSCallbacks>.fromOpaque(pointer).takeUnretainedValue()
    guard error == kDNSServiceErr_NoError, length > 0, length <= 4096, let bytes else {
        context.resolve?(.failure(.invalidRecord)); return
    }
    // Deliberately do not retain or connect to host/fullName. Neither is selected-device proof.
    context.resolve?(.success(IOSVMDNSResolution(port: UInt16(bigEndian: port), txt: Data(bytes: bytes, count: Int(length)))))
}

private func iosVMDNSString(_ pointer: UnsafePointer<CChar>?) -> String? {
    guard let pointer else { return nil }
    let length = strnlen(pointer, 1025)
    guard length <= 1024 else { return nil }
    return String(bytes: UnsafeRawBufferPointer(start: pointer, count: length), encoding: .utf8)
}
