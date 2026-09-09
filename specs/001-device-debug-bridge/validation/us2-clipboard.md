# US2 Clipboard Validation

Date: 2026-09-08

## Fresh non-VM Workspace round-trip — PASS

`devicebridge-nonvm-workspace-0271ppyy`: normal production Workspace authorization, explicit
disposable Unicode clipboard WRITE followed by READ and full equality, screenshot decode/export,
authenticated renewal and Stop/owned-runner exit passed in 50.230 seconds (physical process exit 0).
Fresh pre/post checks found the same paired wired phone and no remaining named runner.
The optional coexistence mode was not enabled: no VM sampling or target-app restart. No global
desktop input or new paste-prompt action. This is real Workspace/backend execution, not a mouse
acceptance check of the running Debug app.

## Latest: authenticated Stop during a real paste prompt — PASS

`devicebridge-paste-pending-stop-wvfwbz_u`: the diagnostic Host set and verified the authorized
disposable source fixture. The normal Runner began its encrypted READ. MobAI matched the exact
selected-phone test paste alert, then wrote only a fixed marker into this run's fresh private gate
file. The host test independently required the READ task to still be unfinished before sending
the normal authenticated Stop request. **No Allow or Deny tap was sent.**

Stop returned success and the pending READ terminated without text within the asserted **five
seconds**. The channel no longer exposed an authenticated context. The normal signed phone test
and native process exited successfully; xcresult required **1 passed / 0 failed / 0 skipped**,
nonce/public Stop-ID log checks and owned cleanup passed. Host physical test **1 passed in
10.456 s**; the **15.815 s** outer duration includes pre-test startup and is not Stop latency.
Independent metadata confirmed the same paired wired phone and no named Runner. A separate
post-test MobAI observation succeeded and found no exact test paste alert.

The opt-in `DEVICEBRIDGE_MANAGED_PASTE_STOP_GATE` requires cross-App-source mode and a gate path
that does not already exist. It is a test-only synchronization boundary, not a product command or
permission bypass. Normal cross-App content qualification still requires complete text equality
and forty-second renewal; this terminal Stop scenario intentionally does **not** claim that renewal.
Its shared process/result/signature/cleanup verification remains unchanged. Production code and
the running Mac Debug app were not changed or restarted for this test.

Fresh regression log `/tmp/devicebridge-paste-stop-core-final.log`: **354 test methods passed,
13 explicit opt-in methods skipped, 56 suites**, no failures, 15.985 s. Reporting correction: Swift
Testing's summary says “367 tests … passed”, but that total includes the 13 skipped methods.
Earlier notes quoting 367 as passed should be read as a successful aggregate run, not 367 executed
tests and never proof of those skipped physical scenarios. The separately opted-in physical Stop
run above executed successfully; it was not skipped.

This qualifies selected-USB cancellation while the real paste permission is pending, not physical
permission denial, locked/protected screens, wireless, or a desktop Stop-button interaction.

## Latest: physical cross-App multi-item clipboard — PASS

`devicebridge-cross-app-multiple-bc5te2lr` used the separately compiled diagnostic source Host
to write four actual general-pasteboard text items: Chinese/Emoji, an empty item, an item with an
embedded newline, and Bengali text. The Host required its own `UIPasteboard.general.strings`
readback to equal the entire four-item array before publishing the fresh public source-ready
receipt. The normal Runner READ then returned the independently specified full newline-joined
value, including the consecutive newlines contributed by the empty item and the original order.
First-item-only, dropped-empty-item and reordered results cannot satisfy the equality assertion.

MobAI observed the exact test paste alert and its single authorized Allow Paste tap succeeded.
The encrypted read returned success and exact equality; the same session continued forty-second
identity renewal, authenticated Stop and owned native cleanup. Host **1 test passed in 50.874 s**;
the outer harness took **58.767 s**, which is not clipboard latency. Independent after-checks
confirmed the same paired wired phone and no named Runner; a separate final MobAI observation
succeeded and found no exact test paste alert. No original clipboard restoration is claimed;
the phone retains the authorized disposable source fixture.

Diagnostic build: `devicebridge-cross-app-multiple-build-_wu3iild`, existing personal Team only,
all three signed artifact roles strictly verified by the physical harness. The additional
`--devicebridge-clipboard-source-multiple` launch flag exists only inside the existing
`DEVICEBRIDGE_CLIPBOARD_SOURCE_PROBE` compile gate. The physical test's
`DEVICEBRIDGE_MANAGED_CLIPBOARD_MULTIPLE=1` requires explicit cross-App-source mode; it does not
turn a normal READ-only run into a source write. Ordinary Host behavior and production clipboard
code were unchanged. No Mac Debug restart was needed for these test-only changes.

Fresh Core regression **367 tests / 56 suites passed**, 17.183 s
(`/tmp/devicebridge-multiple-core.log`); helper packaging **5 passed / 1 skipped**, 1.666 s
(`/tmp/devicebridge-multiple-packaging.log`). This qualifies selected-USB multi-item source and
normal Runner reading; it does not claim Mac visual interaction, physical denial/locked behavior
or wireless transport acceptance.

## Latest: preserve classified recovery advice in the Mac UI

Root cause: `ClipboardService.failureOutcome` already returned distinct safe error/recovery
messages, but `WorkspaceViewModel.applyClipboardOutcome` discarded `recoveryAction` and the
view displayed only the summary. Workspace now publishes the already-classified recovery key;
the view translates it separately, without rendering arbitrary helper error text. Explicit retry,
success, selection, disconnected-content invalidation, Runner invalidation and overall Stop clear
obsolete advice. Existing cancellation checks still block late publication. No native state,
permission policy, retry timing or helper failure classification changed.

While an iOS clipboard operation is busy, a bilingual conditional hint asks the user to keep the
phone unlocked and review any paste prompt **if it appears**. This is not OS-prompt detection and
does not automatically click a permission. An export-specific error temporarily takes precedence
over clipboard recovery advice so the two operations are not conflated.

