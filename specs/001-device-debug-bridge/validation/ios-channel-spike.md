# T082 iOS Channel Experiment

Date: 2026-09-07, Asia/Taipei
Status: USB public-marker transport/stop/lease checks PASS; environment secret bootstrap NO-GO;
replacement mutually pinned TLS 1.3 physical identity exchange PASS. Wireless and full secure lifecycle
remain unqualified. T082/T083 remain open; no production content channel is enabled.

## Authorized scope

The user requested the existing personal iOS signing identity. Reused the one valid Apple
Development identity and a cached compatible profile; no new certificate, account login, portal
registration, automatic provisioning updates, dependency installation or desktop UI automation.
Only the designated physical iPhone was targeted. No clipboard, screenshot or photo action ran.

## Environment and route evidence

- Reference device: iPhone 12, iOS 18.3.1. Raw identifiers are omitted.
- `devicectl device info details`: paired, Developer Mode enabled, transport wired.
- `/var/run/usbmuxd` exists. `iproxy`, `idevice_id` and `ios` are not present in the current PATH.
- A bounded standard-library `ListDevices` request used the system socket, validated header
  length/version/message/tag, and matched the exact designated UDID against CoreDevice metadata.
  Result: one matching entry, ConnectionType USB, exactly one USB route. No `Connect` or content
  request was sent. This proves inventory correlation, not a persistent runner socket.
- Protocol research pinned to libusbmuxd `93eb168bf6b07472d17781328c21df0c60300524`; source links and
  the corrected Wi-Fi limitation are in [the contract](../contracts/ios-runner-channel.md).

## Signed physical startup — 18:48–18:49

Build action: `xcrun xcodebuild build-for-testing`, project
`helpers/ios/DeviceBridgeRunner.xcodeproj`, scheme `DeviceBridgeRunner`, configuration Debug,
exact designated-device destination, automatic signing with the existing certificate's Team.
No `-allowProvisioningUpdates` was passed. Personal identity/Team were resolved in memory and not
written into the project. DerivedData: `/tmp/devicebridge-personal-runner-debug`.

Results:

- Build exited 0. Host and XCTest runner signed with an existing development identity/profile.
- `codesign --verify --deep --strict`: both app bundles passed.
- Decoded embedded profile checks: both unexpired and include the exact designated phone.
- `test-without-building` consumed the unique `.xctestrun` from those same build products.
  Selected only `DeviceBridgeRunnerUITests/RunnerSmokeTests/testRunnerCanLaunchManagedHost`,
  with parallel testing disabled and one destination.
- Physical result: 1 test, 0 failures, 7.358 seconds test-body duration; command exited 0.
  This confirms installation/startup and the test host's expected label, not content capabilities.
- Result bundle: `/tmp/devicebridge-personal-runner-smoke.xcresult`. Development artifacts may
  contain Xcode signing/device metadata and are not suitable for sharing without redaction.

Warnings included missing launch/orientation configuration and absent AppIntents metadata; neither
prevented this smoke test. They are not evidence that production startup/packaging is qualified.
No shared app setting was changed and the running Mac app was not rebuilt or restarted.

## Remaining go/no-go checks

1. Implement and exercise a bounded identity-only runner loopback listener on USB; verify persistent
   exchange, exact route, warm latency, background lifetime, restart and cleanup.
2. Before using a secret nonce, audit a non-secret canary through the exact Xcode bootstrap and its
   artifacts/logs. `TEST_RUNNER_` forwarding alone is not a non-persistence guarantee.
3. Find and prove a wireless mechanism compatible with the no-general-LAN-listener contract.
   Upstream iproxy network mode is direct LAN TCP, so it does not establish that mechanism.
4. Only after the T082 route/security decision, implement and qualify the concrete T083 launcher,
   T084 authenticated dispatcher and T036 workspace integration. Then run T041 clipboard and
   T048 screenshot checks with explicit actions and test data.

The original preflight above remains historical evidence. The following actual transport runs
supersede its NOT RUN status, but do not close the authenticated-channel or feature gates.

## Physical USB identity-only exchange — follow-up

Implementation is explicitly experimental: `helpers/ios/DeviceBridgeRunnerUITests/USBIdentityProbeServer.swift`
and opt-in `RunnerSmokeTests.testUSBIdentityProbe`, with contributor tooling under
`scripts/ios-channel-spike/`. No production core/workspace provider was enabled or changed.
See [reproduction instructions](../../../scripts/ios-channel-spike/README.md).

### Red/green evidence and safety boundaries

- Before adding the listener, exact USB `Connect` to its designated test port was refused. The
  existing signed runner therefore could not satisfy the actual socket test merely by being installed.
- Host protocol tests initially failed for absent route selection, framing and validation; seven
  tests then passed. Swift-server tests initially failed because no listener opened; six then passed.
  Fresh combined headless run: 13 tests passed. These use real local sockets, not a fake phone.
- Signed incremental Debug `build-for-testing` passed using the existing personal identity, with
  no provisioning updates. Each physical run used only the new opt-in identity test from that build.
- Listener binds IPv4 `127.0.0.1`, accepts one client, and immediately closes its listening socket.
  No LAN listener, host TCP proxy, new dependency, Mac window or desktop UI test was introduced.
- Protocol admits only `identity`/`stop`, a public canary and increasing request sequence. Frames
  are at most 4096 bytes. It rejects content actions, wrong canary, replay, malformed/excessive frames.
  This canary comparison is NOT cryptographic authentication and is not suitable for real content.
- The test runs socket work off the iOS main actor. Accept expires after 60 seconds; connected
  lifetime is at most 90 seconds; no complete valid request for 30 seconds expires the lease.
  Partial bytes do not renew it. Exit closes exact owned resources, not a shared device service.
- Each physical run pressed Home only on the designated iPhone before opening its socket.
  XCTest system/user attachments were configured `keepNever`; no explicit clipboard, screenshot,
  photo or file-content command ran. This is a Home-screen lifetime check, not locked-screen or soak
  qualification. The production Mac app was not rebuilt, restarted or controlled.

### Observed runs

| Mode | Exchange | Warm RTT (30 requests) | Terminal result | Physical XCTest |
|------|----------|------------------------|-----------------|-----------------|
| Stop | 37 identity replies on one socket; renewals every 5 seconds | median 0.40 ms, max 1.65 ms | Stop acknowledgement + EOF after 35.05 s | 1 passed, 0 failed, 0 skipped |
| Orphan | 30 replies, then socket left open without heartbeats | median 0.65 ms, max 1.14 ms | Lease expiry + EOF after 30.02 s | 1 passed, 0 failed, 0 skipped |
| Reject | 30 replies, then unsupported test action with no payload | median 0.40 ms, max 0.99 ms | Rejection + EOF after 0.01 s | 1 passed, 0 failed, 0 skipped |

