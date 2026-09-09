# iOS VM discovery evidence

Date: 2026-09-08
Status: The native metadata-only binding issuer and renewal passed on the selected iPhone, using
independent app/process queries, an authoritative probe-local session store and one owned USB
stream. Native Bonjour candidate discovery and exact-device qualification now passed together.
Explicit binding-owned sampling subsequently passed on the physical phone; see
[US5 memory evidence](us5-memory.md). Production multi-candidate orchestration and Core monitoring
now pass; Workspace discovery/commit, idle renewal and explicit monitoring also passed physically
in `devicebridge-workspace-vm-memory-2qslnj7u` (see US5 evidence). T110–T114 are complete for the
pinned USB implementation; broader T064 and wireless acceptance remain open. The metadata-only
experiments below did not sample memory.

## Production app-scoped discovery — 2026-09-08

`IOSFlutterVMDiscovery.discover` is now the production entry. It validates the independently
identified app before browsing, rejects empty/foreign/over-four hint sets before any Connect, and
qualifies sequential hints using one shared 60-second admission deadline. It does not accept a
Bonjour host as device identity or sample memory. A failed candidate owner closes before fallback;
independent provider errors, cancellation, session replacement and cleanup failures are terminal.
The deadline controls admission/publication, not hard completion of an already-running device
query or cleanup. The caller owns final Workspace app-selection revision checks.

Independent review found two reachable regressions: real provider errors had collapsed into a
retryable candidate error, and a classified cleanup failure was overwritten by cancellation at the
outer error mapper. Both have deterministic RED/GREEN tests. Logs retain the failures in
`/tmp/devicebridge-ios-memory-monitor-deterministic-red.log` and
`/tmp/devicebridge-ios-discovery-cleanup-red.log`; final serial Core passed **363 tests / 56 suites**
in 12.882 seconds (`/tmp/devicebridge-ios-production-monitor-final.log`). Review is clean after fixes.

Physical `devicebridge-ios-vm-bound-memory-jpp97xyz` used this production entry rather than the
probe's former private candidate loop, then explicitly ran the real MemoryMonitor. Two samples
passed and the monitor stopped/owner closed; independent app PID and paired wired route remained
unchanged, exit zero, stderr empty. See US5 evidence for scope. This completes T113 Core discovery
handoff, not T114 Workspace readiness/Start or wireless acceptance.

## Native local Bonjour candidate discovery — 2026-09-08

`IOSVMBonjourDiscovery` uses the system `dnssd` module, not CLI text or a connection to an advertised
network host. One private serial queue owns the browse reference, resolve references, bounded
service records, timer and continuation. It browses only local `_dartVmService._tcp`, resolves
matching application-name hints on their observed interfaces, copies port/TXT during C callbacks,
and disposes all references before returning. The observation window is at most five seconds;
scope is capped at 256 app IDs, 512 browse events and 64 service additions. Resolved port/auth pairs
deduplicate across interfaces. This bounded window is not an exhaustive service inventory.

TXT parsing rejects missing/empty/invalid/duplicate authentication, malformed lengths, excess data
and privileged ports. A bare `authCode` followed by `authCode=value` initially escaped duplicate
handling; a focused failing regression preceded the fix. Nine tests cover scoped filtering, no
network work for empty/cancelled input, removed services, pending timeout cleanup, deliberately late
callbacks, remove/re-add generations, bounded overflow, parsing and redaction. Independent review
found no remaining actionable C-context/queue/lifetime defect. Review coverage suggestions were
added. Native OS calls are an external boundary in unit tests; no test service is registered.

Final serial Core suite passed **347 tests in 56 suites**, 12.872 s
(`/tmp/devicebridge-ios-bonjour-core-final.log`). This includes prior binding tests; it does not erase
earlier process-fixture timing failures or replace physical integration evidence.

