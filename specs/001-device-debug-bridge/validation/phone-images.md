# Phone-image implementation and validation — 2026-09-07

## Outcome

T098–T100 Android implementation is complete: fixed shared-folder listing, local paging, selected
preview, unchanged original export and Chinese/English native UI. General file transfer is retained
separately. T101 remains open for camera-photo, isolated desktop interaction and cross-platform
qualification. T102 iOS USB feasibility and T103 production Workspace/provider integration now pass
on the designated iPhone; see [runtime evidence](ios-images-runtime.md). Visual and expanded physical
qualification remain in T101. Historical gate statements below describe earlier turns.

## Production evidence (supersedes the earlier feasibility-only status)

- Android PLD110 / Android 16 / USB: `PhysicalImageLibraryTests` uses production discovery,
  `DeviceSessionStore`, `AndroidImageProvider`, `ImageLibraryService`, ImageIO and export publication.
  It listed **135** entries, previewed an existing **1080×2400** screenshot and exported its unchanged
  **1,167,564** bytes, with remote/source/local/staged SHA-256 agreement. The capped raw-byte provider
  passed at **16:13:05** (1.270 seconds). Initial uncapped provider passed at 15:53:20.
- During the cap change, real tests at 16:08 and 16:11 correctly rejected a 135-byte error response.
  Cause: double escaping a path for `adb exec-out`, which escapes its own operands. A `/dev/zero`
  discriminating check and AOSP source confirmed the cause; raw operands restored the physical pass.
  `adb shell` metadata paths still require literal shell quoting. No image bytes/path/hash were logged.
- Core regression: **171 discovered / 163 executed / 8 physical tests skipped**, **35 suites**, exit
  zero after the final pixel/header and localization regressions. Skips are not physical passes.
- `bash scripts/check-image-view-model.sh` compiles the production presentation model into a console
  executable. It opens no window and runs no XCTest UI process. It covers explicit-only reads,
  cancellation at/after replacement of a valid preview, exact export, collision refusal and explicit
  overwrite, source cleanup, stale save-panel completion and stale replacement confirmation.
  Latest strengthened checks passed once after compilation plus **20 consecutive reruns**.
- Native Release and UI-test targets were built without launching them. This is compilation evidence,
  not desktop visual/accessibility acceptance. An earlier build-for-testing emitted a framework-copy
  diagnostic despite process exit zero; final rerun explicitly reported **TEST BUILD SUCCEEDED**,
  exit zero, with the Release executable rebuilt at **16:19:08**.

Final read-only physical rerun at **16:20:01**: **4 executed checks PASS / 2 mutation checks skipped**.
Android production images (0.843 s), screenshot (1080×2400), memory continuity across 3 seconds and
designated iPhone command readiness passed. Clipboard/file writes were not rerun in this image-focused
read-only check; their earlier evidence remains separately scoped. Final default core rerun at
**16:20:16** again passed 171 declared tests with 8 explicit physical skips.

## Regression findings resolved during implementation

1. Old image browsers could list after session-generation changes (red at 15:58:43). The service is
   now permanently bound to its creation-time device/transport/generation and rejects this before I/O.
2. A late cancellation after preview commit could remove its original. Publication no longer throws
   into cleanup afterward; UI cancellation/error paths reconcile from authoritative committed state.
   Headless stress testing also found early busy-state release during cancellation; setting busy
   before draining cancellation resolved the failing `export failed: Image operation cancelled` case.
3. Cancellation/invalidation during metadata commands could start a subsequent image read. Providers
   now check session validity before/after every command; clear and caller cancellation cancel the
   service-owned worker. The gated-checksum regression failed before this boundary, then passed.
4. Command byte limits were checked only after `readToEnd`. A still-running oversized writer returned
   timeout in the red test; shared chunk-wise quota enforcement now returns output-limit failure early.
   Capped original reads stop at expected length + 1 and reject growth before local write.
5. Existence at save-panel completion was mistaken for replacement authorization. Saves now start
   exclusively; collision replacement has a separate confirmation tied to destination and revision.

