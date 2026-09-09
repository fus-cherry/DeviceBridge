# US3 Screenshot Validation

Date: 2026-09-08

## Fresh non-VM Workspace capture/export — PASS

`devicebridge-nonvm-workspace-0271ppyy` passed in 50.230 seconds, exit 0: normal production
Workspace authentication, PNG capture/decode, byte-exact local export, renewal and Stop with owned
helper exit. Clipboard round-trip also passed in this run; no VM queries or target-app restart.
Paired USB identity was checked independently before/after. This does not claim rendered desktop
interaction, protected/locked screen or wireless qualification.

## Screenshot while native VM monitoring is active

`devicebridge-workspace-coexist-ml81cfgo` passed the real same-Workspace signed helper/native memory
flow in 64.016 seconds. One captured PNG decoded fully and exported byte-for-byte while the exact
target's VM monitor remained active; at least three newer attributed memory samples followed capture.
Selected paired USB device and target PID/executable were independently unchanged afterward, and
the named helper exited. No clipboard access or Mac input. See `us5-memory.md` for the bounded
coexistence scope and the existing bootstrap Home transition, which this result does not remove.

## Continuous selected-iPhone screenshot qualification — 100/100

The explicit `DEVICEBRIDGE_MANAGED_SCREENSHOT_100=1` opt-in extends the existing native physical
test, not production behavior. It requires screenshot opt-in and rejects either clipboard opt-in.
The procedure was fixed before launch: exactly 100 serial requests on one authenticated channel,
metadata-only identity renewal before each capture, no retry/reconnect on failure, then the existing
five identity exchanges over 40 seconds, Stop and native cleanup checks. The test-only owner lifetime
is bounded to 600 seconds, with a 650-second outer harness; normal single-shot tests remain 120 seconds.
Any failed request aborts remaining trials without counting them as success.

Reference: Apple M4 / Mac16,1 / 16 GiB, macOS 26.6, Xcode 26.6 (17F113), Apple Swift 6.3.3.
Phone alias I: iPhone 12 (iPhone13,2), iOS 18.3.1, paired USB route, passcode not required at fresh
preflight, no existing named runner. The already approved personal signing identity and already
signed Debug products were reused; all three roles verified strictly with the same expected Team.
No new certificate/profile, provisioning update, account, permission action or target-app change.
The normal managed runner starts on Home; these are real XCUIScreen captures, not a generated visual
fixture. No capture is exported, copied to a clipboard, or attached to XCTest (`keepNever`).

Build references (code hashes only, never device/credential/content hashes):

- Signed runner test binary SHA-256: `2fd55695fa0d7877904faf83fb7d50b7ae895c16ba397e476d20ea8a8c651f6b`.
- Host physical-test source SHA-256: `980b9dff7893650b4b4456250bbae2761377bcf55622664ab4ad1e515bcfaea6`.
- Host command: `swift test --package-path packages/DeviceBridgeCore --skip-build --no-parallel --filter IOSRunnerManagedPhysicalTests`;
  exact device/signing inputs were supplied only through the existing private harness environment.

Evidence: `devicebridge-screenshot-soak-z2lnp16b/test.log`. It retains all 100 trial numbers and
monotonic durations, no images/bytes/digests. Independent parsing confirmed exactly trials 1–100,
one success each, zero failure markers, **100/100 success**, zero retries, zero missing trials.
Production provider/channel validated request binding and the complete PNG before each success.

| Capture → verified original PNG | Milliseconds |
|---|---:|
| Minimum | 193.480 |
| Median | 198.173 |
| Nearest-rank P95 | 203.981 |
| Maximum | 252.882 |

All **100/100** captures were below five seconds. This timing excludes startup, the preceding
identity renewal, rendered preview and Save UI. It is **not whole-workflow SC-005 acceptance**.
The one real host test passed in **67.561 s**; outer harness elapsed **73.602 s**. The existing test
also required phone xcresult 1 pass / 0 fail / 0 skip, correlated Stop, native child exit zero,
action-log nonce/Stop-ID checks, valid signed artifacts and no pending launcher cleanup. Fresh
postconditions found the same paired wired phone, no active named runner, and an independent exact
USB connection attempt confirmed runner port 49872 closed.

Final default Core regression: **366 tests / 56 suites passed in 16.045 s**
(`/tmp/devicebridge-screenshot-soak-core-final.log`); the opt-in physical test above ran separately.
This turn changed the acceptance test/documentation only. The existing Debug app was not rebuilt
or restarted and no desktop input was used.

This supplies the iOS screenshot subset of stable wired-operation evidence for SC-002, not the
whole Android/iOS matrix, a wrong-route injection trial, generated-fixture visual source validation,
locked/protected-screen behavior, wireless, rendered-window interaction, or hour-long endurance.
T048 and the overall T036/T084 gates remain open; clipboard qualification remains independent.

## Current T036 integration

