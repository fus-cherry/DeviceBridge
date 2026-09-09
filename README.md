# DeviceBridge

DeviceBridge is a small native macOS tool for a trusted Flutter development team. One Mac app
discovers Android and iOS devices, prefers USB, supports prepared wireless transports, and presents
clipboard, screenshot, scoped file-transfer, Flutter VM, memory, and Android Wi-Fi-maintenance tools.
The Flutter app being debugged does not need a package or code change.

## 0.1.1 internal trial

Clipboard now handles complete current text up to 1 MiB UTF-8 (not history), with an expanded editor,
Copy all and exclusive TXT save. Background device discovery is silent. Files → Images shows a
24-item thumbnail album and original download; only the current page is read after explicit Load.
Android shared-folder scope and iOS content restrictions remain unchanged. See
[trial evidence](specs/001-device-debug-bridge/validation/trial-feedback-20260907.md) for checks and gaps.

## Interface language / 界面语言

Use the language menu at the top right of the Mac window to choose **Follow System**, **简体中文**,
or **English**. The default follows the system (Chinese → Simplified Chinese; other languages →
English), and explicit choices persist across launches. The workspace changes immediately without
recreating its device session. Device names, clipboard contents, paths and transferred bytes remain
unchanged. Native macOS dialog/menu chrome and the mobile helpers follow their own OS language.

在 Mac 窗口右上角选择“跟随系统”“简体中文”或“English”，即可即时切换工作区语言。
选择会自动保存，不需要重启；设备名称、剪切板内容和文件路径不会被翻译。

## What a teammate needs

A teammate receiving a signed `DeviceBridge.app` does **not** build or install the Android helper
manually; the APK is embedded and installed or updated by DeviceBridge. Their Mac still needs:

- Apple Silicon macOS 14 or newer;
- Xcode 15.4 or newer, selected for `xcrun devicectl`, iOS Developer Mode, and runner signing;
- Android SDK Platform-Tools with ADB 37 or newer for Android;
- the normal device trust/authorization prompts, and one-time wireless pairing when Wi-Fi is used.

Android clipboard and keep-alive need the visible managed helper. iOS helper features additionally
need a development signing team on each developer Mac. The current iOS persistent command channel
is still under implementation; discovery and CoreDevice file operations do not depend on it.

## Contributor build

Contributors need Gradle 8.11.1 (or the matching Android Studio Gradle runner); the repository does
not currently vendor a Gradle wrapper binary.

Run the automated suites from the repository root:

```sh
swift test --package-path packages/DeviceBridgeCore

gradle -p helpers/android testDebugUnitTest assembleDebug

xcodebuild test -project apps/macos/DeviceBridge.xcodeproj \
  -scheme DeviceBridge -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/xcode-ui-derived \
  -only-testing:DeviceBridgeAppUITests \
  -skip-testing:DeviceBridgeAppUITests/DeviceWorkspaceUITests/testLiveInventoryCanSwitchBetweenTwoCommandReadyDevices
```

This UI command uses fixture devices only. Run the separately named live-device test only when
real-device interaction and managed helper preparation are intended.

### UI test authorization is not a teammate prerequisite

Desktop XCTest synthesizes real input and can steal focus/mouse control on a shared desktop. Do not
run it while the user works unless an isolated picture-in-picture session is actually available or
the user explicitly agrees to foreground testing. A preview window is not input isolation. Use
background core/physical-device checks instead; see [physical validation](specs/001-device-debug-bridge/validation/physical-background.md).
If `testmanagerd` requests enabling an input method, do not treat that as DeviceBridge clipboard
consent or automatically approve it.

XCTest may ask to enable developer UI automation on the Mac. Keep normal local signing enabled for
UI tests; do not add `CODE_SIGNING_ALLOWED=NO` to the test command. If startup stalls before the first
test, inspect the actual system prompt and the requesting app, then approve only the permission you
intend to grant. A timeout alone does not prove that a particular permission is missing. Do not reset
privacy settings or enable every permission as a workaround.

Codex Computer Use's Accessibility permission is for the agent operating the desktop, not a required
permission for teammates running DeviceBridge. The current app uses device tools for phone screenshots,
not Mac screen recording; its implementation does not require blanket Mac Accessibility or Full Disk
Access. Device trust, debugging/pairing, helper notification, and relevant file/network prompts are
separate and still depend on the operation and OS. Fresh-install permission qualification remains open.

Then build the Mac app:

```sh
xcodebuild build -project apps/macos/DeviceBridge.xcodeproj \
  -scheme DeviceBridge -configuration Debug \
  -derivedDataPath .build/xcode-derived
```

The `Package Managed Helpers` phase requires an Android APK before the Mac build. It embeds that APK,
the iOS runner project, and a generated SHA-256/version manifest under
`DeviceBridge.app/Contents/Resources/Helpers`.

## Android helper signing

