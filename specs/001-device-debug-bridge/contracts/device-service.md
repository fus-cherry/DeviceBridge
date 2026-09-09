# Device Service Contract

## Purpose

Define the behavior the Mac session store can rely on from Android and iOS services without
exposing platform command syntax to UI code.

## Interface

A platform service provides these asynchronous operations:

```text
discover() -> List<TransportCandidate>
probe(candidate) -> ProbeResult
capabilities(session) -> Map<CapabilityKind, DeviceCapability>
probeClipboardReadiness(sessionToken) -> Outcome<DeviceCapability>
probeFlutterVmReadiness(sessionToken) -> Outcome<DeviceCapability>
probeScreenshotReadiness(sessionToken) -> Outcome<DeviceCapability>
probeFileScopeReadiness(sessionToken) -> Outcome<DeviceCapability>
probeConnectionHealth(sessionToken) -> Outcome<ConnectionHealth>
recoverConnection(sessionToken, knownEndpoints) -> Outcome<RecoveredTransport>
listApplications(session) -> List<TargetApplication>
readClipboard(sessionToken) -> Outcome<ClipboardSnapshot>
writeClipboard(sessionToken, text) -> Outcome<void>
captureScreenshot(sessionToken, partialPath) -> Outcome<ArtifactDraft>
sendFile(sessionToken, source, destination) -> Outcome<TransferReceipt>
receiveFile(sessionToken, source, partialPath) -> Outcome<TransferReceipt>
sampleMemory(sessionToken, targetApplication) -> Outcome<MemorySample>
cancel(operationId) -> void
```

The concrete Swift protocols may split discovery, helper management, platform operations, and memory providers, but their
observable contract must remain equivalent.

## Universal Rules

1. Every operation except discovery requires an active `SessionToken`.
2. Services never write `WorkspaceSnapshot`; they return typed outcomes to `DeviceSessionStore`.
3. Each external command is target-specific and receives the captured transport, never the current
   global selection.
4. A service checks cancellation before and after each external boundary.
5. Services may create only operation-scoped partial files. The session store and `ArtifactStore`
   control final publication.
6. stdout is data only when the invoked tool documents or a fixture tests that format. stderr and
   nonzero exit status must be considered before success.
7. A zero exit status with missing or malformed required data maps to `malformedOutput`, not success.
8. Sensitive arguments and output are marked for redaction before reaching `HostCommandRunning`.
9. Missing tools and unsupported platform versions return a capability outcome; they do not throw
   uncaught exceptions into the UI.
10. Cancellation must be idempotent.
11. Readiness and health probes never call content-producing operations and never publish artifacts.
12. Health probes are single-flight per transport and yield rather than queue when an exclusive
    screenshot, transfer, clipboard, or VM attach operation owns that transport.

## Outcome Types

```text
Success<T>(value)
Unsupported(reason, recovery?)
HelperRequired(reason, recovery)
ActionRequired(reason, recovery)
Restricted(reason, recovery?)
PermissionDenied(reason, recovery?)
Timeout(reason, recovery?)
Cancelled
Disconnected(reason, recovery?)
MalformedOutput(reason, diagnosticRef?)
Failure(reason, diagnosticRef?, recovery?)
Stale
```

`Stale` is normally assigned by the session store after token validation. Services may return it only
when they can prove their captured transport/session is already invalid.

## Discovery Contract

### Android

- Source: `adb devices -l`.
- Every command after discovery targets `-t <transport_id>`.
- `device`, `offline`, and `unauthorized` remain distinct states.
- An available state requires a bounded target-specific probe, not list presence alone.
- USB and Wi-Fi candidates are not auto-merged without a stable managed-helper identity or explicit
  developer association.
- The service never invokes `adb kill-server` automatically.
- Device tracking and `_adb-tls-connect._tcp` mDNS tracking are refresh inputs; neither alone proves
  command readiness.
- A selected wireless connection receives a bounded target-specific command probe every five seconds
  while idle. Two consecutive failures invalidate the transport generation before reconnect begins.
- Recovery retries the last known endpoint, then current matching mDNS endpoints with 1/2/4/8-second
  backoff. Identity and a successful command are both required before publication.
- Android 17 ADB Wi-Fi 2.0 automatic reconnection is detected and used when available, but the same
  identity and command verification still applies.

### iOS

- Source: `xcrun devicectl list devices --json-output <temporary-file>`.
- The JSON result file is the only authoritative machine input.
- UDID is the stable identity; CoreDevice identity and JSON schema version are retained for parsing.
- `xcdevice observe` may request an early refresh but never mutates inventory directly.
- Only authoritative `transportType == wired` is treated as wired.
- Unavailable, unpaired, locked, missing Developer Mode, and tunnel-unavailable states remain distinct.

