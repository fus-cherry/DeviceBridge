import DeviceBridgeProtocol
import Foundation
import Testing
@testable import DeviceBridgeCore

@Suite("Managed helper protocol")
struct HelperProtocolTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("wire codec emits and accepts ISO-8601 envelopes")
    func wireCodec() throws {
        let request = makeRequest()
        let data = try HelperWireCodec().encode(request)
        let text = String(decoding: data, as: UTF8.self)
        let decoded = try HelperWireCodec().decodeRequest(data)

        #expect(text.contains("2027-01-15T08:00:00Z"))
        #expect(text.contains("\"requestId\""))
        #expect(text.contains("\"helperDeviceId\""))
        #expect(!text.contains("\"requestID\""))
        #expect(!text.contains("\"helperDeviceID\""))
        #expect(decoded == request)
    }

    @Test("result codec accepts Android lower-camel ID keys")
    func androidResultKeys() throws {
        let json = """
        {"protocolVersion":1,"requestId":"11111111-1111-1111-1111-111111111111",\
        "status":"success","completedAt":"2027-01-15T08:00:00Z",\
        "payload":{"written":true}}
        """

        let result = try HelperWireCodec().decodeResult(Data(json.utf8))

        #expect(result.requestID.uuidString == "11111111-1111-1111-1111-111111111111")
        #expect(result.payload?["written"]?.boolValue == true)
    }

    @Test("valid request is accepted until its request ID is completed")
    func replayProtection() async {
        let validator = HelperRequestValidator(
            sessionNonce: "session-secret",
            helperDeviceID: "helper-device"
        )
        let request = makeRequest()

        #expect(await validator.validate(request, encodedByteCount: 256, now: now) == .accepted)
        await validator.markCompleted(request.requestID)
        #expect(await validator.validate(request, encodedByteCount: 256, now: now) == .rejected(.replayed))
    }

    @Test(arguments: [
        ("version", HelperRequestValidationError.unsupportedVersion),
        ("nonce", HelperRequestValidationError.nonceMismatch),
        ("device", HelperRequestValidationError.deviceMismatch),
        ("expired", HelperRequestValidationError.expired),
        ("future", HelperRequestValidationError.invalidTimestamp),
        ("size", HelperRequestValidationError.envelopeTooLarge),
    ])
    func invalidEnvelope(reason: String, expected: HelperRequestValidationError) async {
        let validator = HelperRequestValidator(
            sessionNonce: "session-secret",
            helperDeviceID: "helper-device"
        )
        var request = makeRequest()
        var size = 256
        switch reason {
        case "version": request.protocolVersion = 2
        case "nonce": request.sessionNonce = "wrong"
        case "device": request.helperDeviceID = "wrong"
        case "expired":
            request.createdAt = now.addingTimeInterval(-31)
            request.expiresAt = now.addingTimeInterval(-1)
        case "future": request.createdAt = now.addingTimeInterval(121)
        case "size": size = HelperWireCodec.maximumEnvelopeBytes + 1
        default: Issue.record("Unknown fixture")
        }

        #expect(await validator.validate(request, encodedByteCount: size, now: now) == .rejected(expected))
    }

    @Test("success and failure result payload rules are explicit")
    func resultPayloadRules() {
        let success = HelperResult(
            requestID: UUID(),
            status: .success,
            completedAt: now,
            payload: ["written": .bool(true)]
        )
        let failure = HelperResult(
            requestID: UUID(),
            status: .permissionDenied,
            completedAt: now,
            error: HelperErrorPayload(code: "clipboard.denied", message: "Clipboard access was denied.")
        )

        #expect(success.isStructurallyValid)
        #expect(failure.isStructurallyValid)
        #expect(!HelperResult(
            requestID: UUID(),
            status: .success,
            completedAt: now,
            error: HelperErrorPayload(code: "bad", message: "bad")
        ).isStructurallyValid)
    }

    @Test("length-prefixed frames use an unsigned big-endian header")
    func frameCodec() throws {
        let payload = Data("hello".utf8)
        let frame = try HelperFrameCodec.encode(payload)

        #expect(Array(frame.prefix(4)) == [0, 0, 0, 5])
        #expect(try HelperFrameCodec.decode(frame) == payload)
        #expect(throws: HelperFrameError.envelopeTooLarge) {
            try HelperFrameCodec.encode(Data(count: HelperWireCodec.maximumEnvelopeBytes + 1))
        }
    }

    @Test("identity handshake binds a nonce and returns helper context")
    func identityHandshake() async {
        let channel = HandshakeChannel()
        let outcome = await HelperSessionAuthenticator(channel: channel).authenticate(
            sessionNonce: "fresh-secret",
            now: now
        )
        let request = await channel.request

        #expect(request?.action == .identity)
        #expect(request?.sessionNonce == "fresh-secret")
        #expect(request?.helperDeviceID == "bootstrap")
        #expect(outcome.context?.helperDeviceID == "stable-helper-id")
        #expect(outcome.context?.sessionNonce == "fresh-secret")
    }

    private func makeRequest() -> HelperRequest {
        HelperRequest(
            requestID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            sessionNonce: "session-secret",
            helperDeviceID: "helper-device",
            action: .clipboardRead,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            expiresAt: Date(timeIntervalSince1970: 1_800_000_030),
            payload: [:]
        )
    }
}

private actor HandshakeChannel: HelperRequestSending {
    private(set) var request: HelperRequest?

    func send(_ request: HelperRequest) async throws -> HelperResult {
        self.request = request
        return HelperResult(
            requestID: request.requestID,
            status: .success,
            completedAt: request.createdAt,
            payload: [
                "helperDeviceId": .string("stable-helper-id"),
                "helperVersion": .string("0.1.0"),
                "protocolVersions": .array([.number(1)]),
            ]
        )
    }
}
