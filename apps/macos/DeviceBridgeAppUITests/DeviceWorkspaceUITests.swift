import AppKit
import XCTest

final class DeviceWorkspaceUITests: XCTestCase {
    /// Opt-in diagnosis of the shipped app. No fixture mode, clipboard read/write or VM start.
    @MainActor
    func testOptedInLiveIOSPreparation() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["DEVICEBRIDGE_UI_LIVE_IOS"] == "1",
              let path = environment["DEVICEBRIDGE_UI_APP_PATH"],
              let phone = environment["DEVICEBRIDGE_UI_PHONE_NAME"] else {
            throw XCTSkip("Explicit app path and designated iPhone required")
        }
        continueAfterFailure = false
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "dev.debugutility.DeviceBridge")
        XCTAssertEqual(running.count, 1, "Exactly one target instance required; do not launch or terminate another copy")
        XCTAssertEqual(running.first?.bundleURL?.standardizedFileURL.path,
                       URL(fileURLWithPath: path).standardizedFileURL.path, "Running app path differs from opt-in target")
        print("LIVE_IOS_TARGET_PID: \(running.first!.processIdentifier)")
        let app = XCUIApplication(url: URL(fileURLWithPath: path))
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10), "Target app window unavailable")
        let row = app.buttons[phone]
        XCTAssertTrue(row.waitForExistence(timeout: 20), "Designated phone row unavailable")
        row.click()
        let screenshotModule = app.buttons["module-screenshot"]
        XCTAssertTrue(screenshotModule.waitForExistence(timeout: 20), "Phone selection did not show tools")
        screenshotModule.click()
        let capture = app.buttons["screenshot-capture"]
        XCTAssertTrue(capture.waitForExistence(timeout: 10), "Screenshot action unavailable")
        let deadline = Date().addingTimeInterval(330)
        var lastStatus = ""
        while Date() < deadline {
            guard app.state != .notRunning else {
                XCTFail("Target app exited during preparation; last state: \(lastStatus)")
                return
            }
            let status = app.staticTexts["screenshot-readiness"]
            if status.exists {
                let value = status.value as? String ?? status.label
                if value != lastStatus {
                    lastStatus = value
                    print("LIVE_IOS_SCREENSHOT_STATE: \(value)")
                }
            }
            if capture.exists && capture.isEnabled { break }
            RunLoop.current.run(until: Date().addingTimeInterval(2))
        }
        // Read only app-owned preparation advice, never clipboard fields or arbitrary content.
        let advice = app.staticTexts.matching(NSPredicate(format:
            "label CONTAINS[c] 'runner' OR label CONTAINS '辅助程序' OR label CONTAINS '签名' OR label CONTAINS 'Team ID' OR label CONTAINS 'Xcode'"))
        for item in advice.allElementsBoundByIndex { print("LIVE_IOS_PREPARATION_ADVICE: \(item.label)") }
        XCTAssertTrue(capture.exists && capture.isEnabled, "Physical screenshot runner never became ready; last state: \(lastStatus)")
        app.buttons["module-clipboard"].click()
        let clipboardStatus = app.staticTexts["clipboard-readiness"]
        if clipboardStatus.exists { print("LIVE_IOS_CLIPBOARD_STATE: \(clipboardStatus.value as? String ?? clipboardStatus.label)") }
        let read = app.buttons["clipboard-read"]
        print("LIVE_IOS_CLIPBOARD_ENABLED: \(read.exists && read.isEnabled)")
        XCTAssertTrue(read.exists && read.isEnabled, "Physical clipboard runner unavailable")
        app.buttons["module-screenshot"].click()
        capture.click()
        XCTAssertTrue(app.images["screenshot-preview"].waitForExistence(timeout: 15), "Physical screenshot did not publish a preview")
    }

    /// Requires explicit authorization to replace the phone's clipboard with public text.
    @MainActor
    func testOptedInLiveIOSClipboardRoundTrip() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["DEVICEBRIDGE_UI_LIVE_IOS"] == "1",
              environment["DEVICEBRIDGE_UI_CLIPBOARD_REPLACE"] == "1",
              let path = environment["DEVICEBRIDGE_UI_APP_PATH"] else {
            throw XCTSkip("Explicit public clipboard replacement and running app path required")
        }
        continueAfterFailure = false
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "dev.debugutility.DeviceBridge")
        XCTAssertEqual(running.count, 1)
        XCTAssertEqual(running.first?.bundleURL?.standardizedFileURL.path, URL(fileURLWithPath: path).standardizedFileURL.path)
        let app = XCUIApplication(url: URL(fileURLWithPath: path))
        app.activate()
        let module = app.buttons["module-clipboard"]
        XCTAssertTrue(module.waitForExistence(timeout: 10))
        module.click()
        let editor = app.textViews["clipboard-editor"]
        let send = app.buttons["clipboard-send"]
        let read = app.buttons["clipboard-read"]
        XCTAssertTrue(send.exists && send.isEnabled && read.exists && read.isEnabled)
        let fixture = "DeviceBridge-public-20260908-" + UUID().uuidString + "\nsecond-line-123"
        // Do not inspect the prior editor or phone clipboard; replace only with authorized text.
        editor.click()
        editor.typeKey("a", modifierFlags: .command)
        editor.typeText(fixture)
        send.click()
        let feedback = app.staticTexts["clipboard-feedback"]
        let sent = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            feedback.exists && ["Sent", "已发送"].contains(feedback.value as? String ?? feedback.label)
        }, object: nil)
        let writeResult = XCTWaiter.wait(for: [sent], timeout: 35)
        if feedback.exists {
            XCTContext.runActivity(named: "LIVE_WRITE_STATUS: \(feedback.value as? String ?? feedback.label)") { _ in }
        }
        XCTAssertEqual(writeResult, .completed, "Public clipboard fixture was not sent successfully")
        editor.click()
        editor.typeKey("a", modifierFlags: .command)
        editor.typeKey(.delete, modifierFlags: [])
        read.click()
        let received = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            feedback.exists && ["Read", "已读取"].contains(feedback.value as? String ?? feedback.label)
        }, object: nil)
        let readResult = XCTWaiter.wait(for: [received], timeout: 35)
        if feedback.exists {
            XCTContext.runActivity(named: "LIVE_READ_STATUS: \(feedback.value as? String ?? feedback.label)") { _ in }
        }
        XCTAssertEqual(readResult, .completed, "Public clipboard fixture was not read successfully")
        let returned = editor.value as? String
        XCTContext.runActivity(named: "LIVE_READ_EMPTY: \(returned?.isEmpty == true)") { _ in }
        XCTAssertTrue(returned == fixture, "Readback must equal the complete public fixture; mismatched content is not logged")
    }

    /// Repeated real captures exercise the same live channel across heartbeat intervals.
    @MainActor
    func testOptedInLiveIOSScreenshotStability() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["DEVICEBRIDGE_UI_LIVE_IOS"] == "1",
              let path = environment["DEVICEBRIDGE_UI_APP_PATH"] else {
            throw XCTSkip("Explicit running app path required")
        }
        continueAfterFailure = false
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "dev.debugutility.DeviceBridge")
        XCTAssertEqual(running.count, 1)
        XCTAssertEqual(running.first?.bundleURL?.standardizedFileURL.path, URL(fileURLWithPath: path).standardizedFileURL.path)
        let app = XCUIApplication(url: URL(fileURLWithPath: path))
        app.activate()
        let module = app.buttons["module-screenshot"]
        XCTAssertTrue(module.waitForExistence(timeout: 10))
        module.click()
        let capture = app.buttons["screenshot-capture"]
        let metadata = app.staticTexts["screenshot-metadata"]
        for index in 1...10 {
            XCTAssertTrue(capture.exists && capture.isEnabled, "Capture unavailable at iteration \(index)")
            let before = metadata.exists ? (metadata.value as? String ?? metadata.label) : ""
            let started = Date()
            capture.click()
            let changed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                metadata.exists && (metadata.value as? String ?? metadata.label) != before && capture.isEnabled
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 15), .completed,
                           "Capture did not publish fresh metadata at iteration \(index)")
            XCTAssertTrue(app.images["screenshot-preview"].exists)
            XCTContext.runActivity(named: "LIVE_CAPTURE \(index) completed in \(Date().timeIntervalSince(started)) seconds") { _ in }
            RunLoop.current.run(until: Date().addingTimeInterval(2))
        }
    }

    /// Inspect the already-selected production session without reconnecting or reading content.
    @MainActor
    func testOptedInLiveIOSConnectionStatus() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["DEVICEBRIDGE_UI_LIVE_IOS"] == "1",
              let path = environment["DEVICEBRIDGE_UI_APP_PATH"] else {
            throw XCTSkip("Explicit running app path required")
        }
        continueAfterFailure = false
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "dev.debugutility.DeviceBridge")
        XCTAssertEqual(running.count, 1)
        XCTAssertEqual(running.first?.bundleURL?.standardizedFileURL.path, URL(fileURLWithPath: path).standardizedFileURL.path)
        let app = XCUIApplication(url: URL(fileURLWithPath: path))
        app.activate()
        for module in ["clipboard", "screenshot"] {
            let button = app.buttons["module-" + module]
            XCTAssertTrue(button.waitForExistence(timeout: 10), "Keep the failing phone selected")
            button.click()
            for identifier in [module + "-readiness", module + "-feedback", module + "-recovery"] {
                let text = app.staticTexts[identifier]
                if text.exists {
                    let value = text.value as? String ?? text.label
                    XCTContext.runActivity(named: "LIVE_STATUS \(identifier): \(value)") { _ in }
                }
            }
            let advice = app.staticTexts.matching(NSPredicate(format:
                "label CONTAINS[c] 'runner' OR label CONTAINS '辅助程序' OR label CONTAINS '签名' OR label CONTAINS 'Team ID' OR label CONTAINS 'Xcode'"))
            for text in advice.allElementsBoundByIndex {
                XCTContext.runActivity(named: "LIVE_ADVICE: \(text.label)") { _ in }
            }
        }
    }

    @MainActor
    func testLanguageSwitchPreservesInputsAndPersists() {
        let app = XCUIApplication()
        let suite = "dev.debugutility.language-test.\(UUID().uuidString)"
        defer {
            app.terminate()
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
        app.launchArguments = ["--ui-testing", "--fixture-devices", "--language-test-suite", suite]
        app.launch()
        app.activate()
        if !app.windows.firstMatch.waitForExistence(timeout: 2) {
            app.typeKey("n", modifierFlags: .command)
        }
        let picker = app.popUpButtons["interface-language"]
        XCTAssertTrue(picker.waitForExistence(timeout: 3), app.windows.debugDescription)
        picker.click()
        XCTAssertTrue(app.menuItems["English"].waitForExistence(timeout: 2), app.debugDescription)
        app.menuItems["English"].click()
        app.buttons["Android Test Device"].click()
        let editor = app.textViews["clipboard-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        editor.click()
        editor.typeText("Keep my input")
        app.buttons["module-files"].click()
        app.buttons["files-mode-transfer"].click()
        let path = app.textFields["files-relative-path"]
        path.click()
        path.typeKey("a", modifierFlags: .command)
        path.typeText("my-file.txt")
        app.buttons["module-clipboard"].click()
        app.buttons["clipboard-send"].click()
        XCTAssertTrue(app.staticTexts["clipboard-feedback"].waitForExistence(timeout: 2))
        app.buttons["module-screenshot"].click()
        app.buttons["screenshot-capture"].click()
        XCTAssertTrue(app.images["screenshot-preview"].waitForExistence(timeout: 2))
        app.buttons["module-memory"].click()
        let startMemory = app.buttons["memory-start-android"]
        let memoryEnabled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            startMemory.exists && startMemory.isEnabled
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [memoryEnabled], timeout: 3), .completed,
                       "Memory Start must be enabled before the language preservation scenario")
        startMemory.click()
        XCTAssertTrue(app.buttons["memory-stop"].waitForExistence(timeout: 2),
                      "Start action did not enter monitoring before language switching")
        XCTAssertTrue(app.staticTexts["memory-latest-sample"].waitForExistence(timeout: 2),
                      "Monitoring started but its initial fixture sample was not published")
        picker.click()
        XCTAssertTrue(app.menuItems["简体中文"].waitForExistence(timeout: 2))
        app.menuItems["简体中文"].click()
        app.buttons["module-clipboard"].click()
        XCTAssertTrue(app.buttons["从设备读取"].waitForExistence(timeout: 2))
        XCTAssertEqual(editor.value as? String, "Keep my input")
        app.buttons["module-files"].click()
        XCTAssertEqual(path.value as? String, "my-file.txt")
        XCTAssertTrue(app.staticTexts["Android Test Device · USB"].exists)
        app.buttons["module-clipboard"].click()
        XCTAssertEqual(app.staticTexts["clipboard-readiness"].value as? String, "就绪")
        XCTAssertEqual(app.staticTexts["clipboard-feedback"].value as? String, "已发送")
        app.buttons["module-screenshot"].click()
        XCTAssertTrue(app.images["screenshot-preview"].exists)
        app.buttons["module-memory"].click()
        XCTAssertTrue(app.buttons["memory-stop"].exists)
        XCTAssertTrue(app.staticTexts["memory-latest-sample"].exists)
        app.terminate()
        app.launch()
        app.activate()
        if !app.windows.firstMatch.waitForExistence(timeout: 2) {
            app.typeKey("n", modifierFlags: .command)
        }
        XCTAssertTrue(app.staticTexts["选择设备"].waitForExistence(timeout: 3))
        picker.click()
        XCTAssertTrue(app.menuItems["English"].waitForExistence(timeout: 2))
        app.menuItems["English"].click()
        XCTAssertTrue(app.staticTexts["Select a device"].waitForExistence(timeout: 2))
    }

    @MainActor
    func testAutomaticRecoveryRebindsToolsAndStopsOnDeviceSwitch() {
        let app = XCUIApplication()
        defer { app.terminate() }
        app.launchArguments = ["--ui-testing", "--fixture-devices", "--fixture-recovery"]
        app.launch()
        app.activate()
        app.buttons["Android Test Device"].click()
        XCTAssertTrue(app.staticTexts["connection-recovered"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Android Test Device · Wi-Fi"].exists)
        XCTAssertTrue(app.buttons["clipboard-read"].isEnabled)
        XCTAssertTrue(app.buttons["connection-maintenance-stop"].exists)
        app.buttons["iOS Test Device"].click()
        XCTAssertTrue(app.staticTexts["iOS Test Device · USB"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.buttons["connection-maintenance-stop"].exists)
        XCTAssertFalse(app.staticTexts["connection-recovered"].exists)
    }

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testFixtureDevicesCanBeSelectedWithoutMixingDetail() {
        let app = XCUIApplication()
        defer { app.terminate() }
        app.launchArguments = ["--ui-testing", "--fixture-devices"]
        app.launch()

        XCTAssertTrue(app.buttons["Android Test Device"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["iOS Test Device"].exists)

        app.buttons["Android Test Device"].click()
        XCTAssertTrue(app.staticTexts["Android Test Device · USB"].waitForExistence(timeout: 1))

        app.buttons["refresh-devices"].click()
        XCTAssertTrue(app.staticTexts["Android Test Device · USB"].waitForExistence(timeout: 1))

        app.buttons["iOS Test Device"].click()
        XCTAssertTrue(app.staticTexts["iOS Test Device · USB"].waitForExistence(timeout: 1))
        XCTAssertFalse(app.staticTexts["Android Test Device · USB"].exists)
    }

    @MainActor
    func testClipboardRequiresExplicitReadAndSendActions() {
        let app = XCUIApplication()
        defer { app.terminate() }
        app.launchArguments = ["--ui-testing", "--fixture-devices"]
        app.launch()

        app.buttons["Android Test Device"].click()

        let readiness = app.staticTexts["clipboard-readiness"]
        XCTAssertTrue(readiness.waitForExistence(timeout: 3))
        XCTAssertEqual(readiness.value as? String ?? readiness.label, "Available on demand")

        let editor = app.textViews["clipboard-editor"]
        XCTAssertEqual(editor.value as? String ?? "", "")
        app.buttons["clipboard-read"].click()
        XCTAssertTrue(
            NSPredicate(format: "value == %@", "Fixture device clipboard 📋")
                .evaluate(with: editor)
        )

        editor.click()
        editor.typeKey("a", modifierFlags: .command)
        // XCTest on macOS 26.6 opens Keyboard Settings while synthesizing emoji input.
        // Unicode write-through is covered by ClipboardServiceTests; keep this UI test
        // focused on the explicit edit-and-send interaction.
        editor.typeText("Mac to device")
        app.buttons["clipboard-send"].click()

        let feedback = app.staticTexts["clipboard-feedback"]
        XCTAssertTrue(feedback.waitForExistence(timeout: 2))
        XCTAssertEqual(feedback.value as? String ?? feedback.label, "Sent")
    }

    @MainActor
    func testScreenshotRequiresExplicitCaptureAndShowsSourceMetadata() {
        let app = XCUIApplication()
        defer { app.terminate() }
        app.launchArguments = ["--ui-testing", "--fixture-devices"]
        app.launch()

        app.buttons["Android Test Device"].click()
        app.buttons["module-screenshot"].click()
        let readiness = app.staticTexts["screenshot-readiness"]
        XCTAssertTrue(readiness.waitForExistence(timeout: 3))
        XCTAssertEqual(readiness.value as? String ?? readiness.label, "Ready")
        XCTAssertFalse(app.images["screenshot-preview"].exists)

        app.buttons["screenshot-capture"].click()

        XCTAssertTrue(app.images["screenshot-preview"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["screenshot-metadata"].exists)
        XCTAssertTrue(app.buttons["screenshot-copy"].exists)
        XCTAssertTrue(app.buttons["screenshot-save"].exists)

        app.buttons["screenshot-copy"].click()
        let expected = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9Zl1sAAAAASUVORK5CYII=")
        XCTAssertEqual(NSPasteboard.general.data(forType: .png), expected)
    }

    @MainActor
    func testFilePanelShowsOnlyExplicitScopedActions() {
        let app = XCUIApplication()
        defer { app.terminate() }
        app.launchArguments = ["--ui-testing", "--fixture-devices"]
        app.launch()

        app.buttons["Android Test Device"].click()
        app.buttons["module-files"].click()

        XCTAssertTrue(app.buttons["files-mode-images"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["files-mode-images"].isEnabled)
        XCTAssertFalse(app.textFields["files-relative-path"].exists)
        app.buttons["files-mode-transfer"].click()

        let readiness = app.staticTexts["files-readiness"]
        XCTAssertTrue(readiness.waitForExistence(timeout: 3))
        XCTAssertEqual(readiness.value as? String ?? readiness.label, "Ready")
        XCTAssertTrue(app.popUpButtons["files-scope"].exists)
        XCTAssertTrue(app.textFields["files-relative-path"].exists)
        XCTAssertTrue(app.buttons["files-send"].exists)
        XCTAssertTrue(app.buttons["files-receive"].exists)
        XCTAssertFalse(app.staticTexts["files-feedback"].exists)
    }

    @MainActor
    func testMemoryPanelLabelsSourceAndStartsOnlyAfterAppSelection() {
        let app = XCUIApplication()
        defer { app.terminate() }
        app.launchArguments = ["--ui-testing", "--fixture-devices"]
        app.launch()

        app.buttons["Android Test Device"].click()
        app.buttons["module-memory"].click()

        let readiness = app.staticTexts["memory-readiness"]
        XCTAssertTrue(readiness.waitForExistence(timeout: 3))
        XCTAssertEqual(readiness.value as? String ?? readiness.label, "Ready")
        XCTAssertTrue(app.popUpButtons["memory-application"].exists)
        XCTAssertFalse(app.staticTexts["memory-latest-sample"].exists)

        app.buttons["memory-start-android"].click()

        XCTAssertTrue(app.staticTexts["memory-latest-sample"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["memory-source"].exists)
        XCTAssertTrue(app.buttons["memory-stop"].exists)
    }

    @MainActor
    func testLiveInventoryCanSwitchBetweenTwoCommandReadyDevices() throws {
        let app = XCUIApplication()
        app.launch()

        let rows = app.outlines["Sidebar"].buttons
        guard rows.element(boundBy: 1).waitForExistence(timeout: 15) else {
            throw XCTSkip("Two live devices are required for this validation")
        }

        let header = app.staticTexts["selected-device-header"]
        var selectedNames = Set<String>()
        for index in 0..<min(rows.count, 8) {
            let row = rows.element(boundBy: index)
            let name = row.label
            row.click()
            if header.waitForExistence(timeout: 2) {
                let headerText = header.value as? String ?? header.label
                if headerText.hasPrefix("\(name) · ") {
                    selectedNames.insert(name)
                }
            }
        }

        XCTAssertGreaterThanOrEqual(selectedNames.count, 2)
    }
}
