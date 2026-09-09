import Foundation

public protocol MemoryMonitorSleeping: Sendable {
    func sleep(for duration: Duration) async throws
}

public struct ContinuousMemorySleeper: MemoryMonitorSleeping {
    public init() {}

    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

public enum MemoryMonitorEvent: Sendable, Equatable {
    case sample(MemorySample)
    case restarted(TargetApplication)
    case stopped
    case failure(OperationFailure)
    case invalidated(OperationFailure)
    case busy
    case stale

    public var sample: MemorySample? {
        if case let .sample(sample) = self { return sample }
        return nil
    }

    public var restartedTarget: TargetApplication? {
        if case let .restarted(target) = self { return target }
        return nil
    }
}

public actor MemoryMonitor {
    // Leave headroom under the three-second freshness requirement for RPC/dispatch variation.
    // Slow external operations can still exceed it; never overlap them or invent fresh samples.
    public static let defaultCadence: Duration = .milliseconds(2500)

    private let store: DeviceSessionStore
    private let sampler: any MemorySampling
    private let maximumSamples: Int
    private let cadence: Duration
    private let sleeper: any MemoryMonitorSleeping
    private var activeSample = false
    private var loopTask: Task<Void, Never>?
    private var revision = 0

    public private(set) var target: TargetApplication?
    public private(set) var samples: [MemorySample] = []
    public private(set) var latestEvent: MemoryMonitorEvent?

    public init(
        store: DeviceSessionStore,
        sampler: any MemorySampling,
        maximumSamples: Int = 120,
        cadence: Duration = MemoryMonitor.defaultCadence,
        sleeper: any MemoryMonitorSleeping = ContinuousMemorySleeper()
    ) {
        self.store = store
        self.sampler = sampler
        self.maximumSamples = max(1, maximumSamples)
        self.cadence = cadence
        self.sleeper = sleeper
    }

    public func start(
        target: TargetApplication,
        onEvent: (@Sendable (MemoryMonitorEvent) async -> Void)? = nil
    ) {
        loopTask?.cancel()
        revision += 1
        let revision = revision
        self.target = target
        samples.removeAll(keepingCapacity: true)
        latestEvent = nil
        loopTask = Task { [weak self] in
            await self?.runLoop(target: target, revision: revision, onEvent: onEvent)
        }
    }

    public func stop() {
        revision += 1
        loopTask?.cancel()
        loopTask = nil
        target = nil
        samples.removeAll(keepingCapacity: true)
        latestEvent = nil
    }

    @discardableResult
    public func sampleOnce(target: TargetApplication) async -> MemoryMonitorEvent {
        guard !Task.isCancelled else { return .stale }
        guard !activeSample else { return .busy }
        let revision = revision
        activeSample = true
        defer { activeSample = false }

        let token: SessionToken
        do {
            token = try await store.beginOperation(.memorySample)
        } catch DeviceSessionStoreError.connectionBusy {
            return isCurrent(revision) ? .busy : .stale
        } catch {
            guard isCurrent(revision) else { return .stale }
            return publish(.failure(OperationFailure(
                code: .disconnected,
                safeMessage: "No active device session is available."
            )))
        }
        guard isCurrent(revision) else {
            await store.finishOperation(token)
            return .stale
        }
        guard token.deviceIdentity == target.deviceIdentity else {
            await store.finishOperation(token)
            guard isCurrent(revision) else { return .stale }
            return publish(.stale)
        }

        let outcome = await sampler.sample(target: target, transportID: token.transportID)
        let eligible = await store.finishOperation(token)
        guard isCurrent(revision) else { return .stale }
        guard eligible else { return publish(.stale) }

        switch outcome {
        case let .sample(sample):
            guard sample.deviceIdentity == target.deviceIdentity,
                  sample.applicationID == target.applicationID,
                  target.processID == nil || sample.processID == target.processID else {
                return publish(.stale)
            }
            if self.target == nil { self.target = target }
            samples.append(sample)
            if samples.count > maximumSamples {
                samples.removeFirst(samples.count - maximumSamples)
            }
            return publish(.sample(sample))
        case let .restarted(restarted):
            samples.removeAll(keepingCapacity: true)
            self.target = nil
            loopTask?.cancel()
            loopTask = nil
            return publish(.restarted(restarted))
        case .stopped:
            samples.removeAll(keepingCapacity: true)
            self.target = nil
            loopTask?.cancel()
            loopTask = nil
            return publish(.stopped)
        case let .failure(failure):
            return publish(.failure(failure))
        case let .invalidated(failure):
            samples.removeAll(keepingCapacity: true)
            self.target = nil
            loopTask?.cancel()
            loopTask = nil
            return publish(.invalidated(failure))
        }
    }

    private func runLoop(
        target: TargetApplication,
        revision: Int,
        onEvent: (@Sendable (MemoryMonitorEvent) async -> Void)?
    ) async {
        while isCurrent(revision) {
            let cycleStartedAt = ContinuousClock.now
            let event = await sampleOnce(target: target)
            // Terminal outcomes cancel their own loop, but must still deliver their final reason.
            // A user Stop/new Start changes the revision and suppresses old callbacks completely.
            guard self.revision == revision else { return }
            await onEvent?(event)
            switch event {
            case .restarted, .stopped, .stale, .invalidated:
                return
            case .sample, .failure, .busy:
                break
            }
            do {
                // Sampling and publication consume this cycle's budget. Keep one sequential
                // loop: an overrun gets no extra delay and never queues catch-up samples.
                let remaining = max(.zero, cadence - cycleStartedAt.duration(to: .now))
                try await sleeper.sleep(for: remaining)
            } catch {
                return
            }
        }
    }

    private func isCurrent(_ revision: Int) -> Bool {
        self.revision == revision && !Task.isCancelled
    }

    private func publish(_ event: MemoryMonitorEvent) -> MemoryMonitorEvent {
        latestEvent = event
        return event
    }
}
