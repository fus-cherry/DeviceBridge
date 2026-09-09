# Quickstart and Validation Guide

## Current startup behavior — Build 9, 2026-09-09

[Startup feedback and persistent build reuse](validation/startup-feedback-and-reuse-20260909.md)
records immediate sidebar feedback, candidate/commit separation, success-only cross-process
compiler claims and real build-only timing (33.650 s cold; 2.359 / 1.689 s after process restart).
It supersedes the earlier per-app-only cache limit. Full device readiness remains separately qualified.

## Preparation display — Build 8, 2026-09-09

See [preparation-ui-20260909.md](validation/preparation-ui-20260909.md) for the shared iOS
preparation stages, elapsed time, cancellation/recovery controls, targeted checks and isolated
Computer Use verification. This UI change does not close the remaining physical-device criteria below.

## Current Build 6 closure sequence — 2026-09-08

Follow T115–T128 in [tasks.md](tasks.md) and record results in
[release-closure-20260908.md](validation/release-closure-20260908.md). Current positive CUA evidence is
[ios-nonvm-acceptance.md](validation/ios-nonvm-acceptance.md); older UI blockers below are historical.
Keep one real DeviceBridge app running. Use Computer Use for every Mac action; do not run the
historical macOS XCTest commands while that restriction is active. VM stability remains deferred.

1. Measure actual selection→ready and build/open phases; retain the build/cache conditions.
2. Run focused manager/launcher/channel regression checks before and after any preparation change.
3. Use only authorized public text for visible clipboard origin/long-text/keyboard/copy/save cases.
4. Capture, copy and save a screenshot; validate the saved PNG. Exercise image preview/original
   export and disposable file operations without overwriting unrelated files.
5. Check Chinese/English layout and session/input preservation. Use one owned fixture app if needed,
   exit it immediately afterward and verify no fixture process remains.
6. Coordinate physical denial/locked/unplug conditions with the user; otherwise leave those cases
   not run. Do not change system privacy, pairing, certificates or target business-app lifecycle.
7. Verify updated local app/DMG and reconcile all current summary links. Developer ID/notarization
   and fresh-Mac launch require actual external prerequisites; document local package limits.

Preparation diagnostics: `bash scripts/check-ios-preparation-timing.sh` defaults to an explicit skip.
An authorized designated-device run supplies `DEVICEBRIDGE_IOS_PREPARATION_TIMING=1`,
`DEVICEBRIDGE_PHYSICAL_UDID`, `DEVICEBRIDGE_PHYSICAL_TEAM`, `DEVICEBRIDGE_PHYSICAL_HELPERS`;
add `DEVICEBRIDGE_IOS_INCREMENTAL_BUILD=1`, `DEVICEBRIDGE_IOS_PREPARATION_SAMPLES=3` for repeated
managers sharing one workspace. `DEVICEBRIDGE_IOS_PREPARATION_BUILD_ONLY=1` performs build,
snapshot and real signature/configuration validation without installing/starting a device channel.
Full mode refuses an existing owned runner. Neither mode issues content commands.
For the complete Core regression on this shared host, use `swift test --package-path
packages/DeviceBridgeCore --no-parallel`: explicit serialization avoids sub-100-ms fixture admission
races observed when unrelated timing suites run concurrently. Keep their failed runs in evidence.

This guide validates the implemented product. Normal users launch one Mac application; helper build
commands are contributor checks, not user installation steps.

## 1. Host Prerequisites

- Apple Silicon Mac running macOS 14 or newer.
- Xcode 15.4 or newer selected as the active developer directory.
- Android SDK Platform-Tools with ADB 37.0.0 or newer.
- At least one authorized Android 11+ device and one authorized iOS 17+ device.
- Trust, pairing, Developer Mode, wireless debugging, and signing configured when the platform asks.

This workstation currently has Swift 6.3.3, Xcode 26.6, `devicectl` 518.33, and ADB 37.0.1.

Current iOS status: the selected personal-signed USB Workspace clipboard round-trip, screenshot
capture/export, image preview/original export and 500 MB file service round-trip have physical
evidence. Rendered desktop workflows, adverse device conditions and clean-Mac first use remain
open; VM stability is deferred by the user. See [current non-VM acceptance](validation/ios-nonvm-acceptance.md)
and [T082 evidence](validation/ios-channel-spike.md). Contributor signing uses an existing local
development identity/profile; do not put a personal Team in shared source, enable provisioning
updates, or register devices without explicit consent. No iproxy installation is currently required
for the bounded USB preflight. Do not infer Wi-Fi support from successful USB startup.
The opt-in [USB experiment](../../scripts/ios-channel-spike/README.md) now has three passing
physical public-marker/cleanup runs. Its environment-based secret bootstrap is rejected because
Xcode persists those values in action logs. Never use a real nonce or user content in this probe.

