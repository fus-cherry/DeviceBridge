import Foundation
import Testing
import DeviceBridgeProtocol
@testable import DeviceBridgeCore

@Suite("Screenshot staging and publication")
struct ScreenshotServiceTests {
    @Test("broken iOS transfer and closed session have distinct recovery categories",
        arguments: [(IOSRunnerChannel.Failure.invalidReply, OperationFailureCode.malformedOutput),
                    (.unavailable, .disconnected)])
    func iosChannelFailureCategories(_ failure: IOSRunnerChannel.Failure,
                                    _ expected: OperationFailureCode) async throws {
        let fixture = try await Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let service = ScreenshotService(store: fixture.store,
            provider: RejectedIOSChannelScreenshot(failure: failure), sessionDirectory: fixture.directory)
        #expect(await service.capture().failure?.code == expected)
        #expect(await service.currentArtifact == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).isEmpty)
    }

    @Test("iOS screenshot failures retain actionable categories without publishing a file",
        arguments: [(HelperResultStatus.permissionDenied, OperationFailureCode.permissionDenied),
                    (.actionRequired, .restricted), (.cancelled, .cancelled),
                    (.expired, .timeout), (.invalid, .malformedOutput), (.failure, .failure)])
    func iosFailureCategories(_ status: HelperResultStatus, _ expected: OperationFailureCode) async throws {
        let fixture = try await Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let service = ScreenshotService(store: fixture.store,
            provider: RejectedIOSScreenshot(status: status), sessionDirectory: fixture.directory)
        let outcome = await service.capture()
        #expect(outcome.failure?.code == expected)
        #expect(await service.currentArtifact == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).isEmpty)
        // The failed request must release the single operation slot, not leave capture busy.
        let next = try await fixture.store.beginOperation(.screenshot)
        await fixture.store.finishOperation(next)
    }

    @Test("only a valid nonzero PNG publishes exact provider bytes")
    func validPNGPublishes() async throws {
        let fixture = try await Fixture.make()
        let png = makePNG(width: 3, height: 2, marker: 0x31)
        let provider = ScreenshotProviderDouble(responses: [.data(png)])
        let service = ScreenshotService(
            store: fixture.store,
            provider: provider,
            sessionDirectory: fixture.directory
        )

        let outcome = await service.capture()
        let artifact = outcome.artifact

        #expect(artifact?.sourceDevice == fixture.first.identity)
        #expect(artifact?.byteLength == png.count)
        #expect(try artifact.map { try Data(contentsOf: $0.sessionURL) } == png)
        #expect(await service.currentArtifact == artifact)
        #expect(try partialFiles(in: fixture.directory).isEmpty)
    }

    @Test("invalid capture preserves the previous valid preview and removes partial files")
    func failurePreservesPreview() async throws {
        let fixture = try await Fixture.make()
        let firstPNG = makePNG(width: 1, height: 1, marker: 0x41)
        let provider = ScreenshotProviderDouble(responses: [
            .data(firstPNG),
            .data(Data("not a png".utf8)),
        ])
        let service = ScreenshotService(
            store: fixture.store,
            provider: provider,
            sessionDirectory: fixture.directory
        )
        let first = await service.capture().artifact

        let failed = await service.capture()

        #expect(failed.failure?.code == .malformedOutput)
        #expect(await service.currentArtifact == first)
        #expect(try partialFiles(in: fixture.directory).isEmpty)
    }

    @Test("provider cancellation is terminal and publishes no file")
    func cancellation() async throws {
        let fixture = try await Fixture.make()
        let provider = ScreenshotProviderDouble(responses: [.cancelled])
        let service = ScreenshotService(
            store: fixture.store,
            provider: provider,
            sessionDirectory: fixture.directory
        )

        let outcome = await service.capture()

        #expect(outcome.failure?.code == .cancelled)
        #expect(await service.currentArtifact == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).isEmpty)
    }

