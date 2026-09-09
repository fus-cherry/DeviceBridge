import DeviceBridgeProtocol
import Foundation
import Testing
@testable import DeviceBridgeCore

@Suite("Selected iPhone VM binding admission")
struct IOSFlutterVMDiscoveryTests {
    @Test("production discovery rejects the first hint then hands off one metadata-only owner")
    func multipleCandidates() async throws {
        let setup = try await BindingSetup.make()
        let rejected = BindingRPC(variant: "foreignPID", hold: "", gate: setup.gate)
        let candidates = BindingHints(ports: [12344, 12345])
        let connector = CandidateConnector(rejected: rejected, accepted: setup.rpc)
        let issuer = IOSFlutterVMDiscovery(sessionStore: setup.store, processes: setup.processes,
            connector: connector, candidates: candidates)
        let binding = try await issuer.discover(session: setup.session, applicationID: "dev.example.app")
        #expect(await candidates.scopes == [Set(["dev.example.app"])])
        #expect(await connector.ports == [12344, 12345])
        #expect(await rejected.closed)
        #expect(await !setup.rpc.closed)
        #expect(await setup.rpc.methods.allSatisfy { ["getVersion", "getVM"].contains($0) })
        #expect(binding.session == setup.session)
        await binding.close()
        #expect(await setup.rpc.closed)
    }

    @Test("production discovery has a bounded app-scoped candidate set", arguments: ["empty", "overflow", "foreign", "missingApp"])
    func rejectedDiscovery(_ variant: String) async throws {
        let setup = try await BindingSetup.make(variant: variant)
        let ports: [UInt16] = variant == "empty" ? [] : (variant == "overflow" ? [11001, 11002, 11003, 11004, 11005] : [12345])
        let candidates = BindingHints(ports: ports, applicationID: variant == "foreign" ? "dev.other.app" : "dev.example.app")
        let issuer = IOSFlutterVMDiscovery(sessionStore: setup.store, processes: setup.processes,
            connector: setup.connector, candidates: candidates)
        await #expect(throws: IOSVMBindingError.self) {
            try await issuer.discover(session: setup.session, applicationID: "dev.example.app")
        }
        #expect(await setup.connector.connectedSession == nil)
        if variant == "missingApp" { #expect(await candidates.scopes.isEmpty) }
    }