The exact selected USB route still existed after each run while its probe port refused new
connections. The subsequent runs reopened a fresh runner/socket successfully. This proves three
bounded launches, not crash recovery, cable switching, long-term uptime or the production launcher.
The five-second experimental renewal cadence does not qualify the planned ten-second production
heartbeat. Millisecond figures are raw probe RTT, not clipboard/screenshot/UI response times.

Local result directories (contain Xcode metadata; redact before sharing):

- Stop: `/var/folders/mm/y7mmzv7x2ps17jls3gh616p00000gn/T/devicebridge-usb-spike-kela_s8j`
- Orphan: `/var/folders/mm/y7mmzv7x2ps17jls3gh616p00000gn/T/devicebridge-usb-spike-w7eyw9_d`
- Reject: `/var/folders/mm/y7mmzv7x2ps17jls3gh616p00000gn/T/devicebridge-usb-spike-tlkosfqd`

### Discriminating nonce-bootstrap result: NO-GO

Each run generated a fresh **non-secret public canary** in host memory and supplied it only through
`TEST_RUNNER_DEVICEBRIDGE_PUBLIC_CANARY`, not through shell text, argv or an authored `.xctestrun`.
All three runs found its exact bytes in the exported xcresult **action log**. A parsed-field check
located it in `subsections.…commandInvocationDetails.commandDetails`, associated with the runner
environment key `DEVICEBRIDGE_PUBLIC_CANARY` (after prefix stripping). Values are omitted here.

Captured xcodebuild stdout and the authored `.xctestrun` did not contain the canary. Console/build
log exports were unavailable; no negative claim is made for them or uninspected Apple diagnostics.
One positive persisted action-log occurrence is sufficient to reject this proposed secret bootstrap.
No real nonce or user content was used, so this finding did not expose a real session secret.

Decision: raw USB communication is feasible on this reference phone. **Do not put session nonces,
clipboard contents or VM URIs in test-runner environment variables.** Redacting/deleting logs later
would not meet the no-persistence contract. T082 still requires an independently authenticated,
non-persisting bootstrap and a wireless route decision before T083/T084/T036 production work.
Clipboard, screenshot and iOS VM memory acceptance remain open.

## Replacement public bootstrap + mutual TLS 1.3 — 19:43–19:44

The external-PSK candidate failed a real local matching-key handshake (-9816). Apple TN3213
documents that this Network PSK path does not support TLS 1.3. It was rejected without downgrading
TLS. See [the revised contract](../contracts/ios-runner-channel.md) for primary sources and trust model.

Implemented an experimental shared Swift package, not yet a production content dependency:
`packages/DeviceBridgeSecureChannel`. Apple swift-certificates 1.20.0 generates short-lived P256
certificates; resolved transitive versions are swift-asn1 1.7.2 and swift-crypto 4.5.2. Private keys
are converted in memory using X9.63 into SecKey and SecIdentityCreate; no SecItemAdd, private-key file,
Keychain import or developer certificate issuance. Certificate dates alone do not enforce channel
expiry: the experiment separately owns a hard 90-second deadline.

Local red/green evidence: identity and bootstrap tests first failed against throwing stubs, then
passed. The real Network pair verifies both endpoints negotiated TLS 1.3 and completed echo.
Wrong server/client and missing client certificates produce explicit certificate-authentication
errors; missing/wrong client cannot make the server ready. Independent review identified an initial
test weakness (all network failures counted as rejection); it was corrected before accepting results.
Timeouts, infrastructure and unrelated TLS failures now fail negative tests. Six Swift Testing
tests pass (one has three parameterized authentication cases). They are not physical phone tests.

Physical run:

- Reused the existing personal development identity/profile for incremental Debug build; exit 0,
  no provisioning-update flag, no Mac UI control. Phone: same paired wired iPhone 12/iOS 18.3.1.
- Selected only `RunnerSmokeTests.testSecureUSBIdentityProbe`. The phone presses Home before
  launching a single loopback TLS listener; system/user attachments use `keepNever`.
- Host creates fresh launch ID and in-memory identity. Only its public certificate and launch ID
  enter XCTest environment. The runner publishes only a bounded public certificate record into its
  own appDataContainer. CoreDevice copies the exact launch UUID path from the captured UDID and exact
  `dev.debugutility.DeviceBridgeRunnerUITests.xctrunner` bundle namespace. Host validates launch,
  host certificate digest, build, schema and certificate before pinning; no stdout runner pinning.
- Host loopback proxy relays only TLS ciphertext to the exact USB route. Both peers require client/
  server authentication and exact leaf DER pins; TLS 1.3 only, no tickets/resumption/early data.
- **31 correlated fixed-size identity-only exchanges passed** on one TLS connection. The protocol
  exposes no clipboard, screenshot, photo, file or real session nonce command.
- Physical XCTest: **1 passed, 0 skipped**, command exit 0. Exact USB inventory remains, test port
  refuses new connections after completion. Secure idle lease/parent death/restart/cable handling
  are NOT yet qualified by this short exchange.
- A fresh public marker generated in host memory after bootstrap was absent from the captured
  ciphertext, public record, authored xctestrun, xcodebuild stdout and exported xcresult action log.
  Console/build exports unavailable: no claim for those or uninspected system diagnostics. Unlike
  the rejected environment bootstrap, this marker never enters a launch environment or argv.

Local diagnostics (Xcode device/signing metadata; redact before sharing):
`/var/folders/mm/y7mmzv7x2ps17jls3gh616p00000gn/T/devicebridge-mtls-spike-x7aew3jq`.
Reproduction: `scripts/ios-channel-spike/run_secure_physical_probe.py` with refreshed details,
exact signed products and the package's Debug `DeviceBridgeTLSProbe` executable.

Disposition: secure USB bootstrap is feasible on the reference phone. Finish adversarial secure
lifecycle/latency evidence and an explicit wireless disposition before closing T082. No production
provider/readiness was enabled; T083/T084/T036 and clipboard/screenshot/VM acceptance remain open.

### Secure lifetime/restart follow-up — 19:49–19:52

Four consecutive new personally signed launches passed, each with an exact USB route, fresh
mutual certificate pins, 1 executed passing physical XCTest (0 skipped), and final port refusal.
The public marker was absent from the ciphertext, bootstrap file, xctestrun, stdout and successfully
exported action log in every run. Console/build logs remained unavailable. No content APIs ran.

