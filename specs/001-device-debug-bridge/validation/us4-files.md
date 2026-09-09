# US4 File Transfer Validation

Date: 2026-09-08

## Latest: iPhone 500 MB service qualification — PASS for the tested USB slice

User priority: finish non-VM flows before reconsidering Flutter VM testing. No physical VM
discovery/sampling or target-app restart was performed in this follow-up.

`scripts/ios-file-spike/ServiceQualification.swift` uses the real CoreDevice discovery parser,
DeviceSessionStore, FileTransferService, IOSFileProvider and HostCommandRunner. An independently
checked paired USB iPhone is selected; only a new temporary-domain UUID is written. The generated
fixture is exactly **500,000,000 bytes** (decimal MB), constructed in 1 MiB chunks.

Final evidence `devicebridge-ios-large-service-32xmov3q`, exit 0, 41.245 seconds overall:

- Service send: 14.167 s; length validation reports 500,000,000 bytes.
- Remote collision: a second send without replacement is rejected.
- Real download cancellation: wait for at least 1 MiB of actual local partial bytes, cancel the
  owning task, require `.cancelled`, no published destination and no partial files. Return/cleanup
  latency was 0.0013 s; this is service cancellation, not measured button-response latency.
- Fresh service receive: 24.774 s; 500,000,000 bytes and the independently retained send-side
  SHA-256 match. The remote provider itself supplies length only; do not label it remote SHA-256.
- Local collision: receive without explicit replacement is rejected.
- The generated remote file is replaced with a zero-byte fixture and its zero length verified.
  Local source/output fixtures are removed. The empty remote namespace remains; no delete API is
  claimed. Final paired USB details pass independently.
- Sampled host-process peak RSS: **11,392 KiB**; process-tree peak: **31,296 KiB**, 316 observations.
  Sampling waits 100 ms between `ps` observations (command time is additional). These are sampled
  peaks, not hard memory limits, and exclude shared CoreDevice/system daemons and the desktop app.

### File-sized hashing retention reproduced and fixed

The first functional pass (`devicebridge-ios-large-service-hi9gdx5w`) completed the same transfer,
collision/cancellation/cleanup checks, but sampled host peak RSS reached **456,032 KiB**.
An isolated 256 MiB sparse-zero hashing regression reproduced **269,811,712 bytes** of additional
peak RSS. FileHandle read buffers remained autoreleased across the full hash despite 1 MiB reads.
An explicit per-chunk autorelease pool reduced the regression's extra peak to **1,359,872 bytes**,
with the exact independent SHA-256 oracle unchanged. The final physical rerun above confirms the
improvement on the real service path. Session ownership, partial publication, integrity and
replacement rules were not changed.

Reproduce the isolated regression in a fresh process (its guard is <64 MiB additional peak RSS):

```sh
python3 scripts/compile-core-check.py packages/DeviceBridgeCore/.build/arm64-apple-macosx/debug \
  scripts/check-file-integrity-memory.swift -o /tmp/devicebridge-file-integrity-memory-check
/tmp/devicebridge-file-integrity-memory-check
```

RED/GREEN logs: `/tmp/devicebridge-file-integrity-memory-red.log` and
`/tmp/devicebridge-file-integrity-memory-green.log`. Fresh targeted file/image tests: 23 passed.
Final default Core regression: **357 executed methods passed, 13 explicit opt-ins skipped**, 56
suites (`/tmp/devicebridge-nonvm-final-core.log`; the aggregate 370 includes skips).
In-process module layout/retained editor and image-model checks passed; incremental Debug build
and strict/deep signature verification exited 0. No Release packaging or desktop input was run.

An earlier harness preflight (`devicebridge-ios-large-service-8rnvsi31`) incorrectly required
`.available` from inventory, whose paired USB state is `.candidate`. It stopped before creating
the fixture/domain; only the test precondition was corrected, retaining independent paired-USB
command checks and the production discovery parser. This is not a production connection failure.

T056 remains open for Android 500 MB, physical disconnect and other scoped/platform qualification.
`adb devices -l` currently reports no Android devices. Actual desktop navigation/button response,
manual save panels and wireless cannot be inferred from these backend tests. The permitted
desktop read-only attempt failed with a closed native pipe; no mouse/key action or XCTest UI
takeover was attempted. A truly isolated desktop session or user-driven acceptance is still needed.

