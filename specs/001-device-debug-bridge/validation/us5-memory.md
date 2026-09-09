# US5 Memory Monitoring Validation

Date: 2026-09-08

## Latest resumed VM test with authorized phone scrolling

The user reported the VM running and explicitly agreed to prioritize VM acceptance again, before
the remaining non-VM desktop/wireless checks. A fresh current-process match used the previously
scoped application identity and independently verified the same paired USB phone. The target was
not launched, restarted or terminated; no screenshot helper was started by the memory probe.

- `devicebridge-workspace-memory-resumed-nvkm4kle`: normal production Workspace provider,
  discovery/12-second idle renewal/six attributed samples/Stop passed, exit 0, 40.783 seconds.
  CapturedAt gaps min 2493.6 / mean 2506.2 / max 2515.3 ms. Samples/readiness stayed cleared
  after Stop; independent after-inventory confirmed the unchanged main process and wired device.
- `devicebridge-workspace-memory-resumed-extended-oet42c4m`: **cadence acceptance FAILED**.
  All 120 attributed samples arrived, but gaps were min 1398.1 / mean 2528.3 / max 3725.7 ms,
  exceeding the unchanged three-second gate. The outer probe exited 1; target process and paired
  USB route were still unchanged. This run failed before its explicit successful-Stop assertions;
  the failure handler stopped the Workspace, not the target app. Do not label it a full pass.
- During that extended run, the user expressly authorized MobAI scrolling. A read-only UI/OCR
  observation and one visual check confirmed the scoped foreground application and its dashboard.
  One upward coordinate swipe (no semantic tree initially), two semantic downward page scrolls,
  and an upward scroll-to-observed-summary-header succeeded. Final tree confirmed the original
  dashboard's top section. No business button, permission, setting, launch/kill or desktop input
  was invoked. UI content and screenshots are not copied into repository evidence.

The slow interval coincided with a run containing UI automation, but its cause is not yet proven.
The test-only `DEVICEBRIDGE_WORKSPACE_MEMORY_TIMING=1` option now measures 60 samples with per-RPC
and existing CoreDevice command-boundary timings when tracing is also enabled. It records only
relative monotonic durations and categories, never VM credentials, app/device IDs or metric values.
Production scheduling, identity checks and the three-second threshold remain unchanged.

### Timed scrolling follow-up — slow interval not reproduced

`devicebridge-workspace-memory-timing-mbkascyd` completed 60 attributed samples and explicit Stop,
exit 0, 178.450 seconds overall. CapturedAt gaps min 2356.4 / mean 2525.0 / max 2657.4 ms;
monotonic RPC-completion gaps max 2656.943 ms. Trace recorded 184 successful VM metadata RPCs,
60 memory RPCs, a stable expected PID and pinned isolate. After-inventory confirmed the same
target main process and paired wired phone. No VM RPC reached the trace's 200 ms reporting threshold.
Existing CoreDevice command maximums were details 499.204 ms, apps 477.959 ms, processes 553.640 ms.
These per-command timings do not measure the complete process-validation phase or app UI latency.

The same authorized, read-only dashboard workload ran during this follow-up: two downward page
scrolls, upward return to the observed summary header, then two more down/down/up-to-header cycles.
MobAI reported successful actions and the final tree retained the dashboard summary section.
No business button or app lifecycle action was invoked. The tracer forwards the original command
runner and RPC responses; it adds no retry, response modification or relaxed admission.

This repeat demonstrates functional scrolling/sampling coexistence, not a fix for the prior
3725.7 ms interval. The failed run lacked boundary timings, so there is insufficient evidence to
attribute its isolated delay to VM work, host scheduling, command latency or initial accessibility
activation. Do not remove device/process revalidation or lower/relax the cadence on that guess.
T064's strict three-second interaction-load qualification remains open; no production change was
made in this follow-up. Both successful short/diagnostic runs verify Stop; the failed extended
run is preserved separately.