| Mode | Correlated replies | Observed duration | RTT median / max | Runner terminal result |
|------|--------------------|-------------------|------------------|------------------------|
| Heartbeat | 31, with eight 5-second delays | 42.63 s | 0.41 / 9.33 ms | tls13-31-exchanges |
| Orphan | 30, then no complete frame | 30.04 s | 0.67 / 5.31 ms | leaseExpired |
| Invalid | 30, then invalid fixed frame | 0.03 s | 0.49 / 5.84 ms | invalidFrame |
| Disconnect | 30, then host closes | 0.04 s | 0.57 / 6.38 ms | peerClosed |

These observed durations are not yet assertions in those historical runs. Independent review
required stronger gates: action log must be readable, orphan/partial expiry must occur 28–35 seconds
after the last valid reply, and heartbeat must remain connected 38–60 seconds. Those checks were
added; their strict physical reruns are recorded separately below when complete.

Local diagnostics, respectively: temporary directories `devicebridge-mtls-spike-fefhop9b`,
`devicebridge-mtls-spike-hva95xbt`, `devicebridge-mtls-spike-e4wg0t5z`, and
`devicebridge-mtls-spike-_2p763eb` under the same system temporary root shown above.

The implementation now has an explicit 30-second valid-frame lease, 60-second accept deadline,
10-second handshake deadline, and nominal 90-second experiment deadline. The deadline runs on the
network owner's queue and is not a guarantee against blocked OS/filesystem I/O; external child
wait/termination bounds remain necessary. Public record removal failure maps to a failing outcome,
not a silent success. A read-only container inspection after the first secure run found zero records.

Additional local real-TLS tests assert 0.2-second orphan and partial-frame expiry within tolerance,
and continued 50-ms renewals cannot extend a 0.5-second total experiment deadline. These are scaled
local tests, not proof of a 90-second physical limit or cable/locked-screen recovery.

### Strict timing and required action-log reruns — 20:02–20:05

The current harness now requires a readable action log plus the timing windows described above.

| Mode | Connected / last-reply-to-close | Replies | RTT median / max | Result |
|------|--------------------------------|---------|------------------|--------|
| Heartbeat | 42.674 s connected | 31 | 0.39 / 3.53 ms | 1 physical pass, 0 skipped |
| Orphan | 30.008 s since last valid reply | 30 | 0.78 / 5.84 ms | 1 physical pass, 0 skipped |
| Partial frame | 30.008 s since last valid reply | 30 | 0.44 / 3.92 ms | 1 physical pass, 0 skipped |

All three required action-log audits succeeded with no marker found, as did the other inspected
surfaces. Exact USB listener ports were closed. Diagnostics: `devicebridge-mtls-spike-obggd8tx`,
`devicebridge-mtls-spike-epl5ren3`, `devicebridge-mtls-spike-zuvw_m18` under the temporary root above.

**Unresolved intermittent teardown failure:** two earlier strict heartbeat attempts completed all
31 authenticated replies (one recorded 42.616 s connected) but failed the relay termination check.
They are failed experiments, not passing XCTest/audit evidence. At that point the harness did not
capture relay error types; it now records them. No relay failure was ignored or normalized, and
the later passing rerun does not establish a fix. Failed directories: `devicebridge-mtls-spike-18jf75t2`
and `devicebridge-mtls-spike-gxfxt6oe`. A subsequent normal run (`devicebridge-mtls-spike-ezso_4om`)
also passed the unchanged relay checks.

Independent review identifies a plausible but unconfirmed race: both Swift peers immediately cancel
after the last reply while the proxy may still forward TLS shutdown bytes to an already closed peer.
The current proxy returns on either direction's EOF rather than draining both directions. Preserve
strict failure and instrument operation/direction/errno before claiming the failure's cause. Production
T083/T084 must implement bounded, verified stream teardown; successful content delivery alone is not
enough. Apple's [write-close API](https://developer.apple.com/documentation/network/nwconnection/send%28content%3Acontentcontext%3Aiscomplete%3Acompletion%3A%29-3mfmt)
documents final-message half-close, but it has not yet replaced the experimental immediate cancellation.

USB-candidate GO authorizes continued T083 fixture/launcher implementation, **not production readiness**.
The iproxy wireless candidate remains NO-GO under the no-LAN-listener contract; overall T082 remains
open. Actual nonce handling, artifact/install identity binding, stale-copy/cancellation isolation,
complete teardown, content dispatch/permissions and workspace readiness are still required.

### T083 signed-artifact preflight and fresh-build control — 20:36–20:43

The local signature checker uses public Security APIs with strict nested/resource/all-architecture
validation, expiration consideration, no network access, and an external Apple-anchor + captured
Team + fixed role identifier requirement. No certificate or provisioning update was requested.

The older `/tmp/devicebridge-personal-runner-debug` Runner wrapper failed both this checker and
`codesign --verify --deep --strict` with `errSecCSBadResource` (-67054). The nested XCTest bundle and
Host still passed. `SecStaticCodeCheckValidityWithErrors` identified the nested test binary and its
two dSYM resources as changed. A no-op incremental build returned success without any CodeSign step
and did not fix the seal. The exact earlier mutation step is unproven; do not blame test execution
or suppress resource validation based on this evidence alone.

A fresh Debug control built in `devicebridge-signature-control-devz1fb3` under the same temporary
root passed strict verification of all three roles. Real local signature tests rejected a different
Team, wrong role and a deliberately modified copy of Host's Info.plist; the original remained valid.
These tests only copy/modify their unique temporary fixtures, never the signed source apps.

The fresh control then ran on the designated wired iPhone: 31 correlated TLS 1.3 identity replies,
RTT median 0.47 ms / maximum 6.45 ms, 1 passing physical XCTest / 0 skipped, final USB port refusal.
Required action-log and other available marker scans passed; console/build exports remained
unavailable. Runner's strict outer signature also passed **after** the phone run. Diagnostics:
`devicebridge-mtls-spike-d0213yz3`. No clipboard, screenshot, photo or VM action ran.

Per-attempt products now carry the same Team used by the manager build. The existing 11 manager
lifecycle tests plus 3 configuration tests pass after this handoff change. The new signed-artifact
loader is still preflight support: T083's concrete install/start/process/proxy owner is unfinished.
T082/T083/T084/T036 and the feature acceptance gates remain open.

### Native signed startup and process ownership — 20:46–20:51

Six real local process tests cover immediate exit/spawn failure, TERM-ignoring deadline escalation,
independent attempts, rejection of pre-cancelled startup, cleanup of a remaining child after leader
exit, and a cancelled exit observer followed by explicit stop. Independent read-only review found no
blocking unrelated-process kill path under exclusive reaper ownership; the leader-only grace limit
is now explicit in code and contract. This is not a parent-death or kernel-stall guarantee.

