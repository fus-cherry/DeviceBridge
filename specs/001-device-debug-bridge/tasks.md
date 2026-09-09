# Tasks: Device Debug Bridge

**Input**: Design documents from `/specs/001-device-debug-bridge/`

**Prerequisites**: `plan.md`, `spec.md`, `research.md`, `data-model.md`, `contracts/`, `quickstart.md`

**Tests**: Required by the constitution. Every test task precedes its production task and must be
observed failing for the intended missing behavior.

**Current user priority (2026-09-08)**: Execute the Build 6 remaining-work closure via T115–T128
below. Computer Use now works for the verified DeviceBridge layout; earlier native-pipe blockers are
historical. Mac input remains Computer Use only. VM stability/T064 remains explicitly deferred; do
not restart the phone business app. Preserve single real-app ownership and exit every owned fixture.
See [current closure matrix](validation/release-closure-20260908.md) and
[Build 6 positive evidence](validation/ios-nonvm-acceptance.md). External prerequisites and broader
wireless/platform acceptance stay open until actually supplied and verified.

## Current closure setup and foundations

- [X] T115 Reconcile audited scope, research, state/evidence contract and dependent closure tasks in `specs/001-device-debug-bridge/spec.md`, `plan.md`, `research.md`, `data-model.md`, `contracts/release-closure.md` and `quickstart.md`; preserve original tasks and deferred VM scope.

## Current closure US1 — preparation and recovery (P1)

Goal: measured preparation cost and safe repeated connections. Independent test: actual selection
to authenticated readiness with separate build/open phases; cancellation never publishes a stale session.

- [ ] T116 [US1] Measure current preparation phases and cold/repeated readiness in `packages/DeviceBridgeCore/Sources/DeviceBridgeCore/Helpers/IOSRunnerManager.swift` and `validation/release-closure-20260908.md`; timing is content-free, not a readiness input.
- [X] T117 [US1] Add a failing focused regression for the measured avoidable cost, preserving existing lifecycle counterexamples in `packages/DeviceBridgeCore/Tests/DeviceBridgeCoreTests/IOSRunnerManagerTests.swift` and `IOSRunnerLauncherTests.swift` before the production change.
- [X] T118 [US1] Implement the smallest evidenced preparation improvement in `packages/DeviceBridgeCore/Sources/DeviceBridgeCore/Helpers/` without shared mutable launch outputs or weaker signature/session checks; re-evaluate the plan if profiling identifies a different bottleneck.
- [ ] T119 [US1] Record fresh before/after cold/repeated readiness samples and cancellation/Stop outcomes in `specs/001-device-debug-bridge/validation/release-closure-20260908.md`; do not claim SC-012/T087 from heartbeat labels or insufficient samples.

## Current closure US2 — original-source clipboard (P2)

Goal: exact public source text and truthful failure/recovery feedback. Independent test: another
phone app copies the declared fixture; explicit Mac read matches without first overwriting that source.

- [ ] T120 [US2] Qualify original-source public text, long Unicode, empty/unavailable, Command-Return and text expand/copy/save through `apps/macos/DeviceBridgeApp/Views/ClipboardView.swift`; add regression before repairing any reproduced behavior and record exact scenario scope in `validation/release-closure-20260908.md`.
- [ ] T121 [US2] Verify denial/locked/foreground-failure recovery and selected-session invalidation in `packages/DeviceBridgeCore/Tests/DeviceBridgeCoreTests/IOSRunnerChannelTests.swift` plus coordinated real-phone scenarios in `validation/release-closure-20260908.md`; physical unplug/paste-denial are explicit external conditions, never fixture passes.

## Current closure US3/US4 — visible artifacts (P3/P4)

Goal: complete chosen-file output without partial or stale publication. Independent test: capture
or select one known artifact, export via the native panel, validate output, and cancel a second attempt.

- [ ] T122 [US3] Verify current capture→copy/save/cancel workflow in `apps/macos/DeviceBridgeApp/Views/ScreenshotView.swift` and exact saved PNG behavior, including failure preserving preview, recording `validation/release-closure-20260908.md`.
- [ ] T123 [US4] Verify current image preview/original export and disposable file controls/cancellation in `apps/macos/DeviceBridgeApp/Views/FileTransferView.swift` and `PhoneImagesView.swift`, recording byte integrity and physical-disconnect limits in `validation/release-closure-20260908.md`.

## Current closure US6 — UI regressions and language

- [X] T124 [US6] Diagnose historical keyboard and initial fixture-memory failures, correct evidenced test-contract drift, and qualify Chinese/English layout/input preservation using `apps/macos/DeviceBridgeAppUITests/AccessibilityUITests.swift`, `DeviceWorkspaceUITests.swift`, headless model checks and Computer Use; exclude real VM stability and global macOS XCTest input.

## Current closure polish and delivery

- [X] T125 Record and validate the iOS USB/wireless capability boundary in `apps/macos/DeviceBridgeApp/ViewModels/WorkspaceViewModel.swift` and `specs/001-device-debug-bridge/validation/release-closure-20260908.md`; any user-approved new wireless transport requires a separate verified design before implementation.
- [ ] T126 Complete available signing/first-use checks and actual Developer ID/notarization/clean-Mac acceptance when prerequisites are supplied, updating `specs/001-device-debug-bridge/validation/helper-packaging.md` and `validation/release-closure-20260908.md`; do not mark unavailable external acceptance complete.
- [X] T127 Run affected Core/helper/headless checks, build the updated Mac app and verify local delivery artifacts with `scripts/test_helper_packaging.py`, recording exact scope/results in `specs/001-device-debug-bridge/validation/final-automated.md`.
- [X] T128 Synchronize current task and aggregate statuses in `specs/001-device-debug-bridge/validation/final-real-device.md`, `ios-nonvm-acceptance.md`, `ui-automation.md` and `tasks.md`; ensure owned fixture teardown in `apps/macos/DeviceBridgeAppUITests/` and verify zero remaining fixture apps at handoff.

Dependencies: T115 → T116 → T117 → T118 → T119. T120–T124 may be independently investigated
after T115, with one root-owned desktop session; any code change needs its regression first.
T125/T126 prerequisite inspection can proceed independently. T127 follows all implemented changes;
T128 follows available validation. Root is the only production/document writer. Read-only startup
and UI research can run concurrently; no parallel test apps or physical runner owners.
Original unchecked roll-up tasks below are not automatically closed by this narrower USB slice.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel because it owns different files and has no incomplete dependency.
- **[Story]**: User-story traceability label.

## Phase 1: Native Workspace Setup

**Purpose**: Establish the smallest buildable native host and helper workspaces without deleting the
abandoned Flutter scaffold.

- [X] T001 Create the Swift package skeleton and deployment target in `packages/DeviceBridgeCore/Package.swift`
- [X] T002 Create the native SwiftUI macOS application project, scheme, plist, and entitlements in `apps/macos/DeviceBridge.xcodeproj/` and `apps/macos/DeviceBridgeApp/`
- [X] T003 [P] Create the Android Kotlin helper Gradle skeleton in `helpers/android/`
- [X] T004 [P] Create the iOS XCUITest runner skeleton and shared scheme in `helpers/ios/DeviceBridgeRunner.xcodeproj/`
- [X] T005 Add Swift, Xcode, Android, and universal generated-file patterns to `.gitignore`
- [X] T006 Record exact native host, Android helper, and unsigned iOS runner smoke commands/results in `specs/001-device-debug-bridge/validation/setup-build-smoke.md`

**Checkpoint**: Native host core/app builds; helper projects are independently buildable or have an
actionable signing/toolchain result.

---

## Phase 2: Foundational Contracts

**Purpose**: Create the shared state and external-boundary contracts that block all user stories.

