# Data Model: Device Debug Bridge

## Release closure evidence (2026-09-08)

No new mutable business-state owner is introduced. A validation observation records build, scenario,
control method, timing boundary, fixture class, outcome and remaining scope. Outcomes are `passed`,
`failed`, `not-run-external-prerequisite` or `deferred-by-user`; a passed subset never commits its
parent story as complete. Optional monotonic preparation measurements are derived diagnostics, never
readiness/authentication inputs and never contain target IDs, payloads, certificates or file paths.
See [release-closure.md](contracts/release-closure.md) when implementing or evaluating this closure.

Compiler-state ownership: WorkspaceViewModel owns one IOSRunnerBuildWorkspace actor; it alone writes
its UUID DerivedData path and build admission flag. A failure/cancellation rotates that path. Managers
retain launch identity and eligibility; launchers only read their immutable Products snapshot and own
fresh authentication/native resources. No cached build or timing value is an authoritative readiness
state. File receive staging is operation-local provider storage, never a committed TransferArtifact;
FileTransferService remains the session/integrity/publication owner.

## Implemented Android phone-image extension (2026-09-07)

- `ImageSource`: one of Android DCIM/Pictures/Download or experimental iOS USB camera import.
  The UI label reflects this limited scope, not a complete phone/cloud library.
- `ImageItem`: ephemeral UUID, display name, relative directory, byte length and modification time.
  It belongs to exactly one catalog. The service privately maps its ID to a validated
  provider locator; UI text is never interpreted as a locator or shell command.
- `ImageCatalog`: catalog UUID, source device, session generation, source and
  bounded immutable items. Empty is valid only after successful complete enumeration.
- `ImagePreview`: preview UUID, catalog ID, item metadata, pixel dimensions, media type, thumbnail PNG
  and preview PNG. Device/generation belongs to its catalog; original URL/receipt stays service-private.
  Preview bytes are derived; original bytes are authoritative for export. A partial file is never a committed preview.
- `ImageLibraryService`: sole writer of its committed catalog/preview, locator mapping and request gate.
- `ImageRequestValidity`: the service invalidates this request gate on source/reset/new work. A short
  lock serializes invalidation with terminal file rename. It is not a second writer of catalog state.
  The existing `DeviceSessionStore` still exclusively owns device/transport/session and
  operation tokens. UI presentation copies do not initiate work or become alternate business state.
- `PhoneImagesViewModel.revision`: invalidates older list/preview/export callbacks on the same device when
  source or item selection changes. It complements, and never replaces, the existing session token.

Limits, provider boundaries, iOS session ownership and exact failure/publication rules are specified
in [contracts/phone-images.md](contracts/phone-images.md). iOS production models remain gated.

## Ownership Map

| Business Concept | Authoritative Writer | Readers |
|------------------|----------------------|---------|
| Device inventory and transport candidates | `DeviceSessionStore` actor | Device list, capability panels |
| Active device and session generation | `DeviceSessionStore` actor | All feature view models and services |
| Health cadence, reconnect attempts, and keep-alive lease | Active `ConnectionSupervisor` | Repository and connection UI |
| Operation lifecycle and current results | `DeviceSessionStore` actor | Feature panels, status area |
| Child process lifecycle | `HostCommandRunning` implementation | Platform services |
| Temporary and saved artifact paths | `ArtifactStore` | Repository and screenshot/transfer views |
| Helper installation and request processing | `AndroidHelperManager` / `IOSRunnerManager` | Platform services and helper processes |
| Non-sensitive preferences | `SettingsStore` | App bootstrap and UI |

No feature view or platform adapter may mutate `WorkspaceState` directly.

## DeviceIdentity

Represents one physical authorized device.

| Field | Type | Rules |
|-------|------|-------|
| `value` | opaque string | iOS uses UDID; Android uses managed-helper app-scoped GUID when available, otherwise a transport-scoped provisional ID |
| `kind` | `stable | provisional` | Provisional identities cannot auto-merge with another transport |
| `displaySuffix` | string | Short non-sensitive suffix derived for UI disambiguation |
| `platform` | `android | ios` | Immutable for the lifetime of the record |

**Validation**:

- Names, model strings, IP addresses, and transport serials cannot be treated as a stable physical ID.
- Raw identity values are never written to default diagnostic logs.
- A provisional identity can be replaced only by an explicit stable correlation event.