`assembleDebug` is suitable for one developer and is automatically debug-signed. For a team build,
use one protected, stable internal signing key so future helper versions can update the installed APK.
Do not commit the keystore or passwords.

Set all four variables in the release shell, build the signed helper, then point the Mac archive at
that artifact:

```sh
export DEVICE_BRIDGE_HELPER_KEYSTORE='/secure/path/devicebridge-helper.jks'
export DEVICE_BRIDGE_HELPER_STORE_PASSWORD='stored-outside-the-repository'
export DEVICE_BRIDGE_HELPER_KEY_ALIAS='devicebridge-helper'
export DEVICE_BRIDGE_HELPER_KEY_PASSWORD='stored-outside-the-repository'

gradle -p helpers/android testDebugUnitTest assembleRelease

export DEVICE_BRIDGE_ANDROID_HELPER_APK="$PWD/helpers/android/app/build/outputs/apk/release/app-release.apk"
export DEVICE_BRIDGE_ANDROID_HELPER_METADATA="$PWD/helpers/android/app/build/outputs/apk/release/output-metadata.json"
```

Use a JKS keystore accepted by Android's signing tools. If a device already has a helper signed by a
different key, uninstall `dev.debugutility.helper` once before installing the team build.

## Developer ID archive

Install a `Developer ID Application` certificate and set the development team for the target. The
Release configuration enables Hardened Runtime, disables App Sandbox for local developer-tool access,
does not inject `get-task-allow`, and requests no runtime exceptions.

The simplest supported workflow is Xcode: Product > Archive, open Organizer, choose Distribute App,
then choose Developer ID / Direct Distribution and Upload for notarization.

The equivalent repeatable archive/export commands are:

```sh
xcodebuild archive -project apps/macos/DeviceBridge.xcodeproj \
  -scheme DeviceBridge -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$PWD/.build/archives/DeviceBridge.xcarchive" \
  DEVELOPMENT_TEAM='YOUR_TEAM_ID' CODE_SIGN_STYLE=Automatic

xcodebuild -exportArchive \
  -archivePath "$PWD/.build/archives/DeviceBridge.xcarchive" \
  -exportPath "$PWD/.build/export" \
  -exportOptionsPlist apps/macos/ExportOptions-DeveloperID.plist
```

Verify the exported product before submission:

```sh
codesign --verify --deep --strict --verbose=2 .build/export/DeviceBridge.app
codesign -d --entitlements :- .build/export/DeviceBridge.app
```

## Notarization and distribution

Store notarization credentials interactively in Keychain; never place the app-specific password in
the repository or shell history:

```sh
xcrun notarytool store-credentials 'DeviceBridge-notary' \
  --apple-id 'APPLE_ID' --team-id 'YOUR_TEAM_ID'

ditto -c -k --keepParent \
  .build/export/DeviceBridge.app .build/export/DeviceBridge-submit.zip

xcrun notarytool submit .build/export/DeviceBridge-submit.zip \
  --keychain-profile 'DeviceBridge-notary' --wait

xcrun stapler staple .build/export/DeviceBridge.app
xcrun stapler validate .build/export/DeviceBridge.app
spctl --assess --type execute --verbose=4 .build/export/DeviceBridge.app

ditto -c -k --keepParent \
  .build/export/DeviceBridge.app .build/export/DeviceBridge-notarized.zip
```

Review the notarization log even after success. A ZIP can be submitted but cannot itself be stapled,
so staple the app and create the final ZIP afterward.

Apple references: [notarizing macOS software](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution),
[custom notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow),
and [Hardened Runtime](https://developer.apple.com/documentation/xcode/configuring-the-hardened-runtime).
Android reference: [app signing](https://developer.android.com/studio/publish/app-signing).

## Validation and known limits

The executable validation guide is in
[`specs/001-device-debug-bridge/quickstart.md`](specs/001-device-debug-bridge/quickstart.md), with exact
results under `specs/001-device-debug-bridge/validation/`. Real-device checks remain required for iOS
runner transport, Android OEM battery policies, long wireless sessions, and large transfers.

The app refreshes inventory every five seconds. Selected Android sessions now run idle-only,
single-flight health checks, invalidate failed sessions, and attempt bounded ADB endpoint recovery.
Recovery verifies the existing authenticated helper identity before rebinding tools; unavailable
identity proof requires manual action. Wi-Fi helper lease renewal remains a separate mechanism.
Core command-fixture tests and all eight fixture UI tests pass, including recovery and device
switching. Earlier automation initialization failures did not recur in the latest runs.
iOS still has selection-time checks, not this recovery loop.
See [connection maintenance evidence](specs/001-device-debug-bridge/validation/android-connection-maintenance.md).
See the [task list](specs/001-device-debug-bridge/tasks.md) and
[iOS channel contract](specs/001-device-debug-bridge/contracts/ios-runner-channel.md) for the remaining
implementation and qualification work. A passing automated suite is not final device acceptance.
