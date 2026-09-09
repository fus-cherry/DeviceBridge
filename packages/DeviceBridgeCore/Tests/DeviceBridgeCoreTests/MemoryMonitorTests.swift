import Foundation
import Testing
@testable import DeviceBridgeCore

@Suite("Memory monitor orchestration")
struct MemoryMonitorTests {
    @Test("stop discards a suspended provider result without restoring state")
    func stopInFlight() async throws {
        let fixture = try await MemoryFixture.make()
        let sampler = SuspendingMemorySampler()
        let monitor = MemoryMonitor(store: fixture.store, sampler: sampler)
        let pending = Task { await monitor.sampleOnce(target: fixture.target) }
        while !(await sampler.hasRequest) { await Task.yield() }
        await monitor.stop()
        await sampler.resume(sample: fixture.sample(value: 1))
        #expect(await pending.value == .stale)
        #expect(await monitor.samples.isEmpty)
        #expect(await monitor.target == nil)
        #expect(await monitor.latestEvent == nil)
    }

    @Test("terminal binding invalidation clears history and does not retry a closed owner")
    func invalidationIsTerminal() async throws {
        let fixture = try await MemoryFixture.make()
        let failure = OperationFailure(code: .disconnected, safeMessage: "Verified iOS VM connection ended. Discover again before monitoring.")
        let sampler = OutcomeMemorySampler(outcomes: [.sample(fixture.sample(value: 1)), .invalidated(failure)])
        let events = MemoryEventRecorder()
        let sleeper = RecordingMemorySleeper()
        let monitor = MemoryMonitor(store: fixture.store, sampler: sampler, sleeper: sleeper)
        _ = await monitor.sampleOnce(target: fixture.target)
        await monitor.start(target: fixture.target) { await events.record($0) }
        let deadline = ContinuousClock.now + .seconds(2)
        while await events.values.isEmpty {
            guard ContinuousClock.now < deadline else { throw IOSVMBindingError.unavailable }
            await Task.yield()
        }
        #expect(await events.values == [.invalidated(failure)])
        #expect(await monitor.samples.isEmpty)
        #expect(await monitor.target == nil)
        #expect(await sleeper.durations.isEmpty)
        #expect(await sampler.callCount == 2)
    }

    @Test("ordinary Android provider failure remains non-terminal and preserves the trend")
    func transientFailurePreservesTrend() async throws {
        let fixture = try await MemoryFixture.make()
        let failure = OperationFailure(code: .disconnected, safeMessage: "Temporary failure")
        let sampler = OutcomeMemorySampler(outcomes: [.sample(fixture.sample(value: 1)), .failure(failure), .sample(fixture.sample(value: 2))])
        let monitor = MemoryMonitor(store: fixture.store, sampler: sampler)
        _ = await monitor.sampleOnce(target: fixture.target)
        #expect(await monitor.sampleOnce(target: fixture.target) == .failure(failure))
        #expect(await monitor.samples.count == 1)
        #expect(await monitor.target == fixture.target)
        _ = await monitor.sampleOnce(target: fixture.target)
        #expect(await monitor.samples.map(\.pssBytes) == [1, 2])
    }
    @Test("connection maintenance yields sampling without reporting a disconnection")
    func maintenanceAdmission() async throws {
        let fixture = try await MemoryFixture.make()
        let sampler = SequenceMemorySampler(samples: [fixture.sample(value: 1)])
        let monitor = MemoryMonitor(store: fixture.store, sampler: sampler)
        let session = try #require(await fixture.store.snapshot().session)
        let owner = UUID()
        #expect(await fixture.store.registerMaintenance(owner: owner, session: session))
        #expect(await fixture.store.reserveConnectionProbe(owner: owner, session: session))
        #expect(await monitor.sampleOnce(target: fixture.target) == .busy)
        #expect(await sampler.callCount == 0)
        await fixture.store.releaseConnectionProbe(owner: owner)
        #expect(await monitor.sampleOnce(target: fixture.target).sample?.pssBytes == 1)
    }

    @Test("sampling is single flight while a provider call is suspended")
    func singleFlight() async throws {
        let fixture = try await MemoryFixture.make()
        let sampler = SuspendingMemorySampler()
        let monitor = MemoryMonitor(store: fixture.store, sampler: sampler)

        let first = Task { await monitor.sampleOnce(target: fixture.target) }
        while !(await sampler.hasRequest) { await Task.yield() }
        let second = await monitor.sampleOnce(target: fixture.target)
        await sampler.resume(sample: fixture.sample(value: 1))

        #expect(second == .busy)
        #expect(await first.value.sample?.pssBytes == 1)
        #expect(await sampler.callCount == 1)
    }