Full default Core run before adding the new opt-in physical-startup test: 199 test functions across
39 suites reported success, with 11 explicitly skipped physical/signing gates. Separately, all four
enabled local signature/artifact tests passed against the fresh personal-signed control.

The new opt-in `exactSignedProductsStartOnOptedInPhysicalPhone` composes the actual signed-artifact
loader, exact rewritten `.xctestrun`, and native process owner. It copies only the signed app products
into its own launch directory, selects one phone-only managed-host startup test, passes no inherited
TEST_RUNNER secrets or provisioning flags, and requires xcresult to contain 1 pass/0 failures/0 skips.
It passed on the designated iPhone in 12.238 seconds, including successful post-run signature checks.
Its generated configuration, copied app fixtures and result metadata were removed from the unique
test directory afterward; the original signed build and earlier diagnostics remain intact.

This qualifies these components' real signed-startup composition, not the unfinished full launcher,
authenticated production dispatcher, workspace readiness, clipboard, screenshot or memory feature.

### Launcher orchestration fixtures — 20:58–21:04

`IOSRunnerLauncher` now composes real default artifact loading/native process startup with a required
channel factory (no unauthenticated default). Eleven fixture test functions, including parameterized
cases, pass: exact products/public-only environment, rejected artifacts, stop during validation,
late open after stop, timeout cleanup, early child exit, caller cancellation, duplicate launch,
cleanup retry, pre-existing directory/symlink preservation and blocked validation timeout/cancellation.
The actual managed-channel XCTest entry and authenticated factory are not yet implemented, so this
is not a full production launcher or content-feature qualification.

Independent review's blocked-validation concern was reproduced: a suspended loader initially held
startup past cancellation/timeout. A result owner now bounds the wait without accepting late data;
the abandoned work is read-only and may still finish later. A real fixture permission change also
reproduced lost cleanup ownership; stopping attempts now remain retryable after removal failure.

The review's existing-directory overwrite hypothesis was **not reproduced** on this host: both
directory and directory-symlink preservation tests already passed against Foundation's original
`withIntermediateDirectories: false` call. POSIX exclusive `mkdir` now states ownership explicitly,
but this change is not evidence of a reproduced overwrite defect in the prior implementation.

### Native USB relay and terminal ordering — 21:28–21:34

The native exact-USB implementation now has 18 local socket test functions (32 parameterized cases),
including independent read/write readiness, bounded cancellation, descriptor reuse protection and
both TCP half-close directions. Launcher coverage now has 13 functions, adding same-phone/new-launch
late cleanup isolation and concurrent child stop when channel cleanup is slow.

The loopback relay reproduced an ordering defect locally: complete payload and both peer EOF checks
passed, but a separately scheduled Network state failure (POSIX 50) reached the actor before the USB
write-close barrier finished. The fix does **not** normalize that error to success: before pumping,
state failure remains fatal; afterward it is retained and starts a single bounded drain deadline.
Actual I/O errors remain fatal and clean completion requires both error-free EOF → opposite write-close
barriers. This was independently reviewed. Clean means completed relay operations, not a TLS or
application-level delivery acknowledgement. It does not establish the old Python relay's failure cause.

Seven relay functions (eight cases) pass 20 consecutive full filtered runs: both half-close orders,
absent client timeout, reset during receive, reset with a 16 MiB reply undrained, unmatched half-close
timeout, unused close and cancellation during drain. The complete Core suite at this checkpoint
reported 238 tests in 42 suites passing (12 opt-in tests skipped); these are not physical test counts.

The new contributor-only `NativeUSBProbe` executable composes the same production USB/loopback
primitives, supplying the exact device identifier over stdin and emitting no forwarded bytes. The
existing signed reference build was reused without rebuilding, changing signing or portal access:

- `devicebridge-mtls-spike-8uipkmk3`: normal, 31 TLS 1.3 correlated replies, connected 0.033 s,
  median 0.70 ms / max 10.79 ms, native relay `clean`.
- `devicebridge-mtls-spike-a3l01zv1`: heartbeat, 31 replies, connected 42.642 s,
  median 0.57 ms / max 7.22 ms, native relay `clean`.

Each physical run contains 1 XCTest pass / 0 skips and ends with the exact USB listener refusing a
connection. The public canary was absent from the copied public record, generated xctestrun, stdout
and required xcresult action log. Console/build log exports were unavailable. Native forwarded bytes
are intentionally not captured: its ciphertext audit is `notCapturedNative`, **not a false/pass value**.
Earlier Python ciphertext inspection remains separate evidence. No clipboard/screenshot/VM data was
requested and no desktop UI was controlled. Production factory/dispatcher, content and Wi-Fi remain
unqualified; T082/T083/T084/T036 stay open.

### Native copy and orphan boundary follow-up — 21:40

`IOSRunnerPublicRecordReader` now addresses only the captured UDID, fixed runner appDataContainer
and exact launch UUID path. It creates an exclusive mode-0700 temporary directory, rejects symlinks,
nonregular/empty/over-8192-byte files using descriptor checks and bounded reads, and removes only its
own directory on success/failure/cancel. It returns raw public data, not a verified pin or readiness;
the candidate must still validate the record and recheck live launch/child ownership after awaiting.

Independent review found that using the older TERM-only `HostCommandRunner` would allow a child to
hold this copy open. The default now uses `IOSRunnerProcess` and discards stdout/stderr entirely.
Five reader test functions pass, including a real TERM-ignoring shell/descendant fixture with native
escalation and directory cleanup. The configured 8-second copy deadline plus process-owner grace
does not promise a hard bound for kernel-uninterruptible execution.

Native orphan run `devicebridge-mtls-spike-yzmjgl27` matched the reader's real exact-container copy
against the harness control and exchanged 30 authenticated public replies. Client observed closure
30.011 seconds after the last reply, but native relay reported `usbToHost` failure. The run **failed**;
the harness stopped before completing XCTest/audit/port checks, so no full physical pass is claimed.
The 30-second USB read deadline racing the 30-second phone lease is a hypothesis, not yet a confirmed
cause. Typed non-content failure instrumentation is the next discriminating check.

### Confirmed timeout layering and remaining abrupt-close failure — 21:43–21:49

