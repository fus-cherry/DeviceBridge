import DeviceBridgeProtocol
import Foundation

/// Owns VM continuity. Public metadata is not app/device proof; only the module's verified binding samples.
public actor IOSVMMetadataChannel {
    public enum Failure: Error, Equatable, Sendable {
        case closed, operationInProgress, invalidMetadata, continuityUnverified, isolateSelectionRequired, unsupportedRuntime, staleSession
    }
    public struct Metadata: Sendable, Equatable {
        public let processID: Int
        public let isolateID: String
    }
    struct MemoryUsage: Sendable {
        let capturedAt: Date
        let heapUsedBytes: Int64?
        let externalBytes: Int64?
    }
    private let transport: any VMServiceRPCTransport
    private let expectedProcessID: Int
    private let selectedIsolateID: String?
    private var continuity: Continuity?
    private var closed = false
    private var reading = false

    public static func connect(hardwareUDID: String, port: UInt16, authenticationCode: String,
                               expectedProcessID: Int, selectedIsolateID: String? = nil,
                               timeout: TimeInterval = 5) async throws -> IOSVMMetadataChannel {
        try await connect(hardwareUDID: hardwareUDID, port: port, authenticationCode: authenticationCode,
            expectedProcessID: expectedProcessID, selectedIsolateID: selectedIsolateID,
            timeout: timeout, socketPath: "/var/run/usbmuxd")
    }

    static func connect(hardwareUDID: String, port: UInt16, authenticationCode: String,
                        expectedProcessID: Int, selectedIsolateID: String?, timeout: TimeInterval,
                        socketPath: String) async throws -> IOSVMMetadataChannel {
        let transport = try await IOSVMHTTPTransport.connect(hardwareUDID: hardwareUDID, port: port,
            authenticationCode: authenticationCode, timeout: timeout, socketPath: socketPath)
        do {
            try Task.checkCancellation()
            return IOSVMMetadataChannel(transport: transport, expectedProcessID: expectedProcessID,
                                        selectedIsolateID: selectedIsolateID)
        } catch { await transport.close(); throw error }
    }

    // Only the native factory (or module-internal boundary tests) transfers ownership here.
    init(transport: any VMServiceRPCTransport, expectedProcessID: Int, selectedIsolateID: String?) {
        self.transport = transport
        self.expectedProcessID = expectedProcessID
        self.selectedIsolateID = selectedIsolateID
    }

    /// Initial qualification reads protocol + two VM snapshots; renewals never sample memory.
    public func readMetadata() async throws -> Metadata {
        guard !closed else { throw Failure.closed }
        guard !reading else { throw Failure.operationInProgress }
        reading = true
        defer { reading = false }
        do {
            try checkActive()
            if let current = continuity {
                let response = try await transport.request(method: "getVM", parameters: [:])
                try checkActive()
                try current.observe(Snapshot(response))
                return current.metadata
            }

            let version = try await transport.request(method: "getVersion", parameters: [:])
            try checkActive()
            guard version["type"] == .string("Version"), version["major"] == .number(4),
                  version["minor"] == .number(16) else { throw Failure.unsupportedRuntime }
            let first = try await transport.request(method: "getVM", parameters: [:])
            try checkActive()
            let candidate = try Continuity(first: Snapshot(first), expectedProcessID: expectedProcessID,
                                           selectedIsolateID: selectedIsolateID)
            let second = try await transport.request(method: "getVM", parameters: [:])
            try checkActive()
            let confirmation = try Snapshot(second)
            if selectedIsolateID == nil, confirmation.isolates.count != 1 {
                throw Failure.isolateSelectionRequired
            }
            try candidate.observe(confirmation)
            // Publication point: both observations belong to this still-active owner.
            continuity = candidate
            return candidate.metadata
        } catch {
            closed = true
            continuity = nil
            await transport.close()
            if Task.isCancelled { throw CancellationError() }
            if let failure = error as? Failure { throw failure }
            throw Failure.continuityUnverified
        }
    }

    public func close() async {
        closed = true
        continuity = nil
        await transport.close()
    }

    /// Module-only: the verified binding remains the admission/publication boundary.
    func readMemoryUsage(store: DeviceSessionStore, session: ConnectionSession) async throws -> MemoryUsage {
        guard !closed else { throw Failure.closed }
        guard !reading else { throw Failure.operationInProgress }
        reading = true
        defer { reading = false }
        do {
            try checkActive()
            guard let current = continuity else { throw Failure.continuityUnverified }
            let before = try await transport.request(method: "getVM", parameters: [:])
            try await checkSamplingSession(store: store, session: session)
            try current.observe(Snapshot(before))
            let usage = try await transport.request(method: "getMemoryUsage", parameters: ["isolateId": .string(current.metadata.isolateID)])
            let receivedAt = Date()
            try await checkSamplingSession(store: store, session: session)
            guard usage["type"] == .string("MemoryUsage") else { throw Failure.invalidMetadata }
            let result = try MemoryUsage(capturedAt: receivedAt, heapUsedBytes: Self.memoryBytes(usage["heapUsage"]),
                                        externalBytes: Self.memoryBytes(usage["externalUsage"]))
            guard result.heapUsedBytes != nil || result.externalBytes != nil else { throw Failure.invalidMetadata }
            let after = try await transport.request(method: "getVM", parameters: [:])
            try await checkSamplingSession(store: store, session: session)
            try current.observe(Snapshot(after))
            continuity = current
            return result
        } catch {
            closed = true
            continuity = nil
            await transport.close()
            if Task.isCancelled { throw CancellationError() }
            throw (error as? Failure) ?? Failure.continuityUnverified
        }
    }

    private func checkSamplingSession(store: DeviceSessionStore, session: ConnectionSession) async throws {
        let current = await store.snapshot()
        try checkActive()
        guard current.session == session, current.selectedDeviceIdentity == session.deviceIdentity,
              session.state == .active else { throw Failure.staleSession }
    }

    private static func memoryBytes(_ value: JSONValue?) throws -> Int64? {
        guard let value else { return nil }
        guard case let .number(number) = value, number.isFinite, number >= 0,
              number.rounded() == number, number <= 9_007_199_254_740_991 else { throw Failure.invalidMetadata }
        return Int64(number)
    }

    private func checkActive() throws {
        try Task.checkCancellation()
        guard !closed else { throw Failure.closed }
    }

    private struct Snapshot {
        let processID: Int
        let isolates: Set<String>

        init(_ vm: [String: JSONValue]) throws {
            guard vm["type"] == .string("VM") else { throw Failure.invalidMetadata }
            guard vm["version"]?.stringValue?.split(separator: " ").first == "3.7.2" else { throw Failure.unsupportedRuntime }
            processID = try Self.integer(vm["pid"])
            _ = try Self.integer(vm["startTime"])
            guard case let .array(values)? = vm["isolates"], !values.isEmpty, values.count <= 256 else { throw Failure.invalidMetadata }
            var ids = Set<String>()
            for value in values {
                guard case let .object(isolate) = value, isolate["type"] == .string("@Isolate"),
                      let id = isolate["id"]?.stringValue, id.hasPrefix("isolates/"),
                      (10...256).contains(id.utf8.count),
                      id.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 47, 95].contains($0) }),
                      ids.insert(id).inserted else { throw Failure.invalidMetadata }
            }
            isolates = ids
        }

        private static func integer(_ value: JSONValue?) throws -> Int {
            guard case let .number(number)? = value, number.isFinite, number > 0,
                  number.rounded() == number, number <= 9_007_199_254_740_991 else { throw Failure.invalidMetadata }
            return Int(number)
        }
    }

    /// Only valid on this channel's single, non-reopening native stream. Dart's startTime
    /// is recomputed using different clocks, so it is validated but is not an identity token.
    private struct Continuity {
        let metadata: Metadata

        init(first: Snapshot, expectedProcessID: Int, selectedIsolateID: String?) throws {
            guard first.processID == expectedProcessID else { throw Failure.continuityUnverified }
            let isolateID: String
            if let selectedIsolateID {
                guard first.isolates.contains(selectedIsolateID) else { throw Failure.continuityUnverified }
                isolateID = selectedIsolateID
            } else {
                guard first.isolates.count == 1, let only = first.isolates.first else { throw Failure.isolateSelectionRequired }
                isolateID = only
            }
            metadata = Metadata(processID: first.processID, isolateID: isolateID)
        }

        func observe(_ next: Snapshot) throws {
            guard next.processID == metadata.processID, next.isolates.contains(metadata.isolateID) else { throw Failure.continuityUnverified }
        }
    }
}