    @Test("trend retains only the newest bounded samples")
    func boundedTrend() async throws {
        let fixture = try await MemoryFixture.make()
        let sampler = SequenceMemorySampler(samples: (1...5).map { fixture.sample(value: Int64($0)) })
        let monitor = MemoryMonitor(store: fixture.store, sampler: sampler, maximumSamples: 3)

        for _ in 0..<5 { _ = await monitor.sampleOnce(target: fixture.target) }
        let samples = await monitor.samples

        #expect(samples.map(\.pssBytes) == [3, 4, 5])
    }

    @Test("automatic loop schedules the next sample within the three-second cadence")
    func cadence() async throws {
        let fixture = try await MemoryFixture.make()
        let sampler = SequenceMemorySampler(samples: [fixture.sample(value: 1)])
        let sleeper = RecordingMemorySleeper()
        let monitor = MemoryMonitor(store: fixture.store, sampler: sampler, sleeper: sleeper)

        await monitor.start(target: fixture.target)
        while (await sleeper.durations).isEmpty { await Task.yield() }
        await monitor.stop()

        let duration = try #require(await sleeper.durations.first)
        #expect(duration >= .zero && duration <= .seconds(3))
        #expect(await sleeper.durations.count == 1)
        #expect(await sampler.callCount == 1)
    }

    @Test("provider and publication time consume the cadence instead of adding to it")
    func cadenceIncludesWork() async throws {
        let fixture = try await MemoryFixture.make()
        let sampler = SequenceMemorySampler(samples: [fixture.sample(value: 1)], delay: .milliseconds(120))
        let sleeper = RecordingMemorySleeper()
        let monitor = MemoryMonitor(store: fixture.store, sampler: sampler,
            cadence: .seconds(3), sleeper: sleeper)
        await monitor.start(target: fixture.target) { _ in
            try? await Task.sleep(for: .milliseconds(120))
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while await sleeper.durations.isEmpty {
            try #require(ContinuousClock.now < deadline)
            await Task.yield()
        }
        await monitor.stop()

        let duration = try #require(await sleeper.durations.first)
        // Each controlled delay is at least 120 ms; allow 40 ms of slack, never a full extra 3 s.
        #expect(duration >= .zero && duration <= .milliseconds(2800))
        #expect(await sleeper.durations.count == 1)
        #expect(await sampler.callCount == 1)
    }

    @Test("default cadence keeps updates within three seconds when a later request takes longer")
    func defaultCadenceAllowsLatencyVariation() async throws {
        let fixture = try await MemoryFixture.make()
        let sampler = SequenceMemorySampler(samples: [fixture.sample(value: 1), fixture.sample(value: 2)],
            delay: .milliseconds(200), firstDelay: .zero)
        let events = MemoryEventRecorder()
        let monitor = MemoryMonitor(store: fixture.store, sampler: sampler)
        await monitor.start(target: fixture.target) { await events.record($0) }
        let deadline = ContinuousClock.now + .seconds(6)
        while await events.values.count < 2 {
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(10))
        }
        await monitor.stop()

        let receivedAt = await events.receivedAt
        try #require(receivedAt.count == 2)
        #expect(receivedAt[0].duration(to: receivedAt[1]) <= .seconds(3))
        #expect(await events.values.compactMap(\.sample).map(\.pssBytes) == [1, 2])
    }

    @Test("an overrun yields without another full delay or a negative sleep")
    func cadenceOverrun() async throws {
        let fixture = try await MemoryFixture.make()
        let sampler = SequenceMemorySampler(samples: [fixture.sample(value: 1)], delay: .milliseconds(50))
        let sleeper = RecordingMemorySleeper()
        let monitor = MemoryMonitor(store: fixture.store, sampler: sampler,
            cadence: .milliseconds(20), sleeper: sleeper)
        await monitor.start(target: fixture.target)
        let deadline = ContinuousClock.now + .seconds(5)
        while await sleeper.durations.isEmpty {
            try #require(ContinuousClock.now < deadline)
            await Task.yield()
        }
        await monitor.stop()

        #expect(await sleeper.durations == [.zero])
        #expect(await sampler.callCount == 1)
    }

