import DeviceBridgeProtocol
import Foundation
import Testing
@testable import DeviceBridgeCore

@Suite("Privacy audit")
struct PrivacyAuditTests {
    @Test("representative diagnostics contain no registered payload or secret")
    func redactedLogFixtureHasNoPayload() {
        let secrets = [
            "raw-device-00008120",
            "session-nonce-private",
            "clipboard secret 你好",
            "transferred-file-private-bytes",
            "iVBORw0KGgo-private-screenshot",
        ]
        let rawFixture = """
        device=raw-device-00008120 nonce=session-nonce-private
        clipboardText=clipboard secret 你好
        file=transferred-file-private-bytes screenshot=iVBORw0KGgo-private-screenshot
        vm=ws://127.0.0.1:54321/VM-secret=/ws
        result=permissionDenied
        """

        let exported = Redactor().redact(rawFixture, secrets: secrets)

        for secret in secrets {
            #expect(!exported.contains(secret))
        }
        #expect(!exported.contains("VM-secret"))
        #expect(exported.contains("result=permissionDenied"))
    }

    @Test("untrusted clipboard helper errors cannot echo clipboard or session secrets")
    func clipboardFailureDoesNotPublishPayload() async throws {
        let store = DeviceSessionStore()
        let device = try makeDevice(rawID: "privacy-device", kind: .usb)
        await store.replaceInventory([device])
        _ = try await store.select(device.identity)
        let clipboard = "private clipboard 你好"
        let nonce = "private-session-nonce"
        let channel = PrivacyFailingHelperChannel(message: "failed: \(clipboard) \(nonce)")
        let service = ClipboardService(
            store: store,
            channel: channel,
            sessionNonce: nonce,
            helperDeviceID: "private-helper-id"
        )

        let outcome = await service.write(clipboard)
        let message = outcome.failure?.safeMessage ?? ""
        let recovery = outcome.failure?.recoveryAction ?? ""

        #expect(!message.contains(clipboard))
        #expect(!message.contains(nonce))
        #expect(!recovery.contains(clipboard))
        #expect(!recovery.contains(nonce))
    }

    @Test("untrusted keep-alive helper errors cannot echo lease or session secrets")
    func keepAliveFailureDoesNotPublishPayload() async throws {
        let store = DeviceSessionStore()
        let device = try makeDevice(rawID: "privacy-wireless-device", kind: .wifi)
        await store.replaceInventory([device])
        _ = try await store.select(device.identity)
        let nonce = "private-keepalive-nonce"
        let lease = "private-lease-id"
        let channel = PrivacyFailingHelperChannel(message: "failed: \(nonce) \(lease)")
        let controller = AndroidKeepAliveController(
            store: store,
            channel: channel,
            sessionNonce: nonce,
            helperDeviceID: "private-helper-id"
        )

        let outcome = await controller.start()
        let message = outcome.failure?.safeMessage ?? ""
        let recovery = outcome.failure?.recoveryAction ?? ""

        #expect(!message.contains(nonce))
        #expect(!message.contains(lease))
        #expect(!recovery.contains(nonce))
        #expect(!recovery.contains(lease))
    }

    private func makeDevice(rawID: String, kind: TransportKind) throws -> DeviceRecord {
        let identity = try DeviceIdentity(rawValue: rawID, stability: .stable, platform: .android)
        let candidate = try TransportCandidate(
            id: "transport-\(kind.rawValue)",
            identity: identity,
            kind: kind,
            source: .adb,
            status: .available,
            observedAt: Date()
        )
        return DeviceRecord(
            identity: identity,
            name: "Privacy fixture",
            authorization: .authorized,
            candidates: [candidate],
            preferredTransportID: candidate.id
        )
    }
}

private actor PrivacyFailingHelperChannel: HelperRequestSending {
    let message: String

    init(message: String) {
        self.message = message
    }

    func send(_ request: HelperRequest) async throws -> HelperResult {
        HelperResult(
            requestID: request.requestID,
            status: .failure,
            completedAt: Date(),
            error: HelperErrorPayload(
                code: "fixture.failure",
                message: message,
                recoveryAction: "Retry after removing \(message)"
            )
        )
    }
}