Read-only preflight:

```sh
swift --version
xcodebuild -version
xcrun devicectl --version
adb version
```

The app must display an actionable tool-missing state if a prerequisite is absent. It must not change
the selected Xcode installation, accept Android licenses, or alter device settings silently.

## 2. Core Tests

From the repository root:

```sh
swift test --package-path packages/DeviceBridgeCore
```

The suite must cover:

- Android USB, Wi-Fi, offline, unauthorized, malformed, and duplicate candidates;
- iOS wired, wireless, unavailable, unpaired, locked, and schema variations;
- wired preference and same-name devices;
- selection generation, cancellation, disconnect, recovery, and late-result rejection;
- subprocess timeout, concurrent output drain, termination, redaction, and output limits;
- four independent content-free readiness probes;
- helper version mismatch, installation state, protocol validation, and lease expiry;
- screenshot validation, transfer integrity, clipboard limits, and memory parsing.

Helper tests:

```sh
gradle -p helpers/android testDebugUnitTest assembleDebug
```

```sh
xcodebuild test -project helpers/ios/DeviceBridgeRunner.xcodeproj \
  -scheme DeviceBridgeRunner -destination 'platform=iOS Simulator,name=iPhone 16'
```

## 3. Native Mac Build

```sh
xcodebuild build -project apps/macos/DeviceBridge.xcodeproj \
  -scheme DeviceBridge -destination 'platform=macOS'
```

Expected:

- A normal native `.app` product is created.
- The app target consumes the local `DeviceBridgeCore` package.
- The app is not Mac App Store sandboxed during internal development.
- No Flutter runtime or target-project plugin is linked.
- Missing helper artifacts produce a build-time or helper-required diagnostic, not a crash.

## 4. One-Application First Use

1. Launch `DeviceBridge.app`.
2. Connect an authorized Android or iOS device by USB.
3. Select the device.
4. Invoke a helper-required capability.

Expected:

- The developer never manually installs a general-purpose companion app.
- The Mac workflow detects and installs or updates the embedded Android APK or iOS runner.
- Only unavoidable device trust, Developer Mode, signing, foreground, or permission steps are shown.
- The Flutter project under test requires no dependency or code change.
- Closing the Mac app stops forwards, runner channels, supervisors, and active helper leases.

## 5. P1: Discovery, Preference, and Switching

1. Attach an authorized Android and iPhone by cable.
2. Launch the app or choose Refresh.
3. Verify both appear within 5 seconds with platform, authorization, health, and wired transport.
4. Enable their supported wireless debugging paths.
5. Verify wired remains preferred and wireless is shown as fallback.
6. Start a delayed fixture operation on device A and switch to device B.

Expected:

- Same-name devices remain distinguishable.
- Header and panels switch within 1 second.
- Device A's late result becomes stale and cannot update device B.
- Clipboard, Flutter VM, screenshot, and file-scope readiness run independently without retrieving
  clipboard text, screenshot bytes, file listings, or file bytes.

## 6. Android Wireless Recovery

1. Pair once using Android wireless debugging.
2. Select the wireless transport and start the managed keep-alive when prompted.
3. Confirm the persistent notification and Stop action.
4. During a four-hour run, inject endpoint changes, temporary network loss, missing mDNS, a long
   transfer, and USB arrival during recovery.

Expected:

- Command-ready samples meet the 99% target.
- At least 95% of eligible drops recover within 15 seconds without re-pairing.
- Recovery never invokes `adb kill-server`.
- mDNS or a Wi-Fi lock alone never means healthy; stable identity and a real command are required.
- Long work defers the heartbeat, and USB affects only subsequent work.
- Stop, deselection, shutdown, or lease expiry releases the Wi-Fi lock and foreground service.

## 7. Clipboard

For Android and iOS, read a unique Unicode value, write a different value, then switch devices.

Expected:

- Exact text arrives in both directions after any required privacy response.
- Selection change clears or invalidates the previous text.
- Payloads do not appear in diagnostics, arguments, settings, or operation history.
- An absent or outdated helper is installed or reported as an actionable helper state.

## 8. Screenshots

Capture distinctive Android and iOS screens, save/copy the successful images, then force a second
capture failure.

Expected:

- Android uses the selected target-specific capture command.
- iOS setup is managed through the bundled runner and distinguishes setup time from warm capture.
- Validated PNG bytes are labelled with device and time.
- A failed capture preserves the previous valid preview.

