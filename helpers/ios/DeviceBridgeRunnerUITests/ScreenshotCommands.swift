import Foundation
import XCTest
import DeviceBridgeProtocol
import DeviceBridgeSecureChannel

@MainActor
final class RunnerScreenshotHandler: IOSRunnerScreenshotHandling {
    private let commands: ScreenshotCommands
    init(commands: ScreenshotCommands = ScreenshotCommands()) { self.commands = commands }
    func capture(_ request: HelperRequest) async -> IOSRunnerScreenshotResult {
        guard request.action == .screenshotCapture, request.payload.isEmpty else {
            return failure(request, .invalid, "screenshot.invalid", "Invalid screenshot request.")
        }
        let remaining = request.expiresAt.timeIntervalSinceNow
        let deadline = ContinuousClock.now.advanced(by: .seconds(remaining.isFinite ? max(0, min(30, remaining)) : 0))
        func check() throws {
            try Task.checkCancellation()
            guard remaining.isFinite, Date() < request.expiresAt, ContinuousClock.now < deadline else { throw ScreenCaptureError.expired }
        }
        do {
            try check()
            let captured = await commands.capture(expiresAt: request.expiresAt)
            let capturedAt = Date()
            try check()
            switch captured.status {
            case .success:
                guard let png = captured.pngData else { throw IOSRunnerScreenshotWire.Failure.rejected }
                let descriptor = try IOSRunnerScreenshotWire.descriptor(for: png)
                try check()
                return IOSRunnerScreenshotResult(result: HelperResult(requestID: request.requestID, status: .success,
                    completedAt: capturedAt, payload: descriptor.payload), pngData: png)
            case .actionRequired:
                return failure(request, .actionRequired, "screenshot.device_locked", "Unlock the phone and retry.")
            case .cancelled:
                return failure(request, .cancelled, "screenshot.interrupted", "Screenshot capture was interrupted.")
            case .expired:
                throw ScreenCaptureError.expired
            case .failure:
                let protected = captured.code == "screenshot.protected_content"
                return failure(request, .failure, protected ? "screenshot.protected_content" : "screenshot.capture_failed",
                    protected ? "Protected content cannot be captured." : "The screenshot could not be captured.")
            }
        } catch is CancellationError {
            return failure(request, .cancelled, "screenshot.interrupted", "Screenshot capture was interrupted.")
        } catch ScreenCaptureError.expired {
            return failure(request, .expired, "screenshot.expired", "The screenshot request expired.")
        } catch {
            return failure(request, .failure, "screenshot.invalid_image", "The screenshot was not a valid bounded PNG.")
        }
    }

    private func failure(_ request: HelperRequest, _ status: HelperResultStatus,
                         _ code: String, _ message: String) -> IOSRunnerScreenshotResult {
        IOSRunnerScreenshotResult(result: HelperResult(requestID: request.requestID, status: status,
            completedAt: Date(), error: HelperErrorPayload(code: code, message: message)))
    }
}

enum ScreenshotCommandStatus: String, Sendable {
    case success
    case actionRequired
    case cancelled
    case failure
    case expired
}

enum ScreenCaptureError: Error {
    case deviceLocked
    case protectedContent
    case interrupted
    case expired
}

struct ScreenshotCommandResult: Sendable {
    let status: ScreenshotCommandStatus
    let pngData: Data?
    let code: String?
    let safeMessage: String?
}

@MainActor
protocol ScreenCapturing: AnyObject {
    func pngRepresentation() throws -> Data
}

@MainActor
final class XCUIScreenCapture: ScreenCapturing {
    func pngRepresentation() throws -> Data {
        XCUIScreen.main.screenshot().pngRepresentation
    }
}

@MainActor
final class ScreenshotCommands {
    private let screen: any ScreenCapturing

    init(screen: any ScreenCapturing = XCUIScreenCapture()) {
        self.screen = screen
    }

    func capture(expiresAt: Date = Date().addingTimeInterval(30)) async -> ScreenshotCommandResult {
        let remaining = expiresAt.timeIntervalSinceNow
        let deadline = ContinuousClock.now.advanced(by: .seconds(remaining.isFinite ? max(0, min(30, remaining)) : 0))
        func check() throws {
            try Task.checkCancellation()
            guard remaining.isFinite, Date() < expiresAt, ContinuousClock.now < deadline else { throw ScreenCaptureError.expired }
        }
        do {
            try check()
            let data = try screen.pngRepresentation()
            try check()
            guard !data.isEmpty else {
                return failure(
                    code: "screenshot.empty",
                    message: "The runner returned an empty screenshot."
                )
            }
            return ScreenshotCommandResult(
                status: .success,
                pngData: data,
                code: nil,
                safeMessage: nil
            )
        } catch ScreenCaptureError.expired {
            return ScreenshotCommandResult(status: .expired, pngData: nil, code: "screenshot.expired",
                safeMessage: "The screenshot request expired.")
        } catch ScreenCaptureError.deviceLocked {
            return ScreenshotCommandResult(
                status: .actionRequired,
                pngData: nil,
                code: "screenshot.device_locked",
                safeMessage: "Unlock the device and retry the screenshot."
            )
        } catch ScreenCaptureError.protectedContent {
            return failure(
                code: "screenshot.protected_content",
                message: "Protected content cannot be captured."
            )
        } catch ScreenCaptureError.interrupted, is CancellationError {
            return ScreenshotCommandResult(
                status: .cancelled,
                pngData: nil,
                code: "screenshot.interrupted",
                safeMessage: "Screenshot capture was interrupted."
            )
        } catch {
            return failure(
                code: "screenshot.capture_failed",
                message: "The runner could not capture the screen."
            )
        }
    }

    private func failure(code: String, message: String) -> ScreenshotCommandResult {
        ScreenshotCommandResult(
            status: .failure,
            pngData: nil,
            code: code,
            safeMessage: message
        )
    }
}
