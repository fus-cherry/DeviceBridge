import Foundation
import Testing
import DeviceBridgeProtocol

@Suite("Standalone shared helper wire contract")
struct SharedProtocolTests {
    @Test("a Foundation-only consumer decodes Android request keys and round-trips mixed JSON payloads")
    func independentConsumer() throws {
        let fixture = Data("""
        {"protocolVersion":1,"requestId":"11111111-1111-1111-1111-111111111111",\
        "sessionNonce":"public-fixture","helperDeviceId":"public-helper","action":"clipboard.write",\
        "createdAt":"2027-01-15T08:00:00Z","expiresAt":"2027-01-15T08:00:30Z",\
        "payload":{"text":"你好","sensitive":true,"count":2,"optional":null,"nested":[false,{"name":"fixture"}]}}
        """.utf8)
        let codec = HelperWireCodec()
        let request = try codec.decodeRequest(fixture)
        #expect(request.action == .clipboardWrite)
        #expect(request.requestID == UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        #expect(request.createdAt == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(request.payload == [
            "text": .string("你好"), "sensitive": .bool(true), "count": .number(2),
            "optional": .null, "nested": .array([.bool(false), .object(["name": .string("fixture")])]),
        ])
        let roundTrip = try HelperFrameCodec.decode(HelperFrameCodec.encode(codec.encode(request)))
        #expect(try JSONSerialization.jsonObject(with: roundTrip) as? NSDictionary == JSONSerialization.jsonObject(with: fixture) as? NSDictionary)
    }

    @Test("shared framing preserves complete-frame and existing empty-frame boundaries")
    func frameBoundaries() throws {
        #expect(try HelperFrameCodec.encode(Data()) == Data([0, 0, 0, 0]))
        #expect(try HelperFrameCodec.decode(Data([0, 0, 0, 0])) == Data())
        #expect(throws: HelperFrameError.invalidHeader) { try HelperFrameCodec.decode(Data([0, 0, 0])) }
        #expect(throws: HelperFrameError.invalidLength) { try HelperFrameCodec.decode(Data([0, 0, 0, 2, 42])) }
        #expect(throws: HelperFrameError.invalidLength) { try HelperFrameCodec.decode(Data([0, 0, 0, 1, 42, 43])) }
        #expect(throws: HelperFrameError.envelopeTooLarge) { try HelperFrameCodec.decode(Data([0, 97, 0, 1])) }
        let largest = Data(repeating: 42, count: 6_356_992)
        #expect(try HelperFrameCodec.decode(HelperFrameCodec.encode(largest)) == largest)
        #expect(throws: HelperFrameError.envelopeTooLarge) { try HelperFrameCodec.encode(Data(count: 6_356_993)) }
    }

    @Test("the standalone validator owns replay completion with unchanged size precedence")
    func replayOwnership() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let request = HelperRequest(requestID: UUID(), sessionNonce: "public-fixture", helperDeviceID: "public-helper", action: .identity, createdAt: now, expiresAt: now.addingTimeInterval(30), payload: [:])
        let validator = HelperRequestValidator(sessionNonce: "public-fixture", helperDeviceID: "public-helper")
        #expect(await validator.validate(request, encodedByteCount: 6_356_992, now: now) == .accepted)
        await validator.markCompleted(request.requestID)
        #expect(await validator.validate(request, encodedByteCount: 6_356_992, now: now) == .rejected(.replayed))
        #expect(await validator.validate(request, encodedByteCount: 6_356_993, now: now) == .rejected(.envelopeTooLarge))
    }
}
