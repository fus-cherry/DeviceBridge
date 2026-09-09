# iOS Flutter VM Memory Contract

Date: 2026-09-07
Status: Native app-scoped discovery, verified binding, Workspace readiness/Start/Stop and MemoryMonitor sampling are implemented and physically qualified for the pinned USB runtime. URI-only iOS attach fails closed. Physical load/restart/route-switch and wireless qualification remain open.
Requirements: FR-004/005/016/017/023/024/035.

## Scope and admission

One Mac application, no package or code changes in the target Flutter project. Debug/profile VM
availability is a prerequisite, not a guarantee for every build. Release/no-service/protected
processes report unsupported. iOS OS-level whole-process metrics have no qualified provider.

Automatic work may discover and handshake metadata only. It does not sample memory or invoke GC.
The user explicitly starts monitoring. A local/loopback URI is a candidate, not evidence that a VM
belongs to the selected iPhone. Never create a synthetic `flutter.vm` target with an unverified PID
and publish its samples under that phone's identity.

## Production path and owners

1. Workspace captures the active device/route/generation and selected running application.
2. `IOSFlutterVMDiscovery` owns a bounded metadata discovery attempt and its exact forwarding
   resource. Bonjour names are hints only; correlate the service to the selected device and its
   application/process through a verified device-specific route. USB and Wi-Fi qualify separately.
3. Validate `getVM` against independently obtained device-scoped process identity. PID equality
   without a verified device route is insufficient. Preserve process-start identity when available;
   if correlation is unavailable, retain an actionable unverified state instead of guessing.
4. Workspace rechecks the captured token and commits an immutable verified binding. Readiness is
   derived from this binding, not a manually typed URI or the presence of a signed XCTest runner.
5. Explicit Start admits the binding to the existing single-flight `MemoryMonitor`. Every result
   must match binding/device/process/token before publication. Stop or invalidation closes the
   series first, then cancels work and releases only the attempt-owned forwarding resource.
6. Late discovery, RPC, teardown and reconnect completions cannot publish into a replacement session.
   Reconnection requires new proof; do not replay sampling or GC across a changed target silently.

No XCTest clipboard/screenshot dispatcher dependency is required. Reuse qualified transport
primitives where justified; do not invent a wireless route or accept a shared host port as proof.
VM auth URIs remain in memory and out of logs, argv and validation records.

### Native HTTP refinement

The initial iOS polling adapter owns one exact-device USB stream. No DDS redirect, connection pool,
fallback endpoint or hidden reopen is allowed. Once disconnected, the owner and binding are terminal;
fresh discovery cannot continue the previous trend. Android redirect compatibility remains unchanged.

Single-flight RPC uses a bounded total deadline and bounded header/body framing. HTTP response IDs
are empty strings and must be validated separately from WebSocket integer IDs. HTTP 200 with an
event, error, missing identity or premature body is not a successful metadata/sample response.
Metadata-only readiness precedes explicit Start. Validate the captured VM/app/session and selected
isolate around sampling RPCs; missing metrics are unavailable, not zero. A replaced isolate ends
the series, rather than silently selecting another. Automatic isolate selection requires one
unambiguous candidate; labels must not imply its heap is total application memory.

Framing rejects excess bytes already received with the completed response. HTTP's fixed empty
RPC ID does not independently detect a malicious peer's separately arriving valid same-type replay.
The qualified Dart server owns one response per request; compliant HTTP ordering is a transport
assumption, not device/process proof. Do not claim arbitrary replay detection or use query `id`
as correlation: Dart's URI message constructor treats it only as a method parameter. Local stale
result rejection still requires close/cancel/deadline and the future binding/session checks.

DDS delegation is researched but not the initial implementation. Qualify the observed runtime and
protocol in physical validation; do not extrapolate one phone/version to all iOS or Wi-Fi routes.

### Timestamp continuity, not a process-instance token

On the qualified Dart 3.7.2 / protocol 4.16 route, startTime is independently recomputed from two
clocks. The experimental 1 ms range bound is superseded by the 2026-09-08 sustained physical
counterexample: 2 ms variation without a transport error. `IOSVMMetadataChannel` validates a
positive integral safe-number startTime but does not retain or compare it as identity. Continuity
requires its single non-reopening native USB stream, fixed expected PID and pinned isolate,
plus the independent application/device/session checks below. EOF remains terminal, with no
replacement connection or continued series. This policy does not qualify a proxy, reconnecting
transport, arbitrary metadata-replaying server, or another runtime.

