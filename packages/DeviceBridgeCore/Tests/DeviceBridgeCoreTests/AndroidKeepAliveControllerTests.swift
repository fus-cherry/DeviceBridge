import DeviceBridgeProtocol
import Foundation
import Testing
@testable import DeviceBridgeCore

@Suite("Android helper keep-alive controller")
struct AndroidKeepAliveControllerTests {
    @Test("wireless start publishes a visible lease and renews after ten seconds")
    func startAndRenew() async throws {
        let store = DeviceSessionStore()
        let device = try makeDevice(rawID: "wireless-a", transportID: "adb-wifi-a", kind: .wifi)
        await store.replaceInventory([device])
        _ = try await store.select(device.identity)
        let channel = KeepAliveChannel()
        let sleeper = RenewOnceSleeper()
        let controller = AndroidKeepAliveController(
            store: store,
            channel: channel,
            sessionNonce: "session-nonce",
            helperDeviceID: "helper-a",
            sleeper: sleeper
        )

        let outcome = await controller.start()
        #expect(outcome.lease?.leaseID == "lease-a")
        #expect(outcome.lease?.notificationVisible == true)
        #expect(outcome.lease?.wifiLockHeld == true)

        await waitUntil { await channel.actions.contains(.keepAliveRenew) }
        let requests = await channel.requests
        #expect(requests.first?.action == .keepAliveStart)
        #expect(requests.last?.action == .keepAliveRenew)
        #expect(requests.last?.payload["leaseId"] == .string("lease-a"))
        #expect(await sleeper.durations.first == .seconds(10))
        await controller.stop()
    }

    @Test("USB sessions never start device-side Wi-Fi maintenance")
    func rejectsUSB() async throws {
        let store = DeviceSessionStore()
        let device = try makeDevice(rawID: "usb-a", transportID: "adb-usb-a", kind: .usb)
        await store.replaceInventory([device])
        _ = try await store.select(device.identity)
        let channel = KeepAliveChannel()
        let controller = AndroidKeepAliveController(
            store: store,
            channel: channel,
            sessionNonce: "nonce",
            helperDeviceID: "helper",
            sleeper: NeverReturningKeepAliveSleeper()
        )

        let outcome = await controller.start()

        #expect(outcome.failure?.code == .unsupported)
        #expect(await channel.requests.isEmpty)
    }

    @Test("device switch stops the old lease instead of renewing it")
    func switchStopsLease() async throws {
        let store = DeviceSessionStore()
        let first = try makeDevice(rawID: "wireless-b", transportID: "adb-wifi-b", kind: .wifi)
        let second = try makeDevice(rawID: "wireless-c", transportID: "adb-wifi-c", kind: .wifi)
        await store.replaceInventory([first, second])
        _ = try await store.select(first.identity)
        let channel = KeepAliveChannel()
        let sleeper = GatedKeepAliveSleeper()
        let controller = AndroidKeepAliveController(
            store: store,
            channel: channel,
            sessionNonce: "nonce",
            helperDeviceID: "helper",
            sleeper: sleeper
        )
        _ = await controller.start()
        await waitUntil { await sleeper.isWaiting }

        _ = try await store.select(second.identity)
        await sleeper.release()

        await waitUntil { await channel.actions.contains(.keepAliveStop) }
        let actions = await channel.actions
        #expect(!actions.contains(.keepAliveRenew))
        #expect(actions.filter { $0 == .keepAliveStop }.count == 1)
        #expect(await controller.state == .stopped)
    }

    @Test("explicit shutdown sends one idempotent stop for the active lease")
    func explicitStop() async throws {
        let store = DeviceSessionStore()
        let device = try makeDevice(rawID: "wireless-d", transportID: "adb-wifi-d", kind: .wifi)
        await store.replaceInventory([device])
        _ = try await store.select(device.identity)
        let channel = KeepAliveChannel()
        let controller = AndroidKeepAliveController(
            store: store,
            channel: channel,
            sessionNonce: "nonce",
            helperDeviceID: "helper",
            sleeper: NeverReturningKeepAliveSleeper()
        )
        _ = await controller.start()

        await controller.stop()
        await controller.stop()

        let stopRequests = await channel.requests.filter { $0.action == .keepAliveStop }
        #expect(stopRequests.count == 1)
        #expect(stopRequests.first?.payload["leaseId"] == .string("lease-a"))
        #expect(await controller.state == .stopped)
    }

    @Test("shutdown racing a start still stops the lease returned after cancellation")
    func stopDuringStart() async throws {
        let store = DeviceSessionStore()
        let device = try makeDevice(rawID: "wireless-race", transportID: "adb-wifi-race", kind: .wifi)
        await store.replaceInventory([device])
        _ = try await store.select(device.identity)
        let channel = SuspendedStartKeepAliveChannel()
        let controller = AndroidKeepAliveController(
            store: store,
            channel: channel,
            sessionNonce: "nonce",
            helperDeviceID: "helper",
            sleeper: NeverReturningKeepAliveSleeper()
        )
        let startTask = Task { await controller.start() }
        await waitUntil { await channel.actions == [.keepAliveStart] }

        await controller.stop()
        await channel.completeStart()
        _ = await startTask.value

        await waitUntil { await channel.actions.contains(.keepAliveStop) }
        #expect(await channel.actions == [.keepAliveStart, .keepAliveStop])
        #expect(await controller.state == .stopped)
    }

