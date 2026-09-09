import XCTest
import DeviceBridgeProtocol
import DeviceBridgeSecureChannel

final class ScreenshotCommandsTests: XCTestCase {
    @MainActor
    func testHandlerReturnsBoundPNGAndDoesNotAttachFailureContent() async {
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==")!
        let request = screenshotRequest()
        let handler = RunnerScreenshotHandler(commands: ScreenshotCommands(screen: ScreenCaptureDouble(result: .success(png))))
        let response = await handler.capture(request)
        XCTAssertEqual(response.result.requestID, request.requestID)
        XCTAssertEqual(response.result.status, .success)
        XCTAssertEqual(response.result.payload, ["mediaType": .string("image/png"), "byteLength": .number(70),
            "sha256": .string("4ff6ab670a58c14270e034e2090d9a432caa263a14e0a25785386b0c12f880b5")])
        XCTAssertEqual(response.pngData, png)
        let failed = await RunnerScreenshotHandler(commands: ScreenshotCommands(screen:
            ScreenCaptureDouble(result: .failure(ScreenCaptureError.protectedContent)))).capture(request)
        XCTAssertEqual(failed.result.status, .failure)
        XCTAssertNil(failed.result.payload)
        XCTAssertNil(failed.pngData)
    }

    @MainActor
    func testHandlerRejectsWrongActionWithoutTouchingScreen() async {
        let screen = ScreenCaptureDouble(result: .success(Data([1])))
        var request = screenshotRequest(); request.action = .clipboardRead
        let result = await RunnerScreenshotHandler(commands: ScreenshotCommands(screen: screen)).capture(request)
        XCTAssertEqual(result.result.status, .invalid)
        XCTAssertNil(result.pngData)
        XCTAssertEqual(screen.calls, 0)
    }

    @MainActor
    func testCancelledCaptureNeverTouchesScreen() async {
        let screen = ScreenCaptureDouble(result: .success(Data([1])))
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return await ScreenshotCommands(screen: screen).capture()
        }
        let result = await task.value
        XCTAssertEqual(result.status, .cancelled)
        XCTAssertNil(result.pngData)
        XCTAssertEqual(screen.calls, 0)
    }

    @MainActor
    func testExpiredCaptureNeverTouchesScreen() async {
        let screen = ScreenCaptureDouble(result: .success(Data([1])))
        let result = await ScreenshotCommands(screen: screen).capture(expiresAt: Date().addingTimeInterval(-1))
        XCTAssertNotEqual(result.status, .success)
        XCTAssertNil(result.pngData)
        XCTAssertEqual(screen.calls, 0)
    }

    @MainActor
    func testCaptureReturnsExactPNGBytes() async {
        let png = Data([137, 80, 78, 71, 13, 10, 26, 10, 1, 2, 3])
        let result = await ScreenshotCommands(screen: ScreenCaptureDouble(result: .success(png)))
            .capture()

        XCTAssertEqual(result.status, .success)
        XCTAssertEqual(result.pngData, png)
        XCTAssertNil(result.code)
    }

    @MainActor
    func testLockedAndProtectedScreensMapToActionableFailures() async {
        let locked = await ScreenshotCommands(
            screen: ScreenCaptureDouble(result: .failure(ScreenCaptureError.deviceLocked))
        ).capture()
        let protected = await ScreenshotCommands(
            screen: ScreenCaptureDouble(result: .failure(ScreenCaptureError.protectedContent))
        ).capture()

        XCTAssertEqual(locked.status, .actionRequired)
        XCTAssertEqual(locked.code, "screenshot.device_locked")
        XCTAssertNil(locked.pngData)
        XCTAssertEqual(protected.status, .failure)
        XCTAssertEqual(protected.code, "screenshot.protected_content")
        XCTAssertNil(protected.pngData)
    }
}

private func screenshotRequest() -> HelperRequest {
    HelperRequest(requestID: UUID(), sessionNonce: "public-fixture", helperDeviceID: "public-fixture",
        action: .screenshotCapture, createdAt: Date(), expiresAt: Date().addingTimeInterval(5), payload: [:])
}

@MainActor
private final class ScreenCaptureDouble: ScreenCapturing {
    let result: Result<Data, Error>
    private(set) var calls = 0

    init(result: Result<Data, Error>) { self.result = result }

    func pngRepresentation() throws -> Data { calls += 1; return try result.get() }
}