The first physical native integration `devicebridge-ios-vm-usb-metadata-llbw97jp` returned no
single-candidate qualification and stopped before binding. A diagnostic repeat
`devicebridge-ios-vm-usb-metadata-686i9fum` clarified that the native browser returned **two** matching
app hints, not zero or a browser error. The probe's single-hint assumption was too strict. It now
tries at most four hints through the unchanged exact-device issuer, closes each rejected owned
attempt, and retains the outer 25-second process deadline. Names never select a trusted endpoint.
Both failed probes exited 1 with empty stderr and unchanged independent app PID/paired wired route.

Corrected physical probe `devicebridge-ios-vm-usb-metadata-r4wp96dy` passed: native browse returned
two hints; exact-device qualification rejected candidate 1 and closed that attempt, then candidate 2
issued a verified binding. Renewal succeeded; invalidating the probe-local store rejected another
renewal and made the owner terminal. Exit was zero, stderr empty, and independent app PID/paired
wired route stayed unchanged. This is native candidate → issuer → renewal evidence, not a working
Workspace memory chart or physical cable-switch test. No memory/clipboard RPC, GC, app launch,
permission change, service publication or desktop input occurred in any of these probes.

## Native metadata-only binding issuer — 2026-09-08

`IOSFlutterVMDiscovery.verify` now promotes an unverified in-memory port/authentication candidate
only after current-session validation, independent process lookup, native channel qualification,
a second matching process inventory and final same-owner VM renewal. Every external await is
followed by a cancellation and complete-session check. `IOSVerifiedVMBinding` has a file-private
initializer, unique owner ID, immutable device/session/app/isolate attribution and private channel.
Renewal checks the same independent app and current session; failure or close is terminal. A new
owner cannot reuse an old binding ID, even with identical numeric metadata. No memory API or UI
readiness is enabled by these types. Workspace must still check its own selection revision before
committing a returned binding. Per-operation deadlines are admission budgets, not a guaranteed
kernel cleanup/reaping wall-clock bound.

The initial seven tests produced 11 failures against an inert issuer, then passed. Additional
held-renewal tests found explicit close during a pending metadata RPC returned unavailable rather
than closed. The fix preserves cleanup failure → cancellation → prior closure → sanitized error
priority. Nine tests now cover wrong/same-PID devices, foreign VM PID, changed app path/PID,
stale/cancelled qualification at all five external boundaries, terminal renewal, unique owner
identity, concurrent renewal, late renewal and error redaction. Real store and metadata channel
code run in these tests; only external process and USB RPC boundaries are substituted.

Independent review found no remaining actionable implementation defect, including the final
metadata boundary and held renewal fixes. It did not sign off future Bonjour, UI or memory work.
Final serial Core suite passed **338 tests in 55 suites**, 12.611 s
(`/tmp/devicebridge-ios-binding-core-final.log`). Headless Workspace admission also passed: manual
iOS candidates still cannot sample or publish under the selected phone. The earlier 328-test run's
public-copy fixture failure below remains recorded and is not repaired by this later pass.

Physical `devicebridge-ios-vm-usb-metadata-aty2gh44` passed through the production issuer, native
process provider, native USB channel and binding renewal. Invalidating the probe's own session
store then caused staleSession, closed the binding and made the next renewal return closed.
This was a logical store invalidation, not a physical cable disconnect or the running Workspace's
store. Independent outer app PID and paired wired route checks remained unchanged, probe exit was
zero and stderr empty. No memory/GC/clipboard RPC, app launch, permission change or desktop input
occurred. No current Debug UI functionality is claimed from this headless evidence.

## Independent native application/process correlation — 2026-09-08

`IOSApplicationProcessProvider` now reads bounded CoreDevice JSON through an owned exit-only child
process and 0700 temporary directory. Its production sequence is Details → developer Apps →
Processes → Details. Both device UUID and hardware UDID must match the captured active session;
the physical route must be wired, paired and developer-enabled before and after. Only a unique
main executable directly inside the installed `.app` qualifies, not an extension or prefix match.
The inventory preserves the captured session and leaves unavailable OS process-start identity nil.
It is still an observation, not an atomic process-instance token or a verified VM binding.

