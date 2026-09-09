import DeviceBridgeCore
import Foundation

@main
struct DeviceInformationModelChecks {
    @MainActor
    static func main() async throws {
        try await lifecycleRaces()
        let device = try fixtureDevice()
        let first = ConnectionSession(deviceIdentity: device.identity, generation: 1,
            transportID: "test-route", state: .active, startedAt: Date())
        let second = ConnectionSession(deviceIdentity: device.identity, generation: 2,
            transportID: "test-route", state: .active, startedAt: Date())
        let service = HeldInformationReader()
        let model = DeviceInformationViewModel(device: device, session: first, service: service)
        try require(model.report == nil && !model.isBusy, "binding must not automatically read")
        try require(await service.count == 0, "construction read device content")
        let id = try model.read(origin: .agent).unwrap()
        try require(model.isBusy && model.operation?.id == id && model.operation?.origin == .agent,
            "admission must synchronously assign one owner")
        try require(model.read(origin: .ui) == nil, "UI bypassed agent read exclusion")
        try await wait { await service.count == 1 }
        let oldReport = try report(session: first)
        await service.complete(.report(oldReport))
        try await wait { !model.isBusy }
        try require(model.report == oldReport && model.operation?.reportID == oldReport.id,
            "completed report was not attributed to its operation")
        let refreshID = try model.read().unwrap()
        try require(model.report?.queryFinishedAt == oldReport.queryFinishedAt && model.isShowingPreviousReport,
            "refresh must preserve and label previous report time")
        try await wait { await service.count == 2 }
        model.cancel()
        try require(model.isBusy && model.operation?.state == .cancelling && model.read() == nil,
            "cancel must hold exclusion until completion")
        await service.complete(.report(try report(session: first)))
        try await wait { !model.isBusy }
        try require(model.operation?.id == refreshID && model.operation?.state == .cancelled
            && model.operation?.reportID == nil && model.report == oldReport,
            "late success after cancel must not replace report or claim old report")
        _ = model.read()
        try await wait { await service.count == 3 }
        await service.complete(.failure(OperationFailure(code: .timeout, safeMessage: "This information query timed out.")))
        try await wait { !model.isBusy }
        try require(model.operation?.state == .failed && model.operation?.reportID == nil,
            "failed refresh attributed an earlier report to this operation")
        for _ in 0..<10 {
            _ = model.read()
            try await wait { await service.pending }
            model.invalidate()
            try require(model.report == nil && model.operation == nil, "session invalidation retained content")
            model.bind(device: device, session: second, service: service)
            await service.complete(.report(oldReport))
            try await Task.sleep(for: .milliseconds(10))
            try require(model.report == nil && !model.isBusy, "old completion reached new session")
        }
        _ = model.read()
        try await wait { await service.pending }
        await service.complete(.report(oldReport))
        try await wait { !model.isBusy }
        try require(model.report == nil && model.operation?.state == .failed, "foreign report passed publication guard")
        print("PASS: information initial/partial state, UI-agent exclusion, refresh provenance, cancellation, failure metadata and ten session-switch races")
    }

    @MainActor static func lifecycleRaces() async throws {
        let device = try fixtureDevice()
        let otherIdentity = try DeviceIdentity(rawValue: "other-information-device", stability: .stable, platform: .android)
        let other = DeviceRecord(identity: otherIdentity, name: "Other phone", authorization: .authorized,
            candidates: [], preferredTransportID: "other-route")
        for scenario in ["switch", "disconnect", "cancel", "reconnect"] {
            for _ in 0..<10 {
                let session = ConnectionSession(deviceIdentity: device.identity, generation: 1,
                    transportID: "test-route", state: .active, startedAt: Date())
                let service = HeldInformationReader()
                let model = DeviceInformationViewModel(device: device, session: session, service: service)
                _ = try model.read().unwrap()
                try await wait { await service.pending }
                if scenario == "cancel" {
                    model.cancel()
                    try require(model.isBusy && model.read() == nil, "cancel released information owner early")
                } else {
                    model.invalidate()
                    if scenario != "disconnect" {
                        let target = scenario == "switch" ? other : device
                        let replacement = ConnectionSession(deviceIdentity: target.identity, generation: 2,
                            transportID: "replacement-route", state: .active, startedAt: Date())
                        model.bind(device: target, session: replacement, service: service)
                    }
                }
                await service.complete(.report(try report(session: session)))
                try await wait { !model.isBusy }
                try await Task.sleep(for: .milliseconds(10))
                try require(model.report == nil, "\(scenario) published a stale information report")
                try require(scenario == "cancel" ? model.operation?.state == .cancelled : model.operation == nil,
                    "\(scenario) published the wrong terminal")
                try require(await service.count == 1, "\(scenario) automatically repeated reading")
            }
        }
        print("PASS: information switch/disconnect/cancel/reconnect races: 10 each, zero stale publication or replay")
    }

    static func fixtureDevice() throws -> DeviceRecord {
        let identity = try DeviceIdentity(rawValue: "test-device", stability: .stable, platform: .android)
        let candidate = try TransportCandidate(id: "test-route", identity: identity, kind: .usb,
            source: .adb, status: .available, observedAt: Date())
        return DeviceRecord(identity: identity, name: "Test phone", authorization: .authorized,
            candidates: [candidate], preferredTransportID: candidate.id)
    }
    static func report(session: ConnectionSession) throws -> DeviceInformationReport {
        let now = Date()
        return try DeviceInformationReport(deviceName: "Test phone", session: session,
            queryStartedAt: now, queryFinishedAt: now, sections: DeviceInformationCatalog.makeSections(values: [
                "screen.physicalWidth": DeviceInformationCatalog.field("screen.physicalWidth", value: .integer(1080),
                    source: .init(kind: .adb, queriedAt: now))]))
    }
    @MainActor static func wait(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw Failure.failed("state timeout") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure.failed(message) }
    }
    enum Failure: Error { case failed(String) }
}
private extension Optional {
    func unwrap() throws -> Wrapped {
        guard let self else { throw DeviceInformationModelChecks.Failure.failed("expected admission") }
        return self
    }
}
private actor HeldInformationReader: DeviceInformationReading {
    private(set) var count = 0
    private var continuation: CheckedContinuation<DeviceInformationOutcome, Never>?
    var pending: Bool { continuation != nil }
    func read(device: DeviceRecord, session: ConnectionSession, operationID: UUID) async -> DeviceInformationOutcome {
        count += 1
        return await withCheckedContinuation { continuation = $0 }
    }
    func complete(_ outcome: DeviceInformationOutcome) {
        continuation?.resume(returning: outcome); continuation = nil
    }
}
