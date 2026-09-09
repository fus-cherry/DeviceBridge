# Startup feedback and persistent incremental builds — Build 9

## Outcome and scope

The first sidebar click now immediately presents the selected candidate, a checking indicator and
an explanation. Initial discovery also has visible feedback in the main pane. A failed check shows
its safe failure/recovery message and Retry even when no device has ever been committed.

Completed iOS compiler workspaces now survive app restarts. Three independent processes using
the same build inputs measured 33.650 s cold, then 2.359 s and 1.689 s for build-for-testing.
All three passed the real signed-artifact/configuration loader. These are **build-only** results:
no device installation, channel startup or content commands were performed by the profiler, and
they do not establish total selection-to-authenticated-ready time for Build 9.

## Evidence and design decisions

Before this change, Workspace set the committed selected-device identity only after the external
DeviceCommandProbe finished. The checking overlay was attached only to an already-selected
device's detail view. Thus a first click could remain on the Select a device screen while its real
probe was running (up to the existing 5/7-second command deadline). This establishes a concrete
missing-feedback path, not evidence that every reported startup delay was a blocked main thread.

The prior compiler workspace used a new UUID per app process. A trial copying a completed
DerivedData tree into another directory still required 28.597 s of compilation, plus 1.500 s to copy.
Xcode reported old paths outside the new allowed roots. That relocation scheme was rejected.
Its throwaway evidence remains in `.build/ios-cache-relocation-spike-20260909/result.json`.

The retained solution transfers exclusive ownership of a completed workspace at its original path.
Every connection still runs Xcode's incremental build and the existing signature/configuration
validation. It never treats cached bytes as authenticated device readiness.

## Production path and authoritative owners

1. Workspace handles the click synchronously and publishes DeviceSelectionPresentation.checking
   with the candidate device. This display state is separate from DeviceSessionStore's committed
   session and cannot authorize content actions. The sidebar remains selectable while checking.
2. Existing selection/cleanup drains, then the device probe runs. After awaits, cancellation and
   selection revision reject superseded work. A candidate removed during cleanup becomes visibly
   failed. Only the existing store.select / markCommandReady path commits the connection and clears
   the candidate presentation. Stop clears presentation before asynchronous cleanup.
3. IOSRunnerManager owns native preparation and launch identity. IOSRunnerBuildWorkspace owns
   compiler inputs. Production opts into `~/Library/Caches/dev.debugutility.DeviceBridge/IOSRunnerBuilds-v1`.
   Cache keys hash sorted JSON of executable, arguments (excluding the per-launch DerivedData
   value), explicit environment and expected Team. Nil/inherited and explicit empty environments
   remain distinct. Xcode continues to determine whether changed source/compiler inputs require work.
4. Each build atomically renames a workspace's `.available` marker to a unique `.claimed-UUID`
   marker in the same directory. This POSIX rename is the cross-process ownership point. A new
   directory starts claimed. Every build reacquires a claim, including the actor that previously
   released that directory; there is no retained permission to write after release.
5. Admission remains held until the actual command returns and the immutable per-launch snapshot
   copy finishes. Failed, cancelled, interrupted, or unpublishable builds never offer the workspace
   for reuse. Successful snapshot movement is followed by advisory availability publication. A failed
   availability rename leaves the claim quarantined while the valid launch snapshot remains usable.
6. The unchanged launcher loads the snapshot, validates all signature roles, installs/starts its own
   launch and authenticates the channel. Manager launch guards and Workspace session/revision
   guards still decide readiness. No mutable compiler path is handed to a launcher.

An interrupted workspace can still have orphan writers, so claims are not scavenged and failed
directories are not automatically deleted. Persistent disk retention is not bounded by this change.
This is a deliberate limit, rather than a claim that cleanup is proven safe.

## Verification

- Selection regression: `/tmp/devicebridge-selection-red.log` records the initially missing
  presentation API; `/tmp/devicebridge-selection-green2.log` passes synchronous first/second click
  feedback during a held probe, no early commitment/content access, late failure rejection, visible
  first-use failure, retry, candidate removal during cleanup, Stop and late completion.
