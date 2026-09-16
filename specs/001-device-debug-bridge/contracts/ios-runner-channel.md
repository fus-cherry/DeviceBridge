# iOS Runner Channel Contract

Date: 2026-09-08
Status: selected-USB bootstrap, real screenshot/Workspace capture-save-Stop and 40-second heartbeat
passed on the personal-signed phone. Positive clipboard evidence now includes normal WRITE/READ,
authorized cross-App paste, exact 1 MiB UTF-8 Workspace round trip, and actual multi-item reading
including an empty item and ordering. Workspace binds clipboard and screenshot capabilities to
the same authenticated selected launch. Foreground admission requires UIKit active and exact
XCTest foreground; post-read settlement is owner/deadline/cancellation bounded and never approves
an OS prompt. The screenshot provider and eight baseline adverse transfers are verified.
Authenticated Stop during an observed real paste prompt also passed: the READ was still pending,
no permission tap occurred, and Stop acknowledgement/read suppression/channel invalidation
completed within five seconds, followed by clean signed-phone exit.
Physical denial/locked/protected-screen, wireless and full visible Mac UI acceptance remain open.
Earlier possibly-empty READ runs remain protocol/lease evidence only. Current evidence is in
`validation/us2-clipboard.md` and `validation/us3-screenshot.md`; historical experiment decisions follow.
Requirements: FR-003/005/009/011/024/031/033/035; SC-004/005/012/014/015/017.

## Architecture correction — 2026-09-16

The shared screenshot/clipboard process described in the historical sections below is superseded.
The production design has two independent selected-USB channels:

- `dev.debugutility.DeviceBridgeHost` is an otherwise empty UI-test target. Its XCUITest Runner owns
  screenshots and device information on device port 49872 and remains in the background.
- `dev.debugutility.DeviceBridgeClipboardHost` is an ordinary app that owns clipboard read/write on
  device port 49873. It is launched or activated only by an explicit clipboard operation.
- Each channel has its own manager, preparation presentation, heartbeat task, invalidation and cleanup.
  One cannot publish, clear or overwrite the other's readiness.
- The four signed artifacts (Runner app, nested XCTest bundle, screenshot Host and clipboard Host) are
  resolved from one immutable build snapshot and verified against their distinct bundle identifiers.

Physical iPhone 12 evidence confirms exact clipboard round trips, background screenshot capture while
a representative business app remains foreground, independent failure presentation, and bounded Stop.
Locked/protected screens and wireless transport remain open. No automatic application restoration is
claimed.

## Evidence and Transport Decision

Installed `xcrun devicectl device --help` exposes copy, info, install, notification, orientation,
process, reboot, sysdiagnose, and uninstall. It has no general TCP tunnel or port-forward command.
Its copy command supports app containers; notification post supports Darwin notification names.
Neither proves an in-memory request channel to a persistent XCUITest process.