`devicebridge-mtls-spike-w_fhtcu9` reported `usbRead(.timedOut)` at the 30-second boundary. That
confirms the native read timeout was racing the phone's 30-second idle lease. The relay now permits
35 seconds of USB read inactivity (phone lease unchanged); only `readChunk` accepts a finite maximum
of 60 seconds. Other USB operations retain their 30-second maximum. The new 35-second-argument test
failed with `invalidInput` before the change and passes afterward. A scaled local peer-lease test
distinguishes too-short read deadlines (typed timeout) from deadlines that allow both clean EOFs.
No timeout or write error is normalized to success.

After that change, `devicebridge-mtls-spike-ig_cb5rb` still failed the relay gate on the write direction.
The instrumented `devicebridge-mtls-spike-1hjhs0fq` isolated `usbWrite(.unavailable)` after receiving
30 authenticated replies and host closure at 30.008 seconds. Unlike earlier failed runs, the harness
then collected independent evidence before retaining its overall failure: phone XCTest 1 pass/0 skips
with expected `leaseExpired`, exact USB listener refused, public marker absent from public record,
generated configuration, stdout and required action log. Native ciphertext remains uncaptured.

This supports bounded fail-closed orphan expiry, not graceful bilateral TLS closure. The experimental
TLS probe maps EOF/errors/short frames to `peerClosed` and its `finish` immediately cancels the
connection without awaiting peer shutdown. The new actual write error is preserved. Independent
review permits further bootstrap/identity-only implementation behind existing readiness gates but
rejects claiming graceful orphan qualification. A future short-lease local TLS-through-native-proxy
comparison of abrupt cancellation versus explicit bounded graceful closure is the discriminating
next teardown test; earlier Python relay failure causes remain unproven.

The copy-process escalation fixture was strengthened: the first 80 ms fixture could terminate before
its TERM trap was installed, so it did not prove escalation. The final fixture writes a readiness
marker after installing the trap and uses a 1-second deadline plus the native 2-second grace. It
passed in 3.030 seconds with the marker present, rather than accepting an early exit as evidence.

### Shared protocol and pinned USB endpoint — 21:52–22:00

Wire models, validation and framing now have one implementation in the Foundation-only
`DeviceBridgeProtocol` package (iOS 17/macOS 14). Existing Core consumers import it explicitly;
`ClipboardService.maximumUTF8Bytes` remains an alias of the authoritative shared limit. There are no
duplicate wire types or re-export shims. The original 35 targeted Core tests passed before and after
extraction, three standalone package tests passed, and the shared source typechecked for the iOS 17
simulator. App package references and contributor link scripts were adjusted; no Mac app was built,
restarted or controlled. Core's later secure-bootstrap dependency uses the same pinned certificates,
ASN1 and Crypto versions as the existing secure package, not a dependency upgrade.

`IOSRunnerUSBEndpoint` now owns one immutable launch's public copy, record validation, exact USB
connection and loopback proxy. Only a current opening attempt with a live child can commit a pinned
endpoint; every copy/connect/listen suspension is followed by ownership checks, and stale returned
resources are closed. Stop/cancellation/deadline resolves the waiting open without accepting abandoned
read-only copy results. Five endpoint functions (nine cases) pass with real local USB fixtures and
ephemeral public certificates: valid path, wrong launch/host/build/schema, child exit during copy,
late copy after close, timeout and caller cancellation. This endpoint is not TLS, nonce authentication,
content readiness or an end-to-end signed managed-channel launch.

The complete Core checkpoint before endpoint addition reported 245 tests in 44 suites passing,
including explicit opt-in skips. Final combined regression is still required after the shared TLS
frame transport and contributor static-link checks finish. T082/T083/T084/T036 remain open.

### Endpoint resource review and contributor check linkage — 22:03–22:08

Independent review found that an already acquired USB connection/proxy was not registered with the
endpoint owner until after the next asynchronous child-liveness check. A gated real local socket
test reproduced the defect: close returned but the mux peer did not receive EOF while that check
was suspended. The endpoint now synchronously checks its phase and immediately registers each new
resource before that external await; late acquisitions after invalidation are still closed locally.
It also rechecks `.ready` when the successful continuation resumes, before returning the endpoint.
Six endpoint functions now pass, including the newly discriminating close-during-child-check case.

The new secure dependency made old hand-written check-script object lists incomplete. A separate
`DeviceBridgeCoreChecks` static product leaves the app's existing automatic product unchanged and
lets SwiftPM collect all transitive production objects. The archive contains 12 production targets,
including the C crypto shims and no test targets. One compile helper reuses Core's exact Clang module
arguments from generated build metadata; it does not maintain dependency-name lists or execute a
probe itself. Four synthetic helper tests and syntax checks for all five migrated scripts passed.
Only `check-workspace-modules.sh` was executed: its prohibited-activation, in-process layout and input
identity checks compiled/linked and passed. No window, device probe or app restart was involved.

### Combined frame/endpoint regression and next identity gate — 22:12–22:26

`PinnedTLSFrameStream` now has a single authoritative absolute lifecycle deadline. Listener-ready
and incoming-connection callbacks cannot replace an already expired startup/accept deadline merely
because its timer callback has not run yet. Deterministic exact/after-expiry regressions failed before
the guard and passed afterwards. `close()` explicitly promises logical invalidation and submitting
Network cancellation, not physical descriptor release or graceful TLS shutdown.

Root reran the combined packages: Core 251 tests / 45 suites passed (physical opt-ins remain skipped),
SecureChannel 24 tests / 5 suites passed. The headless module layout/input-retention check also passed
using the complete static archive. These counts precede the new application-identity handshake tests.

The next bounded slice is the actual launch/nonce/challenge/build/capability handshake over this
frame stream. Local pure validation and a real mutually pinned TLS pair passed their initial checks;
independent review identified a missing request-expiry recheck after writing the runner reply and
the existing JSON codec's whole-second timestamp precision. Those findings are being addressed
before the new identity-only physical run. No production channel factory, content dispatcher or
workspace readiness is enabled by these partial results. T082/T083/T084/T036 remain open.

### Actual nonce/challenge handshake on the designated iPhone — 22:28–22:34

Both review findings were reproduced before their fixes: fractional timestamps differed after the
existing ISO8601 wire round-trip, and a real TLS test with a scripted wall clock accepted a runner
session when its reply write crossed request expiry. The final implementation floors host wire
timestamps, accepts whole-second host timeouts in 2...30 and derives the single monotonic deadline
from that same expiry. Runner validates the retained request again after writing. All seven identity
test functions passed, including malformed binding/capability cases and both discriminating timing
regressions. Independent read-only re-review confirmed the two specific counterexamples are closed.

