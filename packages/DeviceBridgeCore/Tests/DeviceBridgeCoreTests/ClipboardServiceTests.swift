import DeviceBridgeProtocol
import Foundation
import Testing
@testable import DeviceBridgeCore

@Suite("Clipboard service")
struct ClipboardServiceTests {
    @Test("Unicode text is sent in the helper payload and never echoed by success")
    func unicodeWrite() async throws {
        let store = DeviceSessionStore()
        let device = try makeDevice(rawID: "one", transportID: "usb-1")
        await store.replaceInventory([device])
        _ = try await store.select(device.identity)
        let channel = RecordingHelperChannel { request in
            HelperResult(
                requestID: request.requestID,
                status: .success,
                completedAt: Date(timeIntervalSince1970: 10),
                payload: [
                    "written": .bool(true),
                    "foregroundDisposition": .string("runnerRemainsForeground"),
                ]
            )
        }
        let service = ClipboardService(
            store: store,
            channel: channel,
            sessionNonce: "secret",
            helperDeviceID: "helper"
        )

        let outcome = await service.write("你好 👋🏽 مرحبا")
        let request = await channel.requests.first

        #expect(outcome == .written(at: Date(timeIntervalSince1970: 10)))
        #expect(request?.payload["text"]?.stringValue == "你好 👋🏽 مرحبا")
        #expect(await service.lastForegroundDisposition == .runnerRemainsForeground)
    }

    @Test("read publishes a generation-bound snapshot")
    func readSnapshot() async throws {
        let store = DeviceSessionStore()
        let device = try makeDevice(rawID: "one", transportID: "usb-1")
        await store.replaceInventory([device])
        _ = try await store.select(device.identity)
        let channel = RecordingHelperChannel { request in
            HelperResult(
                requestID: request.requestID,
                status: .success,
                completedAt: Date(timeIntervalSince1970: 20),
                payload: ["text": .string("clipboard value")]
            )
        }
        let service = ClipboardService(
            store: store,
            channel: channel,
            sessionNonce: "secret",
            helperDeviceID: "helper"
        )

        let outcome = await service.read()

        #expect(outcome.snapshot?.text == "clipboard value")
        #expect(outcome.snapshot?.deviceIdentity == device.identity)
        #expect(outcome.snapshot?.sessionGeneration == 1)
        #expect(await service.currentSnapshot?.text == "clipboard value")
    }

    @Test("oversized text is rejected before reaching the channel")
    func oversizedWrite() async throws {
        let store = DeviceSessionStore()
        let device = try makeDevice(rawID: "one", transportID: "usb-1")
        await store.replaceInventory([device])
        _ = try await store.select(device.identity)
        let channel = RecordingHelperChannel { request in
            HelperResult(requestID: request.requestID, status: .success, completedAt: Date())
        }
        let service = ClipboardService(
            store: store,
            channel: channel,
            sessionNonce: "secret",
            helperDeviceID: "helper"
        )

        let outcome = await service.write(String(repeating: "你", count: 349_526))

        #expect(outcome.failure?.code == .restricted)
        #expect(await channel.requests.isEmpty)
    }

    @Test("current clipboard text beyond the old limit is returned in full")
    func longCurrentText() async throws {
        let store = DeviceSessionStore()
        let device = try makeDevice(rawID: "one", transportID: "usb-1")
        await store.replaceInventory([device])
        _ = try await store.select(device.identity)
        let text = String(repeating: "你\n", count: 200_000) + "END"
        let channel = RecordingHelperChannel { request in
            HelperResult(requestID: request.requestID, status: .success, completedAt: Date(),
                         payload: ["text": .string(text)])
        }
        let service = ClipboardService(store: store, channel: channel, sessionNonce: "secret", helperDeviceID: "helper")
        #expect(await service.read().snapshot?.text == text)
    }

