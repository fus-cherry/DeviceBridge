import Foundation
import Testing
@testable import DeviceBridgeCore

@Suite("Production connection maintenance")
struct ConnectionMaintenanceTests {
    @Test("normal cadence is five seconds")
    func normalCadence() async throws {
        let fixture = try await Fixture()
        #expect(await fixture.maintenance.nextDelay == .seconds(5))
    }

    @Test("selection invalidates late discovery, endpoint lookup and connect", arguments: ["discover", "endpoints", "connect"])
    func lateExternalResult(stage: String) async throws {
        let fixture = try await Fixture()
        await fixture.transport.setHealthy(false)
        _ = await fixture.maintenance.tick()
        _ = await fixture.maintenance.tick()
        let gate = MaintenanceGate()
        await fixture.transport.setExternalGate(gate, stage: stage)
        let recovering = Task { await fixture.maintenance.tick() }
        await gate.waitUntilEntered()
        let other = try fixture.otherDevice()
        await fixture.store.replaceInventory([other])
        _ = try await fixture.store.select(other.identity)
        let calls = await fixture.transport.externalCalls
        await gate.release()
        _ = await recovering.value
        #expect(await fixture.transport.externalCalls == calls)
        #expect(await fixture.store.snapshot().session?.deviceIdentity == other.identity)
        let token = try await fixture.store.beginOperation(.clipboardRead)
        await fixture.store.finishOperation(token)
    }

    @Test("two failed bound probes invalidate work before any recovery")
    func invalidatesBeforeRecovery() async throws {
        let fixture = try await Fixture()
        await fixture.transport.setHealthy(false)
        let first = await fixture.maintenance.tick()
        #expect(first.health == .suspect)
        #expect(await fixture.store.snapshot().session?.state == .active)
        let second = await fixture.maintenance.tick()
        #expect(second.health == .reconnecting)
        #expect(await fixture.store.snapshot().session?.state == .disconnected)
        #expect(second.session.generation > fixture.session.generation)
        #expect(await fixture.transport.connects.isEmpty)
    }

    @Test("an active operation defers the heartbeat and duplicate ticks are single flight")
    func admission() async throws {
        let fixture = try await Fixture()
        let token = try await fixture.store.beginOperation(.fileReceive)
        _ = await fixture.maintenance.tick()
        #expect(await fixture.transport.probes.isEmpty)
        await fixture.store.finishOperation(token)
        let gate = MaintenanceGate()
        await fixture.transport.setGate(gate)
        let first = Task { await fixture.maintenance.tick() }
        await gate.waitUntilEntered()
        _ = await fixture.maintenance.tick()
        #expect(await fixture.transport.probes.count == 1)
        do {
            _ = try await fixture.store.beginOperation(.clipboardRead)
            Issue.record("A probe reservation must exclude a simultaneous content command")
        } catch {}
        await gate.release()
        _ = await first.value
        let next = try await fixture.store.beginOperation(.clipboardRead)
        await fixture.store.finishOperation(next)
    }

    @Test("verified recovery preserves identity, rejects old results, and gates content until rebind")
    func recoveryCommit() async throws {
        let fixture = try await Fixture()
        let old = try await fixture.store.beginOperation(.screenshot)
        await fixture.store.finishOperation(old)
        await fixture.transport.setHealthy(false)
        _ = await fixture.maintenance.tick()
        _ = await fixture.maintenance.tick()
        let candidate = try fixture.candidate(id: "22", kind: .wifi)
        await fixture.transport.setCandidates([candidate], verified: ["22"])
        let recovered = await fixture.maintenance.tick()
        #expect(recovered.health == .recovered)
        #expect(recovered.session.deviceIdentity == fixture.device.identity)
        #expect(recovered.session.transportID == "22")
        #expect(recovered.session.state == .selecting)
        #expect(await !fixture.store.canPublish(old))
        do {
            _ = try await fixture.store.beginOperation(.clipboardRead)
            Issue.record("Old providers must not run on the recovered session")
        } catch {}
        #expect(await fixture.maintenance.resumeAfterRebinding())
        let next = try await fixture.store.beginOperation(.clipboardRead)
        #expect(next.transportID == "22")
        await fixture.store.finishOperation(next)
    }