- [X] T007 [P] Write model equality, validation, and redacted-description tests in `packages/DeviceBridgeCore/Tests/DeviceBridgeCoreTests/DeviceModelsTests.swift`
- [X] T008 [P] Write subprocess success, nonzero, timeout, cancellation, concurrent-output, and output-limit tests in `packages/DeviceBridgeCore/Tests/DeviceBridgeCoreTests/HostCommandRunnerTests.swift`
- [X] T009 [P] Write privacy redaction tests for device IDs, nonces, clipboard markers, and VM URIs in `packages/DeviceBridgeCore/Tests/DeviceBridgeCoreTests/RedactorTests.swift`
- [X] T010 Implement immutable device, transport, capability, session, token, operation, and failure types in `packages/DeviceBridgeCore/Sources/DeviceBridgeCore/Models/DeviceModels.swift`
- [X] T011 Implement cancellable `HostCommandRunning` and bounded Foundation `Process` execution in `packages/DeviceBridgeCore/Sources/DeviceBridgeCore/Commands/HostCommandRunner.swift`
- [X] T012 Implement structured redaction and privacy-safe diagnostics in `packages/DeviceBridgeCore/Sources/DeviceBridgeCore/Privacy/Redactor.swift`
- [X] T013 Implement tool resolution/preflight with actionable ADB and Xcode outcomes in `packages/DeviceBridgeCore/Sources/DeviceBridgeCore/Commands/ToolchainPreflight.swift`

**Checkpoint**: Platform adapters can return typed, privacy-safe outcomes without writing session
state or invoking shell strings.

---

## Phase 3: User Story 1 — Connect and Switch Devices Reliably (Priority: P1) 🎯 MVP

**Goal**: Launch one native Mac app, discover authorized Android/iOS devices, prefer wired routes,
select exactly one device, and reject stale work after selection or transport changes.

**Independent Test**: Connect at least two authorized devices, refresh, switch selection, disconnect
and reconnect one, and verify the header, transport, health, generation, and late-result behavior.

### Tests for User Story 1

- [X] T014 [P] [US1] Write ADB inventory parsing tests for USB, Wi-Fi, offline, unauthorized, duplicate, and malformed rows in `packages/DeviceBridgeCore/Tests/DeviceBridgeCoreTests/ADBDeviceParserTests.swift`
- [X] T015 [P] [US1] Write CoreDevice JSON parsing tests for wired, wireless, unavailable, locked, unpaired, and schema variation fixtures in `packages/DeviceBridgeCore/Tests/DeviceBridgeCoreTests/CoreDeviceParserTests.swift`
- [X] T016 [P] [US1] Write transport preference and provisional identity aggregation tests in `packages/DeviceBridgeCore/Tests/DeviceBridgeCoreTests/DeviceInventoryTests.swift`
- [X] T017 [P] [US1] Write selection generation, cancellation, disconnect, and late-publication tests in `packages/DeviceBridgeCore/Tests/DeviceBridgeCoreTests/DeviceSessionStoreTests.swift`
- [X] T018 [P] [US1] Write single-flight heartbeat, operation-yield, failure threshold, bounded retry, identity verification, and USB-preemption tests in `packages/DeviceBridgeCore/Tests/DeviceBridgeCoreTests/ConnectionSupervisorTests.swift`

### Implementation for User Story 1

- [X] T019 [P] [US1] Implement `adb devices -l` parsing and target-specific candidate metadata in `packages/DeviceBridgeCore/Sources/DeviceBridgeCore/Discovery/ADBDeviceParser.swift`
- [X] T020 [P] [US1] Implement `devicectl --json-output` parsing and CoreDevice status mapping in `packages/DeviceBridgeCore/Sources/DeviceBridgeCore/Discovery/CoreDeviceParser.swift`
- [X] T021 [US1] Implement Android and iOS inventory services through `HostCommandRunning` in `packages/DeviceBridgeCore/Sources/DeviceBridgeCore/Discovery/DeviceDiscoveryServices.swift`
- [X] T022 [US1] Implement candidate aggregation and wired-preferred inventory snapshots in `packages/DeviceBridgeCore/Sources/DeviceBridgeCore/Discovery/DeviceInventory.swift`
- [X] T023 [US1] Implement the actor-isolated authoritative session store and stale-token guard in `packages/DeviceBridgeCore/Sources/DeviceBridgeCore/Session/DeviceSessionStore.swift`
- [X] T024 [US1] Complete active-session health supervision and Android bounded recovery orchestration in `packages/DeviceBridgeCore/Sources/DeviceBridgeCore/Supervision/ConnectionSupervisor.swift`, `ConnectionMaintenance.swift` and `AndroidConnectionTransport.swift` after T091; command-loop, endpoint rediscovery and authenticated identity evidence is in `validation/android-connection-maintenance.md`
- [X] T025 [US1] Implement the observable main-actor workspace model in `apps/macos/DeviceBridgeApp/ViewModels/WorkspaceViewModel.swift`
- [X] T026 [US1] Implement native sidebar, selected-device header, health, transport, refresh, and empty/error states in `apps/macos/DeviceBridgeApp/Views/WorkspaceView.swift`
- [X] T027 [US1] Wire application bootstrap, shutdown cancellation, and toolchain diagnostics in `apps/macos/DeviceBridgeApp/App/DeviceBridgeApp.swift`
- [X] T028 [US1] Add Mac UI automation for refresh, device selection, and generation-safe presentation in `apps/macos/DeviceBridgeAppUITests/DeviceWorkspaceUITests.swift`
- [ ] T029 [US1] Complete P1 USB/wireless real-device checks after T024/T092 and record results in `specs/001-device-debug-bridge/validation/us1-connection.md`; previous wired/fixture evidence is retained, while wireless fault injection was NOT RUN

**Checkpoint**: P1 is a usable native Mac discovery/switching MVP; helpers are not required for this
slice.

---

## Phase 4: User Story 2 — Exchange Clipboard Text (Priority: P2)

**Goal**: Let the Mac app install/manage the needed helper and exchange selected-device clipboard
text without target-project changes or payload logging.

**Independent Test**: Transfer unique Unicode text in both directions on Android and iOS, deny one
permission, update an old helper, and switch devices.

### Tests for User Story 2

- [X] T030 [P] [US2] Write helper envelope, nonce, expiry, replay, size, and version tests in `packages/DeviceBridgeCore/Tests/DeviceBridgeCoreTests/HelperProtocolTests.swift`
- [X] T031 [P] [US2] Write Android helper detection/install/forward/start/stop and actionable-error tests in `packages/DeviceBridgeCore/Tests/DeviceBridgeCoreTests/AndroidHelperManagerTests.swift`
- [X] T032 [P] [US2] Write iOS runner signing/install/start/channel/stop state tests in `packages/DeviceBridgeCore/Tests/DeviceBridgeCoreTests/IOSRunnerManagerTests.swift`
- [X] T033 [P] [US2] Write clipboard payload privacy, Unicode, size, denial, cancellation, and switch invalidation tests in `packages/DeviceBridgeCore/Tests/DeviceBridgeCoreTests/ClipboardServiceTests.swift`

### Implementation for User Story 2