    @Test("late Bonjour results cannot connect after cancellation or selection replacement", arguments: [false, true])
    func lateDiscovery(_ cancel: Bool) async throws {
        let setup = try await BindingSetup.make()
        let candidates = BindingHints(ports: [12345], gate: setup.gate)
        let issuer = IOSFlutterVMDiscovery(sessionStore: setup.store, processes: setup.processes,
            connector: setup.connector, candidates: candidates)
        let attempt = Task { try await issuer.discover(session: setup.session, applicationID: "dev.example.app") }
        try await setup.gate.waitUntilHeld()
        if cancel { attempt.cancel() } else { _ = try await setup.store.select(setup.session.deviceIdentity) }
        await setup.gate.release()
        if cancel { await #expect(throws: CancellationError.self) { try await attempt.value } }
        else { await #expect(throws: IOSVMBindingError.staleSession) { try await attempt.value } }
        #expect(await setup.connector.connectedSession == nil)
    }

    @Test("terminal candidate failures never fall through to another hint", arguments: [
        IOSVMBindingError.cleanupFailed, .staleSession, .unverifiedApplication,
    ])
    func terminalDiscoveryFailure(_ failure: IOSVMBindingError) async throws {
        let setup = try await BindingSetup.make()
        let connector = CandidateConnector(rejected: setup.rpc, accepted: setup.rpc, failure: failure)
        let issuer = IOSFlutterVMDiscovery(sessionStore: setup.store, processes: setup.processes,
            connector: connector, candidates: BindingHints(ports: [12344, 12345]))
        await #expect(throws: failure) { try await issuer.discover(session: setup.session, applicationID: "dev.example.app") }
        #expect(await connector.ports == [12344])
    }

    @Test("independent provider failures after a candidate never retry another hint", arguments: [
        IOSApplicationProcessProvider.Failure.wrongDevice, .unsupportedRoute, .invalidMetadata, .unavailable,
    ])
    func terminalProviderFailure(_ failure: IOSApplicationProcessProvider.Failure) async throws {
        let setup = try await BindingSetup.make()
        await setup.processes.failOnThirdLoad(failure)
        let connector = CandidateConnector(rejected: setup.rpc, accepted: setup.rpc)
        let issuer = IOSFlutterVMDiscovery(sessionStore: setup.store, processes: setup.processes,
            connector: connector, candidates: BindingHints(ports: [12344, 12345]))
        await #expect(throws: IOSVMBindingError.self) {
            try await issuer.discover(session: setup.session, applicationID: "dev.example.app")
        }
        #expect(await connector.ports == [12344])
        #expect(await setup.rpc.closed)
    }

    @Test("discovery preserves cleanup failure even when cancellation crosses its outer error mapping")
    func discoveryCleanupPrecedesCancellation() async throws {
        let setup = try await BindingSetup.make(hold: "sampleProcess")
        await setup.processes.failOnThirdLoad(.cleanupFailed)
        let connector = CandidateConnector(rejected: setup.rpc, accepted: setup.rpc)
        let issuer = IOSFlutterVMDiscovery(sessionStore: setup.store, processes: setup.processes,
            connector: connector, candidates: BindingHints(ports: [12344, 12345]))
        let attempt = Task { try await issuer.discover(session: setup.session, applicationID: "dev.example.app") }
        try await setup.gate.waitUntilHeld()
        attempt.cancel()
        await setup.gate.release()
        await #expect(throws: IOSVMBindingError.cleanupFailed) { try await attempt.value }
        #expect(await setup.rpc.closed)
        #expect(await connector.ports == [12344])
    }

    @Test("invalidating the first candidate closes it and prevents the second connection", arguments: [false, true])
    func staleCandidateFallback(_ cancel: Bool) async throws {
        let setup = try await BindingSetup.make()
        let rejected = BindingRPC(variant: "valid", hold: "metadata", gate: setup.gate)
        let connector = CandidateConnector(rejected: rejected, accepted: setup.rpc)
        let issuer = IOSFlutterVMDiscovery(sessionStore: setup.store, processes: setup.processes,
            connector: connector, candidates: BindingHints(ports: [12344, 12345]))
        let attempt = Task { try await issuer.discover(session: setup.session, applicationID: "dev.example.app") }
        try await setup.gate.waitUntilHeld()
        if cancel { attempt.cancel() } else { _ = try await setup.store.select(setup.session.deviceIdentity) }
        await setup.gate.release()
        if cancel { await #expect(throws: CancellationError.self) { try await attempt.value } }
        else { await #expect(throws: IOSVMBindingError.staleSession) { try await attempt.value } }
        #expect(await rejected.closed)
        #expect(await connector.ports == [12344])
        #expect(await setup.rpc.methods.isEmpty)
    }

    @Test("independent app correlation and current session issue a metadata-only owned binding")
    func verifiedBinding() async throws {
        let setup = try await BindingSetup.make()
        let binding = try await setup.verify()
        #expect(binding.session == setup.session)
        #expect(binding.target.applicationID == "dev.example.app")
        #expect(binding.target.processID == 123)
        #expect(binding.target.processStartIdentity == nil)
        #expect(binding.isolateID == "isolates/7")
        try await binding.renew()
        #expect(await setup.rpc.methods.allSatisfy { ["getVersion", "getVM"].contains($0) })
        #expect(await setup.processes.loads == 3)
        #expect(await setup.connector.connectedSession == setup.session)
        #expect(await setup.connector.expectedPID == 123)
        await binding.close()
        #expect(await setup.rpc.closed)
        await #expect(throws: IOSVMBindingError.closed) { try await binding.renew() }
    }

    @Test("another phone with the same PID cannot qualify the selected phone", arguments: ["session", "inventory", "app"])
    func wrongDevice(_ stage: String) async throws {
        let setup = try await BindingSetup.make(variant: stage)
        await #expect(throws: IOSVMBindingError.self) { try await setup.verify() }
        #expect(await setup.connector.connectedSession == nil)
    }

    @Test("missing app, foreign VM PID or changing app path/PID rejects attribution", arguments: ["missingApp", "foreignPID", "changedPID", "changedPath"])
    func changedApplication(_ variant: String) async throws {
        let setup = try await BindingSetup.make(variant: variant)
        await #expect(throws: IOSVMBindingError.self) { try await setup.verify() }
        if variant != "missingApp" { #expect(await setup.rpc.closed) }
    }

    @Test("selection generation changes and cancellation reject a late qualification", arguments: ["processBefore", "connect", "metadata", "processAfter", "finalMetadata"])
    func staleQualification(_ boundary: String) async throws {
        for cancel in [false, true] {
            let setup = try await BindingSetup.make(hold: boundary)
            let verification = Task { try await setup.verify() }
            try await setup.gate.waitUntilHeld()
            if cancel { verification.cancel() }
            else { _ = try await setup.store.select(setup.session.deviceIdentity) }
            await setup.gate.release()
            if cancel { await #expect(throws: CancellationError.self) { try await verification.value } }
            else { await #expect(throws: IOSVMBindingError.staleSession) { try await verification.value } }
            if boundary != "processBefore" { #expect(await setup.rpc.closed) }
        }
    }

    @Test("binding renewal becomes terminal after disconnect or a changed process", arguments: [false, true])
    func invalidatedRenewal(_ disconnect: Bool) async throws {
        let setup = try await BindingSetup.make()
        let binding = try await setup.verify()
        if disconnect { await setup.store.disconnect() }
        else { await setup.processes.changePID() }
        await #expect(throws: IOSVMBindingError.self) { try await binding.renew() }
        #expect(await setup.rpc.closed)
        await #expect(throws: IOSVMBindingError.closed) { try await binding.renew() }
    }

    @Test("equal numeric VM metadata on a new route owner cannot reuse binding identity")
    func distinctOwners() async throws {
        let first = try await BindingSetup.make()
        let second = try await BindingSetup.make()
        let old = try await first.verify()
        await old.close()
        let replacement = try await second.verify()
        #expect(old.id != replacement.id)
        #expect(old.target.processID == replacement.target.processID)
        await #expect(throws: IOSVMBindingError.closed) { try await old.renew() }
        try await replacement.renew()
        await replacement.close()
    }

    @Test("closing or cancelling a binding rejects delayed renewal across each external boundary", arguments: ["renewProcess", "renewMetadata"])
    func lateRenewal(_ boundary: String) async throws {
        for cancel in [false, true] {
            let setup = try await BindingSetup.make(hold: boundary)
            let binding = try await setup.verify()
            let renewal = Task { try await binding.renew() }
            try await setup.gate.waitUntilHeld()
            await #expect(throws: IOSVMBindingError.operationInProgress) { try await binding.renew() }
            await #expect(throws: IOSVMBindingError.operationInProgress) { try await binding.readMemory() }
            if cancel { renewal.cancel() } else { await binding.close() }
            await setup.gate.release()
            if cancel { await #expect(throws: CancellationError.self) { try await renewal.value } }
            else { await #expect(throws: IOSVMBindingError.closed) { try await renewal.value } }
            #expect(await setup.rpc.closed)
            await #expect(throws: IOSVMBindingError.closed) { try await binding.renew() }
            #expect(await setup.rpc.methods.count == (boundary == "renewProcess" ? 4 : 5))
        }
    }

    @Test("external errors stay redacted and cleanup failure survives cancellation")
    func safeFailure() async throws {
        for cleanup in [false, true] {
            let setup = try await BindingSetup.make(variant: cleanup ? "cleanupFailure" : "externalFailure", hold: "processAfter")
            let verification = Task { try await setup.verify() }
            try await setup.gate.waitUntilHeld()
            if cleanup { verification.cancel() }
            await setup.gate.release()
            await #expect(throws: cleanup ? IOSVMBindingError.cleanupFailed : .unavailable) { try await verification.value }
            #expect(await setup.rpc.closed)
        }
    }

    @Test("candidate formatting never emits authentication")
    func redactedCandidate() {
        let candidate = IOSVMCandidate(port: 12345, authenticationCode: "private-auth-canary=")
        #expect(!String(describing: candidate).contains("private-auth-canary"))
        #expect(!String(reflecting: candidate).contains("private-auth-canary"))
    }

    @Test("explicit memory read stays on the pinned isolate and never fabricates OS memory", arguments: ["usage", "missingExternal", "missingHeap"])
    func boundMemory(_ variant: String) async throws {
        let setup = try await BindingSetup.make(variant: variant)
        let binding = try await setup.verify()
        let before = Date()
        let sample = try await binding.readMemory()
        #expect(sample.deviceIdentity == setup.session.deviceIdentity)
        #expect(sample.applicationID == "dev.example.app")
        #expect(sample.processID == 123)
        #expect(sample.processStartIdentity == nil)
        #expect(sample.heapUsedBytes == (variant == "missingHeap" ? nil : 1024))
        #expect(sample.externalBytes == (variant == "missingExternal" ? nil : 0))
        #expect(sample.rssBytes == nil && sample.pssBytes == nil)
        #expect(sample.capturedAt >= before && sample.capturedAt <= Date())
        #expect(await setup.rpc.methods == ["getVersion", "getVM", "getVM", "getVM", "getVM", "getMemoryUsage", "getVM", "getVM"])
        await binding.close()
    }

    @Test("memory sampler accepts only its committed target and transport", arguments: ["valid", "transport", "target", "closed"])
    func bindingSampler(_ variant: String) async throws {
        let setup = try await BindingSetup.make()
        let binding = try await setup.verify()
        let other = TargetApplication(deviceIdentity: setup.session.deviceIdentity, applicationID: "dev.other.app",
            displayName: "Other", processID: 123, processStartIdentity: nil, debuggable: true, state: .running)
        if variant == "closed" { await binding.close() }
        let result = await binding.sample(target: variant == "target" ? other : binding.target,
            transportID: variant == "transport" ? "OTHER-ROUTE" : setup.session.transportID)
        if variant == "valid" {
            #expect(result.sample?.heapUsedBytes == 1024)
        } else {
            guard case .invalidated = result else { Issue.record("Invalid binding must terminally stop the monitor"); return }
            #expect(await setup.rpc.closed)
            #expect(await !setup.rpc.methods.contains("getMemoryUsage"))
        }
        await binding.close()
    }

    @Test("unusable metrics and continuity changes discard the sample and close its binding", arguments: [
        "missingBoth", "negativeUsage", "fractionalUsage", "booleanUsage", "hugeUsage", "wrongUsageType", "pidDuringUsage", "isolateDuringUsage", "changedAfterSample",
    ])
    func rejectsMemory(_ variant: String) async throws {
        let setup = try await BindingSetup.make(variant: variant)
        let binding = try await setup.verify()
        await #expect(throws: IOSVMBindingError.self) { try await binding.readMemory() }
        #expect(await setup.rpc.closed)
        await #expect(throws: IOSVMBindingError.closed) { try await binding.readMemory() }
    }

    @Test("clock variation during sampling does not invalidate an unchanged native owner")
    func clockVariationDuringUsage() async throws {
        let setup = try await BindingSetup.make(variant: "clockVariationDuringUsage")
        let binding = try await setup.verify()
        #expect(try await binding.readMemory().heapUsedBytes == 1024)
        try await binding.renew()
        #expect(try await binding.readMemory().heapUsedBytes == 1024)
        #expect(await !setup.rpc.closed)
        await binding.close()
    }

    @Test("late memory cannot publish after cancellation, close or session replacement", arguments: ["sampleBeforeMetadata", "sampleUsage", "sampleProcess", "sampleFinalMetadata"])
    func lateMemory(_ boundary: String) async throws {
        for action in ["cancel", "close", "switch"] {
            let setup = try await BindingSetup.make(hold: boundary)
            let binding = try await setup.verify()
            let sample = Task { try await binding.readMemory() }
            try await setup.gate.waitUntilHeld()
            await #expect(throws: IOSVMBindingError.operationInProgress) { try await binding.readMemory() }
            await #expect(throws: IOSVMBindingError.operationInProgress) { try await binding.renew() }
            if action == "cancel" { sample.cancel() }
            else if action == "close" { await binding.close() }
            else { _ = try await setup.store.select(setup.session.deviceIdentity) }
            await setup.gate.release()
            if action == "cancel" { await #expect(throws: CancellationError.self) { try await sample.value } }
            else { await #expect(throws: action == "close" ? IOSVMBindingError.closed : .staleSession) { try await sample.value } }
            #expect(await setup.rpc.closed)
            if boundary == "sampleBeforeMetadata" { #expect(await !setup.rpc.methods.contains("getMemoryUsage")) }
            await #expect(throws: IOSVMBindingError.closed) { try await binding.readMemory() }
        }
    }
}

private struct BindingSetup: Sendable {
    let store: DeviceSessionStore
    let session: ConnectionSession
    let processes: BindingProcesses
    let rpc: BindingRPC
    let connector: BindingConnector
    let gate: BindingGate
    let issuer: IOSFlutterVMDiscovery

    static func make(variant: String = "valid", hold: String = "") async throws -> Self {
        let store = DeviceSessionStore()
        let identity = try DeviceIdentity(rawValue: "PUBLIC-SELECTED", stability: .stable, platform: .iOS)
        let route = try TransportCandidate(id: "11111111-1111-1111-1111-111111111111", identity: identity,
            kind: .usb, source: .coreDevice, status: .available, observedAt: .distantPast)
        await store.replaceInventory([DeviceRecord(identity: identity, name: "Test Phone", authorization: .authorized,
            candidates: [route], preferredTransportID: route.id)])
        let selected = try #require(await store.select(identity).session)
        let session = variant == "session" ? ConnectionSession(deviceIdentity: try DeviceIdentity(rawValue: "PUBLIC-OTHER", stability: .stable, platform: .iOS),
            generation: selected.generation, transportID: selected.transportID, state: .active, startedAt: selected.startedAt) : selected
        let gate = BindingGate()
        let processes = BindingProcesses(variant: variant, hold: hold, gate: gate)
        let rpc = BindingRPC(variant: variant, hold: hold, gate: gate)
        let connector = BindingConnector(rpc: rpc, hold: hold, gate: gate)
        return Self(store: store, session: session, processes: processes, rpc: rpc, connector: connector, gate: gate,
            issuer: IOSFlutterVMDiscovery(sessionStore: store, processes: processes, connector: connector))
    }

    func verify() async throws -> IOSVerifiedVMBinding {
        try await issuer.verify(candidate: IOSVMCandidate(port: 12345, authenticationCode: "private-auth-canary="),
            session: session, applicationID: "dev.example.app")
    }
}

/// Slow external device inventory and USB connection boundaries; session and continuity stay real.
private actor BindingProcesses: IOSApplicationProcessProviding {
    let variant: String
    let hold: String
    let gate: BindingGate
    private(set) var loads = 0
    private var changedPID = false
    private var thirdLoadFailure: IOSApplicationProcessProvider.Failure?
    init(variant: String, hold: String, gate: BindingGate) { self.variant = variant; self.hold = hold; self.gate = gate }
    func changePID() { changedPID = true }
    func failOnThirdLoad(_ failure: IOSApplicationProcessProvider.Failure) { thirdLoadFailure = failure }
    func load(session: ConnectionSession) async throws -> IOSApplicationProcessProvider.Inventory {
        loads += 1
        if (hold == "processBefore" && loads == 1) || (hold == "processAfter" && loads == 2)
            || (["renewProcess", "sampleProcess"].contains(hold) && loads == 3) { await gate.hold() }
        if loads == 3, let thirdLoadFailure { throw thirdLoadFailure }
        if loads == 2 && variant == "cleanupFailure" { throw IOSApplicationProcessProvider.Failure.cleanupFailed }
        if loads == 2 && variant == "externalFailure" { throw NSError(domain: "private-auth-canary", code: 1) }
        let other = try DeviceIdentity(rawValue: "PUBLIC-OTHER", stability: .stable, platform: .iOS)
        let captured = variant == "inventory" ? ConnectionSession(deviceIdentity: other, generation: session.generation,
            transportID: session.transportID, state: .active, startedAt: session.startedAt) : session
        let target = TargetApplication(deviceIdentity: variant == "app" ? other : session.deviceIdentity,
            applicationID: "dev.example.app", displayName: "Example",
            processID: changedPID || (variant == "changedPID" && loads > 1) || (variant == "changedAfterSample" && loads > 2) ? 456 : 123,
            processStartIdentity: nil, debuggable: true, state: .running)
        let directory = variant == "changedPath" && loads > 1 ? "/private/apps/DEF/Example.app" : "/private/apps/ABC/Example.app"
        let app = IOSApplicationProcessProvider.Application(target: target, installationURL: URL(fileURLWithPath: directory),
            executableURL: URL(fileURLWithPath: directory + "/Example"))
        return IOSApplicationProcessProvider.Inventory(session: captured, applications: variant == "missingApp" ? [] : [app])
    }
}

private actor BindingConnector: IOSVMChannelConnecting {
    let rpc: BindingRPC
    let hold: String
    let gate: BindingGate
    private(set) var connectedSession: ConnectionSession?
    private(set) var expectedPID: Int?
    init(rpc: BindingRPC, hold: String, gate: BindingGate) { self.rpc = rpc; self.hold = hold; self.gate = gate }
    func connect(candidate: IOSVMCandidate, session: ConnectionSession, processID: Int) async throws -> IOSVMMetadataChannel {
        #expect(candidate.port == 12345)
        #expect(candidate.authenticationCode == "private-auth-canary=")
        connectedSession = session; expectedPID = processID
        if hold == "connect" { await gate.hold() }
        return IOSVMMetadataChannel(transport: rpc, expectedProcessID: processID, selectedIsolateID: nil)
    }
}

private actor BindingRPC: VMServiceRPCTransport {
    let variant: String
    let hold: String
    let gate: BindingGate
    private(set) var methods: [String] = []
    private(set) var closed = false
    init(variant: String, hold: String, gate: BindingGate) { self.variant = variant; self.hold = hold; self.gate = gate }
    func request(method: String, parameters: [String: JSONValue]) async throws -> [String: JSONValue] {
        methods.append(method)
        if method == "getMemoryUsage" { #expect(parameters == ["isolateId": .string("isolates/7")]) }
        else { #expect(parameters.isEmpty) }
        if hold == "metadata" && methods.count == 3 { await gate.hold() }
        if hold == "finalMetadata" && methods.count == 4 { await gate.hold() }
        if hold == "renewMetadata" && methods.count == 5 { await gate.hold() }
        if hold == "sampleUsage" && method == "getMemoryUsage" { await gate.hold() }
        if hold == "sampleBeforeMetadata" && methods.count == 5 { await gate.hold() }
        if hold == "sampleFinalMetadata" && methods.count == 8 { await gate.hold() }
        if method == "getVersion" { return ["type": .string("Version"), "major": .number(4), "minor": .number(16)] }
        if method == "getMemoryUsage" {
            var usage: [String: JSONValue] = ["type": .string("MemoryUsage"), "heapUsage": .number(1024), "externalUsage": .number(0), "heapCapacity": .number(2048)]
            switch variant {
            case "missingExternal": usage["externalUsage"] = nil
            case "missingHeap": usage["heapUsage"] = nil
            case "missingBoth": usage["heapUsage"] = nil; usage["externalUsage"] = nil
            case "negativeUsage": usage["heapUsage"] = .number(-1)
            case "fractionalUsage": usage["heapUsage"] = .number(1.5)
            case "booleanUsage": usage["heapUsage"] = .bool(true)
            case "hugeUsage": usage["heapUsage"] = .number(1e30)
            case "wrongUsageType": usage["type"] = .string("Sentinel")
            default: break
            }
            return usage
        }
        #expect(method == "getVM")
        let sampled = methods.contains("getMemoryUsage")
        return ["type": .string("VM"), "pid": .number(variant == "foreignPID" || (sampled && variant == "pidDuringUsage") ? 456 : 123),
            "startTime": .number(sampled && variant == "clockVariationDuringUsage" ? 1002 : 1000),
            "version": .string("3.7.2 (stable)"), "isolates": .array([.object(["type": .string("@Isolate"),
                "id": .string(sampled && variant == "isolateDuringUsage" ? "isolates/8" : "isolates/7")])])]
    }
    func close() { closed = true }
}

private actor BindingGate {
    var waiter: CheckedContinuation<Void, Never>?
    func hold() async { await withCheckedContinuation { waiter = $0 } }
    func release() { waiter?.resume(); waiter = nil }
    func waitUntilHeld() async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while waiter == nil {
            guard ContinuousClock.now < deadline else { throw IOSVMBindingError.unavailable }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}

private actor BindingHints: IOSVMCandidateDiscovering {
    let ports: [UInt16]
    let applicationID: String
    let gate: BindingGate?
    private(set) var scopes: [Set<String>] = []
    init(ports: [UInt16], applicationID: String = "dev.example.app", gate: BindingGate? = nil) {
        self.ports = ports; self.applicationID = applicationID; self.gate = gate
    }
    func discover(applicationIDs: Set<String>, duration: Duration) async throws -> [IOSVMBonjourHint] {
        scopes.append(applicationIDs)
        #expect(duration > .zero && duration <= .seconds(5))
        await gate?.hold()
        return ports.map { IOSVMBonjourHint(applicationID: applicationID,
            candidate: IOSVMCandidate(port: $0, authenticationCode: "private-auth-canary=")) }
    }
}

private actor CandidateConnector: IOSVMChannelConnecting {
    let rejected: BindingRPC
    let accepted: BindingRPC
    let failure: IOSVMBindingError?
    private(set) var ports: [UInt16] = []
    init(rejected: BindingRPC, accepted: BindingRPC, failure: IOSVMBindingError? = nil) {
        self.rejected = rejected; self.accepted = accepted; self.failure = failure
    }
    func connect(candidate: IOSVMCandidate, session: ConnectionSession, processID: Int) async throws -> IOSVMMetadataChannel {
        ports.append(candidate.port)
        if let failure { throw failure }
        return IOSVMMetadataChannel(transport: candidate.port == 12344 ? rejected : accepted,
            expectedProcessID: processID, selectedIsolateID: nil)
    }
}
