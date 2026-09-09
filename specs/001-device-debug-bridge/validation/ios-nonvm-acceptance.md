# Remaining iOS non-VM acceptance — 2026-09-08

## Build 7 closure update — 2026-09-08

Incremental build reuse and file receive staging are implemented, tested and locally packaged.
Build-stage warm samples: 2.596/2.059 s versus 31.128 s cold; signatures/configuration passed. Do not
interpret these as complete connection latency. Current Build 6 CUA added long Unicode text
roundtrip/expand/copy/save, screenshot copy/save/cancel and Chinese/English/system switching.
Two GUI file receives stalled in CoreDevice bookmark/getxattr; cancellation left no process or partial.
The staging fix passed 10 unit/service checks plus a real 64 KiB provider roundtrip; new GUI retest
requires switching the active app. iPhone photo loading returned an unmatched USB photo-device
message, so its current preview/export is not qualified.

Original-source/adverse conditions, full Build 7 UI and clean-host distribution remain open;
[release-closure-20260908.md](release-closure-20260908.md) records evidence and prerequisites. Prior
positive backend results below remain historical, not replacements for current rendered acceptance.


## Build 6 Computer Use and physical content follow-up — 2026-09-08

The earlier CUA blocker is now bypassed in DeviceBridge by replacing only the Automatic
readiness GroupBox with a plain layout. Controlled fixture variants rejected the initial
clipboard-container hypothesis. Full details: [CUA investigation](computer-use-crash-20260908.md).

The real Build 6 app passed CUA device selection, full AX read, window screenshot, public
clipboard send → clear editor → exact readback, ten consecutive 1170×2532 phone captures,
and another clear → exact clipboard readback after captures. Capture + CUA confirmation
ranged 1.852–2.414 seconds (mean 1.9983). No service restart was observed during this sequence.

This supersedes earlier pending status for this specific positive roundtrip and short capture
series. VM remains deferred. Save/export, privacy-denial/locked states, disconnection trials,
long-duration stability and arbitrary clipboard-content coverage remain outside this result.
Local delivery: `dist/DeviceBridge-0.1.2-build6-macOS-arm64-20260908.dmg`.


## Build 4 follow-up — 2026-09-08

This follow-up supersedes earlier statements below that production code was unchanged. The user
reports an empty DeviceBridge read while pasting on the iPhone produces content. That physical
failure remains unqualified; the fixes below address independently reproduced failure paths.

- Empty pasteboard text-item lists now return `clipboard.unavailable` / action required instead
  of successful empty text. An explicit empty string item remains valid. A real named simulator
  pasteboard reproduced the old failure before this change.
- Foreground activation failure/timeout before the request deadline now releases the clipboard
  reservation and returns explicit recovery advice while preserving a live authenticated runner
  channel. Cancellation, expired deadlines, dead runners and Stop remain terminal. A real TLS
  test verifies heartbeat, screenshot data, explicit retry and replay rejection after failure.
- iOS screenshot and clipboard UI controls and entry points now reject overlapping operations
  locally. The workspace regression reproduced the previous overlapping-request behavior.
  Android behavior is unchanged.

Fresh verification: full Core run passed (374 aggregate methods, 13 opt-in skips, 361 executed;
56 suites, `/tmp/devicebridge-stability-core-recheck.log`). The initial concurrent run hit an
existing 40 ms launcher-test timing failure; the isolated test and full serial rerun passed.
iOS simulator ClipboardCommands/ScreenshotCommands tests passed 39/39 in
`/tmp/devicebridge-clipboard-helper-final-20260908.xcresult`. Workspace checks passed all four
groups in `/tmp/devicebridge-workspace-content-slot-green.log`; packaging tests passed five
with one opt-in skip in `/tmp/devicebridge-stability-packaging.log`. Independent review found
no actionable defects in the scoped recovery change. These are not physical content trials.

Release build 0.1.2 (4) compiled successfully; strict deep signature verification passed and bundled
helper sources and Chinese localization match current sources. Local delivery:
`dist/DeviceBridge-0.1.2-build4-macOS-arm64-20260908.dmg`. The running older app was not replaced
or terminated. No initial connection-speed improvement is claimed; preserved-channel recovery
avoids unnecessary re-preparation in the tested activation-failure path.

