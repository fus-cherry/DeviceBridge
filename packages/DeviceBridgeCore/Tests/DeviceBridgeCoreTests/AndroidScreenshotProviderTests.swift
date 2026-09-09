import Foundation
import Testing
@testable import DeviceBridgeCore

@Suite("Android screenshot provider")
struct AndroidScreenshotProviderTests {
    @Test("capture targets the selected ADB transport and preserves PNG bytes")
    func targetedCapture() async throws {
        let png = Data([137, 80, 78, 71, 13, 10, 26, 10, 1, 2, 3])
        let runner = ScreenshotCommandRunner(result: HostCommandResult(
            exitCode: 0,
            standardOutput: png,
            standardError: Data()
        ))
        let provider = AndroidScreenshotProvider(
            adbURL: URL(fileURLWithPath: "/sdk/adb"),
            runner: runner
        )

        let payload = try await provider.capture(transportID: "42")
        let request = await runner.request

        #expect(payload.data == png)
        #expect(request?.arguments == ["-t", "42", "exec-out", "screencap", "-p"])
        #expect(request?.maximumOutputBytes == 64 * 1_024 * 1_024)
    }

    @Test("nonzero and empty output are never returned as captures")
    func invalidResults() async {
        let nonzero = AndroidScreenshotProvider(
            adbURL: URL(fileURLWithPath: "/adb"),
            runner: ScreenshotCommandRunner(result: HostCommandResult(
                exitCode: 1,
                standardOutput: Data(),
                standardError: Data("safe failure".utf8)
            ))
        )
        let empty = AndroidScreenshotProvider(
            adbURL: URL(fileURLWithPath: "/adb"),
            runner: ScreenshotCommandRunner(result: HostCommandResult(
                exitCode: 0,
                standardOutput: Data(),
                standardError: Data()
            ))
        )

        await #expect(throws: AndroidScreenshotProviderError.captureFailed) {
            try await nonzero.capture(transportID: "1")
        }
        await #expect(throws: AndroidScreenshotProviderError.emptyOutput) {
            try await empty.capture(transportID: "2")
        }
    }
}

private actor ScreenshotCommandRunner: HostCommandRunning {
    private(set) var request: HostCommandRequest?
    let result: HostCommandResult

    init(result: HostCommandResult) { self.result = result }

    func run(_ request: HostCommandRequest) async throws -> HostCommandResult {
        self.request = request
        return result
    }
}
