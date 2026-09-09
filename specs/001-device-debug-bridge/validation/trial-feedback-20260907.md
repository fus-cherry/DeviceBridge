# Trial feedback — 2026-09-07

Scope: T104–T107 / FR-U01–FR-U03. Native Mac app; non-Git working directory.
No macOS UI automation, input-method permission changes, phone writes or helper deployment performed.

## Implemented behavior

- Clipboard: all current Android textual items joined with newlines; no URI content coercion or history.
  Unified 1 MiB UTF-8 limit; explicit excess, no truncation. Frame budget 6 MiB + 64 KiB covers worst
  JSON escaping. Managed Android helper is versionCode 3 / 0.3.0. Scrollable editor, expanded sheet,
  Copy all and explicit UTF-8 text save. Save rechecks presentation device/export epoch; it is not
  described as a DeviceSessionStore token check. iOS source changes do not enable its gated channel.
- Inventory: actual 5-second background loop no longer toggles manual loading UI; timestamp-only
  observations do not publish sidebar rows or diagnostics. Fresh observations still reach the store.
  Stable ordering, manual refresh joining, real route/auth/identity changes and stop/restart are covered.
- Album: native segmented Images/File transfer control; 24 thumbnail tiles per page; selected accent
  border plus checkmark; selected preview and unchanged-original download. Page reads are sequential,
  selection/export cancel and drain them, and the derived cache is bounded to 48 entries / 20 MiB.
  The existing ADB channel reads bounded originals to derive thumbnails on Mac, then discards them;
  this is not a phone-side thumbnail service. No unvisited-page prefetch or automatic connection scan.

## Red/green evidence

- New clipboard/protocol cases failed old 100k/512KiB behavior before limit changes.
- Headless production workspace first failed background spinner assertion. Added selected-device
  ordering tests caught the selected row shifting on a later poll, before publication normalization.
- Image service thumbnail test failed because calling preview replaced the selected original and
  retained intermediate files; one shared read/validation path now separates thumbnail from commit.
- Headless album harness first failed missing 24-item page thumbnails. Now verifies exact first-page
  reads, cache reuse/bounds, no unvisited-page reads, selection priority and late source cancellation.

## Commands / results

- `swift test --package-path packages/DeviceBridgeCore --filter ImageLibraryServiceTests`: PASS,
  10 test declarations, including thumbnail cleanup and preserved selected-original export.
- `bash scripts/check-image-view-model.sh`: PASS. Compiles/runs production presentation logic without
  any app/window/testmanagerd; includes previous export collision/stale-save regression coverage.
- `bash scripts/check-workspace-inventory.sh`: PASS. Actual timer, silent unchanged publications,
  selection, status/route changes, manual progress and canceled older refresh are exercised headlessly.
- Production Android USB image check: PASS on designated PLD110 transport 17. 135 metadata entries;
  one existing 1,167,564-byte screenshot, 1080×2400; album thumbnail, preview and exported original
  passed decode/length/source-and-export SHA-256 checks. Temporary copies removed; no phone files changed.
  Uses `DEVICEBRIDGE_LIVE_IMAGE_LIBRARY=1`, `DEVICEBRIDGE_LIVE_ADB_PATH` and freshly verified
  `DEVICEBRIDGE_LIVE_ANDROID_TRANSPORT` with `swift test ... --filter PhysicalImageLibraryTests`.
  MobAI tools/resources were unavailable; existing production ADB tests were the declared fallback.
- Final post-review core suite: 178 test declarations / 35 suites reported passing; 8 opt-in physical
  declarations skipped (170 executed declarations). Final album headless harness also passed.
- Android helper: 16 JVM tests passed (clipboard 5, framing 4, lease 7), assembleDebug succeeded;
  versionCode 3 / 0.3.0 APK SHA-256 `886c91a3e683beda5091906a62859c97ebdf022269843fa998359745b5af0cea`.
- iOS clipboard command/test source typechecks with Swift 6 and the simulator SDK; no runner was
  launched and this does not qualify a physical iOS clipboard channel.
- Final Release build: `xcodebuild build -project apps/macos/DeviceBridge.xcodeproj -scheme DeviceBridge
  -configuration Release -destination 'platform=macOS'` — BUILD SUCCEEDED. Version 0.1.1 / build 2.
  Only the normal skipped AppIntents metadata warning (no AppIntents dependency); no UI runner launched.
- Package: `dist/DeviceBridge-0.1.1-test-macOS-arm64-20260907.dmg` (about 2.2 MiB), SHA-256
  `6c74ccd57306821cb31653a730ac91a7d078c72efd967d830bdba70c35fbbd04`.
  `hdiutil verify` valid; ad-hoc hardened-runtime signature verified deep/strict both staged and inside
  a read-only, no-browse mount. Mounted executable/APK matched staging/build byte-for-byte; manifest
  Android version 3 and app build 2 checked. Mount detached. No app launch/installation performed.
  The old 0.1.0 DMG remains unchanged; package contains Chinese trial instructions and Applications link.

## Review and qualification boundaries

Read-only independent album review found no important safety/readability defects. The primary path
still exposes the service owner, selected-original commit, stale guards, cancellation drain and
terminal exclusive/confirmed atomic export. Clipboard review identified and required tests for
FutureTask exception wrapping and text-save collision protection before packaging. Both have failing
then passing regressions: typed exception causes are restored at the main-thread boundary; TXT save
reserves a private sibling stage, writes/closes it and commits via exclusive atomic rename. An existing
destination is preserved and reported, and owned staging files are cleaned on failure.
Focused rereview confirmed both findings resolved with no new important findings.

Not claimed: desktop visual/interactive QA, new helper's long clipboard on a physical phone,
camera-photo fixture, wireless image transfer/soak or iOS content access. The user can qualify visual
layout and clipboard foreground behavior using the new internal package. T101/T102/T103 and previous
cross-platform/long-run qualification remain open.
