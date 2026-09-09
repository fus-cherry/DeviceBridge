# T036 iOS Workspace screenshot integration

Date: 2026-09-08. T036/T084/T041/T048 remain open.

## Dependency correction

Constitution permission isolation, FR-023 and the data model require independent capability
readiness. The previous combined clipboard-before-all-UI dependency was a scheduling error.
Shared USB/authentication and screenshot evidence permit screenshot integration while unqualified
clipboard WRITE/restoration and permission-wait remain unavailable. No acceptance requirement is
removed, and this does not qualify wireless, protected/locked screens, or iOS VM memory.

## Implemented path and ownership

- Local Settings accepts the existing development Team; no automatic certificate selection,
  new certificates, portal updates or device registration. Bundled-source configuration validates
  manifest-relative project and both local package roots, including relocation/escape guards.
- Workspace captures its selection revision and exact DeviceSessionStore session, owns one
  manager reference, and passes stable hardware identity rather than CoreDevice route ID to launch.
  Manager owns build/launch/cleanup. The native channel owns authentication and negotiated actions.
- `authenticatedScreenshotContext` rejects identity-only channels without reading any content.
  ScreenshotService is installed only after this metadata check and existing-context verification;
  context/session/revision are checked again after awaits. Clipboard has no installed service.
- One 10-second identity task renews the 30-second phone lease independently of feature panes.
  The configured normal native lifetime is one hour, explicitly described in Settings; it is not
  indefinite keepalive. Failure/expiry disables screenshot and asks for reselection, without
  disabling independently available file/photo services or replaying a content action.
- Selection and Stop synchronously detach readiness before awaited cleanup; next preparation
  drains old cleanup. Inventory route/session changes invalidate the captured binding.
  A visible toolbar Stop action shuts down only the iOS runner and cancels preparation if active.
- Chinese and English messages are provided. No Mac window/input automation is used.

## Checks and evidence

- First Workspace test actually failed because screenshot was unavailable despite a qualified
  channel. Implemented integration passed the same test.
- `scripts/check-ios-runner-workspace.sh`: passes real model/provider/service behavior across
  independent readiness, exact preview bytes, stable device binding, no implicit content access,
  actual 10-second metadata timer, route replacement, failed heartbeat, Stop and late completion.
  Removing route invalidation caused the route test to fail; restoring it passed the full check.
  The visible Stop action also had an empty-body RED before implementation.
- A real mutual-TLS identity-only runner reproduced false screenshot readiness. After the
  negotiated-capability guard, all 17 IOSRunnerChannel tests pass. Test diagnostics now report
  availability only, not the returned context.
- Configuration: 6 tests pass, with a runtime containment-guard mutation failing escaped paths.
- Core regression: 293 tests / 50 suites pass (13 existing opt-in skips); headless retained-module
  layout and silent-inventory checks pass. Packaging relocation/exclusion safety: 5 tests pass.
- Mac incremental Debug build succeeded; the AppIntents metadata extraction warning reflects
  the absence of an AppIntents dependency, not a build failure. No Release/DMG was produced.
- After the quiet-build fix, the full Core regression was rerun: 293 tests / 50 suites pass in
  10.544 s (`/tmp/devicebridge-ios-workspace-core-quiet-final.log`). The incremental Debug app was
  launched with background `open -g`, replacing only the verified old DeviceBridge Debug process.
  The already selected personal Team was saved to the local app preference only because that key
  was absent; its value is not recorded here. Strict outer app signature verification passed.

## Full bundled-source physical check — PASS

`IOSRunnerWorkspacePhysicalCheck.swift` is an explicit opt-in acceptance executable, not production
UI behavior. It uses the real Workspace model, real manager/launcher and the built Mac app's bundled
sources, with the already selected personal signing Team supplied in memory. It never touches either
clipboard or desktop input. It checks selected USB preparation, renewal, decoded screenshot, exact
save into the private session directory and Stop/cleanup. It does not claim visual UI acceptance.

Initial runs discovered the selected phone but stopped in preparation. The diagnostic run
`devicebridge-workspace-physical-9rdxnzgk/workspace.log` identified **build output quota exceeded**.
Xcode's verbose cold-build invocation output exceeded the existing 2 MiB HostCommandRunner bound.
Manager now supplies `-quiet` (confirmed by local Xcode help: warnings/errors only), retaining that
bound and signing restrictions. The manager command test ran RED before the change and all 11
manager tests then passed.

The same physical acceptance then **passed**, exit 0, in
`devicebridge-workspace-physical-xc4lp0zk/workspace.log`: selected wired iPhone discovered, actual
bundled-source signed build exit 0, screenshot independently ready while clipboard remained gated,
metadata renewal, explicit real screenshot fully decoded, exact export verified, and Stop invalidated
readiness and removed the session artifact. The Mac app's outer strict code signature also verified
after these bundled-source builds. No Mac window or either clipboard was accessed.
The exact phone's USB runner endpoint was also confirmed closed after Stop.

This qualifies the selected USB model/service/build path, not locked/protected-screen behavior,
wireless, one-hour endurance, or visible UI interaction. T036/T048 remain open for those applicable
checks and overall story acceptance; do not describe all iOS features as working.

## Incremental helper resource signing correction — 2026-09-08

Updating bundled runner sources exposed a separate delivery failure: the Debug build succeeded,
but its resource seal failed strict verification because the helper packaging phase ran without
triggering `CodeSign`. Its declared output list was empty. The focused fix declares the actual
`Helpers` output directory in the project build phase; no signing identity or entitlement changed.

The opt-in `DEVICEBRIDGE_TEST_INCREMENTAL_SIGNING=1 python3 scripts/test_helper_packaging.py`
regression demonstrated a signed baseline followed by a failing resource-only update before the
fix, then a baseline and two resource-only updates that each ran `CodeSign` and passed strict
verification afterward (6 tests total). Tests now use independent temporary DerivedData; the
initial experiment sharing DerivedData with a different product directory triggered Xcode stale
output removal, so the normal Debug product was restored and verified. No app was stopped by that
experiment. No release package or certificate was created.

Following the iOS VM admission change, `/tmp/devicebridge-ios-vm-admission-debug.log` again records
a successful incremental Debug build; its normal app bundle passed strict verification. The
headless module layout and iOS runner Workspace checks also passed. This validates the on-disk
Debug product, not a claim that an already running process loaded the new binary.
