# Implementation Plan: Device Debug Bridge

## Startup follow-up — Build 9, 2026-09-09

The implemented selection feedback and success-only transfer of persistent compiler workspaces
are described in [startup-feedback-and-reuse-20260909.md](validation/startup-feedback-and-reuse-20260909.md).
That ownership contract supersedes the per-app-only incremental-cache restriction below while
preserving native launch, immutable snapshots, signature validation and selected-session guards.
The measured improvement is in build time; full physical readiness criteria remain open.

## Build 6 closure implementation — 2026-09-08

**Feature**: `001-device-debug-bridge` (non-Git workspace; no branch operations).
**Input**: SC-C01–SC-C05 in [spec.md](spec.md). **Execution**: T115–T128 in [tasks.md](tasks.md).

### Summary and technical context

Finish the existing USB slice in independently verified steps: profile preparation, fix only an
evidenced bottleneck, qualify clipboard origin and adverse behavior, complete visible export/UI
flows, then reconcile qualification and deliver a new local package if production changes occur.
Swift 6 / SwiftUI / AppKit host, UIKit XCTest helper and existing local Swift packages remain the
stack. No new runtime dependency or mobile target-project modification is planned. Existing actor
owners and attempt-scoped temporary storage remain authoritative. Tests are Swift Testing/XCTest
headless or simulator checks; all Mac interaction uses Computer Use. The current real Build 6 app
stays single-instance; replacement is coordinated only when a new artifact is ready.

SC-004/005/011/012 remain the performance targets. Measure real events, not periodic heartbeat
labels. A fixed shared DerivedData path is rejected: late cleanup could remove a new launch's
configuration, and overlapping builds could mutate already-validated artifacts. Research first;
if build cost dominates, design serialized incremental build inputs with immutable attempt outputs
and explicit invalidation before implementing reuse. Otherwise improve the measured stage only.

Measured baseline: build-only preparation took 28.935 seconds. Use one app-instance-owned
`IOSRunnerBuildWorkspace` actor shared by its managers. It serializes build plus immutable snapshot
publication, always invokes Xcode, and rotates to a fresh UUID workspace after any failed/interrupted
build. App restart also starts fresh: a process-held file lock cannot protect against orphan Xcode
writers after a parent crash. Only two signed apps and one validated xctestrun configuration are
copied into each existing launch directory; launcher signature checks and fresh TLS remain intact.
First connection remains a cold build. Warm reconnect improvement requires measurement.

Rendered file receive reproduced a second bounded issue: CoreDevice hangs creating a bookmark
for the user-chosen sibling partial path; two GUI attempts cancelled cleanly, while the same public
69-byte source copied immediately through the terminal. Profile captured `URL.bookmarkData` →
`getxattr`. Qualify an IOSFileProvider-owned temporary receive directory, then move to the service's
partial path in the app. Service remains the integrity/session/final-publication owner; cancellation
after the external await must prevent moving late data. This changes neither remote scope nor file
permissions. Real GUI retest is required before claiming the workaround resolves the hang.

### State/side-effect map and semantic floor

Workspace selection revision → command-ready DeviceSessionStore commit → independent capability
preparation → IOSRunnerManager build/open → IOSRunnerLauncher signed artifacts/process/candidate →
authenticated selected-session binding → Workspace readiness. Workspace owns UI publication;
manager owns launch eligibility; launcher owns per-attempt native resources. Every await preserves
captured session/revision/cancellation checks. Stop invalidates before cleanup; uncertain writes
never retry automatically. Content-free timing must not contain IDs, payloads, certificates or paths.
Existing manager/launcher/channel regression tests are retained before any lifecycle optimization.
No refactor-only abstraction is authorized without a named structural reduction.

### Research, contracts and validation

Research findings are consolidated in [research.md](research.md); supplementary workflow data is
specified in [data-model.md](data-model.md). [Release closure](contracts/release-closure.md) defines
state/evidence boundaries. [quickstart.md](quickstart.md) links the runnable closure sequence.
Use [validation/release-closure-20260908.md](validation/release-closure-20260908.md) as the current
status/evidence matrix. Old results remain historical, not silently rewritten as current passes.

### Constitution check (pre/post design)

Pass: selected-device attribution, explicit local content actions, capability isolation, bounded
operations and small vertical slices are preserved. No new credentials, privacy-setting changes,
automatic provisioning or phone business-app restart. The local keychain contains Apple Development
only; Developer ID/notarization and clean-host evidence are external prerequisites, not local passes.
VM stability remains deferred. Wireless behavior must stay explicitly unavailable until separately
qualified. No exception to the constitution or destructive/Git operation is needed.

### Dependencies and ownership

Root owns documentation, all production writes and exclusive Computer Use. Read-only research
agents may inspect startup and historical UI failures independently; they do not launch apps or
access phone content. Profile → regression → fix → measurement is sequential. Export/UI acceptance
can proceed while research runs. Final packaging follows relevant checks; every owned fixture app
is exited and verified absent before handoff. External prerequisite failures do not halt independent
local work and never become checked acceptance tasks.

