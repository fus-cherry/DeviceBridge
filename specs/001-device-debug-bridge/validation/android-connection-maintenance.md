# Android connection maintenance — 2026-09-07

## Scope and production path

`WorkspaceViewModel.start` refreshes inventory every five seconds. After Android selection and helper
preparation, `startConnectionMaintenance` schedules `ConnectionMaintenance.tick`. Normal delay is
five seconds after the previous tick completes, not a fixed-rate overlapping timer.

`DeviceSessionStore` remains the authoritative session writer. Each maintenance actor has an owner
UUID and exact session generation. A between-operation reservation excludes content commands while
probing; existing transfers defer the probe. Memory sampling returns busy rather than a false
disconnection while the reservation is held.

Two failed probes invalidate the session before reconnecting. Recovery checks existing routes, then
the known endpoint and matching mDNS service endpoints, with eight rounds and 1/2/4/8-second capped
delays. Each command is bounded; candidates and endpoints are capped at eight and four respectively.
Android commands use explicit transport IDs. Connect output alone never grants readiness.

With a helper context, health/recovery checks verify the existing nonce, helper ID, protocol and
version through an ephemeral forward. This reads identity metadata only: no clipboard/file/image
payload, helper bootstrap, install, launch, force-stop or shared ADB server reset. Without the
authenticated context, an initial get-state probe can report command readiness, but recovery cannot
prove identity and eventually requires manual action.

After external awaits, ownership/cancellation checks reject late results. A verified route commits
to a new generation in selecting state, so old providers cannot issue content commands. The workspace
clears old providers and runs selection/rebinding with the existing helper context; this creates
another active generation. It does not use the core's optional `resumeAfterRebinding` entry point.
Reattach/detach changes only the exact forward, preserving the authenticated helper process. Failed
resume verification also detaches instead of force-stopping an unverified candidate.

Switching device or stopping cancels the maintenance task and revokes store ownership. Memory events
also check the current monitor instance before publication. The workspace displays recovery attempts,
action-required guidance, successful rebound count and an explicit pause action.

## Verification

- `swift test --package-path packages/DeviceBridgeCore`: 131 tests / 28 suites passed on the final
  run at 13:31:49 local time. See [final-automated.md](final-automated.md).
- Focused maintenance, ADB boundary, helper lifecycle and TCP deadline run: 21 tests / 4 suites passed.
- New tests cover reservation/single-flight behavior, five-second cadence, two-failure invalidation,
  verified recovery, wrong identity, USB preference, finite retries, late discovery/endpoint/connect/
  verification results after selection, and stop during a late probe.
- ADB command fixtures cover selected-service mDNS filtering, unsafe endpoint rejection,
  metadata-only identity checks, mismatch rejection and exact forward cleanup.
- The added mDNS-failure fallback regression first failed with `commandFailed`; after retaining the
  known endpoint on lookup failure (while preserving cancellation), the full suite passed.
- Memory admission regression verifies a reserved connection probe returns busy with zero provider
  calls, and the next sample succeeds after release.
- Real loopback TCP tests cover a silent peer timing out and cancellation releasing a pending read.
- `xcodebuild build -quiet -project apps/macos/DeviceBridge.xcodeproj -scheme DeviceBridge
  -configuration Debug CODE_SIGNING_ALLOWED=NO`: passed. Release also passed.
- New `DeviceWorkspaceUITests/testAutomaticRecoveryRebindsToolsAndStopsOnDeviceSwitch`: PASS on the
  14:04 individual rerun and 14:04–14:05 eight-test fixture suite. Two earlier attempts timed out while
  enabling automation mode, and native UI fallback lost its pipe; those were not assertion failures.
  No permission or production code changes were needed for the passing reruns. See [UI evidence](ui-automation.md).

## Remaining limits

T092/T073 now have fresh UI evidence; T029/T088/T089 remain open for physical/quantitative
qualification. No new mobile device commands were executed for this follow-up. Four-hour Wi-Fi
soak, OEM battery-policy behavior, recovery latency targets and 100 fault-injection trials are NOT RUN.

Repeated command/probe timeouts can make a round exceed the backoff duration and the desired recovery
latency target. Long content operations defer health checks. mDNS instance changes, helper restarts,
lost pairing or changed nonce may require reselection/pairing. Address support is limited to literal
private/link-local IPv4 and bracketed local IPv6 without zone IDs; no public-address/DNS scanning.
ADB backends that omit `usb:` inventory metadata need explicit wired-classification qualification.
Forward cleanup is best effort if ADB fails; an allocation whose output is never returned cannot
be precisely identified. iOS continuous recovery and its concrete runner channel are still absent.

Command semantics reference: [AOSP adb manual](https://android.googlesource.com/platform/packages/modules/adb/+/refs/heads/main/docs/user/adb.1.md).
