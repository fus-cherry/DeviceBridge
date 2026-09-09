import Foundation
import Testing
@testable import DeviceBridgeCore

@Suite("Authoritative device session store")
struct DeviceSessionStoreTests {
    @Test("captured session admission cannot silently run on a newly selected device")
    func admissionRejectsChangedSession() async throws {
        let first = try device(rawID: "first", transportID: "usb-1")
        let second = try device(rawID: "second", transportID: "usb-2")
        let store = DeviceSessionStore()
        await store.replaceInventory([first, second])
        let original = try await store.select(first.identity)
        let captured = try #require(original.session)
        let current = try await store.select(second.identity)

        await #expect(throws: DeviceSessionStoreError.staleSession) {
            try await store.beginOperation(.deviceInformation, expectedSession: captured)
        }
        #expect(await store.snapshot().activeOperationIDs.isEmpty)
        let token = try await store.beginOperation(.deviceInformation,
            expectedSession: #require(current.session))
        #expect(token.deviceIdentity == second.identity)
        #expect(await store.finishOperation(token))
    }

    @Test("reselecting the same device invalidates captured admission while legacy callers still work")
    func admissionChecksGeneration() async throws {
        let selected = try device(rawID: "selected", transportID: "usb-1")
        let store = DeviceSessionStore()
        await store.replaceInventory([selected])
        let original = try await store.select(selected.identity)
        let captured = try #require(original.session)
        _ = try await store.select(selected.identity)
        await #expect(throws: DeviceSessionStoreError.staleSession) {
            try await store.beginOperation(.androidShell, expectedSession: captured)
        }
        let legacy = try await store.beginOperation(.clipboardRead)
        #expect(await store.canPublish(legacy))
        #expect(await store.finishOperation(legacy))
    }

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

    @Test("Shell cancellation revokes success but keeps cleanup exclusion and its current-session terminal")
    func shellCancellationDrains() async throws {
        let selected = try device(rawID: "selected", transportID: "usb-1")
        let store = DeviceSessionStore()
        await store.replaceInventory([selected])
        let session = try #require(await store.select(selected.identity).session)
        let owner = UUID()
        #expect(await store.registerMaintenance(owner: owner, session: session))
        let shell = try await store.beginOperation(.androidShell, expectedSession: session)
        await #expect(throws: DeviceSessionStoreError.connectionBusy) {
            try await store.beginOperation(.androidShell, expectedSession: session)
        }
        await store.invalidateOperation(shell, reason: .cancelled)
        #expect(await !store.canPublish(shell))
        #expect(await store.snapshot().activeOperationIDs.isEmpty)
        await #expect(throws: DeviceSessionStoreError.connectionBusy) {
            try await store.beginOperation(.androidShell, expectedSession: session)
        }
        #expect(await !store.reserveConnectionProbe(owner: owner, session: session))
        #expect(await store.finishShellOperation(shell, terminal: .cancelled))
        #expect(await store.reserveConnectionProbe(owner: owner, session: session))
    }

    @Test("cancelled or timed out Shell cannot publish a late remote exit", arguments: [ShellOperationInvalidationReason.cancelled, .timedOut])
    func shellInvalidatedSuccess(reason: ShellOperationInvalidationReason) async throws {
        let selected = try device(rawID: "selected", transportID: "usb-1")
        let store = DeviceSessionStore()
        await store.replaceInventory([selected])
        _ = try await store.select(selected.identity)
        let shell = try await store.beginOperation(.androidShell)
        await store.invalidateOperation(shell, reason: reason)
        #expect(await !store.finishShellOperation(shell, terminal: .remoteExit))
        let next = try await store.beginOperation(.androidShell)
        await store.invalidateOperation(next, reason: .timedOut)
        #expect(await store.finishShellOperation(next, terminal: .timedOut))
    }

    @Test("old Shell drains across explicit selection without publishing into the new session")
    func oldShellCleanup() async throws {
        let first = try device(rawID: "first", transportID: "usb-1")
        let second = try device(rawID: "second", transportID: "usb-2")
        let store = DeviceSessionStore()
        await store.replaceInventory([first, second])
        _ = try await store.select(first.identity)
        let old = try await store.beginOperation(.androidShell)
        let session = try #require(await store.select(second.identity).session)
        #expect(await store.snapshot().activeOperationIDs.isEmpty)
        await #expect(throws: DeviceSessionStoreError.connectionBusy) {
            try await store.beginOperation(.androidShell, expectedSession: session)
        }
        #expect(await !store.finishShellOperation(old, terminal: .cancelled))
        let next = try await store.beginOperation(.androidShell, id: old.operationID, expectedSession: session)
        #expect(await !store.finishShellOperation(old, terminal: .remoteExit))
        #expect(await store.canPublish(next))
        #expect(await store.finishShellOperation(next, terminal: .remoteExit))
    }

    @Test("operation IDs cannot overwrite live ownership and old full tokens cannot finish replacements")
    func operationIdentityIsComplete() async throws {
        let selected = try device(rawID: "selected", transportID: "usb-1")
        let store = DeviceSessionStore()
        await store.replaceInventory([selected])
        _ = try await store.select(selected.identity)
        let old = try await store.beginOperation(.deviceInformation)
        await #expect(throws: DeviceSessionStoreError.connectionBusy) {
            try await store.beginOperation(.clipboardRead, id: old.operationID)
        }
        _ = try await store.select(selected.identity)
        let next = try await store.beginOperation(.deviceInformation, id: old.operationID)
        #expect(await !store.finishOperation(old))
        #expect(await store.canPublish(next))
        #expect(await store.finishOperation(next))
    }

    @Test("inventory shows new candidates but defers preferred-route migration through Shell cleanup")
    func inventoryDefersRouteMigration() async throws {
        let selected = try device(rawID: "selected", transportID: "usb-1")
        let replacement = try device(rawID: "selected", transportID: "usb-2")
        let store = DeviceSessionStore()
        await store.replaceInventory([selected])
        let original = try #require(await store.select(selected.identity).session)
        let shell = try await store.beginOperation(.androidShell)
        await store.replaceInventory([replacement])
        #expect(await store.snapshot().devices == [replacement])
        #expect(await store.snapshot().session == original)
        await store.invalidateOperation(shell, reason: .cancelled)
        await store.replaceInventory([replacement])
        #expect(await store.snapshot().session == original)
        #expect(await store.finishShellOperation(shell, terminal: .cancelled))
        await store.replaceInventory([replacement])
        #expect(await store.snapshot().session?.transportID == "usb-2")
    }

    @Test("inventory disconnect retains Shell drain but removes legacy work")
    func inventoryDisconnectDrainsOnlyShell() async throws {
        let selected = try device(rawID: "selected", transportID: "usb-1")
        let store = DeviceSessionStore()
        await store.replaceInventory([selected])
        _ = try await store.select(selected.identity)
        let shell = try await store.beginOperation(.androidShell)
        let legacy = try await store.beginOperation(.fileReceive)
        await store.replaceInventory([])
        #expect(await store.snapshot().session?.state == .disconnected)
        #expect(await store.snapshot().activeOperationIDs.isEmpty)
        #expect(await !store.finishOperation(legacy))
        await store.replaceInventory([selected])
        _ = try await store.select(selected.identity)
        await #expect(throws: DeviceSessionStoreError.connectionBusy) {
            try await store.beginOperation(.androidShell)
        }
        #expect(await !store.finishShellOperation(shell, terminal: .failure))
        let next = try await store.beginOperation(.androidShell)
        #expect(await store.finishShellOperation(next, terminal: .remoteExit))
    }

    @Test("repeated disconnect is idempotent while an old Shell is still draining")
    func disconnectDoesNotRegenerateDrain() async throws {
        let selected = try device(rawID: "selected", transportID: "usb-1")
        let store = DeviceSessionStore()
        await store.replaceInventory([selected])
        _ = try await store.select(selected.identity)
        let shell = try await store.beginOperation(.androidShell)
        await store.disconnect()
        let disconnected = await store.snapshot()
        await store.disconnect()
        #expect(await store.snapshot().session == disconnected.session)
        #expect(await !store.finishShellOperation(shell, terminal: .failure))
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