The user authorized public fixture replacement, then explicitly restricted desktop interaction to
Computer Use. The attempted live XCTest clipboard round trip failed during text synthesis and was
cancelled, without reaching send/read. The screenshot repetition trial did not establish product
failure or stability; its metadata assertion needed correction and the retry was cancelled.
No further Mac XCTest/global desktop input was used after that restriction. Computer Use still
returned a closed native-service pipe. Physical round trip and repeated captures remain pending
user interaction or restored Computer Use. Only public test text should be used for this trial;
never read or back up unrelated existing clipboard contents.


## Latest user feedback and UI diagnosis — 2026-09-08

The user reports that the shipped DMG's iOS image browsing and memory worked, but clipboard
and screenshots remained disconnected. This is user-reported acceptance, not an automated pass;
VM testing remains deferred. Historical provider and packaging results below do not override it.

The first live XCTest result `/tmp/devicebridge-ui-live-ios-20260908.xcresult` contains one failed
test (about 339.7 seconds), zero passes. Activities bind to PID 14859, select the designated phone
at 17:15:38 and the screenshot module at 17:15:39. The last recorded AX snapshot request for that
PID is 17:21:02.709; querying preparation advice fails at 17:21:13.607 because the app is no longer
running. AppKit logs show normal `terminate:` at 17:21:03.447 and termination completion at
17:21:03.577. This does not establish a crash or a runner failure layer.

During takeover, CUA read the exact dist app window but a device-row click produced no AX change;
subsequent screenshot access returned `Sky Computer Use native pipe closed before response`.
`SkyComputerUseService-2026-09-08-172454.ips` records SIGTRAP/EXC_BREAKPOINT with
`_assertionFailure` and `Array.remove(at:)` on the faulting stack. This is the automation service,
not DeviceBridge. No permissions or automation binaries were changed.

The initial takeover XCTest `/tmp/devicebridge-ui-live-ios-20260908-takeover-1.xcresult` failed
its new single-running-instance precondition with count zero, before device/content operations.
PID 29526 had completed normal termination at 17:25:14.724. The user then confirmed having
closed the app and authorized continuation. Do not attribute these exits to a product crash.

The opt-in diagnostic now checks one running instance and its exact bundle path, stops on failed
assertions, reports readiness transitions during the bounded wait, and stops if the app exits.
It retains the screenshot-preview assertion and does not read/write clipboard content or start VM.
Production behavior is unchanged. Failure attachments can contain private screens; retain locally.

### Fresh visible UI pass, with remaining boundary

After the user's confirmation, the dist app was opened and the existing targeted XCTest was
rerun using `/tmp/devicebridge-ui-live-ios-20260908-takeover-2.xcresult` and sibling `.log`.
Fresh xcresult summary: **1 passed, 0 failed, 0 skipped**. Activities show phone selection at
17:27:07.668, screenshot module at 17:27:10.250, clipboard module at 17:27:58.368, screenshot
capture click at 17:27:59.709, and screenshot-preview existence at 17:28:01.223. The passing
assertions require enabled screenshot and clipboard-read controls before capture. No clipboard
content read/write, VM start, screenshot copy/save or phone business-app restart was performed.

Target: `dist/DeviceBridge-0.1.2-test-20260908/DeviceBridge.app`, PID 32550, one instance.
Before this run, both its executable and the mounted 0.1.2 DMG executable had SHA-256
`ab470a171c3edb1a8c8767db6d374e15d3fa5a7157f482c57223083923500201`; both app signatures
verified. This is executable equivalence, not proof of identical launch environment. The observed
production child command used bundled Helpers and fresh attempt
`9A431FBF-8AEA-48E2-B54A-0D1FBD6D2232` in `DeviceBridgeRunnerBuilds`; products include a
physical-iOS `.xctestrun`. No production repair was needed for this successful run.

**Still unresolved:** the user's original persistent disconnection is not reproduced under this
single-instance dist launch. Read-only DMG launch and multiple-instance effects remain hypotheses;
clipboard content transfer remains untested by design. A controlled exact-DMG comparison requires
permission to exit the current app to preserve single-instance conditions. CUA's native-service
crash is separately evidenced and remains unresolved. No overall feature acceptance is claimed.

## User-directed DMG handoff — 0.1.2 (3)

After confirming permissions and authorizing alternative automation or a DMG, the user requested
a package for manual validation if reliable UI automation remained unavailable. AppleScript had
returned explicit auxiliary-access denial; existing XCTest UI fixtures are another engineering
route but cannot substitute for actual iPhone/desktop acceptance. No permission bypass, further
app restart, or claim of recovered Computer Use was made for packaging.

