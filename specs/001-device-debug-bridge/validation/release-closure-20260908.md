# Build 6 remaining-work closure — 2026-09-08

Current execution: SpecKit T115–T128. This file supersedes stale summary status only for observations
recorded here. The full original story/quantitative tasks remain open until all of their criteria pass.

| Area | Baseline | Current outcome / next evidence |
|---|---|---|
| Preparation speed | ~45 s timestamp observation; build repeated in unique directory | Baseline isolated build 28.935 s. Incremental design: cold 31.128 s; warm 2.596 / 2.059 s; real signatures/config passed. Full authenticated readiness still pending Build 7 switch. |
| Clipboard | Build 6 public write→clear→exact read twice passed | Original source app still requested. Public 67-byte Unicode and 15,871-byte / 256-line send→clear→read match. Command-Return, expand, copy/paste and text save pass in Build 6. |
| Adverse paths | Core/simulator cancellation and failure evidence exists | Actual denial/locked/unplug/recovery pending user-controlled conditions |
| Screenshots | Build 6 10/10 capture+preview, 1.852–2.414 s CUA-inclusive | Build 6 copy and save match exactly (1170×2532 PNG). Cancel save retained the same preview/timestamp and no success receipt. |
| Images/files | Earlier real provider and 500 MB service passes | Build 6 public 69-byte send passed; two receive attempts stalled in CoreDevice bookmark/getxattr and cancelled with zero partials. Temporary staging fix has 10 provider/service tests passing; updated GUI retest pending. Image load returned an explicit unmatched USB-photo-device recovery message; requires reconnect and retest. |
| Language/UI regression | Historical full fixture suite 7/9; causes unqualified | Refresh label drift corrected; keyboard fixture asserts enabled input and exact roundtrip. Three headless first-sample/Stop passes at 3 ms. CUA English/Chinese/system switch preserves fields and translates cancellation status. Mac UI tests compiled only; no global XCTest input. |
| Wireless | Production iOS clipboard/screenshot guard requires USB | Scope clarification requested; unsupported boundary remains explicit |
| Distribution | Local Build 6 ad-hoc signed DMG | No Developer ID in local identity inventory; clean host not supplied |
| VM | Explicitly deferred by user | No real VM stability work in this closure |
| Cleanup | Prior isolated test processes exited | Verify after every further fixture use and final handoff |

SpecKit prerequisites: existing plan retained; task template resolved; requirements checklist 16/16
checked; no extension hooks configured. Workspace is non-Git. No checklist markers were changed.


## Preparation implementation and evidence

- Root cause of avoidable repeated build cost: each new selected-session manager used a fresh DerivedData
  directory. Regression failed on unequal compiler input paths (`/tmp/devicebridge-incremental-red.log`).
- Workspace now owns one IOSRunnerBuildWorkspace actor. Two successive manager instances share
  serialized compiler inputs; their two signed-app snapshots and single xctestrun stay launch-specific.
  Every preparation still invokes Xcode. Cancellation/failure rotates inputs; app restart starts fresh.
- App-process file locks were rejected because orphan compiler processes can outlive their lock owner.
  No cross-process cache or signed-product admission shortcut was introduced.
- Independent falsification found the snapshot metadata read must retain the existing 1 MiB bound.
  Both readers now share bounded regular-file loading. Valid oversized plist and canonical path escape
  regressions failed before their fixes; 33 targeted build/manager/launcher/configuration tests passed.
- Real build-only profiling used existing development signing and bundled sources, no launch or content
  commands. Cold/warm preparation totals including snapshot and signature/config checks:
  31.182 / 2.651 / 2.116 s. Signature/config phases: 0.038 / 0.040 / 0.043 s.
  `/tmp/devicebridge-incremental-timing.log`. These are build-stage measurements, not SC-012 passes.
- Build 7 replacement approval was requested because the user previously asked not to close the active
  formal application without coordination. Current Build 6 was kept running pending that answer.

## Rendered Build 6 evidence