Fresh headless Workspace lifecycle checks (`/tmp/devicebridge-ios-memory-resumed-checks.log`) passed
all five groups: verified selection/explicit sampling, Stop/retry/app replacement, stale discovery,
independent screenshot preparation/route invalidation, in-flight Stop/store invalidation, and manual
unverified-candidate rejection. These do not replace the failed physical cadence gate.

## Sustained Workspace sampling investigation — 2026-09-08

### Post-correction five-minute physical pass

After the user explicitly reported restarting the target, fresh CoreDevice inventories matched
the exact previously sampled application by bundle identity and its one current main executable.
The new PID was admitted through fresh native discovery; no old binding or series was reused.
Evidence: `devicebridge-workspace-memory-trace-bahkg0ph`, native probe exit 0, 327.368 seconds
including discovery, 12-second idle renewal and Stop validation.

- 120 attributed memory samples over at least 290 seconds; 364 successful metadata RPCs.
- CapturedAt gaps: min 2493.6 ms, mean 2527.0 ms, max 2602.3 ms; all below 3 seconds.
- Observed startTime range 3 ms with fixed expected PID and pinned isolate; no transport error.
- Every sample matched the selected device/application/PID; RSS/PSS remained unavailable rather
  than fabricated. This measures Dart heap/external, not total iOS application memory.
- Explicit Stop cleared samples/readiness immediately and remained stopped after two seconds.
- Independent after-inventory confirmed unchanged target PID and the same paired wired phone.

This passes the bounded single-device USB endurance/cadence slice using the real Workspace and
native VM route, with diagnostic-only observation at the RPC boundary. It is not rendered-window
latency, Wi-Fi, background/lock, deliberate app restart or route-switch qualification. The probe
excluded screenshot helper launch; no target-project edits, GC, desktop input or target restart
were performed by the agent. Existing incremental Debug remains in place; no packaging needed.

### Explicit rediscovery after Stop — physical acceptance

`devicebridge-workspace-memory-rediscovery-saxlq5vc` passed in 89.496 seconds, exit zero.
The same actual Workspace first discovered/renewed/sampled six times and stopped, then invoked
the existing Discover action twice, each time waiting for metadata readiness without sampling,
explicitly starting six new samples, and stopping. Each cycle required an empty prior series,
all new capturedAt values after that cycle's explicit Start, exact device/application/PID
attribution, and immediate plus two-second stopped/empty/not-ready checks. Three native owners
closed independently; tracing recorded 6 memory RPCs each. Independent after-inventory confirmed
unchanged target PID and paired wired device. No target app, Mac app or device was restarted.

The test-only `DEVICEBRIDGE_WORKSPACE_MEMORY_REDISCOVER=1` option covers reuse of a closed binding,
old-series retention and unintended sampling on Discover. Production code was unchanged and no
Debug rebuild/package was needed. This is same-process explicit rediscovery, not physical process
restart or network-route-switch qualification; those remain separate acceptance items.

### Same-Workspace screenshot and VM coexistence — physical pass

Evidence `devicebridge-workspace-coexist-ml81cfgo`: exit zero in 64.016 seconds. Unlike the
memory-only probe, this opt-in runs the real signed IOSRunnerManager and native memory provider
inside the same Workspace. Fresh inventories selected the exact previously scoped application
and current main PID; the already approved signing Team and bundled sources were used.

The normal helper bootstrap explicitly presses Home (`RunnerSmokeTests.runManagedChannel`),
whereas `XCUIScreenCapture` only captures the screen. This means independent feature passes cannot
establish coexistence. This run waited for authenticated screenshot readiness, selected the same
VM application and obtained at least three real memory samples, captured/decoded/export-verified
one screenshot, then required at least three later samples with exact device/application/PID
attribution while the same monitor remained active. The existing Workspace Stop and manager cleanup
completed. Independent postconditions: paired wired phone unchanged, target PID/executable unchanged,
no named runner left, phone observation available and no exact test paste alert.