    @Test("matching names and endpoints cannot bypass helper identity verification")
    func wrongIdentity() async throws {
        let fixture = try await Fixture()
        await fixture.transport.setHealthy(false)
        _ = await fixture.maintenance.tick()
        _ = await fixture.maintenance.tick()
        await fixture.transport.setCandidates([try fixture.candidate(id: "wrong", kind: .wifi)], verified: [])
        let update = await fixture.maintenance.tick()
        #expect(update.health == .reconnecting)
        #expect(update.session.transportID == fixture.session.transportID)
        #expect(await fixture.store.snapshot().session?.state == .disconnected)
    }

    @Test("a healthy verified USB route replaces Wi-Fi only between operations")
    func usbPreference() async throws {
        let fixture = try await Fixture()
        await fixture.transport.setCandidates([try fixture.candidate(id: "usb", kind: .usb)], verified: ["usb"])
        let token = try await fixture.store.beginOperation(.fileSend)
        _ = await fixture.maintenance.tick()
        #expect(await fixture.store.canPublish(token))
        #expect(await fixture.transport.verified.isEmpty)
        await fixture.store.finishOperation(token)
        let update = await fixture.maintenance.tick()
        #expect(update.health == .recovered)
        #expect(update.session.transportID == "usb")
        #expect(await fixture.transport.connects.isEmpty)
    }

    @Test("late recovery after selecting another device cannot commit")
    func selectionInvalidation() async throws {
        let fixture = try await Fixture()
        await fixture.transport.setHealthy(false)
        _ = await fixture.maintenance.tick()
        _ = await fixture.maintenance.tick()
        let gate = MaintenanceGate()
        await fixture.transport.setVerificationGate(gate)
        await fixture.transport.setCandidates([try fixture.candidate(id: "22", kind: .wifi)], verified: ["22"])
        let recovering = Task { await fixture.maintenance.tick() }
        await gate.waitUntilEntered()
        let other = try fixture.otherDevice()
        await fixture.store.replaceInventory([other])
        _ = try await fixture.store.select(other.identity)
        await gate.release()
        _ = await recovering.value
        #expect(await fixture.store.snapshot().session?.deviceIdentity == other.identity)
        #expect(await fixture.store.snapshot().session?.transportID == "other")
    }

    @Test("stop while probing suppresses late failures and releases admission")
    func stopDuringProbe() async throws {
        let fixture = try await Fixture()
        let gate = MaintenanceGate()
        await fixture.transport.setGate(gate)
        await fixture.transport.setHealthy(false)
        let probing = Task { await fixture.maintenance.tick() }
        await gate.waitUntilEntered()
        await fixture.maintenance.stop()
        await gate.release()
        #expect(await probing.value.health == .stopped)
        #expect(await fixture.maintenance.tick().health == .stopped)
        #expect(await fixture.transport.probes.count == 1)
    }

    @Test("retry budget is finite and metadata discovery never grants readiness")
    func boundedRetries() async throws {
        let fixture = try await Fixture()
        await fixture.transport.setHealthy(false)
        _ = await fixture.maintenance.tick()
        _ = await fixture.maintenance.tick()
        #expect(await fixture.maintenance.nextDelay == .seconds(1))
        for expected in [2, 4, 8] {
            _ = await fixture.maintenance.tick()
            #expect(await fixture.maintenance.nextDelay == .seconds(expected))
        }
        for _ in 0..<5 { _ = await fixture.maintenance.tick() }
        #expect(await fixture.maintenance.snapshot.health == .actionRequired)
        let attempts = await fixture.transport.connects.count
        _ = await fixture.maintenance.tick()
        #expect(await fixture.transport.connects.count == attempts)
    }

