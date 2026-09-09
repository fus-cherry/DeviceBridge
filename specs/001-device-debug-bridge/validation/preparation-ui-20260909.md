# iOS preparation progress — 2026-09-09

Build 8 makes the shared clipboard/screenshot preparation visible. It does not change native
build, signing, device installation, authentication, deadlines, or content access policy.

## Observed problem

The user reported that entering Build 7 showed both clipboard and screenshots preparing, with
the screenshot message appearing as an action-required state. A read-only Computer Use
observation at 10:29:23 found both capabilities ready in the existing mounted Build 7 app.
That observation establishes that this session completed preparation; it does not establish
every session's duration or rule out other startup failures. Previously measured cold build
time was 31.128 s and warm builds within one app workspace were 2.596 / 2.059 s. Those remain
build-stage measurements, not end-to-end readiness measurements.

## Production path and ownership

Device selection creates the existing connection session, then Workspace prepares one iOS
runner shared by clipboard and screenshots. IOSRunnerManager remains the authoritative owner
of build/start state and native resources. Its new read-only preparationState accessor exposes
the existing state. Workspace polls that accessor every 250 ms for display only, checks the
selected session/revision after each await, and rejects cancelled or replaced observations.

The visible stages are device connected, build and sign, and start and verify. Only Workspace's
existing successful authentication and provider binding can finish the presentation as ready;
observing the manager's connected state alone cannot do so. The monotonic elapsed timer freezes
on readiness, failure, or Stop. Session detachment cancels observation and clears the presentation.
Failure retains the last stage and safe recovery message. Cancel uses the existing Stop path;
Reconnect uses explicit device reselection and is disabled during selection, preparation, file
transfer, or memory monitoring. The presentation cannot authorize content commands.

## Verification

- Headless regression first failed on the old screenshot action-required classification:
  `/tmp/devicebridge-preparation-ui-red.log`.
- Updated real Workspace checks passed: actual build/start projection, both capabilities preparing,
  independent file availability, no premature readiness, successful binding, frozen completion,
  Stop, a held observer resuming after cancellation, late prepare results, and existing configuration,
  Wi-Fi, heartbeat, clipboard/screenshot isolation and export invalidation cases.
  Log: `/tmp/devicebridge-preparation-observer-green.log`.
- 18 targeted Core tests in 2 suites passed (IOSRunnerManager and InterfaceLanguage, including
  catalog completeness/template preservation): `/tmp/devicebridge-preparation-core-tests.log`.
- Computer Use exercised the actual IOSPreparationView in a separate, device-free preview app:
  Chinese build/start/failure/Stop; reconnect resets elapsed time; English Stop preserves its elapsed
  value; English preparing and ready; resizing from 620 px to 400 px makes the steps vertical with
  all text and controls readable. The preview uses local synthetic state and is not evidence of a
  physical Build 8 connection. Its first launch timed out in Computer Use; the already-running
  preview was then successfully selected and inspected. It was quit through Computer Use and
  process absence verified. The user's mounted Build 7 process remained running.

New UI copy is available in Chinese and English. Normal preparation uses blue, failures use
orange with recovery actions, and readiness collapses to a green connected status.

## Remaining acceptance scope

Build 8 physical selection-to-ready timing and adverse phone conditions have not been measured.
The outstanding real-device, photo matching, updated file GUI, signing distribution and clean-host
items in [release-closure-20260908.md](release-closure-20260908.md) retain their previous status.
This display change does not claim to eliminate the first build or satisfy those broader criteria.

## Delivered artifact

Release Build 8 compiled successfully (`/tmp/devicebridge-preparation-build8-final.log`). Both the
source and staged application passed strict deep signature verification. The DMG passed
`hdiutil verify` (`/tmp/devicebridge-preparation-dmg-verify.log`).

- Workspace: `dist/DeviceBridge-0.1.2-build8-macOS-arm64-20260909.dmg`
- Download: `/Users/fus/Downloads/DeviceBridge-0.1.2-build8-macOS-arm64-20260909.dmg`
- SHA-256: `0a9a9d33457eb06c767c0354eae0dba05c1f49ca5e182ad5c8562b066977072d`
- Size: 6749345 bytes

The downloaded copy was hash-checked against the verified workspace DMG. Both retain checksum
sidecars. This is a local ad-hoc signed package; Developer ID/notarization remains unqualified.
The final preview was reopened after the accessibility-label adjustment, visually checked, quit
through Computer Use, and its process absence verified again.