No clipboard command, target launch/restart, target-project edit or desktop input was performed.
The host acceptance executable alone was recompiled; the signed helper build was test-owned and
the installed Mac Debug app was not rebuilt/reloaded. This short coexistence run does not qualify
arbitrary foreground/background transitions, locked devices, wireless or long-duration concurrent
use. It also does not prove that bootstrap preserves the user's foreground app—it explicitly does
not. `DEVICEBRIDGE_WORKSPACE_COEXIST_APP` and `_PID` opt into the test; clipboard replacement is
rejected in this mode. Original clipboard/screenshot-only acceptance behavior remains unchanged.

Foreground follow-up (read-only): `IOSRunnerLauncher.installStartAndOpen` starts `xcrun xcodebuild
test-without-building` with a validated xctestrun, not `devicectl device process launch`.
The normal test entry then explicitly presses Home before publishing its authenticated channel.
Local Xcode 26.6 `devicectl device process launch --help` exposes `--activate/--no-activate`
(platform-dependent), but that option is not a drop-in option on the current xcodebuild invocation.
No documented foreground-preserving switch was found in local xcodebuild help; this is not proof
that every alternative is impossible. Removing the explicit Home call alone has not been physically
qualified to preserve the previous foreground app, so no production change was made on that guess.
Appium's [preinstalled WDA guide](https://appium.github.io/appium-xcuitest-driver/11.17/guides/run-preinstalled-wda/)
describes a different launch/artifact workflow; adopting it would require new signed-artifact,
test-session lifetime and cleanup qualification rather than merely reusing the launch flag.
The supported behavior remains short-lived phone foreground disruption at helper startup; the
successful coexistence result above does not imply foreground preservation. No Mac UI takeover.

### Authorized termination attempt — invalidation observed, process exit NOT qualified

After explicit user authorization to interrupt the target, `devicebridge-workspace-memory-termination-aqe91vg7`
qualified the exact running application and collected six samples. A fresh device/PID/executable
check preceded exactly one `devicectl device process terminate --pid` request (SIGTERM, no --kill).
CoreDevice accepted the command. The native VM subsequently timed out; the actual Workspace cleared
its series/readiness and stopped 7.996 seconds after the test's ready receipt, then remained empty
and stopped for five seconds. This interval includes harness polling, independent preflight and
termination-command latency; it is not precise process-exit detection latency.

The inner probe exited zero, but the OUTER acceptance correctly FAILED: independent after-inventory
still contained the old PID/executable. A fresh recheck was collected; successful signal delivery
does not prove process exit. No second signal, force kill, debugger operation or relaunch followed.
This is VM-unavailability invalidation evidence, NOT a successful process-termination/restart test.
The reason the process remained listed (including possible debugger interception) is unverified.
The new test-only TERMINATION mode publishes a fixed ready receipt, then observes production
invalidation without directly calling Stop; it cannot alone certify that external termination
succeeded. Real process exit and subsequent new-PID binding remain pending user-assisted restart.

### Historical failures and correction evidence

User-assisted exit follow-up: `devicebridge-user-exit-confirm-d68aq7t3` independently confirmed
the old signalled PID absent and exactly one new main PID for the same installed application.
`devicebridge-workspace-memory-new-process-aqmm942u` then attempted fresh discovery through the
normal native Workspace provider (no diagnostic connector). It failed at binding before sampling;
the new PID/executable and paired wired phone remained unchanged afterward. Old-process exit is
now confirmed, but new-process VM availability/rebinding is NOT accepted. Running the application
alone is insufficient evidence of an accessible Debug VM; no old connection/sample was reused.

The earlier six-sample cadence pass is not endurance acceptance. A 120-sample (approximately
five-minute) actual Workspace probe was added, with no app restart, GC, debugger termination,
desktop input or target-project changes. Fresh private inventories must match both the previously
scoped developer process PID and the paired wired phone before running.

- `devicebridge-workspace-memory-extended-93ra0d19`: first unchanged candidate failed binding.
- `devicebridge-workspace-memory-extended-uabrhy2a`: second candidate bound, then stopped sampling.
- `devicebridge-workspace-memory-trace-om0kc23k`: real native RPC-boundary trace recorded 94 getVM,
  30 getMemoryUsage, 2 ms startTime range and no transport error; before/after PID and route matched.
  This falsifies the experimental lifetime 1 ms bound, not the exact-device ownership contract.