Fresh Release build:

```sh
xcodebuild build -quiet -project apps/macos/DeviceBridge.xcodeproj -scheme DeviceBridge \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/xcode-release-acceptance-20260908 \
  CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= MARKETING_VERSION=0.1.2 CURRENT_PROJECT_VERSION=3
```

Exit 0; version overrides apply to this artifact, not a source version edit. The app has ad-hoc
Hardened Runtime signing and an empty entitlements dictionary, no Developer ID identity or
notarization. No account, certificate/profile or provisioning change was made. Existing dist
artifacts and the running Debug app were preserved.

- Core: 357 executed methods passed / 13 opt-in skips / 56 suites. Log:
  `/tmp/devicebridge-dmg-20260908-core.log`.
- Android: local cached Gradle 8.11.1 ran `testDebugUnitTest assembleDebug`, exit 0;
  16 unit tests, no failures/skips. Bare `gradle` was absent from PATH, so no tool was installed.
  Log: `/tmp/devicebridge-dmg-20260908-android.log`.
- Packaging checks: 5 passed / incremental-signing opt-in skipped. Log:
  `/tmp/devicebridge-dmg-20260908-packaging.log`.
- Build and read-only mounted DMG app both pass `codesign --verify --deep --strict`.
  The mounted executable matches the build; bundled APK matches the freshly built APK.
  Both local iOS Swift-package manifests are present. Binary is arm64 with system library links.
- `hdiutil verify` reports VALID; read-only mount succeeded and the exact verification volume
  was detached afterward. Applications shortcut resolves to `/Applications`.
- Output: `dist/DeviceBridge-0.1.2-test-macOS-arm64-20260908.dmg`, 6,692,993 bytes.
  SHA-256: `2c78e423d3ba797e77205a647270c0b6ec71d0185e4845dc3d35ad8f2f0fd2a6`.
  A sibling `.sha256` file and included `验收说明.md` accompany the package.

This verifies the packaged artifact, not Gatekeeper acceptance, fresh-Mac onboarding, rendered UI,
or new physical device trials. The instructions ask the user to quit the old app, copy the new app
to Applications and confirm version 0.1.2 (3). VM stability remains deferred. All story-level
acceptance gaps below remain open pending manual results.

## Subsequent UI authorization and control blocker

The user later explicitly permitted a DeviceBridge restart. The exact running Debug process was
checked, terminated with SIGTERM, confirmed exited and relaunched from the same absolute path.
No phone process was terminated. After resetting the automation session, the empty device-selection
window could be read again. Attempting to click the designated iPhone again returned the native
pipe error. A subsequent full AX snapshot still showed no selected device; no successful selection
or feature operation is claimed. A second click and combined full-AX/screenshot check also failed.

The corresponding local `SkyComputerUseService-2026-09-08-164804.ips` report identifies the
automation service, not DeviceBridge, terminating with `EXC_BREAKPOINT` / `SIGTRAP`; its faulting
stack contains Swift `_assertionFailure` and `Array.remove(at:)`. The relaunched DeviceBridge
process remains present. Disabling AX diffing allowed one full snapshot but did not restore clicks
or the combined snapshot, so a diff-only cause/workaround is not established. No permissions,
automation binaries or production code were changed. Restarting the target did not resolve the
UI acceptance blocker; do not keep restarting it as a substitute for a tool fix.

The user subsequently authorized interaction with DeviceBridge and its own save dialogs only.
VM monitoring and other Mac apps remain outside scope. The first full-Debug-path `getApp` attempt
failed with `Sky Computer Use native pipe closed before response`; resetting the UI session and
retrying produced the same error. Application enumeration succeeded and listed DeviceBridge as
running. Bundle-ID selection was ambiguous because multiple local products share that ID;
returning to the exact Debug path still failed. No click, typing, save operation or phone action
was sent. The fault is observed at window-control access; its root cause is not established and
this is not evidence that a DeviceBridge business operation failed. Visible workflow acceptance
remains pending despite the user's granted input authorization.

## Initial pass scope

User direction: defer VM stability and proceed with remaining iOS workflows. This is a scoped
acceptance pass, not permission to implement wireless support, reset device permissions, restart
the target application, change signing identities, or take over desktop input. T064 is deferred,
not passed. No production code changed in this pass.

