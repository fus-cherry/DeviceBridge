// Test fixture only. Normal Debug/Release builds do not define this compilation condition.
#if DEVICEBRIDGE_CLIPBOARD_SOURCE_PROBE
import UIKit

@MainActor
enum ClipboardSourceProbe {
    private static var started = false

    static func run() async {
        let arguments = ProcessInfo.processInfo.arguments
        guard let rawIdentifier = arguments.last, let identifier = UUID(uuidString: rawIdentifier) else { return }
        record("entered", identifier: identifier)
        guard !started, arguments.count == 3,
              ["--devicebridge-clipboard-source", "--devicebridge-clipboard-source-multiple"].contains(arguments[1]) else { return }
        let multipleItems = arguments[1] == "--devicebridge-clipboard-source-multiple"
        record("arguments-valid", identifier: identifier)
        started = true
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while UIApplication.shared.applicationState != .active {
            guard !Task.isCancelled, ContinuousClock.now < deadline else { return }
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
        }
        guard !Task.isCancelled, ContinuousClock.now < deadline else { return }
        record("active", identifier: identifier)
        // Explicitly authorized disposable replacement. The public launch arguments and
        // receipt contain no clipboard data. No restoration or privacy approval is attempted.
        let texts = multipleItems ? ["第一项 📋", "", "second\nline", "শেষ"]
            : ["DeviceBridge separate Host source · 跨应用 📋\n2026-09-08"]
        UIPasteboard.general.setItems(texts.map { [UIPasteboard.typeAutomatic: $0] }, options: [.localOnly: true])
        record("written", identifier: identifier)
        guard UIApplication.shared.applicationState == .active,
              UIPasteboard.general.strings == texts else { return }
        record("source-ready", identifier: identifier)
    }

    private static func record(_ stage: String, identifier: UUID) {
        do {
            let directory = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true).appendingPathComponent("DeviceBridgeClipboardProbe", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(stage.utf8).write(to: directory.appendingPathComponent(identifier.uuidString + ".ready"),
                options: .atomic)
        } catch {
            // A missing receipt fails source setup; no retry of the clipboard mutation.
        }
    }
}
#endif