    private struct Fixture {
        let store = DeviceSessionStore()
        let transport = MaintenanceTransportFixture()
        let device: DeviceRecord
        let session: ConnectionSession
        let maintenance: ConnectionMaintenance

        init() async throws {
            let identity = try DeviceIdentity(rawValue: "selected", stability: .provisional, platform: .android)
            let candidate = try TransportCandidate(id: "11", identity: identity, kind: .wifi, source: .adb,
                status: .available, observedAt: Date(), endpoint: "192.168.1.2:40000")
            device = DeviceRecord(identity: identity, name: "Test phone", authorization: .authorized,
                candidates: [candidate], preferredTransportID: candidate.id)
            await store.replaceInventory([device])
            session = try #require(await store.select(identity).session)
            maintenance = ConnectionMaintenance(store: store, transport: transport, device: device, session: session)
            #expect(await maintenance.activate())
        }

        func candidate(id: String, kind: TransportKind) throws -> TransportCandidate {
            try TransportCandidate(id: id,
                identity: DeviceIdentity(rawValue: "candidate-\(id)", stability: .provisional, platform: .android),
                kind: kind, source: .adb, status: .candidate, observedAt: Date(),
                endpoint: kind == .wifi ? "192.168.1.2:41000" : nil)
        }

        func otherDevice() throws -> DeviceRecord {
            let candidate = try candidate(id: "other", kind: .usb)
            return DeviceRecord(identity: candidate.identity, name: "Other", authorization: .authorized,
                candidates: [candidate], preferredTransportID: candidate.id)
        }
    }
}

private actor MaintenanceTransportFixture: ConnectionMaintenanceTransport {
    private(set) var probes: [String] = []
    private(set) var connects: [String] = []
    private(set) var verified: [String] = []
    private var healthy = true
    private var candidates: [TransportCandidate] = []
    private var verifiedIDs = Set<String>()
    private var gate: MaintenanceGate?
    private var verificationGate: MaintenanceGate?
    private var externalGate: MaintenanceGate?
    private var externalStage = ""
    private(set) var externalCalls: [String] = []
    func setExternalGate(_ gate: MaintenanceGate, stage: String) {
        externalGate = gate; externalStage = stage
    }
    private func external(_ stage: String) async {
        externalCalls.append(stage)
        if stage == externalStage { await externalGate?.enter() }
    }
    func setHealthy(_ value: Bool) { healthy = value }
    func setGate(_ value: MaintenanceGate) { gate = value }
    func setVerificationGate(_ value: MaintenanceGate) { verificationGate = value }
    func setCandidates(_ values: [TransportCandidate], verified: Set<String>) {
        candidates = values; verifiedIDs = verified
    }
    func probe(_ candidate: TransportCandidate) async throws -> Bool {
        probes.append(candidate.id)
        await gate?.enter()
        return healthy
    }
    func discover() async throws -> [TransportCandidate] {
        await external("discover")
        return candidates
    }
    func recoveryEndpoints(for candidate: TransportCandidate) async throws -> [String] {
        await external("endpoints")
        return candidate.endpoint.map { [$0] } ?? []
    }
    func connect(endpoint: String) async throws {
        connects.append(endpoint)
        await external("connect")
    }
    func verifyIdentity(_ candidate: TransportCandidate) async throws -> Bool {
        verified.append(candidate.id)
        await verificationGate?.enter()
        return verifiedIDs.contains(candidate.id)
    }
}

private actor MaintenanceGate {
    private var entered = false
    private var released = false
    private var entryWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    func enter() async {
        entered = true; entryWaiter?.resume(); entryWaiter = nil
        if !released { await withCheckedContinuation { releaseWaiter = $0 } }
    }
    func waitUntilEntered() async {
        if !entered { await withCheckedContinuation { entryWaiter = $0 } }
    }
    func release() { released = true; releaseWaiter?.resume(); releaseWaiter = nil }
}