- Incremental ownership: `/tmp/devicebridge-persistent-build-green4.log` passes 10 tests, including
  parameterized failure/input cases, independent actor recreation, concurrent claims, original-actor
  reacquisition, cancellation-ignoring late success, immutable snapshot bytes and input segregation.
  Earlier runs caught `/var` versus `/private/var` spelling differences. Both newly created and
  enumerated paths now use the same Foundation normalization, avoiding accidental relocation.
- Full Core regression: 386 tests in 57 suites passed with explicit `--no-parallel` in 18.311 s:
  `/tmp/devicebridge-startup-core-final.log`.
- Real Workspace integration and inventory regressions passed:
  `/tmp/devicebridge-startup-ios-workspace-final.log` and
  `/tmp/devicebridge-startup-inventory-final.log`.
- An independent read-only reviewer examined claim ownership, cancellation, snapshot publication,
  signature boundaries and candidate display. Its disappearing-candidate finding was fixed and
  covered by the held-probe/removal regression.

### Real build-only measurements

Each row is a fresh OS process, manager and workspace instance. Sources came from the existing
mounted Build 8 app with the designated device and existing Team. The currently running app and
its phone channel were left untouched. The cache started empty.

| Process | Build | Build + snapshot + validation | Signature/configuration validation | Channel/content |
|---|---:|---:|---:|---|
| 1, cold | 33.649906 s | 33.704787 s | 0.037245 s, passed | Not started / 0 commands |
| 2, reused | 2.359498 s | 2.416087 s | 0.039919 s, passed | Not started / 0 commands |
| 3, reused | 1.689157 s | 1.739313 s | 0.037539 s, passed | Not started / 0 commands |

Evidence: `.build/ios-persistent-timing-20260909/results.json` and `process-1.log` through
`process-3.log`. To reproduce with explicit build-only authorization, use the existing profiler
flags and add `DEVICEBRIDGE_IOS_PERSISTENT_BUILD_ROOT` pointing to an owned cache directory;
run the executable separately for each process. Never infer authenticated readiness from these rows.

### Computer Use

A separate preview app used the production WorkspaceView/WorkspaceViewModel and synthetic,
held external boundaries. Computer Use visually verified initial discovery, first click, switching
to another device while the old probe remained held, unchanged current feedback after the old
failure arrived, the current failure/recovery message, Retry, and English switching while busy.
No physical command or device content was available to this preview.

The first two app selections timed out. A two-second process sample showed the app's main thread
idle in its event loop, not blocked. Resetting the Computer Use connection and selecting the unique
bundle identifier restored access. After the synthetic successful probe, ScreenCaptureKit returned
error -3811; the visual transition into the final tool pane is therefore not claimed. Its model
commit transition passed headlessly. The preview was quit through Computer Use and its process
absence verified; the user's mounted Build 8 process remained running.

## Remaining qualification

First-ever builds and changed installation paths, teams or devices can still require a cold build.
Total Build 9 device readiness and phone-side startup latency remain to be measured with a
coordinated real app switch. Other outstanding original acceptance items retain their previous
status in [release-closure-20260908.md](release-closure-20260908.md).

## Delivered artifact

Release Build 9 compiled successfully (`/tmp/devicebridge-startup-build9-final.log`). Strict deep
signature verification passed for both the source and staged apps. The final bundled Chinese
catalog includes the corrected Retry translation and persistent-reuse hint. The DMG passed
`hdiutil verify` (`/tmp/devicebridge-startup-dmg-verify.log`).

- Workspace: `dist/DeviceBridge-0.1.2-build9-macOS-arm64-20260909.dmg`
- Download: `/Users/fus/Downloads/DeviceBridge-0.1.2-build9-macOS-arm64-20260909.dmg`
- SHA-256: `d2aa5526d347fc6f46396b578a4c4ea812ae5f22bb1b193954a87400577958e1`
- Size: 6788614 bytes

The downloaded copy matches the verified DMG hash; both have checksum sidecars. This is a local
ad-hoc signed test build. Developer ID/notarization and clean-host qualification remain unchanged.
The final read-only review reported no remaining blockers in the bounded change. No app or phone
channel replacement was performed.
