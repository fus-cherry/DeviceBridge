# Phone Images Contract

Status: Android production provider/browser implemented; USB screenshot round-trip verified.
Actual desktop interaction, camera-photo fixtures, wireless and iOS remain separately gated.
Implements FR-P01–FR-P03 and SC-P01–SC-P02. General file transfer remains unchanged.

## Public service boundary

```text
ImageSource = androidDCIM | androidPictures | androidDownload | iosUSBCameraImport
ImageItemID = UUID (local, ephemeral, catalog-bound)
ImageCatalog = catalogID + sourceDevice + sessionGeneration + source + items
ImageItem = itemID + displayName + relativeDirectory + byteLength + modifiedAt
ImagePreview = previewID + catalogID + item + pixelDimensions + mediaType + thumbnailPNG + previewPNG

ImageLibraryService(store, capturedSession, provider, sessionDirectory)
ImageLibraryService.load(source: ImageSource) async throws -> ImageCatalog
ImageLibraryService.thumbnail(itemID: ImageItemID) async throws -> Data
ImageLibraryService.preview(itemID: ImageItemID) async throws -> ImagePreview
ImageLibraryService.export(previewID: UUID, destination: URL, replaceExisting: Bool)
    async throws -> URL
ImageLibraryService.clear() async
```

The service owns the committed catalog, preview, item-locator mapping and request revision. The
existing DeviceSessionStore owns selected device, transport, operation token and generation. Views
cannot construct a remote locator from a filename or change the catalog mapping. A locator is valid
only for its original catalog/device/session and is never persisted or sent to diagnostics.

The provider boundary consumes a captured transport and one source or service-owned locator:

```text
list(source, transportID, validateSession) async throws -> [ImageCandidate]
receive(locator, transportID, partialURL, validateSession) async throws -> DeviceFileReceipt
```

`ImageCandidate` contains validated metadata and an internal provider locator. Android receipts reuse
`DeviceFileReceipt` (length and required source SHA-256); source identity is checked by the provider.
The original URL/receipt stays private to the service. Preview device/generation comes from its catalog.
The service uses `PhoneImageError`/bounded command errors rather than a second outcome wrapper; the
view model maps errors to safe localized text. The future iOS representation model is still gated.
Providers do not mutate selection, catalogs or published artifacts. In the iOS candidate the locator
refers to an ICC item held only by its session gateway, never a free-form CoreDevice file path.

## Android data boundary

- Exact roots: `/sdcard/DCIM`, `/sdcard/Pictures`, `/sdcard/Download`. Source selection is enum-based.
  Do not scan `/sdcard`, app-private storage, cloud accounts or removable volumes implicitly.
- Enumerate regular files without following child symlinks. Fixed `find -printf` metadata contains
  byte length, modification time and path separated/terminated by NUL. Host parsing is byte-based;
  whitespace/newline in a valid filename cannot create another entry. Reject malformed tuples,
  invalid UTF-8, negative/overflow lengths and nonfinite timestamps.
- Validate source-prefix/component boundaries, traversal/NUL rejection and canonical scope
  before transfer; reject symlink escape or changed source identity. Never reuse an old locator after
  refreshing, switching source or reconnecting. ADB remote-shell operands require tested literal
  quoting despite the host Process argv boundary. No interpolation of filenames as executable syntax.
- Known extensions are discovery hints: JPEG, PNG, HEIF/HEIC, WebP, GIF, AVIF and BMP. ImageIO must
  actually recognize bytes before preview. Corrupt images remain a visible per-item error.
- `adb exec-out head -c (catalogLength+1)` performs a capped raw-byte read, followed by an exclusive
  write to a unique local partial path. `exec-out` escapes operands itself; only `adb shell` operands
  use our shell quoting. Compare length and SHA-256
  with source metadata, and reject a source that changed during retrieval. Missing hashes lower the
  stated verification level; do not claim hash validation when only length is available.
- The preview read limit is 20 MiB and 100 MP; one active read, no automatic full-catalog download.
  The shared command runner retains stdout/stderr under one streaming quota with 16 KiB read chunks.
  Read one byte beyond the expected length to reject growth before writing a file; never use an
  uncapped pull. Complete a session check before and after each provider command. Clear cancels
  the service-owned worker; caller cancellation propagates to that worker and its child command.
  Stop/cancellation terminates the bounded child command and removes only the matching partial path.
- Nonzero listing, inaccessible root, malformed output and timeout are not successful empty albums.
  A genuinely successful empty listing is empty. Limit errors are explicit, not partial success.
- The same provider may target authorized USB or Wi-Fi ADB transport IDs. USB is the verified baseline;
  wireless image transfer and recovery require their own physical tests. Never migrate an active read.

## iOS go/no-go boundary