## Current memory freshness correction (2026-09-08)

SC-007 remains a three-second freshness requirement. MemoryMonitor now budgets each sequential
cycle from its monotonic start, including sampling and event publication, instead of sleeping a
full interval after completion. The shared default is 2.5 seconds to allow request/dispatch variation;
overruns add no delay or catch-up queue. Ownership, session eligibility, terminal events and Stop
remain unchanged. Controlled regressions failed before both corrections. On the selected wired
iPhone, six Workspace samples produced five gaps of 2525.3–2562.2 ms, with unchanged independent
app PID/route and successful Stop. This is not rendered-UI timing or load/restart/endurance coverage.
See [current memory evidence](validation/us5-memory.md); T064 and clipboard qualification remain open.

## Current iOS recovery slice (2026-09-07)

### Evidence-led VM transport revision (2026-09-08)

Qualify a narrow native HTTP VM adapter over **one owned persistent exact-device USB stream**
for iOS polling; preserve the Android WebSocket/DDS path. On the designated phone, Dart 3.7.2 /
VM protocol 4.16 answered `getVM → getVersion → getVM` on one USB Connect, with stable VM identity,
independently correlated app PID and wired route. WebSocket upgrades instead delegated to DDS.
See [the experiment record](validation/ios-vm-discovery.md). This removes a second endpoint and
DDS delegation lifecycle from the initial polling path, not device/process identity checks.
No runtime dependency, target-project package, permission or debug-setting change is required.
HTTP is less formally specified than the RPC schema: qualify observed protocol/framing only;
unknown responses fail closed. Event streaming and universal runtime compatibility are not promised.

Production path: Workspace captures session/app → bounded Bonjour hints plus independent process
metadata → native owner opens exact USB once → HTTP protocol/VM PID/start baseline → fresh app and
session checks → commit immutable binding → explicit Start. One owner serializes RPCs and never
redirects, reconnects or retries. EOF, malformed/oversized response, timeout or cancellation closes
it permanently; a binding cannot outlive its owner. Recheck captured identity across every await.
Stop invalidates publication before cleanup. Metadata renewal yields to an active sample.

The HTTP reader bounds headers to 16 KiB and decoded body to 1 MiB under one overall request
deadline. Support observed chunked and explicit Content-Length framing; reject ambiguous framing,
excess/premature bytes, redirects, unsolicited events and invalid envelopes. HTTP RPC response IDs
are empty strings, unlike the existing WebSocket integer IDs. DDS takeover can interrupt HTTP too:
invalidate rather than silently hand off. T110/T111 still require candidate/binding types; T113
first tests this native owner and adversarial framing/lifecycle, then integrates discovery.

T114 binds one explicitly selected app isolate (automatic only when unambiguous). Isolate replacement
ends the series; never silently switch to the first remaining isolate. Label its heap/external
metrics as queried through the pinned isolate: Dart 3.7.2 reports its isolate group's shared heap,
not exclusive per-isolate or total app memory. Never sum sibling-isolate results. T064 still requires real memory/load,
restart and route tests; USB metadata evidence does not qualify Wi-Fi or working memory monitoring.
Post-design constitution gates remain intact: explicit content access, capability isolation,
bounded resources, device/session attribution and no additional permissions. No exception is needed.

### Production discovery and monitor handoff (2026-09-08)

T113 is complete for the qualified USB route. `discover(session:applicationID:)` validates the app
before native Bonjour, admits at most four hints, and passes one shared 60-second admission deadline
through qualification. Failed candidate channels close before fallback. Independent provider errors,
stale sessions, cancellation and cleanup failure end the attempt; cleanup failure remains visible even
through nested error mapping. In-flight operations and cleanup may exceed the admission budget.

`IOSVerifiedVMBinding` now directly implements MemorySampling: only its exact target/transport can
sample. No forwarding adapter or additional state owner is needed. `invalidated` is terminal, unlike
ordinary Android failures. MemoryMonitor owns a start/stop revision; DeviceSessionStore completion
atomically consumes publication eligibility, replacing the previous check-then-finish await pair.
This is a store completion linearization point, not a cross-actor atomic UI commit. Workspace must
still reject old monitor/selection callbacks. A real production-discovery → monitor loop → Stop probe
passed with two samples; Core 363 tests pass and the manual iOS URI admission gate remains intact.

T114 Workspace ownership/UI is now implemented. MainActor Workspace alone publishes binding and
readiness: app inventory → explicit app selection (automatic only for one available app) → bounded
discovery → complete session/revision/target checks → committed binding. `iosMemoryRevision` invalidates
app changes; the general preparation revision prevents an old task from clearing a new task handle.
Idle metadata renewal runs every 10 seconds, yields while monitoring, and tolerates single-flight busy.
Explicit Start consumes only the committed binding. Stop/disconnect/route/app changes revoke references
before asynchronous monitor Stop, channel close and task drain. iOS `.stale` also revokes readiness,
even before inventory publication catches up. No manual iOS URI is used or displayed.

