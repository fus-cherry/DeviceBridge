# Capability lifecycle redesign record — 2026-09-16

## Accepted direction

The user authorized re-examining and replacing the architecture and explicitly rejected patch-style
boolean/branch additions. Connection, capability preparation and explicit operation are separate.
Device selection has zero mobile foreground or permission side effects. Clipboard may use an explicit
on-demand foreground transaction; strict no-foreground environments report clipboard unsupported.

## Baseline evidence

- `WorkspaceViewModel.select` synchronously invalidates all capability resources and calls Android
  clipboard preparation; iOS selection then prepares the shared runner.
- Android preparation force-stops/starts the helper Activity and waits for current focus.
- iOS clipboard activates the runner per request and the phone handler restores Home.
- Four readiness enums are combined with global connection and cross-feature busy booleans, allowing
  Ready text while the action is disabled.
- Android maps a null clipboard to empty success; ClipboardService checks publication and finishes in
  separate actor turns.
- Current SwiftPM returns `.build/out/Products/Debug` while the old headless helper consumed a stale
  target-triple `description.json` and SDK path.

## Slice status

- T129 architecture/spec record: complete.
- T130 headless compiler compatibility: Python fixture passed; `check-device-selection.sh` passed.
- T131 selection boundary: complete. Android/iOS selection performs no helper/runner preparation;
  selecting the same healthy device is a no-op; explicit clipboard/screenshot actions own preparation.
- T132 presentation ownership: complete. Four feature-specific readiness enums became one
  session-revision-bound capability state and one action presentation; the global content gate was
  removed from feature admission.
- T133 preparation ownership: complete. Selection has zero clipboard/runner preparation calls;
  reconnect retries the iOS capability without recreating the selected device session.
- T134 clipboard correctness: complete in automated coverage. Publication and operation finish are one
  actor transaction; Android empty/unavailable are distinct; writes are read back; notification consent
  is requested only by the explicit Wi-Fi keep-alive action.
- T135 iOS foreground contract: complete in automated coverage. Clipboard success explicitly reports
  `runnerRemainsForeground`; the runner never presses Home and the UI tells the user to return to the
  prior app. Automatic restoration remains unclaimed pending physical feasibility evidence.
- T136 copy and obsolete path removal: complete. English/Chinese readiness and recovery copy follows
  the same action model and there is no retained selection-time readiness source.
- T137 automated qualification: complete. External physical cases remain open below.

## Structural delta

| Measure | Before | After |
|---|---:|---:|
| Feature-specific readiness enum types | 4 | 1 shared lifecycle |
| Global content-action admission gates | 1 | 0 |
| Selection-time clipboard/runner preparation calls | 2 | 0 |
| Clipboard publication/finish actor turns | 2 | 1 |
| iOS clipboard success routes that press Home | 1 | 0 |

The new state separates `availableOnDemand`, `preparing`, `ready` and `actionRequired`, binds it to the
selected session revision, and derives status text, detail and button admission together. No parallel
legacy state source was retained.

## Automated evidence

- `swift test --package-path packages/DeviceBridgeCore --no-parallel -j 1`: 510 tests in 67 suites
  passed; physical and signing-dependent tests remained explicitly skipped.
- Android Gradle `testDebugUnitTest assembleDebug`: passed, including empty/unavailable clipboard and
  explicit notification-permission policy coverage.
- `bash scripts/check-device-selection.sh`: passed, including first/second-click feedback, same-device
  no-op, retry, Stop and stale-result rejection without device/UI commands.
- `bash scripts/check-ios-runner-workspace.sh`: passed all six runner/workspace groups, including no
  automatic content access, explicit first action, cancellation, Stop and stale-result rejection.
- `bash scripts/check-workspace-inventory.sh`: passed fixture clipboard/memory and inventory lifecycle
  coverage without system clipboard, physical VM, device commands or UI input. It now also compiles
  and runs the previously standalone iOS memory admission check so removed Workspace APIs cannot leave
  that lifecycle verification silently stale.
- `python3 -m unittest scripts/test_compile_core_check.py`: 5 tests passed.
- `python3 scripts/test_helper_packaging.py`: 6 tests passed, 1 environment-dependent test skipped.
- macOS Debug build and iOS runner `build-for-testing` succeeded with code signing disabled.
- `xcodebuild analyze` for the `DeviceBridge` macOS scheme succeeded.
- Localization JSON parsing and `git diff --check` passed.

An earlier unconstrained full Core run exposed two timing-sensitive failures under concurrent load.
Both suites passed alone, and the required full serial run above passed. This record treats the serial
result as qualification evidence and does not conceal the parallel scheduling sensitivity.

## Physical evidence still open

- A MuMu Android 12 emulator passed the production Workspace selection path: the Settings application
  remained foreground, clipboard showed `Available on demand` with enabled actions, and the helper
  became foreground only after the first explicit read. The same run verified exact Unicode write/read
  and explicit empty write/read without confusing empty content with unavailable content.
- The opt-in `PhysicalDeviceTests` suite passed on the same designated emulator: decoded 2160×3840
  screenshot, two memory samples across the monitoring interval, clipboard round trip/restoration with
  no permission UI in front, and a 65,536-byte Downloads round trip with SHA-256 and cleanup.
- Equivalent selection/clipboard evidence on designated Android hardware remains open. Android 13+
  notification denial is also still open because this emulator runs Android 12; the policy unit test is
  the current evidence for that branch.
- An unreadable non-text Android clipboard item still needs a designated-device trial.
- iOS must be checked with a real prior debugging app for runner foreground disclosure, cancellation,
  Stop and whether platform-supported restoration is feasible; no automatic restoration is promised.
- Existing signing, pairing, wireless soak and release-acceptance tasks retain their original status.

No physical-device result is inferred from fixtures. No permission, signing, pairing or target
business-application lifecycle change is authorized by this record.