## Latest: iPhone temporary-domain provider round-trip — PASS

With VM checks explicitly paused, a fresh paired USB preflight and the actual IOSFileProvider
sent a generated 65,536-byte fixture into a unique CoreDevice temporary domain, then received it
into a new local file. Both receipts reported 65,536 bytes and every returned byte matched.
Evidence: `devicebridge-ios-file-roundtrip-fixed-h9r7i_ji`; runner
`scripts/ios-file-spike/ProviderRoundTrip.swift`, exit 0. No app documents or photos were modified.
Two isolated temporary domains retain one disposable 64 KiB fixture each (failed and successful
attempt); no remote deletion API or cleanup is claimed.

The initial physical attempt (`devicebridge-ios-file-roundtrip-m5ibh10u`) copied successfully but
returned `malformedMetadata`. Installed CoreDevice info-files uses `files[].metadata.size`;
the parser only recognized same-level sizes. A sanitized real-shape regression failed on receive
and unconfirmed-overwrite prevention before adding the narrowly scoped nested-size lookup.
Afterward 9 provider/service tests passed (`/tmp/devicebridge-files-green.log`), followed by the
successful physical retry. Legacy size formats and file-name association remain unchanged.

Final incremental macOS Debug build and strict/deep signature verification exited 0. The freshly
compiled Workspace regression also passed clipboard/read-write, screenshot/export, renewal,
Stop/invalidation and late-result rejection (`/tmp/devicebridge-nonvm-workspace-regression.log`).
The on-disk Debug app includes the fix; the running Mac app was not relaunched in this pass.

This verifies the real provider, not rendered desktop file controls, app-container entitlements,
500 MB transfers or physical cancellation. Service staging/integrity/session gates were exercised
by targeted automated tests. T056 remains open. iPhone photo access/export is separately qualified
in [ios-images-runtime.md](ios-images-runtime.md); earlier iOS-unknown statements below are historical.

## Image-first implementation — current status

T098–T100 Android image listing, selected preview, unchanged original export and Chinese/English
native browser are implemented. The production service passed an actual USB screenshot round-trip;
headless production-view-model checks cover cancellation, collision and stale-save behavior.
Camera-photo, iOS content, wireless and isolated desktop interaction checks remain open. See
[phone-images.md](phone-images.md) for exact scope, evidence and pending tasks.

The user clarified that reading phone images/photos is the primary file use case. Existing providers
still support known Downloads/app-container paths separately. The new Android browser covers
DCIM/Pictures/Download, not a complete system/cloud photo library. The 64 KiB generic file checks do
not establish photo-library access; the new image evidence is independently scoped.

## Physical follow-up

Android wired Downloads send/receive passed with a 65,536-byte generated file and matching remote/
local SHA-256. Unique test artifacts were removed. This supersedes the earlier no-transfer status
below, not the outstanding 500 MB, cancellation, private-scope or iOS checks; T056 remains open.
See [physical-background.md](physical-background.md).

## Automated evidence

- Full core suite: PASS, 80 tests in 20 suites.
- Android provider fixtures: PASS for selected-transport targeting, shared Downloads staging,
  debuggable `run-as` reads, exact bytes, remote metadata, and platform-scope rejection.
- iOS provider fixtures: PASS for temporary/app-container domain arguments, read-only crash-log
  handling, JSON file metadata, and partial-path receipt.
- Transfer service: PASS for relative-path/identifier validation, chunked SHA-256, length/hash
  comparison, replacement confirmation, cancellation cleanup, and stale-session rejection.
- Full macOS UI suite: PASS, including native scoped file controls and no automatic content action.
- Android helper JVM tests/build and iOS clipboard/screenshot command tests: PASS in the same
  regression run.

## Remaining qualification

- T056 remains open because no real-device transfer was allowed in this session and the 500 MB
  fixture was not run.
- Android debuggable-app receive currently uses bounded `exec-out run-as ... cat` output with a
  600 MiB ceiling. The 500 MB qualification must measure peak memory before this path is considered
  release-ready; a streaming stdout-to-file command boundary may be required.
- Apple's public command reference documents CoreDevice domains and JSON-output use but does not
  publish a stable copy-metadata schema. The tolerant metadata parser therefore needs a real-device
  fixture from the installed Xcode version before T056 can pass.