- `devicebridge-workspace-memory-trace-0u3py9vx`: a separate repeat ended with transport-closed
  after 10 metadata / 2 memory RPCs; PID and pinned-isolate observations remained stable and the
  range was 1 ms. This is a distinct failure, not explained by removal of the timestamp bound.

The reviewed focused correction removes two mutable timestamp extrema and their rejection branch.
The semantic floor remains one non-reopening native stream, expected PID/pinned isolate, independent
app/path and session generations, strict numeric metadata, cancellation and terminal closure.
RED: `/tmp/devicebridge-vm-clock-red.log`, 34 tests / 4 issues from forward/reverse/large valid clock
variation and variation during memory sampling. Genuine PID/isolate mutation and late-result
rejection tests are preserved. Extended physical acceptance remains pending.

GREEN: `/tmp/devicebridge-vm-clock-final.log`: 356 executed test methods passed plus 13 opt-in skips
(369 aggregate), 56 suites, 18.095 seconds. The added native stream test qualifies across 2 ms,
then forces peer EOF and asserts terminal closure with no second Connect. An initial concurrent
whole-suite run had unrelated short-deadline fixture failures; the serial regression passed.
An intermediate new EOF fixture omitted the JSON-RPC version and was corrected before this result.

Post-correction physical preflight `devicebridge-workspace-memory-trace-sqjxig7i` found only one
of the two original processes unchanged: the previously sampling second process was absent.
It aborted before connecting rather than silently selecting another application or restarting one.
Thus no post-correction physical endurance pass is claimed. Re-establishing a target debug process
requires user direction; the distinct transport-closed observation also remains to investigate.

Follow-up evidence audit: the saved before/after inventories from `0u3py9vx` show the sampled
process absent immediately after the transport-closed run, while the other scoped process survived.
The same hardware identity and paired wired route remained present. This is consistent with target
process termination closing the stream, not evidence of USB disconnection; the reason for process
termination is unproven. Fresh preflight `devicebridge-workspace-memory-trace-j8utv26n` confirms that
the same application is still installed but has no running main process (not merely a changed PID).
No target was launched, restarted or replaced. Continuing physical sampling needs that developer
application running again with a debug VM; retain a fresh binding rather than resume the old series.

Incremental macOS Debug build passed (`/tmp/devicebridge-vm-clock-debug.log`), followed by strict
deep code-signature verification. The exact idle previous Debug process had no child and exited
normally; the updated app was opened in background and its process verified. No Release packaging
or desktop input occurred. Independent final read-only review found no actionable ownership
regression; it explicitly did not qualify physical stability.

## SC-007 cadence correction — 2026-09-08

The old production loop waited a full three seconds **after** both provider completion and event
publication. That makes its update interval longer than the spec's three-second freshness target
even on a healthy route. Two focused regressions reproduced the defect before the correction:
controlled provider/publication delays still requested the full extra wait, and a provider overrun
still added another full cycle. RED: `/tmp/devicebridge-memory-cadence-red.log`, 10 tests / 2 failures.

The production path remains Workspace Start → MemoryMonitor's revision-owned sequential loop →
DeviceSessionStore operation token → provider → atomic eligibility/finish → guarded event publication.
Only the cycle budget changed: a local monotonic start instant precedes sampling; the subsequent
wait subtracts provider and callback time and clamps to zero. No new persistent owner, timer queue,
overlapping request, catch-up backlog or reconnect was added. Existing Stop/restart/stale/invalidated
and bounded-history behavior is preserved.

The first physical measurement after that subtraction, but with the original three-second default,
was **not SC-007 acceptance**: `devicebridge-workspace-vm-cadence-a9ns8tpr` produced six attributed
samples with five capturedAt gaps of **3005.3–3056.9 ms**, mean **3028.0 ms**. A second controlled
regression made the later provider call 200 ms slower and observed a **3.20957675 s** publication gap
(`/tmp/devicebridge-memory-freshness-red.log`, 11 tests / 1 failure).

