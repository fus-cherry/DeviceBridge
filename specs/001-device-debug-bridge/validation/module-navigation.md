# Module navigation — 2026-09-07

T108/T109 implement the approved four-card selector, selected fill/border/checkmark, Clipboard default
and one full-width content pane. Cards stay navigable when their capability is unavailable. Existing
WorkspaceViewModel/DeviceSessionStore ownership is unchanged; only WorkspaceView writes selectedModule.
No probe writes selection. RetainedModulePane keeps child identity while collapsing, disabling and
accessibility-hiding inactive content. FileTransferView passes visibility to PhoneImagesView, which
suspends thumbnails when hidden and resumes the model's current page. Explicit transfer, screenshot,
clipboard and memory tasks retain their existing owners and session guards.

## Fresh checks

- `bash scripts/check-workspace-modules.sh`: RED observed before collapse implementation: inactive
  pane occupied 420 points. GREEN: selected pane keeps natural height, inactive pane has zero height,
  and the same edited input instance survives hide/show. This is an in-process NSHostingView layout
  check, not desktop automation. An initial experiment found no accessibility hierarchy in an unshown
  window; that failed test approach was replaced, not presented as an accessibility pass.
- `bash scripts/check-image-view-model.sh`: PASS, including existing paging/cache, selection priority,
  cancellation/export/stale-save checks plus hidden/resumed page preservation without extra downloads.
- `bash scripts/check-workspace-inventory.sh`: PASS, including actual silent five-second polling,
  manual refresh, meaningful changes, selection stability and stop/restart stale completion.
- `swift test --package-path packages/DeviceBridgeCore --filter
  'PhysicalDeviceTests/iosReadiness|InterfaceLanguageTests'` with the explicitly selected iOS transport:
  **7 tests passed**, including one physical iOS readiness test and six localization tests.
- Incremental `xcodebuild build -project apps/macos/DeviceBridge.xcodeproj -scheme DeviceBridge
  -configuration Debug -destination 'platform=macOS,arch=arm64' ONLY_ACTIVE_ARCH=YES`: **BUILD SUCCEEDED**.
  Build log: `/tmp/devicebridge-modules-debug.log`.
- Updated pre-existing UI fixtures to navigate modules before asserting their actions. Swift 6
  typecheck passed using the macOS SDK, Developer/Library/Frameworks and Developer/usr/lib. The first
  standalone invocation omitted the XCTest Swift-module include path; adding it resolved the harness
  import errors. **No XCTest UI execution**, synthesized input, global desktop control or permission
  changes. Existing UI qualification gaps remain open.
- Requested graceful termination only of the verified old Debug process, then launched the Debug
  app with `open -g`. Verified the new process remained alive (PID 23755, >1 minute). No Release,
  DMG generation or installed-app replacement.

## User visual check still required

Click all four cards in Chinese and English; confirm only the selected pane is visible, unavailable
iOS actions explain their limitation, and file input/album page/preview remain after returning.
Run memory monitoring, visit another module, return and confirm the latest sample continues.
Keyboard reachability/hidden shortcuts and rendered selected styling require user inspection; the
headless layout check does not claim visual or full accessibility qualification.

iOS content work remains separately gated: see `phone-images.md`. The physical identity association
passed, but the reference phone's camera-import interface reports restricted access.
