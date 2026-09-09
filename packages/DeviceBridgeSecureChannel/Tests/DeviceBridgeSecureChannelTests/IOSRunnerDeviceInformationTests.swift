import Foundation
import Testing
import DeviceBridgeProtocol
@testable import DeviceBridgeSecureChannel

struct IOSRunnerDeviceInformationTests {
    @Test func negotiatesOnlyInstalledHandlerAndReturnsStrictMetadata() async throws {
        let old = try await RunningSession.start()
        #expect(!old.session.allowedActions.contains(.deviceInformation))
        await old.cancel()
        let running = try await RunningSession.start(deviceInformationHandler: MetadataFixture())
        do {
            #expect(running.session.allowedActions.contains(.deviceInformation))
            let result = try await running.send(running.request(.deviceInformation))
            #expect(try DeviceRuntimeInformation(payload: result.payload ?? [:]).processorCount == 6)
            #expect(try await running.send(running.request(.identity)).status == .success)
            _ = try await running.send(running.request(.stop))
            #expect(try await running.task.value == .stopped)
        } catch { await running.cancel(); throw error }
    }
    @Test func heartbeatAndStopBypassSuspendedMetadataAndDiscardLateResult() async throws {
        let gate = MetadataGate()
        let running = try await RunningSession.start(deviceInformationHandler: gate)
        do {
            try await running.host.writeFrame(HelperWireCodec().encode(running.request(.deviceInformation)))
            try await gate.waitUntilEntered()
            #expect(try await running.send(running.request(.identity)).status == .success)
            #expect(try await running.send(running.request(.stop)).status == .success)
            #expect(try await running.task.value == .stopped)
            await gate.release()
            await #expect(throws: (any Error).self) { try await running.host.readFrame(timeout: 1) }
        } catch { await gate.release(); await running.cancel(); throw error }
    }
    @Test func extraRequestKeysAreRejectedBeforeSampling() async throws {
        let gate = MetadataGate()
        let running = try await RunningSession.start(deviceInformationHandler: gate)
        var request = running.request(.deviceInformation); request.payload = ["extra": .null]
        await #expect(throws: (any Error).self) { try await running.send(request) }
        #expect(await gate.entered == false)
        await gate.release(); await running.cancel()
    }
    @Test func invalidSuccessPayloadClosesSession() async throws {
        let running = try await RunningSession.start(deviceInformationHandler: MetadataFixture(invalid: true))
        await #expect(throws: (any Error).self) { try await running.send(running.request(.deviceInformation)) }
        await #expect(throws: IOSRunnerSessionServer.Failure.rejected) { try await running.task.value }
        await running.cancel()
    }
    @Test func metadataSharesContentSlotWithClipboard() async throws {
        let gate = MetadataGate()
        let running = try await RunningSession.start(clipboardHandler: MetadataClipboardFixture(), deviceInformationHandler: gate)
        do {
            try await running.host.writeFrame(HelperWireCodec().encode(running.request(.deviceInformation)))
            try await gate.waitUntilEntered()
            await #expect(throws: (any Error).self) { try await running.send(running.request(.clipboardRead)) }
            await #expect(throws: IOSRunnerSessionServer.Failure.rejected) { try await running.task.value }
            await gate.release(); await running.cancel()
        } catch { await gate.release(); await running.cancel(); throw error }
    }
    @Test func expiredSuspendedMetadataCannotPublish() async throws {
        let gate = MetadataGate()
        let running = try await RunningSession.start(lease: .seconds(3), maximum: .seconds(5), deviceInformationHandler: gate)
        do {
            var request = running.request(.deviceInformation)
            request.expiresAt = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) + 2)
            try await running.host.writeFrame(HelperWireCodec().encode(request))
            try await gate.waitUntilEntered()
            await #expect(throws: (any Error).self) { try await running.host.readFrame(timeout: 2) }
            await #expect(throws: IOSRunnerSessionServer.Failure.rejected) { try await running.task.value }
            await gate.release(); await running.cancel()
        } catch { await gate.release(); await running.cancel(); throw error }
    }
}

private struct MetadataFixture: IOSRunnerDeviceInformationHandling {
    var invalid = false
    func handle(_ request: HelperRequest) async -> HelperResult {
        let payload: [String: JSONValue] = [
            "systemName": .string("iOS"), "systemVersion": .string("26.6"), "modelIdentifier": .string("iPhone17,1"),
            "processorCount": .number(6), "physicalMemoryBytes": .number(8_589_934_592),
            "screenWidthPixels": .null, "screenHeightPixels": .null, "screenWidthPoints": .null, "screenHeightPoints": .null,
            "screenCoordinateBasis": .null, "screenScale": .null, "screenNativeScale": .null, "maximumFramesPerSecond": .null,
            "totalStorageBytes": .null, "availableStorageBytes": .null, "batteryLevel": .null, "batteryState": .string("unknown")]
        return HelperResult(requestID: request.requestID, status: .success, completedAt: Date(), payload: invalid ? [:] : payload)
    }
}
private struct MetadataClipboardFixture: IOSRunnerClipboardHandling {
    func handle(_ request: HelperRequest) async -> HelperResult {
        HelperResult(requestID: request.requestID, status: .success, completedAt: Date(), payload: ["text": .string("fixture")])
    }
}
private actor MetadataGate: IOSRunnerDeviceInformationHandling {
    private var waiting: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    func handle(_ request: HelperRequest) async -> HelperResult {
        entered = true
        await withCheckedContinuation { waiting = $0 }
        return await MetadataFixture().handle(request)
    }
    func waitUntilEntered() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !entered {
            guard ContinuousClock.now < deadline else { throw IOSRunnerSessionServer.Failure.rejected }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    func release() { waiting?.resume(); waiting = nil }
}
