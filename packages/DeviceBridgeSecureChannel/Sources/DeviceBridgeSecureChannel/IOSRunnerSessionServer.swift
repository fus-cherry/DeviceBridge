import Foundation
import DeviceBridgeProtocol

/// The platform adapter owns clipboard access and must check cancellation before side effects.
/// A handler may outlive cancellation; the session never joins it or publishes a late result.
/// Cancellation callbacks must be non-blocking: Task.cancel() invokes them synchronously.
public protocol IOSRunnerClipboardHandling: Sendable {
    func handle(_ request: HelperRequest) async -> HelperResult
}

/// Capture stays on the phone. The session validates metadata and sends binary chunks only
/// for the same admitted request; this value never enters logs or launch artifacts.
public struct IOSRunnerScreenshotResult: Sendable {
    public let result: HelperResult
    public let pngData: Data?
    public init(result: HelperResult, pngData: Data? = nil) {
        self.result = result; self.pngData = pngData
    }
}

public protocol IOSRunnerScreenshotHandling: Sendable {
    func capture(_ request: HelperRequest) async -> IOSRunnerScreenshotResult
}

/// The caller supplies a mutually pinned stream and owns listener/launch teardown. Content
/// actions are advertised only with their corresponding installed platform handler.
public enum IOSRunnerSessionServer {
    public static let helperBuild = "devicebridge-ios-runner-v1"
    public enum Exit: Sendable, Equatable { case stopped, leaseExpired, lifetimeExpired }
    public enum Failure: Error, Sendable, Equatable {
        case invalidConfiguration, rejected, replay, requestLimitReached, connectionClosed, cancelled
    }

