# Interface language validation — 2026-09-07

## Scope and state ownership

Approved slice: T094–T097 / FR-L01–FR-L05. One app-level `AppStorage` preference owns language.
The existing `WorkspaceViewModel` remains a `StateObject`; environment language and locale are
presentation inputs, not view identity. Switching has no device command, reconnect, cancel or
monitor-start call site. Existing session-generation checks and operation ownership are unchanged.

English message keys and opaque arguments are retained until rendering. Existing feedback can
therefore change language without rerunning an operation. Device names, identifiers, paths and
clipboard contents bypass catalog lookup. OS-owned menu/panel chrome and mobile helper UI remain
outside this Mac workspace setting; unknown safe external diagnostics retain their original text.

## Red/green evidence

- The first language UI test failed on the missing `interface-language` picker before UI integration.
- A malformed oversized numeric placeholder reproduced an integer-conversion crash; guarded parsing
  now preserves unknown placeholders, and the regression test passes.
- Menu selection initially failed on a missing-menu-item lookup. Explicitly waiting for the actual
  menu item made the test pass; no permission or signing change was needed.
- Standalone switching/persistence/input test passed in
  `Test-DeviceBridge-2026.09.07_14-40-28-+0800.xcresult` (1 test, 0 failures).
- Fresh core run at 14:40:56: **136 tests in 29 suites passed**, including language resolution,
  invalid preference fallback, catalog loading, template parity and opaque formatting.
- Fresh Release build: **PASS** with `CODE_SIGNING_ALLOWED=NO`, using
  `.build/xcode-release-language`. This verifies compilation and bundling, not distributable signing.
- The first full UI run, `Test-DeviceBridge-2026.09.07_14-41-42-+0800.xcresult`, passed 8/9 tests.
  The enhanced language case passed, preserving edited clipboard/path, selected device, existing
  sent feedback, screenshot preview and active memory controls across switching. The pre-existing
  screenshot test failed querying a StaticText accessibility snapshot; its standalone rerun exited
  zero at 14:44:31 without implementation changes. The cause is not established.
- Latest full rerun, `Test-DeviceBridge-2026.09.07_14-45-29-+0800.xcresult`: **7/9 passed, 2 failed**.
  The screenshot case passed. Keyboard clipboard feedback was absent, and the language case failed
  waiting for its initial memory sample **before** switching to Chinese. The captured hierarchy
  still contained the ready memory panel/start button, selected fixture device, edited inputs and
  screenshot. These observations do not establish the cause or justify calling the full suite green.
  No retries, weakened assertions or application behavior changes were added to hide these failures.

## Reproduction

```sh
swift test --package-path packages/DeviceBridgeCore
xcodebuild test -quiet -project apps/macos/DeviceBridge.xcodeproj \
  -scheme DeviceBridge -destination 'platform=macOS,arch=arm64' \
  -only-testing:DeviceBridgeAppUITests \
  -skip-testing:DeviceBridgeAppUITests/DeviceWorkspaceUITests/testLiveInventoryCanSwitchBetweenTwoCommandReadyDevices
xcodebuild build -quiet -project apps/macos/DeviceBridge.xcodeproj \
  -scheme DeviceBridge -configuration Release \
  -derivedDataPath .build/xcode-release-language CODE_SIGNING_ALLOWED=NO
```

UI tests use an isolated fixture preference domain. The persistence case uses a unique domain and
removes it after terminating the test app; it does not overwrite the user's normal language choice.
The test opens a new window with Command-N if macOS restores the test application without a window.

## Limits

Fixture checks are not evidence of physical iOS transport, sustained Android Wi-Fi recovery, or
language switching during a real 500 MB transfer. Those existing qualification tasks remain open.
System-language resolution is covered by pure tests; changing macOS language while the app is
already running has not been qualified.

Chinese visual review is **NOT COMPLETE**. Computer Use initially exposed the native language
menu, but subsequent attempts to reconnect the fixture app failed with `native pipe closed before
response`, including after resetting the automation session. No system permission was changed.
T097 remains open until the full UI regression passes and default-size Chinese layout is visually
checked; AX assertions alone do not prove the absence of clipping.