iOS device selection becomes actionable after command-ready session commit, without waiting for the
independent screenshot runner. Each capability still checks its own readiness. Five headless memory
groups, the screenshot regression, Core 363 tests, a physical Workspace discovery/idle-renewal/two-sample/
Stop probe and the final incremental Debug build/signature checks pass. The new app was launched in
background without desktop input or focus takeover. T064 load/restart/physical route-switch acceptance,
general clipboard permission and Wi-Fi qualification remain separate next work.

### Earlier recovery sequencing (historical checkpoints)

`IOSApplicationProcessProvider` now supplies independent selected-device app/main-executable/PID
observations. `IOSFlutterVMDiscovery.verify` issues an `IOSVerifiedVMBinding` after metadata-only
before/after process correlation and current-store checks around one native channel. The binding
owns terminal renewal/close, not a reusable URI. Its explicit one-shot `readMemory()` now passed
twice physically (two samples each); Workspace revision commit and monitoring remain unimplemented.
Physical issuer/renewal/probe-local invalidation passed. `IOSVMBonjourDiscovery` replaces experimental
`dns-sd` text parsing with bounded native local `_dartVmService._tcp` browse/resolve. Names remain
hints; resolve only matching developer-app candidates, never connect to the returned network host.
Use the existing system `dnssd` module (available in the installed SDK) for port/TXT lookup;
Apple marks NetServiceBrowser deprecated and NWBrowser alone does not provide the needed SRV port.
DNS-SD browse/resolve references must be cancelled on their owning serial queue, with bounded
candidate counts, record sizes and attempt duration. No service publication, port scan or target
Flutter project change is required. References and limitations are in research.md.

Sampling implementation: binding checks store → channel checks getVM/getMemoryUsage/getVM and
store after each RPC → independent app/path/PID query → same-channel renewal → final store check
and immutable result. The channel remains the only VM-continuity writer; the binding owns its
terminal read/renew guard and cannot transfer its route. A held pre-usage getVM/session-change
regression proves the content RPC is not sent after invalidation. Missing heap/external stay nil;
RSS/PSS and fake OS start are absent. Next T113/T114 work is bounded multi-candidate orchestration,
MemoryMonitor adapter and Workspace lifecycle/UI wiring, with headless checks before Debug launch.

Native VM metadata implementation now uses `IOSVMMetadataChannel` as the sole continuity writer
over its private `IOSVMHTTPTransport`. A candidate is committed only after protocol4.16 / Dart3.7.2
and two expected-PID snapshots agree within a total 1 ms startTime range. Both initial snapshots
must be singleton for automatic isolate selection; renewals pin that choice. The range never slides
and cannot transfer to a replacement owner. Larger variation is unverified continuity, not proof
of restart. Ten physical observations passed this gate; device/app/session binding and actual
memory sampling remain the next T110/T111/T113/T114 work, not implied by this metadata result.

Resume the existing mainline, not additional album or presentation work: T082 transport proof →
T083 launcher → T084 command channel → T036 workspace integration → T041 physical clipboard →
T048 physical screenshot. Keep USB and Wi-Fi evidence separate. A signed build, a launched XCTest
or an inventory connection is not a working content channel. Current personal-identity signing and
physical startup evidence is in [validation/ios-channel-spike.md](validation/ios-channel-spike.md).
Use the user's existing personal iOS development identity and compatible local profiles; no new
certificate, portal registration or automatic provisioning update is authorized by this validation.
Keep the Team out of shared source, and pass it only to the selected local Debug build.

T061 covers Android VM discovery and the shared RPC client, not iOS discovery. T110–T114 restore
the missing iOS memory path and prevent a manually entered Mac/other-phone VM endpoint from being
attributed to the selected iPhone. A verified device route plus application/process binding is
required before publication; see [contracts/ios-vm-memory.md](contracts/ios-vm-memory.md).
VM transport research can reuse T082 evidence without depending on XCTest content dispatch.
Dependency correction (2026-09-08): constitution permission isolation and FR-023 require independent
capability readiness. T036 may integrate the qualified shared USB channel and screenshot provider
while T084 clipboard WRITE/restoration and permission-wait remain open. Those clipboard paths stay
unreachable from the screenshot UI. This changes scheduling, not acceptance: T041/T048, locked or
protected-screen checks and wireless qualification remain open. Earlier all-content gates and
unimplemented-channel descriptions below are historical, superseded by the latest channel evidence.
Deliver the usable screenshot slice next, then finish clipboard and memory; iOS process-wide OS memory remains
unsupported unless a separate verified source exists. Do not label Dart heap as total app memory.
Incremental Debug only; phone-side test execution must not invoke Mac desktop UI automation.