Workspace screenshot plumbing and local signing Settings are now implemented independently of
the still-gated clipboard. Headless lifecycle checks and Debug build pass. The full bundled-source
physical Workspace build/prepare/renew/screenshot/exact-save/Stop path now passes; the first attempt
exposed verbose Xcode output exceeding the build quota, fixed with quiet output while retaining the
quota. See [current integration evidence](ios-workspace.md). Earlier prerequisite-only
statements below describe their original validation point, not the current source state.

## T036 prerequisites and T084 adverse transfers — latest evidence

`IOSRunnerScreenshotProvider` bridges the concrete authenticated channel to `ScreenshotProviding`.
It captures one transport and existing helper context; it does not bootstrap a second nonce or
own a second session. It checks transport/context before requesting and context/cancellation again
before returning. Channel/manager shutdown and ScreenshotService's session-token publication checks
remain separate owners. Tests reject another transport, an obsolete helper build and a closed channel.
The initial provider scaffold failed the real TLS screenshot test with `.unavailable`; implementation
passed. This is an integration prerequisite, **not** an enabled Mac Workspace feature.

- Actual physical provider run: `devicebridge-encrypted-screenshot-a2fehgb4/test.log`, **47.900 s
  PASS**, selected personal-signed wired iPhone, verified image, five metadata exchanges over 40
  seconds, Stop, native exit zero, phone 1 pass/0 skips, action-log nonce/Stop-ID audit and cleanup.
  All three signed roles passed strict verification before/after. No image export, attachment,
  clipboard access, Mac UI takeover, signing update or phone rebuild was needed for this host change.
- Whole-channel rejection: eight cases cover absent descriptor, absent/truncated attachment,
  wrong digest/offset/request, duplicate descriptor and deadline expiry. All return no image and
  terminate the authenticated session. Temporarily omitting receipt validation made the wrong-digest
  case return synthetic bytes and fail; the validation was restored. Log:
  `/tmp/devicebridge-ios-screenshot-adverse-mutation.log` (synthetic data only).
- ScreenshotService now retains permission-denied, restricted/action-required, cancelled, expired,
  invalid-response and failure categories. Bad wire responses are malformed output; a closed
  channel is disconnected. These mappings had **5 then 2 RED cases**, instead of falsely suggesting
  every error is fixed by unlocking. Chinese messages are included. Failures publish no file and
  release the operation slot. Logs: `/tmp/devicebridge-ios-screenshot-errors-red.log`,
  `/tmp/devicebridge-ios-channel-errors-red.log`.
- Latest full Core regression: **286 tests / 49 suites PASS in 10.492 s**, 13 existing opt-in skips;
  `/tmp/devicebridge-ios-screenshot-integration-core.log`. The real opt-in run above is separate.
  Five libtool no-symbol warnings came from dependency assembly objects; no compiler errors occurred.
- Final targeted rerun after test diagnostic sanitization: **23 methods / 2 suites PASS in 2.007 s**,
  `/tmp/devicebridge-ios-screenshot-final-targeted.log`. `bash scripts/check-workspace-modules.sh`
  also passed selected-only layout and retained-pane identity/input checks, without a window,
  desktop XCTest or input automation; `/tmp/devicebridge-ios-screenshot-workspace-modules.log`.

### Portable runner source bundle

The original bundle copied only `helpers/ios`, leaving `../../packages/DeviceBridgeSecureChannel`
and its sibling `DeviceBridgeProtocol` unresolved outside the repository. Packaging now retains
`ios-runner/helpers/ios` and `ios-runner/packages/{DeviceBridgeSecureChannel,DeviceBridgeProtocol}`.
The manifest project path is `helpers/ios/DeviceBridgeRunner.xcodeproj`. Build caches, user state,
signing artifacts and stale generated files are excluded/removed only within the validated generated
runner subtree. No source project references were rewritten.

Root rerun: `python3 scripts/test_helper_packaging.py`, **5 PASS in 2.110 s**. It executes the real
packaging script in owned temporary fixtures, moves the original source away, parses the real project
and offline Swift manifests, and verifies local dependencies, Android bytes/hash, incremental cleanup,
artifact exclusions and unsafe-output rejection. Remote package dependencies remain pinned, not
vendored; a genuinely fresh Mac build/install and personal-signing onboarding are still unqualified.

T084/T036/T041/T048 remain open: permission-wait flow, general clipboard WRITE/restoration,
Workspace signing/lifecycle/readiness and locked/protected-screen behavior remain to be completed.
These tests do not qualify wireless, device-bound VM memory or an indefinitely maintained session.

## T084 encrypted screenshot implementation — current evidence

The signed `testManagedChannel` now supplies `RunnerScreenshotHandler`. It captures on the phone
without foregrounding the runner, checks request expiry/cancellation before capture and after the
OS call/PNG validation, and returns only fixed errors or request-bound metadata plus PNG bytes.
No screenshot enters launch arguments/environment, clipboard, XCTest attachments or stdout.
The host has a dedicated `captureScreenshot` path; generic `send` cannot accidentally publish a
successful metadata-only image result.