The default is therefore a **2.5-second cycle budget**, retaining 0.5 seconds of headroom under the
unchanged three-second freshness requirement. The explicit-cadence regression still uses three
seconds, so reducing the default cannot conceal a return to post-completion sleeping. Slow external
operations may still exceed the target; the implementation must retain real timestamps/failure state,
not overlap operations or fabricate freshness. Both Android and iOS use this shared default.

Physical remeasurement **`devicebridge-workspace-vm-cadence-2an46fj6` passed its scoped checks**:
native Workspace discovery/binding, 12-second idle metadata renewal, six attributed real samples,
Stop and unchanged stopped state. Five gaps were **2525.3–2562.2 ms**, mean **2544.5 ms**, all below
three seconds. Independent app PID and paired wired route remained unchanged, exit zero, stderr
empty. Only timing statistics were retained, not memory values/VM credentials. No app launch/restart,
GC, clipboard operation, phone permission change or desktop input occurred.

This measures real Workspace sample timestamps, **not rendered-window paint timing**, and only five
intervals, not endurance/load/restart/physical route-switch acceptance. T064 remains open. The UI's
English/Chinese feedback now states the 2.5-second **target** rather than promising an exact interval.
Earlier sections describe their original two-sample/three-second-post-completion checkpoints.

Final serial Core regression: **366 tests / 56 suites passed in 15.882 s**
(`/tmp/devicebridge-memory-freshness-core-final.log`). The five headless Workspace memory groups
also passed with the revised cadence, retaining Android/manual-URI gates, screenshot independence,
late discovery rejection, in-flight Stop and stale-store invalidation. The final incremental Debug
build passed (`/tmp/devicebridge-memory-freshness-debug-final.log`) and deep/strict signature
verification succeeded. The exact previously validated Debug process was normally terminated and
the refreshed app was opened with `open -g`; the exact new executable process was verified running.
No force kill, Release/DMG, new signing material or desktop UI/input automation was used.

## Workspace integration and Debug handoff — 2026-09-08

T114 now connects the real Workspace and iOS controls to the qualified native VM binding. App
inventory alone is not ready; the selected target/session must equal the issuer's returned binding
after current-store and Workspace revision checks. One available app may be selected automatically;
otherwise the picker requires a choice. Idle renewal is metadata-only every 10 seconds. Explicit
Start feeds the committed binding to MemoryMonitor. Stop, device/route/app change and terminal/stale
sample events revoke readiness before owned cleanup. The iOS UI replaces manual URI input with
Start/Discover/Stop and bilingual USB/debug-profile/shared-isolate-group guidance.

`scripts/verify-workspace-ios-memory.swift` preserves the old manual iOS rejection and Android gates,
then exercises real store/issuer/binding/monitor code with synthetic external process/RPC boundaries.
Five groups passed in `/tmp/devicebridge-ios-workspace-memory-final.log`: app selection/explicit
samples/Stop/retry/App replacement; delayed discovery both before and after binding creation;
screenshot-preparation independence and observed route replacement; in-flight Stop and store-only
generation invalidation before inventory publication; unchanged manual admission gates.

Two regressions were reproduced: the old selection busy flag blocked memory while an unrelated
screenshot runner prepared, and a `.stale` monitor event left a closed binding temporarily ready.
The classified stale RED is retained at `/tmp/devicebridge-ios-workspace-stale-classified-red.log`.
Earlier RED checks exited via Swift top-level assertion; the checker now reports failure and exits
normally. Independent scoped review is clear after fixes; a test scheduling suggestion was applied
by waiting for actual owner closure, not merely provider return. Renewal/Start reverse admission is
handled conservatively as busy; its exact scheduler interleaving is not a deterministic GUI test.