    @Test("oversized read is explicit and never publishes truncated text")
    func oversizedRead() async throws {
        let store = DeviceSessionStore()
        let device = try makeDevice(rawID: "one", transportID: "usb-1")
        await store.replaceInventory([device])
        _ = try await store.select(device.identity)
        let channel = RecordingHelperChannel { request in
            HelperResult(requestID: request.requestID, status: .success, completedAt: Date(),
                         payload: ["text": .string(String(repeating: "你", count: 349_526))])
        }
        let service = ClipboardService(store: store, channel: channel, sessionNonce: "secret", helperDeviceID: "helper")
        #expect(await service.read().failure?.code == .restricted)
        #expect(await service.currentSnapshot == nil)
    }

    @Test("helper size rejection is surfaced without copying its arbitrary error text")
    func helperSizeRejection() async throws {
        let store = DeviceSessionStore()
        let device = try makeDevice(rawID: "one", transportID: "usb-1")
        await store.replaceInventory([device])
        _ = try await store.select(device.identity)
        let channel = RecordingHelperChannel { request in
            HelperResult(requestID: request.requestID, status: .failure, completedAt: Date(),
                         error: HelperErrorPayload(code: "clipboard.too_large", message: "secret clipboard content"))
        }
        let service = ClipboardService(store: store, channel: channel, sessionNonce: "secret", helperDeviceID: "helper")
        let outcome = await service.read()
        #expect(outcome.failure?.code == .restricted)
        #expect(outcome.failure?.safeMessage.contains("secret") == false)
    }

    @Test("maximum-size control-character clipboard text survives JSON escaping and framing")
    func escapedMaximumTextFrame() throws {
        let text = String(repeating: "\u{0000}", count: 1_048_576)
        let result = HelperResult(requestID: UUID(), status: .success, completedAt: Date(), payload: ["text": .string(text)])
        let codec = HelperWireCodec()
        let encoded = try codec.encode(result)
        let decoded = try codec.decodeResult(HelperFrameCodec.decode(HelperFrameCodec.encode(encoded)))
        #expect(decoded.payload?["text"]?.stringValue == text)
    }