The wire uses existing pinned TLS frames, exact screenshot descriptors and request-bound 64 KiB
binary chunks (64 MiB total maximum). PNG validation includes bounded chunk CRCs and exact IEND,
ImageIO decode and a 100 MP bound before pixel allocation. ImageIO alone was observed accepting
corrupted IDAT, motivating the CRC check rather than assuming decoding proves integrity.

Evidence, all synthetic unless explicitly noted:

- Wire codec: 11 methods passed after permissive-scaffold RED with 47 issues. Literal UUID/endian
  bytes, independently computed PNG SHA-256, malformed descriptor/chunk/PNG and size bounds covered.
- Session server: initial 28-method run failed the two new screenshot-advertisement/dispatch tests;
  these passed after implementation. Exact binary dispatch then failed before chunk support.
  Current **30 methods pass**, including a valid >150 KiB PNG transmitted in three ordered chunks
  with a separately correlated heartbeat, failure without attachment and Stop bypassing a gated
  capture. This does not claim every heartbeat necessarily arrives before the final buffered chunk.
- Host: screenshot API RED `.invalidRequest`, then complete verified PNG GREEN. An independently
  reviewed Stop race failed before correction: a late descriptor/chunk must not close the channel
  before an in-flight Stop ACK. Current **15 channel + 5 receipt methods pass**.
- Cleanup: a test-owned immutable `image.partial` proved `finish` could return data while deletion
  failed. Explicit cleanup now throws; success requires deletion first. Incomplete finish is
  terminal. Both red regressions were observed. Teardown reports `cleanupFailed` to pending callers
  if explicit removal fails; deinit remains best effort, so filesystem refusal can leave a private
  owned temporary file and is not claimed guaranteed physical cleanup.
- Signed iPhone screenshot fixtures: cancellation/expiry RED (2 pass/2 fail in
  `devicebridge-clipboard-checks-cngsg8ed`), command GREEN (4 pass in `...-6tor168k`), handler RED
  (5 pass/1 fail in `...-luldflrr`), then **6 pass/0 skips** (`...-2b2boqx3`, `...-sns1e774`).
  The final signed build also proves the ImageIO/zlib module compiles for iOS. These fixture tests
  use synthetic images, not the real screen; production encrypted capture is being verified separately.

Logs: `/tmp/devicebridge-screenshot-multichunk-check.log`,
`/tmp/devicebridge-screenshot-reviewed-channel-green.log`,
`/tmp/devicebridge-screenshot-cleanup-red.log`,
`/tmp/devicebridge-screenshot-incomplete-finish-red.log`.

### Real encrypted iPhone screenshot — passed

`devicebridge-encrypted-screenshot-r87ogva2/test.log`: the actual production factory/native launcher
and signed runner completed `captureScreenshot` in an opt-in run, then five metadata exchanges over
40 seconds, correlated Stop and native child exit zero. Overall host test **passed in 45.936 s**;
it also required phone xcresult **1 pass/0 skips**, nonce/Stop-ID action-log audit and owned cleanup.
All three signed roles verified strictly before and after the test. The image was captured through
the real `XCUIScreen`, transported as request-bound binary chunks, staged and fully validated by
production code, then the receipt's private partial file was removed before returning data.

Final root regression: `swift test --package-path packages/DeviceBridgeCore --no-parallel` passed
**283 tests / 49 suites in 9.620 s** (13 existing opt-in skips), and SecureChannel passed **77 tests /
9 suites in 9.466 s**. Logs: `/tmp/devicebridge-screenshot-core-regression.log` and
`/tmp/devicebridge-screenshot-secure-regression.log`; neither reported compiler warnings/errors.
Earlier legacy TLS diagnostic flakes remain documented, not claimed fixed by these passes.

This run never activated another phone app, read/wrote clipboard, exported the PNG, attached it to
XCTest, or printed screenshot bytes/count/digest. It qualifies actual encrypted screenshot capture
on this selected wired, personal-signed phone under its current state, not Mac UI readiness,
locked/protected-screen handling, wireless or all adverse-transfer schedules.

T084/T036/T048 remain open. Remaining qualification includes additional malformed/truncated
transfer cases, locked/protected-screen behavior and Mac UI integration.
No Mac UI takeover, new certificate, provisioning update or Release packaging was performed.

## Historical automated evidence

- Core screenshot service tests: PASS for PNG signature/nonzero dimensions, exact-byte publication,
  partial cleanup, cancellation, device-switch stale rejection, prior-preview preservation, and
  session byte cleanup.
- Android provider tests: PASS for target-specific `adb -t <transport> exec-out screencap -p`, a
  bounded 64 MiB output contract, nonzero exit, and empty output.
- iOS simulator `ScreenshotCommandsTests`: PASS for exact PNG response and explicit locked/protected
  result mapping.
- macOS fixture UI test: PASS for no automatic capture, explicit capture, source metadata, preview,
  Save/Copy controls, and exact original PNG bytes on the system pasteboard.

## Historical real-device status (before T084)

- T048 remains open. Android capture was not invoked because the active mobile-control skill's MobAI
  desktop API is unavailable in this session.
- iOS real-device capture remains action-required until T036 supplies the persistent runner channel.
  The app does not claim CoreDevice alone can take a screenshot.