    @Test("invisible notification fails start and schedules no renewals")
    func notificationRequired() async throws {
        let store = DeviceSessionStore()
        let device = try makeDevice(rawID: "wireless-e", transportID: "adb-wifi-e", kind: .wifi)
        await store.replaceInventory([device])
        _ = try await store.select(device.identity)
        let channel = KeepAliveChannel(notificationVisible: false)
        let controller = AndroidKeepAliveController(
            store: store,
            channel: channel,
            sessionNonce: "nonce",
            helperDeviceID: "helper",
            sleeper: NeverReturningKeepAliveSleeper()
        )

        let outcome = await controller.start()

        #expect(outcome.failure?.code == .permissionDenied)
        #expect(await controller.state.failure?.code == .permissionDenied)
        #expect(await channel.actions == [.keepAliveStart, .keepAliveStop])
    }

    private func makeDevice(
        rawID: String,
        transportID: String,
        kind: TransportKind
    ) throws -> DeviceRecord {
        let identity = try DeviceIdentity(rawValue: rawID, stability: .stable, platform: .android)
        let transport = try TransportCandidate(
            id: transportID,
            identity: identity,
            kind: kind,
            source: .adb,
            status: .available,
            observedAt: Date()
        )
        return DeviceRecord(
            identity: identity,
            name: rawID,
            authorization: .authorized,
            candidates: [transport],
            preferredTransportID: transport.id
        )
    }

    private func waitUntil(
        attempts: Int = 1_000,
        _ condition: @escaping @Sendable () async -> Bool
    ) async {
        for _ in 0..<attempts {
            if await condition() { return }
            await Task.yield()
        }
        Issue.record("Timed out waiting for asynchronous keep-alive work")
    }
}

private actor KeepAliveChannel: HelperRequestSending {
    private(set) var requests: [HelperRequest] = []
    private let notificationVisible: Bool

    init(notificationVisible: Bool = true) {
        self.notificationVisible = notificationVisible
    }

    var actions: [HelperAction] { requests.map(\.action) }

    func send(_ request: HelperRequest) async throws -> HelperResult {
        requests.append(request)
        let state = request.action == .keepAliveStop ? "stopped" : "active"
        var payload: [String: JSONValue] = [
            "state": .string(state),
            "notificationVisible": .bool(notificationVisible),
            "wifiLockHeld": .bool(request.action != .keepAliveStop),
        ]
        if request.action != .keepAliveStop {
            payload["leaseId"] = .string("lease-a")
            payload["startedAt"] = .string("2026-09-07T00:00:00Z")
            payload["renewedAt"] = .string("2026-09-07T00:00:10Z")
            payload["expiresAt"] = .string("2026-09-07T00:00:40Z")
        }
        return HelperResult(
            requestID: request.requestID,
            status: .success,
            completedAt: Date(),
            payload: payload
        )
    }
}

private actor SuspendedStartKeepAliveChannel: HelperRequestSending {
    private(set) var requests: [HelperRequest] = []
    private var startContinuation: CheckedContinuation<HelperResult, Never>?
    private var startRequest: HelperRequest?

    var actions: [HelperAction] { requests.map(\.action) }

    func send(_ request: HelperRequest) async throws -> HelperResult {
        requests.append(request)
        if request.action == .keepAliveStart {
            startRequest = request
            return await withCheckedContinuation { continuation in
                startContinuation = continuation
            }
        }
        return HelperResult(
            requestID: request.requestID,
            status: .success,
            completedAt: Date(),
            payload: [
                "state": .string("stopped"),
                "notificationVisible": .bool(false),
                "wifiLockHeld": .bool(false),
            ]
        )
    }

    func completeStart() {
        guard let request = startRequest else { return }
        startContinuation?.resume(returning: HelperResult(
            requestID: request.requestID,
            status: .success,
            completedAt: Date(),
            payload: [
                "state": .string("active"),
                "leaseId": .string("lease-race"),
                "startedAt": .string("2026-09-07T00:00:00Z"),
                "renewedAt": .string("2026-09-07T00:00:00Z"),
                "expiresAt": .string("2026-09-07T00:00:30Z"),
                "notificationVisible": .bool(true),
                "wifiLockHeld": .bool(true),
            ]
        ))
        startContinuation = nil
        startRequest = nil
    }
}

private actor RenewOnceSleeper: AndroidKeepAliveSleeping {
    private(set) var durations: [Duration] = []
    private var invocationCount = 0

    func sleep(for duration: Duration) async throws {
        durations.append(duration)
        invocationCount += 1
        if invocationCount == 1 { return }
        try await Task.sleep(for: .seconds(60))
    }
}

private struct NeverReturningKeepAliveSleeper: AndroidKeepAliveSleeping {
    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: .seconds(60))
    }
}

private actor GatedKeepAliveSleeper: AndroidKeepAliveSleeping {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var isWaiting = false

    func sleep(for duration: Duration) async throws {
        isWaiting = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        isWaiting = false
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private extension AndroidKeepAliveControllerState {
    var failure: OperationFailure? {
        if case let .failed(failure) = self { return failure }
        return nil
    }
}