`IOSRunnerHandshakeProbe` and CLI mode `identity` exercise this actual handshake, followed by one
nonce/launch/helper-bound Stop. The probe advertises only identity/stop and has no UIKit/content
dispatcher. A freshly generated Stop request UUID is an intentionally public audit marker; the real
nonce/challenge never leave the Swift TLS processes via output or launch metadata. Probe cleanup
compares bounded public-record bytes before deletion, preserving a detected replacement. This is
not atomic compare-and-unlink against a concurrent writer in the trusted container. Local tests
cover two exchanges, invalid Stop/request replies, cancellation, replacement preservation and CLI
schemas. Root reran SecureChannel: **36 tests / 7 suites passed**, exit 0.

An incremental `build-for-testing` of the iOS Debug runner used the same existing personal Team and
cached profile, without `-allowProvisioningUpdates`, device registration or new certificate issuance.
All three rebuilt signed roles passed `codesign --verify --deep --strict` before the physical run.
No Mac app build/restart, desktop UI test, input takeover or permission approval occurred.

Physical diagnostics: `devicebridge-mtls-spike-mmbwr0kr`. The designated paired wired iPhone executed
`testSecureUSBManagedIdentityProbe`: **1 passed / 0 skipped**. Native exact-container copy matched
the control, mutual TLS plus the actual identity and Stop exchanges returned
`identity-2-exchanges`, two RTT samples had median **5.97 ms** / maximum **10.79 ms**, and connected
exchange time was **0.012 seconds**. Native relay reported `clean`; reconnecting the exact USB port
after completion was refused. This short run does not qualify long-term lease/uptime behavior.

The public Stop UUID was absent from the public record, authored xctestrun, captured stdout and
required xcresult action log. Console/build log exports were unavailable, and native ciphertext was
not captured; those surfaces are not claimed inspected. The marker audit is evidence for this
execution path, not a proof of all possible system diagnostics or a dump/search of real secrets.

This closes the bounded actual-nonce physical experiment, **not** the overall T082/T083/T084/T036
tasks. The concrete signed-launcher-to-handshake factory, managed entry/lease/content dispatcher,
binary screenshot attachments and Workspace readiness integration still remain. The three requested
iOS content/VM features must not be reported usable from this identity-only pass. Wireless remains
separately unresolved under the loopback-only contract.

Post-physical strict signature verification still passed for all three signed roles. The final
Core regression after the new shared handshake compiled in reported 251 tests / 45 suites passing,
with 12 explicitly opted-out physical/tool cases; these skips are not additional device passes.

### Formal native metadata channel and signed-launcher run — 22:35–22:55

`IOSRunnerChannelFactory` now creates a fresh in-memory host identity and exact-container/USB
endpoint per attempt. `IOSRunnerChannel` owns its opening task, TLS stream and cached authenticated
context in one actor. It commits only after authenticated handshake and a live-child check, owns
the stream before subsequent awaits, and invalidates before cleanup. Its current send path is
strictly serialized identity/stop. The existing generic authenticator's `verifyExisting` consumes
that context without generating a new nonce; Workspace has not yet been wired to this path.

Seven channel test functions cover distinct attempt pins, cross-launch rejection, persistent
identity/Stop, close during route acquisition, caller cancellation, close during a gated final
child-liveness check, five bad reply variants and concurrent/cancelled in-flight replies. The initial
successful-channel/close tests failed against the stub before implementation. Review-driven extra
regressions passed against the completed guards. No response can revive a closed context. A cached
context is not an instantaneous liveness check; a non-cooperative injected child observer can delay
the original open task even after close has reclaimed resources.

The shared server handles only identity/stop, a 30-second default lease and a bounded non-evicting
replay ledger including the bootstrap ID. The first lifetime API used a relative duration; independent
review found that the phone-entry handoff could re-anchor it after an executor delay. A fix to pass
the same absolute deadline is in progress and must be revalidated before this lifecycle is qualified.
The bounded metadata stage still does not supply permission-blocked content/heartbeat concurrency.

The formal phone `testManagedChannel` now exists and is directly selected by `IOSRunnerLauncher`.
Only public launch/certificate/maximum-duration metadata enters its environment. It creates its own
ephemeral identity, binds loopback, publishes via an exclusive staging file plus atomic no-replace
rename, then runs the metadata server. Cleanup checks a non-symlink regular file's size and own
public bytes; it does not claim adversarial atomic compare-and-unlink in the trusted container.

The new opt-in `IOSRunnerManagedPhysicalTests` uses the actual native launcher, signature loader,
public copy process, exact USB/proxy, TLS and channel factory, with only an owned xcresult path added
to the native process request for evidence. The personal-signed iPhone run passed in **47.318 s**:
five authenticated identity probes over at least **40 seconds**, then a bound Stop; the phone result
contained **1 passed / 0 failed / 0 skipped**, the child exited zero, and launcher cleanup completed.
The actual nonce and public Stop UUID were absent from the required action log (checked in memory
without rendering either). This is not an audit of unavailable/other system logs. The exact USB
listener subsequently refused connections and all three reference signatures remained valid.
The fixture's copied products/result bundle were removed from its own unique temporary directory;
the original signed reference products were not modified by the test.

Regression evidence: targeted channel/launcher/opt-in tests passed (physical test explicitly skipped
without its opt-in environment). One default concurrent full Core run failed the existing synthetic
copy-process escalation fixture: its readiness marker was absent and it exited after ~1.02 seconds,
before demonstrating the intended TERM-ignore/KILL path. No production code was changed to mask
this. The fixture alone passed in 3.031 seconds; an explicit `--no-parallel` full Core run passed
**259 tests / 47 suites in 8.368 seconds**, including 13 opt-in skips. These observations indicate
a startup-scheduling-sensitive fixture, not a proven new channel cleanup defect; the default
concurrent-run flake remains recorded, not erased by the serial pass.

### Absolute lifetime handoff and repeated physical qualification — 22:56–23:02

The formal phone entry now retains its absolute-deadline timer through unified cleanup and passes
that exact `ContinuousClock.Instant` to the sole `IOSRunnerSessionServer.run` API. The server does
not convert it back into a duration/re-anchor it. A deadline already elapsed before dispatch closes
the stream and returns `lifetimeExpired` without starting identity. The deterministic queue-delay
counterexample and past-entry case failed before the change and passed afterwards. This also keeps
an entry-timer closure classifiable against the same server deadline, rather than hiding an arbitrary
transport failure as expiry. Root reviewed the direct deadline wiring.

Final checks after this correction:

- SecureChannel: **49 tests / 8 suites passed** (root rerun, 1.136 s).
- Core, explicit `--no-parallel`: **259 tests / 47 suites passed** (8.344 s, 13 opt-in skips).
- Incremental personal-signed iOS Debug `build-for-testing`: passed; no provisioning updates or
  certificate issuance, and all three products passed strict signature checks before the run.
