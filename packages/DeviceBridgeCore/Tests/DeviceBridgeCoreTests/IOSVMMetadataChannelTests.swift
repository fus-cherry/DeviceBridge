import DeviceBridgeProtocol
import Foundation
import Testing
@testable import DeviceBridgeCore

@Suite("iOS VM metadata continuity on one owned route")
struct IOSVMMetadataChannelTests {
    @Test("usage cannot be requested before metadata qualification")
    func unqualifiedUsage() async throws {
        let rpc = MetadataRPC(starts: [])
        let channel = IOSVMMetadataChannel(transport: rpc, expectedProcessID: 123, selectedIsolateID: nil)
        let session = ConnectionSession(deviceIdentity: try DeviceIdentity(rawValue: "PUBLIC-PHONE", stability: .stable, platform: .iOS),
            generation: 1, transportID: "PUBLIC-ROUTE", state: .active, startedAt: .distantPast)
        await #expect(throws: IOSVMMetadataChannel.Failure.continuityUnverified) {
            try await channel.readMemoryUsage(store: DeviceSessionStore(), session: session)
        }
        #expect(await rpc.methods.isEmpty)
        #expect(await rpc.closed)
    }

    @Test("adjacent millisecond observations keep the same pinned isolate")
    func quantization() async throws {
        let rpc = MetadataRPC(starts: [1000, 1001, 1000, 1001])
        let channel = IOSVMMetadataChannel(transport: rpc, expectedProcessID: 123, selectedIsolateID: nil)
        for _ in 0..<3 {
            let metadata = try await channel.readMetadata()
            #expect(metadata.processID == 123)
            #expect(metadata.isolateID == "isolates/7")
        }
        #expect(await rpc.methods == ["getVersion", "getVM", "getVM", "getVM", "getVM"])
        await channel.close()
        #expect(await rpc.closed)
    }

    @Test("valid clock changes do not replace the owner PID or pinned isolate", arguments: [[1000, 1001, 1002], [1002, 1001, 1000], [1000, 86401000, 500]])
    func clockVariation(_ starts: [Int]) async throws {
        let rpc = MetadataRPC(starts: starts)
        let channel = IOSVMMetadataChannel(transport: rpc, expectedProcessID: 123, selectedIsolateID: nil)
        _ = try await channel.readMetadata()
        #expect(try await channel.readMetadata().isolateID == "isolates/7")
        #expect(await !rpc.closed)
        #expect(await rpc.methods.count == 4)
        await channel.close()
    }

    @Test("foreign PID, replacement isolate and invalid metadata cannot qualify", arguments: ["pid", "isolate", "missingStart", "fractionalStart", "booleanStart", "runtime", "missingIsolates", "duplicateIsolate"])
    func rejectsIdentity(_ variant: String) async throws {
        let rpc = MetadataRPC(starts: [1000, 1000], secondVariant: variant)
        let channel = IOSVMMetadataChannel(transport: rpc, expectedProcessID: 123, selectedIsolateID: nil)
        await #expect(throws: IOSVMMetadataChannel.Failure.self) { try await channel.readMetadata() }
        #expect(await rpc.closed)
        await #expect(throws: IOSVMMetadataChannel.Failure.closed) { try await channel.readMetadata() }
    }

    @Test("multiple isolates require a selection and never silently change that selection")
    func multipleIsolates() async throws {
        let ambiguousRPC = MetadataRPC(starts: [1000, 1000], multipleIsolates: true)
        let ambiguous = IOSVMMetadataChannel(transport: ambiguousRPC, expectedProcessID: 123, selectedIsolateID: nil)
        await #expect(throws: IOSVMMetadataChannel.Failure.isolateSelectionRequired) { try await ambiguous.readMetadata() }
        #expect(await ambiguousRPC.closed)
        let selectedRPC = MetadataRPC(starts: [1000, 1001], multipleIsolates: true)
        let selected = IOSVMMetadataChannel(transport: selectedRPC, expectedProcessID: 123, selectedIsolateID: "isolates/8")
        #expect(try await selected.readMetadata().isolateID == "isolates/8")
        await selected.close()
    }

    @Test("protocol mismatch fails before any VM content RPC")
    func unsupportedProtocol() async throws {
        let rpc = MetadataRPC(starts: [], protocolMinor: 99)
        let channel = IOSVMMetadataChannel(transport: rpc, expectedProcessID: 123, selectedIsolateID: nil)
        await #expect(throws: IOSVMMetadataChannel.Failure.unsupportedRuntime) { try await channel.readMetadata() }
        #expect(await rpc.methods == ["getVersion"])
        #expect(await rpc.closed)
    }

    @Test("automatic selection must remain unambiguous through the initial commit")
    func ambiguityBeforeCommit() async throws {
        let rpc = MetadataRPC(starts: [1000, 1001], secondVariant: "extraIsolate")
        let channel = IOSVMMetadataChannel(transport: rpc, expectedProcessID: 123, selectedIsolateID: nil)
        await #expect(throws: IOSVMMetadataChannel.Failure.isolateSelectionRequired) { try await channel.readMetadata() }
        #expect(await rpc.closed)
    }

    @Test("an isolate appearing after commit does not replace the pinned isolate")
    func additionalIsolateAfterCommit() async throws {
        let rpc = MetadataRPC(starts: [1000, 1001, 1000], secondVariant: "extraIsolate", variantAt: 2)
        let channel = IOSVMMetadataChannel(transport: rpc, expectedProcessID: 123, selectedIsolateID: nil)
        _ = try await channel.readMetadata()
        #expect(try await channel.readMetadata().isolateID == "isolates/7")
        await channel.close()
    }

    @Test("close while awaiting metadata rejects late RPC results")
    func lateResult() async throws {
        let rpc = MetadataRPC(starts: [1000, 1001], holdSecond: true)
        let channel = IOSVMMetadataChannel(transport: rpc, expectedProcessID: 123, selectedIsolateID: nil)
        let read = Task { try await channel.readMetadata() }
        try await rpc.waitUntilHeld()
        await channel.close()
        await rpc.release()
        await #expect(throws: IOSVMMetadataChannel.Failure.closed) { try await read.value }
        await #expect(throws: IOSVMMetadataChannel.Failure.closed) { try await channel.readMetadata() }
    }

    @Test("cancellation does not commit a late initial qualification")
    func cancellation() async throws {
        let rpc = MetadataRPC(starts: [1000, 1001], holdSecond: true)
        let channel = IOSVMMetadataChannel(transport: rpc, expectedProcessID: 123, selectedIsolateID: nil)
        let read = Task { try await channel.readMetadata() }
        try await rpc.waitUntilHeld()
        read.cancel()
        await rpc.release()
        await #expect(throws: CancellationError.self) { try await read.value }
        #expect(await rpc.closed)
    }

    @Test("metadata calls cannot interleave their qualification sequences")
    func singleFlight() async throws {
        let rpc = MetadataRPC(starts: [1000, 1001], holdSecond: true)
        let channel = IOSVMMetadataChannel(transport: rpc, expectedProcessID: 123, selectedIsolateID: nil)
        let first = Task { try await channel.readMetadata() }
        try await rpc.waitUntilHeld()
        await #expect(throws: IOSVMMetadataChannel.Failure.operationInProgress) { try await channel.readMetadata() }
        await rpc.release()
        #expect(try await first.value.processID == 123)
        await channel.close()
    }

    @Test("a PID that does not match the independent expected process never qualifies")
    func expectedPID() async throws {
        let rpc = MetadataRPC(starts: [1000])
        let channel = IOSVMMetadataChannel(transport: rpc, expectedProcessID: 456, selectedIsolateID: nil)
        await #expect(throws: IOSVMMetadataChannel.Failure.continuityUnverified) { try await channel.readMetadata() }
        #expect(await rpc.closed)
        #expect(await rpc.methods == ["getVersion", "getVM"])
    }

    @Test("a committed channel rejects late renewal after close or cancellation", arguments: [false, true])
    func lateRenewal(_ cancel: Bool) async throws {
        let rpc = MetadataRPC(starts: [1000, 1001, 1000], holdSecond: true, holdAt: 2)
        let channel = IOSVMMetadataChannel(transport: rpc, expectedProcessID: 123, selectedIsolateID: nil)
        _ = try await channel.readMetadata()
        let renewal = Task { try await channel.readMetadata() }
        try await rpc.waitUntilHeld()
        if cancel { renewal.cancel() } else { await channel.close() }
        await rpc.release()
        if cancel {
            await #expect(throws: CancellationError.self) { try await renewal.value }
        } else {
            await #expect(throws: IOSVMMetadataChannel.Failure.closed) { try await renewal.value }
        }
        #expect(await rpc.closed)
        await #expect(throws: IOSVMMetadataChannel.Failure.closed) { try await channel.readMetadata() }
    }
}

