# Background physical-device checks — 2026-09-07

## Read-only regression after image implementation — 16:20

Android production image catalog/preview/original export, screenshot and memory continuity plus
iPhone command readiness passed: **4 executed / 2 mutation tests skipped**. The host runner now has
streaming output quotas; this rerun verifies the changed boundary on both designated phones.
See [phone-images.md](phone-images.md) for image scope and exact evidence. No desktop input, phone
image modifications or permission changes occurred. Earlier clipboard/file round-trips below were
not rerun in this read-only check.

## Production fixes and repeat verification — 15:19

This follow-up supersedes the two failures in the historical table below.

- Android memory now uses kernel `/proc/<pid>/stat` field 22 (start ticks), not elapsed runtime.
  Discovery obtains bounded process metadata in one batch; selected-process sampling rejects
  unavailable/malformed identity instead of treating it as a stable match. Parser coverage includes
  spaces/parentheses in process names and PID reuse with different start ticks.
- Helper preparation now waits up to 10 seconds for the listening abstract socket and focused helper
  window before returning a candidate channel for authenticated handshake. The host does not click
  permission dialogs or read clipboard contents to probe readiness. Stop/detach invalidate pending
  preparation; cancellation/timeout clean the exact candidate forward in cancellation-independent
  cleanup. New preparation is excluded while the old helper is being stopped. Reattach still avoids
  foreground launch/reset and still requires the existing identity/nonce authentication by its caller.
- The physical test's diagnostic-only socket wait was removed. Both 15:15:53 and 15:19:06 test runs
  passed all five physical cases through production adapters: Android 1080×2400 screenshot, memory
  continuity across 3 seconds, Unicode clipboard round-trip and text-restoration readback, 64 KiB
  Downloads transfer with SHA-256, and iPhone command readiness.
- Fresh default core run at 15:18:42: 149 discovered tests, 5 explicitly skipped physical tests,
  144 executed, 30 suites, exit zero. macOS Release build also exited zero. No desktop UI automation
  was run. Android Helper stayed at installed version 2; no phone installation/update was performed.

Red-to-green evidence: memory regressions failed at 15:12:09 and passed at 15:12:58; delayed helper
readiness/stop regression failed at 15:13:33 and passed at 15:14:43; overlapping cleanup/preparation
regression failed at 15:18:16 and passed in the 15:18:42 full suite. Timeout, cancellation, exact
forward removal, and non-resetting recovery attach are covered by focused tests.

T035 and T060 implementation fixes are closed. T041/T064 remain open for broader platform and
workflow qualification. Startup focus evidence is not a guarantee of later background clipboard
access: Helper v2 can still return null/empty if focus changes after startup. A phone-side per-request
focus/access failure check remains necessary; no unrestricted background clipboard claim is made.
Text restoration does not preserve arbitrary non-text ClipData formats.

Phone-image discovery/preview/original export was **not implemented or tested** by those earlier file checks;
the subsequent dedicated implementation and USB image validation are linked above.
The user's image-first clarification is tracked as FR-P01–FR-P03 and T098–T101. iOS photo access,
iOS clipboard/screenshot content channel, actual Flutter target/VM memory, and long-running wireless
recovery remain unqualified. The 64 KiB USB result does not qualify large files or wireless behavior.

## Scope and desktop isolation

The user confirmed the connected PLD110 Android 16 and iPhone 12 iOS 18.3.1 are test phones.
Both were wired and accepted targeted commands. No Wi-Fi route was present in the checked inventory.
No Mac UI tests, mouse events, keyboard events, input-source changes or permission approvals were
performed in this run. The current Computer Use API has no exposed isolated picture-in-picture
control. Do not substitute foreground/global automation while the user works.

MobAI MCP was not available; its CLI reported connection refused on the local API, and its skill's
referenced DSL file was absent. The declared fallback used the product's ADB/CoreDevice boundaries
in background Swift tests. It did not open the MobAI or DeviceBridge Mac UI.

## Real results (not fixtures)

`PhysicalDeviceTests.swift` instantiates the production `HostCommandRunner`, discovery, inventory,
command probe, screenshot/memory/file providers, Android helper manager, authenticated TCP channel
and clipboard service. These are backend integration checks, not proof of the full Mac UI workflow.