The initial seven focused tests passed. Independent review then identified cancellation masking
cleanup failure and contradictory identity mappings. Three regression cases failed against that
version: cancelled cleanup reported CancellationError, duplicate installation paths and duplicate
PIDs were accepted. The minimal fixes preserve cleanupFailed priority and reject both duplicate
mappings. Eight focused tests now pass, including 12 malformed-metadata and nine scope variants
(`/tmp/devicebridge-ios-process-review-red.log`, `/tmp/devicebridge-ios-process-review-green.log`).

Physical runs `devicebridge-ios-vm-usb-metadata-qjdl96u_` (before review fixes) and
`devicebridge-ios-vm-usb-metadata-0em7l74x` (after fixes) both passed. The native provider independently
obtained the app PID/path before opening the metadata channel; ten VM observations qualified;
the provider reloaded afterwards and the exact app/path/PID remained unchanged. The probe exited
zero, closed its owned stream, produced no stderr, and independent outer route/PID checks passed.
No memory sampling, app launch, GC, clipboard, desktop input or permission changes occurred.

Do not claim a clean full-suite result for this slice: serial Core run
`/tmp/devicebridge-ios-process-core-final.log` ran 328 tests in 54 suites and failed the existing
`nativeCopyDeadlineEscalatesAndCleansTheOwnedDirectory` readiness/minimum-duration assertions
(1.023 s, no ready marker). Its isolated serial recheck passed in 3.032 s
(`/tmp/devicebridge-ios-copy-deadline-isolated.log`). The failure therefore is not confined to
parallel mode. Source inspection shows the test assumes its fresh shell fixture installs a TERM
trap within a one-second lifetime; startup delay is a hypothesis, not a proven cause or repair.
No production process owner or old test was modified, and both outcomes remain recorded.

T110–T114 remain open: native Bonjour candidate discovery, immutable binding/session admission and
explicit memory sampling are not enabled by the process-provider slice. The desktop app was not
rebuilt/relaunched for this Core-only change.

## Native bounded continuity qualification — 2026-09-08

`devicebridge-ios-vm-usb-metadata-a80mrjlt` used the production `IOSVMMetadataChannel` native factory
and private transport owner. One selected USB connection performed protocol qualification, two
initial getVM snapshots and eight renewals (ten VM observations total). The expected independently
obtained app PID and pinned isolate remained stable; protocol 4.16 / Dart 3.7.2 were required and
the total observed startTime range stayed within 1 ms. The probe exited zero with no stderr;
independent device-scoped app PID and paired wired route remained unchanged before and after.
The channel closed on completion. No memory/GC/clipboard/screenshot RPC, app launch, permission
change or Mac input occurred. This is metadata-continuity qualification, not a verified binding.

The metadata actor owns the only continuity writer and never replaces its transport. Initial
candidate state is committed only after protocol and two matching snapshots; later metadata calls
renew that same pinned isolate. Automatic selection requires a singleton in both initial snapshots.
A newly appearing isolate after commit does not change the selection. Close, cancellation, invalid
metadata, PID/isolate change or total timestamp spread above 1 ms makes the owner terminal. Failure
does not label every timing change as a definite app restart. No memory request exists on this API.

Tests first reproduced adjacent-time rejection, cumulative drift/straddling risk and stale initial
qualification boundaries. An independent review found `[A] → [A,B]` could incorrectly auto-commit A;
a regression test failed before the second-snapshot singleton check was added. Additional coverage
checks late renewal after successful qualification, expected-PID mismatch and one-Connect native
integration. The reviewer did not sign off future device/session attribution or production sampling.

Final general verification: explicit serial run
`swift test --package-path packages/DeviceBridgeCore --skip-build --no-parallel` passed **321 tests
in 53 suites**, 12.393 s (`/tmp/devicebridge-vm-continuity-core-serial.log`), with the existing opt-in
physical skips. The headless Workspace iOS admission check passed: a manual candidate still cannot
start monitoring or publish a phone sample. No desktop app restart or Release/package build occurred.