Clipboard qualification update (2026-09-08): authorized normal Runner WRITE/READ and, after a
focused post-read foreground-settlement correction, actual separate-Host → encrypted Runner READ
now pass on the real USB iPhone. The user explicitly authorized MobAI to click this test phone's
exact Allow Paste prompt; product code still does not approve permissions. New tests preserve
deadline, cancellation, foreground and operation ownership while the read result remains local
until the same Runner becomes active again. T036 can next bind explicit selected-USB clipboard
operations, with remaining denial/retry UX, locked/long-data/wireless acceptance still open. User
authorization also allowed terminating the exact app-owned native session for testing; this does
not permit interrupting unrelated processes. Source fixtures are excluded from ordinary builds;
see `validation/us2-clipboard.md` for physical evidence and diagnostic-build prerequisites.

T036 ownership: Workspace selection revision and the exact DeviceSessionStore session bind the
runner manager before preparation. The manager owns build/launch/cleanup; one Workspace metadata
task renews the authenticated channel every 10 seconds independently of the selected feature pane.
Preparation, heartbeat and content completions recheck their captured session/revision after awaits.
Selection, Stop and inventory route/generation invalidation synchronously remove readiness and
cancel tasks before awaiting cleanup. Clipboard readiness requires both negotiated actions and a
context equal to the already-authenticated owned launch; no second manager/heartbeat or content
probe is introduced. Stop and route/heartbeat invalidation also clear clipboard content/feedback
and invalidate pending exports. Selection clears the prior device's text synchronously. The
selected-USB Workspace WRITE/READ and screenshot/export path passed on the physical reference
phone (2026-09-08); visual and remaining adverse/wireless acceptance remain open.
A failed runner affects screenshot and clipboard readiness, not photo/file
services with separate routes. The initial native process lifetime is explicitly bounded to one hour;
expiry requires reselection and is not presented as an indefinitely maintained session.

## Approved module navigation (2026-09-07)

The four readiness cards become equal-size module buttons with a selected border, fill and checkmark.
Only the selected module occupies the content area; Clipboard is the default. Unavailable modules
remain navigable so their restrictions are visible. Probe results do not write module selection.
`WorkspaceView` owns the selected module; the existing session/model owners remain unchanged.
Retain the four pane identities but collapse, disable and accessibility-hide inactive panes so file
input and preview state survive switching. Album thumbnail loading is suspended while its pane is
inactive and resumes the same page on return; explicit transfers and memory monitoring continue.
No module action starts discovery, selects a device, reads content or changes permissions by itself.
Check the actual view in an unshown in-process host plus existing headless model regressions, then
incrementally build/run Debug only. T102/T103 have since passed their recorded image-provider gates;
remaining image qualification stays in T101 and does not replace the current iOS core slice.

## Approved trial-feedback revision (2026-09-07)

User approved full current text (not clipboard history), a scrollable expanded clipboard editor with
copy/save, silent background inventory polling, and an album-style thumbnail grid with original
download. This supersedes the earlier list-only image presentation; batch export remains outside scope.
Keep explicit content actions: connection/readiness never reads clipboard or images. After explicit
Load, only visible/page thumbnails are eligible for bounded sequential reads; discard intermediate
originals and retain a bounded derived-thumbnail cache. Selection takes priority and its verified
original remains the only export source. Source/device invalidation drains tasks and rejects late
results through existing service/session gates. Background inventory keeps DeviceSessionStore as
authority; UI suppresses timestamp-only publications, not actual device/route/status changes.
Clipboard wire and host/helper text limits must agree, reject excess explicitly and never truncate.
Use tests before changes and headless checks; no macOS UI automation or permission changes.

## Approved image-first slice (2026-09-07)

**Goal:** Browse existing phone images, preview a selected image and export its unchanged bytes;
keep known-path bidirectional file transfer as a separate control within the same panel.

**Implementation update:** Android provider, native browser and Chinese/English copy are implemented.
Production USB screenshot read/preview/export passed. See [validation](validation/phone-images.md).
The original read uses capped `exec-out head`, not uncapped `pull`; the command runner enforces a
combined streaming byte quota. `PhoneImagesViewModel` owns only UI copies and revision; the service
owns a request-validity gate and is bound to its creation-time session. Throws replace the planned
outcome wrapper. Headless production-view-model checks supplement, but do not replace, isolated UI QA.

**Architecture:** Android uses the existing target-specific ADB boundary for allow-listed shared
image directories. A small image service binds catalogs and staged previews to the authoritative
device-session generation. SwiftUI renders its immutable results; it does not own transport state.
iOS uses a separately gated public ImageCaptureCore adapter experiment, not CoreDevice app-container
copy, and cannot advertise working photo access before its physical identity/original-export gate passes.

**Tech stack:** Existing Swift/Foundation/Swift Testing, ADB, ImageIO and UniformTypeIdentifiers;
ImageCaptureCore is the iOS candidate. No new host runtime, mobile APK, Flutter package or cloud API.
**Spec:** FR-P01–FR-P03 and SC-P01–SC-P02 in [spec.md](spec.md).

