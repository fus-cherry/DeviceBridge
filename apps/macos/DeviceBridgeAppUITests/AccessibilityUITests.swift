import XCTest

final class AccessibilityUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testPrimaryControlsExposeStableLabelsAndValues() {
        let app = launchFixtureApp()

        let refresh = app.buttons["refresh-devices"]
        XCTAssertTrue(refresh.waitForExistence(timeout: 3))
        XCTAssertEqual(refresh.label, "Refresh devices")

        let device = app.buttons["Android Test Device"]
        XCTAssertEqual(device.label, "Android Test Device")
        device.click()

        let readiness = app.staticTexts["clipboard-readiness"]
        XCTAssertTrue(readiness.waitForExistence(timeout: 3))
        XCTAssertEqual(readiness.value as? String ?? readiness.label, "Ready")

        let editor = app.textViews["clipboard-editor"]
        XCTAssertEqual(editor.label, "Clipboard text")
        XCTAssertEqual(app.buttons["clipboard-read"].label, "Read from device")
        XCTAssertEqual(app.buttons["clipboard-send"].label, "Send to device")
        XCTAssertFalse(app.buttons["screenshot-capture"].exists)
        app.buttons["module-screenshot"].click()
        XCTAssertEqual(app.buttons["screenshot-capture"].label, "Capture screenshot")
        app.buttons["module-files"].click()
        app.buttons["files-mode-transfer"].click()
        XCTAssertEqual(app.popUpButtons["files-scope"].label, "Scope")
        app.buttons["module-memory"].click()
        XCTAssertEqual(app.popUpButtons["memory-application"].label, "Application")
    }

    @MainActor
    func testClipboardSendHasKeyboardPath() {
        let app = launchFixtureApp()
        let device = app.buttons["Android Test Device"]
        XCTAssertTrue(device.waitForExistence(timeout: 3))
        app.activate()
        device.click()

        let editor = app.textViews["clipboard-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        let send = app.buttons["clipboard-send"]
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            editor.exists && editor.isEnabled && send.exists && send.isEnabled
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 3), .completed,
                       "Clipboard controls must be ready before keyboard input")
        editor.click()
        editor.typeText("Keyboard transfer")
        XCTAssertEqual(editor.value as? String, "Keyboard transfer")

        app.typeKey(.return, modifierFlags: .command)

        let feedback = app.staticTexts["clipboard-feedback"]
        XCTAssertTrue(feedback.waitForExistence(timeout: 2))
        XCTAssertEqual(feedback.value as? String ?? feedback.label, "Sent")
        editor.click()
        editor.typeKey("a", modifierFlags: .command)
        editor.typeKey(.delete, modifierFlags: [])
        app.buttons["clipboard-read"].click()
        let received = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            editor.value as? String == "Keyboard transfer"
                && (feedback.value as? String ?? feedback.label) == "Read"
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [received], timeout: 2), .completed,
                       "Keyboard send must transfer the complete text, not merely show feedback")
    }

    @MainActor
    private func launchFixtureApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--fixture-devices"]
        app.launch()
        app.activate()
        addTeardownBlock { @MainActor in app.terminate() }
        return app
    }
}