`/tmp/devicebridge-clipboard-recovery-red.log` reproduced missing recovery advice. The final
headless production-model check passed: permission-denied versus expired recovery, no failed
payload publication, no untrusted helper text, no silent retry, clearing on explicit retry/success,
selection and failed heartbeat, plus prior clipboard/screenshot ownership checks
(`/tmp/devicebridge-clipboard-recovery-final.log`). Localization **6 tests passed**, including
catalog/template completeness (`/tmp/devicebridge-clipboard-recovery-language.log`). Incremental
Debug build passed with an empty build log (`/tmp/devicebridge-clipboard-recovery-debug.log`).
These are presentation/model checks, not a claim of fresh physical denial or timeout acceptance.
The strict-verified Debug bundle was restarted in the background after confirming the previous
app had no children; latest process PID 82862 was observed. No desktop input or Release build.

### Physical maximum-size Unicode follow-up

`devicebridge-workspace-clipboard-maximum-8ll48gj_` passed the production Workspace path with
ordinary bundled helper sources, the same existing personal signature and exact selected wired
phone. With both explicit replacement and `DEVICEBRIDGE_WORKSPACE_CLIPBOARD_MAXIMUM=1` opt-ins,
the fixture contains 87,381 twelve-byte UTF-8 units (`你好 📋` plus newline), then four fresh ASCII
characters: exactly **1,048,576 bytes**. WRITE succeeded; a separate READ matched the entire fresh
fixture exactly. No prefix-only/hash-only acceptance or content logging was used.

The same run renewed the session, decoded a screenshot, exported exact image bytes, stopped and
left no named native Runner. Independent metadata confirmed the same paired wired phone; MobAI
observations succeeded before/after without a recognized test paste prompt or an approval tap.
The **52.469 s** outer duration includes bundled-source build and lifecycle work, not clipboard
latency. The phone retains this authorized disposable test fixture; no original backup/restoration
is claimed. This closes the selected-USB maximum-text round-trip gap, not physical multi-item,
denial/locked/wireless or visible long-editor acceptance.

## Latest: T036 Workspace clipboard binding and physical round trip

The production Workspace now binds explicit clipboard Read/Send to its existing authenticated
USB Runner, not to inventory presence or a second helper. `IOSRunnerClipboardChannel` exposes a
metadata-only context only while the live launch negotiated **both** clipboard actions. Workspace
requires that context to equal its authenticated screenshot context, rechecks captured selection
revision/store session after the asynchronous query, then publishes services/readiness together.
The existing ten-second identity heartbeat owns the shared lifetime; Android's helper context and
independent image/file/memory owners are unchanged. No automatic clipboard access or OS approval
was added to the product.

Runner Stop, route invalidation and failed heartbeat synchronously remove clipboard readiness and
service, cancel the operation, clear content/feedback and invalidate pending export epochs before
native cleanup. A cancelled completion cannot republish text. Selection also clears old clipboard
text immediately; a focused RED check caught the pre-existing omission before the one-line fix.
New restriction/Stop messages have Chinese translations; English remains the source language.

Evidence:

- Workspace RED: `devicebridge-clipboard-binding-red.log` failed because negotiated clipboard
  remained unavailable. Capability RED: `devicebridge-clipboard-capability-red.log` failed for
  the both-actions case. GREEN includes zero/read-only/write-only/both negotiation and post-Stop
  invalidity, using a real pinned TLS handshake (**18 channel tests pass**).
- `devicebridge-clipboard-selection-red.log` failed on retained previous-device text. Final
  headless Workspace checks cover explicit complete Unicode read/write, metadata-only preparation,
  Stop/export invalidation, late read rejection, synchronous selection clearing, screenshot-only
  capability isolation, route change and failed heartbeat (`/tmp/devicebridge-clipboard-binding-final.log`).
- Core regression **367 tests / 56 suites passed**, 16.012 s
  (`/tmp/devicebridge-clipboard-binding-core-final.log`). Helper packaging **5 passed / 1 skipped**,
  3.214 s; the skipped optional packaging case is not counted as passed.
- Physical evidence root `devicebridge-workspace-clipboard-malp6bam`: the production Workspace
  built the ordinary bundled helper sources with the existing personal identity, selected the exact
  paired USB phone, authenticated both capabilities and renewed the same session. Explicit WRITE
  followed by independent READ matched the complete fresh disposable Unicode fixture. Screenshot
  decoded and export matched exact original bytes. Stop cleaned the owned native Runner; independent
  metadata confirmed it absent and the selected paired wired identity unchanged. MobAI observation
  succeeded before and after, with no exact test paste prompt present; **no approval tap was needed**.
  The whole harness took **51.007 s**, not a clipboard latency measurement. The phone retains test
  text: this was an authorized replacement, not original clipboard backup/restoration.

The physical check is reproducible through `IOSRunnerWorkspacePhysicalCheck.swift`; its additional
`DEVICEBRIDGE_WORKSPACE_CLIPBOARD_REPLACE=1` opt-in is required to touch the phone clipboard.
This is a production-model/device integration check, not desktop visual/button-click acceptance.
The subsequent one-line selection-clear change has headless regression coverage; it does not
change native clipboard I/O. T036/T041/T084 remain open for remaining lifecycle/permission UX,
locked/long/multi-item/wireless acceptance. Prior UI-gated notes below describe older builds.

Final incremental Mac Debug build passed with an empty diagnostic log
(`/tmp/devicebridge-clipboard-binding-debug-final.log`), followed by strict bundle signature
verification. After verifying the old Debug executable and absence of children, only that app was
restarted with background `open -g`; the new Debug process was observed running (PID 77622).
No Release/DMG build, desktop input takeover, native child interruption or new signing identity
was used in this slice. User selection in the newly opened app remains a separate UI action.

## Latest: authorized paste approval and real cross-App READ passed

The user explicitly answered “允许” to approving the selected test phone's **Allow Paste**
prompt. That supersedes the earlier no-click testing boundary only for this permission and
device; no other privacy/trust/account approval is authorized. Product code still never approves
system alerts. MobAI observation matched the exact alert requesting a paste by
`DeviceBridgeRunnerUITests-Runner` from our separate `Device Bridge Runner` Host before a
single exact-text/button tap. No coordinates, generic Allow selector or blind retry was used.

Progression (all private evidence roots below are in the owned temporary area):