## TransportCandidate

One currently observed route to a device.

| Field | Type | Rules |
|-------|------|-------|
| `transportId` | string | Unique within the source tool snapshot; Android transport IDs may change on reconnect |
| `deviceIdentity` | `DeviceIdentity` | Stable or provisional |
| `kind` | `usb | wifi` | Derived only from authoritative tool output or verified transport metadata |
| `source` | `adb | coreDevice` | Determines the platform service |
| `status` | `candidate | probing | available | degraded | offline | unauthorized | removed` | Never infer available solely from historical presence |
| `observedAt` | timestamp | Must be refreshed before expiry |
| `lastHealthyAt` | timestamp? | Set only by a successful target-specific probe |
| `metadata` | redacted map | Only fields needed for capability and display |
| `endpoint` | redacted endpoint? | Wireless host/port; replaceable after mDNS rediscovery and never a physical identity |
| `mdnsInstance` | redacted string? | Discovery correlation hint only; must be verified against stable identity before commit |
| `failure` | `OperationFailure?` | Present for non-available states |

**Preferred transport rule**: choose a healthy USB candidate before Wi-Fi for the next operation.
An already-running operation remains bound to its captured transport.

## DeviceRecord

Aggregates known candidates for one physical device.

| Field | Type | Rules |
|-------|------|-------|
| `identity` | `DeviceIdentity` | Aggregation key |
| `name` | string | User-recognizable but not unique |
| `model` | string? | Display only |
| `osVersion` | string? | Display and capability evaluation |
| `authorization` | `unknown | actionRequired | authorized | denied` | Updated from current probes |
| `candidates` | non-empty list of `TransportCandidate` | Removed when all candidates expire |
| `preferredTransportId` | string? | Must identify a currently available candidate |
| `capabilities` | map of `CapabilityKind -> DeviceCapability` | Recomputed when device, transport, permission, helper, or tool state changes |

## ConnectionSession

The committed active-device context.

| Field | Type | Rules |
|-------|------|-------|
| `deviceIdentity` | `DeviceIdentity` | Must exist in current inventory |
| `generation` | positive integer | Increments on selection, disconnect, transport invalidation, or explicit reset |
| `transportId` | string | Bound preferred transport for new work |
| `state` | `selecting | active | invalidating | disconnected` | Only active sessions start operations |
| `startedAt` | timestamp | Immutable |
| `capabilities` | capability snapshot | Used to gate commands at start; repository rechecks current state before commit |
| `supervisorId` | identifier | Exactly one active supervisor belongs to a committed session generation |

### Session Transitions

```text
none
  -> selecting
  -> active
  -> invalidating -> selecting   (device or transport change)
  -> invalidating -> disconnected
  -> none
```

Every transition away from `active` increments generation and requests cancellation of all active
operations. Late completions still undergo token validation and become stale.

## ConnectionSupervisor

Owns health and recovery for one committed `ConnectionSession`; it never owns device selection.

| Field | Type | Rules |
|-------|------|-------|
| `id` | identifier | Unique per supervisor instance |
| `sessionGeneration` | integer | Exact match required before publishing health or recovery |
| `state` | `starting | healthy | suspect | reconnecting | recovered | actionRequired | stopped` | `stopped` is terminal |
| `lastProbeStartedAt` | timestamp? | At most one health probe may be running |
| `lastHealthyAt` | timestamp? | Updated only after a target-specific command succeeds |
| `consecutiveFailures` | integer | Reset only by a successful target-specific command |
| `nextProbeAt` | timestamp? | Normal cadence; absent while stopped or blocked by an exclusive operation |
| `reconnectAttempt` | integer | Drives bounded backoff and resets after recovery |
| `knownEndpoints` | redacted list | Last verified endpoint plus current discovery candidates |
| `keepAliveLease` | `KeepAliveLease?` | Android managed-helper lease only; absence does not imply connection failure |
| `failure` | `OperationFailure?` | Required for action-required state |

Supervisor rules:

- A normal probe yields to an exclusive device operation and is rescheduled; it never queues behind it.
- Two consecutive bounded health failures invalidate the current transport generation before recovery.
- A recovered transport becomes active only after stable-identity verification and a real command.
- A healthy USB candidate cancels Wi-Fi recovery for new work; running operations never migrate.
- Stop cancels timers, discovery listeners, reconnect attempts, and the keep-alive lease.