**Global constraints:** macOS 14+, Android API 30+, iOS 17+; local and session-only unless explicitly
saved; no global Mac UI automation; no new permission grant/entitlement or helper installation during
the probe; no phone writes/deletion; no automatic file enumeration/download during readiness.

### Source and interaction decisions

- Android sources are DCIM, Pictures and Download, labelled as shared image directories, not the
  entire Photos library. Read-only fixed-root checks may support readiness; listing starts only when
  the user chooses Load images. Catalog entries include filename, source directory, byte length and
  modification time. Do not label modification time as capture time or expose EXIF GPS by default.
- The image UI is a source selector, album grid and selected-image preview. After explicit Load,
  the current page reads originals sequentially to derive 320-pixel thumbnails, discarding those
  intermediate originals. Selection gets priority and retains verified original bytes plus an at-most
  2048-pixel preview. No full-library prefetch; thumbnail cache is bounded to 48 entries / 20 MiB.
  Batch export is outside this slice. This is host-derived preview, not a phone thumbnail API.
- Android listing is bounded to 4 MiB / 10,000 records / 20 seconds per source. Tiles display 24 at a
  time from one immutable catalog; this is local paging, not remote streaming pagination. Overflow
  returns a visible scope/limit failure, never a silently truncated successful catalog.
- Only one image transfer/decode runs at a time. First-slice image originals are limited to 20 MiB
  and 100 megapixels for preview; oversize content has an explicit unsupported-preview outcome.
  General file transfer retains its existing scope and limits. Device commands, ImageIO decoding and
  hashing stay off the UI thread; partial/previous artifacts cannot grow an unbounded cache.
- A preview retains the verified original bytes until selection/session changes. Export copies those
  same bytes to a user-chosen destination, with explicit replacement approval, staging and integrity
  verification. Never silently convert HEIC to JPEG and call it the original.
- iOS initial candidate is USB camera import only. Unverified identity correlation, restricted access,
  incomplete catalog and unsupported routes must not appear as an empty or successful album. No
  iPhone wireless photo-library or cloud-only-original claim follows from ADB or generic ICC network support.

### Stateful image path and ownership

1. `WorkspaceViewModel` dispatches an explicit image action to `ImageLibraryService`; the current
   `DeviceSessionStore` remains the sole selected-device/generation/operation owner. A dedicated
   `PhoneImagesViewModel` carries the image presentation state and explicit user actions.
2. The service starts an image operation and captures its token and a monotonically increasing
   image request-validity gate. The service alone owns the committed catalog and preview. UI fields are
   immutable presentation copies, never an alternative source of truth.
3. `AndroidImageProvider` lists one fixed source via `HostCommandRunning` or reads an item from the
   current catalog. Caller-supplied arbitrary paths are not accepted. Provider outputs are candidates.
4. After every external await, check cancellation, image revision and session token; only a current
   result can replace the catalog or preview. A same-device source/selection change also invalidates
   old work, even if the connection generation is unchanged.
5. Original bytes first land at an operation-specific partial path. Validate source scope/version,
   length, available SHA-256, ImageIO type/dimensions and the current token before publication. Keep
   the previous valid preview on failure of a replacement request within the same image source.
6. File-panel completion must revalidate the captured preview ID/revision and device token before any
   destination side effect. Cancellation or mismatch removes only this operation's partial copies.
7. Source/device/transport change clears the catalog and preview, cancels work and releases temporary
   artifacts. An iOS gateway closes its camera session and ignores late delegate callbacks by generation.

### Test-first implementation steps

Use the existing SpecKit execution workflow in this workspace; no Git operations are authorized.
Each task below is a separate acceptance gate; exact boundaries are in [contracts/phone-images.md](contracts/phone-images.md).

- T099 owns `Models/PhoneImages.swift`, `Operations/AndroidImageProvider.swift`,
  `Operations/ImageLibraryService.swift` and matching `PhoneImageModelsTests`, `AndroidImageProviderTests`,
  `ImageLibraryServiceTests` under DeviceBridgeCore. First assert path/record validation, scoped ADB
  requests, denied-vs-empty, stale session and same-session selection results, cancellation, original
  integrity and no-readiness-content behavior. Observe red before implementing each behavior; use
  `swift test --package-path packages/DeviceBridgeCore --filter 'PhoneImageModelsTests|AndroidImageProviderTests|ImageLibraryServiceTests'`.
- T100 owns `Views/PhoneImagesView.swift`, the image section of `Views/FileTransferView.swift`, focused
  `WorkspaceViewModel.swift` wiring, and `Localization/zh-Hans.json`. Preserve existing file actions.
  First add fixture UI scenarios for explicit Load, source selection, selected preview/export, device
  switching and Chinese/English copy. Compile normally; execute UI tests only in verified isolation.
- T101 uses production adapters on the reference phones. The current feasibility probe is not a
  substitute for the production service/UI check. Verify an existing camera photo and screenshot,
  byte-preserving export, cancellation and source-device correctness; report each platform separately.