    @Test("device switch rejects late bytes and removes staging output")
    func switchRejectsLateCapture() async throws {
        let fixture = try await Fixture.make(includeSecondDevice: true)
        let provider = SuspendingScreenshotProvider()
        let service = ScreenshotService(
            store: fixture.store,
            provider: provider,
            sessionDirectory: fixture.directory
        )

        let task = Task { await service.capture() }
        while !(await provider.hasRequest) { await Task.yield() }
        _ = try await fixture.store.select(fixture.second!.identity)
        await provider.resume(with: makePNG(width: 2, height: 2, marker: 0x51))

        #expect(await task.value == .stale)
        #expect(await service.currentArtifact == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).isEmpty)
    }

    @Test("ending a session removes its retained screenshot bytes")
    func sessionCleanup() async throws {
        let fixture = try await Fixture.make()
        let provider = ScreenshotProviderDouble(responses: [
            .data(makePNG(width: 1, height: 1, marker: 0x61)),
        ])
        let service = ScreenshotService(
            store: fixture.store,
            provider: provider,
            sessionDirectory: fixture.directory
        )
        #expect(await service.capture().artifact != nil)

        await service.clearSessionArtifacts()

        #expect(await service.currentArtifact == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.path))
    }

    private func partialFiles(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.contains(".partial.") }
    }

    private func makePNG(width: UInt32, height: UInt32, marker: UInt8) -> Data {
        var bytes: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
        bytes += [0, 0, 0, 13]
        bytes += Array("IHDR".utf8)
        bytes += [
            UInt8(width >> 24), UInt8(width >> 16), UInt8(width >> 8), UInt8(width),
            UInt8(height >> 24), UInt8(height >> 16), UInt8(height >> 8), UInt8(height),
            8, 6, 0, 0, 0,
        ]
        bytes += [0, 0, 0, marker]
        return Data(bytes)
    }
}

private struct RejectedIOSScreenshot: ScreenshotProviding {
    let status: HelperResultStatus
    func capture(transportID: String) async throws -> ScreenshotCapturePayload {
        throw IOSRunnerChannel.ScreenshotFailure.status(status)
    }
}

private struct RejectedIOSChannelScreenshot: ScreenshotProviding {
    let failure: IOSRunnerChannel.Failure
    func capture(transportID: String) async throws -> ScreenshotCapturePayload { throw failure }
}

private struct Fixture {
    let store: DeviceSessionStore
    let first: DeviceRecord
    let second: DeviceRecord?
    let directory: URL

    static func make(includeSecondDevice: Bool = false) async throws -> Fixture {
        let store = DeviceSessionStore()
        let first = try Self.device(id: "first", transport: "transport-1")
        let second = includeSecondDevice ? try Self.device(id: "second", transport: "transport-2") : nil
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "screenshot-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let devices = [first, second].compactMap { $0 }
        await store.replaceInventory(devices)
        _ = try await store.select(first.identity)
        return Fixture(store: store, first: first, second: second, directory: directory)
    }

    private static func device(id: String, transport: String) throws -> DeviceRecord {
        let identity = try DeviceIdentity(rawValue: id, stability: .stable, platform: .android)
        let candidate = try TransportCandidate(
            id: transport,
            identity: identity,
            kind: .usb,
            source: .adb,
            status: .available,
            observedAt: Date()
        )
        return DeviceRecord(
            identity: identity,
            name: id,
            authorization: .authorized,
            candidates: [candidate],
            preferredTransportID: transport
        )
    }
}

private actor ScreenshotProviderDouble: ScreenshotProviding {
    enum Response: Sendable {
        case data(Data)
        case cancelled
    }

    private var responses: [Response]

    init(responses: [Response]) { self.responses = responses }

    func capture(transportID: String) async throws -> ScreenshotCapturePayload {
        switch responses.removeFirst() {
        case let .data(data): ScreenshotCapturePayload(data: data, capturedAt: Date())
        case .cancelled: throw CancellationError()
        }
    }
}

private actor SuspendingScreenshotProvider: ScreenshotProviding {
    private var continuation: CheckedContinuation<ScreenshotCapturePayload, Never>?
    var hasRequest: Bool { continuation != nil }

    func capture(transportID: String) async throws -> ScreenshotCapturePayload {
        await withCheckedContinuation { continuation = $0 }
    }

    func resume(with data: Data) {
        continuation?.resume(returning: ScreenshotCapturePayload(data: data, capturedAt: Date()))
        continuation = nil
    }
}