- `devicebridge-cross-app-consent-l22el037`: source write/readback acknowledged; observed the
  exact paste prompt, but the request expired before a fresh manual dispatch could match it.
  **No tap** was sent after the fresh match failed. Host failed; cleanup left no named Runner.
- `devicebridge-authorized-paste-read-99mfbt2w`: read-only follow-up with a newly strengthened
  exact-text assertion failed despite status success; no matched prompt or tap. This is a useful
  negative control for stale/empty acceptance, not proof the prior source persists across sessions.
  `DEVICEBRIDGE_MANAGED_EXPECT_CROSS_APP=1` requires READ-only mode and excludes all write and
  screenshot opt-ins; only Boolean equality is asserted/logged.
- `devicebridge-cross-app-authorized-5z4boirl`: same-session source acknowledged; matched prompt,
  but the combined tap/wait/observe API request timed out. Approval outcome was uncertain, not
  counted as success. Runner returned `clipboard.foreground_required`; no automatic second tap.
- `devicebridge-cross-app-single-tap-sa1q1fkc`: isolated single tap returned a **successful tap
  step**, yet the unmodified Runner still returned `clipboard.foreground_required` and no text.
  This provided the real counterexample motivating post-read state-settlement investigation.

### Focused read-publication correction

Production ownership remains `RunnerClipboardHandler.operationID`. Its captured context admits
the system read only for that owner and an active, foreground Runner. `SystemClipboardAccessor`
continues to serialize real pasteboard I/O away from MainActor. The command now keeps the returned
value **local and unpublished** for at most two seconds while the same context regains foreground,
bounded by the original request deadline and cancellation. It neither re-reads the clipboard,
activates an app, approves a permission nor changes WRITE admission. The existing final
authorization/owner checks still precede response publication; failure/cancellation cannot restore
Home over a different foreground app or let an obsolete read affect a new operation.

Two new tests first failed against the old behavior on the signed phone:
`devicebridge-read-settlement-red-tests-z5_05f7w`, **0 pass / 2 fail / 0 skip**. They caught an
immediate discarded read during a transient inactive state and `actionRequired` instead of the
subsequent cancellation. After the focused change, **32 ClipboardCommands tests passed / 0 skip**
(`devicebridge-read-settlement-green-tests-43c5nuxx`), including original background rejection,
deadline, cancellation, concurrent-owner, late-result, privacy and named-board WRITE coverage.
The new deadline case also verifies no content escapes and no unrelated app is sent Home.

### Actual qualified content path

`devicebridge-cross-app-settled-655_cciq`: separate Host source WRITE/readback acknowledged;
MobAI matched and successfully tapped the exact authorized paste button; the **normal encrypted
Runner READ returned success and exactly matched the full known Unicode source text**. Host
**1 pass in 49.756 s**, phone **1 pass / 0 fail / 0 skip**, 40-second renewal, Stop, native exit,
signed artifacts and owned cleanup all passed. The 71.572 s outer harness included a SwiftPM
lock wait during a concurrent local regression run; it is not a clipboard latency measurement.
Future physical runs should not overlap SwiftPM runs against the same package build directory.

Independent post-run checks: named Runner absent, selected USB port 49872 refused connection,
MobAI remained responsive and the exact test paste alert was absent. The single-tap script's
`Post-tap observation succeeded: False` means that its reused batch-result parser found no
observation step in a **tap-only** response; the separate final observation actually succeeded.
No clipboard content, length or hash was logged. The phone retains disposable test text; no
original-content backup/restoration is claimed.

Fresh host regression: **366 tests / 56 suites passed** (15.723 s,
`/tmp/devicebridge-paste-consent-core-final.log`); helper packaging **5 tests passed** (3.475 s).
Ordinary Debug helper build and strict signing
passed, with diagnostic Host symbols absent (`devicebridge-read-settlement-green-build-909cy9lx`).
The physical qualification combined that new signed Runner with the previously verified
diagnostic source Host in a fresh owned products directory; no original signed products were
overwritten. Mac runtime/clipboard UI was not rebuilt or enabled in this slice.

This qualifies the selected USB cross-App happy path with explicit paste approval, alongside the
earlier authorized normal Runner WRITE round-trip. T036 can next bind those explicit operations
to the already-owned Workspace session. Full T041/T084 remain open for remaining acceptance,
including denial/retry UX, long/multi-item physical data, locked devices and wireless behavior.

## Latest: authorized interruption, observed paste prompt, and working MobAI observation

The user explicitly authorized interrupting the app-owned session. After revalidating both
executable paths and parentage, normal SIGTERM stopped only DeviceBridge's owned `xcodebuild`;
the Mac app remained running, its child exited, and the selected phone had no remaining named
Runner before the next test. No business app or unrelated process was stopped.

- `devicebridge-cross-app-readonly-l174gc22`: normal encrypted READ, 40-second renewal, Stop,
  phone/native result and owned cleanup **passed** (host 1 test, 48.925 s). This existing test
  accepts a non-nil textual value, including empty text; it does not qualify positive content.
- `devicebridge-cross-app-wait-audit-pvypcxp1`: public ready received but the diagnostic host
  supplied launch options after the app positional argument. Activation failed before the read;
  its owned native process was reaped. This is a harness error, not a clipboard failure.
- `devicebridge-cross-app-wait-audit-_nm7upsb`: corrected argument order, public ready matched,
  activation preserved the exact Runner PID, UIKit became active. The existing read-only phone
  observer then detected a recognized **paste-approval button while READ was pending**, with
  MainActor responsive and UIKit no longer active. READ had not completed; it was cancelled
  without approval/write, and the phone returned Home. **0 pass / 0 fail / 1 skip**, 3.538 s,
  native exit zero, no named Runner afterward. This directly establishes a permission prompt
  during this read; it does not retroactively determine every earlier `actionRequired` cause.

The user then enabled MobAI's iPhone control. No MobAI MCP tools/resources were exposed to this
task, but the installed CLI reached its local API. Its physical device ID exactly matched the
selected CoreDevice hardware identity in memory; iPhone13,2 / iOS 18.3.1 / bridgeRunning=true.
An initial `observe --include ui_tree` succeeded, without screenshots or taps. The CLI skill's
linked device-automation reference is missing; installed CLI help supplied the used syntax.

