# Phase 0 Research: Device Debug Bridge

## Build 6 closure decisions — 2026-09-08

- Decision: profile before introducing build reuse. Workspace creates a new manager on selection;
  IOSRunnerBuildProducts chooses a new UUID-derived directory and manager invokes build-for-testing.
  This proves repeated work, not its latency share. The ~45-second observation used a heartbeat
  timestamp and cannot identify the bottleneck. Alternatives rejected: weakening auth/expiry guards,
  using one mutable output directory, or claiming that existing warm screenshot latency measures startup.
- Decision: resolve historical UI failures against current readiness and module navigation. The
  recorded keyboard/memory failures occurred before the latest flow and do not prove a current bug.
  Use Computer Use plus deterministic model checks; no macOS XCTest/global input retry. An existing
  accessibility test expects "Refresh" while production labels the action "Refresh devices"; verify
  the current contract before correcting that test assertion.
- Decision: qualification evidence has an explicit scope/build/control/condition/outcome. Build 6's
  positive same-origin public roundtrip and ten screenshots are retained; cross-app original-source,
  denial/locked/disconnect, save/export and full UI coverage need their own observations.
- Decision: preserve local-only distribution until an existing Developer ID identity is supplied.
  Read-only `security find-identity -v -p codesigning` found one Apple Development identity and no
  Developer ID. A valid ad-hoc signature does not satisfy clean-Mac Gatekeeper/notarization acceptance.
- Decision: user-controlled adverse conditions, original source-app details and clean-host access are
  external test prerequisites. Record unavailable conditions precisely; do not manufacture denial,
  reset privacy settings or mark their acceptance complete from fixtures.

### Closure evidence updates

Build-only baseline measured 28.935 s. App-instance input reuse measured 31.128 s cold then
2.596/2.059 s warm; real signatures/configuration passed, full readiness remains unmeasured on the
candidate. Reject process-held locks across launches because orphan compiler descendants can outlive
parent locks. Gate build and immutable snapshot completion within one app-owned actor; rotate after
failure/cancellation. Use Xcode itself to validate source/toolchain/Team inputs every attempt.

Rendered file receive twice stalled in CoreDevice's bookmarkData/getxattr for the user-chosen partial
path; direct copies of the exact public file succeeded in under 0.2 s. Provider temporary staging now
keeps the external tool away from user-selected publication paths; 10 tests and a 64 KiB real provider
roundtrip pass, while new GUI confirmation awaits app replacement. No permission diagnosis or
permission changes were made. Current USB image identity matching remains an explicit reconnect
prerequisite. See the [current evidence matrix](validation/release-closure-20260908.md).

## Image-first decisions — 2026-09-07