A focused read-only review identified these safety issues; re-review found no remaining important
defect in those fixes. No phone images were modified/deleted, permissions granted, helpers installed,
Mac input events sent, or cloud media requests made. Only test-owned Mac temporary copies were removed.

The user approved image listing → preview → original export, with file transfer retained separately.
The design uses Android shared-image access first and gates iOS ImageCaptureCore behind a physical
identity/access/original-format experiment. See [plan](../plan.md) and [contract](../contracts/phone-images.md).

## Android physical evidence

Designated phone: PLD110 / Android 16 / USB. Transport was resolved again without persisting its raw
device serial. MobAI MCP was absent and CLI again returned local API unavailable. The declared
fallback used the product's HostCommandRunner/ADB boundary, without any global Mac input or UI.

The opt-in `PhysicalImageAccessProbeTests` is **planning feasibility code**, not a production image
service. It reads fixed DCIM/Pictures/Download sources with bounded NUL-delimited metadata, pulls only
selected existing images into a unique local temporary directory, verifies length/SHA-256 and uses
ImageIO to generate a thumbnail. It never writes/deletes a phone file, installs a helper, reads the
clipboard, changes settings, launches UI or approves permissions. It logs no filenames, bytes or hashes.

| Check | Observed result |
|---|---|
| Shared directory listing | DCIM: 0 image entries; Pictures: 135; Download: 0 |
| Existing screenshot original | 1,167,564 bytes; local length and SHA-256 match phone source |
| Screenshot decoding | ImageIO thumbnail: 144×320 |
| Local cleanup | Probe directory and copied image removed; no phone files changed |
| Existing camera image | NOT RUN: no eligible camera image existed in DCIM/Camera |
| Production image provider / Mac browser | Historical probe did not implement these; see production evidence above |
| Wireless image access | NOT RUN; this evidence is USB only |

At 15:26:34 the initial probe stopped because it required a camera image before reading the screenshot.
This was a missing fixture, not evidence of denied access. The probe now distinguishes screenshot
feasibility from the stricter camera-plus-screenshot acceptance case. At 15:27:42 screenshot feasibility
passed in 0.484 seconds with camera acceptance explicitly reported NOT RUN. The strict case retains
the camera-fixture requirement behind `DEVICEBRIDGE_LIVE_CAMERA_IMAGE_PROBE=1`; it must not silently
pass without a camera image. Default tests skip both physical probes.

## iOS research — not physical success

Read-only SDK and official-documentation research identified this public candidate path:
`ICDeviceBrowser` → exact verified phone association → `ICCameraDevice` session/catalog →
`ICCameraFile` thumbnail/download. No iPhone content read or Mac authorization change was attempted.

- `ICDevice.UUIDString`, persistent ID, serial and USB location fields exist, but equality with
  CoreDevice identity is not documented. Exact correlation is a go/no-go requirement; names are not IDs.
- `contentCatalogPercentCompleted` and the complete-catalog delegate distinguish pending from empty.
- Access-restriction callbacks exist. The generic locked flag concerns deletion protection and must
  not substitute for the actual access-restriction signal.
- `mediaPresentation` defaults to converted media. Original presentation is required where supported;
  rendered/edited assets can still differ from unmodified camera originals and must be labelled.
- Thumbnail/download completions may arrive off the main queue. Confine Apple objects to a gateway
  and reject obsolete session/request callbacks. Download cancellation is conditional on support.
- CoreDevice copy domains remain temporary/appDataContainer/appGroupDataContainer/systemCrashLogs,
  not a system Photos-library interface. Generic ICC network discovery does not prove iPhone Wi-Fi
  import, and the iCloud-enabled flag does not prove cloud-only original hydration.

SDK: `/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/Library/Frameworks/ImageCaptureCore.framework/Headers/`, especially
`ICCameraDevice.h` (catalog/restriction/presentation), `ICCameraFile.h` (thumbnail/download),
`ICDevice.h` (identity) and `ICDeviceBrowser.h` (discovery).