The next experiment is a runner-owned loopback socket reached through USB usbmux. Pin upstream
libusbmuxd evidence to commit `93eb168bf6b07472d17781328c21df0c60300524`:
[protocol header](https://github.com/libimobiledevice/libusbmuxd/blob/93eb168bf6b07472d17781328c21df0c60300524/include/usbmuxd-proto.h),
[ListDevices/Connect client](https://github.com/libimobiledevice/libusbmuxd/blob/93eb168bf6b07472d17781328c21df0c60300524/src/libusbmuxd.c),
[iproxy routing](https://github.com/libimobiledevice/libusbmuxd/blob/93eb168bf6b07472d17781328c21df0c60300524/tools/iproxy.c).
Important correction: `iproxy --network` connects directly to the device's LAN address and port;
only its USB branch uses `usbmuxd_connect`. A host loopback listener does not imply a device-loopback
tunnel over Wi-Fi. This candidate therefore does NOT establish the required wireless route.
Do not broaden the runner listener to the LAN to work around that gap.

A standard-library host probe can use the existing `/var/run/usbmuxd` socket without installing
a proxy: bounded version-1 plist frames, `ListDevices`, exact serial/ConnectionType selection, then
`Connect` with that DeviceID and network-byte-order port. Validate size/type/tag and deadlines.
This is a candidate implementation, not proof that a persistent XCTest socket can be reached.

Apple's [test runner environment reference](https://developer.apple.com/documentation/xcode/environment-variable-reference)
and installed `man xcodebuild` document stripping the `TEST_RUNNER_` prefix. They do not guarantee
that Xcode avoids serializing the resulting environment into diagnostics or launch artifacts.
A non-secret-canary audit has now run on the reference iPhone: all three runs persisted the marker
in the xcresult action log's `commandInvocationDetails.commandDetails`. Therefore this mechanism
is **NO-GO for real secrets**, even though the authored `.xctestrun` and captured stdout were clean.
Do not pass nonces/content/VM URIs through the test runner environment. Later log deletion/redaction
does not cure persistence. See [physical evidence](../validation/ios-channel-spike.md).

T082 must pin the tested source/version and decide whether a bundled proxy/library is needed.
Do not add an end-user Homebrew command, install a tool automatically, or silently substitute Wi-Fi
when USB was selected. Inventory continues to use CoreDevice; a socket alone does not prove health.
The exact UDID and selected transport must match both inventory sources or readiness stays blocked.

Container mailboxes are not the content transport: writing clipboard values or session nonces into
files conflicts with the in-memory clipboard/nonce contract. Darwin notifications may be wake hints
only and must never contain secrets. A public LAN listener is outside this design.

### Revised authenticated bootstrap candidate (T082, bounded physical TLS proof obtained)

The next identity-only experiment uses **public app-container metadata** and system TLS 1.3
with mutually pinned ephemeral certificates. This replaces secret environment bootstrap; it is not an exception
allowing secrets or encrypted content in files. CoreDevice `info files` successfully addressed the
exact installed runner's `appDataContainer` on the designated paired phone. Exact public-file copy,
mutual TLS 1.3 exchange and bounded lifecycle cases have passed physically; production launch
ownership, actual session-nonce handshake and complete adversarial cases remain before enablement.

1. Host owns a fresh launch UUID and P256 signing private key in memory. Only its public certificate, public launch
   UUID and expected protocol/build identifiers enter the signed XCTest launch environment.
2. The signed runner generates its own private key in memory and atomically writes a bounded public
   JSON record to `Documents/DeviceBridgeBootstrap/<launch-UUID>.json` in its private app container.
   Record fields are version, launch UUID, host certificate digest, runner certificate and helper build identifier only.
   No private key, session key, session nonce, VM URI or content may be encoded or written.
3. Host copies only that exact path from the captured UDID and exact runner bundle's appDataContainer.
   Check the command's target/domain, current attempt/child lifetime, bounded schema, exact launch,
   host certificate digest and build before pinning the runner certificate once. No directory search, latest-file lookup,
   output-marker parser or network-provided replacement key. Invalid/stale metadata fails closed.
4. Both peers construct a fresh one-hour self-signed P256 certificate using Apple's swift-certificates
   package and an in-memory SecIdentityCreate identity. No SecItemAdd, Keychain import, developer
   certificate issuance or private-key serialization. Self-signing is structure, not a trust root.
5. Network/Security TLS 1.3 owns mutual key confirmation and bidirectional authenticated records.
   Require peer authentication explicitly on both sides (server default is false), and verify only
   the actual leaf DER against the immutable peer pin. Disable early data, tickets, resumption and
   anonymous/version fallback. No application
   readiness or content before TLS and selected-device identity confirmation both succeed.
6. Because public NWConnection does not accept a usbmux descriptor, an attempt-owned host loopback
   proxy may relay **TLS ciphertext only** to the exact USB socket. It owns one client, bounded
   buffers/deadlines and cleanup, never private keys or plaintext. The phone binds loopback only.
7. On failure/stop/expiry, invalidate the attempt before closing channel/process/proxy and remove
   its public record. A crash may leave public metadata, but it cannot authorize a new launch.
   Certificate validity fields do not enforce connection expiry under exact pin verification.
   The experimental 90-second deadline is scheduled on its owning queue; blocking OS/file I/O
   can delay cleanup, so the external harness also bounds waits and terminates its owned children.
   T083 must enforce production child deadlines independently of channel-queue responsiveness.

Trust assumptions: local Mac/Xcode/signing identity and the installed exact signed runner are trusted;
other device app containers and unauthenticated local/network peers are not. CoreDevice container
selection is a trusted namespace boundary, not independent cryptographic code attestation. T083 must
preserve exact signed build-product installation ownership. A matching stdout marker alone is not
accepted as app identity. Test wrong device/bundle/build/launch/host certificate, stale/late copy,
wrong/missing client or server certificates, expected certificate only later in a chain,
truncated handshake, replay/restart, ciphertext alteration and resource cleanup before qualification.

Rejected candidate: Apple's external-PSK Network path does not support TLS 1.3. The real local
matching-key probe failed with server error -9816; a negative-key failure alone was not evidence
of authenticated success. Keep `test_tls_psk.py` as an explicitly opt-in feasibility diagnostic.
Do not downgrade to TLS 1.2. See [Apple TN3213](https://developer.apple.com/documentation/technotes/tn3213-moving-from-multipeer-connectivity-to-network-framework).

Research: [in-memory SecIdentityCreate](https://developer.apple.com/documentation/security/secidentitycreate%28_%3A_%3A_%3A%29),
[required peer authentication](https://developer.apple.com/documentation/security/sec_protocol_options_set_peer_authentication_required%28_%3A_%3A%29),
[Apple swift-certificates](https://github.com/apple/swift-certificates).
Independent review rejected reciprocal HPKE as an unnecessary application record protocol when
both public keys are already pinned; TLS provides the established handshake/record layer.

## Production Path and State Ownership

1. Workspace captures the selected session token and asks `IOSRunnerManager.prepare` to prepare its
   device. Workspace integration must stop the manager on every transport/generation replacement,
   including reconnection to the same UDID; manager device caching is not a session-token check.
2. The manager reserves one `IOSRunnerLaunch(id, deviceIdentifier)` before any suspension. It owns
   readiness and rejects a concurrent prepare with a non-success outcome. A prior connected launch
   is disposed by its own ID before building the replacement.
3. A manager-owned cancellable task builds the compatible runner. The concrete build stage must use
   an attempt-owned DerivedData directory and explicit build products rather than a shared latest
   result. T083 must pass the exact `.xctestrun` product to `test-without-building` and track its child
   process; the concrete launcher does not yet implement this verified artifact-to-process handoff.
   The manager now reserves an immutable `IOSRunnerBuildProducts` value under a launch-UUID directory,
   captures the selected signing Team in that descriptor, passes that same directory to Debug
   `xcodebuild -derivedDataPath`, and hands it to the launcher
   interface only after the existing current-launch guard. Default builds no longer request portal
   provisioning updates. This is path ownership, not yet validation of product files or installed code.
   The concrete launcher must reject launch mismatches and resolve/verify only that exact products
   directory; artifact cleanup and immutable signed-product reuse are still T083 work.
   The structural resolver supports the observed Xcode format-1 configuration only, rejects extra
   targets or paths outside the exact expected Debug products, and forces both attachment lifetimes
   to `keepNever`. A structurally resolved configuration is not signed or installed evidence.
   `IOSRunnerSignedArtifacts.load` combines exact configuration resolution with offline signature
   verification of the Runner, nested tests and Host, rejecting escaped product symlinks and wrong
   Team/bundle requirements. This is local preflight only, not installation/readiness or a lock
   preventing later filesystem mutation. The concrete launch owner must retain exclusive build use.

4. The launcher owns processes and sockets keyed by launch ID. It installs/starts the selected runner
   and opens only the captured route. Startup has a 60-second deadline after build; trust/signing
   failures use safe local messages. The build deadline is 300 seconds.
5. A content-free handshake verifies protocol, launch identity, helper identity, and session nonce.
   `installStartAndOpen` returns a channel only after this succeeds. T082 must demonstrate secure nonce
   bootstrap through the selected trusted connection without logging or persisting the nonce; a
   self-asserted device identifier is insufficient authentication.
6. The manager rechecks attempt ownership and cancellation after every external await, then commits
   its channel and `connected` state. Workspace separately rechecks its captured session token before
   publishing capability readiness. This is the sole user-visible readiness commit.
7. Content requests require an explicit action. Every response is bound to launch and request IDs;
   workspace/operation services recheck their session token before publishing data.
8. Stop clears manager ownership/readiness and cancels the build/start task before awaiting launcher
   cleanup. Cleanup addresses the exact attempt, is bounded and idempotent, and can be called again
   when an interrupted open returns late. A late success/failure/cleanup cannot alter a newer launch.

`IOSRunnerManager` owns the candidate/current launch and preparation task. The launcher owns external
resources only; it cannot publish workspace state. No feature service installs or starts runners.

The concrete launcher orchestration is now implemented with required `IOSRunnerChannelPreparing`
injection and **no default channel factory**. It is not wired into workspace readiness. Its production
defaults load locally verified artifacts and start the native child; authenticated open remains T084.
It reserves an attempt before asynchronous validation, bounds the wait for read-only validation, and
rejects late/cancelled results before creating resources. Each attempt progresses through preparing,
opening, connected and stopping; stopping invalidates readiness before cleanup awaits. Failed removal
of the exact generated startup directory retains that stopping attempt for cleanup retry.

Startup writes only the verified configuration and public certificate/launch bootstrap, exclusively
creates `DeviceBridgeLaunch` under its attempt directory, and starts only `testManagedChannel` from
the captured `.xctestrun` without rebuilding or provisioning. That phone entry point and real channel
factory are intentionally still absent until T084. A connected result requires authenticated open,
live child, current attempt and unexpired startup deadline. Maximum runner lifetime is an explicit
constructor policy input; no production default or uptime claim is chosen by this fixture slice.

The native `IOSRunnerProcess` uses a fresh POSIX process group and closed inherited descriptors.
Its actor owns PID, deadlines, stop escalation and exit publication; it observes the unreaped leader
with `waitid(WNOWAIT)`, signals only that reserved group, then reaps. TERM grace applies while the
leader lives; leader exit triggers immediate remaining-group cleanup, not a descendant flush window.
Kernel-stalled exits and abrupt parent death are not claimed to have hard host-process cleanup bounds.
No global process search or termination is permitted. See Apple's
[spawn-group contract](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man3/posix_spawnattr_getpgroup.3.html).

The native USB relay preserves independent EOF/write-close directions, with one teardown deadline
that later callbacks cannot extend. It reports clean only after both error-free completion barriers;
this is not application delivery acknowledgement. Its USB read inactivity deadline is 35 seconds,
allowing the runner's 30-second idle lease to close first. `readChunk` accepts finite deadlines up to
60 seconds for this layering margin; connect, write and the legacy full-close read retain their
30-second maximum. Real read errors/timeouts still close the stream and fail the relay. No timeout
is converted into clean EOF. The phone lease remains 30 seconds, with metadata heartbeat every 10.

### T083 local signature versus device authorization boundary

Use macOS `SecStaticCodeCheckValidity` on each Runner app, nested XCTest bundle and Host app,
with strict/resources/nested/all-architecture checking, certificate expiration consideration and
no network access. An external requirement must constrain `anchor apple generic`, the selected
Team's leaf OU and the expected signing identifier; validate requirement inputs first. Merely
creating a code handle or reading signing metadata is not a signature check. Offline validation
does not establish current online revocation status, and build ownership must prevent mutation
between validation and installation.

Profile CMS/plist parsing is **metadata preflight only**, not Apple device authorization. Modern
systems use DER-Encoded-Profile as the authority, and the plist is not a stable authorization API.
If inspecting it, bind expiry, device, team, signing certificate and permitted App ID carefully;
App ID prefix is not necessarily Team ID. Runner/Host apps own profiles; do not require a separate
profile for their nested XCTest bundle. Actual native installation, startup and authenticated identity
on the designated device remain mandatory. No profile preflight may publish readiness.

Sources: [Apple static code validation](https://developer.apple.com/documentation/security/secstaticcodecheckvalidity%28_%3A_%3A_%3A%29),
[requirements](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements/),
[profiles](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles),
[App ID prefixes](https://developer.apple.com/library/archive/qa/qa1879/_index.html).

## Proposed Wire Contract (T084)

- Carry the version-1 envelopes from `companion-protocol.md` over one authenticated byte stream.
  Control frames use a four-byte big-endian length and at most 6 MiB + 64 KiB UTF-8 JSON. Reject impossible
  lengths before allocation; partial reads do not count as complete frames.
- Serialize content requests and frame writes per channel; permit identity/stop while one content
  request is pending. Allow identity, clipboard.read, clipboard.write,
  screenshot.capture, and stop only. Reject replay, wrong nonce/device/version, unsupported actions,
  expiry, and malformed envelopes before invoking UIKit/XCTest.
- Handshake uses a fresh random challenge in addition to the nonce; authenticate the reply and its
  helper version/allowed actions before `connected`. Nonces, endpoints and identifiers are redacted.
  The first `identity` envelope addresses `helperDeviceId=bootstrap` and carries exactly
  `launchId` and `challenge` in its payload. The host generates independent 32-byte random nonce
  and challenge values in memory, encoded as canonical base64; neither enters launch metadata.
  A successful reply binds its request ID and exact `launchId`, `sessionNonce`, `challenge`,
  `helperDeviceId`, `helperVersion`, and unique `allowedActions`. The launch UUID is the opaque
  helper ID for this attempt; exact physical-device attribution still comes from the signed
  container/USB route, not from treating the UUID as a hardware identity.
  Supported actions are the iOS allowlist above, and the host requires its requested subset.
  The identity-only diagnostic advertises only `identity` and `stop`; it cannot claim content
  capabilities. Version-1 ISO8601 timestamps have whole-second precision, so host handshake timeout
  is a whole number of seconds in `2...30`. Both wire timestamps use that precision and the single
  monotonic host deadline derives from the same expiry (up to less than one second shorter than
  the requested upper bound). Runner rechecks request expiry after reply writing before returning
  a session. The outer channel owner must still recheck current launch/generation after the await.
- The initial managed metadata slice uses `IOSRunnerChannelFactory` to create one fresh host
  identity and exact-container/USB endpoint. `IOSRunnerChannel` owns opening work, TLS and cached
  authenticated context; it commits only after handshake plus a live-child check. Close invalidates
  its phase before resource cleanup. A cached context is not a fresh liveness probe. If an injected
  child-status observer never returns, close still invalidates/releases acquired resources, but
  the original open task needs that observer to return; the outer launcher independently bounds
  startup and the native process owner bounds the real child.
  Current sends admit one clipboard operation, one identity and one Stop, with a single writer
  and correlated reader. A second content request fails locally without replacing the first.
  Host-side CoreDevice activation must finish before queuing content; metadata/Stop bypass that
  preparation. Stop removes unsent work and its timers so obsolete expiry cannot preempt its ACK.
  CoreDevice timeout arguments are integer seconds; the native owner independently enforces the
  original absolute activation deadline. The phone handler polls foreground for at most two seconds
  within the request budget, because command exit precedes visible activation. Both the exact
  XCTest runner foreground state and `UIApplication.applicationState == .active` are required;
  the former alone was observed while UIKit remained inactive and clipboard reads falsely looked
  empty. The bounded poll yields MainActor so UIKit can deliver the activation transition.
  It never activates
  or approves prompts itself and rechecks foreground/cancellation/expiry before access and publication.
  `receive` validates, removes pending and resumes its continuation without suspension: this is
  the completion commit point. A later Stop/close does not retract an already committed result;
  UI consumers must still check their captured session/generation. Caller cancellation requests
  terminal close cooperatively; `Task.cancel()` is not a synchronous no-more-network-writes barrier.
  Awaited `close()` invalidates unsent preparation, and uncertain writes are never replayed.
- `IOSRunnerSessionServer` admits identity/stop by default. An explicitly supplied
  `IOSRunnerClipboardHandling` additionally advertises clipboard read/write; an explicit
  `IOSRunnerScreenshotHandling` advertises screenshot capture. The signed production phone entry now
  supplies both platform handlers. Mac UI readiness remains gated until physical
  content qualification and T036. One run task owns deadlines, replay admission, the
  active content slot and every result/chunk write. One read task feeds the bounded four-slot inbox;
  one content task plus its expiry timer may coexist. Metadata bypasses a blocked content task.
  Results and expiry events are correlated to the active request ID and revalidated before/after
  writes. Read deadlines depend only on lease/max, so completed content cannot leave a stale
  content deadline on the pending read. Stop cancels the content operation at admission, before
  acknowledgement; errors cancel content before cleanup awaits. No task-value join is used for a
  blocked accessor, and cancellation callbacks must not block (Task.cancel invokes them
  synchronously). UIKit adapters must check cancellation immediately before side effects; a setter
  already started cannot be assumed rolled back. The bootstrap request ID is in the replay ledger.
  The ledger never evicts IDs and
  fails closed at 1024 total IDs. This bounded first implementation requires session replacement
  before that limit for long-running use; it does not qualify indefinite continuous debugging.
  Every full valid identity reply must finish before the old lease and request deadlines before
  it can renew the lease. Partial frames, invalid messages and delayed replies cannot renew it.
  Maximum runner lifetime is an explicit host policy, carried only as public duration metadata
  (`DEVICEBRIDGE_PUBLIC_MAXIMUM_LIFETIME`); the phone accepts positive finite durations up to 24 hours.
  The phone entry captures one absolute local deadline and passes that same instant into the
  session server while keeping its entry cleanup timer alive; executor delay cannot re-anchor it.
  No production Workspace default or automatic replacement policy is selected by these primitives.
- Clipboard values stay in memory with the shared 1 MiB UTF-8 text and envelope byte limits.
  A large Unicode value that exceeds the byte limit fails explicitly; never truncate it.
  The system accessor retains its foreground await, then invokes a synchronous setter/readback
  boundary with the original cancellation/deadline checks. Its internal write receipt identifies
  the setter's expected revision, never a later observed writer's revision. This supports a separate
  opt-in preserving physical probe, not a production rollback promise. That probe's 28 named-board
  fixtures pass; its actual general WRITE failed acknowledgement, and later read-only audits found
  no complete item backup. General WRITE/restoration is still unqualified (see US2 validation).
- Screenshot results use metadata plus a length-delimited binary PNG attachment (maximum 64 MiB),
  bound to the request ID with byte length and SHA-256. Do not base64 a full screenshot into the
  bounded control envelope. Read into an operation-scoped host partial file and publish only after
  integrity, PNG and session checks; a missing attachment cannot produce success.
  The successful control payload has exactly `mediaType: "image/png"`, integral `byteLength` and
  lowercase `sha256`; `completedAt` supplies capture time. It is a candidate receipt, not host
  completion. Subsequent payloads use magic bytes `44 42 50 4e 47 01`, 16 raw request-UUID bytes,
  an eight-byte unsigned big-endian offset, then 1–65,536 PNG bytes. Each payload retains the
  existing four-byte TLS-frame length prefix. Offsets must be contiguous from zero, the request ID
  must match the sole pending content receipt, and total bytes must match the descriptor exactly.
  Control JSON and binary chunks share one reader/writer pair. The sender advances one chunk per
  owner-loop event so queued identity/Stop work can interleave; no second content request overlaps.
  The receiver owns one private temporary directory per receipt, removes partial bytes on close,
  expiry, malformed/truncated chunks or failed validation, and returns bytes only after exact
  length/hash and PNG decoding checks. PNG dimensions are capped at 100 million pixels before
  decode, matching the existing image-library safety limit. This paragraph specifies the current
  T084 implementation. Both the direct channel and its selected-transport provider passed real
  selected-USB screenshot/lease/Stop runs. Eight whole-channel cases reject missing/duplicate descriptors, missing/truncated images,
  wrong digest/offset/request and attachment expiry. Locked/protected-screen behavior and other
  physical fault schedules still require qualification.
- Content deadlines are 30 seconds, excluding explicit user permission waiting. Cancellation closes
  the affected channel if an in-flight request cannot be safely cancelled; no automatic replay of a
  clipboard write. Reconnect starts a fresh nonce, launch and workspace generation.
  The current optional dispatcher enforces a 30-second absolute content bound and does not yet
  implement a permission-wait extension. That user-permission workflow remains a clipboard integration gate;
  independently qualified screenshot plumbing may be integrated without exposing clipboard commands
  (2026-09-08 dependency correction under constitution permission isolation and FR-023).
  do not silently suspend a deadline or automatically approve a phone prompt.
- The runner exits after a 30-second unrenewed host lease or explicit Stop. A metadata heartbeat every
  10 seconds renews the lease and never reads clipboard/screens/files. Long or permission-blocked
  operations must not prevent lease processing. This is cleanup policy, not an iOS uptime promise.
- Failed startup closes partial resources. User denial is terminal. Transport loss invalidates
  readiness; unknown tool/helper text is mapped to local messages, never echoed as diagnostics.

## Required Discriminating Evidence

T076/T077: stop during build/open, caller cancellation, concurrent prepare, late old build failure,
same-device replacement, slow cleanup, and partial-launch failure must be protected with gated tests.
Tests must be able to return after cancellation; cooperative mocks alone miss the resurrection bug.

T082: on a reference iPhone prove a persistent identity-only exchange using a runner loopback socket,
with USB and Wi-Fi tested separately; verify the actual route, nonce bootstrap, background lifetime,
restart, and no general LAN listener. Measure warm request latency. A simulator socket test cannot
qualify USB, pairing, developer signing or physical transport choice.
Current partial evidence: three signed physical USB runs pass public-marker exchange, bounded
Home-screen lifetime, Stop, idle lease expiry, rejection and port cleanup. The opt-in probe accepts
no production content and its public marker is not authentication. It does not close T082.

T083: fixture-test exact build-product handoff, signing denial, install failure, start timeout,
process exit, cancellation and per-attempt resource cleanup, then check a signed runner on device.
The user authorized the existing personal iOS development identity. Initial signed Debug build and
physical host-launch smoke passed using already cached profiles, without provisioning updates;
see [the experiment record](../validation/ios-channel-spike.md). This manual contributor preflight
does not close the concrete-launcher task. Never log the identity, Team, UDID or provisioning contents.

T084: split/coalesced frames, excessive size, replay, nonce/device mismatch, expiry, permissions,
screen attachment truncation/hash mismatch, orphan timeout, and response-after-stop tests must pass
before enabling content actions. Tests never use personal clipboard/screen/file data.

T036: integrate Settings signing selection, lifecycle recovery UI, capability handshake and
session-token invalidation. T041/T048 validate actual supported clipboard/screenshot operations.
No checkbox in this contract substitutes for those task results.