- Actual native launcher/factory/copy/USB/TLS path repeated on the designated iPhone:
  **47.339 s**, five probes spanning at least **40 seconds**, correlated Stop, child exit zero;
  phone xcresult **1 passed / 0 failed / 0 skipped**, no actual nonce or public Stop UUID found in
  the required action log, owned launcher cleanup completed. Exact USB listener then refused.
- Two isolated fixture tests also executed **on the iPhone** using the same signed Debug products:
  invalid lifetime policy bounds and no-overwrite/no-wrong-record-delete publication. Phone result
  **2 passed / 0 failed / 0 skipped**; diagnostics retained in `devicebridge-managed-fixtures-xofz_301`.
  These two tests contain no Home, clipboard, screenshot or network action. Their code was supplied
  test-first with the entry implementation but was not run as a red device test before implementation;
  do not describe that physical fixture run as an observed red-to-green cycle.

T083 is now complete for the selected personal-signed USB backend under the documented trusted
Xcode/signing/container assumptions. Overall T082 remains open for its remaining adversarial/lifecycle
and wireless disposition, and T084/T036 remain open for content dispatch, permission/heartbeat
concurrency, binary screenshots and Workspace integration. Neither this task checkbox nor the
metadata-only physical tests claim the user's clipboard/screenshot/VM features are usable yet.

### Next content gate: clipboard foreground and permission evidence