- T102 is an iOS-only go/no-go experiment before T103. With user-resolved permissions, prove exact
  selected-device correlation, complete USB catalog, thumbnail, original-presentation download and
  stale/cancel cleanup. If correlation or access fails, return an actionable restriction; do not map
  by device name or reuse the unresolved XCTest content channel as a photo-access claim.
- T103 implements the ImageCaptureCore gateway and provider only after T102. Keep Apple delegate
  objects confined to one main-actor gateway, return typed immutable candidates to the image service,
  and test incomplete catalogs, restriction/removal, edited/converted representation and late callbacks.

### Image constitution re-check

PASS for the Android design: existing session owner and ADB server, explicit content actions, bounded
scope/storage/work, byte-preserving export and no additional permissions. iOS remains **experimental
and gated**: unresolved physical access is a qualification risk with a defined failure state, not a
permission bypass or an assumption of parity. Research/probe evidence: [validation/phone-images.md](validation/phone-images.md).

## Approved language slice (2026-09-07)

Use a small bundled English-key/Simplified-Chinese catalog and pure `InterfaceLanguage` resolution in
DeviceBridgeCore. An app-level AppStorage preference is the only writer for language; inject the
resolved presentation language/locale into SwiftUI. Do not assign view identity from language or
recreate WorkspaceViewModel. Existing session ownership and await guards remain unchanged.
Translate at rendering, not when asynchronous results arrive. Parameterized messages retain a key
and opaque arguments; substitutions are one-pass so user data cannot become translation syntax.
Device payloads and identifiers never pass through translation lookup. Tests cover resolution,
catalog lookup/fallback, formatting, UI switching, persistence and preservation of inputs/session.
Constitution gates: PASS; local non-sensitive preference only, no new permissions or device commands.

**Branch**: `001-device-debug-bridge` | **Date**: 2026-09-04 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `/specs/001-device-debug-bridge/spec.md`

## Summary

Deliver one native Mac application for a small trusted Flutter team. The application discovers and
operates Android devices through the developer's ADB server and iOS 17+ devices through Xcode
CoreDevice. SwiftUI provides the macOS interface; a local Swift package owns models, parsers, process
execution, immutable workspace snapshots, and one actor-isolated device session store. Every
asynchronous result carries a device, transport, generation, and operation token so a stale result
cannot publish after switching or reconnecting.

The Mac application automatically probes clipboard, Flutter VM, screenshot, and permitted file-scope
readiness. It packages and manages a native Android helper APK and an iOS XCUITest runner when a
feature requires device-side code. The developer never has to modify the Flutter project being
debugged. Platform trust, Developer Mode, signing, permission, and foreground requirements remain
explicit. Wired transport is preferred; Android Wi-Fi uses both host-side recovery and a visible,
lease-bounded device Wi-Fi keep-alive.

## Technical Context

**Language/Version**: Apple Swift 6.3.3 for host/core; Kotlin/JVM 21 toolchain for Android helper;
Swift/XCTest for iOS runner

**Primary Dependencies**: SwiftUI, AppKit, Foundation, Network, OSLog, Swift Testing, XCTest; host ADB
37.0.0+; Xcode 15.4+ `devicectl` and `xcodebuild`; Android SDK and externally installed Gradle
8.11.1 for contributor helper builds (no Gradle wrapper is vendored)

**Storage**: Per-launch temporary artifact directory; small property-list/JSON preferences containing
no payloads or raw secrets; no database

**Testing**: Swift Testing core tests, XCTest UI/runner tests, Kotlin unit and Android instrumentation
tests, deterministic command fixtures, fake process runner, and Android/iOS real-device contract checks

**Target Platform**: Apple Silicon macOS 14+ host; Android 11/API 30+ devices; iOS 17+ devices

**Project Type**: Xcode macOS application + local Swift package + managed Android APK + managed iOS
XCUITest runner

**Performance Goals**: Interactive window within 3 seconds; authorized-device discovery within
5 seconds; device switch within 1 second; readiness summary within 10 seconds; supported clipboard
operation within 3 seconds excluding user consent; prepared screenshot capture within 5 seconds;
memory samples every 3 seconds; eligible Android wireless recovery within 15 seconds

**Constraints**: One launched Mac application; zero required changes to target Flutter projects;
local-only; USB preferred; exactly one active device; no shell interpolation; subprocesses are
cancellable and time-bounded; payloads never logged; readiness probes never retrieve content;
health probes are single-flight and yield to active operations; helpers are removable and visible
when continuously active

**Scale/Scope**: One developer, up to 8 visible devices, one active session, five feature panels, one
Android helper package, one iOS runner, and bounded in-memory operation history

## Constitution Check

*The table reviews architectural constraints, not physical implementation. The iOS completion
gate below is NOT PASSED; its unresolved route/security evidence blocks production enablement.*