    @Test("text export writes the complete UTF8 snapshot and refuses switched or renewed sessions")
    func textExport() throws {
        let first = try makeDevice(rawID: "one", transportID: "usb-1").identity
        let second = try makeDevice(rawID: "two", transportID: "usb-2").identity
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("clipboard.txt")
        let text = String(repeating: "完整文本\n", count: 40_000) + "END"
        let snapshot = ClipboardSnapshot(deviceIdentity: first, text: text, capturedAt: Date(), sessionGeneration: 7)
        #expect(try !snapshot.saveText(to: destination, currentDeviceIdentity: second, currentSessionGeneration: 7))
        #expect(try !snapshot.saveText(to: destination, currentDeviceIdentity: first, currentSessionGeneration: 9))
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(try snapshot.saveText(to: destination, currentDeviceIdentity: first, currentSessionGeneration: 7))
        #expect(try String(contentsOf: destination, encoding: .utf8) == text)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["clipboard.txt"])
        let otherSnapshot = ClipboardSnapshot(deviceIdentity: first, text: "replacement", capturedAt: Date(), sessionGeneration: 7)
        #expect(throws: (any Error).self) {
            try otherSnapshot.saveText(to: destination, currentDeviceIdentity: first, currentSessionGeneration: 7)
        }
        #expect(try String(contentsOf: destination, encoding: .utf8) == text)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["clipboard.txt"])
    }

    @Test(arguments: [
        (HelperResultStatus.permissionDenied, OperationFailureCode.permissionDenied),
        (HelperResultStatus.cancelled, OperationFailureCode.cancelled),
        (HelperResultStatus.actionRequired, OperationFailureCode.helperMissing),
    ])
    func terminalHelperStatus(status: HelperResultStatus, expected: OperationFailureCode) async throws {
        let store = DeviceSessionStore()
        let device = try makeDevice(rawID: "one", transportID: "usb-1")
        await store.replaceInventory([device])
        _ = try await store.select(device.identity)
        let channel = RecordingHelperChannel { request in
            HelperResult(
                requestID: request.requestID,
                status: status,
                completedAt: Date(),
                error: HelperErrorPayload(code: "safe", message: "Safe clipboard error")
            )
        }
        let service = ClipboardService(
            store: store,
            channel: channel,
            sessionNonce: "secret",
            helperDeviceID: "helper"
        )

        let outcome = await service.read()

        #expect(outcome.failure?.code == expected)
        let expectedMessage = switch status {
        case .permissionDenied: "Clipboard access was denied on the device."
        case .cancelled: "Clipboard action cancelled."
        case .actionRequired: "The managed clipboard helper needs attention."
        default: ""
        }
        #expect(outcome.failure?.safeMessage == expectedMessage)
    }

    @Test(arguments: [
        ("clipboard.unavailable", "No readable text was returned by the device.",
         "Copy text on the device and review any paste prompt, then retry."),
        ("clipboard.foreground_required", "The clipboard helper could not enter the foreground.",
         "Unlock the device, keep the managed helper visible, and retry.")
    ])
    func unavailableClipboardPreservesSpecificRecovery(code: String, message: String, recovery: String) async throws {
        let store = DeviceSessionStore()
        let device = try makeDevice(rawID: "one", transportID: "usb-1")
        await store.replaceInventory([device])
        _ = try await store.select(device.identity)
        let channel = RecordingHelperChannel { request in
            HelperResult(requestID: request.requestID, status: .actionRequired, completedAt: Date(),
                error: HelperErrorPayload(code: code, message: "Untrusted private diagnostic must not be displayed"))
        }
        let service = ClipboardService(store: store, channel: channel, sessionNonce: "secret", helperDeviceID: "helper")
        let outcome = await service.read()
        #expect(outcome.snapshot == nil)
        #expect(outcome.failure?.safeMessage == message)
        #expect(outcome.failure?.recoveryAction == recovery)
        #expect(await channel.requests.count == 1)
    }

    @Test("device switch makes an in-flight read stale")
    func switchInvalidatesRead() async throws {
        let store = DeviceSessionStore()
        let first = try makeDevice(rawID: "one", transportID: "usb-1")
        let second = try makeDevice(rawID: "two", transportID: "usb-2")
        await store.replaceInventory([first, second])
        _ = try await store.select(first.identity)
        let channel = SuspendingHelperChannel()
        let service = ClipboardService(
            store: store,
            channel: channel,
            sessionNonce: "secret",
            helperDeviceID: "helper"
        )

        let task = Task { await service.read() }
        while !(await channel.hasRequest) { await Task.yield() }
        _ = try await store.select(second.identity)
        await channel.resume(text: "late secret")
        let outcome = await task.value

        #expect(outcome == .stale)
        #expect(await service.currentSnapshot == nil)
    }

    private func makeDevice(rawID: String, transportID: String) throws -> DeviceRecord {
        let identity = try DeviceIdentity(rawValue: rawID, stability: .stable, platform: .android)
        let candidate = try TransportCandidate(
            id: transportID,
            identity: identity,
            kind: .usb,
            source: .adb,
            status: .available,
            observedAt: Date()
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

private actor RecordingHelperChannel: HelperRequestSending {
    private(set) var requests: [HelperRequest] = []
    private let handler: @Sendable (HelperRequest) -> HelperResult

    init(handler: @escaping @Sendable (HelperRequest) -> HelperResult) {
        self.handler = handler
    }

    func send(_ request: HelperRequest) async throws -> HelperResult {
        requests.append(request)
        return handler(request)
    }
}

private actor SuspendingHelperChannel: HelperRequestSending {
    private var request: HelperRequest?
    private var continuation: CheckedContinuation<HelperResult, Never>?

    var hasRequest: Bool { request != nil }

    func send(_ request: HelperRequest) async throws -> HelperResult {
        self.request = request
        return await withCheckedContinuation { continuation = $0 }
    }

    func resume(text: String) {
        guard let request, let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: HelperResult(
            requestID: request.requestID,
            status: .success,
            completedAt: Date(),
            payload: ["text": .string(text)]
        ))
    }
}