    /// The caller's absolute maximum deadline includes queueing and bootstrap; it is never
    /// re-anchored at entry. An elapsed deadline exits normally. A future deadline must be
    /// within 24 hours; leaseDuration must be positive and at most 30 seconds.
    /// Close means logical invalidation and NW.cancel submission, not graceful physical shutdown.
    public static func run(stream: PinnedTLSFrameStream, launchID: UUID, maximumDeadline: ContinuousClock.Instant,
                           leaseDuration: Duration = .seconds(30),
                           clipboardHandler: (any IOSRunnerClipboardHandling)? = nil,
                           screenshotHandler: (any IOSRunnerScreenshotHandling)? = nil) async throws -> Exit {
        let started = ContinuousClock.now
        guard maximumDeadline > started else {
            await stream.close()
            return .lifetimeExpired
        }
        guard maximumDeadline <= started.advanced(by: .seconds(86_400)),
              leaseDuration > .zero, leaseDuration <= .seconds(30) else {
            await stream.close()
            throw Failure.invalidConfiguration
        }
        // This task alone owns admission, deadlines, the replay ledger and every result write.
        var deadlines = IOSRunnerSessionDeadlines(now: started, maximumDeadline: maximumDeadline, leaseDuration: leaseDuration)
        // One pending frame, one result, one expiry, plus a cancelled expiry already queued.
        // No producer reads ahead or queues another clipboard operation.
        let inbox = AsyncStream<SessionEvent>.makeStream(bufferingPolicy: .bufferingOldest(4))
        var reader: Task<Void, Never>?
        var content: PendingContent?
        defer {
            inbox.continuation.finish()
            reader?.cancel()
            content?.cancel()
        }
        do {
            try Task.checkCancellation()
            var actions: Set<HelperAction> = [.identity, .stop]
            if clipboardHandler != nil { actions.formUnion([.clipboardRead, .clipboardWrite]) }
            if screenshotHandler != nil { actions.insert(.screenshotCapture) }
            let session = try await IOSRunnerIdentityHandshake.acceptRunner(stream: stream, launchID: launchID,
                helperBuild: helperBuild, allowedActions: actions, timeout: deadlines.timeout(at: .now))
            try Task.checkCancellation()
            try deadlines.renew(at: .now)
            var seen: Set<UUID> = [session.bootstrapRequestID]
            let codec = HelperWireCodec()
            var events = inbox.stream.makeAsyncIterator()
            while true {
                if reader == nil {
                    let readDeadlines = deadlines
                    reader = Task {
                        do {
                            let timeout = try readDeadlines.timeout(at: .now)
                            enqueue(.frame(try await stream.readFrame(timeout: timeout)), into: inbox.continuation)
                        }
                        catch { enqueue(.readFailed(error), into: inbox.continuation) }
                    }
                }
                let event = await events.next()
                try Task.checkCancellation()
                _ = try deadlines.timeout(at: .now)
                if let content, ContinuousClock.now >= content.deadline { throw Failure.rejected }
                guard let event else { throw Failure.connectionClosed }
                let request: HelperRequest
                let reply: HelperResult
                switch event {
                case .readFailed(let error): throw error
                case .screenshotChunk(let id):
                    guard var pending = content, pending.request.requestID == id,
                          let png = pending.attachment else { continue }
                    try validate(pending.request, session: session, now: Date())
                    let bytes = Data(png.dropFirst(pending.attachmentOffset).prefix(IOSRunnerScreenshotWire.maximumChunkBytes))
                    let frame = try IOSRunnerScreenshotWire.encodeChunk(requestID: id,
                        offset: pending.attachmentOffset, bytes: bytes)
                    try Task.checkCancellation()
                    try await stream.writeFrame(frame, timeout: writeTimeout(for: pending.request,
                        content: pending, deadlines: deadlines))
                    try Task.checkCancellation()
                    _ = try writeTimeout(for: pending.request, content: pending, deadlines: deadlines)
                    pending.attachmentOffset += bytes.count
                    if pending.attachmentOffset == png.count {
                        pending.cancel(); content = nil
                    } else {
                        content = pending
                        // Yield one bounded write at a time. An already queued metadata/Stop
                        // frame is processed before this next chunk, by the same sole owner.
                        enqueue(.screenshotChunk(id), into: inbox.continuation)
                    }
                    continue
                case .contentExpired(let id):
                    if content?.request.requestID == id { throw Failure.rejected }
                    continue
                case .contentResult(let id, let result, let png):
                    guard let pending = content, pending.request.requestID == id else { continue }
                    guard ContinuousClock.now < pending.deadline else { throw Failure.rejected }
                    request = pending.request
                    try validate(request, session: session, now: Date())
                    try validate(result, for: request, admittedAt: pending.admittedAt, now: Date())
                    if request.action == .screenshotCapture, result.status == .success {
                        guard let png, let payload = result.payload else { throw Failure.rejected }
                        try IOSRunnerScreenshotWire.validate(png, descriptor: .init(payload: payload))
                        content?.attachment = png
                    } else { guard png == nil else { throw Failure.rejected } }
                    reply = result
                case .frame(let frame):
                    reader = nil
                    request = try codec.decodeRequest(frame)
                    try validate(request, session: session, now: Date())
                    guard !seen.contains(request.requestID) else { throw Failure.replay }
                    // Record IDs at admission, including in-flight content; never evict them.
                    guard seen.count < 1024 else { throw Failure.requestLimitReached }
                    seen.insert(request.requestID)
                    // Stop invalidates platform work at admission, before acknowledgement or
                    // cleanup can suspend. Keep the deadline for the bounded Stop reply.
                    if request.action == .stop { content?.operation.cancel() }
                    if request.action == .clipboardRead || request.action == .clipboardWrite || request.action == .screenshotCapture {
                        try Task.checkCancellation()
                        guard content == nil else { throw Failure.rejected }
                        let admittedAt = Date()
                        let deadline = ContinuousClock.now.advanced(by: .seconds(min(30, request.expiresAt.timeIntervalSince(admittedAt))))
                        let dispatchDeadline = min(deadline, deadlines.lease, deadlines.maximumDeadline)
                        let continuation = inbox.continuation
                        let operation = Task {
                            // Scheduling the adapter must not bypass the admission deadline.
                            guard !Task.isCancelled, ContinuousClock.now < dispatchDeadline,
                                  Date() < request.expiresAt else { return }
                            let response: IOSRunnerScreenshotResult
                            if request.action == .screenshotCapture, let screenshotHandler {
                                response = await screenshotHandler.capture(request)
                            } else if let clipboardHandler {
                                response = IOSRunnerScreenshotResult(result: await clipboardHandler.handle(request))
                            } else { return }
                            guard !Task.isCancelled else { return }
                            enqueue(.contentResult(request.requestID, response.result, response.pngData), into: continuation)
                        }
                        let expiry = Task {
                            do {
                                try await Task.sleep(until: deadline, clock: .continuous)
                                try Task.checkCancellation()
                                enqueue(.contentExpired(request.requestID), into: continuation)
                            } catch { /* Cancellation only invalidates this request's timer. */ }
                        }
                        content = PendingContent(request: request, admittedAt: admittedAt, deadline: deadline,
                            operation: operation, expiry: expiry)
                        continue
                    }
                    let payload: [String: JSONValue] = request.action == .identity ? [
                        "helperDeviceId": .string(session.helperDeviceID),
                        "helperVersion": .string(helperBuild), "protocolVersions": .array([.number(1)])
                    ] : [:]
                    reply = HelperResult(requestID: request.requestID, status: .success, completedAt: Date(), payload: payload)
                }
                // Encoding up to 1 MiB of escaped text consumes the same absolute budget.
                let encodedReply = try codec.encode(reply)
                try Task.checkCancellation()
                try await stream.writeFrame(encodedReply, timeout: writeTimeout(for: request, content: content, deadlines: deadlines))
                // No post-await success or lease renewal may outlive the old deadline/request.
                try Task.checkCancellation()
                _ = try deadlines.timeout(at: .now)
                try validate(request, session: session, now: Date())
                if let content, ContinuousClock.now >= content.deadline { throw Failure.rejected }
                if request.action == .stop {
                    await stream.close()
                    return .stopped
                }
                if request.action == .identity { try deadlines.renew(at: .now) }
                else if request.action == .screenshotCapture, reply.status == .success {
                    enqueue(.screenshotChunk(request.requestID), into: inbox.continuation)
                }
                else {
                    guard let pending = content, ContinuousClock.now < pending.deadline else { throw Failure.rejected }
                    pending.cancel()
                    content = nil
                }
            }
        } catch {
            // A cooperative adapter must see cancellation before transport cleanup yields.
            content?.cancel()
            let expired = deadlines.expired(at: .now)
            await stream.close()
            if Task.isCancelled { throw Failure.cancelled }
            if let expired { return expired }
            if let failure = error as? Failure { throw failure }
            if let failure = error as? PinnedTLSFrameStream.Failure,
               failure == .closed || failure == .connectionFailed { throw Failure.connectionClosed }
            throw Failure.rejected
        }
    }