| Principle or Gate | Design Evidence | Result |
|-------------------|-----------------|--------|
| Stable Connection Is the Product | One supervisor verifies target-specific commands, prefers wired transport, and performs bounded Android endpoint recovery without moving active work. | PASS |
| One Authoritative Device Session | `DeviceSessionStore` is the only writer; session tokens reject late results after each suspension point. | PASS |
| Local, Explicit, Least-Privilege Access | Content remains local and ephemeral; helpers expose only debugging actions and unavoidable device consent is explicit. | PASS |
| Honest Cross-Platform Capabilities | Availability distinguishes helper-required, action-required, restricted, offline, experimental, and unsupported. | PASS |
| Small, Verifiable Vertical Slices | Delivery starts with native Mac discovery/switching, then adds one independently testable capability at a time. | PASS |
| Stateful Flow Quality Gate | Entry, owner, publication, stale guard, cancellation, failure mapping, and terminal UI effect are defined below. | PASS |
| One-Application Experience | The Mac product detects, deploys, upgrades, starts, stops, and diagnoses helpers; target Flutter projects remain unchanged. | PASS |

### Primary Stateful Production Path

1. `DeviceBridgeApp` resolves ADB and Xcode tools, creates an ephemeral artifact session, and asks
   `DeviceSessionStore` to refresh inventory.
2. `AndroidDeviceService` and `IOSDeviceService` cross the process boundary through
   `HostCommandRunning` and return transport candidates. Only `DeviceSessionStore` merges candidates,
   selects the preferred transport, increments generation, and publishes a `WorkspaceSnapshot`.
3. Selecting a device invalidates the previous generation, requests operation cancellation, clears
   device-scoped transient data, and commits exactly one active `ConnectionSession`.
4. Four independent readiness probes start. Helper-required probes first use `HelperManager` to
   compare embedded and installed versions; installation or foreground permission becomes a named
   action instead of an opaque failure.
5. `ConnectionSupervisor` runs one health probe at a time. Two failures invalidate the current
   transport generation; Android recovery tries verified known and mDNS endpoints with bounded
   backoff. A command-ready identity match is required before publication.
6. A user operation captures `SessionToken(deviceID, transportID, generation, operationID)`, crosses
   the adapter boundary, and checks cancellation and token validity after every `await`.
7. Only a matching token may commit state or a user-visible side effect. A mismatch terminates as
   stale and discards content.
8. Artifact operations write to partial paths, verify content, atomically publish to the session
   store, and preserve the previous valid preview if the new attempt fails.
9. Closing or deselecting stops timers, reconnect attempts, forwarded ports, runner activity, and
   Android helper leases.

## Project Structure

### Documentation

```text
specs/001-device-debug-bridge/
├── spec.md
├── plan.md
├── research.md
├── data-model.md
├── quickstart.md
├── contracts/
├── checklists/
└── tasks.md
```

### Source Code

```text
apps/
└── macos/
    ├── DeviceBridge.xcodeproj/
    ├── DeviceBridgeApp/
    │   ├── App/
    │   ├── Views/
    │   ├── ViewModels/
    │   ├── Resources/
    │   │   └── Helpers/
    │   └── DeviceBridgeApp.entitlements
    └── DeviceBridgeAppUITests/

packages/
├── DeviceBridgeProtocol/           # Foundation-only iOS/macOS wire models, validation and framing
├── DeviceBridgeSecureChannel/      # Ephemeral certificate pins and authenticated TLS transport
└── DeviceBridgeCore/
    ├── Package.swift
    ├── Sources/DeviceBridgeCore/
    │   ├── Models/
    │   ├── Commands/
    │   ├── Discovery/
    │   ├── Session/
    │   ├── Supervision/
    │   ├── Helpers/
    │   ├── Operations/
    │   └── Privacy/
    └── Tests/DeviceBridgeCoreTests/

helpers/
├── android/
│   ├── app/src/main/kotlin/dev/debugutility/helper/
│   ├── app/src/test/
│   └── app/src/androidTest/
└── ios/
    ├── DeviceBridgeRunner.xcodeproj/
    └── DeviceBridgeRunnerUITests/

tool/
└── fixtures/
    ├── adb/
    ├── devicectl/
    └── memory/
```

**Structure Decision**: The Xcode application is the sole user-facing product. The local Swift
packages keep the host core independently testable and share only wire/security primitives with iOS.
`DeviceBridgeCoreChecks` is an additional static product for contributor headless checks, not a new
user-facing app or distribution format; SwiftPM owns its complete transitive link archive. Native helpers use their platform toolchains and
are embedded as versioned resources in release builds. There is no shared Flutter/Dart workspace and
no package added to the application under test.

## Phase 0 Research Decisions

- SwiftUI/AppKit is the Mac shell; the difficult device logic stays in `DeviceBridgeCore`.
- The installed ADB server is reused and never killed automatically.
- `devicectl --json-output` owns iOS inventory; private CoreDevice frameworks are not linked.
- Managed native helpers replace a separately installed Flutter companion.
- Android screenshot uses `screencap`; iOS screenshot uses the managed XCUITest runner.
- Flutter VM Service discovery requires no target-project plugin; Swift speaks the required protocol
  subset and keeps service URIs in memory only.
