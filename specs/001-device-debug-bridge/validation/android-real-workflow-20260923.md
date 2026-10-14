# Android real-workflow correction

## Contract and evidence

User requires clipboard reads/writes without foregrounding a helper, one card per verified physical
Android device across USB/Wi-Fi, and desktop UI validation of repeated operations and reconnection.
This supersedes the Android foreground allowance in the September 16 qualification record.

Baseline: two regression tests fail on whitespace-containing ADB/mDNS names. Clipboard currently
uses an ordinary Activity's context and cached TCP connection; returning to a business app invalidates
the platform's read permission without invalidating that connection. MuMu foreground read/write was
not evidence of background capability on Android hardware.

## Slices

1. Preserve complete ADB service names; verify a hardware identity through each authorized transport
   before merging routes. Keep unknown identities separate. Reuse inventory and maintenance ownership.
2. Execute clipboard commands in an ADB shell process, bound to the captured hardware identity.
   Do not launch an Activity or automatically fall back to a foreground read. Preserve exact Unicode,
   empty vs unavailable, verified writes, request bounds, cancellation and stale-session publication.
3. Validate desktop UI with a physical phone: initial selection, repeated background reads, write/read,
   USB + wireless single card, transport loss and reconnect. Update version/build only after checks.

Structural budget: one clipboard execution path, no clipboard-owned Activity or persistent port;
one inventory identity resolution boundary; reuse session-generation guards and route supervisor.
Shell clipboard operations are short-lived and use standard input/output; the existing foreground
helper is reserved for explicitly requested connection maintenance.

## Current status

September 23: no physical Android phone in `adb devices -l`; user notified. Launched the user's
existing MuMu Android 12 emulator and tested the locally built desktop app through Computer Use.
Physical USB/wireless acceptance remains pending. Publication withheld. The user subsequently requested
a local replacement and build-cache cleanup; local candidate version 0.1.5 build 4 was packaged
with this acceptance limitation unchanged.

### Implemented and observed

- Preserved whitespace-containing ADB and mDNS names (baseline: 2 tests, 7 failed expectations).
- Merge verified hardware serial routes. Devices with no serial use a verified boot UUID for this
  boot only; unknown identity stays separate. MuMu has a blank serial, so this fallback is exercised.
- Clipboard uses one short-lived shell process per action, framed stdin, on-device identity and
  deadline checks. No clipboard Activity or persistent TCP channel. Explicit Wi-Fi maintenance remains
  separate and may launch its helper only when requested.
- MuMu ADB starts as UID 0; the new process drops to shell UID/GID 2000 before Binder access.
  Without this, the emulator rejected clipboard grants. Ordinary ADB UID 2000 needs no change.
- Actual disconnect testing found a recovered-but-no-session defect: recovery with no helper context
  was mistaken for a redundant user click. Explicit selection intent now distinguishes verified
  recovery. Recovery discovery also preserves verified identity metadata for subsequent recoveries.
- Independent read-only review found misleading failure advice to restart a persistent helper.
  Generic clipboard transport/protocol failures now advise connection checks and reselecting.

### Real desktop UI operations, September 23 ~17:20–17:35

App: `.build/android-workflow/Build/Products/Debug/DeviceBridge.app`.
Business app remained `com.daohong.billard_data/com.example.billard_data.MainActivity` in `dumpsys window`.
`pidof dev.debugutility.helper` returned no ordinary helper process after operations.

1. Selected MuMu; read repeatedly using the desktop button without switching the business app.
2. Sent and read exact public fixture `DeviceBridge 后台剪切板 📋\n2026-09-23 连续读写验证` (63 UTF-8 bytes).
3. Cleared editor, sent, then read: UI showed success, empty editor and 0 bytes (screenshot verified).
4. Connected the same emulator through `127.0.0.1:16384` and `localhost:16384`: one device row.
5. Disconnected the selected endpoint, waited for recovery, clicked read successfully. Reconnected
   the other endpoint and repeated the disconnect/recovery/read cycle successfully a second time.
   These are two wireless aliases, NOT evidence of physical USB-to-Wi-Fi behavior.
6. Sent the Unicode fixture, switched to screenshot, captured 2160×3840 successfully, returned to
   clipboard, read exact fixture again; business app still foreground.