- [X] T034 [P] [US2] Implement versioned helper request/result envelopes, now shared from `packages/DeviceBridgeProtocol/Sources/DeviceBridgeProtocol/HelperProtocol.swift` so iOS does not import macOS-only Core; original JSON/framing behavior and Core clipboard limit API remain covered
- [X] T035 [US2] Implement Android APK version management, ADB forwarding, and helper lifecycle in `packages/DeviceBridgeCore/Sources/DeviceBridgeCore/Helpers/AndroidHelperManager.swift`; cold-start readiness fixed with bounded socket/focus checks, cancellation/stale cleanup and two physical passes without the diagnostic gate; see `validation/physical-background.md`
- [ ] T036 [US2] Integrate the concrete iOS runner provider, signing settings, readiness, session-token invalidation and shutdown in `apps/macos/DeviceBridgeApp/ViewModels/WorkspaceViewModel.swift` after the relevant T077/T082/T083/T084 prerequisites; the original build/install/start/channel/stop scope is preserved. Per constitution/FR-023, each capability may proceed on its own qualified evidence. Selected-USB screenshot and explicit clipboard binding now have positive evidence; never enable from inventory presence alone. Full T084/T036 and T041/T048 remain open until their remaining acceptance passes.
  Current next step (2026-09-08): complete remaining permission/lifecycle UX and adverse-path acceptance on the integrated Workspace, then remaining transport qualification. Classified recovery advice is now preserved by Workspace and shown in both languages; waiting guidance is conditional, not a claim that an OS prompt was detected. No automatic permission approval or clipboard retry was added.
  Maximum-text follow-up: production Workspace exact **1 MiB UTF-8** Chinese/Emoji/newline WRITE → independent READ passed on the selected personal-signed USB iPhone, followed by screenshot/export, renewal and Stop (`devicebridge-workspace-clipboard-maximum-8ll48gj_`, 52.469 s outer harness). Full-text transmission is verified; physical multi-item/denial/locked/wireless and visible long-editor acceptance remain open.
  Latest binding progress (2026-09-08, supersedes the preceding next-step/UI gate): Workspace now enables explicit clipboard actions only after both actions are negotiated on the same authenticated selected USB Runner. Stop/route/heartbeat cancellation clears clipboard state and export epoch; selection clears previous content. RED/GREEN channel and headless checks pass; Core 367/56 passes. Physical production Workspace + bundled ordinary signed sources passed WRITE/READ exact round trip, screenshot/export, renewal and Stop (51.007 s outer harness, `devicebridge-workspace-clipboard-malp6bam`). This is not visual/button-click acceptance or the full adverse/wireless matrix; full T036/T041/T084 remain open. See `validation/us2-clipboard.md`.
  Progress (2026-09-08): provider physical screenshot/40-second heartbeat/Stop passed in 47.900 s; portable bundle and local Team settings are implemented. Workspace now binds one manager to the exact selected USB session, requires negotiated screenshot capability, renews metadata every 10 s and invalidates on route changes/Stop. Screenshot can be independently ready; clipboard stays gated by WRITE/restoration and permission-wait. Headless model checks and Debug build pass. Full bundled-source physical Workspace build/prepare/renew/screenshot/exact-save/Stop now passes (`devicebridge-workspace-physical-xc4lp0zk`), after fixing verbose Xcode output with `-quiet` while retaining the 2 MiB quota. Visible UI, locked/protected cases, wireless and full story acceptance remain open. See `validation/ios-workspace.md` and `validation/us3-screenshot.md`.