Do not erase two earlier default-parallel failures: `/tmp/devicebridge-vm-continuity-core-final.log`
failed the launcher's 40 ms blocked-start cleanup assertions; its isolated recheck passed in 0.047 s.
`/tmp/devicebridge-vm-continuity-core-recheck.log` failed the public-copy fixture's readiness marker
and minimum escalation-duration assertions. Source inspection shows those tests depend on reaching
process/channel setup before short wall-clock deadlines. Parallel scheduling sensitivity is a
supported hypothesis, not a reproduced production regression or a repaired test. Neither production
launcher nor those tests was changed in this slice. The serial pass establishes an isolated
full-suite baseline, not default-parallel stability.

## Native physical follow-up: startTime is not an opaque stable identity

`devicebridge-ios-vm-usb-metadata-z3zi87uz` used the actual `IOSVMHTTPTransport` factory, reader and
single owned USB stream for `getVM → getVersion → getVM`. RPCs succeeded, protocol was 4.16 and VM
PID matched the independent selected-device app PID, but the exact PID/start tuple differed. The
probe exited 2 (unverified), with stable independent app PID/route and no stderr. Do not report this
as an identity pass merely because HTTP or the process correlation worked.

Diagnostic repeat `devicebridge-ios-vm-usb-metadata-79cygdg8` separated PID from time: all ten getVM
observations kept the same PID; their startTime values occupied two adjacent milliseconds. The
initial pair differed by one millisecond, so the unchanged exact gate again returned unverified.
Only classifications were printed, not timestamps, PIDs, URIs or authentication values. The native
owner was closed, the process exited, and independent device/app metadata remained stable.