### Automated checks

- Full Core suite: 504 tests / 68 suites passed on final full rerun. First run had an existing iOS
  subprocess timing test fail before its fixture started; that 5-test suite passed independently,
  then the complete rerun passed. Retain this timing sensitivity as a test-environment risk.
- Android `testDebugUnitTest assembleDebug`: passed.
- Device selection check: passed. Workspace inventory check including no-helper-context recovery: passed.
- Xcode Debug build: passed. Helper packaging checks: 6 tests, 1 skipped, successful.
- Final failure-message change: all 11 ClipboardService tests passed.
- Independent review found no statically confirmed identity crossover or stale publication defect;
  OEM compatibility remains a runtime question, not proven by that review.

### Remaining acceptance boundary

Connect the user's physical Android phone with USB and paired wireless ADB simultaneously. Verify one
row, USB preferred, background repeated/empty/Unicode read-write, USB unplug recovery, second recovery,
and lock/unlock behavior without foreground helper. Also qualify OS/OEM clipboard Binder variants on
that phone. Do not present emulator aliases as this physical evidence. Device info/Shell wireless
availability and explicitly started keepalive are outside the clipboard UI tests recorded above.
Restored the original `127.0.0.1:16384` emulator route and disconnected the added `localhost` alias.

## Local installation and cache cleanup

0.1.5 build 4 installed at `/Applications/DeviceBridge.app`; bundled helper version 4,
arm64 agent, release verifier and deep signature verification passed. Opened installed app with
Computer Use and confirmed its device-list window and `/Applications` process path.
DMG retained at `dist/ci/0.1.5-build4`; previous installed app retained at
`dist/local-backups/previous-app.o8XLbI/DeviceBridge.app`.
21 explicitly inventoried project build/cache directories (approximately 3.3 GiB) were moved to
`/Users/fus/.Trash/DeviceBridge-build-caches.CUC1Ue`, and their original locations verified absent.
Includes repository Swift/Xcode/Gradle/Dart outputs, inventory-check scratch build, project-specific
Xcode DerivedData and cached IOSRunnerBuilds-v1. Recoverable; disk space is not reclaimed until Trash
is emptied. Shared SDK/global dependency caches, settings, pairing and session data were not removed.
No commit, push or merge performed in this installation step. Physical acceptance remains pending.

## Physical wireless incident investigation, September 23

Phone: OPPO PLD110 / K12s 5G, Android 16, serial `3B66420179800000`.
Installed candidate: 0.1.5 build 4. This section supersedes the earlier no-physical-device status;
full physical acceptance is still incomplete. No production edits in this diagnostic slice.

### Verified observations

- 18:13:55 desktop clipboard read succeeded without bringing a helper Activity forward.
  User subsequently copied public fixture `22413`; by 18:14:35 desktop was reconnecting.
- During failure, both IP and service-name ADB routes remained listed as `device`, but shell echo
  timed out. MuMu shell on the same host ADB server worked. Raw TCP connections to phone port
  39515 also timed out, including an explicit Wi-Fi source/interface and IPv6 attempt. Phone ping
  responded and closed ports 45285/34839 returned refusal. Therefore the failure was below the
  clipboard operation, and `adb devices` was not proof of executable commands.
- Host log shows successful TLS reconnections at 18:23:01 and 18:23:11. USB arrived at 18:26:53;
  do not attribute recovery to USB insertion. Phone adbd PID/start and port remained unchanged.
- After recovery, direct clipboard requests on BOTH wireless routes returned `22413`; desktop USB
  read also succeeded. Repeated parallel USB/IP/service-name shell probes passed. Exact names
  containing spaces and `(3)` execute successfully; the name itself is not demonstrated broken.
- Direct unicast DNS queries to phone UDP 5353, bypassing host discovery caches, returned all three
  service registrations: unsuffixed -> 45285, `(2)` -> 34839, `(3)` -> 39515. Reconfirmed 18:44:57
  from source `192.168.13.6:5353`; first two ports refused, 39515 connected in 0.016 s. Phone listener
  inspection likewise showed only 39515. Host PID 21861 repeatedly tries the two refused ports.
  This proves stale registrations are actively served by the phone, not merely cached on the Mac.
  It does NOT prove these registrations caused the initial current-port outage.