## 9. Files and Images

### Phone-image feasibility and subsequent acceptance

The Android image browser is implemented. In Files → Images, select a shared folder, Load images,
view the current page of thumbnails, select one image, then Download original. File transfer remains
a separate segmented mode. iPhone USB images are now connected to the same browser: select the
authorized wired iPhone, choose Files and images → Images → Load images, select a tile, then Download
original. PNG/JPEG/HEIC have passed through the actual Workspace/model/provider path. Wireless iPhone
photos remain unavailable. No content is read simply by connecting.

Repeat the production iPhone check without a desktop UI runner (set the exact designated CoreDevice
transport in `DEVICEBRIDGE_LIVE_IOS_TRANSPORT` first):

```sh
DEVICEBRIDGE_LIVE_IOS_WORKSPACE_IMAGES=1 bash scripts/check-ios-images-workspace.sh
```

It loads the current album page, previews/exports existing PNG/JPEG/HEIC fixtures, cancels, refreshes,
reselects and reloads; local test copies are removed. Missing fixtures fail rather than simulate a
pass. See `validation/ios-images-runtime.md` for limitations and the still-required Debug visual check.

Headless presentation regression (does not launch an app/window or a UI test runner):

```sh
bash scripts/check-image-view-model.sh
```

Production backend check on the explicitly designated physical Android phone (set the same exact
ADB path/transport environment variables described below):

```sh
DEVICEBRIDGE_LIVE_IMAGE_LIBRARY=1 swift test --package-path packages/DeviceBridgeCore --filter PhysicalImageLibraryTests
```

This reads one existing screenshot, verifies unchanged export, and removes local temporary copies.
To repeat the earlier opt-in Android feasibility check, set
`DEVICEBRIDGE_LIVE_ADB_PATH` to the installed ADB path and
`DEVICEBRIDGE_LIVE_ANDROID_TRANSPORT` to the freshly resolved designated test-phone transport ID.
Then run:

```sh
DEVICEBRIDGE_LIVE_IMAGE_PROBE=1 swift test --package-path packages/DeviceBridgeCore --filter PhysicalImageAccessProbeTests/androidExistingImages
```

This lists only DCIM/Pictures/Download, pulls one existing screenshot and an existing camera photo
when present, checks original bytes and decodes a thumbnail. It logs no filenames, content or hashes,
changes no phone file, and removes local probe copies. It is not a production-service/UI test.
After adding a camera-photo fixture on the test phone, the stricter opt-in check is:

```sh
DEVICEBRIDGE_LIVE_CAMERA_IMAGE_PROBE=1 swift test --package-path packages/DeviceBridgeCore --filter PhysicalImageAccessProbeTests/androidCameraAndScreenshot
```

This second check MUST fail if either the camera photo or screenshot is missing. It is not silently
qualified by the screenshot-only result. Both cases skip in normal test runs.

Complete T101 with an existing camera-photo fixture and an actually isolated UI session:
Load a chosen source, select an existing photo/screenshot, inspect preview and source labels, export
the original, switch device/source during a delayed request, cancel a transfer, and test a denied
source. Verify byte integrity and no stale preview/save. iOS additionally requires T102's exact-device
correlation, complete catalog and original-format gate before T103 enables the provider.

iOS standalone USB feasibility probe (not production/UI acceptance): set
`DEVICEBRIDGE_LIVE_IOS_TRANSPORT` to the freshly resolved, explicitly designated paired USB phone's
CoreDevice transport ID. Unlock/trust or consent, if required, must be handled manually. Default
execution is hardware association only; it does not open a media session:

```sh
bash scripts/probe-ios-photo-identity.sh
```

Explicit catalog, two bounded still-image samples and real cancellation/late-callback checks:

```sh
DEVICEBRIDGE_LIVE_IOS_CATALOG=1 DEVICEBRIDGE_LIVE_IOS_IMAGE_SAMPLES=1 DEVICEBRIDGE_LIVE_IOS_CANCEL_SAMPLE=1 bash scripts/probe-ios-photo-identity.sh
```

Add `DEVICEBRIDGE_LIVE_IOS_SAMPLE_FORMAT=heic` to select one HEIC instead of the default first two
still images. Missing requested samples fail. Catalog-only mode omits the sample/cancel flags.
Samples are limited to 20 MiB and 100 MP, use unique private temporary directories and are removed
after validation. No phone writes/deletes, automatic consent, desktop UI control, or persistent photo
export occurs. Source length and local export SHA-256 are verified, not remote-source SHA-256.
Initial restriction is not conclusive before opening: content still requires an unrestricted live
session and complete catalog. See `validation/phone-images.md` for the observed -9943 unlock sequence.

