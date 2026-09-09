# macOS UI automation follow-up — 2026-09-07

## Current CUA closure — Build 6 observations / Build 7 implementation, 2026-09-08

Mac interaction remained Computer Use only. Public 15,871-byte / 256-line Unicode text roundtrip,
Command-Return, expanded editor, copy/paste and user-assisted text save passed. PNG copy and saved
file matched; cancelling another save retained the same preview. Language switched through English,
简体中文 and original Follow System with file fields and translated cancellation feedback preserved.

Historical Refresh label mismatch and missing readiness assertions were corrected. Keyboard/initial
memory behavior passed through the production model in headless checks; Mac UI targets compiled
without execution. A received 69-byte file stalled twice in the real GUI (bookmark/getxattr), with
cancel cleanup passing; the Build 7 staging workaround remains awaiting its GUI retest. USB photo
load could not match the selected phone and requested reconnect. These are explicit unresolved cases.

No new fixture app was launched. Final exact-process inventory found zero isolation fixture apps;
formal Build 6 PID 162 was kept running. [Full scope](release-closure-20260908.md).


## Outcome

The previously blocked recovery test passed individually (1 test, 0 failures), then all fixture UI
tests passed (8 tests, 0 failures). Core rerun: 131 tests in 28 suites passed at 14:04:52 local time.
No app implementation, signing configuration, or system permission was changed in this follow-up.
T092 and the affected-surface T073 rerun are complete; physical-device acceptance remains open.

## Investigation and limits of the diagnosis

Prior runs failed before test assertions with `Timed out while enabling automation mode`. The user
suggested an unconfirmed permission dialog. Read-only inspection of System Settings showed Codex
Computer Use Accessibility already enabled; no blocking authorization dialog was observed. This is
the desktop agent's permission, not proof of XCTest authorization or a DeviceBridge prerequisite.

The same targeted locally signed XCTest command now exited zero. The test manager log showed active
automation services and normal automation-mode teardown. These observations establish that the
blocker no longer reproduces; they do not establish which prior prompt or environmental state caused
it. No TCC reset, Accessibility change, Full Disk Access grant, or automatic confirmation was used.

Xcode still reported `no debugger version`, without failing the tests. The result bundle contains a
QoS priority-inversion runtime warning during the clipboard test. This remains a responsiveness risk
for T087, not a failed assertion or a demonstrated permission problem.

## Reproduction commands

From the repository root, keep normal local signing enabled:

```sh
xcodebuild test -quiet -project apps/macos/DeviceBridge.xcodeproj \
  -scheme DeviceBridge -destination 'platform=macOS,arch=arm64' \
  -only-testing:DeviceBridgeAppUITests/DeviceWorkspaceUITests/testAutomaticRecoveryRebindsToolsAndStopsOnDeviceSwitch

xcodebuild test -quiet -project apps/macos/DeviceBridge.xcodeproj \
  -scheme DeviceBridge -destination 'platform=macOS,arch=arm64' \
  -only-testing:DeviceBridgeAppUITests \
  -skip-testing:DeviceBridgeAppUITests/DeviceWorkspaceUITests/testLiveInventoryCanSwitchBetweenTwoCommandReadyDevices
```

The live-device test was excluded by the selection filter (not a runtime skip); both result bundles
report zero skipped tests. No real-phone behavior is inferred. Recovery uses `--fixture-recovery`.

Inspected with `xcrun xcresulttool get test-results summary --path <bundle>` and `get test-results tests`:

- Individual result: `Test-DeviceBridge-2026.09.07_14-03-59-+0800.xcresult`, Passed, 1/1.
- Suite result: `Test-DeviceBridge-2026.09.07_14-04-36-+0800.xcresult`, Passed, 8/8.
- Local parent: `/Users/fus/Library/Developer/Xcode/DerivedData/DeviceBridge-cqkmodeknsdtpygimyxxvhokpgke/Logs/Test/`.

Passing cases cover recovery/rebinding/device switch, normal refresh/switch, explicit clipboard
read/send, screenshot capture/source metadata, scoped file controls, memory source/start controls,
accessibility labels and the keyboard send action. They do not exercise actual wireless faults.

## If authorization blocks another run

Inspect the requesting app and the exact system dialog before accepting anything. Confirm only the
intended permission with the user; do not infer a missing permission from a timeout, grant all
permissions, or disable signing for UI tests. Check the result bundle to distinguish runner startup
failure from an application assertion failure. Contributor UI automation and teammate device trust/
debugging/operation permissions are separate; see the contributor section in the root README.

## Live iOS takeover evidence — 2026-09-08

The DMG user reports screenshot/clipboard disconnection. Fixture passes above are not live UI
acceptance. See [latest non-VM diagnosis](ios-nonvm-acceptance.md#latest-user-feedback-and-ui-diagnosis--2026-09-08)
for the failed 17:15–17:21 XCTest, normal app-exit evidence, recurring CUA service crash, and
the takeover test's early single-instance failure. `testOptedInLiveIOSPreparation` requires
explicit opt-in, one already-running exact-path app and a designated phone. It stops on failed
assertions and never reads or writes clipboard content. Use a fresh xcresult path for every run.

Fresh takeover-2 result: **1 live test passed, 0 failed, 0 skipped** in the single-instance dist
app. The test selected the phone, observed enabled screenshot and clipboard-read controls,
clicked capture and found the screenshot preview. Result: `/tmp/devicebridge-ui-live-ios-20260908-takeover-2.xcresult`.
This does not qualify clipboard content transfer, save/copy, or launching from the read-only DMG.
The original disconnect root cause and CUA service fault remain open; production code is unchanged.

## Current control restriction and build 4

The user now requires Computer Use only for desktop interaction. Do not run the opt-in live Mac
XCTest flows or other global input automation under this authorization. The interrupted clipboard
round trip did not reach send/read and is not a pass. CUA returned a closed service pipe, so live
content and repeated-capture acceptance remain pending. Headless model and iOS simulator results,
the scoped production fixes and the new local build are recorded in
[build 4 follow-up](ios-nonvm-acceptance.md#build-4-follow-up--2026-09-08).


Computer Use native crash diagnosis and repair limits: [2026-09-08 investigation](computer-use-crash-20260908.md).


Build 6 now passes the previously blocked CUA device-selection/full-tree/window-screenshot
sequence, a real public-text roundtrip, ten phone captures and a second readback. The fix
changes only the Automatic readiness semantic container. See the
[scoped final evidence](computer-use-crash-20260908.md#build-6-formal-app-verification--passed-scoped-checks).
All UI operations in this follow-up used CUA; the restriction against Mac XCTest/global
input remains in force.