- User confirms phone VPN was not enabled. No evidence supports blaming phone VPN or screen-off.

### Confirmed application recovery defects

1. `ConnectionMaintenance.recover` sets `actionRequired` after eight attempts; `tick` then returns
   without discovery/probing. Observed UI stayed at attempt 8/8 after healthy wireless and USB were
   available. Passive route arrival cannot recover this terminal state.
2. `DeviceSessionStore.replaceInventory` retains the maintenance-owned route and pins it preferred,
   even when absent from fresh discovery. Manual reselection used obsolete transport 4888 and failed;
   explicit desktop refresh then retry selected USB successfully. Fix must preserve in-flight route
   ownership while separating observed candidates from committed session ownership.
3. UI briefly retained retry count 8/8 after a successful new USB selection.

### Remaining discriminating checks and boundaries

- Original 39515 TCP outage mechanism remains unproven: no simultaneous phone-side TCP state was
  captured during the outage. Current successful commands do not resolve that historical cause.
- Asked permission to toggle only existing wireless debugging off/on with USB retained, observing
  registration withdrawal/republication. Do not remove pairing, restart phone, or kill shared ADB.
- Attempted isolated ADB-version comparison was inconclusive; temporary servers 15038/15039 were
  cleaned up. Default server PID 21861 was not restarted. Do not claim a version-specific defect.
- No release/commit claim until application recovery defects and physical failure/recovery acceptance
  are resolved. Next slice should preserve regression evidence before changing recovery ownership.

### Second captured outage, 18:47:31

- MobAI USB observation at 18:46:06 succeeded; phone browser input contained `22413`.
- All three phone routes executed echo successfully at 18:47:30 (USB 0.051 s, IP 0.133 s,
  service name 0.137 s). MobAI long-press request began 18:47:31.498, but eventually returned
  `get UI tree timed out` at its first step. The actual long press/copy was NOT performed;
  do not attribute the outage to a completed long-press gesture.
- From the 18:47:33 probe onward, USB and BOTH wireless routes timed out together, repeatedly.
  At ~18:48, host `devices`/phone `get-state` still returned immediately, MuMu echo passed,
  phone ping worked, port 39515 TCP connect timed out, old ports still refused.
- User confirms phone UI remains normally interactive. This narrows the fault to this phone's
  debugging paths, not whole-phone unresponsiveness or a Wi-Fi-only failure. Phone-side adbd
  processing stall is a hypothesis; no stack trace or per-thread state from the failure yet.
- Both incidents followed MobAI UIAutomator2 startup, but causal attribution is NOT established.
  Second request timed out while retrieving UI hierarchy, before performing the intended gesture.
- Phone-wide cumulative ListenOverflows/ListenDrops were 7989 before this second outage; without
  a time/port-specific delta, this is not evidence that port 39515 overflowed during either outage.
- Preserve current fault: no shared-server reset, no pairing changes. Asked user to return Home
  only to discriminate current-browser/system-policy effects. Pending USB log retrieval is bounded.

### Located blocking boundary, 18:50–18:53

Pending log retrieval completed at 18:50:41 without resetting either ADB server or phone. Device log:

```text
09-23 18:48:34.594  5938  5938 E adbd : failed to connect to socket 'tcp:6790': Connection timed out
09-23 18:49:37.826  5938  5938 E adbd : failed to connect to socket 'tcp:6790': Connection timed out
09-23 18:50:41.318  5938  5938 E adbd : failed to connect to socket 'tcp:6790': Connection timed out
```

PID equals TID: these failures occur on adbd's main thread. Three serial ~63-second waits align
with the 18:47:31 request and recovery at 18:50:41. Queued wireless accepts resumed at 18:50:41.
`adb forward --list` ties this phone's host port 57170 to phone `tcp:6790`; MobAI log identifies
57170 as its UIAutomator2 bridge started at 18:46:06. The service process is
`run.mobai.uia2.server`, PID 31682, still alive/instrumented, not a cached process.

