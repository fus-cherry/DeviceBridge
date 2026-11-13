import AppKit
import XCTest

/// Native macOS sheets driven with real input. The explicit fixture provider is
/// confined to a fresh test directory and never invokes a device command.
final class FileTransferDialogUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor
    func testSendPickerCancellationAndAPKRequiresFinalConsent() throws {
        let root = try fixture()
        let app = launch(root)
        click("files-send", app, twice: true)
        let first = picker(app)
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "open-panel").count, 1,
                       "A real double click must not create duplicate file pickers")
        XCTAssertEqual(try events(root).count, 0)
        app.typeKey(.escape, modifierFlags: [])
        dismissed(first)
        XCTAssertEqual(try events(root).count, 0)
        XCTAssertTrue(app.buttons["files-send"].isEnabled)

        click("files-send", app)
        choose(root.appendingPathComponent("sample.apk"), app: app)
        let cancelled = consent("Copy file", app)
        XCTAssertEqual(try events(root).count, 0, "Choosing an APK must not send before explicit copy consent")
        XCTAssertEqual(app.windows.sheets.containing(.button, identifier: "Copy file").count, 1)
        cancelled.buttons["Cancel"].click()
        dismissed(cancelled)
        XCTAssertEqual(try events(root).count, 0)

        click("files-send", app)
        choose(root.appendingPathComponent("sample.apk"), app: app)
        let approved = consent("Copy file", app)
        XCTAssertEqual(try events(root).count, 0)
        record("apk-copy-awaiting-explicit-consent")
        approved.buttons["Copy file"].click()
        dismissed(approved)
        try waitForEvents(1, root: root)
        let event = try XCTUnwrap(events(root).first)
        XCTAssertEqual(event["operation"], "send")
        XCTAssertEqual(event["fileName"], "sample.apk")
        XCTAssertEqual(event["transportID"], "UI-HARMONY")
        XCTAssertTrue(app.staticTexts["files-feedback"].waitForExistence(timeout: 5))
        XCTAssertEqual(try events(root).count, 1, "One consent must produce exactly one fixture send")
    }

    @MainActor
    func testReceiveSavePanelCancellationThenWritesOnlyFixtureDestination() throws {
        let root = try fixture()
        let app = launch(root)
        let relativePath = app.textFields["files-relative-path"]
        reveal(relativePath, app)
        replace(relativePath, "received.txt")
        click("files-receive", app)
        let cancelled = picker(app, save: true)
        app.typeKey(.escape, modifierFlags: [])
        dismissed(cancelled)
        XCTAssertEqual(try events(root).count, 0)
        let output = root.appendingPathComponent("received.txt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))

        click("files-receive", app)
        choose(root, app: app, save: true)
        try waitForEvents(1, root: root)
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? Data(contentsOf: output)) == Data("Fixture file from device\n".utf8)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 5), .completed)
        XCTAssertEqual(try Data(contentsOf: output), Data("Fixture file from device\n".utf8))
        let event = try XCTUnwrap(events(root).first)
        XCTAssertEqual(event["operation"], "receive")
        XCTAssertEqual(event["relativePath"], "received.txt")
        XCTAssertEqual(event["transportID"], "UI-HARMONY")
        XCTAssertEqual(try events(root).count, 1)
        record("receive-completed-in-isolated-fixture")
    }

    @MainActor
    func testHAPPickerAndInstallConsentCancellationNeverInvokeInstaller() throws {
        let root = try fixture()
        let app = launch(root)
        click("files-install-hap", app)
        let cancelledPicker = picker(app)
        app.typeKey(.escape, modifierFlags: [])
        dismissed(cancelledPicker)
        XCTAssertEqual(try events(root).count, 0)

        click("files-install-hap", app)
        choose(root.appendingPathComponent("sample.hap"), app: app)
        let cancelled = consent("Install or update", app)
        XCTAssertEqual(try events(root).count, 0)
        XCTAssertEqual(app.windows.sheets.containing(.button, identifier: "Install or update").count, 1)
        cancelled.buttons["Cancel"].click()
        dismissed(cancelled)
        XCTAssertEqual(try events(root).count, 0, "Cancelled installation must never reach even the fake installer")

        click("files-install-hap", app)
        choose(root.appendingPathComponent("sample.hap"), app: app)
        let approved = consent("Install or update", app)
        XCTAssertEqual(try events(root).count, 0)
        approved.buttons["Install or update"].click()
        dismissed(approved)
        try waitForEvents(1, root: root)
        let failure = app.staticTexts["files-install-feedback"]
        let failed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            failure.exists && self.text(failure).contains("Fixture installer stopped before any device action.")
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [failed], timeout: 5), .completed)
        let event = try XCTUnwrap(events(root).first)
        XCTAssertEqual(event["operation"], "install")
        XCTAssertEqual(event["fileName"], "sample.hap")
        XCTAssertEqual(event["transportID"], "UI-HARMONY")
        XCTAssertEqual(try events(root).count, 1)
        record("fake-installer-explicitly-stopped-without-device-action")
    }

    @MainActor
    func testDeviceSwitchInAnotherWindowCancelsPendingFilePicker() throws {
        let root = try fixture()
        let app = launch(root)
        click("files-send", app)
        let pending = picker(app)
        XCTAssertEqual(try events(root).count, 0)

        // A native sheet blocks only its owning window. Open another real
        // Workspace window and change the shared selection through its sidebar.
        let previousWindowCount = app.windows.count
        app.typeKey("n", modifierFlags: .command)
        let opened = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.windows.count > previousWindowCount
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [opened], timeout: 5), .completed,
                       "New Window must remain available while a file sheet is pending")
        let newWindow = app.windows.firstMatch
        let sidebar = newWindow.scrollViews["device-sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(newWindow.descendants(matching: .any).matching(identifier: "open-panel").firstMatch.exists,
                       "Device switching must occur in the new window, not behind the old modal sheet")
        let android = sidebar.buttons["Android Test Device"]
        XCTAssertTrue(android.waitForExistence(timeout: 5), newWindow.debugDescription)
        XCTAssertTrue(android.isHittable, "The second window must accept real sidebar input")
        android.click()
        dismissed(pending)
        let header = newWindow.staticTexts["selected-device-header"]
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            header.exists && self.text(header).contains("Android Test Device")
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 5), .completed)
        XCTAssertEqual(try events(root).count, 0,
                       "Changing device must invalidate the old picker without sending to either device")
        record("second-window-device-switch-cancelled-pending-picker")
    }

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DeviceBridge-FileDialogs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("Fixture APK, not executable\n".utf8).write(to: root.appendingPathComponent("sample.apk"))
        try Data("Fixture HAP, not executable\n".utf8).write(to: root.appendingPathComponent("sample.hap"))
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    @MainActor
    private func launch(_ root: URL) -> XCUIApplication {
        let suite = "dev.debugutility.file-dialog-test.\(UUID().uuidString)"
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--fixture-devices", "--fixture-sidebar", "--fixture-file-dialogs",
                               "--fixture-file-dialog-root", root.path, "--language-test-suite", suite, "--fixture-language", "en"]
        addTeardownBlock { @MainActor in
            app.terminate()
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
        app.launch()
        app.activate()
        let sidebar = app.scrollViews["device-sidebar"]
        if !sidebar.waitForExistence(timeout: 2) {
            app.typeKey("n", modifierFlags: .command)
            app.activate()
        }
        XCTAssertTrue(sidebar.waitForExistence(timeout: 10), app.debugDescription)
        let harmony = sidebar.buttons["device-row-harmonyos:UI-HARMONY"]
        XCTAssertTrue(harmony.waitForExistence(timeout: 5), app.debugDescription)
        harmony.click()
        XCTAssertTrue(app.buttons["module-files"].waitForExistence(timeout: 5))
        app.buttons["module-files"].click()
        let identifier = app.textFields["files-scope-identifier"]
        XCTAssertTrue(identifier.waitForExistence(timeout: 5), app.debugDescription)
        reveal(identifier, app)
        replace(identifier, "100")
        return app
    }

    private func events(_ root: URL) throws -> [[String: String]] {
        let file = root.appendingPathComponent("file-dialog-events.jsonl")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: String])
        }
    }

    private func waitForEvents(_ count: Int, root: URL) throws {
        let recorded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? self.events(root).count) == count
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [recorded], timeout: 5), .completed)
        XCTAssertEqual(try events(root).count, count)
    }

    @MainActor
    private func picker(_ app: XCUIApplication, save: Bool = false) -> XCUIElement {
        let panel = app.descendants(matching: .any).matching(identifier: save ? "file-transfer-save-panel" : "open-panel").firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 5), app.debugDescription)
        return panel
    }

    @MainActor
    private func choose(_ url: URL, app: XCUIApplication, save: Bool = false) {
        let panel = picker(app, save: save)
        app.typeKey("g", modifierFlags: [.command, .shift])
        app.typeKey("a", modifierFlags: .command)
        app.typeText(url.path)
        app.typeKey(.return, modifierFlags: [])
        record(save ? "native-save-before-default-action" : "native-open-before-default-action")
        // Real native default action; never poll XPC button flags or frames.
        app.typeKey(.return, modifierFlags: [])
        dismissed(panel)
    }

    @MainActor
    private func consent(_ action: String, _ app: XCUIApplication) -> XCUIElement {
        let sheet = app.windows.sheets.containing(.button, identifier: action).firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), app.debugDescription)
        return sheet
    }

    @MainActor
    private func dismissed(_ element: XCUIElement) {
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !element.exists }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 10), .completed)
    }

    @MainActor
    private func click(_ id: String, _ app: XCUIApplication, twice: Bool = false) {
        let button = app.buttons[id]
        reveal(button, app)
        XCTAssertTrue(button.isEnabled, button.debugDescription)
        if twice { button.doubleClick() } else { button.click() }
    }

    @MainActor
    private func reveal(_ element: XCUIElement, _ app: XCUIApplication) {
        let scroll = app.scrollViews["device-workspace-scroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 5))
        for _ in 0..<14 {
            var deltaY: CGFloat = -260
            if element.exists {
                let viewport = scroll.frame
                let target = element.frame
                if element.isHittable && viewport.contains(target) { return }
                if target.maxY > viewport.maxY {
                    deltaY = -min(320, max(80, target.maxY - viewport.maxY + 20))
                } else if target.minY < viewport.minY {
                    deltaY = min(320, max(80, viewport.minY - target.minY + 20))
                }
            }
            scroll.scroll(byDeltaX: 0, deltaY: deltaY)
        }
        XCTFail("File control must be fully visible: \(element.debugDescription)")
    }

    @MainActor
    private func replace(_ element: XCUIElement, _ value: String) {
        element.click()
        element.typeKey("a", modifierFlags: .command)
        element.typeText(value)
    }

    @MainActor
    private func text(_ element: XCUIElement) -> String { (element.value as? String) ?? element.label }

    @MainActor
    private func record(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
