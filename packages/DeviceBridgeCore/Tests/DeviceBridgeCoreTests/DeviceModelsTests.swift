import Foundation
import Testing
@testable import DeviceBridgeCore

@Suite("Device domain model")
struct DeviceModelsTests {
    @Test("identity rejects an empty raw value")
    func identityRejectsEmptyValue() {
        #expect(throws: ModelValidationError.self) {
            _ = try DeviceIdentity(rawValue: "", stability: .stable, platform: .android)
        }
    }

    @Test("identity description exposes only a short suffix")
    func identityDescriptionIsRedacted() throws {
        let identity = try DeviceIdentity(
            rawValue: "private-device-ABCDEF",
            stability: .stable,
            platform: .android
        )

        #expect(identity.displaySuffix == "CDEF")
        #expect(identity.description == "android ••••CDEF")
        #expect(!identity.description.contains("private-device"))
    }

    @Test("transport rejects an empty transport identifier")
    func transportRejectsEmptyIdentifier() throws {
        let identity = try DeviceIdentity(
            rawValue: "device-1",
            stability: .provisional,
            platform: .android
        )

        #expect(throws: ModelValidationError.self) {
            _ = try TransportCandidate(
                id: "",
                identity: identity,
                kind: .usb,
                source: .adb,
                status: .available,
                observedAt: Date(timeIntervalSince1970: 100)
            )
        }
    }

    @Test("session token requires every session field and active operation")
    func tokenPublicationGuardChecksCompleteContext() throws {
        let identity = try DeviceIdentity(
            rawValue: "device-1",
            stability: .stable,
            platform: .iOS
        )
        let session = ConnectionSession(
            deviceIdentity: identity,
            generation: 7,
            transportID: "wired-1",
            state: .active,
            startedAt: Date(timeIntervalSince1970: 100)
        )
        let operationID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let token = SessionToken(
            deviceIdentity: identity,
            transportID: "wired-1",
            sessionGeneration: 7,
            operationID: operationID
        )

        #expect(token.canPublish(in: session, activeOperationIDs: [operationID]))
        #expect(!token.canPublish(in: session, activeOperationIDs: []))

        let replacedSession = ConnectionSession(
            deviceIdentity: identity,
            generation: 8,
            transportID: "wired-1",
            state: .active,
            startedAt: Date(timeIntervalSince1970: 101)
        )
        #expect(!token.canPublish(in: replacedSession, activeOperationIDs: [operationID]))
    }
}