Physical **`devicebridge-workspace-vm-memory-2qslnj7u` passed** using
`scripts/ios-vm-spike/WorkspaceMemoryProbe.swift`: native device/app discovery through Workspace,
verified readiness, 12 seconds of idle renewal without published memory, two attributed timestamped
samples, immediate Stop and unchanged stopped state after two seconds. Independent before/after
app PID and paired wired route matched; exit zero, stderr empty. This was windowless and used the
native VM provider; only screenshot runner launch was excluded to isolate memory. No target app
launch/restart, GC, clipboard operation, permission change or desktop input occurred. The probe
checks stopped Workspace state; lower-level exact close/drain is covered by prior Core physical
evidence and headless closure checks, not claimed as a new physical socket teardown measurement.

Final serial Core **363 tests / 56 suites passed** in 12.951 seconds
(`/tmp/devicebridge-ios-workspace-core-final.log`). The existing screenshot isolation/renewal/route/
Stop regression also passed (`/tmp/devicebridge-ios-workspace-screenshot-regression.log`). Its wait
now correctly observes screenshot readiness, rather than treating device selection completion as
capability readiness. Final incremental Debug build passed
(`/tmp/devicebridge-ios-workspace-debug-final.log`), followed by deep/strict signature verification.
Only the validated previous Debug process was terminated; the new app was opened with `open -g`
and its exact executable process verified running. No Release/DMG or desktop UI automation was run.
T064 still requires real load/restart/route-switch/endurance checks; clipboard and wireless remain
unqualified independently. Earlier checkpoints below are historical, not current UI status.

## Production discovery and monitoring loop — 2026-09-08

The newer `MemoryProbe.swift` now calls the production app-scoped `discover` method and explicitly
starts `MemoryMonitor` with the resulting binding as its MemorySampling source. The normal loop
waits three seconds after each completed sample. After two samples the probe calls Stop, closes
its binding and checks that the monitor's target and retained samples are cleared. It never
launches/restarts an app, invokes GC, touches clipboard, edits a Flutter project or takes desktop
input. It has a 40-second monitor wait inside the existing 60-second outer process limit.

Physical **`devicebridge-ios-vm-bound-memory-jpp97xyz` passed** with two real samples: heap/external
were present, timestamps advanced, target/device/PID checks held, RSS and fabricated process-start
identity were absent. The production monitor stopped and owner closed. Independent before/after
app PID and paired wired route were unchanged; exit zero, stderr empty. This adds two samples to
the earlier four one-shot observations, but does not assert changing values, deliberate load,
process restart, physical route switch or wireless stability.

Binding conformance checks the exact target/transport and maps a dead owner to a distinct terminal
`invalidated` event. Busy renewal is non-terminal. MemoryMonitor clears invalidated series; existing
Android provider failures retain trends and may retry. A deterministic Stop-during-provider test
failed against the old implementation, which restored samples/target/latestEvent after Stop, then
passed after start/stop revision guards. Store completion now atomically consumes eligibility;
cross-actor Workspace publication still requires its own current monitor/selection checks.

Final serial Core **363 tests / 56 suites passed**, 12.882 s
(`/tmp/devicebridge-ios-production-monitor-final.log`), including the review regression preventing
cancelled discovery from hiding cleanup failure. Independent scoped review is clear. The latest
headless Workspace manual iOS URI gate also passed, preserving Android and stopped-Workspace
admission. These do not erase historical public-copy timing failures documented in discovery.

Workspace now handles the new terminal event with bilingual messages, but app selection,
discovery binding commit, metadata renewal and Start/Stop consumption are still T114 work. No
incremental app build or relaunch was done in this slice; the current Debug UI does not contain
working iOS memory. T064 remains open. The one-shot checkpoint below describes the earlier probe.

## Native verified iPhone one-shot sampling — 2026-09-08

The production binding now exposes explicit `readMemory()`; discovery and renewal remain metadata
only. One private native USB owner performs getVM → getMemoryUsage(pinned isolate) → getVM, then
the binding rechecks independent CoreDevice app/path/PID and renews VM continuity before returning
the sample. Store selection/generation is checked after each channel RPC, not just at the outer
method boundary. Failure, close and cancellation make the binding terminal. No MemorySampling
adapter, Workspace Start/Stop integration or current Debug UI readiness is enabled yet.

