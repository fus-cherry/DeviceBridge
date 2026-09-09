import Foundation
import Testing
@testable import DeviceBridgeCore

@Suite("Authoritative device session store")
struct DeviceSessionStoreTests {
    @Test("operation completion consumes publication eligibility in one store turn")
    func completionEligibility() async throws {
        let selected = try device(rawID: "selected", transportID: "usb-1")
        let store = DeviceSessionStore()
        await store.replaceInventory([selected])
        _ = try await store.select(selected.identity)
        let active = try await store.beginOperation(.memorySample)
        #expect(await store.finishOperation(active))
        #expect(await !store.finishOperation(active))
        let stale = try await store.beginOperation(.memorySample)
        #expect(await store.canPublish(stale))
        _ = try await store.select(selected.identity)
        #expect(await !store.finishOperation(stale))
    }
    @Test("switching devices increments generation and rejects prior operation")
    func switchRejectsLateResult() async throws {
        let first = try device(rawID: "first", transportID: "usb-1")
        let second = try device(rawID: "second", transportID: "usb-2")
        let store = DeviceSessionStore()
        await store.replaceInventory([first, second])

        _ = try await store.select(first.identity)
        let oldToken = try await store.beginOperation(
            .screenshot,
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        )
        let secondSnapshot = try await store.select(second.identity)

        #expect(secondSnapshot.session?.deviceIdentity == second.identity)
        #expect(secondSnapshot.generation == 2)
        #expect(await !store.canPublish(oldToken))
    }

    @Test("removing selected device disconnects and invalidates operations")
    func removalDisconnectsSelection() async throws {
        let selected = try device(rawID: "selected", transportID: "usb-1")
        let store = DeviceSessionStore()
        await store.replaceInventory([selected])
        _ = try await store.select(selected.identity)
        let token = try await store.beginOperation(.clipboardRead)

        await store.replaceInventory([])
        let snapshot = await store.snapshot()

        #expect(snapshot.generation == 2)
        #expect(snapshot.session?.state == .disconnected)
        #expect(snapshot.selectedDeviceIdentity == selected.identity)
        #expect(await !store.canPublish(token))
    }

    @Test("cannot select an unknown device")
    func rejectsUnknownSelection() async throws {
        let store = DeviceSessionStore()
        let unknown = try DeviceIdentity(rawValue: "unknown", stability: .stable, platform: .iOS)

        do {
            _ = try await store.select(unknown)
            Issue.record("Expected selection failure")
        } catch let error as DeviceSessionStoreError {
            #expect(error == .deviceNotFound)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("explicit disconnect invalidates active work and preserves the selected device")
    func explicitDisconnectInvalidatesWork() async throws {
        let selected = try device(rawID: "selected", transportID: "usb-1")
        let store = DeviceSessionStore()
        await store.replaceInventory([selected])
        _ = try await store.select(selected.identity)
        let token = try await store.beginOperation(.clipboardRead)

        await store.disconnect()
        let snapshot = await store.snapshot()

        #expect(snapshot.generation == 2)
        #expect(snapshot.session?.state == .disconnected)
        #expect(snapshot.selectedDeviceIdentity == selected.identity)
        #expect(await !store.canPublish(token))
    }

    private func device(rawID: String, transportID: String) throws -> DeviceRecord {
        let identity = try DeviceIdentity(rawValue: rawID, stability: .stable, platform: .iOS)
        let candidate = try TransportCandidate(
            id: transportID,
            identity: identity,
            kind: .usb,
            source: .coreDevice,
            status: .available,
            observedAt: Date(timeIntervalSince1970: 100)
        )
        return DeviceRecord(
            identity: identity,
            name: rawID,
            authorization: .authorized,
            candidates: [candidate],
            preferredTransportID: transportID
        )
    }
}