`devicebridge-mobai-read-observation-017a65qw` verified coexistence: the normal encrypted READ
test ran while **12 MobAI UI observations succeeded**, including successful observation steps
and a nonempty native UI tree. No recognized paste labels were captured by those bounded
observations. Host **1 pass** in **48.143 s**, outer 49.563 s, renewal/Stop/native cleanup passed,
selected USB phone unchanged, named Runner absent afterward. No automatic bridge restart,
permission approval, clipboard write, target-app restart, or Mac input takeover was requested.
This read test still allows empty text; neither its pass nor the absence of recognized labels
qualifies positive cross-App access or a permission exemption.

Use MobAI for further selected-phone observations. Permission approval remains a separate user
decision, not implied by authorization to inspect device state. T036/T041/T084 remain open;
no production readiness gate or runtime code was changed in this continuation.

## Latest cross-App discrimination: source confirmed, Runner READ needs action

The separate `DeviceBridgeHost` bundle now contains a **test-only** clipboard source fixture.
Only an explicit Host Debug compilation condition (`DEVICEBRIDGE_HOST_PROBE_CONDITION` set to
`DEVICEBRIDGE_CLIPBOARD_SOURCE_PROBE`) plus an exact runtime source opt-in permits one disposable
general-pasteboard write per Host process. Normal Debug and Release omit the fixture implementation.
Only the test Host is restarted to consume its arguments, never the user's target app or Runner.
Fresh UUID-scoped receipts contain only fixed stage names; no clipboard data travels through
launch arguments, environment, app-container receipts, stdout or assertions. The normal Runner
and encrypted READ implementation are unchanged.

The physical test catches missing source setup and empty/default READs: it requires a new source
receipt after the Host's active-state setter and own readback, then independently requires exact
text equality from the Runner. Relevant runs, in order:

- `devicebridge-clipboard-cross-app-red-ckvebazb`: stopped at preflight because the original
  combined busy check included Host as well as Runner. No content operation.
- `devicebridge-clipboard-cross-app-red-82sh7iww`: harness error (`outputLimitExceeded`), not a
  clipboard acceptance failure. Replaced its zero-quota capturing executor with the existing
  exit-only, deadline-owned executor that discards CoreDevice output.
- `devicebridge-clipboard-cross-app-red-zml95inn`: genuine negative control with the old Host;
  **1 failed** in 9.585 s at `sourceReady`. It never entered the cross-App READ.
- Initial diagnostic build failed because command-line `SWIFT_ACTIVE_COMPILATION_CONDITIONS`
  overrode dependency conditions. The condition now belongs only to the Host Debug target;
  the corrected signed diagnostic build passes without changing signing or package dependencies.
- `devicebridge-clipboard-cross-app-tvn_rota`: no source receipt, **1 failed**, no cross-App
  READ. The available evidence does not isolate old Host installation from diagnostic startup.
- `devicebridge-host-source-readonly-rvd7n2nb`: explicitly installed the strictly verified
  diagnostic Host and launched with only a public UUID, **without the source opt-in**. Its new
  entry receipt matched; no clipboard setter was admitted. This validates actual diagnostic
  startup, not clipboard functionality.
- `devicebridge-clipboard-cross-app-os4nlrjg`: fresh source reached **`source-ready`**, proving
  Host foreground WRITE and own readback. The unchanged encrypted Runner READ then returned
  **`actionRequired`**, not matching text. Host **1 failed** in **23.723 s** (outer 25.076 s).
  No write retry or permission approval. Post-run exact USB phone was unchanged and no named
  Runner remained at that check. This run did not complete the later 40-second lease/Stop
  acceptance sequence; launcher failure cleanup ran instead.

The cross-App failure is now isolated after successful source setup. Its returned status alone
does **not** identify an observed paste alert, denial, loss of foreground, or absent readable text;
the first cross-App harness did not record the fixed error code. Do not infer permission state.
The phone retains disposable source text; original content was not backed up/restored.

A subsequent read-only preflight (`devicebridge-cross-app-readonly-gq0x7qqa`) found a different
Runner already active. Its Mac `xcodebuild` parent was the running DeviceBridge Debug app, not
this test harness. The read-only probe therefore stopped **before READ** and did not terminate
that app-owned session. Further phone characterization needs exclusive Runner ownership; do not
kill the user's active connection to obtain it. T036/T041/T084 remain open, and clipboard UI
readiness remains gated. Screenshot/memory readiness and the running Mac app were not changed.

Reproduction prerequisite: strictly verify the existing-Team diagnostic products, explicitly
install their `DeviceBridgeHost.app` on the selected phone, and run the opt-in
`IOSRunnerManagedPhysicalTests` with `DEVICEBRIDGE_MANAGED_CLIPBOARD_CROSS_APP=1` only while
no other Runner owns the device. Do not assume Xcode's existing test-target installation is the
new diagnostic source. Installing or launching the Host without the exact source opt-in is not
authorization to seed the pasteboard. The harness now records an allowlisted fixed error code
for the next cross-App run; that addition has not yet been exercised on the occupied phone.

Local checks: fresh Core **366 tests / 56 suites passed** (16.027 s,
`/tmp/devicebridge-cross-app-core-final.log`); helper packaging **5 tests passed** (2.759 s).
A separate **ordinary Debug** helper
build passed with the existing personal identity (`devicebridge-cross-app-normal-build-whemehz0`),
strict Host signing verified, and symbol inspection confirmed `ClipboardSourceProbe` is absent.
It was not installed over the active app-owned session. No Release/DMG or Mac app restart occurred.

## Authorized replacement: real encrypted WRITE and independent READ passed

After the user confirmed the explicit disposable-text replacement request with “继续”,
`DEVICEBRIDGE_MANAGED_CLIPBOARD_REPLACE=1` ran once on the selected, unlocked, paired USB iPhone.
It used the existing personally signed products and the normal production handler, with neither
the preserving test wrapper nor an automatic write retry. Other content opt-ins were excluded.