`scripts/ios-vm-spike/MemoryProbe.swift` is separately opt-in via DEVICEBRIDGE_VM_MEMORY_PROBE=1,
accepts bounded stdin metadata, uses native Bonjour and the production issuer, and performs two
explicit samples one second apart. The orchestration process is bounded to 60 seconds; no GC,
target-project edits, app launch, clipboard, desktop input or permission changes occur. It closes
only its own binding; the target app and external Flutter/DDS session remain running.

Physical `devicebridge-ios-vm-bound-memory-9mxvjkzx` **passed**: both heap/external metrics reported,
timestamps advanced, expected independently obtained app PID matched and the owner closed. The
final timestamp-capture refinement was recompiled and repeated successfully in
`devicebridge-ios-vm-bound-memory-ou9infmy`. Both exited zero with empty stderr and unchanged
independent app PID/paired wired route. Four real samples across the two probes establish readable
metrics on this phone/runtime; no deliberate load change, process restart or physical route switch
was performed, and changing memory values were not asserted. T064 remains open for those checks.

Tests initially recorded 26 failures against the unimplemented sampling API, then passed. They
cover nil-vs-zero metrics, invalid numeric/type values, changed PID/isolate/timestamp/app path,
single-flight sampling/renewal and stale/cancelled/closed samples. Review identified a reachable
pre-usage gap: after a held getVM, a changed store generation could still allow getMemoryUsage to
be sent, although publication was rejected. `sampleBeforeMetadata` reproduced that exact request
before channel-level session checks were added. The regression now proves no usage RPC is sent.
Unqualified channels also reject usage without any RPC.

Serial full Core verification after the session fix passed **351 tests in 56 suites**, 12.973 s
(`/tmp/devicebridge-ios-memory-session-green.log`). The final timestamp-only placement refinement
passed **40 focused tests in four suites** (`/tmp/devicebridge-ios-memory-focused-final.log`) and
the second physical probe above. The headless manual-URI admission check still passes; Android
source and behavior were not changed. Independent review found no remaining sampling attribution
or lifetime defect. Existing earlier process-fixture timing failures remain in ios-vm-discovery.md.
The final unchanged-binary serial recheck also passed all 351 tests after the timestamp refinement,
12.905 s (`/tmp/devicebridge-ios-memory-release-gate.log`; this filename denotes a test gate, not
a Release build). No macOS app rebuild/relaunch or packaging occurred in these Core-only slices.

