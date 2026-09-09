# Native Setup Build Smoke — 2026-09-04

Environment: Apple Swift 6.3.3, Xcode 26.6, ADB 37.0.1, Apple Silicon macOS 26.6.

## Swift core

```sh
swift test --package-path packages/DeviceBridgeCore
```

Result: exit 0; one Swift Testing package smoke test passed.

## macOS application

```sh
xcodebuild build -quiet -project apps/macos/DeviceBridge.xcodeproj \
  -scheme DeviceBridge -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

Result: exit 0. Xcode selected the first matching local Mac architecture and produced the native app.

## Android helper

```sh
apps/device_companion/android/gradlew -q -p helpers/android assembleDebug
```

Result: exit 0. The temporary command reuses the already-downloaded legacy Gradle wrapper without
linking the helper to Flutter; a dedicated wrapper remains release polish.

## iOS runner

```sh
xcodebuild build-for-testing -quiet \
  -project helpers/ios/DeviceBridgeRunner.xcodeproj \
  -scheme DeviceBridgeRunner -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO
```

Result: exit 0. The host app and UI-test runner compiled unsigned. Xcode emitted a non-blocking
traditional-headermap warning, which is tracked for project-setting cleanup before final release.

## Conclusion

The native macOS app, pure Swift core, Android Kotlin helper, and unsigned iOS XCUITest runner all
compile on the current workstation. This validates the revised technology split before connection
behavior is added. No device settings, signing configuration, or global toolchain installation was
changed.