| Check | Result | Evidence |
|---|---|---|
| Android discovery + readiness + screenshot | PASS | 14:54:16 run; actual PNG decoded in memory at 1080×2400 |
| iOS discovery + selected-device readiness | PASS | Same run; paired wired iPhone accepted device-info command |
| Android memory continuity | FAIL | Initial sample succeeds; after 3 seconds PID unchanged but provider reports restart |
| Android Downloads send/receive | PASS | 14:56:36 run; 65,536 generated bytes round-trip, both remote receipts and local SHA-256 match |
| Android cold-start clipboard handshake | FAIL | 14:56:36 / 14:57:54; production prepare returns before usable socket; TCP connectionClosed |
| Android clipboard with diagnostic readiness gate | CONDITIONAL PASS | 15:00:15; socket registered and helper focused; Chinese/emoji round-trip and restoration readback match |

Screenshots and clipboard payloads were not logged, attached or persisted. The file test removed
only its unique generated remote file/stage and local temporary directory. No personal files were
removed. The already-installed helper version was 2; no install/update occurred. The test closed
its helper session and exact ADB forward; final checks found neither a remaining helper process
nor ADB forwards.

An earlier diagnostic run at 14:58:29 passed handshake but failed clipboard readback. It attempted
to restore the text returned by the initial read; matching empty/unavailable reads cannot prove
restoration of the original full clipboard (including non-text formats). The test now refuses to
write unless current window focus is demonstrably the helper. A first focus diagnostic used
`dumpsys window windows`, which omits the current-focus field on this phone; the corrected command
uses `dumpsys window` and requires that the field exists. This diagnostic correction is not a
production fix and the earlier mismatch's focus state was not captured.

## Defects exposed

1. `AndroidMemoryProvider` assigns `ps ELAPSED` to `processStartIdentity` and compares it between
   samples. ELAPSED advances while a process runs, so the existing restart comparison rejects an
   unchanged process. Replace it with a stable process-lifetime identity while preserving real PID
   reuse/restart detection. T060 reopened; T064 still unqualified.
2. `AndroidHelperManager.prepare` returns after `am start`, without proving socket readiness or
   foreground clipboard access. A separate diagnostic socket gate permits handshake, and a
   focused helper permits the clipboard round-trip. This is not evidence that the current normal
   startup flow works reliably. T035 reopened; T041 remains open. Background clipboard null reads
   must also not be confused with verified empty clipboard data.

No production fix was applied in this diagnostic/test request. iOS content channel implementation,
Flutter target/VM validation, app-private file scope, 500 MB/cancellation, wireless fault injection
and long-duration recovery remain outstanding. Do not extrapolate the 64 KiB wired file result.

## Reproduction and explicit gates

Resolve current transport IDs on each run; never reuse the original ephemeral ADB transport ID.
Set `DEVICEBRIDGE_LIVE_ADB_PATH`, `DEVICEBRIDGE_LIVE_ANDROID_TRANSPORT`, and/or
`DEVICEBRIDGE_LIVE_IOS_TRANSPORT` for the intended test phones, then run:

```sh
swift test --package-path packages/DeviceBridgeCore --filter PhysicalDeviceTests
```

Clipboard/file cases require the additional explicit opt-in
`DEVICEBRIDGE_LIVE_ANDROID_MUTATIONS=1` and a dedicated test phone. Clipboard restoration preserves
text only, not arbitrary ClipData formats. The former diagnostic-only flag
`DEVICEBRIDGE_LIVE_WAIT_HELPER_SOCKET=1` was removed after the production readiness fix. Historical
diagnostic results above are not normal-startup passes. Without live flags,
all five physical cases are skipped rather than silently contacting devices.

## Mac input-method popup diagnosis

The user's screenshot requests that `testmanagerd` enable Sogou Pinyin. It is an input-method trust
dialog, not device clipboard consent or a DeviceBridge permission requirement. The Mac UI tests
call `typeText`/`typeKey`; the production clipboard actions send authenticated helper messages and
do not select Mac input sources. Apple's [typeText documentation](https://developer.apple.com/documentation/xcuiautomation/xcuielement/typetext(_:))
describes synthesized keyboard input requiring focus. Together these support the test-input path
as the leading explanation for the recurring prompt. No new disruptive reproduction or approval
was attempted, so exact re-prompt policy and attribution of every earlier UI failure remain unproven.
Do not enable Sogou, reset TCC, or change the user's input source to make these tests pass. Resume
desktop UI automation only in a verified isolated session or with explicit foreground-test consent.