    private static func validate(_ request: HelperRequest, session: IOSRunnerIdentityHandshake.Session, now: Date) throws {
        guard request.protocolVersion == 1, request.sessionNonce == session.sessionNonce,
              request.helperDeviceID == session.helperDeviceID,
              session.allowedActions.contains(request.action),
              request.createdAt.timeIntervalSince1970.isFinite, request.expiresAt.timeIntervalSince1970.isFinite,
              abs(request.createdAt.timeIntervalSince(now)) <= 120,
              request.createdAt < request.expiresAt, request.expiresAt > now,
              request.expiresAt.timeIntervalSince(request.createdAt) <= 30 else { throw Failure.rejected }
        switch request.action {
        case .identity, .stop, .clipboardRead, .screenshotCapture:
            guard request.payload.isEmpty else { throw Failure.rejected }
        case .clipboardWrite:
            guard let text = request.payload["text"]?.stringValue,
                  text.utf8.count <= HelperWireCodec.maximumClipboardUTF8Bytes,
                  Set(request.payload.keys).isSubset(of: ["text", "sensitive"]),
                  request.payload["sensitive"] == nil || request.payload["sensitive"]?.boolValue != nil else { throw Failure.rejected }
        default: throw Failure.rejected
        }
    }

    private static func validate(_ result: HelperResult, for request: HelperRequest, admittedAt: Date, now: Date) throws {
        // Local admission is authoritative for freshness; the host clock can be ahead by the
        // accepted skew. Preserve the wire format's whole-second timestamp precision.
        let earliestCompletion = Date(timeIntervalSince1970: floor(admittedAt.timeIntervalSince1970))
        guard result.protocolVersion == 1, result.requestID == request.requestID, result.isStructurallyValid,
              result.completedAt.timeIntervalSince1970.isFinite,
              result.completedAt >= earliestCompletion, result.completedAt < request.expiresAt,
              result.completedAt <= now else { throw Failure.rejected }
        guard result.status == .success else { return }
        if request.action == .clipboardRead {
            guard let payload = result.payload, Set(payload.keys) == ["text"],
                  let text = payload["text"]?.stringValue,
                  text.utf8.count <= HelperWireCodec.maximumClipboardUTF8Bytes else { throw Failure.rejected }
        } else if request.action == .screenshotCapture {
            guard let payload = result.payload else { throw Failure.rejected }
            _ = try IOSRunnerScreenshotWire.Descriptor(payload: payload)
        } else {
            guard result.payload == ["written": .bool(true)] else { throw Failure.rejected }
        }
    }