## Fresh automated evidence

All commands below exited zero. Physical opt-in skips are not successful device trials.

| Command | Result | Local log |
|---|---|---|
| `swift test --package-path packages/DeviceBridgeCore --filter 'IOSRunner\|IOSFile\|IOSPhoto\|Clipboard\|Screenshot\|FileTransfer\|Helper\|Configuration'` | 133 executed methods passed, 9 opt-in methods skipped; 24 suites, aggregate 142 | `/tmp/devicebridge-ios-nonvm-acceptance-core.log` |
| `swift test --package-path packages/DeviceBridgeCore --filter 'ToolchainPreflightTests\|DeviceDiscoveryServicesTests\|IOSUSBMuxConnectionTests\|IOSImageAccessTests\|Localization'` | 31 methods passed, no skips; 5 suites | `/tmp/devicebridge-ios-nonvm-acceptance-boundaries.log` |
| `python3 scripts/test_helper_packaging.py` | 5 passed, incremental-signing opt-in skipped | `/tmp/devicebridge-ios-nonvm-acceptance-packaging.log` |
| `bash scripts/check-ios-runner-workspace.sh` | Three acceptance groups passed after test-only extension | `/tmp/devicebridge-ios-nonvm-acceptance-workspace-expanded.log` |
| `codesign --verify --deep --strict .build/xcode-derived/Build/Products/Debug/DeviceBridge.app` | Existing on-disk Debug signature verified | No signature identity logged |

The Workspace test now additionally exercises a parsed Wi-Fi candidate and all five configuration
failure classes: missing signing Team, missing bundle, invalid manifest, missing sources, unsafe
paths. It requires explicit USB-only advice without runner launch/content access on Wi-Fi, and
classified first-use advice with independent file readiness retained on configuration failure.
Existing explicit read/write, denial/expiry advice, no silent retry, late-result rejection,
10-second metadata heartbeat, route replacement, failed heartbeat and Stop checks also passed.
External device/configuration failures are injected fixtures; they do not prove physical denial,
network reconnection, fresh-Mac installation, or visible-button interaction. No assertions or
production guards were relaxed.

## Current physical/UI observations and remaining steps

- Fresh MobAI inventory found the designated physical iPhone ready over USB, bridge running.
  No screen action, permission response, clipboard replacement or file transfer was sent this pass.
- Read-only native desktop observation succeeded: the running DeviceBridge window exposes the
  Chinese language selector, refresh control, device sidebar and empty “选择设备” state. No device
  was selected and no mouse/key event was synthesized. This is accessibility evidence only;
  clipping, save panels and actual content flows remain untested in the rendered window.
- Earlier physical positive results remain in [clipboard](us2-clipboard.md),
  [screenshots](us3-screenshot.md), [files](us4-files.md) and
  [images](ios-images-runtime.md). They are retained historical evidence, not rerun here.

| Remaining acceptance | Disposition / next discriminating step |
|---|---|
| Mac clipboard, screenshot save, image preview/export, file controls and Chinese layout | DeviceBridge-only input is now authorized, but window-control access fails as recorded above. Start by selecting the connected iPhone and verifying preparation/readiness once control is available, or use user-driven interaction. Do not start VM monitoring. |
| Physical paste denial and locked/protected screens | Pending coordinated phone interaction; do not reset system privacy settings or dismiss unrelated alerts. Permission-pending Stop already has earlier physical evidence, but is not denial evidence. |
| USB disconnect during a transfer, stale-result exclusion and reconnection | Pending coordinated physical unplug/replug with a disposable fixture; synthetic route/Stop checks above do not substitute. |
| iOS wireless | Current production screenshot/clipboard preparation explicitly requires `.usb`; USB endpoint selection also rejects non-USB entries. Image browser is installed for USB camera import only. Unsupported-boundary behavior now passes at Workspace level. Actual wireless discovery/files and a wireless helper implementation are not qualified. Full wireless acceptance remains open. |
| Clean-Mac first use and signing/permission recovery | Packaging relocation and configuration errors pass in fixtures; this already-provisioned workstation cannot prove fresh installation. A separate clean host/account and user-controlled existing signing setup remain necessary. No certificates/profiles were created or removed. |

No overall T036/T041/T048/T056/T082/T084/T090/T097/T101 completion is claimed. The next acceptance
step requires visible UI interaction, not more repetition of already-proven backend happy paths.