## KeepAliveLease

| Field | Type | Rules |
|-------|------|-------|
| `leaseId` | random identifier | Bound to helper identity and active host session |
| `state` | `starting | active | expiring | stopped | failed` | Terminal after stopped/failed |
| `startedAt` | timestamp | Set after visible service acknowledgement |
| `renewedAt` | timestamp | Updated only by an authenticated host renewal |
| `expiresAt` | timestamp | Companion releases resources after expiry |
| `wifiLockHeld` | boolean | Diagnostic state, never assumed from service process presence |
| `notificationVisible` | boolean | Must be true while active on Android |

The lease reduces Android Wi-Fi radio sleep. It is not proof that ADB is healthy and never replaces
the supervisor's command probe.

## SessionToken

Immutable authorization for one operation result to publish.

| Field | Type | Rules |
|-------|------|-------|
| `deviceIdentity` | `DeviceIdentity` | Exact equality required |
| `transportId` | string | Exact equality required |
| `sessionGeneration` | integer | Exact equality required |
| `operationId` | UUID/random identifier | Must still be registered and non-terminal |

A result can commit only if all four fields match current repository state after the last asynchronous
boundary. Failure to match produces the terminal state `stale` with no user-data publication.

## DeviceCapability

| Field | Type | Rules |
|-------|------|-------|
| `kind` | `clipboardRead | clipboardWrite | flutterVm | screenshot | fileScopes | fileSend | fileReceive | memory` | Unique per device |
| `availability` | `available | helperRequired | actionRequired | restricted | offline | experimental | unsupported` | `available` is never inferred from a visible button |
| `reasonCode` | stable string | Required unless available |
| `message` | localized/user-facing string | Must describe actual condition |
| `recoveryAction` | named action? | Never performs privileged or destructive work without explicit invocation |
| `checkedAt` | timestamp | Capability expires with its session or tool probe |
| `probeState` | `pending | probing | ready | terminal` | Each capability advances independently |
| `validationLevel` | `metadataOnly | commandVerified | userOperationVerified` | Automatic probes use metadata-only unless a non-content command can verify more |

## DeviceOperation

Common lifecycle for discovery-independent user commands.

| Field | Type | Rules |
|-------|------|-------|
| `id` | operation ID | Unique in the app session |
| `type` | `clipboardRead | clipboardWrite | screenshot | fileSend | fileReceive | memorySample` | Immutable |
| `token` | `SessionToken` | Captured before crossing the adapter boundary |
| `state` | `queued | running | succeeded | failed | cancelled | disconnected | stale` | Terminal states do not transition |
| `createdAt` | timestamp | Immutable |
| `startedAt` | timestamp? | Set once |
| `finishedAt` | timestamp? | Required for terminal state |
| `deadline` | timestamp | Required |
| `progress` | `OperationProgress` | Determinate or indeterminate |
| `failure` | `OperationFailure?` | Required for failed/disconnected; optional recovery for cancelled |
| `resultRef` | local reference? | Present only after validation and atomic publication |

### Operation Transitions

```text
queued -> running -> succeeded
                  -> failed
                  -> cancelled
                  -> disconnected
                  -> stale
queued -> cancelled
queued -> stale
```

Timeout maps to `failed` with reason code `timeout`. A user cancellation maps to `cancelled`.
Device loss maps to `disconnected`. Token mismatch always maps to `stale`.

## OperationProgress

| Field | Type | Rules |
|-------|------|-------|
| `mode` | `indeterminate | determinate` | Human CLI text is not parsed as determinate unless contract-tested |
| `completedBytes` | integer? | Non-negative and required for determinate byte transfer |
| `totalBytes` | integer? | Positive and not less than completed bytes |
| `phase` | `preparing | transferring | validating | publishing` | User-visible business phase |

## OperationFailure

| Field | Type | Rules |
|-------|------|-------|
| `code` | stable enum/string | Includes permissionDenied, timeout, cancelled, disconnected, malformedOutput, toolMissing, helperMissing, restricted, unsupported, integrityMismatch, and failure |
| `safeMessage` | string | Contains no payload, raw identity, or secret |
| `recoveryAction` | named action? | Optional |
| `diagnosticRef` | local redacted log reference? | Never contains clipboard/file/image bytes |