Load these notes when implementing T084/T041's actual iPhone clipboard path. Read-only upstream
research identified why the current `SystemClipboardAccessor` cannot be assumed usable while the
runner is Home/background: Appium's official guide requires the real WDA Runner foreground for
physical-device clipboard reads (iOS 13+) and writes (iOS 15+). Activating the ordinary Host app is
not proof that the `.xctrunner` process is foreground. This is upstream guidance, not yet a measured
restriction on this designated phone. [Appium clipboard guide](https://appium.github.io/appium-xcuitest-driver/11.12/guides/clipboard/)

WDA pinned revision `6f8c0d19b6027ef4a2fa6a5a5e176d8182439323` reads all `strings` and joins with
newlines, but its iOS 16+ getter path also dispatches work off-thread and automatically accepts
system alerts. Do **not** copy automatic permission approval. Apple documents user-intent approval
for cross-app programmatic pasteboard reads. The current Swift accessor's setter has no error
return, so its immediate `.success` is not evidence the system value changed; `nil` reads also do
not distinguish empty, denied and background-unavailable states.
[WDA source](https://github.com/appium/WebDriverAgent/blob/6f8c0d19b6027ef4a2fa6a5a5e176d8182439323/WebDriverAgentLib/Utilities/FBPasteboard.m),
[Apple privacy session](https://developer.apple.com/videos/play/wwdc2022/10096/)

Next validation should determine whether public `XCUIApplication(bundleIdentifier:).activate()` can
foreground the exact already-running runner, without restarting it or using private active-app
discovery. Preserve all text items and the explicit 1 MiB refusal; never truncate. Keep network
heartbeat/stop independent of a permission-blocked UIKit call, and preserve the prior clipboard
before any synthetic write. A required phone permission must be user-controlled. No foreground
activation or real clipboard read/write has been performed as part of the metadata qualification.

### Clipboard foreground characterization (physical, after T083)

The selected paired USB iPhone ran `testPhysicalRunnerForegroundRoundTrip` using the existing
personal-signed incremental Debug products: **1 passed, 0 failed, 0 skipped**, native child exit 0.
The test checks that it executes inside the exact `.xctrunner`, goes Home, observes the existing
runner in background, calls public `activate()`, observes foreground with the same process ID,
then returns Home/background. This establishes the foreground prerequisite on this phone; it
does not prove clipboard access or restoration of an arbitrary previously active app.

Diagnostics: `devicebridge-foreground-probe-c2vjnp_6/result.xcresult` in the owned macOS temporary
directory. Strict signatures of Host, Runner and nested tests were checked before execution.
Attachment lifetimes remained `keepNever`. No clipboard/screen/photo content API, Mac UI action,
paste approval, developer account or provisioning update was used in this test.

The installed iPhoneOS SDK `UIPasteboard.h` declares `UIPasteboard` `NS_SWIFT_SENDABLE` and does
not annotate its class as main-actor-only. The iOS Swift 6 compiler accepts a dedicated actor's
pasteboard access. This permits serializing OS clipboard I/O separately from the UI/main actor;
it is not a claim that an uncooperative OS getter can be forcibly cancelled. Content dispatch
must invalidate and discard late results without joining that getter during Stop/lease expiry.

### Optional clipboard dispatcher — local TLS and physical access prerequisites

The session server now has an optional `IOSRunnerClipboardHandling` boundary. Without an adapter
it still advertises metadata only, as used by the current production phone entry. With an adapter,
one content operation can wait while authenticated identity/Stop is processed over the same stream.
One run task owns admission/replay IDs/deadlines/result writes; read/content/expiry producers use a
four-slot bounded inbox. Clipboard payloads stay in memory and have the existing 1 MiB bound.
Screenshot/binary attachments are not implemented by this slice.

26 session-server tests passed, including real pinned TLS, blocked/uncooperative content,
identity/Stop responsiveness, no join on handler return, late results, replay while in-flight,
malformed payload/result rejection, read/write limits, permission denial mapping, content expiry
despite heartbeats, completed-content stale timer rejection and host clock skew. Test-first review
also fixed terminal ordering: Stop cancels content at admission, and errors cancel it before waiting
for stream cleanup. Read cancellation stays after Stop acknowledgement. Cancellation callbacks
must not block; this is an explicit adapter contract, not a guarantee against arbitrary hostile
callback code. Root independently reviewed ownership and reran the full package:
**62 tests / 8 suites passed in 9.682 s**, `/tmp/devicebridge-content-session-reviewed-full.log`.
Core regression also passed **259 tests / 47 suites in 8.343 s**, with 13 existing opt-in skips,
using explicit `--no-parallel`: `/tmp/devicebridge-content-core-regression.log`. This does not
reclassify an opt-in skip as device acceptance.

Preserved regression evidence: the preceding full run failed legacy `TLSIdentityProbeTests`
`.sustain` terminal classification (`connectionRejected` vs `peerClosed`); standalone rerun failed
a different `.disconnect` case with missing public record. Ten subsequent isolated runs and the
final full run passed, but **these legacy flakes are not fixed**. The sustained case had completed
at least two authenticated exchanges and server deadline expiry; competing NW `.failed`/receive
termination callbacks are classified differently by the old diagnostic. Missing-record root cause
is not established (publication/port/scheduling remains to distinguish). Do not raise timeouts or
call a transport failure clean EOF. Original failures remain in
`/tmp/devicebridge-content-session-full.log` and
`/tmp/devicebridge-content-legacy-lifecycle-recheck.log`.

Physical access prerequisite is now measured: a real read under async XCTest activation passed but
took 84.876 s due to XCTest idle/animation waits, so that activation path is unsuitable for the
30-second content budget. Public host-side CoreDevice activation without terminating the existing
runner then passed an unchanged-PID foreground + real pasteboard read + Home test in **1.365 s**;
the activation command itself took **0.240 s**. See [clipboard evidence](us2-clipboard.md).
No general pasteboard writes, private clipboard logs, automatic paste approval, or encrypted content
round-trip occurred. Next work is Core host request correlation/serialized writes plus this verified
activation boundary, the actual iOS clipboard adapter, then T036 UI integration. T084/T041 remain
open; screenshot/VM work and permission-wait extension are still unqualified.

## 2026-09-08 — production encrypted clipboard READ qualified on selected USB

Supersedes the preceding no-content status for this narrow read-only slice. The actual
`IOSRunnerChannelFactory`/native launcher, signed `testManagedChannel` with `RunnerClipboardHandler`,
and real general UIPasteboard completed a correlated encrypted READ, five metadata exchanges over
40 seconds, Stop, native child exit zero and owned cleanup in **48.982 s**. The opt-in host test also
checked phone xcresult 1 pass/0 skips, nonce/Stop-ID absence in its action log and strict signatures
on all three source bundle roles. Evidence: `devicebridge-encrypted-read-v92l5xx0/test.log` in the
owned macOS temporary area. No clipboard text/count/hash or foreign error description was logged.

Two real integration failures were preserved and fixed: CoreDevice rejects decimal timeout strings
even though fake command executors accepted them; and command exit precedes visible foreground.
Integer command timeout plus the original native absolute deadline fixed the first; bounded,
cancellation-aware foreground settlement before access fixed the second. Exact red/green paths
and limitations are in [US2 validation](us2-clipboard.md).

Host channel: 13 methods pass, including Stop preempting an unsent request without retaining its
obsolete timer, and awaited close invalidating uncooperative foreground preparation. Activator:
11 methods pass, including fresh deadline checks immediately before native spawn. iPhone clipboard
fixtures: 22 pass/0 skips, with the two settlement regressions failing first. Root integration
regression: **276 tests / 48 suites pass in 9.532 s** (existing physical opt-ins skipped),
`/tmp/devicebridge-encrypted-read-core-regression.log`; SecureChannel **62 tests / 8 suites pass in
8.804 s**, `/tmp/devicebridge-encrypted-read-secure-regression.log`. Prior legacy diagnostic flakes
remain recorded and are not claimed fixed.

General clipboard writes/restoration, user permission waiting/denial, screenshot binary attachments,
wireless, VM memory and Mac workspace readiness remain unqualified. T084/T036/T041 are still open.
No signing-account mutation, Release packaging or Mac UI takeover was performed.

## 2026-09-08 — production encrypted screenshot qualified on selected USB

The actual signed runner now also serves `RunnerScreenshotHandler`. The production channel stages
request-bound binary PNG chunks in a private receipt directory, validates exact length/SHA-256,
PNG CRC/IEND and ImageIO decoding, and removes its partial before returning bytes. Explicit cleanup
failure prevents success and is reported, while best-effort teardown cannot guarantee removal
against a refusing filesystem. In-flight screenshot frames are safely drained after Stop without
creating a new file or preempting its acknowledgement; the precise late-descriptor race was
reproduced RED and fixed. See [screenshot evidence](us3-screenshot.md) for fixture/review details.

`devicebridge-encrypted-screenshot-r87ogva2/test.log` records **45.936 s PASS** for the actual
`captureScreenshot`, five metadata exchanges over 40 seconds, Stop, native child exit zero, phone
xcresult 1 pass/0 skips, nonce/Stop-ID action-log audit and cleanup. All three signed source roles
strictly verified. No clipboard access, PNG export/attachment/logging or Mac UI automation occurred.
Root regression: Core **283 tests / 49 suites pass**, SecureChannel **77 tests / 9 suites pass**;
13 Core physical opt-ins were skipped in the default regression, separately from the executed phone
evidence above. General WRITE/restoration, permission-wait flow, further adverse screenshots, Mac UI,
wireless and device-bound VM memory remain open; this does not close T084/T036/T041/T048 or the goal.

## 2026-09-08 — screenshot consumer and portable bundle prerequisites

The concrete `IOSRunnerScreenshotProvider` now binds selected transport plus authenticated context
and was used in the actual signed physical run `devicebridge-encrypted-screenshot-a2fehgb4/test.log`:
**47.900 s PASS**, image validation, 40-second metadata lease renewal, Stop/native exit zero, phone
1 pass/0 skips, log audit and owned cleanup; all three signed roles verified before/after. No general
clipboard action, image export or Mac UI interaction ran. Eight synthetic whole-channel screenshot
fault schedules also pass, with a wrong-digest validation-removal mutation failing as intended.

The bundled iOS project was found missing both local Swift dependencies. Packaging now retains
the relative source graph and excludes build/signing/user artifacts, verified by five relocation and
safety tests. Core regression: **286 tests / 49 suites pass**, existing physical opt-ins skipped in
the default suite. Full evidence and remaining T084/T036 gates are in [US3 validation](us3-screenshot.md).

## 2026-09-08 — preserving WRITE probe did not qualify general writes

The shared production synchronous setter/readback boundary and test-only ownership-aware restoration
passed **28 named-board phone fixtures**, including two independently identified await/never-set
ownership bugs that failed first. The signed encrypted general WRITE attempt
`devicebridge-encrypted-write-pig8mwzc` failed acknowledgement in **6.055 s**. No second general write
was attempted. A normal encrypted READ plus lease/Stop passed in **46.525 s** (`...read-xsejja7v`),
with no synthetic write fixture present. Two subsequent **read-only** snapshot audits skipped because
a complete item backup was unavailable; the latest returned no items without a reported revision
change. This is not proof of an empty safe-to-overwrite board or successful rich-content restoration.
See [US2 validation](us2-clipboard.md) for exact scope, diagnostics, privacy limits and next check.
Core **286**, SecureChannel **77** and packaging **5** regression tests pass. T084/T036/T041 remain open.