/// Models only the remote RPC boundary. Real continuity/ownership code is never replaced.
private actor MetadataRPC: VMServiceRPCTransport {
    private let starts: [Int]
    private let secondVariant: String?
    private let multipleIsolates: Bool
    private let protocolMinor: Int
    private let holdSecond: Bool
    private let variantAt: Int
    private let holdAt: Int
    private var vmCalls = 0
    private var held: CheckedContinuation<Void, Never>?
    private(set) var methods: [String] = []
    private(set) var closed = false
    init(starts: [Int], secondVariant: String? = nil, multipleIsolates: Bool = false,
         protocolMinor: Int = 16, holdSecond: Bool = false, variantAt: Int = 1, holdAt: Int = 1) {
        self.starts = starts; self.secondVariant = secondVariant; self.multipleIsolates = multipleIsolates
        self.protocolMinor = protocolMinor; self.holdSecond = holdSecond
        self.variantAt = variantAt
        self.holdAt = holdAt
    }
    func request(method: String, parameters: [String: JSONValue]) async throws -> [String: JSONValue] {
        methods.append(method)
        #expect(parameters.isEmpty)
        if method == "getVersion" { return ["type": .string("Version"), "major": .number(4), "minor": .number(Double(protocolMinor))] }
        #expect(method == "getVM")
        let index = vmCalls; vmCalls += 1
        guard index < starts.count else { throw IOSVMMetadataChannel.Failure.invalidMetadata }
        if holdSecond && index == holdAt { await withCheckedContinuation { held = $0 } }
        var isolates: [JSONValue] = [.object(["type": .string("@Isolate"), "id": .string("isolates/7"), "name": .string("main")])]
        if multipleIsolates { isolates.append(.object(["type": .string("@Isolate"), "id": .string("isolates/8"), "name": .string("worker")])) }
        var vm: [String: JSONValue] = ["type": .string("VM"), "pid": .number(123),
            "startTime": .number(Double(starts[index])), "version": .string("3.7.2 (stable)"),
            "isolates": .array(isolates)]
        if index == variantAt {
            switch secondVariant {
            case "pid": vm["pid"] = .number(456)
            case "isolate": vm["isolates"] = .array([.object(["type": .string("@Isolate"), "id": .string("isolates/9"), "name": .string("main")])])
            case "missingStart": vm["startTime"] = nil
            case "fractionalStart": vm["startTime"] = .number(1000.5)
            case "booleanStart": vm["startTime"] = .bool(true)
            case "runtime": vm["version"] = .string("9.0.0 (future)")
            case "missingIsolates": vm["isolates"] = nil
            case "duplicateIsolate": vm["isolates"] = .array([isolates[0], isolates[0]])
            case "extraIsolate": vm["isolates"] = .array(isolates + [.object(["type": .string("@Isolate"), "id": .string("isolates/8"), "name": .string("worker")])])
            default: break
            }
        }
        return vm
    }
    func close() { closed = true } // Intentionally does not suppress already pending replies.
    func release() { held?.resume(); held = nil }
    func waitUntilHeld() async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while held == nil {
            guard ContinuousClock.now < deadline else { throw IOSVMMetadataChannel.Failure.invalidMetadata }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}