    private enum SessionEvent: Sendable {
        case frame(Data)
        case readFailed(any Error)
        case contentResult(UUID, HelperResult, Data?)
        case contentExpired(UUID)
        case screenshotChunk(UUID)
    }

    private struct PendingContent {
        let request: HelperRequest
        let admittedAt: Date
        let deadline: ContinuousClock.Instant
        let operation: Task<Void, Never>
        let expiry: Task<Void, Never>
        var attachment: Data?
        var attachmentOffset = 0
        func cancel() { operation.cancel(); expiry.cancel() }
    }

    private static func writeTimeout(for request: HelperRequest, content: PendingContent?,
                                     deadlines: IOSRunnerSessionDeadlines) throws -> TimeInterval {
        var timeout = min(try deadlines.timeout(at: .now), request.expiresAt.timeIntervalSinceNow)
        if let content {
            let remaining = ContinuousClock.now.duration(to: content.deadline)
            timeout = min(timeout, Double(remaining.components.seconds) + Double(remaining.components.attoseconds) / 1e18)
        }
        guard timeout > 0 else { throw Failure.rejected }
        return timeout
    }

    private static func enqueue(_ event: SessionEvent, into inbox: AsyncStream<SessionEvent>.Continuation) {
        // A violated producer bound terminates the session instead of silently losing an event.
        if case .dropped = inbox.yield(event) { inbox.finish() }
    }
}

/// One run task owns this value. A delayed reply must not revive an already expired lease.
struct IOSRunnerSessionDeadlines {
    let maximumDeadline: ContinuousClock.Instant
    private(set) var lease: ContinuousClock.Instant
    let leaseDuration: Duration

    init(now: ContinuousClock.Instant, maximumDeadline: ContinuousClock.Instant, leaseDuration: Duration) {
        self.maximumDeadline = maximumDeadline
        lease = now.advanced(by: leaseDuration)
        self.leaseDuration = leaseDuration
    }

    func expired(at now: ContinuousClock.Instant) -> IOSRunnerSessionServer.Exit? {
        if now >= maximumDeadline { return .lifetimeExpired }
        if now >= lease { return .leaseExpired }
        return nil
    }

    mutating func renew(at now: ContinuousClock.Instant) throws {
        _ = try timeout(at: now)
        lease = now.advanced(by: leaseDuration)
    }

    func timeout(at now: ContinuousClock.Instant) throws -> TimeInterval {
        guard expired(at: now) == nil else { throw IOSRunnerSessionServer.Failure.rejected }
        let duration = now.duration(to: min(maximumDeadline, lease))
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        return min(30, seconds)
    }
}