## Capability Contract

A capability evaluation is specific to:

```text
device identity
+ platform and OS version
+ selected transport
+ authorization/lock state
+ host tool versions
+ managed helper/runner presence and version
+ provider transport/readiness
+ check timestamp
```

A capability expires when any input changes. Buttons may dispatch only when availability is
`available` or when the button itself is the named recovery action. Experimental capabilities must
remain visibly labelled throughout the operation.

## Automatic Readiness Contract

- Clipboard, Flutter VM, screenshot, and file-scope probes begin after a session first becomes
  command-ready and rerun after a recovered transport generation commits.
- The four probes run independently with a maximum of two concurrent external commands per device.
- Clipboard readiness authenticates the managed helper and checks advertised state; it does not read the
  clipboard.
- Flutter VM readiness discovers and handshakes with an eligible debug/profile service, redacting its
  URI; absence is a normal unavailable result.
- Screenshot readiness checks provider/tool/device preconditions and does not retain image bytes.
- File readiness checks predetermined scope accessibility without listing user files or transferring
  bytes.
- A probe timeout affects only that capability and never changes an otherwise healthy connection to
  disconnected.

## Keep-Alive and Recovery Contract

- `ConnectionSupervisor` is created and stopped only by `DeviceSessionStore`; adapters return
  observations and never select a device themselves.
- A health success requires a target-specific command, not list presence, mDNS presence, a helper
  lease, or a TCP socket alone.
- Android helper keep-alive status reports its foreground notification and Wi-Fi-lock state only.
- Deselect, Mac app shutdown, generation replacement, or explicit Stop cancels timers and reconnect
  attempts and terminates the helper lease.
- Disabled Wi-Fi/wireless debugging, revoked pairing, network isolation, reboot, and exhausted bounded
  retries map to `actionRequired` with a concrete recovery step.
- iOS uses the same host supervision states but has no device-side indefinite keep-alive promise;
  wired remains the reliability baseline.

## Screenshot Contract

### Android

- Read PNG bytes from the target-specific screencap command.
- Write to a unique partial file.
- Validate PNG signature, nonzero dimensions, and token before publication.
- Secure/protected content limitations are reported without claiming full capture.
- The previous valid preview remains if capture fails.

### iOS

- CoreDevice alone reports screenshot as helper-required.
- `IOSRunnerManager` owns signing readiness, build-product version, install, start, connection, and
  stop for the bundled XCUITest runner.
- The provider is available only after device trust, Developer Mode, runner signing, and a real
  command-ready probe pass.
- The Mac application may automatically install and start the compatible runner, but must surface
  device confirmation or signing steps it cannot complete.
- Provider startup and user permission time are excluded from the warm-capture metric.

## File Transfer Contract

Phone-image discovery, selected preview and original export are a distinct extension of US4, not a
claim made by known-path file transfer. The implemented Android interface and remaining platform gates are in
[phone-images.md](phone-images.md); they reuse the existing session/operation contract.

- Source and destination must use an allow-listed scope descriptor, not an arbitrary shell fragment.
- Device-to-host transfer writes `.partial.<operationId>` and renames only after validation.
- Host-to-device transfer uses an operation-specific staging name and publishes only after remote
  validation where supported.
- At minimum, compare byte length. Compare SHA-256 when both sides can report it. If integrity cannot
  be proved, the result states the validation level.
- A cancellation, timeout, disconnect, or integrity mismatch cannot produce a final artifact.
- Existing destinations require explicit replace confirmation or a new destination.

## Memory Contract

- A sample is bound to device identity, package/bundle ID, PID, process-start identity when available,
  session generation, and source.
- Android `dumpsys meminfo` uses PSS as the primary OS metric and never substitutes missing fields.
- VM Service URIs are secrets held in memory and redacted from all logs.
- iOS CoreDevice process lists provide identity only, not memory values.
- PID or process-start changes close the prior series and return `restarted` before new samples.
- Sampling is single-flight per target with a three-second freshness target. The default
  start-to-start cycle budget is 2.5 seconds, including provider and publication time, leaving
  headroom for request/dispatch variation. An overrun adds no further delay and queues no catch-up
  samples. Slow external operations can still exceed the freshness target; keep the actual sample
  timestamp and existing failure state instead of overlapping requests or fabricating freshness.

## Error Mapping Minimum

Each adapter fixture suite must discriminate:

- tool missing or incompatible;
- unauthorized or unpaired device;
- offline or disconnected transport;
- locked device or action required;
- permission denial;
- helper missing or incompatible;
- timeout;
- explicit cancellation;
- malformed/partial output;
- integrity mismatch;
- unsupported platform capability;
- unclassified safe failure.