    @Test("restart closes the old series before new samples")
    func restartClosesSeries() async throws {
        let fixture = try await MemoryFixture.make()
        let restarted = TargetApplication(
            deviceIdentity: fixture.target.deviceIdentity,
            applicationID: fixture.target.applicationID,
            displayName: fixture.target.displayName,
            processID: 200,
            processStartIdentity: "new",
            debuggable: true,
            state: .restarted
        )
        let sampler = RestartMemorySampler(
            first: fixture.sample(value: 10),
            restarted: restarted
        )
        let monitor = MemoryMonitor(store: fixture.store, sampler: sampler)
        _ = await monitor.sampleOnce(target: fixture.target)

        let outcome = await monitor.sampleOnce(target: fixture.target)

        #expect(outcome.restartedTarget == restarted)
        #expect(await monitor.samples.isEmpty)
        #expect(await monitor.target == nil)
    }
}

private actor MemoryEventRecorder {
    private(set) var values: [MemoryMonitorEvent] = []
    private(set) var receivedAt: [ContinuousClock.Instant] = []
    func record(_ event: MemoryMonitorEvent) {
        values.append(event)
        receivedAt.append(.now)
    }
}

private actor OutcomeMemorySampler: MemorySampling {
    var outcomes: [MemoryProviderOutcome]
    private(set) var callCount = 0
    init(outcomes: [MemoryProviderOutcome]) { self.outcomes = outcomes }
    func sample(target: TargetApplication, transportID: String) -> MemoryProviderOutcome {
        callCount += 1
        return outcomes.isEmpty ? .stopped : outcomes.removeFirst()
    }
}

private struct MemoryFixture {
    let store: DeviceSessionStore
    let target: TargetApplication

    static func make() async throws -> MemoryFixture {
        let identity = try DeviceIdentity(rawValue: "device", stability: .stable, platform: .android)
        let candidate = try TransportCandidate(
            id: "transport",
            identity: identity,
            kind: .usb,
            source: .adb,
            status: .available,
            observedAt: Date()
        )
        let device = DeviceRecord(
            identity: identity,
            name: "device",
            authorization: .authorized,
            candidates: [candidate],
            preferredTransportID: candidate.id
        )
        let store = DeviceSessionStore()
        await store.replaceInventory([device])
        _ = try await store.select(identity)
        return MemoryFixture(
            store: store,
            target: TargetApplication(
                deviceIdentity: identity,
                applicationID: "dev.example.app",
                displayName: "Example",
                processID: 100,
                processStartIdentity: "old",
                debuggable: true,
                state: .running
            )
        )
    }

    func sample(value: Int64) -> MemorySample {
        MemorySample(
            deviceIdentity: target.deviceIdentity,
            applicationID: target.applicationID,
            processID: target.processID!,
            processStartIdentity: target.processStartIdentity,
            capturedAt: Date(timeIntervalSince1970: TimeInterval(value)),
            source: .androidMeminfo,
            pssBytes: value
        )
    }
}

private actor SuspendingMemorySampler: MemorySampling {
    private var continuation: CheckedContinuation<MemoryProviderOutcome, Never>?
    private(set) var callCount = 0
    var hasRequest: Bool { continuation != nil }

    func sample(target: TargetApplication, transportID: String) async -> MemoryProviderOutcome {
        callCount += 1
        return await withCheckedContinuation { continuation = $0 }
    }

    func resume(sample: MemorySample) {
        continuation?.resume(returning: .sample(sample))
        continuation = nil
    }
}

private actor SequenceMemorySampler: MemorySampling {
    private var values: [MemorySample]
    private let delay: Duration
    private let firstDelay: Duration
    private(set) var callCount = 0

    init(samples: [MemorySample], delay: Duration = .zero, firstDelay: Duration? = nil) {
        values = samples
        self.delay = delay
        self.firstDelay = firstDelay ?? delay
    }

    func sample(target: TargetApplication, transportID: String) async -> MemoryProviderOutcome {
        callCount += 1
        let delay = callCount == 1 ? firstDelay : self.delay
        if delay > .zero { try? await Task.sleep(for: delay) }
        guard !values.isEmpty else { return .stopped }
        return .sample(values.removeFirst())
    }
}

private actor RestartMemorySampler: MemorySampling {
    private let first: MemorySample
    private let restarted: TargetApplication
    private var callCount = 0

    init(first: MemorySample, restarted: TargetApplication) {
        self.first = first
        self.restarted = restarted
    }

    func sample(target: TargetApplication, transportID: String) async -> MemoryProviderOutcome {
        callCount += 1
        return callCount == 1 ? .sample(first) : .restarted(restarted)
    }
}

private actor RecordingMemorySleeper: MemoryMonitorSleeping {
    private(set) var durations: [Duration] = []

    func sleep(for duration: Duration) async throws {
        durations.append(duration)
        throw CancellationError()
    }
}