Crucial independent check after recovery: phone-local `toybox nc -w 2 127.0.0.1 6790`
timed out in 2.070 s, while USB and both wireless shell echo probes immediately afterward passed
in 0.054/0.187/0.187 s. Thus the automation server's local endpoint remains non-responsive even
when ADB transport is healthy. This is not a host Wi-Fi reachability failure. Listener exists;
exact internal server stall/backlog cause has not been obtained. Java stack retrieval with
`debuggerd -j 31682` was denied (`root is required`); no privilege escalation attempted.
Phone-wide ListenOverflows increased from 7989 to 8210 during this window (supporting context,
not a port-attributed measurement).

Android 16 upstream path corroborates the blocking boundary:
`adb.cpp` A_OPEN -> `create_local_service_socket` -> `services.cpp:service_to_fd` ->
`socket_spec_connect` -> `network_loopback_client` for `tcp:6790`. The observed main-thread
timeout, forwarding map, and phone-local endpoint timeout establish this second outage's fault
chain. They do not prove the OEM automation server's exact internal bug or conclusively establish
the first outage's cause (its equivalent device logs were no longer available).

Sources:
- https://android.googlesource.com/platform/packages/modules/adb/+/android16-release/services.cpp
- https://android.googlesource.com/platform/packages/modules/adb/+/android16-release/socket_spec.cpp
- https://android.googlesource.com/platform/packages/modules/adb/+/android16-release/sockets.cpp
- https://android.googlesource.com/platform/packages/modules/adb/+/android16-release/adb.cpp

Current disposition: stop invoking the non-responsive automation endpoint; no phone reboot,
wireless-debug toggle, pairing deletion or shared ADB restart. All diagnostic subprocesses ended.
DeviceBridge recovery bugs remain independent product defects requiring focused regression tests
and repair; do not present the MobAI/adbd finding as absolving those defects or completing acceptance.

### Follow-up: why the MobAI endpoint stalls (not yet resolved)

At ~18:54–18:58 PID 31682 remained alive; ActivityManager reported `cached=false`,
`isPendingFreeze=false`, `isFrozen=false`, active instrumentation and foreground scheduling.
APK and runtime traces identify an Appium-derived Netty server. Netty thread kernel wait channels
were `__arm64_sys_ppoll`; this alone is normal waiting and does not prove deadlock or its cause.
No evidence yet distinguishes selector wakeup failure, stopped acceptance, full backlog, or a
device-local networking policy. Do not claim UI hierarchy traversal itself caused the stall.

Normal debuggable-app `run-as` access succeeded. Requested a non-terminating ART SIGQUIT stack dump
as the app UID: ART wrote traces to tombstoned, but the trace location is not readable under the
available permissions. At that moment Netty logged Connection reset by peer; this is not proof of
the original failure. A subsequent phone-local HTTP `/status` probe still timed out.
JDB attachment was bounded at 20 seconds and timed out without a usable stack. Its temporary
`tcp:50435 -> jdwp:31682` forward was removed; debugger subprocess and JDWP inventory client ended.
No root, permission changes, business-app termination, or automation server restart performed.

The confirmed result remains the propagation mechanism (6790 connection waits block adbd's main
thread), NOT a fully established internal MobAI root cause. Explicitly corrected this distinction
to the user when asked why MobAI itself hangs.

### Controlled follow-up authorized by user, starting 19:02

- 75-second no-MobAI-request baseline: all 24 parallel rounds on USB/IP/service-name passed.
  Existing MobAI process was still present, so this is an idle-service/request-free baseline,
  not proof with the service absent. Desktop initially remained stuck at 8/8 until reselected.
- First desktop clipboard read returned unavailable content, while transport probes passed.
  Direct helper stderr located null primary clip at ShellClipboard.kt:121, not a transport
  timeout. Wrote public fixture `22413` through desktop UI, verified successful write and two reads.
- Stopped only MobAI phone bridge via its API. Teardown request also coincided with an ADB outage;
  stop completed around 19:05:01, phone automation PID disappeared, owned forward disappeared,
  and all routes resumed. No ADB restart or wireless toggle.
- Restarted bridge at ~19:05:27: new PID 21393, forwards 58968->6790 and 59022->7810.
  A minimal JDWP client successfully captured Java stacks using normal debuggable-app access,
  resumed each briefly inspected thread, detached, and removed its temporary forward. Unlike
  the earlier JDB attempt, this worked. Healthy Netty threads were in PollSelectorImpl.select;
  UiAutomation and instrumentation threads were idle in their message queues.