## ClipboardSnapshot

| Field | Type | Rules |
|-------|------|-------|
| `deviceIdentity` | identity | Must match the publishing token |
| `text` | string | Complete current text, maximum 1 MiB UTF-8; reject excess, never truncate |
| `capturedAt` | timestamp | Required |
| `sensitivity` | `normal | sensitiveSuspected` | Only affects preview/redaction behavior |
| `sessionGeneration` | integer | Snapshot is cleared or visibly invalidated on generation change |

Clipboard snapshots are never written to settings, history, or diagnostics.

## ReadinessProbe

Represents an automatic, non-content capability check.

| Field | Type | Rules |
|-------|------|-------|
| `id` | identifier | Unique within the session |
| `kind` | `clipboard | flutterVm | screenshot | fileScopes` | One active probe per kind |
| `sessionGeneration` | integer | Result is discarded on mismatch |
| `state` | `queued | running | succeeded | unavailable | actionRequired | failed | cancelled | stale` | Terminal except queued/running |
| `startedAt` / `finishedAt` | timestamps | Required according to lifecycle |
| `deadline` | timestamp | Bounded independently from other probes |
| `capabilityResult` | `DeviceCapability?` | Contains no clipboard, image, or file content |

Readiness probes may authenticate a helper, discover and handshake with a VM service, validate a
screenshot provider, or check predetermined file scopes. They cannot call clipboard read, create a
screenshot artifact, enumerate user files, or download bytes.

## Artifact

| Field | Type | Rules |
|-------|------|-------|
| `id` | artifact ID | Unique |
| `kind` | `screenshot | image | file` | Immutable |
| `sourceDevice` | identity | Required |
| `operationId` | operation ID | Required |
| `sessionPath` | absolute local path | Must reside in the current session directory until explicitly saved |
| `mediaType` | string? | Validated from bytes or known transfer metadata |
| `byteLength` | integer | Non-negative |
| `sha256` | string? | Required where both endpoints can support integrity validation |
| `createdAt` | timestamp | Required |
| `savedPath` | absolute user-selected path? | Set only after an explicit successful save |

A partial path is not an Artifact and cannot appear in success UI.

## TransferJob

Extends `DeviceOperation` with:

| Field | Type | Rules |
|-------|------|-------|
| `direction` | `hostToDevice | deviceToHost` | Immutable |
| `source` | scoped path descriptor | Must be user-selected or capability-approved |
| `destination` | scoped path descriptor | Must be user-selected or capability-approved |
| `expectedLength` | integer? | Used when known |
| `sourceHash` | SHA-256? | Never substitutes for destination verification |
| `destinationHash` | SHA-256? | Compared before publication when available |
| `partialPath` | path | Operation-specific; cleaned or clearly retained as partial after failure |

## TargetApplication

| Field | Type | Rules |
|-------|------|-------|
| `deviceIdentity` | identity | Must match active session |
| `applicationId` | package or bundle ID | Required |
| `displayName` | string | Display only |
| `processId` | integer? | Required for active monitoring |
| `processStartIdentity` | string? | Used with PID to detect restart when available |
| `debuggable` | bool/unknown | Controls private file and VM capabilities |
| `vmServiceUri` | secret URI? | Kept in memory, redacted from logs |
| `state` | `running | stopped | restarted | unavailable` | Monitoring requires running |

## Flutter VM candidate and verified binding (T110–T114, partially implemented)

`VMCandidate` is unverified: its in-memory secret URI, discovery source and optional process hints
must not supply a device label to a memory sample. User-entered loopback URIs begin in this state.

`VerifiedVMBinding` captures the selected `SessionToken`, exact device identity, verified transport
and forwarding resource owner, application bundle/package ID, independently correlated PID and
process-start identity when available, plus the in-memory endpoint. A trusted device route and
process correlation are required; a self-reported name/PID/URI is insufficient. Failure to establish
that proof leaves the candidate unverified and sampling disabled for the selected device.