- [X] T037 [P] [US2] Implement Android clipboard and nonce-bound socket handling in `helpers/android/app/src/main/kotlin/dev/debugutility/helper/ClipboardBridge.kt`
- [X] T038 [P] [US2] Implement iOS runner clipboard commands and privacy-state mapping in `helpers/ios/DeviceBridgeRunnerUITests/ClipboardCommands.swift`
- [X] T039 [US2] Implement host clipboard service and selection-generation invalidation in `packages/DeviceBridgeCore/Sources/DeviceBridgeCore/Operations/ClipboardService.swift`
- [X] T040 [US2] Implement clipboard readiness and explicit read/send UI in `apps/macos/DeviceBridgeApp/Views/ClipboardView.swift`
- [ ] T041 [US2] Run P2 Android/iOS real-device clipboard checks and record results in `specs/001-device-debug-bridge/validation/us2-clipboard.md` (automated evidence: T078)
  - 2026-09-08: exact real paste prompt + independently unfinished READ → authenticated Stop passed without approval/denial tap. Stop ACK, no content, invalid channel within five seconds, phone 1 pass/0 fail/0 skip and cleanup passed (`devicebridge-paste-pending-stop-wvfwbz_u`, host 10.456 s). This terminal case does not claim forty-second renewal or denial/locked/wireless acceptance. Latest default Core run: 354 passed methods + 13 skipped opt-ins (the aggregate summary's 367 includes skips).
  - 2026-09-08: selected-USB exact 1 MiB Workspace round trip and separately written four-item cross-App clipboard both passed. Multi-item source readback verified the complete array before normal Runner READ matched ordered newline joining, including the empty item. One exact user-authorized paste tap, forty-second renewal and Stop passed (host 1 test / 50.874 s, `devicebridge-cross-app-multiple-bc5te2lr`). Physical denial/locked/wireless and visible UI acceptance remain open; this is not a full-story completion claim.

---

## Phase 5: User Story 3 — Capture and Retrieve Visual Artifacts (Priority: P3)

**Goal**: Capture, preview, copy, and save a selected-device screenshot while preserving the previous
valid preview on failure.

**Independent Test**: Capture distinctive Android and iOS screens, save/copy exact bytes, then force
a failed capture and switch devices.

### Tests for User Story 3

- [X] T042 [P] [US3] Write PNG validation, partial publication, failure preservation, cancellation, and stale-result tests in `packages/DeviceBridgeCore/Tests/DeviceBridgeCoreTests/ScreenshotServiceTests.swift`
- [X] T043 [P] [US3] Write iOS runner screenshot response and protected/locked-state tests in `helpers/ios/DeviceBridgeRunnerUITests/ScreenshotCommandsTests.swift`

### Implementation for User Story 3

- [X] T044 [P] [US3] Implement Android target-specific screencap provider in `packages/DeviceBridgeCore/Sources/DeviceBridgeCore/Operations/AndroidScreenshotProvider.swift`
- [X] T045 [P] [US3] Implement XCUIScreen capture response in `helpers/ios/DeviceBridgeRunnerUITests/ScreenshotCommands.swift`
- [X] T046 [US3] Implement artifact staging, PNG validation, token checks, and atomic publication in `packages/DeviceBridgeCore/Sources/DeviceBridgeCore/Operations/ScreenshotService.swift`
- [X] T047 [US3] Implement screenshot readiness, preview, copy, save, and error presentation in `apps/macos/DeviceBridgeApp/Views/ScreenshotView.swift`
- [ ] T048 [US3] Run P3 Android/iOS real-device screenshot checks and record results in `specs/001-device-debug-bridge/validation/us3-screenshot.md` (automated evidence: T079)
  - 2026-09-08: selected personal-signed iPhone completed 100/100 serial encrypted screenshots on one native USB channel, no retries; median 198.173 ms / P95 203.981 ms / maximum 252.882 ms for capture-to-verified-PNG only. Continued 40-second identity renewal, Stop, native exit and independently closed runner port passed. This does not include rendered preview/save timing, generated visual-fixture attribution, locked/protected screens, Android matrix, wireless or long endurance; T048 remains open. Evidence: `devicebridge-screenshot-soak-z2lnp16b/test.log`, detailed in `validation/us3-screenshot.md`.

---

## Phase 6: User Story 4 — Transfer Images and Files (Priority: P4)

**Goal**: Send and retrieve permitted files with scope, cancellation, integrity, and partial-result
semantics.

**Independent Test**: Transfer representative text, binary, image, and 500 MB fixtures in both
directions; cancel one transfer and disconnect another.

### Tests for User Story 4

- [X] T049 [P] [US4] Write path-scope, staging, length/hash, replacement, cancellation, and partial-cleanup tests in `packages/DeviceBridgeCore/Tests/DeviceBridgeCoreTests/FileTransferServiceTests.swift`
- [X] T050 [P] [US4] Write Android ADB and debuggable `run-as` transfer fixture tests in `packages/DeviceBridgeCore/Tests/DeviceBridgeCoreTests/AndroidFileProviderTests.swift`
- [X] T051 [P] [US4] Write iOS CoreDevice domain and restriction fixture tests in `packages/DeviceBridgeCore/Tests/DeviceBridgeCoreTests/IOSFileProviderTests.swift`

### Implementation for User Story 4

- [X] T052 [P] [US4] Implement Android shared/debuggable file provider in `packages/DeviceBridgeCore/Sources/DeviceBridgeCore/Operations/AndroidFileProvider.swift`
- [X] T053 [P] [US4] Implement iOS CoreDevice file-domain provider in `packages/DeviceBridgeCore/Sources/DeviceBridgeCore/Operations/IOSFileProvider.swift`
- [X] T054 [US4] Implement staged transfer, integrity validation, cancellation, and atomic publication in `packages/DeviceBridgeCore/Sources/DeviceBridgeCore/Operations/FileTransferService.swift`
- [X] T055 [US4] Implement native file panels, permitted scopes, progress, cancellation, and replacement confirmation in `apps/macos/DeviceBridgeApp/Views/FileTransferView.swift`
- [ ] T056 [US4] Run P4 Android/iOS real-device file checks including 500 MB integrity, cancellation and peak host memory, and record results in `specs/001-device-debug-bridge/validation/us4-files.md` (automated evidence: T080)
  - 2026-09-08 selected-iPhone USB slice passed through the real FileTransferService: 500,000,000-byte send/receive, matching round-trip SHA-256, remote/local collision protection and cancellation after actual partial bytes with no late publication. Per-chunk hashing release fixed an independently reproduced file-sized RSS increase; final sampled host peak 11,392 KiB / process tree 31,296 KiB. Owned large fixtures reclaimed, empty remote namespace retained. Android is currently absent; physical disconnect, other domains and desktop/wireless qualification remain open. Evidence: `devicebridge-ios-large-service-32xmov3q`, `validation/us4-files.md`.

---

## Phase 7: User Story 5 — Inspect Application Memory (Priority: P5)

**Goal**: Discover eligible applications and show timestamped Android OS and Flutter VM memory trends
without requiring a Flutter project package.

**Independent Test**: Monitor a debug/profile app, change load, restart it, and verify source-specific
metrics and unsupported states.

### Tests for User Story 5

- [X] T057 [P] [US5] Write Android meminfo parsing, missing-field, malformed, PID-change, and restart tests in `packages/DeviceBridgeCore/Tests/DeviceBridgeCoreTests/AndroidMemoryProviderTests.swift`
- [X] T058 [P] [US5] Write Flutter VM discovery, WebSocket JSON-RPC, URI-redaction, GC, disconnect, and restart tests in `packages/DeviceBridgeCore/Tests/DeviceBridgeCoreTests/FlutterVMServiceTests.swift`
- [X] T059 [P] [US5] Write single-flight cadence and bounded trend tests in `packages/DeviceBridgeCore/Tests/DeviceBridgeCoreTests/MemoryMonitorTests.swift`

### Implementation for User Story 5

- [X] T060 [P] [US5] Implement Android application/process discovery and meminfo provider in `packages/DeviceBridgeCore/Sources/DeviceBridgeCore/Operations/AndroidMemoryProvider.swift`; replace advancing `ELAPSED` with kernel start ticks, preserve PID reuse detection, pass regression and two physical continuity checks; see `validation/physical-background.md`
- [X] T061 [US5] Implement Android Flutter VM discovery/ADB forwarding and the shared narrow WebSocket JSON-RPC client in `packages/DeviceBridgeCore/Sources/DeviceBridgeCore/Operations/FlutterVMService.swift`; iOS discovery and verified endpoint binding were not implemented by this task and are tracked by T110–T114
- [X] T062 [US5] Implement source-aware, single-flight, restart-safe trend monitoring in `packages/DeviceBridgeCore/Sources/DeviceBridgeCore/Operations/MemoryMonitor.swift`
  - SC-007 correction (2026-09-08): provider/publication time now consumes the cycle budget rather than adding to a full post-completion sleep. A 2.5-second default leaves headroom under the unchanged three-second freshness requirement. Two work/overrun regressions and a later-slower-request regression were observed RED, then fixed without changing owner/session/Stop semantics. Core 366 tests pass. Six real Workspace samples on the selected wired iPhone had five gaps of 2525.3–2562.2 ms and clean Stop with unchanged app PID/route; this does not complete rendered UI, load/restart/route-switch or endurance acceptance in T064. See `validation/us5-memory.md`.
- [X] T063 [US5] Implement application selection, source labels, timestamps, trend chart, and unsupported states in `apps/macos/DeviceBridgeApp/Views/MemoryView.swift`
- [ ] T064 [US5] Run P5 Android/iOS real-device memory/VM checks and record results in `specs/001-device-debug-bridge/validation/us5-memory.md` (automated evidence: T081)
  - Latest resumed test: normal Workspace six-sample discovery/renewal/Stop passed on the user-started VM. A 120-sample run with explicitly authorized MobAI dashboard scrolling remained device/process bound but FAILED the three-second gate (max 3725.7 ms). A timed 60-sample scrolling repeat passed functional sampling/Stop with max 2657.4 ms; no RPC >=200 ms was recorded. The original delay is not yet attributed or fixed. Keep interaction-load cadence acceptance open; no target restart, business-button action or production scheduling/identity change. See `validation/us5-memory.md`.
  - Authorized SIGTERM attempt `devicebridge-workspace-memory-termination-aqe91vg7`: one freshly revalidated exact-PID signal accepted; VM timed out and Workspace became empty/not-ready/stopped within 7.996 seconds from the ready receipt. Outer acceptance FAILED because the PID/executable remained in independent inventories. Do not count this as process exit/restart; no repeat signal or force kill performed. User-assisted Debug stop/relaunch is still needed.
  - Same-Workspace coexistence pass: `devicebridge-workspace-coexist-ml81cfgo` ran the actual signed screenshot runner and native VM provider together. At least three attributed samples before and three after a decoded/export-verified screenshot; monitor remained active, target PID/executable and paired USB unchanged, helper cleaned up. No clipboard command or target restart. Bootstrap still presses Home; foreground preservation and sustained/background/locked/wireless combined use are not qualified.
  - Stop/Discover physical pass: `devicebridge-workspace-memory-rediscovery-saxlq5vc` exercised one initial plus two fresh same-Workspace connections, six attributed samples each, no automatic sampling on metadata readiness, no old timestamps and clean Stop each time. Target process and paired USB route remained unchanged. Test-only probe extension; no production change. Actual target restart/network switch remain unqualified.
  - Post-correction USB endurance pass (2026-09-08): user restarted the exact target; fresh binding admitted its new PID. `devicebridge-workspace-memory-trace-bahkg0ph` completed 120 attributed samples over at least 290 seconds, max capturedAt gap 2602.3 ms, stable PID/isolate despite a 3 ms timestamp range, clean Stop and independent unchanged PID/paired wired route after the run. This completes the bounded five-minute USB slice, not rendered UI, Wi-Fi, background/lock or deliberate restart/switch acceptance.
  - Sustained correction (2026-09-08): real native trace falsified the experimental 1 ms startTime bound (94 metadata / 30 memory RPCs, 2 ms range, no transport error). Reviewed correction retains numeric validation and the non-reopening stream/PID/isolate/app/session ownership, removes timestamp extrema, and passes 356 executed Core methods plus 13 skips. A separate repeat encountered transport closure; the post-correction attempt stopped at preflight because the previously sampled process disappeared. Five-minute real-device acceptance remains open; no app restart or automatic target replacement was performed. See `validation/us5-memory.md`.

### Restored iOS scope for User Story 5 (2026-09-07)

Existing IDs and completed Android/shared-client work are preserved. These tasks decompose the
missing iOS scope rather than adding features. No iOS VM sample may be claimed device-bound merely
because the user selected an iPhone and entered a loopback URI.

- [X] T110 [US5] Reproduce unverified manual VM attribution and specify binding, wrong-device, same-PID/different-device, restart and stale-generation rejection in `packages/DeviceBridgeCore/Tests/DeviceBridgeCoreTests/FlutterVMServiceTests.swift`, dedicated `IOSFlutterVMDiscoveryTests.swift` / `IOSVMMetadataChannelTests.swift`, and `scripts/verify-workspace-ios-memory.swift`; use synthetic endpoints, never personal VM URIs
- [X] T111 [US5] After T110, distinguish unverified VM candidates from verified device/process bindings in `packages/DeviceBridgeCore/Sources/DeviceBridgeCore/Operations/IOSFlutterVMDiscovery.swift`, preserve the unverified-client gate in `FlutterVMService.swift`, and gate manual attach in `apps/macos/DeviceBridgeApp/ViewModels/WorkspaceViewModel.swift`; keep an actionable unsupported/unverified state instead of attributing samples to the selected device without proof
  - 2026-09-08 admission slice: reproduced URI-only iOS attribution for missing/matching PID and foreign-VM restart publication; Core now rejects iOS before RPC, Workspace rejects manual iOS attach and disables the button with bilingual guidance. Headless checks preserve Android admission and reject stopped Workspace attachment. Core 294 tests pass. T110/T111 remain open: verified binding types and restart/stale-generation admission tests still require the qualified discovery path; blocking unsafe attribution is not working iOS memory.
  - 2026-09-08 continuity slice: `IOSVMMetadataChannel.swift` and its tests qualify protocol4.16/Dart3.7.2, expected PID, pinned isolate and <=1 ms total timestamp range on one private native transport owner. Initial/renewal late-result and drift tests added; auto-selection ambiguity found in review and fixed test-first. Ten physical VM observations passed with independent PID/USB route checks. No verified device/session binding or memory sampling is enabled by this slice; T110/T111 stay open.
  - 2026-09-08 binding slice: `IOSVMCandidate` is redacted and unverified; only `IOSFlutterVMDiscovery.verify` constructs `IOSVerifiedVMBinding` after independent app/path/PID and captured-store checks on one native owner. Nine focused binding tests pass including same-PID/wrong-device, stale/cancelled five-boundary qualification, terminal/late renewal and owner replacement. Review fixed close-error classification. Physical issuance/renewal/probe-local invalidation passed, Core 338 tests and manual-admission headless checks pass. T110/T111 remain open for integrated Workspace binding/sample acceptance, not metadata-only evidence.
  - Completion gate (2026-09-08): T110/T111's admission/type requirements are now met by real binding/read tests plus the unchanged headless manual gate. Core 351 tests pass; explicit physical binding reads passed twice. Earlier open notes above are historical. Consuming the binding in Workspace is T114, not a circular prerequisite for T111 completion. This does not claim UI memory delivery.
- [X] T112 [US5] After T111, run a metadata-only physical iOS debug/profile discovery and exact-device forwarding experiment, recording process/bundle/PID correlation, USB/Wi-Fi limitations, endpoint redaction and cleanup in `specs/001-device-debug-bridge/validation/ios-vm-discovery.md`; use T082 transport evidence where applicable, do not require a target Flutter package or infer identity from a Bonjour display name
  - 2026-09-08: two Bonjour hints resolved; selected USB WebSocket origin returned 302 to loopback. Explicit device-originated DDS protocol/identity/delegation checks passed subsequently. Direct HTTP then passed two `getVM → getVersion → getVM` sequences, each on one exact USB Connect (Dart 3.7.2 / VM protocol 4.16), with independent app PID/route checks. Plan refined to native persistent USB HTTP polling, retaining Android redirect compatibility. T112 remains open for a reproducible native qualification path; these are metadata-only experiments, not memory or wireless acceptance. See `validation/ios-vm-discovery.md`.
  - Completion gate (2026-09-08): native process provider, native Bonjour and exact-device issuer/renewal/probe-local invalidation subsequently passed together. Metadata-only evidence `r4wp96dy` qualifies the pinned USB route; wireless remains unsupported/unqualified. This satisfies the route feasibility experiment, not full T064 acceptance.
- [X] T113 [US5] After T112 passes for a route, test then implement route-owned iOS VM discovery/forwarding in `packages/DeviceBridgeCore/Sources/DeviceBridgeCore/Operations/IOSFlutterVMDiscovery.swift` and `packages/DeviceBridgeCore/Tests/DeviceBridgeCoreTests/IOSFlutterVMDiscoveryTests.swift`; enforce captured session, bounded probing, PID/start identity verification, cancellation and exact resource cleanup
  - Native HTTP prerequisite: one exact-device USB owner, single-flight bounded framing/deadline, empty-string RPC ID validation, and terminal closure on EOF/redirect/event/cancellation. Tests must forbid hidden Connect/retry and publication after owner invalidation before production discovery is admitted.
  - 2026-09-08 native transport slice: `IOSVMHTTPTransport.swift` / `IOSVMHTTPResponse.swift` and matching tests implemented; 14 focused tests and Core 308 general tests pass. Independent review completed with one parser fix and an explicit HTTP ordering limitation. Physical native metadata reached the correct app/protocol but observed 1 ms startTime variation; admission remains unverified pending identity-semantics tests. No iOS sampling or discovery UI enabled; T113 stays open.
  - 2026-09-08 independent process slice: `IOSApplicationProcessProvider.swift` reads selected-device Details/Apps/Processes/Details, validates paired wired scope and unique main executable/PID mapping, and removes bounded private JSON output. Eight focused tests pass after three review regressions; native provider + ten VM observations passed twice physically, including after fixes. Full serial Core run retains an unrelated public-copy fixture failure and passing isolated recheck. Inventory is not a binding; T113 remains open for native Bonjour and session-owned admission.
  - 2026-09-08 native Bonjour slice: `IOSVMBonjourDiscovery.swift` uses system DNS-SD on one owning serial queue, bounded local scope/records/time, app-name hints, strict TXT parsing and before-return reference disposal. Nine tests and independent review cover cancellation/late callbacks, remove/re-add generations, limits and redaction. Core 347 tests pass. Physical native browse found two hints; exact-device issuance rejected the first, accepted the second, renewed and terminally invalidated it. T113 stays open for production orchestration and Workspace handoff; earlier single-hint probe failures remain in validation.
  - Completion gate (2026-09-08): production `discover(session:applicationID:)` now prevalidates the selected app, browses app-scoped hints and qualifies at most four sequential candidates under one 60-second admission budget (not a cleanup wall-clock guarantee). Provider identity/route/metadata errors are terminal; cleanup failure survives cancellation and double error mapping. Review regressions were reproduced then fixed. Physical `jpp97xyz` used this entry and the real MemoryMonitor loop: two samples, clean Stop/close, unchanged independent PID/wired route, exit zero and empty stderr. Core 363 tests pass. Returning the verified owner completes Core handoff; Workspace commit/readiness is T114. Earlier open notes are historical; Wi-Fi remains unqualified.
- [X] T114 [US5] After T111/T113, wire verified iOS VM readiness and explicit monitoring into `apps/macos/DeviceBridgeApp/ViewModels/WorkspaceViewModel.swift` with headless checks in `scripts/verify-workspace-ios-memory.swift`; preserve Android behavior, stop on device/route/process changes, label heap/external/RSS distinctly and hand off physical load/restart/switch checks to T064
  - Pin an explicitly selected isolate; auto-select only an unambiguous single candidate. Isolate exit/replacement terminates its series. Metadata readiness must not invoke memory sampling. The pinned runtime returns shared group heap through that isolate; do not claim exclusive per-isolate or total app memory, or sum sibling readings.
  - 2026-09-08 sampling prerequisite: explicit binding.readMemory() now passed focused stale/cancel/close/metric tests and two real iPhone probes with two samples each. A review regression prevented a usage RPC after session change during preflight getVM. Core 351 tests and manual-admission headless check pass. T114 remains open for MemoryMonitor adapter, lifecycle-safe Workspace/UI wiring and Debug integration.
  - 2026-09-08 monitor slice: the verified binding now conforms to MemorySampling with exact target/transport guards. `invalidated` terminates the loop and clears the series; ordinary Android failures retain retry/trend behavior. Monitor revision prevents Stop/new-Start late results, and store completion atomically consumes publication eligibility. Workspace handles the new terminal event and CN/EN messages exist, but it does not yet discover/commit/start an iOS binding. Physical production-monitor probe and final manual-admission headless checks pass; current Debug UI has not been rebuilt/relaunched. Next: lifecycle-safe app inventory/selection → discovery commit → metadata renewal/explicit Start/Stop → headless checks → incremental Debug.
  - Completion gate (2026-09-08): Workspace now owns app-scoped discovery, exact-session/revision binding commit, 10-second idle metadata renewal, explicit Start and terminal Stop/route/App invalidation. iOS has Start/Discover/Stop instead of a manual URI; shared-group metrics are bilingual. A store-only stale callback readiness bug and screenshot-preparation admission blockage were reproduced and fixed. Five headless groups and existing screenshot isolation regression pass; Core 363 tests pass. Physical Workspace probe `2qslnj7u` passed discovery, 12-second idle renewal, two attributed samples and stable Stop, with independent PID/USB route unchanged. Final incremental Debug build and strict signature verification passed; exact Debug app launched in background and its new process was verified. This is not global desktop UI automation or T064 load/restart/Wi-Fi acceptance. Clipboard content permission remains separate.

Independent iOS acceptance: the selected debug/profile app produces changing, timestamped VM
metrics without project changes; Mac/other-phone endpoints cannot populate its chart; process
restart and device/route changes terminate the old series. Release/no-service states stay explicit.

---

## Phase 8: Managed Helper Keep-Alive and Cross-Cutting Release Work

**Purpose**: Complete the one-application helper experience, privacy hardening, packaging, and final
qualification across stories.

- [X] T065 [P] Write Android lease start/renew/expiry/stop/reboot/crash tests in `helpers/android/app/src/test/kotlin/dev/debugutility/helper/KeepAliveServiceTest.kt`
- [X] T066 Implement Android connected-device foreground service, notification Stop action, Wi-Fi lock, and orphan timeout in `helpers/android/app/src/main/kotlin/dev/debugutility/helper/KeepAliveService.kt`
- [X] T067 Implement Mac-side helper lease renewal and shutdown cleanup in `packages/DeviceBridgeCore/Sources/DeviceBridgeCore/Helpers/AndroidKeepAliveController.swift`
- [X] T068 Embed versioned helper artifacts and manifests in `apps/macos/DeviceBridgeApp/Resources/Helpers/`
- [X] T069 [P] Add accessibility labels and keyboard navigation checks in `apps/macos/DeviceBridgeAppUITests/AccessibilityUITests.swift`
- [X] T070 [P] Add privacy log audit fixtures and payload absence assertions in `packages/DeviceBridgeCore/Tests/DeviceBridgeCoreTests/PrivacyAuditTests.swift`
- [X] T071 Configure hardened runtime and direct-distribution entitlements in `apps/macos/DeviceBridgeApp/DeviceBridgeApp.entitlements`
- [X] T072 Add internal build, helper signing, archive, and notarization instructions in `README.md`
- [ ] T073 Run Swift, Xcode, Kotlin, UI, privacy and packaging automated validations and record exact commands, versions and results in `specs/001-device-debug-bridge/validation/final-automated.md`; reopened after localization rerun: core 136 and Release pass, latest fixture UI 7/9 with unresolved keyboard-feedback and pre-switch memory-start failures; earlier baseline evidence retained, no real-device results inferred
- [ ] T074 Execute `quickstart.md` end to end and record remaining platform-specific limitations in `specs/001-device-debug-bridge/validation/final-real-device.md`

---

## Phase 9: Analysis Remediation and Explicit Qualification

Original IDs are retained for traceability. The increase in task count decomposes existing scope;
it does not add product features or relax real-device acceptance. T073 tracks automated evidence
only and reopens when affected checks cannot run. T074 requires story and quantitative checks.

- [X] T075 Specify iOS IPC evidence, resource ownership, wire limits and go/no-go criteria in `specs/001-device-debug-bridge/contracts/ios-runner-channel.md`
- [X] T076 [US2] Reproduce iOS stop/build/open, cancellation, duplicate preparation and late-result races with deterministic gates in `packages/DeviceBridgeCore/Tests/DeviceBridgeCoreTests/IOSRunnerManagerTests.swift`
- [X] T077 [US2] Fix iOS preparation cancellation, per-attempt resource cleanup and stale publication guards in `packages/DeviceBridgeCore/Sources/DeviceBridgeCore/Helpers/IOSRunnerManager.swift`; record red/green evidence in `specs/001-device-debug-bridge/validation/ios-runner-lifecycle.md`
- [X] T078 [US2] Record P2 automated clipboard/helper checks in `specs/001-device-debug-bridge/validation/us2-clipboard.md`; real-device acceptance stays in T041
- [X] T079 [US3] Record P3 automated screenshot/provider/UI checks in `specs/001-device-debug-bridge/validation/us3-screenshot.md`; real-device acceptance stays in T048
- [X] T080 [US4] Record P4 automated scope/integrity/cancellation checks in `specs/001-device-debug-bridge/validation/us4-files.md`; real-device acceptance stays in T056
- [X] T081 [US5] Record P5 automated memory/VM/restart checks in `specs/001-device-debug-bridge/validation/us5-memory.md`; real-device acceptance stays in T064
- [ ] T082 [US2] Execute the identity-only physical iOS transport experiment in `specs/001-device-debug-bridge/contracts/ios-runner-channel.md`, record pinned dependency/version, USB/Wi-Fi route proof, nonce bootstrap, lifetime and latency in `specs/001-device-debug-bridge/validation/ios-channel-spike.md`, and choose or reject the transport before production channel work; environment secret bootstrap was rejected. Replacement public-container pinning + mutual TLS 1.3 passed 31 physical exchanges and the available marker audit; the later actual in-memory nonce/challenge identity + bound Stop also passed on the personal-signed iPhone (1 executed test, 0 skips, native relay clean, listener closed). Full secure lifecycle/adversarial evidence and wireless disposition remain open
- [X] T083 [US2] After T082's recorded USB-candidate GO (overall wireless gate stays open), fixture-test then implement attempt-scoped build products, signed install/start, timeout and child-process cleanup in `packages/DeviceBridgeCore/Sources/DeviceBridgeCore/Helpers/IOSRunnerManager.swift` and a concrete `packages/DeviceBridgeCore/Sources/DeviceBridgeCore/Helpers/IOSRunnerLauncher.swift`; reuse the selected existing personal development identity, gate provisioning updates on explicit consent instead of unconditional `-allowProvisioningUpdates`, and verify the concrete launcher on a signed reference device. Completed selected-USB backend scope: the actual native factory/launcher ran the signed reference iPhone through authentication, 40 seconds of heartbeat and Stop twice; post-absolute-deadline-fix run passed in 47.339 s, phone 1 pass/0 skips, child exit zero and cleanup verified. Evidence in `validation/ios-channel-spike.md`. No production content readiness until T084/T036 acceptance
- [ ] T084 [US2] After T082/T083, test then implement authenticated persistent framing, identity/clipboard/screenshot dispatch and lease/stop handling in `helpers/ios/DeviceBridgeRunnerUITests/` and `packages/DeviceBridgeCore/Sources/DeviceBridgeCore/Helpers/IOSRunnerChannel.swift`, including bounded binary attachments and invalid-message tests
  Latest selected-USB clipboard qualification (2026-09-08): user explicitly authorized the exact test-phone paste approval. MobAI single tap succeeded but old code still rejected foreground; two new signed-phone tests reproduced immediate post-read rejection. A bounded, owner/deadline/cancellation-preserving read-publication settlement now passes all 32 phone clipboard tests. Actual separate-Host source → authorized Allow Paste → normal encrypted Runner READ exactly matched, followed by 40-second renewal/Stop/cleanup (host 1 pass in 49.756 s; `devicebridge-cross-app-settled-655_cciq`). Core 366/56 passes. No production auto-approval or WRITE guard change. Together with the earlier normal Runner WRITE round-trip, this permits the next focused T036 selected-USB explicit clipboard binding; full T041/T084 remain open for remaining adverse, UX and wireless acceptance. Prior blocked/no-permission notes below are historical.
  Latest observation (2026-09-08): user-authorized interruption released the app-owned Runner without exiting the Mac app. Read-only phone audit directly observed a paste-approval prompt while READ remained pending and UIKit became inactive (0 pass / 0 fail / 1 skip); no approval was clicked. MobAI CLI is now usable and exactly device-matched; 12 successful UI observations coexisted with a normal encrypted READ/renew/Stop test (1 pass in 48.143 s). That existing READ test allows empty text, so positive cross-App/permission and Workspace clipboard qualification remain open. See the latest `validation/us2-clipboard.md`; “MobAI unavailable” notes below are historical.
  Latest cross-App discrimination (2026-09-08): a compile-time/runtime opt-in separate Host successfully wrote and read back disposable text; the unchanged encrypted Runner READ returned `actionRequired` (`devicebridge-clipboard-cross-app-os4nlrjg`, host 1 fail in 23.723 s). This harness did not inspect permission alerts and no approval was automated, so do not infer the cause from status alone. A later read-only probe stopped at preflight because the running Mac Debug app owned a new Runner session; that connection was left intact. Cross-App/permission and Workspace clipboard gates remain open. See latest `validation/us2-clipboard.md` for the genuine negative control, no-write Host preflight and source-stage evidence.
  Latest authorized positive control (2026-09-08): after explicit disposable-text replacement confirmation, one normal encrypted WRITE and a separate READ exactly matched on the real iPhone; host 1 pass in 50.242 s, phone 1 pass / 0 skips, 40-second renewal/Stop/native cleanup passed (`devicebridge-clipboard-replacement-3o6_8sje`). Original contents were not backed up/restored; no automatic write retry or permission approval. This qualifies same-origin exchange only. Cross-App source/permission handling and Workspace clipboard integration remain open; older failures below are historical, not a claim that every current WRITE fails.
  Latest read-only discrimination (2026-09-08): externally activated signed-phone READ now returns with UIKit active and MainActor responsive; no recognized paste prompt was observed. Strengthened positive-text acceptance correctly skips instead of accepting the empty success response (`devicebridge-clipboard-wait-evidence-nqlvwf1r`, 0 pass / 0 fail / 1 skip). This neither proves paste permission nor qualifies original-content READ. No general WRITE/approval occurred. Do not repeat empty reads as progress; the next positive-control test requires an authorized known text state without automatically overwriting the user's clipboard. See the latest section of `validation/us2-clipboard.md`.
  Latest clipboard correction (2026-09-08): actual WRITE again returned cancelled (6.118 s), no automatic retry. Investigation proved XCTest foreground may coexist with UIKit inactive; the active-state metadata-only audit reports real content whereas earlier inactive reads appeared empty. Production now requires exact runner foreground AND UIKit active; 30 signed phone tests pass. Prior non-nil empty READ evidence proves framing/lease but not functional system clipboard access. Consistent-empty backup handling and conflict/intervening-writer protections are covered, but original-content READ/WRITE and permission flow remain unqualified. See `validation/us2-clipboard.md`; the following WRITE notes are historical.
  WRITE evidence (2026-09-08): preserving test wrapper and shared production synchronous setter/readback boundary pass 28 signed phone named-board fixtures. Two independent-review ownership defects were reproduced RED and fixed. The actual encrypted general WRITE attempt failed acknowledgement in 6.055 s and was not retried; subsequent encrypted READ/40-second lease/Stop passed in 46.525 s with the synthetic write fixture absent. Two read-only audits reproduce an unavailable/empty full-item backup (skipped, not accepted). Discriminate genuine emptiness from unreadable/redacted data before relaxing the preserving probe. General WRITE/restoration and permission waiting remain unqualified. Fresh regressions: Core 286 / SecureChannel 77 / packaging 5 pass; detailed evidence in `validation/us2-clipboard.md`.
  Additional qualification (2026-09-08): eight whole-channel screenshot cases pass: missing descriptor, missing attachment, truncated attachment, wrong digest, wrong offset, wrong request ID, duplicate descriptor and attachment expiry. Omitting final digest/PNG validation makes the wrong-digest test fail; validation restored. ScreenshotService preserves six runner-status categories plus malformed-transfer versus closed-channel errors, with Chinese messages and no publication on failure. Latest Core regression: 286 tests / 49 suites pass; this does not complete permission waiting, general WRITE/restoration, UI, locked/protected-screen or wireless acceptance.
  Partial: clipboard-capable session server and heartbeat/Stop concurrency are fixture-tested, with terminal ordering independently reviewed. Production host correlation/activation and iOS handlers are now wired. An actual encrypted system-pasteboard READ, 40-second heartbeat, Stop, native child exit and cleanup passed on the selected personal-signed iPhone in 48.982 s. Physical failures revealed and fixed CoreDevice integer-only timeout parsing and asynchronous foreground settlement. Screenshot metadata/binary chunks, exact partial-file staging and PNG/length/hash validation are implemented (30 server methods, 11 wire methods, 20 host channel/receipt methods; 6 signed phone screenshot fixtures pass). Actual encrypted XCUIScreen capture followed by 40-second heartbeat/Stop/cleanup passed in 45.936 s on the same selected personal-signed phone. General clipboard WRITE/restoration, permission-wait flow, remaining screenshot adverse-path qualification and Mac UI readiness remain open; see `validation/ios-channel-spike.md`, `validation/us2-clipboard.md` and `validation/us3-screenshot.md`.
- [X] T085 Define reference conditions, sample sizes, thresholds and evidence fields for SC-008/011/012/013/014/016/017 in `specs/001-device-debug-bridge/validation/qualification-protocol.md`
- [ ] T086 Execute the 10-person first-use usability trial for SC-008 and record per-participant outcomes in `specs/001-device-debug-bridge/validation/usability-results.md` using T085
- [ ] T087 Measure 30 startup runs, 30 selections per platform and UI responsiveness during monitoring/500 MB transfer for SC-011/012 in `specs/001-device-debug-bridge/validation/latency-results.md` using T085
- [ ] T088 Run four-hour Android Wi-Fi qualification per reference device with at least 100 classified recovery trials for SC-013 and record time-series evidence in `specs/001-device-debug-bridge/validation/wireless-soak-results.md` using T085
- [ ] T089 Inject 100 drop/recovery races with delayed results for SC-014, prove zero wrong-device commands/stale publications, and record exact schedules and outcomes in `specs/001-device-debug-bridge/validation/recovery-race-results.md` using T085
- [ ] T090 Validate fresh Mac installation plus missing/outdated helpers on Android/iOS for SC-016/017, including signing/permission recovery, and record outcomes in `specs/001-device-debug-bridge/validation/first-use-results.md` using T085
- [X] T091 [US1] Write command-driven health/recovery integration tests in `packages/DeviceBridgeCore/Tests/DeviceBridgeCoreTests/ConnectionMaintenanceTests.swift` and `AndroidConnectionTransportTests.swift` covering five-second single-flight probes, operation yielding, failure invalidation, known/mDNS endpoint recovery, stable helper-identity checks, USB preference and stale-result guards at external boundaries; TCP deadline and helper reattach regression tests also pass
- [X] T092 [US1] After T024, connect discovery refresh and connection maintenance to selection, operation admission, readiness restart and shutdown in `apps/macos/DeviceBridgeApp/ViewModels/WorkspaceViewModel.swift`; add fixture integration tests and replace snapshot-only UI status in `apps/macos/DeviceBridgeApp/Views/WorkspaceView.swift` only once the production loop is verified
  - Recovery/rebind/device-switch test passed individually and in the 8-test fixture UI suite on 2026-09-07 at 14:04–14:05. Earlier automation initialization failures are retained as history in `validation/ui-automation.md`; no permissions or production code changed to obtain this result.
- [X] T093 Reproduce fast-process exit hangs and replace blocking run-loop waits with pre-launch exit observation in `packages/DeviceBridgeCore/Sources/DeviceBridgeCore/Commands/HostCommandRunner.swift`; protect with existing timeout/cancellation/output tests and rapid-exit regression in `packages/DeviceBridgeCore/Tests/DeviceBridgeCoreTests/HostCommandRunnerTests.swift`, with evidence in `specs/001-device-debug-bridge/validation/process-exit.md`

---

## Dependencies & Execution Order

### Approved language slice (independent of remaining physical-device work)

- [X] T094 [US6] Test system/explicit/fallback language and opaque formatting in `packages/DeviceBridgeCore/Tests/DeviceBridgeCoreTests/InterfaceLanguageTests.swift`; add switching/persistence/preserved-state UI coverage in `apps/macos/DeviceBridgeAppUITests/DeviceWorkspaceUITests.swift`
- [X] T095 [US6] Implement bundled translation catalog and language/message types in `packages/DeviceBridgeCore/Sources/DeviceBridgeCore/Localization/`; preserve fallback text and raw arguments
- [X] T096 [US6] Add persisted language control in `apps/macos/DeviceBridgeApp/App/DeviceBridgeApp.swift` and localize all workspace views and feedback without restarting the model/session
- [ ] T097 [US6] Verify core/UI/Release and Chinese layout, record evidence in `specs/001-device-debug-bridge/validation/localization.md`, and update `README.md`

Order: T094 → T095 → T096 → T097. Existing real-device/iOS tasks remain open.

### Phase Dependencies

- Phase 1 has no dependency and creates the native workspaces.
- Phase 2 depends on Phase 1 and blocks all user stories.
- US1 depends on Phase 2 and is the MVP.
- US2–US5 depend on the US1 active-session contract but remain independently testable by their own
  operation service and UI panel.
- Phase 8 depends on the desired stories and completes helper/release qualification.
- Phase 9 preserves the original iOS/acceptance scope with explicit dependencies: T075 → T076 →
  T077; T075 → T082 → T083 → T084 shared channel + capability-specific gates → T036 corresponding capability → T041/T048. T085 defines T086–T090 measurements;
  their completed results plus story real-device checks are prerequisites for T074.
- Current delivery priority is qualified T082/T083/T084 screenshot → T036 screenshot, then remaining T084 clipboard → T036 clipboard → T041/T048, followed by the iOS
  memory path T110 → T111 → T112 → T113 → T114 → T064. T112 may independently investigate
  metadata once T111 protects attribution; it can reuse qualified T082 route primitives but does
  not depend on the XCTest clipboard/screenshot dispatcher. No physical acceptance is inferred
  from fixture tests or helper installation. Keep T082 open until its route/security decision is recorded.
- Production-call-site review reopened T024/T029: `ConnectionSupervisor` was referenced only by its
  unit tests, and wireless real-device evidence was NOT RUN. T091 → T024 → T092 must precede T029,
  T088/T089 and T074. Helper lease renewal T065–T067 does not satisfy host ADB recovery.

### Within Each Story

- Run every listed test before its production task and confirm the expected feature-missing failure.
- Models and parsers precede services; services precede SwiftUI integration.
- No feature service writes `WorkspaceSnapshot` directly.
- A story checkpoint requires fresh automated evidence plus its real-device validation record.

### Parallel Opportunities

- T003 and T004 can proceed in parallel after T001/T002 paths are established.
- T007–T009 own separate foundational files.
- Parser, inventory, session, and supervisor tests T014–T018 own separate files.
- Android and iOS provider tests/implementations in US2–US5 can proceed independently.
- Accessibility and privacy audits T069–T070 are independent after the UI/core exist.

## Parallel Example: User Story 1

```text
Task: T014 — ADB parser tests
Task: T015 — CoreDevice parser tests
Task: T016 — inventory preference tests
Task: T017 — session generation tests
Task: T018 — supervisor tests
```

## Implementation Strategy

### MVP First

1. Complete native workspace setup.
2. Complete foundational contracts with red-green TDD evidence.
3. Complete US1 discovery, selection, and stale-result protection.
4. Stop and validate the native Mac MVP on current Android and iOS devices.

### Incremental Delivery

1. US1: trusted connection and device switching.
2. US2: Mac-managed helpers and clipboard.
3. US3: screenshots and artifact handling.
4. US4: scoped file/image transfer.
5. US5: Android and Flutter VM memory trends.
6. Cross-cutting keep-alive, packaging, signing, and privacy qualification.

## Notes

### Approved trial feedback (2026-09-07)

- [X] T108 [US1] Test then implement selectable readiness cards and one retained visible module in `WorkspaceView.swift`; preserve inputs, album page/preview and memory monitoring, suspend hidden album thumbnails, localize selected feedback and verify without desktop takeover.
- [X] T109 Verify T108 with headless presentation/model checks and incremental Debug build/run only; record evidence in `validation/module-navigation.md`. No Release or DMG. Desktop interaction QA remains user-driven.

- [X] T104 [P] [US2] Test then implement complete current textual clipboard items, explicit large-payload boundaries, long-text viewing/copy/save in helper, ClipboardService and ClipboardView. No history or background content polling.
- [X] T105 [P] [US1] Test then separate silent inventory polling from initial/manual loading presentation, publish only meaningful sidebar changes, preserve selection and real disconnect handling in WorkspaceViewModel/WorkspaceView.
- [X] T106 [US4] Test then implement bounded on-demand album thumbnails, selected preview/original download, and unambiguous Images/File transfer and image selection styling. Preserve session cancellation and exclusive/confirmed original export.
- [X] T107 Verify core, headless presentation checks, helper build and Release packaging; record exact evidence and produce a new internal DMG without desktop UI takeover. Retain separate physical/iOS qualification gaps. Evidence: `validation/trial-feedback-20260907.md`.

### US4 image-first follow-up (Android implemented; full physical/UI and iOS qualification pending)

- [X] T098 [US4] Agree the image-source, preview and original-export design for FR-P01–FR-P03 in `spec.md`; interaction confirmed by the user, design in `plan.md` and `contracts/phone-images.md`, Android existing-screenshot probe in `validation/phone-images.md`; iOS remains behind the T102 physical gate, not claimed working.
- [X] T099 [US4] After T098, add image-provider and session-invalidation regression tests before implementing listing, metadata, preview and original retrieval in `packages/DeviceBridgeCore/`; specify provider contracts in `contracts/device-service.md` first. Android production USB evidence, bounded raw reads and review fixes: `validation/phone-images.md`.
- [X] T100 [US4] After T099, add the native image browser with source-device labels and Chinese/English feedback in `apps/macos/DeviceBridgeApp/Views/`; retain general file transfer separately. Production view-model console checks pass; actual isolated UI interaction stays in T101, not claimed passed.
- [ ] T101 [US4] Qualify SC-P01–SC-P02 on the designated Android and iPhone using backend tests and an actually isolated UI session; record supported and unsupported image scopes in `validation/us4-files.md`.
- [X] T102 [US4] Run the public ImageCaptureCore USB go/no-go experiment in `contracts/phone-images.md`: exact selected-phone identity, complete catalog, PNG/JPEG/HEIC thumbnail and original-presentation downloads, actual cancellation, late-result isolation and acknowledged close passed on the designated iPhone 12. No new Mac permission/entitlement was needed for this probe; evidence and remaining production limits are in `validation/phone-images.md`. T103 remains the separate production gate.
- [X] T103 [US4] After T102/T099, implement the main-actor ImageCaptureCore provider and workspace-owned discovery in `packages/DeviceBridgeCore/`, wire the proven USB scope into T100, and preserve restriction/original-representation/integrity labels. Actual Workspace→model→provider catalog, album thumbnails, PNG/JPEG/HEIC preview/export, cancellation, refresh and reselection passed; red/green and review evidence plus soft transit-limit caveat: `validation/ios-images-runtime.md`. Visual/expanded physical qualification stays in T101.

- The abandoned Flutter scaffold is intentionally not deleted by these tasks.
- Device IDs, helper nonces, clipboard text, VM URIs, and artifact bytes never enter validation logs.
- Helper installation is a Mac-app workflow; signing or platform consent may still require an explicit
  developer action.
- No task authorizes Git staging, commits, publishing, or destructive cleanup.


### Build 7 closure execution checkpoint — 2026-09-08

T115/T117/T118/T124/T125/T127/T128 are complete within their scoped definitions. Build 7 is packaged;
381 Core tests passed serially, language checks 6/6, headless workspace checks and 64 KiB real file
provider roundtrip passed. Current default-concurrent timing-fixture failures are retained in evidence.
T116/T119 remain open for complete authenticated startup; T120/T121 for source/adverse phone
conditions; T122 for real save failure; T123 for new GUI receive and USB-photo reconnect; T126 for
Developer ID/notarization/clean-host prerequisites. None of these is silently satisfied by a subset.
See [release-closure-20260908.md](validation/release-closure-20260908.md).
