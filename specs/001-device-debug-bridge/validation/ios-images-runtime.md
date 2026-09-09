# iPhone Images runtime integration — 2026-09-07

## Fresh non-VM recheck — 2026-09-08 PASS

The actual Workspace and PhoneImagesViewModel physical check was freshly compiled and rerun on
the designated USB iPhone, exit 0 (`/tmp/devicebridge-ios-images-current.log`). Ten catalog entries
and ten decoded thumbnails; PNG 1170×2532 / 232,894 bytes, JPEG 5000×7499 / 5,159,523 bytes,
HEIC 4032×3024 / 7,510,580 bytes. Preview, original export, cancel/refresh/reselection and clearing
the old browser passed. Test exports were removed; phone photos were unchanged. No VM queries
or global desktop input. This remains production-model/backend evidence, not rendered UI acceptance.

## Outcome

T103 now connects the **production Workspace → PhoneImagesViewModel → ImageLibraryService →
IOSImageProvider → ImageCaptureCore** path for the selected stable USB iPhone. This is no longer
the standalone T102 probe. General CoreDevice file domains, iOS clipboard/screenshot and VM memory
are separate unfinished work; an online device is not evidence those features work.

The designated iPhone 12 / iOS 18.3.1 passed:

- Ten still-image catalog entries, correct selected device and USB source.
- All ten current-page thumbnails decoded through the production image service.
- PNG: 1170×2532, 232,894 exported bytes; JPEG: 5000×7499, 5,159,523 bytes;
  HEIC: 4032×3024, 7,510,580 bytes. The PNG differs from the earlier probe because the production
  catalog sorts by modification time and selects a different existing PNG.
- Production preview and exclusive original-format export; source length validated, then retained
  local original/export SHA-256 compared. Remote-source SHA-256 is unavailable and not claimed.
- Presentation cancellation, refresh after cancellation, old-browser invalidation on reselection,
  and a new provider loading the same phone successfully in the same process.

Physical runner: `scripts/check-ios-images-workspace.sh`, with the exact designated
`DEVICEBRIDGE_LIVE_IOS_TRANSPORT` and `DEVICEBRIDGE_LIVE_IOS_WORKSPACE_IMAGES=1`. It compiles the
actual app view models, opens no window, sends no input events, and removes its test exports.
This proves application routing/state and real backend behavior, not visual/mouse acceptance of
the running Debug window. T101 remains open for that user-driven check and other platform cases.

## Failures reproduced, then fixed

1. Initial real Workspace check failed: **Production workspace has no iOS image browser**.
   Workspace created an image provider only for Android. It now creates the iOS provider only for
   stable selected USB routes and supplies the iOS-only source picker.
2. A focused service test failed with `integrityMismatch`: iOS has no remote SHA-256. Only the iOS
   source now permits a nil remote checksum; Android still rejects it. The service computes and
   retains a local digest for subsequent export, and the UI labels this distinction in both languages.
3. Locked/open/incomplete-catalog and post-removal callback gate tests failed against an initial stub,
   then passed with `IOSPhotoAccessState`. -9943 waits for a positive unlock callback and complete
   catalog; restrictions, missing session and converted presentation cannot become successful content.
4. Independent review found that cancelling a Swift worker did not prove ICC download completion.
   Delayed-completion and timeout tests failed before the drainage implementation. The reservation
   now stays busy until completion or a five-second deadline; missed acknowledgment invalidates the
   media session so another download cannot start on it. A stale callback cleans only its own UUID
   directory and cannot publish a new preview.
5. A file-growth test failed before adding in-flight private-directory byte monitoring. The current
   100 ms monitor counts ICC temporary files, cancels above the catalog length and removes owned
   partials; final length is still mandatory. This is a **soft monitored transit limit**, not a hard
   filesystem/stream quota. A faster writer can overshoot between polls. Only catalog originals up to
   20 MiB enter this path, and preview decoding remains limited to 100 MP.
6. Tried the public offset/length read API on the reference HEIC to obtain a strict capped read.
   The callback returned unavailable; no success inferred. Opt-in reproduction is
   `DEVICEBRIDGE_LIVE_IOS_BOUNDED_READ=1` with the T102 HEIC probe. The proven download API remains
   production's path; this limitation is explicit, not an undocumented streaming guarantee.
7. Two physical cancel→refresh runs failed with USB matches=1 but new ICC browser cameras=0.
   Recreating ICDeviceBrowser in-process lost discovery on this host. Workspace now retains one
   lazily started `IOSPhotoDiscovery`; only media session state is recreated. The strengthened real
   runner then passed refresh and reselection/reload. The transient diagnostic print was removed.
8. Close completion is single-flight and awaited before reuse. A failed/timeout acknowledgment is
   latched in the workspace discovery owner, independently of weak session lifetime; it blocks later
   providers too. Its test failed before the latch and passed afterward. The actionable UI asks for
   cable reconnection and app restart rather than silently reusing a potentially active session.

## Ownership and checks

- Workspace owns the native discovery lifetime; connection and selection still belong to
  DeviceSessionStore. Discovery serializes camera handoff and records failed native teardown.
- Each catalog has fresh IOSPhotoSession state and opaque UUID→ICC item mappings. Exact hardware
  association uses the selected UDID's USB serial/location and is rechecked across suspensions.
- IOSImageProvider binds the transport and serializes operations. The image service retains its
  original committed catalog/preview/export ownership and token/request guards.
- Apple objects/callback publication are MainActor-confined. Synchronous metadata predicate is
  nonisolated; download completions are explicitly Sendable then hop to MainActor. ImageIO/hashing
  remain on the existing service actor, not the UI actor.
- Readiness/selection creates no photo catalog or file read. Explicit Load and current-page image
  requests are required. Download names are locally generated, no overwrite/delete/sidecars on phone.

Final core regression: Swift Testing reports **186 tests / 36 suites**, with **8 explicit physical
skips** (not phone passes). Headless image-model and retained-module checks pass. Incremental native
Debug build succeeds; no XCTest desktop UI execution, Release archive or DMG. Independent read-only
review's cancellation and failed-close findings were fixed and re-reviewed with no remaining blocker
in those paths; the soft transit-limit caveat remains documented above.

No phone images were changed or deleted, helper installed, permission granted, or global desktop
input used. Test exports are temporary only. Remaining acceptance: actual Debug window interaction,
physical cable removal/lock during read, large libraries, other iOS/device versions. Wireless photo
import, cloud-only originals, Live Photo video companions and an unedited camera-master guarantee
are not provided by this slice.