Primary references: [ImageCaptureCore](https://developer.apple.com/documentation/imagecapturecore),
[media presentation](https://developer.apple.com/documentation/imagecapturecore/iccameradevice/mediapresentation),
[download API](https://developer.apple.com/documentation/imagecapturecore/iccamerafile/requestdownload(options:completion:)),
[Apple's cable-import workflow](https://support.apple.com/guide/image-capture/imgcp1003/mac).

## Remaining acceptance

### iOS physical follow-up — 2026-09-07, module-navigation turn

Historical result, superseded by the unlocked-phone follow-up below: T102 remained OPEN.
A bounded public-framework probe is now available as
`scripts/probe-ios-photo-identity.sh` / `.swift`. It uses the explicit
`DEVICEBRIDGE_LIVE_IOS_TRANSPORT` reference phone; it never picks the first or same-named camera.
Default mode is device metadata only. `DEVICEBRIDGE_LIVE_IOS_CATALOG=1` additionally permits a
catalog-session attempt for that exact phone, without thumbnail/original download or phone mutation.

Observed on the designated iPhone 12:

- Fresh CoreDevice command-readiness check passed (0.302 seconds); paired USB route and stable UDID.
- ICC local enumeration returned one or two USB cameras across observations. Neither camera serial
  nor camera UUID directly equalled the selected CoreDevice UDID. Immediate initial enumeration
  could miss the target; the probe now waits up to ten seconds for exact association.
- Public IOKit USB serial, normalized only for UDID separator/case, matched the selected hardware
  UDID at exactly one USB location. ICC USB location matched exactly one camera. No raw identifiers,
  filenames, photo bytes, hashes or full metadata were logged. This is observed hardware correlation,
  not yet a production cancellation/removal-safe adapter.
- First catalog attempt: `opened=false`, `complete=false`, `restricted=true`; requested original
  media presentation, but no original representation was actually retrieved. Close was requested;
  `hasOpenSession` had not cleared within the two-second observation. The probe process exited;
  close acknowledgment was **not** qualified as passed.
- Added an early restricted-access guard before opening. Fresh repeat: exact association passed,
  `isAccessRestrictedAppleDevice` remained true, **catalog session not requested, downloads=0**.
  No probe processes remain. Never interpret this as an empty album or working image capability.
- No entitlement changes, TCC grant/reset, helper installation, phone setting changes, content
  download, deletion or global UI control. MobAI API was unavailable; this probe uses the product's
  CoreDevice boundary plus Apple's public ICC/IOKit APIs.

At that point the requested user action was to unlock the designated iPhone and manually resolve any
trust/photo-access consent. The pre-open restriction check was subsequently corrected (see below).
Complete catalog readiness,
thumbnail, original-format/length/export checks and bounded acknowledged teardown/late-callback
rejection are still required before T103. Do not enable the production iOS image browser yet.

Sources: [ICC USB location](https://developer.apple.com/documentation/imagecapturecore/icdevice/usblocationid),
[ICC device identity](https://developer.apple.com/documentation/imagecapturecore/icdevice),
[ImageCaptureCore setup](https://developer.apple.com/documentation/imagecapturecore).
Installed SDK confirms `isAccessRestrictedAppleDevice` and access-restriction callbacks. The
contents-authorization request APIs are unavailable on macOS; do not invoke their iOS-only variants
or add broad Mac Photos authority as a speculative workaround.

Default regression at 15:33:37: **151 discovered tests / 144 executed / 7 physical tests skipped**,
31 suites, exit zero. No production Mac UI was changed or launched in this planning step. Existing
core behavior remains covered; physical probe skips are not counted as passed phone tests.

T099/T100 production entry points now have the evidence above. Provide one
existing camera photo on the Android test phone for strict acceptance. T102's subsequent USB result
is recorded below; T103 production integration is still required. T101 also needs isolated UI, source/device-switch failures,
Chinese/English display and export collision/integrity checks. No full Photos/iCloud or wireless parity
is inferred from the current probe.

### iOS unlocked-phone follow-up — 2026-09-07, T102 PASS

The user unlocked the designated iPhone 12 (iOS 18.3.1) and requested continuation. The standalone
Swift 6 probe used public CoreDevice/IOKit/ImageCaptureCore APIs in the background. No desktop input,
XCTest UI runner, helper installation, permission/entitlement change, or phone mutation was performed.

Observed lifecycle: exact paired USB identity → unique IOKit serial/location and ICC camera match →
open → positive unrestricted/live-session state → complete catalog → serialized samples → invalidate
request/cancel → close acknowledgment. CameraCatalogProbe owns the probe session and request revision;
each asynchronous content result checks its active request before publication. A stale download
callback can remove only its own UUID temporary directory, never the newer result's artifact.

The old pre-open restricted flag was a false blocker on this phone: opening can initially return
`ICReturnDeviceIsPasscodeLocked` (-9943), followed by restriction removed with `hasOpenSession=true`
and a complete catalog. Closing can set the flag back to restricted. The probe now treats -9943 as
waiting for unlock, not success: content requires a positive unrestricted live session plus complete
catalog. Other open errors fail. Both legacy delegate and completion-style open APIs showed this
sequence; an extra close/reopen did not fix it. Apple documents the
[restriction-removed callback](https://developer.apple.com/documentation/imagecapturecore/iccameradevicedelegate/cameradevicedidremoveaccessrestriction%28_%3A%29)
as unlocked, paired and media available. Do not copy the obsolete early guard into T103.

| Physical check | Observed result |
|---|---|
| Exact selected-phone association | One matched USB location and one ICC camera, despite two visible USB cameras |
| Complete catalog | 13 media items; 10 still-image candidates within the 20 MiB probe limit |
| PNG | 1170×2532, 314,665 bytes; thumbnail 148×320, 12,765 bytes |
| JPEG | 5000×7499, 5,159,523 bytes; thumbnail 214×320, 21,874 bytes |
| HEIC | 4032×3024, 7,510,580 bytes; thumbnail 240×320, 14,351 bytes |
| Original representation | `.originalAssets`; all three actual ImageIO types matched their expected formats and catalog lengths; bounded decode passed |
| Local export integrity | SHA-256 of local export matched the downloaded bytes for each sample; remote SHA-256 is unavailable |
| Real cancellation | Returned Progress cancelled; completion error -9937 (`ICReturnDownloadCanceled`) |
| Late-result isolation | Callback arrived after request invalidation; newer-result marker retained; old partial directory removed |
| Teardown | Close callback acknowledged success and `hasOpenSession=false` |
| Final cleanup | Zero probe-owned temporary directories and no PhotoIdentityCheck process remained |

The final HEIC + cancellation command exited zero; the earlier PNG/JPEG + cancellation run also
passed. Commands/opt-ins are in `quickstart.md`. Only counts, dimensions, types, byte lengths and
safe platform error codes are logged; no image names, bytes, raw identifiers or hashes.
Original-presentation data is not a guarantee of an unedited camera master. No remote-source
cryptographic checksum is claimed.

Two standalone-probe crashes exposed Swift 6 actor assumptions before the passing runs: ICC invokes
the synchronous `shouldGetThumbnail` delegate and download completion off the main queue. Removed
the optional thumbnail predicate, made the constant metadata predicate nonisolated, and made both
content completions explicitly `@Sendable` before hopping to MainActor for request checks. These
were probe failures, not Debug app crashes. One 314,665-byte test-owned PNG left by the crash was
verified and removed with its unique directory; the phone original was untouched. Normal samples
and exports were removed after checks. Raw crash reports were not copied into the repository.

T102 is complete as a bounded public-API go/no-go experiment, **not production/UI acceptance**.
T103 must still provide deterministic restriction/incomplete-catalog/identity-mismatch/removal and
post-teardown callback tests, session-generation integration, bounded catalog policy, representation
and integrity labels, and a real app-level USB check before enabling iPhone Images. Replug/lock
transitions, large libraries, wireless import, cloud-only originals and Live Photo companions are
not qualified by these samples. iOS clipboard/screenshot runner work remains separately gated.
This follow-up changed the probe and evidence only; no app rebuild, Release or DMG was performed.
