import Foundation
import Testing
@testable import DeviceBridgeCore

@Suite("Device information admission and publication")
struct DeviceInformationServiceTests {
    @Test("the captured active session is admitted and its candidate report is returned")
    func returnsEligibleReport() async throws {
        let fixture = try await ServiceFixture.make()
        let provider = StaticInformationProvider(response: .report)
        let service = DeviceInformationService(store: fixture.store, provider: provider)

        let outcome = await service.read(
            device: fixture.first,
            session: fixture.session,
            operationID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        )

        guard case let .report(report) = outcome else {
            Issue.record("Expected an eligible report")
            return
        }
        #expect(report.session == fixture.session)
        #expect(report.deviceName == fixture.first.name)
        #expect(await provider.calls == 1)
        #expect(await fixture.store.snapshot().activeOperationIDs.isEmpty)
    }

    @Test("an old captured session is rejected atomically before the provider runs")
    func rejectsOldSessionAtAdmission() async throws {
        let fixture = try await ServiceFixture.make(includeSecond: true)
        _ = try await fixture.store.select(fixture.second!.identity)
        let provider = StaticInformationProvider(response: .report)
        let outcome = await DeviceInformationService(store: fixture.store, provider: provider).read(
            device: fixture.first, session: fixture.session, operationID: UUID())

        #expect(outcome == .stale)
        #expect(await provider.calls == 0)
        #expect(await fixture.store.snapshot().activeOperationIDs.isEmpty)
    }

    @Test("a session change while the provider is suspended rejects the late candidate")
    func rejectsLateReport() async throws {
        let fixture = try await ServiceFixture.make(includeSecond: true)
        let provider = SuspendingInformationProvider()
        let service = DeviceInformationService(store: fixture.store, provider: provider)
        let task = Task {
            await service.read(device: fixture.first, session: fixture.session, operationID: UUID())
        }
        while !(await provider.hasRequest) { await Task.yield() }

        _ = try await fixture.store.select(fixture.second!.identity)
        await provider.resume()

        #expect(await task.value == .stale)
        #expect(await fixture.store.snapshot().activeOperationIDs.isEmpty)
    }

    @Test("a provider report attributed to another session is never publishable")
    func rejectsMismatchedReport() async throws {
        let fixture = try await ServiceFixture.make(includeSecond: true)
        let provider = MismatchedInformationProvider(session: fixture.secondSession!)
        let outcome = await DeviceInformationService(store: fixture.store, provider: provider).read(
            device: fixture.first, session: fixture.session, operationID: UUID())

        #expect(outcome == .stale)
        #expect(await fixture.store.snapshot().activeOperationIDs.isEmpty)
    }

    @Test("task cancellation releases admission and never returns a late report")
    func cancellationDoesNotPublish() async throws {
        let fixture = try await ServiceFixture.make()
        let provider = SuspendingInformationProvider()
        let service = DeviceInformationService(store: fixture.store, provider: provider)
        let task = Task {
            await service.read(device: fixture.first, session: fixture.session, operationID: UUID())
        }
        while !(await provider.hasRequest) { await Task.yield() }

        task.cancel()
        await provider.resume()
        let outcome = await task.value

        guard case let .failure(failure) = outcome else {
            Issue.record("Expected cancellation failure")
            return
        }
        #expect(failure.code == .cancelled)
        #expect(await fixture.store.snapshot().activeOperationIDs.isEmpty)
    }

    @Test("ordinary provider failures retain a structured category and release admission",
          arguments: [(StaticInformationProvider.Response.timedOut, OperationFailureCode.timeout),
                      (.outputLimit, .failure), (.unavailable, .failure)])
    fileprivate func mapsFailures(_ response: StaticInformationProvider.Response,
                                  _ expected: OperationFailureCode) async throws {
        let fixture = try await ServiceFixture.make()
        let provider = StaticInformationProvider(response: response)
        let outcome = await DeviceInformationService(store: fixture.store, provider: provider).read(
            device: fixture.first, session: fixture.session, operationID: UUID())

        guard case let .failure(failure) = outcome else {
            Issue.record("Expected structured failure")
            return
        }
        #expect(failure.code == expected)
        #expect(await fixture.store.snapshot().activeOperationIDs.isEmpty)
    }

    @Test("provider-classified failures retain their safe category and recovery",
          arguments: [
            OperationFailure(code: .timeout, safeMessage: "The detail query timed out.", recoveryAction: "Retry."),
            OperationFailure(code: .malformedOutput, safeMessage: "The detail response was invalid."),
            OperationFailure(code: .integrityMismatch, safeMessage: "The detail response belonged to another device."),
          ])
    func preservesClassifiedFailure(_ expected: OperationFailure) async throws {
        let fixture = try await ServiceFixture.make()
        let outcome = await DeviceInformationService(
            store: fixture.store,
            provider: ClassifiedFailureProvider(failure: expected)
        ).read(device: fixture.first, session: fixture.session, operationID: UUID())

        #expect(outcome == .failure(expected))
        #expect(await fixture.store.snapshot().activeOperationIDs.isEmpty)
    }