Metric interpretation was corrected using the pinned runtime implementation: Dart 3.7.2
`Isolate::PrintMemoryUsageJSON` reads its isolate group's shared heap. These are Dart heap/external
values queried through a pinned isolate, not that isolate's exclusive usage and not app RSS/PSS.
Do not sum sibling-isolate readings. `capturedAt` is host response-receipt time, captured before the
following session-validation await. Missing metrics remain nil; no OS process-start value is
fabricated. See [the source decision](../research.md#memory-scope-correction-from-the-pinned-runtime-implementation).

The following sections are retained historical evidence, superseded by this core sampling result
only where explicitly stated. Current Workspace/UI integration and full physical acceptance remain
uncompleted.

## iOS unverified-attribution safety slice — 2026-09-08

The manual attach flaw described below is now fail-closed, not a qualified iOS memory feature.
The real Core client previously returned a sample labelled with the selected iPhone for both
missing and matching target PID; a different PID could incorrectly publish a restart identity.
Three synthetic cases reproduced those failures (9 assertions) before the change. The Core client
now rejects iOS targets before any VM RPC. The actual Workspace also rejects manual iOS attach
before creating a client or monitor; its button uses the same admission condition. The readiness
message explains the missing verified device/app connection in English and Chinese.

`scripts/verify-workspace-ios-memory.swift` reproduced the Workspace starting a monitor before the
fix, then passed after the fix. It also exposed stopped Workspace admission, which is now rejected;
existing Android attach remains enabled. The harness runs in-process against real Workspace code
and synthetic inventory, without a window, phone command or live VM request. Compile/run it with
the static Core product through `scripts/compile-core-check.py`, like the existing Workspace checks.

Verification: 6 Flutter VM tests (including the 3-case rejection test), 294 Core tests in 50 suites,
headless iOS admission, retained module layout, and runner Workspace regression all pass. Existing
opt-in physical Core tests remain skipped in the general suite. Incremental Debug build and strict
signature validation pass. Independent read-only review found no remaining iOS URI-only bypass
or Android admission regression in this slice.

T110/T111 remain open for verified binding types and lifecycle acceptance. T112 metadata findings
are tracked separately in `ios-vm-discovery.md`; no iOS memory sample has been qualified.

## Scope correction — iOS recovery

T061 proves Android VM discovery/ADB forwarding and a shared RPC client, not iOS discovery.
Production review found iOS preparation returns an actionable unavailable state while manual URI
attach can construct a target without independently verified process/device identity. Consequently
even successful manual RPC would not qualify iPhone memory. T110–T114 now track candidate admission,
device-specific discovery/forwarding, process binding and integration. T064 remains open.
These are code-review findings, not a physical VM sampling pass. The signed iPhone runner startup
recorded in `ios-channel-spike.md` does not establish a VM connection.

## Latest production-fix verification — 15:19

The Android provider now reads stable kernel start ticks, with PID-reuse and malformed-stat tests.
Both physical reruns passed initial and 3-second-later SystemUI memory samples. T060 is closed;
T064 remains open for real development-app load/restart, Flutter VM and transport-switch checks.
This supersedes the continuity failure below, not the broader outstanding qualification.

## Physical follow-up

Android first memory sample passed, but the sample 3 seconds later incorrectly reported a restart
with unchanged PID. `ELAPSED` changes as the process runs and is not a stable start identity. T060
is reopened and T064 remains open. This supersedes the earlier NOT RUN status below; no Flutter VM
or iOS memory acceptance is inferred. See [physical-background.md](physical-background.md).

## Automated evidence

- Full DeviceBridgeCore suite: PASS, 94 tests in 23 suites.
- Android provider fixtures: PASS for running-process discovery, modern and legacy `dumpsys meminfo`
  parsing, missing RSS, malformed output, stable PID sampling, and PID/start-identity restart handling.
- Flutter VM Service fixtures: PASS for loopback-only URI discovery, exact ADB forwarding cleanup,
  WebSocket JSON-RPC `getVM` and `getMemoryUsage`, explicit GC, disconnect, restart detection, and
  VM URI redaction.
- Memory monitor fixtures: PASS for three-second post-completion cadence, single-flight sampling,
  bounded trends, device/session stale-result rejection, stop handling, and restart series reset.
- Native macOS app build: PASS.
- Full macOS UI suite: PASS, 6 tests. The memory panel verifies that readiness does not start
  sampling, application selection gates Android sampling, and published values show timestamp,
  metric source, trend data, and a Stop action.

## Remaining qualification

- T064 remains open because MobAI's local desktop API was unavailable, so no command was sent to a
  real Android or iOS device in this session.
- Android still needs an observed debug/profile run covering process discovery, changing load,
  application restart, and USB/Wi-Fi transport switching.
- iOS OS-level application memory is intentionally reported as unsupported. Flutter memory requires
  a debug/profile VM Service exposed through a verified device-specific route with process binding.
  Its real-device flow remains unqualified. It may reuse transport evidence from the runner
  experiment but does not require the XCTest content dispatcher.
- These metrics are sampling diagnostics (Android PSS/RSS or Flutter heap/external bytes), not a
  replacement for Instruments, Android Studio Profiler, or DevTools allocation analysis.

## Test infrastructure note

- On Xcode 26.6, `CODE_SIGNING_ALLOWED=NO` produced an invalid macOS UI-test runner that the OS killed
  before XCTest bootstrap. The same tests passed with Xcode's default local ad-hoc signing; product
  code was unchanged for this infrastructure correction.