- 19:06:29 all routes healthy; requested only wait-for-stability plus UI-tree observation.
  Observe timed out after 30 seconds, and all routes began timing out by 19:06:35.
  No long press or clipboard gesture was requested in this reproduction. Screenshot-only test
  remains pending until this fault is characterized. Do not repeatedly enqueue automation calls.
- Temporary local diagnostic scripts live at /tmp/devicebridge-mobai-audit.Szima4.
  probe.py uses bounded parallel echo probes and a scoped error-log stream; jdwp_probe.py
  captures selected thread stacks and cleans its owned debugger forward. No product code edits.

### Confirmed OEM-policy cause, 19:10–19:13

The previous claim that system freezing was excluded was too broad. Android ActivityManager's
`isFrozen=false` did NOT exclude OPPO Hans policy. Device-side evidence now identifies it:

```text
18:46:53.786 OAppNetControlService: Hans update:[10402=true] ... blackList:[...,10402]
19:05:01.410 OAppNetControlService: Hans update:[10402=false] ...
19:06:16.308 OplusAlarmAdjustment: proxyAlarmsByUid(), uid=10402, pkgName=run.mobai.uia2.server
19:06:19.317 OplusProxyWakeLock: add uid:10402 ... pid=21393 ... to FroceReleaseWakeLock list
19:06:19.320 OAppNetControlService: Hans update:[10402=true] ... blackList:[...,10402]
```

The new bridge was healthy on startup, including readable JDWP stacks, before the 19:06:19 policy
transition. MobAI UI request at 19:06:30 then encountered the same serial adbd-main-thread port-6790
timeouts at 19:07:33.796, 19:08:36.773, 19:09:40.003. Phone-local connect-only probes (`nc -z -w 2`)
to 6790 timed out both as shell and as MobAI's own UID. Direct Wi-Fi connections to 6790 and 7810
also timed out. Standard netpolicy still reported effective blocked state NONE for this UID;
the OEM log is the discriminating evidence, not the standard process/network-policy view.

Non-restart cross-check on SAME PID 21393, with no settings or permission changes:

1. 19:12:12 requested ART's non-terminating stack dump as the debuggable app UID.
2. 19:12:12.511 Hans explicitly removed UID 10402 from its blacklist.
3. Immediately, phone-local connect-only 6790 probe succeeded (0.051 s).
4. First UI-tree call returned a prompt execution error, NOT a timeout; the next MobAI batch
   successfully captured screenshot (528 ms) and UI tree (176 ms) of the unchanged browser page.
   Screenshot artifact: /tmp/devicebridge-mobai-audit.Szima4/hans-release-window.png.
5. 19:12:30.561 Hans re-added UID 10402 after ~18 seconds. No adbd restart, app restart, wireless
   toggle, or content gesture occurred in this window. Follow-up connect-only probes timed out
   again, while ordinary USB/IP/service-name echo probes remained healthy because no new ADB
   forwarded requests to the restricted service were queued.

Conclusion: OPPO's Hans background management restricts the MobAI automation package and its
network endpoint; forwarding new requests to that restricted endpoint exposes synchronous
adbd connect waits, stalling all transports. This supersedes the unproven Netty-deadlock theory.
Do not turn repeated diagnostic signals/restarts into a keepalive workaround. Durable remediation
needs a supported per-app background-policy exception or an OEM-compatible MobAI service lifecycle,
plus independent repair of DeviceBridge's exhausted-retry/stale-selection behavior. System-wide
Hans disabling, root, security bypass, or permanent policy changes were not authorized or performed.

End-of-diagnostic state, ~19:13: MobAI bridge stopped through its API during a temporary
diagnostic wake window; target PID and phone forwards absent, other devices' forwards untouched.
All bounded collectors ended; no debugger attachment remains. Original USB and two wireless ADB
routes preserved. Desktop again showed the independent 8/8 recovery defect; reselected phone,
clicked Read, and verified UI `已读取`, `22413`, 5 bytes. No product fixes, commits, or release
performed in this diagnostic turn.