T102 and the T103 production Workspace path now have [physical evidence](../validation/ios-images-runtime.md).
One workspace-owned native browser survives catalog refresh/reselection; fresh media-session delegates
own each catalog. Session handoff waits for close acknowledgment, and failed close is latched across
providers until restart. Cancellation drains the platform callback or invalidates the media session.
The download API enforces the 20 MiB admission limit via metadata, monitors private-directory growth
every 100 ms and validates final length. Its transient storage bound is soft, not a hard streaming
quota; the reference phone rejected the public capped offset/length read experiment. Do not claim
hard transit capping. This differs from Android's hard capped raw-read path above.

Use public ImageCaptureCore only. Before connecting it to the app, prove all of these on the designated
iPhone; otherwise keep the capability experimental/action-required:

1. `ICDeviceBrowser` discovers a local USB camera. Correlate it to the selected physical iPhone with
   verified hardware identity; `UUIDString`, serial and CoreDevice ID equality cannot be assumed.
   Display names and first/only-camera heuristics never authorize an image read.
2. A retained camera delegate opens the session; restriction/removal callbacks are handled. Only
   complete catalog readiness makes an empty result meaningful. Restriction is not empty success.
3. For HEIF-capable devices request original media presentation. Default converted assets must not
   be labelled original. Burned-in effects/edited assets may still expose rendered representations;
   show representation truthfully instead of claiming an unedited camera original.
4. Request thumbnail data on demand, and download to an app-controlled partial destination with
   overwrite and delete-after-download disabled. Callback success, actual file, length/type and
   representation checks precede publication. Report that remote SHA-256 is unavailable when it is.
5. Serialize camera downloads. Cancel returned Progress/device download where supported, close on
   teardown, and guard every callback by camera identity, session generation and request revision.
   A late callback cannot re-open the session or publish/delete a newer request's artifact.

Public API availability is not proof of iPhone Wi-Fi media import or cloud-only iCloud originals.
Do not enable either in the initial provider. Hidden/restricted assets, Live Photo video companions
and unsupported formats are not implicitly requested; this slice exports still-image files only.
Phone trust/unlock and any Mac consent are user actions. No automatic Photos entitlement/permission
change is authorized by this document; surface the exact blocker for review first.

## UI and terminal side effects

The Files panel gains Images (default) and File transfer modes. Images offers a source selector,
Load/Refresh, a locally paged album grid, selected-image preview, Cancel and Download original. All owned copy
and accessibility labels use the existing Chinese/English catalog. Names/paths/data are opaque.
The header always shows the source device and scope, and missing dimensions remain unavailable.

Only explicit Load enumerates image entries. Current-page (24 items) thumbnail reads are sequential,
cancelled/drained before selection/export, and derive only a 320-pixel PNG before deleting temporary
original bytes. Thumbnail reads never replace the selected preview or export source. The presentation
cache holds at most 48 thumbnails / 20 MiB; source/device change clears it. No unvisited-page or
full-library prefetch. This uses the existing original-read channel, not a remote thumbnail service.
Selecting an image starts its bounded original read;
export saves the verified original associated with that preview. Save-panel completion must recheck
the captured preview/revision and session token. Final destination replacement requires confirmation.
The service is bound to its creation-time device/transport/generation, not whatever is selected later.
Source invalidation and terminal rename serialize under a short validity lock; session validation and
rename run on the session actor without an await between them. Preview publication is a commit point:
cancellation during subsequent operation cleanup cannot delete the committed original. The UI drains
cancellation and reconciles from the committed service preview before allowing another action.

Every save initially uses exclusive rename. A collision offers a separate replacement confirmation
bound to the captured destination and UI revision; existence after save-panel completion is not consent.
Failure of a new preview preserves the last valid preview in the same source, visibly labelled; source
or device switching clears it. Cleanup never deletes a phone image or an unrelated user file.

## Required tests

- Ordinary/Unicode/spaces/apostrophe/newline filenames; traversal, symlink escape and malformed NUL
  tuples; output/record limit; denied, missing root, true empty and unsupported format.
- Same-device source switch; newer preview superseding a slow one; disconnect/recovery; cancellation
  during listing/pull/decode/save; late results must not update the new selection or save destination.
- Image type/dimension/byte limits; truncated data; source changes while pulling; hash/length mismatch;
  original bytes remain exact while thumbnail/preview are downsampled; collision refusal.
- Readiness and initial panel render invoke zero enumeration, image read or content retention.
- iOS incomplete catalog, access restriction, device correlation mismatch, default conversion,
  download cancellation/removal and callbacks arriving after teardown, before runtime enablement.
- Physical existing photo plus screenshot on each enabled platform; decoded preview and unchanged
  export; platform restrictions recorded honestly. The planning probe is not UI/provider acceptance.