- The first release depends on compatible Xcode and Android platform tools already present on the
  developer Mac and reports missing prerequisites in the app.
- Direct distribution starts unsigned for local development, then adopts Developer ID, hardened
  runtime, and notarization. Mac App Store sandboxing is out of scope.

See [research.md](research.md) for evidence and alternatives.

## Phase 1 Design Decisions

- `DeviceSessionStore` is the one authoritative mutable owner; SwiftUI observes immutable snapshots.
- `HostCommandRunning` is the only child-process boundary and contains no device business policy.
- `AndroidHelperManager` and `IOSRunnerManager` own version checks, install/start/stop, and actionable
  setup states. Feature services cannot install helpers directly.
- Companion envelopes are versioned, nonce-bound, size-limited, expiry-limited, and payload-redacted.
- Automatic readiness is metadata-only; content operations always require an explicit user action.
- Android helper leases expire without renewal; iOS runner processes and channels are scoped to the
  selected session. Each iOS launch has a unique resource ID, including same-device retries;
  stop invalidates ownership before awaiting cleanup and late returns cannot publish readiness.
- Temporary artifacts are removed on normal exit and next launch. Explicit saves use user-selected
  locations and atomic publication.

Detailed state is in [data-model.md](data-model.md), service and UI boundaries are in
[contracts/](contracts/), and end-to-end verification is in [quickstart.md](quickstart.md).

### iOS Completion Gate (2026-09-07)

The concrete iOS channel is not implemented. Public `devicectl` has no port-forward command in the
installed version. [contracts/ios-runner-channel.md](contracts/ios-runner-channel.md) specifies the
lifecycle and wire requirements and a usbmux transport experiment. It does not claim that experiment
has passed. T082 must establish physical transport selection, authenticated in-memory exchange, and
cleanup before T083/T084 implement the concrete provider and T036 connects it to the workspace.
No new tool is a recipient prerequisite until its packaging and compatibility are proven.
Phase disposition after bounded personal-signed mutual TLS 1.3 USB runs: the **USB candidate is GO
for T083 fixture/launcher implementation**, not for content readiness. The iproxy wireless candidate
is NO-GO because its direct LAN path violates the selected listener boundary. T082's overall wireless
work remains open. Production enablement still requires T083/T084/T036: exact product/install binding,
actual secret nonce exchange, cancellation/generation isolation, resource cleanup and content permissions.
Strict timing reruns are recorded in validation, never inferred from exit status alone.
T082 now investigates public-container certificate pinning + in-memory ephemeral identities + mutual TLS 1.3
specified in the channel contract. This permits public bootstrap metadata only, not secret/content
mailboxes. Separate USB and wireless dispositions; an unqualified wireless route cannot silently
serve a USB session. No authenticated-content go/no-go is claimed from the earlier public canary.
The upstream `iproxy` network branch opens direct LAN TCP, not a paired tunnel into device
loopback. Thus it does not satisfy the wireless/no-LAN-listener contract. USB inventory, signed
startup and three bounded public-marker exchange/cleanup runs now pass. They do not qualify
authenticated content. A real canary audit found runner environment values in xcresult action logs;
`TEST_RUNNER_` secret bootstrap is rejected. Secure bootstrap, complete lifecycle and wireless remain
unqualified; no production content provider is enabled by the experimental test server.

Quantitative qualification is defined in [validation/qualification-protocol.md](validation/qualification-protocol.md).
T073 owns automated qualification; T041/T048/T056/T064 and T074 own real-device evidence.

Production call-site review initially found the tested supervisor policy unwired. T091/T024 now
provide the command-driven maintenance actor, authenticated ADB recovery and regression tests.
T092 workspace wiring is implemented and its recovery/rebind/device-switch test now passes both
individually and in the eight-test fixture UI suite. Android supervision is separate from helper leases;
iOS still has selection-time checks. See [maintenance evidence](validation/android-connection-maintenance.md).
Architecture gates describe the target design, not completed runtime qualification; T029/T088/T089
remain open for real-device and quantitative evidence.

## Post-Design Constitution Re-check

The architecture retains the constitution constraints, but the iOS transport implementation gate
is NOT PASSED: wireless routing and nonce bootstrap remain unresolved. T082 is an experiment, not
authorization to enable production content actions. The revised design removes one user-facing companion app and the Flutter
desktop runtime without adding another state owner. Device helpers remain necessary correctness
boundaries, but their lifecycle is managed by the Mac product and their continuous behavior is
visible, stoppable, and lease-bounded. Platform restrictions remain explicit.

## Complexity Tracking

The migration reduces the user-visible install count from two apps to one and removes the Dart/Swift
platform-channel boundary from the host. Native Android and iOS helper targets remain because they
enforce platform-required execution boundaries rather than duplicate business state. No constitution
exception is required.