Evidence: `devicebridge-clipboard-replacement-3o6_8sje/test.log`, host **1 pass / 0 fail** in
**50.242 s** (outer harness 56.209 s). WRITE returned success and acknowledged `written=true`;
a separate encrypted READ returned success and exactly matched the disposable Unicode text.
Only Boolean equality and fixed status labels were logged, never text, length or hash.
The same test then passed 40-second identity renewal, Stop, phone result validation
(1 pass / 0 fail / 0 skip), native exit zero, signature checks and owned cleanup. The selected
paired wired phone was unchanged and the named Runner was no longer running after completion.

**The phone clipboard now contains test text; the previous content was not backed up or restored.**
This authorization supersedes the earlier lack of consent only for controlled disposable-text
tests on this phone. It does not authorize privacy approval or copying test hooks into production.
This positive control proves same-origin system-pasteboard exchange, not reading another App's
text or its paste-permission handling. T036/T041/T084 therefore remain open. The next bounded
discrimination uses our separate Host bundle as the source and the unchanged Runner as reader.
The historical empty reads and preserving-write failures below remain valid evidence for their
original runs; they no longer mean that every production WRITE is known to fail.

## Latest read-only wait discrimination: returns empty, no recognized prompt observed

An opt-in `DEVICEBRIDGE_READ_WAIT_AUDIT=1` branch in
`RunnerSmokeTests.testPhysicalExternalForegroundClipboardRead` observes only known SpringBoard
paste-approval button labels while the existing production `ClipboardCommands.read()` runs.
It never taps a button, writes the general pasteboard, logs content/length/hash, or records app names.
The observation loop has a 12-second cooperative budget; synchronous XCTest/OS calls are not
interruptible by that loop. The host harness therefore also bounds the native test lifetime and
reaps its owned process group. Test attachments are configured `keepNever`.

Fresh selected-phone preflight used CoreDevice's **`info lockState`**, not a guessed key in
`info details`: `passcodeRequired=false`, `unlockedSinceBoot=true`, paired wired route, and no
existing named runner. The diagnostic reuses the approved existing personal signing identity
without provisioning updates. Host activation preserves the observed runner PID.

- `devicebridge-clipboard-wait-audit-yohk7nga`: **0 pass / 1 fail / 0 skip**. The phone test
  reached its authored "Host did not activate" assertion; the host did not receive its public
  ready record. Clipboard READ was not reached. That harness did not retain copy errors, so its
  failure cannot retrospectively be attributed to a specific CoreDevice error.
- `devicebridge-clipboard-wait-evidence-rtw4ih2d`: **1 pass / 0 fail / 0 skip**, native exit zero.
  The revised diagnostic retains private structured copy errors, uses the production reader's
  five-second CoreDevice timeout, and puts the public probe marker explicitly in the test
  configuration. Copies include a CoreDevice 7000 timeout before a later successful ready copy.
  These changes do not isolate the cause of the earlier ready failure. UIKit became active,
  MainActor remained responsive, no recognized paste prompt was observed, and READ returned
  success. This version did not require nonempty text, so it is **not positive-content acceptance**.
- `devicebridge-clipboard-wait-evidence-w1jxigxa`: after requiring nonempty text, active state,
  advertised text metadata and a stable revision, **0 pass / 0 fail / 1 skip**, native exit zero.
- `devicebridge-clipboard-wait-evidence-nqlvwf1r`: with separate fixed qualification-failure
  classifications, **0 pass / 0 fail / 1 skip**, native exit zero. The exact classification is
  **"positive text was not returned"**, despite a success status, UIKit active and a responsive
  MainActor. No recognized paste prompt was observed before/during the read. Production success
  contains a textual value, so this is an empty-text response, not proof of readable original text.

No general WRITE, permission approval, Mac input takeover, app restart/GC, or target-project edit
was performed. A read returning empty may reflect actual clipboard contents or restricted access;
the current evidence does not discriminate those explanations. The earlier metadata-only evidence
of content presence was at a different time and must not be treated as a simultaneous positive-text
control. Absence of the three recognized button labels is also not a permission-status API.
Do not repeat this same empty read as progress or enable clipboard readiness from it. A subsequent
positive-content qualification needs an authorized known textual clipboard state; this audit must
not manufacture one by overwriting the existing clipboard. T041/T084 and general WRITE/restoration
remain open. The already qualified screenshot and memory capabilities are unaffected.