This channel qualifies metadata only: its numeric Metadata value is not a transferable identity
token. `IOSVerifiedVMBinding` now captures the exact device/application/session and this owner;
equal metadata from a replacement owner cannot continue an old series. Initial auto-selection is
unambiguous in both qualifying snapshots; after commit, additional isolates may appear without
changing the pinned choice. Protocol/runtime changes, closure and stale completions invalidate it.

The metadata-only issuer verifies the complete current DeviceSessionStore session before and after
every external await. Its independent CoreDevice inventory must match the selected app/device,
including main executable and installation path before/after qualification; OS start identity stays
nil where unavailable. Binding renewal repeats independent app/session validation on the same
channel. A fresh UUID identifies each binding owner; there is no public binding/PID/URI initializer.
The caller still owns pending-attempt cancellation and must check its UI selection revision before
commit. Discovery and renewal cannot sample memory. The binding's separate explicit `readMemory()`
performs one-shot sampling. Its MemorySampling conformance feeds Core monitoring, and Workspace
now commits and consumes this owner only after checking its captured session, revision and target.

Workspace owns the selected app and binding reference. Application selection starts metadata-only
verification; multiple available apps require an explicit picker choice. Idle renewal runs every
10 seconds and yields to sampling, with single-flight busy treated as non-terminal. Start uses only
the committed binding, never iOS URI text. Stop, route/app/session replacement and `.invalidated` or
iOS `.stale` events revoke readiness before asynchronous close/drain. Discovery task cleanup is
awaited before the replacement attempt. The iOS selection busy flag covers device-session admission,
not the independent screenshot runner's signing or permission wait.

Production discovery admits at most four app-scoped hints under one shared 60-second admission
deadline. The deadline is not a hard in-flight-operation/cleanup bound. Only candidate transport/VM
unavailability can proceed to another hint after closing the failed owner; independent provider
errors, session change and cancellation terminate the attempt. Cleanup failure has priority over
cancellation, including when it has already been classified by an inner layer.

MemorySampling checks the exact immutable target and transport. A permanently invalid binding
returns `invalidated`, clearing the monitor series and ending its loop; it never silently retries
a closed owner. Ordinary provider failure (including busy metadata renewal) remains non-terminal.
Monitor start/stop revision prevents late provider results from restoring state. Store operation
completion checks and consumes eligibility in one actor turn; Workspace still owns selection and
monitor-identity guards around UI publication. Stopping the monitor does not itself close a generic
provider: the binding owner (Workspace, or the physical probe) must explicitly close it as well.

`readMemory()` first validates the binding/session. Its private channel checks VM continuity before
and after getMemoryUsage, including current-store checks after each RPC so a selection change
during the initial getVM prevents the content RPC. The binding then compares fresh independent app
metadata, renews on the same channel and rechecks the captured session before returning. Sampling
and metadata renewal share one single-flight guard; close/cancel/invalid metadata is terminal.
Only finite nonnegative integers up to 2^53−1 qualify; missing heap/external remain nil and both
missing fails. RSS/PSS are not returned. Host receipt time is captured immediately after usage RPC,
before subsequent validation awaits. This is an explicit one-shot API, not automatic monitoring.

## Metric semantics

Show timestamp/source and the reported Dart heap used/external bytes queried through the pinned
isolate. The qualified Dart 3.7.2 implementation returns that isolate group's shared heap; do not
label it exclusive per-isolate usage or sum sibling-isolate values. Missing fields remain
unavailable. An actual reported RSS field, if supported and verified, is separately labelled; heap
plus external bytes must not be presented as total application memory. Multiple-isolate policy must
be explicit rather than silently claiming first-isolate values describe the whole app.

## Discriminating acceptance

- A host VM or second phone with the same PID cannot populate the selected iPhone's chart.
- Manual unverified URI, unavailable correlation and missing VM service produce no device sample.
- Delayed discovery/RPC results after device or route switching cannot restore readiness or trends.
- App restart, PID reuse, forwarding failure and disconnect terminate the old series.
- On the designated iPhone, debug/profile load changes produce real timestamped values without a
  target-project modification; qualify USB and wireless independently and report unsupported routes.
- T110/T111 protect admission, T112 establishes discovery feasibility, T113/T114 implement the
  verified path, and T064 records actual load/restart/transport-switch evidence.