    @Test("a provider failure arriving after a session change is stale")
    func rejectsLateFailure() async throws {
        let fixture = try await ServiceFixture.make(includeSecond: true)
        let provider = SuspendingFailureProvider()
        let task = Task {
            await DeviceInformationService(store: fixture.store, provider: provider).read(
                device: fixture.first, session: fixture.session, operationID: UUID())
        }
        while !(await provider.hasRequest) { await Task.yield() }

        _ = try await fixture.store.select(fixture.second!.identity)
        await provider.resume()

        #expect(await task.value == .stale)
        #expect(await fixture.store.snapshot().activeOperationIDs.isEmpty)
    }
}

private actor StaticInformationProvider: DeviceInformationProviding {
    enum Response: Sendable {
        case report
        case timedOut
        case outputLimit
        case unavailable
    }

    private(set) var calls = 0
    let response: Response
    init(response: Response) { self.response = response }

    func read(device: DeviceRecord, session: ConnectionSession, deadline: ContinuousClock.Instant,
              validateSession: @escaping @Sendable () async throws -> Void) async throws -> DeviceInformationReport {
        calls += 1
        try await validateSession()
        switch response {
        case .report: return try serviceReport(device: device, session: session)
        case .timedOut: throw HostCommandError.timedOut
        case .outputLimit: throw HostCommandError.outputLimitExceeded
        case .unavailable: throw AndroidDeviceInformationError.noDeviceData
        }
    }
}

private actor SuspendingInformationProvider: DeviceInformationProviding {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var hasRequest = false

    func read(device: DeviceRecord, session: ConnectionSession, deadline: ContinuousClock.Instant,
              validateSession: @escaping @Sendable () async throws -> Void) async throws -> DeviceInformationReport {
        hasRequest = true
        await withCheckedContinuation { continuation = $0 }
        return try serviceReport(device: device, session: session)
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

private struct MismatchedInformationProvider: DeviceInformationProviding {
    let session: ConnectionSession
    func read(device: DeviceRecord, session: ConnectionSession, deadline: ContinuousClock.Instant,
              validateSession: @escaping @Sendable () async throws -> Void) async throws -> DeviceInformationReport {
        try serviceReport(device: device, session: self.session)
    }
}

private struct ClassifiedFailureProvider: DeviceInformationProviding {
    let failure: OperationFailure
    func read(device: DeviceRecord, session: ConnectionSession, deadline: ContinuousClock.Instant,
              validateSession: @escaping @Sendable () async throws -> Void) async throws -> DeviceInformationReport {
        throw failure
    }
}

private actor SuspendingFailureProvider: DeviceInformationProviding {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var hasRequest = false

    func read(device: DeviceRecord, session: ConnectionSession, deadline: ContinuousClock.Instant,
              validateSession: @escaping @Sendable () async throws -> Void) async throws -> DeviceInformationReport {
        hasRequest = true
        await withCheckedContinuation { continuation = $0 }
        throw AndroidDeviceInformationError.noDeviceData
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

private func serviceReport(device: DeviceRecord, session: ConnectionSession) throws -> DeviceInformationReport {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    return try DeviceInformationReport(deviceName: device.name, session: session,
        queryStartedAt: date, queryFinishedAt: date,
        sections: DeviceInformationCatalog.makeSections(values: [
            "identity.name": DeviceInformationCatalog.field("identity.name", value: .text(device.name),
                source: DeviceInformationSource(kind: .session, queriedAt: date)),
        ]))
}

private struct ServiceFixture {
    let store: DeviceSessionStore
    let first: DeviceRecord
    let second: DeviceRecord?
    let session: ConnectionSession
    let secondSession: ConnectionSession?

    static func make(includeSecond: Bool = false) async throws -> ServiceFixture {
        let first = try device(name: "first", transport: "route-1")
        let second = includeSecond ? try device(name: "second", transport: "route-2") : nil
        let store = DeviceSessionStore()
        await store.replaceInventory([first] + [second].compactMap { $0 })
        let session = try await store.select(first.identity).session!
        let secondSession: ConnectionSession?
        if let second {
            secondSession = ConnectionSession(deviceIdentity: second.identity, generation: session.generation + 1,
                transportID: second.preferredTransportID!, state: .active, startedAt: .distantPast)
        } else {
            secondSession = nil
        }
        return ServiceFixture(store: store, first: first, second: second, session: session, secondSession: secondSession)
    }

    private static func device(name: String, transport: String) throws -> DeviceRecord {
        let identity = try DeviceIdentity(rawValue: name, stability: .stable, platform: .android)
        let candidate = try TransportCandidate(id: transport, identity: identity, kind: .usb,
            source: .adb, status: .available, observedAt: .distantPast)
        return DeviceRecord(identity: identity, name: name, authorization: .authorized,
            candidates: [candidate], preferredTransportID: candidate.id)
    }
}