- CUA-only interaction, designated USB iPhone. Public Unicode text includes Chinese, emoji, accented
  Latin, blank lines. Long text was exactly matched after clear/read, expanded editor remained readable,
  Copy All→clear→paste matched exactly. Save was user-assisted to `/Users/fus/Documents/Clipboard.txt`,
  whose 15,871 bytes matched the declared generated fixture. This is helper-write roundtrip evidence,
  not an original cross-application paste-origin qualification.
- Screenshot capture at 19:11:27 was saved to the task exports directory. Native PNG pasteboard data
  and saved PNG were byte-identical and decoded as 1170×2532. A later 19:35:59 capture's save panel was
  cancelled; the same preview/timestamp remained and no saved-success feedback appeared.
- File send used a new temporary domain `dev.debugutility.closure20260908`, public file
  `closure-file-1939.txt`, 69 bytes. Send showed length-validated success. Two GUI receives remained in
  CoreDevice copy-from, no local partial created. Cancel returned the UI to enabled controls and removed
  the child process. Direct diagnostic copies of the same file (ordinary and hidden partial names) took
  under 0.2 s and matched all bytes. This isolates an app-origin/path boundary but does not establish an
  OS permission diagnosis. Sample: `/tmp/devicebridge-file-copy-stall.sample`.
- IOSFileProvider now receives into an owned temporary directory, checks cancellation after the command,
  then moves to FileTransferService's partial path. Service still validates length/hash and selected
  session before final publication. Red/green logs: `/tmp/devicebridge-file-staging-{red,green}.log`.

## Current checks

- Core full suite before file staging: 380 tests / 57 suites passed. Earlier full runs exposed two
  test-only assumptions that 40–50 ms was sufficient to enter a held external boundary under load.
  Their execution budgets now start within the task / allow one second for admission; assertions still
  require actual child cleanup and rejection after the original deadline. Dedicated early-expiry tests
  remain. No production activation/launch deadlines changed.
- Workspace inventory and explicit fixture clipboard/memory checks passed without an application,
  desktop input, system clipboard access or physical VM; first samples [3,3,3] ms.
- Build 7 Release and Mac UI build-for-testing succeeded; UI tests were not executed. Helper packaging
  tests: 6 run, 1 opt-in real-build skip; the separate actual Release build and strict signature passed.
- Developer ID/notarization, clean-host install, original paste source, paste denial/locked/unplug and
  original quantitative acceptance remain uncompleted prerequisites. Real VM work remains deferred.

- Current iOS workspace checks passed USB/Wi-Fi capability rejection, five first-use configuration failures, shared clipboard/screenshot admission, classified recovery, Stop/export invalidation, stale results and heartbeat isolation (`/tmp/devicebridge-closure-ios-workspace-final.log`).


## Local delivery / final status

- Final Core check: **381 tests / 57 suites passed** with explicit `--no-parallel`, exit zero.
  The prior default-parallel run failed a pre-existing VM fragmented-deadline fixture before its
  intended held boundary; this remains recorded in `/tmp/devicebridge-closure-core-delivery.log`.
  No real VM stability qualification is inferred from the serial pass.
- File provider's new staging path: fresh native temporary-domain send and receive matched every
  one of 65,536 generated bytes (`/tmp/devicebridge-file-provider-qualification.log`). Updated GUI
  behavior remains unverified while Build 6 is active. iPhone image empty-state wording was corrected
  to instruct Load images; language catalog 6/6 passed.
- Final Release Build 7 succeeded and both source/copy strict deep signatures passed. Final DMG
  checksum verified VALID; SHA-256 `04297ffd484713c046393b1afd7ac253d10fcd81c9846f5d397d672afd4b6212`.
  Artifact: `dist/DeviceBridge-0.1.2-build7-macOS-arm64-20260908.dmg` (6,710,197 bytes).
- At handoff: zero isolation fixture apps and zero pending public-fixture copy commands. Formal
  Build 6 PID 162 remained running; no new duplicate app was launched. Follow System was restored.
- Completed scoped tasks: T115, T117, T118, T124, T125, T127, T128. T116/T119 full readiness,
  T120 original source/empty device condition, T121 adverse physical conditions, T122 save failure,
  T123 updated GUI/image reconnect and T126 external distribution prerequisites remain open.