Reference comparison: upstream [WebDriverAgent pasteboard implementation](https://github.com/appium/WebDriverAgent/blob/master/WebDriverAgentLib/Utilities/FBPasteboard.m)
uses a background read plus alert handling; its automatic approval is deliberately **not** copied.
This source supports investigating permission waiting, not concluding that our phone showed a prompt.

## Current investigation: UIKit activity differs from XCTest foreground

The new real WRITE attempt (`devicebridge-encrypted-write-1_nlc_rt/test.log`) returned cancelled
and failed acknowledgement in 6.118 s; no automatic write retry followed. A read-only encrypted
check then passed transport/READ/40-second heartbeat/Stop in 46.542 s, with the synthetic write
fixture absent (`devicebridge-encrypted-read-v3lbh5yz`). This does not prove original rich content
restoration or meaningful system-pasteboard access.

A concrete discrepancy was then observed: synchronous foreground snapshot audit
`devicebridge-snapshot-audit-as4j2gr5` reported XCTest foreground, but `UIApplication` not active and
no active foreground scene, then reached the bounded harness timeout. In contrast, the externally
activated async audit `devicebridge-clipboard-checks-ls5pha09` yielded the MainActor during a
bounded settlement and reported `UIApplication became active`, but its subsequent read also
reached the harness timeout. A permission prompt is a hypothesis, not confirmed by this observation.
Apple documents asynchronous XCTest state publication separately from UIKit active/inactive state;
XCTest foreground alone is not sufficient for admission to system clipboard operations.

Consequently, earlier READ successes returning a non-nil (possibly empty) string qualify envelope,
lease and cleanup behavior, but are not conclusive positive-content clipboard acceptance. Keep the
Mac clipboard UI unavailable while fixing activity admission and verifying the actual system path.
No clipboard contents, lengths, hashes, or phone permissions have been logged or changed for this
investigation beyond the explicitly opted-in preserving write attempt.

Production foreground admission now requires both exact-runner XCTest foreground and UIKit active.
The existing bounded settlement loop yields MainActor between checks; no activation, certificate or
permission authority changed. New admission-policy test first failed with the old rule
(`devicebridge-clipboard-checks-5046eib6`, 29 pass / 1 fail); after the fix, all **30 signed phone
tests pass / 0 skip** (`devicebridge-clipboard-checks-u_mvbaub`). A metadata-only active-state audit
then **passed 1 test / 0 skips** (`devicebridge-active-clipboard-metadata-8gssz7om`) without calling
items/strings or any setter: UIKit became active, public metadata reported **content present**, and
revision stayed stable. This is a concrete counterexample to treating the earlier inactive empty
reads as successful real clipboard access. It does not reveal or identify that content and does
not itself prove paste permission. No further general write was attempted after this finding.
The synchronous snapshot audit now skips before reading content whenever UIKit is inactive.

### Consistent-empty backup classification

The preserving test wrapper now distinguishes an empty backup from conflicting metadata using
`numberOfItems == 0`, empty `types` and all-item `types(forItemSet: nil)`, and all `has*` flags false,
plus its existing revision check. Restoration repeats the same metadata classification. This
implements the public metadata contract, not a permission-status API or proof of app activity.
The production accessor is unchanged by this test-only backup classification.

- Empty named-board test RED: `devicebridge-clipboard-checks-jxt_vsfr`, 28 pass / 1 fail.
- Consistent-empty implementation GREEN: `devicebridge-clipboard-checks-p7kqxiu4`, 29 pass.
- Removing conflict checks failed the corresponding test (`devicebridge-clipboard-checks-hx1sblio`).
- Restored checks and empty/nonempty intervening-writer coverage: `devicebridge-clipboard-checks-_i6oz4vu`,
  **29 pass / 0 fail / 0 skip** on the signed physical phone.
- Independent review found this classification reasonable under the public contract, and required
  the all-item/custom-type checks and restoration revalidation. It does not authorize treating an
  inactive process's empty output as meaningful system state.

Apple also documents deferred `changeCount` increments until an event-loop boundary and updates
on reactivation. Revision checks are therefore not atomic snapshots or absolute protection against
concurrent external copies; original OS expiration/Handoff metadata remains unrestorable.
Sources: [UIPasteboard metadata](https://developer.apple.com/documentation/uikit/uipasteboard),
[changeCount](https://developer.apple.com/documentation/uikit/uipasteboard/changecount),
[UIApplication state](https://developer.apple.com/documentation/uikit/uiapplication/applicationstate),
[XCTest state](https://developer.apple.com/documentation/xcuiautomation/xcuiapplication/state-swift.property).

Read-only follow-up `devicebridge-snapshot-audit-vqt50hpk`: 0 pass / 0 fail / 1 skip. In addition
to an empty items backup, public item/type/presence metadata consistently reports empty. This
does not establish paste authorization or qualify restoration/WRITE. No general pasteboard write
occurred. Do not repeat the same audit as evidence of progress or classify the skip as a pass.

## Latest: preserving WRITE probe, real failure and read-only follow-up

General WRITE is **not qualified**. A separately opted-in signed phone entry exercises the real
encrypted write handler and shared system setter/readback, with a test-only in-memory backup and
restoration wrapper. Normal `testManagedChannel` continues using the production accessor directly.
The host test explicitly selects `testManagedClipboardWriteWithRestoration` and adds its public
opt-in flag; the normal launcher and its environment policy are unchanged.

The wrapper snapshots every item/representation, not only flattened text. A high-risk read-only
review found two concrete bugs in the first wrapper: a foreground await between snapshot and setter
could overwrite a newer copy, and a failed-before-setter operation could wrongly claim an independent
same-text copy. Both reproduced on real **named** pasteboards: `devicebridge-clipboard-checks-5cdvx_cf`
reported **25 pass / 2 fail**. No general write had been attempted at that point.

The production `SystemClipboardAccessor` now shares a synchronous `performSystemWrite` boundary:
the existing foreground await remains outside; cancellation/deadline checks remain before the setter,
after the setter and after readback. A receipt records the expected pre-set revision + 1, or no
revision if no setter ran. The probe invokes this same boundary immediately after its snapshot,
without an intervening await, and restores only an explicitly owned revision with matching text.
Failed-before-setter and failed-after-setter outcomes are distinct. Review accepted the revised
boundary and confirmed the two bugs were closed. UIKit has no atomic cross-process compare-and-set;
the remaining synchronous IPC races around both initial write and restore are not eliminated.

Named-board evidence:

- Initial probe scaffold: `...-pfyzxk3l`, **22 pass / 3 fail**.
- A fixture initially compared the pre-insertion dictionary against UIKit's canonicalized stored
  objects (`...-dn4c7y2n`, 24 pass / 1 fail). It now snapshots the actual stored multi-item values
  before invoking the production path; all represented keys are checked independently.
- Ownership fixes: `...-ub4uw74z`, **27 pass / 0 fail / 0 skips**.
- Conservative unavailable-backup guard: RED `...-_jkocv7m`, **27 pass / 1 fail**; GREEN
  `...-90s6bkqb`, **28 pass / 0 fail / 0 skips**. An empty, incomplete or changing snapshot aborts
  this preserving probe before mutation. This intentionally does not disable normal writes to an
  empty pasteboard, which remain covered by the existing system-accessor named-board test.

### Actual encrypted WRITE attempt — failed; no automatic retry

`devicebridge-encrypted-write-pig8mwzc/test.log`: authentication succeeded, but the write did not
return the required successful correlated acknowledgement; host test **failed in 6.055 s**. Signed
roles verified after owned launcher cleanup. The first attempt lacked a detailed safe result-status
diagnostic, so its exact failure stage is not established retrospectively. Do not claim that the
general setter ran or that full restoration was proven. Later host tests now log only the fixed
result status, never contents. No second general WRITE was attempted.

The follow-up used only the normal encrypted READ: `devicebridge-encrypted-read-xsejja7v/test.log`,
**46.525 s PASS**, followed by five metadata exchanges over 40 seconds, Stop, native exit zero,
phone 1 pass/0 skips, log audit and cleanup. An in-memory comparison confirmed that the prior
synthetic write fixture was absent. A successful non-nil text response can represent empty text;
this is not evidence that every original rich representation or system metadata was restored.

Read-only snapshot audits then reproduced an unavailable backup: `devicebridge-snapshot-audit-bz08_6e7`
and `...-6mn9trqv`, each **0 pass / 0 fail / 1 skip**. The second fixed diagnostic reports that the
items API returned no backup, without a reported item-metadata mismatch or a revision change. The
guard stopped before copying to a named board, and neither audit writes the general pasteboard.
These are useful diagnostic skips, not passing WRITE acceptance. Next discrimination: distinguish a
genuinely empty board from unavailable/redacted content using public metadata before relaxing any
probe guard; never infer "empty and safe to overwrite" solely from an empty `items` return.

Restoration preserves readable item contents only; OS change counts, expiration and Handoff metadata
are not promised restored. Relevant public APIs: [changeCount](https://developer.apple.com/documentation/uikit/uipasteboard/changecount),
[data representations](https://developer.apple.com/documentation/uikit/uipasteboard/data%28forpasteboardtype%3Ainitemset%3A%29),
and [pasteboard items/privacy options](https://developer.apple.com/documentation/uikit/uipasteboard).

Fresh regressions: Core **286 tests / 49 suites PASS in 10.366 s**, SecureChannel **77 tests / 9 suites
PASS in 8.192 s**, packaging **5 PASS in 2.140 s**. Logs: `/tmp/devicebridge-write-probe-core-regression.log`,
`/tmp/devicebridge-write-probe-secure-regression.log`, `/tmp/devicebridge-write-probe-packaging.log`.
The default Core suite skips its existing physical opt-ins; the actual executed phone evidence is
separate above. No new certificate/provisioning update, permission approval, Mac global UI takeover,
Mac app restart, Release build or distribution package was performed. T084/T036/T041 remain open.

## Current encrypted-channel integration (T084, not yet Mac UI acceptance)

The actual signed entry now supplies `RunnerClipboardHandler`. Its 20 physical fixture methods
passed with zero skips twice (`devicebridge-clipboard-checks-dk2ls1o6` and `...-8_mg8dgz`), including
exact Unicode named-pasteboard write/readback, optional Boolean `sensitive`, complete text, expiry,
foreground checks and late-result cancellation. These fixtures never write the general pasteboard.
The optional-sensitive regression failed before correction (`...-rr6nj1zh`: 19 pass/1 fail).

Core host tests now pass 13 methods: correlated complete-text replies, one content slot plus
independent heartbeat/Stop, foreground preparation, expired unsent Stop preemption, and cancellation
followed by awaited close discarding late activation. The Stop timer regression was observed failing
with `.unavailable` before its fix. Log: `/tmp/devicebridge-channel-close-barrier-check.log`.
An independent review confirmed `receive` is the completion commit point; caller cancellation is
cooperative, not an instantaneous wire barrier. These boundaries are recorded in the channel contract.

Production-factory physical READ attempts exposed two failures hidden by isolated fixtures:

- `devicebridge-encrypted-read-8pq75lcf` and `...-7d5n_lx3`: authentication succeeded, then `.unavailable`.
  The installed CoreDevice parser rejects `--timeout 5.0` (read-only `--help` validation exits 64).
  Its option requires integer seconds. Red fixtures then produced four issues; corrected integer
  arguments passed all 11 activator methods. The native owner retains the original absolute deadline,
  including subsecond requests; rounding the tool's timer does not extend the request budget.
- `devicebridge-encrypted-read-q7y7eny2` and `...-cvsbkhsq`: authenticated read returned a correlated
  `actionRequired / clipboard.foreground_required` reply. CoreDevice command completion does not
  itself establish that the runner has finished becoming foreground. Bounded settlement is the next
  fix; the earlier external probe explicitly polled foreground, explaining its different outcome.

No general clipboard write, automatic paste approval, Mac UI takeover, new signing identity or
Release packaging occurred. Failed real reads remain failures, not a capability-readiness claim.

### Encrypted real READ passed after the two production corrections

`devicebridge-encrypted-read-v92l5xx0/test.log`: the opt-in
`signedNativeLauncherMaintainsAuthenticatedPhoneSessionAndStops` passed in **48.982 s**. This is the
actual production factory/launcher, personal-signed phone runner, selected USB route and pinned TLS,
not a fake channel or named pasteboard. The correlated read returned `success` with non-nil text;
the test then completed five metadata exchanges over 40 seconds, correlated Stop, native child exit
zero, phone xcresult 1 pass/0 skips, nonce/Stop-ID action-log audit, and owned cleanup. All three
signed source roles verified strictly before and after. Content, count and digest were never logged.

Foreground settlement is now a cancellation-aware 50 ms state poll for at most two seconds within
the original content deadline. It does not activate apps, read before foreground, or approve prompts.
Two new physical fixture regressions failed first (`...-5sj5lb9t`: 20 pass/2 fail), then all **22
passed, 0 skips** (`...-cmqyp3_8`). Original background/expiry/cancellation fixtures are preserved.

This qualifies one successful real encrypted READ under the phone's current permission state,
plus backend lease/Stop. General clipboard WRITE/restoration, permission waiting/denial, screenshots,
wireless and Mac workspace integration remain unqualified; T084/T036/T041 remain open.

## iOS cancellation and foreground qualification — after T083

The selected personal-signed iPhone ran the seven `ClipboardCommandsTests` fixtures:
**7 passed, 0 failed, 0 skipped** after the fix. These execute on the physical runner but use
isolated clipboard doubles, not the phone's personal clipboard. Two new regressions were observed
failing first: an already-cancelled request still accessed the clipboard/reported success, and an
uncooperative read completing after cancellation still returned text. The commands now check
cancellation before access and again after the asynchronous boundary, never publishing late text.
The system accessor also checks cancellation on entry before a queued OS action can start.

`SystemClipboardAccessor` now serializes UIPasteboard I/O on a dedicated actor rather than the main
actor. This is accepted by the installed iPhoneOS Swift 6 SDK (UIPasteboard is declared Sendable),
without unsafe isolation overrides. It does not make a blocked OS call forcibly cancellable,
nor does a cancelled write prove that a setter already in progress was rolled back. The transport
must close/invalidate and must never replay an uncertain clipboard write.

Evidence directories (owned macOS temporary area):

- `devicebridge-clipboard-checks-oyia_10e`: initial cancellation regression, 5 pass/1 fail.
- `devicebridge-clipboard-checks-_a5nadbg`: both cancellation regressions, 5 pass/2 fail.
- `devicebridge-clipboard-checks-b3o4lpop`: fixed asynchronous accessor, 7 pass/0 fail.
- `devicebridge-foreground-probe-c2vjnp_6`: real `.xctrunner` foreground/background round-trip,
  1 pass/0 fail/0 skip, same runner process; no clipboard or screen API used in that probe.

All builds reused the existing personal identity and cached profiles; no provisioning updates,
Mac UI automation, paste approval, or Release packaging. T041/T084/T036 remain open: these checks
do not yet qualify real clipboard content exchange over the channel or from the Mac UI.

### Actual iPhone clipboard read (not a fixture)

`RunnerSmokeTests/testPhysicalClipboardReadWhileForeground` then ran against the phone's general
system pasteboard: **1 passed, 0 failed, 0 skipped**, native test child exit 0. It activates the exact
runner, calls the real `ClipboardCommands`/actor-backed `SystemClipboardAccessor`, and checks a
successful result with non-nil text. It returns the phone Home afterward. It never writes a fixture,
prints text/count/hash/item metadata, approves an alert, or attaches clipboard contents.
Diagnostics: `devicebridge-clipboard-read-s38rw2fz/result.xcresult` in the owned temporary area.

This proves real foreground text access on the selected phone under its current permission state,
not a permission exemption, denial handling, an encrypted content round-trip, background access,
general clipboard write/restoration, or Mac UI usability. Those acceptance gates remain open.

Important latency counterexample: the read test took **84.876 s**. Its action log locates the
delay in `XCUIApplication.activate()` inside the asynchronous test: idle notification timeout at
60.59 s, animation completion timeout at 84.37 s; foreground state/read/Home began immediately
afterward. The earlier synchronous foreground-only characterization took 1.797 s. Therefore do
not ship direct synchronous `activate()` in the asynchronous command handler merely because both
tests passed. It can consume the complete 30-second content deadline before touching pasteboard.
Next experiment uses the installed public CoreDevice `process launch --activate` (without
`--terminate-existing`) and checks the same runner PID to establish non-restarting foreground
activation. Its help documents foreground activation; reuse of the current XCTest process still
requires physical evidence, not inference from the flag name.

The follow-up **passed on the same physical phone**: `testPhysicalExternalForegroundClipboardRead`,
1 pass/0 fail/0 skip, total **1.365 s**. The host's public `devicectl device process launch --activate`
returned exit 0 in **0.240 s**; no `--terminate-existing`, arguments, child environment, console
attachment, or permission approval was supplied. The phone test checks foreground and unchanged
runner PID, reads the real general pasteboard through `ClipboardCommands`, removes its exact
public ready record and returns Home. All three signed bundle roles remained strictly valid
afterward. Evidence: `devicebridge-clipboard-checks-zxhyo7_1/result.xcresult`.

Use this verified host-side activation boundary in the next content integration rather than
calling `XCUIApplication.activate()` from an async clipboard handler. The ready file was only a
public experiment signal; production content and authorization must use the authenticated channel.
No real clipboard write or encrypted content transfer occurred in this follow-up.

## Latest production-fix verification — 15:19

Two Android physical runs passed cold-start authentication, Unicode round-trip and original-text
restoration readback without the diagnostic socket wait. Production prepare now gates on socket and
focus, bounds waiting, invalidates stopped/cancelled work, and cleans exact forwards. T035 is closed.
T041 remains open: iOS clipboard is not implemented end-to-end, and Helper v2 still needs a
per-request focus/access guard to distinguish background denial from empty clipboard. These are
backend tests, not Mac UI qualification. Historical failures below are retained as evidence.

## Physical follow-up (supersedes earlier NOT RUN status)

The user confirmed both connected phones as test machines. Android cold-start authentication failed
with TCP connectionClosed. A diagnostic socket readiness gate plus verified foreground focus allowed
a Chinese/emoji round-trip and text-restoration readback to pass at 15:00:15. This does not qualify
the unmodified startup path; T035 is reopened and T041 remains open. iOS content is still blocked by
the missing concrete channel. Details and cleanup/clipboard limits: [physical-background.md](physical-background.md).

## Automated evidence

- `swift test --package-path packages/DeviceBridgeCore`: PASS, 62 tests in 15 suites.
- `gradlew testDebugUnitTest assembleDebug`: PASS for the Android helper, including big-endian
  framing, Unicode round-trip, and oversize rejection.
- iOS simulator `ClipboardCommandsTests`: PASS for Unicode read/write, permission-denied mapping,
  and write-size rejection.
- macOS `DeviceBridgeAppUITests`: PASS, including explicit fixture clipboard read and send. Launch
  performs readiness only and does not read clipboard contents.

## Interoperability corrections proved by tests

- Swift wire keys are the protocol keys `requestId` and `helperDeviceId`, matching Android JSON.
- Android resets a previous helper process before a new nonce handshake and removes the exact ADB
  forward on stop.
- Clipboard results are guarded by the selected session generation, so a late result cannot publish
  after a device switch.

## Real-device status

- Android real-device mutation was not run. The available mobile-control skill requires MobAI, and
  `mobai devices list --json` reported that its local desktop API was unreachable. Direct ADB writes
  were intentionally not used as an undeclared fallback.
- iOS real-device clipboard is not ready: runner build/state orchestration and clipboard command
  mapping exist, but the concrete persistent selected-transport channel is still missing. The Mac UI
  reports this as **Action required** instead of claiming readiness.

Therefore T041 remains open, and T036 remains open until a concrete iOS install/start/channel/stop
provider is connected and verified.