For the initial iOS HTTP path, the transport owner is one persistent exact-device USB connection,
not a reusable host URL. Store VM `startTime` milliseconds separately from optional OS process-start
identity; missing OS metadata must never be fabricated from the VM timestamp. The binding also pins
the selected isolate ID and observed protocol version. Only the qualified discovery issuer can
construct a binding; consumers cannot promote a candidate by supplying a PID. Owner closure,
identity change or isolate replacement makes the binding terminal and closes its series. A new
connection requires a new binding even if its PID, port or URI happens to match the previous one.

Qualification finding: Dart 3.7.2 recalculates VM startTime on each getVM; native physical observations
varied by 1 ms with unchanged PID on one stream. `IOSVMMetadataChannel` now owns a tested non-drifting
total-range bound of 1 ms, with fixed PID and pinned isolate on one non-replaceable transport. Its
Metadata is not a verified binding or an opaque process-instance token. The issuer must
add independent app/device/session correlation and never reuse this continuity state across owners.
`IOSFlutterVMDiscovery.verify` now supplies independent app/device/session correlation, issuing an
`IOSVerifiedVMBinding` with immutable session/app/isolate fields and a unique owner UUID. Its private
channel never transfers or reconnects. Admission and renewal tests cover wrong/same-PID devices,
changed app identity, stale generations, cancellation and terminal closure. Production app-scoped
discovery returns this owner through at most four bounded hints. Workspace now captures a discovery
session and app-selection revision, commits the returned owner after complete session/target checks,
and derives iOS readiness from that reference. Binding qualification
and renewal stay metadata-only; a separate explicit `readMemory()` now returns a validated one-shot
sample from its private channel. It checks the current store after every RPC, independent app/PID
after usage and final same-owner continuity before return. The owner now directly conforms to
MemorySampling and rejects any target/transport other than its committed pair. Terminal binding
failure maps to `invalidated`, clears Core monitoring history and ends the loop. MemoryMonitor owns
its start/stop revision; DeviceSessionStore consumes operation eligibility atomically at completion.
Workspace explicitly consumes the owner for monitoring. Idle renewal is metadata-only; Stop and
stale/invalidated events synchronously revoke its reference/readiness before asynchronous cleanup.

The discovery/forwarding owner creates the candidate and owns its resources. Workspace commits a
verified binding only after checking its captured session across every asynchronous boundary.
Device, route, process or generation replacement invalidates the binding before cleanup; old
callbacks cannot restore it. URI/nonce values are never persisted or included in diagnostics.
See [the iOS memory contract](contracts/ios-vm-memory.md).

## MemorySample

| Field | Type | Rules |
|-------|------|-------|
| `deviceIdentity` | identity | Must match token |
| `applicationId` | string | Required |
| `processId` | integer | Required |
| `processStartIdentity` | string? | A change terminates the old series |
| `capturedAt` | timestamp | Monotonic within a series |
| `source` | `androidMeminfo | flutterVmService` | Determines metric semantics |
| `rssBytes` | integer? | Missing is unavailable, never zero-filled |
| `pssBytes` | integer? | Android only when reported |
| `heapUsedBytes` | integer? | VM Service only when reported |
| `externalBytes` | integer? | VM Service only when reported |

Only a bounded in-memory window is retained. A device, process, or generation change closes the
current series before new samples can publish.

## HelperRequest

| Field | Type | Rules |
|-------|------|-------|
| `protocolVersion` | integer | MVP accepts exactly version 1 |
| `requestId` | random identifier | Single use |
| `sessionNonce` | random secret | Must match the active host-helper channel |
| `helperDeviceId` | helper-scoped GUID | Must match the selected device correlation |
| `action` | `identity | clipboardRead | clipboardWrite | pickFile | pickImage | hashFile | keepAliveStart | keepAliveRenew | keepAliveStop | keepAliveStatus` | Allow-list only |
| `createdAt` / `expiresAt` | timestamps | Reject expired or implausibly future requests |
| `payload` | action-specific object | Size-limited; never logged |

## HelperResult

| Field | Type | Rules |
|-------|------|-------|
| `protocolVersion` | integer | Matches request |
| `requestId` | identifier | Exact match |
| `status` | `success | permissionDenied | cancelled | expired | invalid | failure` | No ambiguous success |
| `payload` | action-specific object? | Present only on success |
| `error` | safe error? | Required on non-success |
| `completedAt` | timestamp | Required |

See [contracts/companion-protocol.md](contracts/companion-protocol.md) for transport and payload rules.