Implementation refinement: cap originals with `adb exec-out head -c (expectedLength+1)`, verify source
metadata/SHA-256 before and after, then write only exact-length bytes. This avoids an uncapped pull
when the source grows. `exec-out` escapes operands itself, unlike `shell`; double escaping produced
135 bytes of error text in the real-phone test and was rejected by length validation. Raw operands
restored the 1,167,564-byte screenshot round-trip. This matches the
[AOSP command implementation](https://android.googlesource.com/platform/system/core/+/android-9.0.0_r18/adb/commandline.cpp).
The shared host runner now enforces its quota while collecting chunks rather than after readToEnd.

**Android decision:** use fixed shared-image sources over existing ADB before adding MediaStore
permissions or a photo helper. The reference phone reports Toybox `find -printf` with NUL fields,
size and modification timestamps. An opt-in probe found 135 image entries under Pictures and zero
under DCIM/Download. A real existing screenshot was pulled, decoded through ImageIO, and matched
source SHA-256/length. This proves a bounded shared-file route, not full MediaStore/album coverage.
See [phone-image evidence](validation/phone-images.md) and the [ADB file-copy contract](https://developer.android.com/tools/adb#copyfiles).

**Alternatives:** MediaStore in a managed helper provides indexed media/thumbnail access but requires
appropriate media authorization for other apps' images; a photo picker provides only selected media
and requires device interaction. Neither is necessary for the currently demonstrated directory slice.
They remain candidates only if direct ADB scope/performance proves insufficient, not silent fallbacks.
[Android shared-media guidance](https://developer.android.com/training/data-storage/shared/media).

**iOS decision:** isolate a public ImageCaptureCore USB-camera-import experiment from the unfinished
XCTest content channel. CoreDevice's file domains do not expose the system Photos library. Public
ICC APIs provide catalog callbacks, image thumbnails and downloads, but cross-framework device
identity equality is undocumented. Keep the provider experimental until exact identity association,
restriction behavior and original export are proven on the designated iPhone. Source:
[ImageCaptureCore](https://developer.apple.com/documentation/imagecapturecore),
[camera session](https://developer.apple.com/documentation/imagecapturecore/icdevice/requestopensession()),
[file download](https://developer.apple.com/documentation/imagecapturecore/iccamerafile/requestdownload(options:completion:)).

**Original-format constraint:** ICC's default media presentation can convert HEIF to JPEG. Use original
presentation where supported, while labelling rendered/edited representations honestly. Do not claim
all iCloud-only originals or iPhone wireless media access: neither is established by the public API
surface or this run. [Media presentation](https://developer.apple.com/documentation/imagecapturecore/iccameradevice/mediapresentation),
[Apple camera-import guide](https://support.apple.com/guide/image-capture/imgcp1003/mac).

**Presentation/performance decision:** list metadata first and read one selected original on demand;
derive thumbnail/preview locally and keep the exact bytes for export. This avoids a hidden full-library
download and bounds transfer/decode/cache work. Remote thumbnail optimization requires separate
evidence before adding a device helper. The first slice does not add a photo-write/delete workflow.

**Platform permission decision:** no Mac privacy grant, entitlement, helper install or input control
was performed. Before the iOS signed-app experiment, inspect its exact required authorization and
ask for any new authority. Framework documentation is not proof of prompt-free deployment.

## Environment Baseline

- Host: Apple Silicon macOS 26.6.
- Installed: Apple Swift 6.3.3, Xcode 26.6, `devicectl` 518.33, ADB 37.0.1,
  Flutter 3.29.2, Dart 3.7.2, CocoaPods 1.16.2, and Java 21.
- `xcodegen` and `tuist` are not installed, so the product must not introduce either as a build
  prerequisite.
- Read-only probes found at least one available Android device and one available iOS device, which
  makes real-device contract validation possible without recording their identifiers.
- The directory is not currently a Git repository. No branch or commit workflow is assumed.
- The existing Flutter controller/companion files are an abandoned scaffold. They remain untouched
  until migration is proven and their removal is explicitly authorized.

## Decision 1: One Mac Application, Native Host

**Decision**: Build the user-facing product as a native macOS application using SwiftUI with AppKit
bridges only where macOS-specific controls require them. Put state, parsers, process execution, and
device orchestration in a local Swift package consumed by the application target. The application is
the only product the developer launches.

**Rationale**: The product targets macOS only and needs native window lifecycle, child-process
management, Keychain, file panels, notifications, signing, hardened runtime, and direct distribution.
SwiftUI supplies the app lifecycle and can integrate AppKit without a cross-platform runtime. A local
Swift package keeps core behavior independently testable and prevents views from owning connection
state.

**Alternatives considered**:

- Flutter Desktop: fast for a Flutter team but adds a large runtime and platform-channel boundary to
  a macOS-only tool whose difficult work is native process and device orchestration.
- Electron: productive UI tooling but a larger runtime and no benefit for this native-only scope.
- Tauri/Rust: attractive if Windows/Linux becomes a requirement, but currently adds an unnecessary
  language and IPC boundary.

**Evidence**: Installed Swift/Xcode versions; [SwiftUI App](https://developer.apple.com/documentation/swiftui/app),
[SwiftUI](https://developer.apple.com/documentation/swiftui).

## Decision 2: Product-Managed Mobile Helpers

**Decision**: Mobile helpers are implementation components managed by the Mac application, not apps
that users install separately. Android uses a small native Kotlin APK. iOS uses a minimal signed
XCUITest runner for screenshot and clipboard operations that require an on-device process. The Mac
application detects versions, installs or updates compatible builds, starts them when allowed, and
surfaces any unavoidable trust, Developer Mode, signing, foreground, or permission action.

**Rationale**: Reliable clipboard access and Android Wi-Fi radio keep-alive require an on-device
process. iOS programmable screenshots of other apps require the UI-testing boundary. Hiding helper
lifecycle inside one Mac workflow matches the intended MobAI-style experience without pretending
platform security prompts can be bypassed.

**Alternatives considered**:

- A Flutter package added to every target project: provides deeper app-private integration but
  violates zero-project-modification baseline behavior and disappears when the target app stops.
- A separately launched companion app: simpler implementation but creates the setup burden the user
  explicitly rejected.
- No helper at all: cannot meet reliable clipboard or Android device-side Wi-Fi-lock requirements.

**Evidence**: [XCTest and XCUIAutomation](https://developer.apple.com/documentation/xctest),
[Developer Mode](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device).

## Decision 3: Android Discovery and Transport

**Decision**: Reuse the developer's installed ADB server. Combine bounded inventory refresh with
`adb track-devices` and `_adb-tls-connect._tcp` mDNS observations, target commands with
`-t <transport_id>`, and prefer a verified USB transport for new operations. Never kill or replace
the shared ADB server automatically.

**Rationale**: Flutter, Android Studio, and this tool must coexist with one ADB server. A transport ID
identifies a current route, while the helper's app-scoped identifier or an explicit user association
correlates USB and Wi-Fi candidates for the same physical device.

**Alternatives considered**:

- Bundle and own a second ADB server: risks port/version conflicts with existing developer tools.
- Merge candidates by name, model, or IP address: can combine different physical devices.
- Implement the ADB smart-socket protocol immediately: useful later, but unnecessary for the first
  vertical slice.

**Evidence**: Installed ADB 37.0.1; [Android ADB guide](https://developer.android.com/tools/adb),
[AOSP ADB command contract](https://android.googlesource.com/platform/packages/modules/adb/+/refs/heads/main/docs/user/adb.1.md).

## Decision 4: iOS Discovery and Transport

**Decision**: Use `xcrun devicectl list devices --json-output <temporary-file>` as the authoritative
iOS inventory for iOS 17+. Use UDID as stable identity. Treat observation streams only as refresh
hints. Prefer a healthy wired route and show wireless as a secondary transport.

**Rationale**: Installed `devicectl` explicitly provides file-based JSON for programmatic use and
reports pairing, availability, transport, lock, Developer Mode, app, process, and file-domain state.
Linking private CoreDevice frameworks would create avoidable compatibility and distribution risk.

**Alternatives considered**:

- Parse human-oriented stdout: not a stable contract.
- Use `flutter devices`: omits transport and CoreDevice capability detail.
- Adopt `go-ios` immediately: useful if CoreDevice gaps become blocking, but adds a second host
  runtime before the public tool boundary has been exhausted.

**Evidence**: Installed `devicectl` 518.33 and `xcrun devicectl help`;
[Xcode command-line tool reference](https://developer.apple.com/documentation/xcode/xcode-command-line-tool-reference).

## Decision 5: State Ownership and External Process Boundary

**Decision**: A `DeviceSessionStore` actor is the sole writer for inventory, selection, preferred
transport, session generation, capabilities, supervisor state, and current operations. One
`HostCommandRunning` implementation invokes absolute executable URLs with argument arrays, drains
stdout/stderr concurrently, limits output, enforces deadlines, and supports cancellation. Views
receive immutable snapshots on the main actor.

**Rationale**: Actor isolation matches Swift concurrency and prevents device-switch races. A complete
session token is checked after every suspension point before results or artifacts are committed.
Argument arrays avoid shell interpolation and make command behavior fixture-testable.

**Alternatives considered**:

- Let each SwiftUI view model own device state: creates multiple writers and stale publication paths.
- Run shell command strings: introduces quoting and injection risk.
- Start with a persistent daemon: there is no second consumer yet to justify another lifecycle.

**Evidence**: [Foundation Process executableURL](https://developer.apple.com/documentation/foundation/process/executableurl).

## Decision 6: Clipboard Exchange

**Decision**: Model clipboard as `available`, `helperRequired`, `actionRequired`, `restricted`, or
`unsupported`. Android uses an ADB-forwarded, nonce-bound local socket to the managed Kotlin helper.
iOS uses the managed XCUITest runner. Payloads are framed in memory and never placed in process
arguments, URLs, or logs. Automatic readiness performs only a helper handshake and never reads text.

**Rationale**: ADB and `devicectl` expose no supported system clipboard command. Android restricts
background clipboard reads, and iOS pasteboard access may require a foreground/privacy interaction.
The helper boundary is necessary, but content access remains an explicit user action.

**Alternatives considered**:

- Universal Clipboard: cannot target one selected device and has no controlling API.
- Android hidden Binder calls or accessibility/default-IME privilege: unstable or excessive.
- Polling clipboards: violates privacy and foreground behavior.

**Evidence**: [Android clipboard privacy](https://developer.android.com/develop/ui/views/touch-and-input/copy-paste),
[Apple UIPasteboard](https://developer.apple.com/documentation/uikit/uipasteboard).

## Decision 7: Screenshot Providers

**Decision**: Android captures PNG bytes with `adb -t <id> exec-out screencap -p`. iOS uses the
Mac-managed XCUITest runner and `XCUIScreen.main.screenshot()`. The capability remains
`helperRequired` or `actionRequired` until the runner is signed, installed, and command-ready.

**Rationale**: Android provides a direct public host command. Installed CoreDevice exposes no
screenshot subcommand, while XCUITest is Apple's programmable UI-testing boundary. Runner startup
cost is measured and shown honestly; a cold setup is not counted as a warm capture.

**Alternatives considered**:

- Optional `pymobiledevice3`: useful for experiments but adds Python, tunnel, and private-protocol
  versioning to the baseline.
- Automate Xcode's Device Hub UI: not a stable program contract.
- Capture from a normal iOS companion: cannot silently capture other applications.

**Evidence**: Installed `devicectl` help; [XCTest](https://developer.apple.com/documentation/xctest).

## Decision 8: Files and Images

**Decision**: Stage transfers to operation-specific partial paths, verify byte length and SHA-256
when both endpoints can report them, then publish atomically. Android uses shell-accessible shared
paths and `run-as` for debuggable packages. iOS uses supported CoreDevice temporary,
app-data-container, and app-group domains. The helper owns only a narrow inbox/outbox if a user-facing
selection flow is later required.

**Rationale**: Neither platform permits arbitrary browsing of another app's private storage. Explicit
domains and user-selected destinations meet the useful debugging scenarios without claiming root-like
access.

**Alternatives considered**:

- Expose the entire device filesystem: impossible on stock devices and violates least privilege.
- Route large files through the clipboard or VM service: wrong transport and excessive memory risk.
- Treat command exit alone as integrity proof: cannot detect all partial or wrong-destination results.

**Evidence**: [AOSP ADB push/pull contract](https://android.googlesource.com/platform/packages/modules/adb/+/refs/heads/main/docs/user/adb.1.md),
[Android app-specific storage](https://developer.android.com/training/data-storage/app-specific).

## Decision 9: Flutter VM and Application Memory

**Decision**: Discover Flutter debug/profile VM services through installed Flutter tooling and
forwarded ports, but speak the required VM Service JSON-RPC/WebSocket subset directly from Swift.
Android also provides coarse process memory with `dumpsys meminfo`. iOS release or protected
processes without an available VM service report unsupported.

**Rationale**: A project plugin is unnecessary for an exposed debug/profile VM service. A narrow
Swift client avoids embedding Dart solely for a handful of memory and isolate requests. VM service
URIs are in-memory secrets and are redacted from diagnostics.

**Alternatives considered**:

- Require a Flutter project package: violates the baseline and couples the tool to app code.
- Embed a Dart sidecar with `vm_service`: more complete protocol coverage but adds runtime and IPC.
- Parse Instruments traces as an always-on MVP gauge: heavy and schema-sensitive.

**Evidence**: [Flutter DevTools Memory view](https://docs.flutter.dev/tools/devtools/memory),
[Dart VM Service protocol](https://github.com/dart-lang/sdk/blob/main/runtime/vm/service/service.md).

## Decision 10: Android Wireless Supervision

**Decision**: The active session supervisor probes every five seconds when the transport is idle,
marks one failure suspect, invalidates after two consecutive failures, and reconnects the verified
physical device with bounded 1/2/4/8-second backoff using its known and rediscovered endpoints. A
healthy USB route cancels Wi-Fi recovery for new operations. The managed Android helper offers a
visible, stoppable foreground service with a non-reference-counted Wi-Fi lock and a lease renewed by
the Mac application.

**Rationale**: Host probes detect and repair ADB transport loss; the device Wi-Fi lock addresses radio
sleep. Neither alone is sufficient. A lease and persistent notification make battery cost visible and
prevent an orphaned helper from running indefinitely.

**Alternatives considered**:

- Repeated `adb shell true` without a state machine: cannot rediscover endpoints or reject stale work.
- `adb kill-server`: disrupts Flutter, Android Studio, and unrelated devices.
- Unbounded wake locks: unnecessary battery cost and poor failure cleanup.

**Evidence**: [Android wireless debugging](https://developer.android.com/tools/adb#connect-to-a-device-over-wi-fi-android-11),
[WifiLock](https://developer.android.com/reference/android/net/wifi/WifiManager.WifiLock),
[foreground-service types](https://developer.android.com/develop/background-work/services/fgs/service-types).

## Decision 11: Build, Storage, and Distribution

**Decision**: Use an Xcode macOS app target plus a local Swift package, an Android Gradle/Kotlin helper,
and an iOS XCUITest runner project. Avoid third-party host dependencies in the first slice. Store
artifacts in a per-launch temporary directory and persist only non-sensitive preferences and redacted
diagnostics. Target direct internal distribution, then Developer ID signing and notarization. The
developer workstation must have compatible Xcode and Android platform tools; the Mac app detects and
explains missing prerequisites.

**Rationale**: Xcode produces a normal `.app` archive and provides signing/notarization workflows.
Hardened runtime is required for Developer ID distribution; App Sandbox is optional for direct
distribution and is likely incompatible with unrestricted developer-tool process access unless
carefully scoped.

**Alternatives considered**:

- SwiftPM executable plus a hand-built `.app` wrapper: adequate for a spike but weaker for archive,
  entitlements, signing, and distribution.
- Mac App Store distribution: sandbox constraints conflict with the tool's intended local developer
  integrations.
- Persist operation payload history: violates session-only privacy expectations.

**Evidence**: [Preparing an app for distribution](https://developer.apple.com/documentation/xcode/preparing-your-app-for-distribution),
[creating distribution-signed macOS code](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac/).

## Decision 12: Test and Acceptance Strategy

**Decision**: Use Swift Testing for core unit and integration tests, XCTest for UI and iOS runner
tests, and Android unit/instrumentation tests for the helper. Protect parsers, state transitions,
transport preference, stale-result rejection, redaction, helper version negotiation, lease expiry,
integrity, and cancellation with deterministic fixtures. Add real-device USB and wireless contract
checks after each independently useful story.

Automatic readiness probes run independently and never read clipboard content, create screenshot
artifacts, enumerate user files, or download bytes. The 3-second clipboard target excludes time spent
responding to an operating-system prompt. The 5-second iOS screenshot target applies to a prepared,
command-ready runner; initial signing/install/startup is reported separately.

**Rationale**: Deterministic tests exercise race and malformed-output cases that are difficult to
reproduce manually, while real-device checks prove the external contracts. Modern Xcode projects can
use Swift Testing for unit/integration work and XCTest for UI automation.

**Alternatives considered**:

- Only manual testing: cannot reliably reproduce stale-result and cancellation races.
- Mock every boundary: misses real command schemas, signing, device state, and permission behavior.

**Evidence**: [Adding tests to an Xcode project](https://developer.apple.com/documentation/xcode/adding-tests-to-your-xcode-project),
[XCTest](https://developer.apple.com/documentation/xctest).

## Follow-up: iOS Channel Evidence (2026-09-07)

**Next bounded candidate after the canary failure**: Public-key pinning through the exact signed
runner's private app container, in-memory ephemeral P256 certificate identities, and mutual TLS 1.3.
The earlier external-PSK candidate was rejected: Apple TN3213 documents no TLS 1.3 support, and a
real matching-key local probe failed (-9816). No TLS version downgrade is authorized. Use the public
SecIdentityCreate API, not Keychain import, and require peer authentication explicitly on servers.
Independent review prefers this concrete namespace boundary to parsing aggregate XCTest stdout,
whose emitting application is not authenticated by a text marker. CoreDevice read-only access to
the exact runner appDataContainer passed. The full public metadata/copy and TLS path is pending.
Do not close T082 or carry content until its discriminating tests pass. See the revised bootstrap
section of [the contract](contracts/ios-runner-channel.md) for threat model, ownership and sources.

Public CoreDevice help was rechecked without contacting a device: it has no general TCP forwarding
command. App-container copy and Darwin notification commands exist, but clipboard/nonces cannot use
a persistent file mailbox under the chosen privacy contract. A runner loopback socket through usbmux
is now the next bounded USB experiment. The earlier inference from iproxy's network option is
superseded: its source connects directly to a LAN address, not through a paired loopback tunnel.
Pinned implementation evidence and the unresolved wireless gate are in the channel contract.

See [the channel contract](contracts/ios-runner-channel.md) for evidence links, lifecycle ownership,
wire limits and the T082 go/no-go experiment. Existing iOS command tests and abstract lifecycle tests
do not establish an installed, authenticated, persistent device channel. End-user dependencies remain
unchanged until that experiment and packaging checks pass.

### Decision: personal signing and transport preflight

**Decision**: Reuse the user's authorized existing Apple Development identity and local compatible
profiles for a Debug-only physical runner preflight. Do not install a new proxy or create certificates.
Use bounded system-usbmux protocol probes for USB research; wireless remains a separate unresolved
transport decision, not an automatic fallback.

**Rationale**: One usable development identity, an unexpired profile covering the designated phone,
an exact USB inventory match and a successful physical runner startup were verified locally. This
removes signing/startup as hypothetical prerequisites but does not prove persistent IPC. See
[physical evidence](validation/ios-channel-spike.md) and the pinned sources in
[the channel contract](contracts/ios-runner-channel.md).

**Alternatives considered**: Installing iproxy solely for USB inventory is unnecessary. Using its
network branch would require a reachable LAN listener and fails the current contract. A nonce in
`TEST_RUNNER_` is now explicitly rejected: three physical public-canary runs found the marker in
xcresult action logs, despite absence from the authored `.xctestrun` and captured stdout.

**Physical follow-up**: A dependency-free system-usbmux host probe and a signed XCTest loopback
listener exchanged correlated public markers on one USB socket for more than 35 seconds. Stop,
30-second idle expiry, unknown-action rejection, exact port cleanup and fresh launches passed.
This establishes bounded raw USB feasibility on the reference phone, not authentication, whole
lifecycle recovery, wireless support or a production clipboard/screenshot path. The experiment and
13 passing headless contract tests are recorded in [T082 evidence](validation/ios-channel-spike.md).

### Decision: restore iOS VM discovery and identity scope

**Decision**: Preserve completed Android discovery and shared VM RPC work under T061. Track iOS
candidate discovery, exact-device forwarding, process binding and workspace integration explicitly
as T110–T114; keep physical acceptance in T064. Reject attribution of an unverified manual endpoint.

**Rationale**: The current workspace auto-discovers only Android. Its manual URI path can create a
target with no PID/start identity and then label RPC samples with the selected iPhone's identity.
A loopback URI and `getVM` PID alone do not prove device ownership; PIDs can coincide across devices.
See [the binding contract](contracts/ios-vm-memory.md). VM transport need not run inside XCTest.

**Alternatives considered**: A mandatory Flutter plugin violates FR-035. Treating heap/external
metrics as total process memory is inaccurate. Treating the runner build or an arbitrary host VM
as iOS VM acceptance misses both the discovery path and the selected-device invariant.

### Decision: qualify direct persistent USB HTTP for iOS memory polling (2026-09-08)

**Decision**: Prefer a narrow native HTTP adapter owning one selected-device USB stream, gated by
framing, identity and lifecycle tests. Preserve Android WebSocket/DDS compatibility. This is a
design decision, not a claim that production iOS memory works.

**Rationale**: Two physical runs completed `getVM → getVersion → getVM` on one USB Connect with
chunked keep-alive responses, stable VM identity and independently matched device-app PID. The
qualified observation is Dart 3.7.2 / VM protocol 4.16. Explicit DDS metadata verification also
succeeded, but adds delegation and second-endpoint ownership not needed for polling. See
[the physical evidence](validation/ios-vm-discovery.md).

**Opposing evidence / limits**: HTTP transport is less fully specified than RPC schemas. DDS
takeover can send an event or close an in-flight HTTP client. Persistent TCP alone does not prove
app/process identity. Keep one non-reconnecting owner plus PID/start/isolate/session checks, reject
unexpected envelopes, and terminate on failure. No physical memory or wireless acceptance exists yet.

**Alternatives considered**: Automatic redirects lose route proof. Explicit device-originated DDS
delegation is a researched future option, not part of this initial adapter. Disabling DDS or modifying
the target project is not authorized. A loopback URI plus matching PID is insufficient.

**Primary sources**: Dart 3.7.2
[VM HTTP server](https://github.com/dart-lang/sdk/blob/3.7.2/sdk/lib/_internal/vm/bin/vmservice_server.dart)
and [VM Service protocol](https://github.com/dart-lang/sdk/blob/3.7.2/runtime/vm/service/service.md).
The server distinguishes ordinary HTTP RPC from WebSocket DDS forwarding; protocol identity and
memory semantics remain independently required.

### Finding: VM startTime equality is not a stable identity primitive

The native phone probe observed ten matching-PID reports with a total startTime range of 1 ms.
Dart 3.7.2's [OS clocks](https://github.com/dart-lang/sdk/blob/3.7.2/runtime/vm/os_macos.cc#L59-L83)
and [uptime conversion](https://github.com/dart-lang/sdk/blob/3.7.2/runtime/vm/dart.h#L76-L79)
independently truncate wall time and monotonic elapsed time. A fixed true start of 1,000,500 µs
with uptimes 100/600/1100/1600 µs can therefore yield 1000/1001/1000/1001 ms without restarting.
The protocol timestamp is not an opaque immutable instance ID. Non-atomic reads and wall-clock
adjustments also mean 1 ms is not a guaranteed upper bound; larger changes may require failed
continuity qualification rather than a definitive “app restarted” message.

**Historical bounded decision gate (superseded below)**: before implementing a verified binding, test an at-most-1-ms total
observed range only within one non-reconnectable owner and matching PID/device/session/pinned isolate.
Reject rolling drift (1000/1001/1002) and an initial ±1 window spanning 2 ms (1001/1000/1002). Identity
changes or missing/noninteger metadata always reject. No cross-owner/reconnect tolerance, no fake
OS process-start field and no removal of the production iOS sampling gate are authorized by this
finding. The bounded policy is now implemented/tested inside the metadata-only
`IOSVMMetadataChannel` and passed ten native physical VM observations. T110/T111 remain open for
independent device/application/session admission; the metadata value alone cannot issue a binding.

**2026-09-08 sustained counterexample and reviewed correction**: the actual Workspace path stopped
after 30 successful memory RPCs / 94 metadata RPCs with a 2 ms total startTime range and no transport
error; independent before/after application PID and wired device identity were unchanged. Dart's
`service.cc` computes startTime anew as wall-clock milliseconds minus monotonic uptime milliseconds.
A separate read-only falsification review found no compliant-server same-stream replacement that
the range check uniquely prevents: the native owner cannot reopen, pool or redirect its stream.
Remove the timestamp extrema and comparison, not raise the numeric tolerance. Preserve strict
numeric metadata validation, expected PID, pinned isolate, exact application/session admission,
cancellation and terminal closure. A future intermediary/reconnecting route needs new proof.
Real process restart qualification remains open; clock-only mutation tests must not claim restart.

### Native Bonjour candidate boundary (next T113 slice)

The metadata-only binding issuer now passed physical app/process/session qualification; discovery
still uses an experimental CLI-text orchestrator. Replace that boundary with the installed `dnssd`
module, verified by compiling `import dnssd`. No new package/runtime is needed. The SDK header
`dns_sd.h` was inspected for callback lifetime, network-byte-order port, reference disposal and
serial-queue ownership. Resolve SRV/TXT only for matching local Flutter service hints; discard the
returned network hostname, which is not a selected-phone route. Do not publish a service or scan ports.

Apple's [NetServiceBrowser documentation](https://developer.apple.com/documentation/foundation/netservicebrowser)
marks that API deprecated. Its suggested Network browser is suitable for browsing, but this path
needs the advertised port without creating a connection to a network host. The lower-level
[DNSServiceResolve](https://developer.apple.com/documentation/dnssd/dnsserviceresolve(_:_:_:_:_:_:_:_:))
directly returns SRV port and TXT data using the browse callback's name/domain/interface. C callback
data must be copied before return; no pointer may escape. The API assumes the ordinary one-SRV,
one-TXT service form, not arbitrary multi-record resolution.

[DNSServiceSetDispatchQueue](https://developer.apple.com/documentation/dnssd/dnsservicesetdispatchqueue(_:_:))
supports a dedicated serial queue. The SDK requires deallocation on that same queue, and forbids
mixing dispatch scheduling with DNSServiceProcessResult. The implementation must own all references,
bound attempts/records and reject late results after cancellation. This boundary is now implemented
and reviewed; native physical browse returned two app hints, one of which passed exact-device
binding/renewal while the other was rejected and closed. The probe was corrected to qualify multiple
hints rather than require a unique advertisement. Production orchestration and UI remain separate
acceptance gates; see the dated evidence in validation/ios-vm-discovery.md.

### Memory scope correction from the pinned runtime implementation

The protocol describes `getMemoryUsage(isolateId)` as isolate memory statistics, but the pinned
[Dart 3.7.2 implementation](https://github.com/dart-lang/sdk/blob/3.7.2/runtime/vm/isolate.cc)
implements `Isolate::PrintMemoryUsageJSON` by calling `group()->heap()->PrintMemoryUsageJSON`.
Therefore the measured heap belongs to the selected isolate's group, not exclusively to that
isolate. A sibling worker's allocations can affect the same result. Keep the request isolate pinned
for continuity; label the metric as Dart heap/external through that isolate (shared group heap on
this runtime), never sum per-isolate readings or call it process RSS/PSS. External usage is the
runtime-reported retained non-Dart amount, not every native allocation in the process.