### Existing general file transfer

Transfer text, binary, image, and a separate 500 MB fixture in both directions; cancel one transfer
and disconnect another.

Expected:

- Scope, direction, device, phase, cancellation, and outcome remain visible.
- Completed content has matching length and SHA-256 when supported.
- Partial files never appear as completed artifacts.
- Protected locations are blocked with a clear platform-specific explanation.

## 10. Flutter VM and Memory

Android discovery/shared RPC are implemented. Native iOS app-scoped discovery, verified binding
and Workspace monitoring passed on the designated USB phone; T110–T114 are complete. The current
incremental Debug app exposes the qualified USB path. Load/restart/physical route-switch and wireless
acceptance remain T064 work; this is not a promise of compatibility with every Dart/iOS version.
See [the iOS binding contract](contracts/ios-vm-memory.md). A pasted loopback URI alone must not
qualify an iPhone; verify the device route and selected application/process before sampling.

Initial iOS acceptance targets the native persistent USB HTTP path. First run metadata-only
`getVM → getVersion → getVM` on a single owned USB connection and correlate fresh device/app metadata
before and after. The native metadata channel now checks protocol first, then two VM snapshots
and same-owner renewals. It passed on Dart 3.7.2 / VM protocol 4.16 with independent CoreDevice
process and current-store checks. Run focused tests with
`swift test --package-path packages/DeviceBridgeCore --filter 'IOSVM|IOSFlutterVMDiscovery|IOSApplicationProcessProvider|MemoryMonitor|DeviceSessionStore'`.
They cover one-owner RPC, non-drifting timestamp range, app/path/PID/session correlation, bounded
Bonjour hints and close/cancel/stale admission. Explicit `MemoryProbe.swift` checks are separate from
metadata-only probes: two one-shot runs returned two real heap/external samples each; a subsequent
run used production discovery and MemoryMonitor's three-second loop for two samples, then verified
Stop/close. Core 363 tests pass. Discovery admits at most four hints under one shared 60-second
admission deadline, not a guaranteed wall-clock bound including cleanup. These results do not
prove working Workspace monitoring, deliberate load changes, restart or wireless acceptance.

Never save or print the authenticated URI. Verify that
redirect, DDS event, malformed/chunked partial body, deadline and cancellation permanently close
the owner with no reconnect or sample publication. Transport and metadata tests cover these failure
boundaries; binding/one-shot counterparts now have focused tests and recorded physical evidence.
The UI and broader physical lifecycle counterparts remain acceptance targets.

After verified readiness, explicitly select an isolate (auto-select only when unambiguous) and
Start monitoring. In the iOS memory module choose the running application, wait for Ready, then
click Start Flutter memory. No manual URI is used. Discover again renews readiness but does not
restart sampling; Stop closes the binding and requires fresh discovery. The app labels heap and
external memory as shared isolate-group metrics, not OS total memory. Verify
`getVM → getMemoryUsage → getVM` uses that same connection and identity.
Isolate exit/replacement must terminate the old series, even when the VM PID is unchanged. Qualify
Wi-Fi separately; do not infer it from wired metadata. Keep the user's existing DDS/debug session.

Run a debug/profile Flutter application without adding a package. Verify VM readiness, generate
allocations, restart the process, and compare Android OS memory where available.

Expected:

- The VM service is discovered and handshaken without exposing or persisting its URI.
- Samples show source and timestamp; missing fields remain unavailable rather than zero.
- Process restart closes the prior series.
- Unsupported iOS processes are labelled honestly and linked to full profiling tools.
- A Mac or second-phone VM, even with the same PID, cannot populate the selected iPhone's chart.
- Device/route changes discard late samples and require a new verified binding.
- Heap/external values are labelled as Dart VM metrics through a pinned isolate. Dart 3.7.2 reports
  shared isolate-group heap, not exclusive per-isolate or total iOS app memory; do not sum siblings.

## 11. Privacy and Failure Review

Exercise permission denial, missing tool/helper, timeout, malformed output, cancellation, disconnect,
and stale completion. Inspect diagnostics and app-local storage.

Pass conditions:

- Every case ends in an explicit terminal state.
- No clipboard payload, transferred content, screenshot content, VM URI, nonce, or raw device ID
  appears in logs.
- Unsaved artifacts are removed on normal exit or next launch.
- The application makes no unrequested cloud or LAN connection.
