import AppKit
import XCTest

/// Real settings controls on the isolated macOS CI runner. Every tool and network
/// operation is confined to a temporary fixture; no unknown executable is launched.
final class HDCManagerUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor
    func testGeneralSettingsHideSigningTeamsAndKeepHDCNavigationInBothLanguages() throws {
        for language in ["en", "zh-Hans"] {
            let chinese = language == "zh-Hans"
            let root = try makeFixture()
            // Seed only this test's isolated preference domain, never the user's
            // standard defaults or local signing identities.
            let app = launch(root: root, language: language, legacySigningTeam: "9Y3KFUUCJG")
            app.typeKey(",", modifierFlags: .command)
            let settings = app.windows["com_apple_SwiftUI_Settings_window"]
            XCTAssertTrue(settings.waitForExistence(timeout: 5), app.debugDescription)
            let general = settings.buttons[chinese ? "通用" : "General"]
            XCTAssertTrue(general.waitForExistence(timeout: 5), settings.debugDescription)
            general.click()
            assertLabel(settings.staticTexts["general-ios-preparation-title"], equals: chinese ? "iOS 准备" : "iOS preparation")
            assertLabel(settings.staticTexts["general-ios-preparation-note"], equals: chinese
                ? "iOS 辅助工具在本机上构建。请预先安装匹配的 Apple 开发签名身份和设备描述文件。DeviceBridge 不会创建证书或描述文件。"
                : "iOS helpers are built on this Mac. A matching Apple development signing identity and provisioning profile must already be installed. DeviceBridge does not create certificates or profiles.")
            XCTAssertEqual(settings.textFields.count, 0, "General settings must not expose an editable signing-team field")
            let displayed = settings.staticTexts.allElementsBoundByIndex.map { displayedText($0) }.joined(separator: "\n")
            for forbidden in ["9Y3KFUUCJG", "5F6294RLX4", "Team ID", "团队 ID", "团队ID"] {
                XCTAssertFalse(displayed.localizedCaseInsensitiveContains(forbidden), "General settings must not display signing-team values or labels")
            }
            record(app, name: "general-ios-preparation-no-team-\(language)")
            settings.buttons["_XCUI:CloseWindow"].click()
            let entry = ensureWorkspaceSidebar(app).buttons["hdc-open-settings"]
            XCTAssertTrue(entry.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(entry.isHittable)
            XCTAssertGreaterThan(entry.frame.width, 200)
            XCTAssertEqual(entry.label, chinese ? "HDC 工具管理…" : "Manage HDC tools…")
            entry.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).click()
            XCTAssertTrue(app.buttons["hdc-inspect"].waitForExistence(timeout: 5),
                          "Removing signing settings must preserve direct HDC-tool navigation")
            XCTAssertEqual(app.buttons["hdc-inspect"].label, chinese ? "检查路径" : "Inspect path")
            app.terminate()
        }
    }

    @MainActor
    func testHDCPathInspectionImportVersionConsentAndPersistentSelection() throws {
        let root = try makeFixture()
        let app = launch(root: root)
        let sidebar = ensureWorkspaceSidebar(app)
        let entry = sidebar.buttons["hdc-open-settings"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(entry.isHittable, "The real sidebar entry must be visible before testing its whitespace click")
        XCTAssertGreaterThan(entry.frame.width, 200, "Tool-management entry must retain a full-row hit area")
        record(app, name: "hdc-manager-sidebar-entry-before-open")
        entry.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).click()
        XCTAssertTrue(app.buttons["hdc-inspect"].waitForExistence(timeout: 5), "Sidebar tool-management entry must open the HDC tab directly")
        let path = app.textFields["hdc-path-field"]
        XCTAssertEqual(path.value as? String, root.appendingPathComponent("sdk/hdc").path)
        app.buttons["hdc-inspect"].click()
        assertLabel(app.staticTexts["hdc-inspection-status"], equals: "Static checks passed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("version-request.txt").path),
                       "Static inspection must never invoke HDC")

        app.buttons["hdc-check-version"].click()
        let versionConsent = executionSheet(app, action: "Run client version check")
        XCTAssertTrue(versionConsent.staticTexts.matching(NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", "server version and device connection are not checked", "server version and device connection are not checked")).firstMatch.exists)
        clickSheetButton("Cancel", in: versionConsent)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("version-request.txt").path))
        app.buttons["hdc-check-version"].click()
        clickSheetButton("Run client version check", in: executionSheet(app, action: "Run client version check"))
        assertLabel(app.staticTexts["hdc-version-result"], equals: "HDC fixture 6.0.0")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("version-request.txt"), encoding: .utf8), "-v")

        replace(path, with: root.appendingPathComponent("broken").path)
        XCTAssertFalse(app.buttons["hdc-activate"].isEnabled, "Editing a checked path invalidates its old approval")
        app.buttons["hdc-inspect"].click()
        assertLabel(app.staticTexts["hdc-inspection-status"], equals: "Tool needs attention")
        XCTAssertFalse(app.buttons["hdc-activate"].isEnabled)
        assertLabel(app.staticTexts["hdc-inspection-issue-0"], equals: "Required library was not found beside HDC: libusb_shared.dylib")

        let pathBeforePickerCancel = try XCTUnwrap(path.value as? String)
        let configurationURL = root.appendingPathComponent("managed/configuration.json")
        let configurationBeforePickerCancel = try? Data(contentsOf: configurationURL)
        app.buttons["hdc-choose-path"].click()
        let cancelledPicker = nativePicker(app)
        app.typeKey(.escape, modifierFlags: [])
        waitForNativePickerDismissal(cancelledPicker)
        XCTAssertEqual(path.value as? String, pathBeforePickerCancel,
                       "Escaping the native picker must preserve the prior path")
        XCTAssertEqual(try? Data(contentsOf: configurationURL), configurationBeforePickerCancel,
                       "Cancelling the picker must not enable or persist a different tool")
        XCTAssertFalse(app.buttons["hdc-activate"].isEnabled)
        assertLabel(app.staticTexts["hdc-inspection-status"], equals: "Tool needs attention")

        app.buttons["hdc-choose-path"].click()
        chooseDirectory(root.appendingPathComponent("sdk"), prompt: "Choose", app: app)
        assertLabel(app.staticTexts["hdc-inspection-status"], equals: "Static checks passed")
        let chosen = try XCTUnwrap(path.value as? String)
        XCTAssertEqual(URL(fileURLWithPath: chosen).resolvingSymlinksInPath(),
                       root.appendingPathComponent("sdk").resolvingSymlinksInPath(),
                       "The real native panel must return the requested SDK directory")
        app.buttons["hdc-import-directory"].click()
        chooseDirectory(root.appendingPathComponent("sdk"), prompt: "Import", app: app)
        let importedPath = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (path.value as? String)?.hasPrefix(root.appendingPathComponent("managed/toolchains").path) == true
                && app.buttons["hdc-activate"].isEnabled
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [importedPath], timeout: 5), .completed)
        let imported = try XCTUnwrap(path.value as? String)
        XCTAssertTrue(imported.hasPrefix(root.appendingPathComponent("managed/toolchains").path))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: imported).deletingLastPathComponent().appendingPathComponent("libusb_shared.dylib")), try Data(contentsOf: root.appendingPathComponent("sdk/libusb_shared.dylib")))
        XCTAssertFalse(app.staticTexts["hdc-version-result"].exists, "Import must not run the version command")
        app.buttons["hdc-activate"].click()
        clickSheetButton("Cancel", in: executionSheet(app, action: "Enable and allow discovery"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("managed/configuration.json").path),
                       "Cancelling execution consent must leave the selection unchanged")
        app.buttons["hdc-activate"].click()
        clickSheetButton("Enable and allow discovery", in: executionSheet(app, action: "Enable and allow discovery"))
        assertSelectedPath(imported, root: root, app: app)
        record(app, name: "hdc-manager-imported-english")

        app.terminate()
        app.launch()
        app.activate()
        _ = ensureWorkspaceSidebar(app)
        openHDCSettings(app)
        XCTAssertEqual(app.textFields["hdc-path-field"].value as? String, imported)
        app.buttons["hdc-clear"].click()
        let cleared = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let config = try? self.configuration(root) else { return false }
            return config["selectedExecutablePath"] as? String == nil
                && !app.staticTexts["hdc-enabled-path"].exists
                && !app.buttons["hdc-clear"].isEnabled && app.buttons["hdc-rollback"].isEnabled
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [cleared], timeout: 5), .completed,
                       "Clearing must persist and update the real controls before rollback")
        app.buttons["hdc-rollback"].click()
        assertSelectedPath(imported, root: root, app: app)
        XCTAssertTrue(app.buttons["hdc-clear"].isEnabled)
        XCTAssertEqual(app.buttons["hdc-inspect"].label, "Inspect path", "Container AX identifiers must not replace child control labels")
    }

    @MainActor
    func testHDCCustomHTTPSValidationSourceRankingArchitectureMismatchAndCancellation() throws {
        let root = try makeFixture()
        let app = launch(root: root)
        openHDCSettings(app)
        reveal(app.textFields["hdc-source-name"], in: app, down: true)
        replace(app.textFields["hdc-source-name"], with: "Unsafe")
        reveal(app.textFields["hdc-source-url"], in: app, down: true)
        replace(app.textFields["hdc-source-url"], with: "http://fixture.invalid/unsafe.zip")
        reveal(app.buttons["hdc-source-add"], in: app, down: true)
        app.buttons["hdc-source-add"].click()
        reveal(app.staticTexts["hdc-error-detail"], in: app, down: true)
        XCTAssertEqual(displayedText(app.staticTexts["hdc-error-detail"]), "Custom download sources must use public HTTPS URLs without embedded credentials.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("probe-unsafe.zip.txt").path))

        try addSource("Slow", file: "slow.zip", app: app)
        try addSource("Fast", file: "fast.zip", app: app)
        try addSource("Timeout", file: "timeout.zip", app: app)
        reveal(app.popUpButtons["hdc-artifact-architecture"], in: app, down: false)
        app.popUpButtons["hdc-artifact-architecture"].click()
        app.menuItems["Intel (x86_64)"].click()
        try addSource("Other architecture", file: "other.zip", app: app)
        reveal(app.popUpButtons["hdc-artifact-architecture"], in: app, down: false)
        app.popUpButtons["hdc-artifact-architecture"].click()
        app.menuItems["Apple Silicon (arm64)"].click()
        reveal(app.buttons["hdc-benchmark-start"], in: app, down: true)
        app.buttons["hdc-benchmark-start"].click()
        let fastID = try sourceID("Fast", root: root)
        let slowID = try sourceID("Slow", root: root)
        let timeoutID = try sourceID("Timeout", root: root)
        let otherID = try sourceID("Other architecture", root: root)
        let fastResult = app.staticTexts["hdc-source-result-\(fastID)"]
        XCTAssertTrue(fastResult.waitForExistence(timeout: 5))
        XCTAssertEqual(displayedText(fastResult), "1024 KiB/s")
        XCTAssertEqual(displayedText(app.staticTexts["hdc-source-result-\(slowID)"]), "256 KiB/s")
        XCTAssertEqual(displayedText(app.staticTexts["hdc-source-result-\(timeoutID)"]), "The source exceeded the sample time limit.")
        XCTAssertEqual(displayedText(app.staticTexts["hdc-source-result-\(otherID)"]), "Only the same HDC version and architecture can be compared.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("probe-other.zip.txt").path),
                       "A different architecture must never be downloaded for a speed comparison")
        let fast = app.buttons["hdc-source-open-\(fastID)"]
        let slow = app.buttons["hdc-source-open-\(slowID)"]
        reveal(fast, in: app, down: false)
        XCTAssertLessThan(fast.frame.minY, slow.frame.minY, "Successful matching sources must be ranked fastest first")
        // Far-right source-row whitespace opens that source, not its separate remove control.
        fast.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).click()
        XCTAssertTrue(app.buttons["hdc-source-remove-\(fastID)"].exists)
        XCTAssertEqual(try sources(root).count, 5)
        record(app, name: "hdc-manager-ranked-source-results")
        reveal(app.popUpButtons["hdc-artifact-architecture"], in: app, down: true)
        app.popUpButtons["hdc-artifact-architecture"].click()
        app.menuItems["Intel (x86_64)"].click()
        XCTAssertFalse(fastResult.exists, "Changing the comparison architecture must invalidate old speeds and ordering")
        app.popUpButtons["hdc-artifact-architecture"].click()
        app.menuItems["Apple Silicon (arm64)"].click()

        try Data("wait".utf8).write(to: root.appendingPathComponent("benchmark-mode.txt"))
        reveal(app.buttons["hdc-benchmark-start"], in: app, down: true)
        app.buttons["hdc-benchmark-start"].click()
        XCTAssertTrue(app.buttons["hdc-benchmark-cancel"].waitForExistence(timeout: 2))
        // Wait until the fake transport has started; cancellation must stop it, not only hide a spinner.
        let cancellation = root.appendingPathComponent("probe-cancelled.txt")
        let waiting = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            FileManager.default.fileExists(atPath: root.appendingPathComponent("probe-waiting.txt").path)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [waiting], timeout: 3), .completed)
        app.buttons["hdc-benchmark-cancel"].click()
        let cancelled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in FileManager.default.fileExists(atPath: cancellation.path) }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [cancelled], timeout: 3), .completed)
        XCTAssertTrue(app.buttons["hdc-benchmark-start"].isEnabled)
        XCTAssertFalse(app.buttons["hdc-benchmark-cancel"].exists)
        reveal(app.staticTexts["hdc-feedback"], in: app, down: true)
        XCTAssertEqual(displayedText(app.staticTexts["hdc-feedback"]), "Speed test cancelled.")
        app.terminate()
        app.launch()
        app.activate()
        _ = ensureWorkspaceSidebar(app)
        openHDCSettings(app)
        XCTAssertEqual(try sourceID("Fast", root: root), fastID, "Custom source identity must persist across relaunch")
        reveal(app.buttons["hdc-source-remove-\(timeoutID)"], in: app, down: true)
        app.buttons["hdc-source-remove-\(timeoutID)"].click()
        XCTAssertEqual(try sources(root).count, 4)
        XCTAssertFalse(app.buttons["hdc-source-remove-\(timeoutID)"].exists)
    }

    @MainActor
    func testHDCManagerChineseLabelsAndArchitectureFailure() throws {
        let root = try makeFixture()
        let app = launch(root: root, language: "zh-Hans")
        openHDCSettings(app, chinese: true)
        XCTAssertEqual(app.buttons["hdc-inspect"].label, "检查路径")
        XCTAssertEqual(app.buttons["hdc-import-directory"].label, "导入目录…")
        replace(app.textFields["hdc-path-field"], with: root.appendingPathComponent("intel").path)
        app.buttons["hdc-inspect"].click()
        assertLabel(app.staticTexts["hdc-inspection-status"], equals: "工具需要处理")
        XCTAssertFalse(app.buttons["hdc-activate"].isEnabled)
        assertLabel(app.staticTexts["hdc-inspection-issue-0"], equals: "此 HDC 不包含所需的 Apple Silicon 架构。")
        reveal(app.buttons["hdc-official-source"], in: app, down: true)
        XCTAssertTrue(app.buttons["hdc-official-source"].label.contains("华为官方下载 / 登录"))
        app.buttons["hdc-official-source"].click()
        reveal(app.staticTexts["hdc-safety-note"], in: app, down: true)
        XCTAssertTrue(displayedText(app.staticTexts["hdc-safety-note"]).contains("不会自动解压、启用或执行"))
        XCTAssertEqual(displayedText(app.staticTexts["hdc-feedback"]), "已在浏览器中打开下载来源。")
        record(app, name: "hdc-manager-chinese-safety-and-sources")
    }

    private func makeFixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DeviceBridge-HDC-UI-\(UUID().uuidString)", isDirectory: true)
        for (name, cpu, hasLibrary) in [("sdk", UInt32(0x0100000c), true), ("broken", UInt32(0x0100000c), false), ("intel", UInt32(0x01000007), true)] {
            let folder = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let dependency = Array("@loader_path/libusb_shared.dylib\0".utf8)
            let size = (24 + dependency.count + 7) & ~7
            var words: [UInt32] = [0xfeedfacf, cpu, 0, 2, 1, UInt32(size), 0, 0, 0xc, UInt32(size), 24, 0, 0, 0]
            var bytes = Data()
            for index in words.indices { words[index] = words[index].littleEndian }
            words.withUnsafeBytes { bytes.append(contentsOf: $0) }
            bytes.append(contentsOf: dependency)
            bytes.append(contentsOf: repeatElement(UInt8(0), count: 32 + size - bytes.count))
            let executable = folder.appendingPathComponent("hdc")
            try bytes.write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            if hasLibrary {
                var libraryWords: [UInt32] = [0xfeedfacf, cpu, 0, 6, 0, 0, 0, 0]
                for index in libraryWords.indices { libraryWords[index] = libraryWords[index].littleEndian }
                let library = libraryWords.withUnsafeBytes { Data($0) }
                try library.write(to: folder.appendingPathComponent("libusb_shared.dylib"))
            }
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    @MainActor
    private func launch(root: URL, language: String = "en", legacySigningTeam: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        let suite = "dev.debugutility.hdc-ui.\(UUID().uuidString)"
        if let legacySigningTeam {
            let defaults = UserDefaults(suiteName: suite)!
            defaults.set(legacySigningTeam, forKey: "iosSigningTeamID")
            defaults.synchronize()
        }
        // Ignore restoration only in this launched test process. A previous
        // multiwindow test must not change the Workspace under the sidebar test.
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES", "--ui-testing", "--fixture-devices", "--fixture-hdc-manager", "--hdc-fixture-root", root.path,
                               "--language-test-suite", suite, "--fixture-language", language]
        app.launch()
        app.activate()
        addTeardownBlock { @MainActor in app.terminate(); UserDefaults.standard.removePersistentDomain(forName: suite) }
        _ = ensureWorkspaceSidebar(app)
        return app
    }

    @MainActor
    private func ensureWorkspaceSidebar(_ app: XCUIApplication) -> XCUIElement {
        let workspaces = app.windows.containing(.scrollView, identifier: "device-sidebar")
        // macOS can relaunch a WindowGroup app with no restored windows after an
        // earlier test terminated it from Settings. This is ordinary New Window,
        // not a fixture-only navigation shortcut or a bypass of the sidebar entry.
        if !workspaces.firstMatch.waitForExistence(timeout: 2) {
            app.typeKey("n", modifierFlags: .command)
            app.activate()
        }
        XCTAssertTrue(workspaces.firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(workspaces.count, 1, "HDC tests require one isolated Workspace, not multiple restored windows")
        let sidebar = workspaces.element(boundBy: 0).scrollViews["device-sidebar"]
        XCTAssertTrue(sidebar.isHittable, "The controlled Workspace sidebar must be in the foreground")
        return sidebar
    }

    @MainActor
    private func openHDCSettings(_ app: XCUIApplication, chinese: Bool = false) {
        app.activate()
        app.typeKey(",", modifierFlags: .command)
        let label = chinese ? "HDC 管理" : "HDC Manager"
        // macOS renders Settings tabs as native NSToolbar buttons with AXTitle,
        // not the AXLabel exposed by SwiftUI content buttons.
        let tab = app.windows["com_apple_SwiftUI_Settings_window"].buttons[label]
        XCTAssertTrue(tab.waitForExistence(timeout: 5), app.debugDescription)
        tab.click()
        XCTAssertTrue(app.buttons["hdc-inspect"].waitForExistence(timeout: 3), app.debugDescription)
    }

    @MainActor
    private func executionSheet(_ app: XCUIApplication, action: String) -> XCUIElement {
        let settings = app.windows["com_apple_SwiftUI_Settings_window"]
        let sheet = settings.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(sheet.buttons[action].waitForExistence(timeout: 3), sheet.debugDescription)
        XCTAssertEqual(sheet.buttons.matching(NSPredicate(format: "label == %@ OR identifier == %@", action, action)).count, 1,
                       "Execution consent must have exactly one on-screen action, excluding Touch Bar mirrors")
        return sheet
    }

    @MainActor
    private func clickSheetButton(_ title: String, in sheet: XCUIElement) {
        let button = sheet.buttons[title]
        XCTAssertEqual(sheet.buttons.matching(NSPredicate(format: "label == %@ OR identifier == %@", title, title)).count, 1, sheet.debugDescription)
        XCTAssertTrue(button.isEnabled && button.isHittable, sheet.debugDescription)
        button.click()
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !sheet.exists }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed,
                       "The on-screen consent sheet must dismiss before the next operation")
    }

    @MainActor
    private func nativePicker(_ app: XCUIApplication) -> XCUIElement {
        // Native panels can expose either AXSheet or AXDialog depending on
        // macOS hosting. The public panel identifier is stable in both forms.
        let panel = app.descendants(matching: .any).matching(identifier: "open-panel").firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 5), app.debugDescription)
        return panel
    }

    @MainActor
    private func waitForNativePickerDismissal(_ panel: XCUIElement) {
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !panel.exists }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 10), .completed,
                       "The real native picker must close before the next operation")
    }

    @MainActor
    private func chooseDirectory(_ directory: URL, prompt: String, app: XCUIApplication) {
        let panel = nativePicker(app)
        app.typeKey("g", modifierFlags: [.command, .shift])
        app.typeKey("a", modifierFlags: .command)
        app.typeText(directory.path)
        // First Return commits Go to Folder. The second invokes NSOpenPanel's
        // standard default Choose/Import action using real keyboard input.
        // Avoid querying XPC-hosted button frames/flags after navigation: macOS
        // reports stale AXDisabled ancestors and can stall those remote snapshots.
        app.typeKey(.return, modifierFlags: [])
        let evidence = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        evidence.name = "hdc-native-panel-before-\(prompt.lowercased())"
        evidence.lifetime = .keepAlways
        add(evidence)
        app.typeKey(.return, modifierFlags: [])
        waitForNativePickerDismissal(panel)
        XCTAssertTrue(app.buttons["hdc-inspect"].waitForExistence(timeout: 3))
    }

    @MainActor
    private func replace(_ field: XCUIElement, with value: String) {
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(value)
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication, down: Bool) {
        let scroll = app.scrollViews["hdc-manager-scroll"]
        for _ in 0..<12 {
            var deltaY: CGFloat = down ? -320 : 320
            if element.exists {
                let viewport = scroll.frame
                let target = element.frame
                if element.isHittable && viewport.contains(target) { return }
                // Follow the actual laid-out control after source rows grow or
                // ranking reorders them, rather than assuming one scroll direction.
                if target.maxY > viewport.maxY {
                    deltaY = -min(320, max(80, target.maxY - viewport.maxY + 20))
                } else if target.minY < viewport.minY {
                    deltaY = min(320, max(80, viewport.minY - target.minY + 20))
                }
            }
            scroll.scroll(byDeltaX: 0, deltaY: deltaY)
        }
        XCTAssertTrue(element.exists && element.isHittable && scroll.frame.contains(element.frame), app.debugDescription)
    }

    @MainActor
    private func addSource(_ name: String, file: String, app: XCUIApplication) throws {
        reveal(app.textFields["hdc-source-name"], in: app, down: true)
        replace(app.textFields["hdc-source-name"], with: name)
        reveal(app.textFields["hdc-source-url"], in: app, down: true)
        replace(app.textFields["hdc-source-url"], with: "https://fixture.invalid/\(file)")
        reveal(app.buttons["hdc-source-add"], in: app, down: true)
        app.buttons["hdc-source-add"].click()
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (app.textFields["hdc-source-name"].value as? String) == ""
                && (app.textFields["hdc-source-url"].value as? String) == ""
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 3), .completed,
                       "Adding a source must complete before growing the form again")
    }

    private func configuration(_ root: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("managed/configuration.json"))) as? [String: Any])
    }
    private func sources(_ root: URL) throws -> [[String: Any]] { try XCTUnwrap(configuration(root)["sources"] as? [[String: Any]]) }
    private func sourceID(_ name: String, root: URL) throws -> String { try XCTUnwrap(sources(root).first { $0["name"] as? String == name }?["id"] as? String) }

    @MainActor
    private func assertSelectedPath(_ expected: String, root: URL, app: XCUIApplication) {
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let enabledPath = app.staticTexts["hdc-enabled-path"]
            let clear = app.buttons["hdc-clear"]
            return (try? self.configuration(root)["selectedExecutablePath"] as? String) == expected
                && enabledPath.exists && self.displayedText(enabledPath) == expected
                && clear.exists && clear.isEnabled
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 5), .completed,
                       "Selection must be saved on disk and published to the ready UI before continuing")
    }

    @MainActor
    private func assertLabel(_ element: XCUIElement, equals expected: String) {
        let match = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            element.exists && self.displayedText(element) == expected
        }, object: nil)
        let outcome = XCTWaiter.wait(for: [match], timeout: 5)
        if outcome != .completed {
            let attachment = XCTAttachment(string: element.debugDescription)
            attachment.name = "hdc-static-text-assertion-failure"
            attachment.lifetime = .keepAlways
            add(attachment)
            record(XCUIApplication(), name: "hdc-static-text-failure-screen-and-hierarchy")
        }
        XCTAssertEqual(outcome, .completed, "Expected \(expected), got \(element.exists ? displayedText(element) : "missing")")
    }

    @MainActor
    private func displayedText(_ element: XCUIElement) -> String {
        // NSTextField-backed static text exposes its content through AXValue on macOS.
        // Buttons are intentionally checked through their labels separately.
        if let value = element.value as? String, !value.isEmpty { return value }
        return element.label
    }

    @MainActor
    private func record(_ app: XCUIApplication, name: String) {
        for attachment in [XCTAttachment(screenshot: app.screenshot()), XCTAttachment(string: app.debugDescription)] {
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}