Pinned Dart 3.7.2 [service implementation](https://github.com/dart-lang/sdk/blob/3.7.2/runtime/vm/service.cc#L5263-L5265)
recomputes startTime as current wall-clock milliseconds minus uptime milliseconds on each call.
This supports clock quantization as the hypothesis, not a license to ignore restarts. Review clock
implementation and establish bounded, non-drifting identity semantics with tests before promoting
a production binding. Missing OS process-start metadata stays missing; no tolerance or sampling
admission was enabled in those failing probes. The bounded metadata-only policy above was added
after this investigation. This also offers a possible explanation, not retrospective proof, for
the earlier combined-identity failure `s067bnlo`.

## Latest evidence: one persistent USB HTTP stream

`devicebridge-ios-vm-usb-metadata-de179mjk` completed `getVM → getVersion → getVM` on **one** raw
exact-device USB Connect. All responses were HTTP 200 with chunked framing, keep-alive and the
expected empty-string JSON-RPC ID. Both VM PID/start pairs matched; VM PID matched the independently
selected app process. Device-scoped app PID and paired wired route were stable before/after.
There was no HTTP connection pool, redirect, retry, new Connect or alternate endpoint. The probe
used the existing USB experiment primitive and Python's HTTPResponse framing parser on that socket.

`devicebridge-ios-vm-usb-metadata-_d9eg6a3` repeated the same sequence successfully and recorded
**Dart 3.7.2 / VM protocol 4.16**. The earlier probe's runtime-version regex did not extract the
version; correcting that probe-only regex changed no transport behavior. An earlier two-connection
HTTP experiment (`devicebridge-ios-vm-usb-metadata-rr6s9s6j`) also passed but is weaker continuity
evidence and must not be substituted for these single-Connect observations.

No getMemoryUsage, allocation, GC, app launch, clipboard or Mac input operation was performed.
One persistent stream does not replace process/session binding. Native HTTP framing, cancellation,
DDS takeover, isolate replacement, restart and physical sampling remain implementation/acceptance
work. Prefer this direct path in the revised plan because polling does not need a second DDS
endpoint; qualify only the observed runtime/protocol, not arbitrary runtimes or wireless routes.

## Native transport implementation review

The new native HTTP parser/owner passed 14 focused tests across two suites, including real local
UNIX usbmux inventory/Connect, three ordered RPCs, empty-string IDs, invalid envelopes, redirects,
partial bodies, single-flight rejection, total fragmented-response deadline and cancellation/close.
Factory validation rejects bad authentication/deadline inputs before opening a socket. This is
synthetic protocol evidence, not a physical memory test. Tests first failed against inert framing,
request and factory implementations; an embedded LF status-line case separately failed before repair.

Independent read-only review found no actionable close/cancel race or diagnostic secret exposure.
It correctly narrowed the excess-response claim: bytes coalesced with a completed frame are rejected,
but a separately arriving valid replay cannot be distinguished by HTTP's empty RPC ID. Pinned Dart
3.7.2 creates a request-specific HTTP response and offers no normal-server replay path; its
[URI message constructor](https://github.com/dart-lang/sdk/blob/3.7.2/sdk/lib/vmservice/message.dart#L96-L100)
does not accept a caller-assigned response ID. Preserve compliant-server ordering as an explicit
assumption, not cryptographic replay protection. The status-line finding was reproduced and fixed.
Review allows metadata-only native qualification, not production binding or memory sign-off.

Core's full general suite subsequently passed 308 tests in 52 suites
(`/tmp/devicebridge-http-core-final.log`), with its usual opt-in physical skips. This includes 14
new HTTP tests; it does not replace the unverified physical identity outcome above.

Incremental macOS Debug build subsequently succeeded (`/tmp/devicebridge-http-debug.log`). The app
was not relaunched and no UI readiness or memory sampling was enabled by this transport-only slice.

## Explicit DDS experiment

`devicebridge-ios-vm-usb-metadata-y3huhpgh` read a 302 Location only through the selected USB route,
validated its literal loopback address, allowed scheme/port/path and absence of userinfo/query/
fragment, then explicitly connected with redirects rejected. `getSupportedProtocols` identified
DDS; two getVM PID/start pairs were stable and matched the independently selected device-app PID.
A fresh selected-USB delegation read afterward matched the in-memory URL. Independent app PID and
wired route remained stable, exit was zero and stderr empty. No URI/authentication value was logged.
This demonstrates a feasible explicit delegation check, not production lifecycle qualification.

An earlier explicit attempt (`devicebridge-ios-vm-usb-metadata-7tx1u48g`) failed because the probe
incorrectly required Location to end in `/ws`. The server returns an authenticated root URL; the
probe now validates that root and normalizes its WebSocket path. Keep this failure as probe evidence,
not evidence that DDS is unavailable. Both researched paths leave the existing debug session intact.

Independent source review found that DDS takeover can notify/disconnect non-DDS HTTP clients too.
A production reader must reject streamNotify/error/partial responses and never treat any HTTP 200
as success or silently reopen. HTTP RPC IDs are empty strings, not the WebSocket client's integers.
The plan now explicitly requires this framing boundary, one permanent owner and pinned isolate.

## Earlier correction: direct USB versus DDS handoff

Independent review identified an untested assumption in the earlier experiment: a WebSocket
opened through the USB proxy could follow an HTTP redirect. Local real-transport tests confirmed
that the existing URLSession client followed 301/302/303/307/308 to a second loopback endpoint.
Consequently, the metadata success recorded below proves a USB-originated attempt with matching
VM PID, **not that getVM stayed within the owned USB connection**.

After explicitly rejecting redirects, the physical attempt in
`devicebridge-ios-vm-usb-metadata-es4gr3eu` failed at getVM; independent phone/app state was stable.
A subsequent direct HTTP WebSocket-upgrade request over the selected USB stream, in
`devicebridge-ios-vm-usb-metadata-o76p6dau`, observed status **302**, a Location field and a loopback
destination. It did not follow that destination or log/save its URI. This is consistent with Dart's
documented DDS single-client forwarding behavior, not yet independent proof of the DDS identity.
No DDS process was stopped and the target Flutter debug session was not reconfigured.

The first blanket redirect rejection would also break existing redirect-based clients. A real
local DDS-style compatibility test reproduced that regression before the policy was narrowed.
The shared transport now has an explicit redirect policy: existing clients default to `.follow`,
preserving prior Android/manual behavior; the experimental owned iOS path selects `.reject`.
Production iOS URI-only sampling remains rejected before RPC. This is **not** a global guarantee
that every FlutterVMService client is route-bound, and no verified iOS issuer exists yet.

`python3 scripts/test_vm_transport_redirects.py` passed 3 tests, including five strict redirect
subcases, a direct WebSocket metadata response and a default-constructor DDS-style redirect to a
second real WebSocket endpoint. Core passed 294 tests in 50 suites; the usual opt-in physical tests
remain skipped in that general suite. Incremental Debug build and strict app signature passed
(`/tmp/devicebridge-vm-endpoint-debug.log`). Independent read-only review accepted the scoped
policy, explicitly retracting its earlier assumption that blanket rejection preserved DDS users.

Any future delegated implementation must distinguish a direct VM endpoint from a
device-originated middleware handoff. A DDS URI is not independently verified merely because it
is loopback or reports a matching PID. Record and verify the selected USB endpoint's delegation,
the DDS protocol/VM identity and the captured device/app/session together before admitting such
a binding. Do not silently follow arbitrary redirects or disable the user's existing DDS to make
a test pass. Direct, delegated, restart, stale-session and cleanup behavior still need production
tests and real-device acceptance.

## Safety boundary and current admission

T111's initial safety slice now blocks every URI-only iOS sample before RPC and blocks Workspace
manual attach before monitor creation. It does not yet implement a verified binding type or
discovery issuer. T110/T111 remain open for that work. This makes the following metadata-only
T112 investigation possible without misattributing a sample in the production app.

No Mac window, input device, desktop XCTest, clipboard, app launch, GC or memory RPC was used.
MobAI tools were absent after tool discovery; the already authorized Xcode/CoreDevice fallback
was used. No account, certificate, provisioning profile, local-network permission or phone setting
was changed. No VM authentication URI/code was printed, placed in argv, or saved to disk.

## Observed physical metadata

The designated iPhone was queried with bounded `devicectl device info details`, `apps` (default
developer-app scope), and `processes`, using supported JSON output. Each command exited zero.
The fresh route was wired and paired with Developer Mode enabled. Private 0700/0600 evidence is
under the temporary directory `devicebridge-ios-vm-metadata-x3e3xte0`; raw phone identifiers,
application identifiers, installation URLs and PIDs are deliberately omitted from this report.

- Six developer-app records were returned. Two were this project's own helpers. Three of the four
  other developer apps had a running executable inside their exact installed app directory.
- The union of process-record fields was only `executable` and `processIdentifier`. No independent
  process start time was returned. Installation URL containment can correlate a running executable
  to an app, but is not by itself a VM connection or restart/PID-reuse proof.
- A bounded Bonjour `_dartVmService._tcp` browse returned six announcement rows across interfaces,
  which deduplicated to **two** service names. Both names matched developer-app bundle identifiers
  installed on the selected phone. Those names are hints, not device identity proof.
- Both candidates resolved a port and an authentication TXT field within bounded queries. Their
  host, port, name and authentication code were retained only in the probe's memory and discarded
  on exit. Each exact child `dns-sd` process was terminated and reaped at its deadline.
- An intermediate parser produced zero candidates because it assumed no leading whitespace in
  CLI rows. Inspection of redacted column layout identified that probe-only parsing error. Splitting
  the observed columns correctly produced the two candidates above. Do not interpret that earlier
  zero as missing VM service or use human-readable CLI output as a production discovery interface.

No forwarding socket was opened and no `getVM` request was made in this preliminary observation.
It therefore does not qualify USB forwarding, endpoint/device/PID correlation, start identity,
wireless routing, load changes, restart or cleanup of a VM forward.

## Exact USB getVM experiment — 2026-09-08

`scripts/ios-vm-spike/MetadataProbe.swift` is an opt-in experimental executable, compiled against
the existing Core static product. It accepts bounded JSON on stdin, uses `IOSUSBMuxConnection`
with the selected hardware UDID and advertised port, creates an owned one-client loopback proxy,
and sends only two `getVM` calls through one WebSocket. It closes the RPC and proxy on success,
failure and the eight-second RPC deadline. The orchestrator bounds each probe process to 25 seconds
and reaps it. Identifiers/authentication fields never enter its arguments or saved logs. This is
transport/process-correlation research, not a verified-binding issuer or a memory feature.

First attempt, private metadata directory `devicebridge-ios-vm-usb-metadata-s067bnlo`:

- Candidate 1 reached the device VM over exact USB, but the combined stable-VM-identity and
  expected-PID predicate failed (exit 2). The initial probe did not distinguish those two facts,
  so the cause is unresolved. Independent app PID and wired route matched before and after.
- Candidate 2 failed at the selected USB connection (exit 1), with the same independent route/app
  stability. No fallback to a Bonjour network host was attempted.

Second attempt, `devicebridge-ios-vm-usb-metadata-k7x49yq7`, added only fixed classification output:

- Candidate 1 **passed** (exit 0): two VM PID/startTime pairs agreed, VM PID equalled the expected
  device-scoped app PID, and it was present in the selected phone's process inventory. Independent
  app PID and paired wired route remained unchanged before/after. The exact probe process exited
  after closing its owned resources; no background forward remains from that process.
- Candidate 2 still failed at selected USB connection. Both probes had empty stderr.
- Comparing private CoreDevice metadata across both attempts found no known developer-app PID
  change. The earlier combined-predicate failure therefore remains unexplained; the later pass
  must not erase it or be represented as stable/repeatable production discovery.

No `getMemoryUsage`, allocation, GC, app launch or clipboard operation occurred. The successful
session demonstrates feasibility for one USB candidate; it does not satisfy T110/T111 binding
types/lifecycle, T113/T114 production integration, T064 load/restart or wireless qualification.

## Original direct-route experiment plan (now requires the DDS correction above)

Resolve candidates in memory, then use the selected hardware UDID and an attempt-owned USB
connection/loopback endpoint to reach the advertised device port. Do not connect directly to the
Bonjour host and call that selected-device proof. Send `getVM` only; correlate its PID against fresh
device-scoped executable/app metadata before and after the handshake. Record VM `startTime`
separately from any OS process-start identity; determine how PID reuse and missing OS start
metadata can be safely handled before enabling a production verified binding. Bound all probes,
close/reap only their own resources, and redact authentication information in every failure path.
Do not enable sampling merely because the metadata handshake succeeds. T113/T114 and physical
T064 load/restart/route checks remain required. Wi-Fi must be qualified independently.

## Primary references inspected

- Installed `xcrun devicectl help device info apps` and `processes`: supported file JSON interface,
  developer-app default filter, timeout and executable/PID output observed above.
- [Flutter mDNS discovery implementation](https://github.com/flutter/flutter/blob/master/packages/flutter_tools/lib/src/mdns_discovery.dart):
  service discovery uses SRV/TXT data and separate device port forwarding; application-name hints
  do not replace our device/route validation contract.
- [Dart VM Service Protocol](https://github.com/dart-lang/sdk/blob/main/runtime/vm/service/service.md):
  `getVM` provides VM PID and a VM start timestamp in milliseconds since epoch. That timestamp
  must not be confused with OS kernel start ticks or a missing independent process-start field.
  Its Single Client Mode section documents forwarding new WebSocket connections to DDS by redirect.
