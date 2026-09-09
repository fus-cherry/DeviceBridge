import Foundation
import DeviceBridgeProtocol
import DeviceBridgeSecureChannel

/// Exact-route acquisition is an external boundary; it does not confer application identity.
protocol IOSRunnerEndpointOpening: Sendable {
    func open(process: any IOSRunnerProcessOwning) async throws -> IOSRunnerUSBEndpoint.PinnedEndpoint
    func close() async
}
extension IOSRunnerUSBEndpoint: IOSRunnerEndpointOpening {}

/// One launch owns its endpoint, TLS stream and authenticated context. No UI readiness is
/// published here; IOSRunnerManager and Workspace must recheck their captured generation.
public actor IOSRunnerChannel: IOSRunnerChannelCandidate, HelperRequestSending, IOSRunnerClipboardChannel {
    public enum Failure: Error, Equatable, Sendable { case unavailable, invalidRequest, invalidReply, operationInProgress, cleanupFailed }
    public enum ScreenshotFailure: Error, Equatable, Sendable { case status(HelperResultStatus) }
    public nonisolated var launchID: UUID { launch.id }
    public nonisolated let publicHostCertificateDER: Data
    private let launch: IOSRunnerLaunch
    private let identity: EphemeralTLSIdentity
    private let endpoint: any IOSRunnerEndpointOpening
    private let helperBuild: String
    private let foreground: (any IOSRunnerForegroundActivating)?
    private enum Phase {
        case idle, opening
        case connected(IOSRunnerIdentityHandshake.Session)
        case stopping(IOSRunnerIdentityHandshake.Session)
        case closing(Task<Void, Never>)
        case closed
    }
    private var phase = Phase.idle
    private var invalidationHandler: (@Sendable (UUID) -> Void)?
    private var stream: PinnedTLSFrameStream?
    private var opening: Task<Void, any Error>?
    private var runnerProcess: (any IOSRunnerProcessOwning)?
    private enum RequestStage { case preparing, queued, writing, awaitingReply, receivingScreenshot }
    private struct Response: Sendable {
        let result: HelperResult
        var screenshot: ScreenshotCapturePayload?
    }
    private final class PendingRequest {
        let request: HelperRequest
        let deadline: ContinuousClock.Instant
        let continuation: CheckedContinuation<Response, any Error>
        var stage = RequestStage.queued
        var expiry: Task<Void, Never>?
        var preparation: Task<Void, Never>?
        var screenshotResult: HelperResult?
        var screenshotReceipt: IOSRunnerScreenshotReceipt?
        var discardedScreenshotOffset: Int?
        init(request: HelperRequest, deadline: ContinuousClock.Instant,
             continuation: CheckedContinuation<Response, any Error>) {
            self.request = request; self.deadline = deadline; self.continuation = continuation
        }
    }
    // This actor is the sole request owner and completion publisher. At most one content,
    // one identity and one Stop can be pending; frame writes never overlap.
    private var pending: [UUID: PendingRequest] = [:]
    private var admittedIDs: Set<UUID> = []
    private var writeQueue: [UUID] = []
    private var writer: Task<Void, Never>?
    private var reader: Task<Void, Never>?

    init(launch: IOSRunnerLaunch, identity: EphemeralTLSIdentity, endpoint: any IOSRunnerEndpointOpening,
         helperBuild: String, foreground: (any IOSRunnerForegroundActivating)? = nil) {
        self.launch = launch; self.identity = identity; self.endpoint = endpoint; self.helperBuild = helperBuild
        self.foreground = foreground
        publicHostCertificateDER = identity.certificateDER
    }

    public func open(launch: IOSRunnerLaunch, process: any IOSRunnerProcessOwning) async throws -> any HelperRequestSending {
        try Task.checkCancellation()
        guard case .idle = phase, launch == self.launch else { throw Failure.unavailable }
        phase = .opening
        let work = Task { try await establish(process: process) }
        opening = work
        do {
            try await withTaskCancellationHandler { try await work.value } onCancel: {
                work.cancel()
                Task { await self.close() }
            }
            opening = nil
            try Task.checkCancellation()
            guard case .connected = phase else { throw Failure.unavailable }
            return self
        } catch {
            await close()
            throw Task.isCancelled ? CancellationError() : Failure.unavailable
        }
    }

    public func authenticatedContext() throws -> HelperSessionContext {
        guard case .connected(let session) = phase else { throw Failure.unavailable }
        return HelperSessionContext(sessionNonce: session.sessionNonce,
            helperDeviceID: session.helperDeviceID, helperVersion: session.helperBuild)
    }

    public func authenticatedScreenshotContext() throws -> HelperSessionContext {
        guard case .connected(let session) = phase,
              session.allowedActions.contains(.screenshotCapture) else { throw Failure.unavailable }
        return try authenticatedContext()
    }

    public func authenticatedClipboardContext() throws -> HelperSessionContext {
        guard case .connected(let session) = phase,
              session.allowedActions.contains(.clipboardRead),
              session.allowedActions.contains(.clipboardWrite) else { throw Failure.unavailable }
        return try authenticatedContext()
    }

    public func authenticatedDeviceInformationContext() throws -> HelperSessionContext {
        guard case .connected(let session) = phase, session.allowedActions.contains(.deviceInformation) else {
            throw Failure.unavailable
        }
        return try authenticatedContext()
    }

    /// One binding observer. It must not block or synchronously wait for channel teardown.
    /// Registration after logical invalidation immediately receives this original launch ID.
    public func registerInvalidationHandler(_ handler: @escaping @Sendable (UUID) -> Void) {
        switch phase {
        case .closing, .closed: handler(launch.id)
        default: invalidationHandler = handler
        }
    }

    public func captureScreenshot(_ request: HelperRequest) async throws -> ScreenshotCapturePayload {
        guard request.action == .screenshotCapture else { throw Failure.invalidRequest }
        let response = try await perform(request)
        guard response.result.status == .success else { throw ScreenshotFailure.status(response.result.status) }
        guard let screenshot = response.screenshot else { throw Failure.invalidReply }
        return screenshot
    }

    /// Admit bounded work before suspension. One reader correlates responses, so an identity or
    /// Stop reply cannot be consumed by a clipboard caller waiting for permission on the phone.
    public func send(_ request: HelperRequest) async throws -> HelperResult {
        guard request.action != .screenshotCapture else { throw Failure.invalidRequest }
        return try await perform(request).result
    }

    private func perform(_ request: HelperRequest) async throws -> Response {
        try Task.checkCancellation()
        guard case .connected(let session) = phase else { throw Failure.unavailable }
        try validate(request, session: session)
        guard !admittedIDs.contains(request.requestID), admittedIDs.count < 1024 else { throw Failure.invalidRequest }
        guard !pending.values.contains(where: { sameSlot($0.request.action, request.action) }) else {
            throw Failure.operationInProgress
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(min(30, request.expiresAt.timeIntervalSinceNow)))
        do {
            let result: Response = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                    let entry = PendingRequest(request: request, deadline: deadline, continuation: continuation)
                    pending[request.requestID] = entry
                    admittedIDs.insert(request.requestID)
                    entry.expiry = Task { [weak self] in
                        do {
                            try await Task.sleep(until: deadline, clock: .continuous)
                            await self?.expire(request.requestID)
                        } catch { }
                    }
                    if request.action == .stop {
                        phase = .stopping(session)
                        // These requests never reached the peer. Their obsolete timers must not
                        // shorten an independent Stop deadline or close its acknowledgement.
                        let unsent = pending.values.filter {
                            $0.request.requestID != request.requestID && ($0.stage == .preparing || $0.stage == .queued)
                        }
                        for waiting in unsent {
                            pending.removeValue(forKey: waiting.request.requestID)
                            waiting.expiry?.cancel(); waiting.preparation?.cancel()
                            writeQueue.removeAll { $0 == waiting.request.requestID }
                            waiting.continuation.resume(throwing: Failure.unavailable)
                        }
                        writeQueue.insert(request.requestID, at: 0)
                    } else if foreground != nil, request.action == .clipboardRead || request.action == .clipboardWrite {
                        entry.stage = .preparing
                        entry.preparation = Task { [weak self] in await self?.prepareContent(request.requestID) }
                    } else { writeQueue.append(request.requestID) }
                    startWriter()
                }
            } onCancel: { Task { await self.close() } }
            try Task.checkCancellation()
            _ = try remaining(until: deadline)
            return result
        } catch {
            if Task.isCancelled { await close(); throw CancellationError() }
            throw (error as? Failure) ?? Failure.unavailable
        }
    }

    public func close() async {
        await shutdown(failure: .unavailable)
    }

    private func shutdown(failure: Failure) async {
        switch phase {
        case .closed: return
        case .closing(let cleanup): await cleanup.value; return
        default: break
        }
        opening?.cancel(); opening = nil
        let requests = Array(pending.values)
        pending.removeAll(); writeQueue.removeAll()
        var completionFailure = failure
        for entry in requests {
            entry.expiry?.cancel(); entry.preparation?.cancel()
            do { try entry.screenshotReceipt?.discard() }
            catch { completionFailure = .cleanupFailed }
        }
        runnerProcess = nil
        reader?.cancel(); reader = nil
        writer?.cancel(); writer = nil
        let oldStream = stream; stream = nil
        let route = endpoint
        let cleanup = Task {
            async let tlsClosed: Void? = oldStream?.close()
            await route.close()
            _ = await tlsClosed
        }
        phase = .closing(cleanup)
        // This actor turn publishes logical invalidation before the inherited cleanup task
        // can suspend on endpoint/TLS teardown or pending callers regain their continuations.
        let observer = invalidationHandler
        invalidationHandler = nil
        observer?(launch.id)
        await cleanup.value
        phase = .closed
        for entry in requests { entry.continuation.resume(throwing: completionFailure) }
    }

    private func sameSlot(_ lhs: HelperAction, _ rhs: HelperAction) -> Bool {
        let content: Set<HelperAction> = [.clipboardRead, .clipboardWrite, .screenshotCapture, .deviceInformation]
        return lhs == rhs || (content.contains(lhs) && content.contains(rhs))
    }

    private var liveSession: IOSRunnerIdentityHandshake.Session? {
        switch phase {
        case .connected(let session), .stopping(let session): return session
        default: return nil
        }
    }

    private func expire(_ id: UUID) async {
        guard pending[id] != nil else { return }
        await shutdown(failure: .unavailable)
    }

    private func startWriter() {
        guard writer == nil else { return }
        writer = Task { [weak self] in await self?.writeRequests() }
    }

    /// Foreground activation is a separate public OS boundary. It may return after cancellation;
    /// only this actor can commit that candidate result to the outgoing queue.
    private func prepareContent(_ id: UUID) async {
        guard let entry = pending[id], let foreground, let process = runnerProcess else { return }
        do {
            try requirePreparing(entry)
            guard await process.exitStatus() == nil else { throw Failure.unavailable }
            try requirePreparing(entry)
            let activated: Bool
            do {
                try await foreground.activate(launch: launch, deadline: entry.deadline)
                activated = true
            } catch let failure as IOSRunnerForegroundActivator.Failure
                where failure == .activationFailed || failure == .timedOut {
                activated = false
            }
            try requirePreparing(entry)
            guard await process.exitStatus() == nil else { throw Failure.unavailable }
            try requirePreparing(entry)
            if !activated {
                // This content request never reached the phone. Release only its reservation;
                // the authenticated transport and screenshot/heartbeat remain independently valid.
                // Expiry, cancellation, Stop and a dead runner still take the terminal path above.
                pending.removeValue(forKey: id)
                entry.expiry?.cancel()
                entry.preparation = nil
                entry.continuation.resume(returning: Response(result: HelperResult(requestID: id,
                    status: .actionRequired, completedAt: Date(),
                    error: HelperErrorPayload(code: "clipboard.foreground_required",
                        message: "Keep the managed runner visible to access the clipboard."))))
                return
            }
            entry.preparation = nil
            entry.stage = .queued
            writeQueue.append(id)
            startWriter()
        } catch {
            // Stop/close has already invalidated this work; late activation must not close a
            // Stop acknowledgement or publish a fresh request into an obsolete session.
            guard case .connected = phase, pending[id] === entry else { return }
            await shutdown(failure: .unavailable)
        }
    }

    private func requirePreparing(_ entry: PendingRequest) throws {
        try Task.checkCancellation()
        guard case .connected = phase, pending[entry.request.requestID] === entry,
              entry.stage == .preparing else { throw Failure.unavailable }
        _ = try remaining(until: entry.deadline)
    }

    private func writeRequests() async {
        do {
            while !writeQueue.isEmpty {
                try Task.checkCancellation()
                guard let session = liveSession, let stream else { return }
                let id = writeQueue.removeFirst()
                guard let entry = pending[id] else { continue }
                // Stop preempts content that has not reached the wire; its caller is failed at
                // shutdown. An already-started write is never replayed or claimed undone.
                if case .stopping = phase, entry.request.action != .stop { continue }
                try validate(entry.request, session: session)
                let bytes = try HelperWireCodec().encode(entry.request)
                entry.stage = .writing
                try await stream.writeFrame(bytes, timeout: remaining(until: entry.deadline))
                try Task.checkCancellation()
                guard liveSession != nil else { return }
                if let current = pending[id], current === entry {
                    _ = try remaining(until: entry.deadline)
                    // A fast descriptor may already have committed reception during this write.
                    if current.stage == .writing { current.stage = .awaitingReply }
                }
            }
            writer = nil
        } catch { await shutdown(failure: (error as? Failure) ?? .unavailable) }
    }

    private func startReader(stream: PinnedTLSFrameStream) {
        reader = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let frame = try await stream.readFrame(timeout: 30)
                    guard let channel = self else { await stream.close(); return }
                    if try await !channel.receive(frame) { return }
                }
            } catch { await self?.shutdown(failure: (error as? Failure) ?? .unavailable) }
        }
    }

    private func receive(_ frame: Data) async throws -> Bool {
        try Task.checkCancellation()
        guard let session = liveSession else { return false }
        if IOSRunnerScreenshotWire.isAttachmentFrame(frame) {
            return try receiveScreenshotChunk(frame, session: session)
        }
        let result: HelperResult
        do { result = try HelperWireCodec().decodeResult(frame) }
        catch { throw Failure.invalidReply }
        guard let entry = pending[result.requestID], entry.stage == .writing || entry.stage == .awaitingReply else {
            throw Failure.invalidReply
        }
        _ = try remaining(until: entry.deadline)
        try validate(entry.request, session: session)
        try validate(result, for: entry.request, session: session)
        if entry.request.action == .screenshotCapture, result.status == .success {
            guard let payload = result.payload else { throw Failure.invalidReply }
            if case .stopping = phase {
                // Bind the already-in-flight descriptor, but do not create a new file after Stop.
                entry.discardedScreenshotOffset = 0
            } else {
                entry.screenshotReceipt = try IOSRunnerScreenshotReceipt(requestID: result.requestID,
                    descriptor: .init(payload: payload))
            }
            entry.screenshotResult = result
            entry.stage = .receivingScreenshot
            return true
        }
        if case .stopping = phase, entry.request.action != .stop { return true }
        pending.removeValue(forKey: result.requestID)
        entry.expiry?.cancel()
        if entry.request.action == .stop {
            await shutdown(failure: .unavailable)
            if ContinuousClock.now < entry.deadline { entry.continuation.resume(returning: Response(result: result)) }
            else { entry.continuation.resume(throwing: Failure.unavailable) }
            return false
        }
        entry.continuation.resume(returning: Response(result: result))
        return true
    }

    private func receiveScreenshotChunk(_ frame: Data, session: IOSRunnerIdentityHandshake.Session) throws -> Bool {
        do {
            let chunk = try IOSRunnerScreenshotWire.decodeChunk(frame)
            guard let entry = pending[chunk.requestID], entry.stage == .receivingScreenshot,
                  let result = entry.screenshotResult else { throw Failure.invalidReply }
            try validate(entry.request, session: session)
            _ = try remaining(until: entry.deadline)
            if case .stopping = phase {
                let descriptor = try IOSRunnerScreenshotWire.Descriptor(payload: result.payload ?? [:])
                let offset = entry.discardedScreenshotOffset ?? entry.screenshotReceipt?.nextOffset ?? 0
                guard chunk.offset == offset, chunk.bytes.count <= descriptor.byteLength - offset else { throw Failure.invalidReply }
                entry.discardedScreenshotOffset = offset + chunk.bytes.count
                return true
            }
            guard let receipt = entry.screenshotReceipt else { throw Failure.invalidReply }
            if try receipt.append(chunk) {
                let bytes = try receipt.finish()
                try Task.checkCancellation()
                _ = try remaining(until: entry.deadline)
                try validate(entry.request, session: session)
                pending.removeValue(forKey: chunk.requestID)
                entry.expiry?.cancel()
                entry.continuation.resume(returning: Response(result: result,
                    screenshot: ScreenshotCapturePayload(data: bytes, capturedAt: result.completedAt)))
            }
            return true
        } catch { throw (error as? Failure) ?? Failure.invalidReply }
    }

    private func establish(process: any IOSRunnerProcessOwning) async throws {
        try requireOpening()
        let pinned = try await endpoint.open(process: process)
        try requireOpening()
        let connected = try await PinnedTLSFrameStream.connect(localPort: pinned.port, identity: identity,
            peerCertificateDER: pinned.runnerCertificateDER)
        do { try requireOpening() }
        catch { await connected.close(); throw error }
        stream = connected // Own the acquired stream before the next external suspension.
        let session = try await IOSRunnerIdentityHandshake.openHost(stream: connected, launchID: launch.id,
            helperBuild: helperBuild, requiredActions: [.identity, .stop])
        try requireOpening()
        guard await process.exitStatus() == nil else { throw Failure.unavailable }
        try requireOpening()
        phase = .connected(session)
        runnerProcess = process
        admittedIDs = [session.bootstrapRequestID]
        startReader(stream: connected)
    }

    private func requireOpening() throws {
        try Task.checkCancellation()
        guard case .opening = phase else { throw Failure.unavailable }
    }

    private func validate(_ request: HelperRequest, session: IOSRunnerIdentityHandshake.Session) throws {
        let now = Date()
        guard request.protocolVersion == 1, request.sessionNonce == session.sessionNonce,
              request.helperDeviceID == session.helperDeviceID, session.allowedActions.contains(request.action),
              request.createdAt.timeIntervalSince1970.isFinite, request.expiresAt.timeIntervalSince1970.isFinite,
              abs(request.createdAt.timeIntervalSince(now)) <= 120,
              request.createdAt < request.expiresAt, request.expiresAt > now,
              request.expiresAt.timeIntervalSince(request.createdAt) <= 30 else { throw Failure.invalidRequest }
        switch request.action {
        case .identity, .stop, .clipboardRead, .screenshotCapture, .deviceInformation:
            guard request.payload.isEmpty else { throw Failure.invalidRequest }
        case .clipboardWrite:
            guard let text = request.payload["text"]?.stringValue,
                  text.utf8.count <= HelperWireCodec.maximumClipboardUTF8Bytes,
                  Set(request.payload.keys).isSubset(of: ["text", "sensitive"]),
                  request.payload["sensitive"] == nil || request.payload["sensitive"]?.boolValue != nil else { throw Failure.invalidRequest }
        default: throw Failure.invalidRequest
        }
    }

    private func validate(_ result: HelperResult, for request: HelperRequest,
                          session: IOSRunnerIdentityHandshake.Session) throws {
        guard result.protocolVersion == 1, result.requestID == request.requestID, result.isStructurallyValid,
              result.completedAt.timeIntervalSince1970.isFinite,
              abs(result.completedAt.timeIntervalSinceNow) <= 120 else { throw Failure.invalidReply }
        switch request.action {
        case .identity, .stop:
            let expected: [String: JSONValue] = request.action == .identity ? [
                "helperDeviceId": .string(session.helperDeviceID), "helperVersion": .string(session.helperBuild),
                "protocolVersions": .array([.number(1)]),
            ] : [:]
            guard result.status == .success, result.payload == expected else { throw Failure.invalidReply }
        case .clipboardRead:
            if result.status == .success {
                guard let payload = result.payload, Set(payload.keys) == ["text"],
                      let text = payload["text"]?.stringValue,
                      text.utf8.count <= HelperWireCodec.maximumClipboardUTF8Bytes else { throw Failure.invalidReply }
            }
        case .clipboardWrite:
            if result.status == .success {
                guard result.payload == ["written": .bool(true)] else { throw Failure.invalidReply }
            }
        case .deviceInformation:
            if result.status == .success {
                guard let payload = result.payload else { throw Failure.invalidReply }
                do { _ = try DeviceRuntimeInformation(payload: payload) }
                catch { throw Failure.invalidReply }
            }
        case .screenshotCapture:
            if result.status == .success {
                guard let payload = result.payload else { throw Failure.invalidReply }
                do { _ = try IOSRunnerScreenshotWire.Descriptor(payload: payload) }
                catch { throw Failure.invalidReply }
            }
        default: throw Failure.invalidReply
        }
    }

    private func remaining(until deadline: ContinuousClock.Instant) throws -> TimeInterval {
        let duration = ContinuousClock.now.duration(to: deadline)
        guard duration > .zero else { throw Failure.unavailable }
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    deinit {
        opening?.cancel()
        reader?.cancel(); writer?.cancel()
        // Suspended send calls retain this actor through their post-result deadline check;
        // pending completions are drained by actor-isolated shutdown, never by deinit.
        let oldStream = stream, route = endpoint
        Task { await oldStream?.close(); await route.close() }
    }
}
