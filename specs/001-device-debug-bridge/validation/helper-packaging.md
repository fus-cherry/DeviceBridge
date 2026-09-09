# Managed Helper Packaging Validation

## Build 7 local delivery — 2026-09-08

Release build 0.1.2 / 7, strict deep app signatures and final DMG CRC validation passed. Helper
packaging tests: 6 run / 1 opt-in build skip; actual Release packaging ran successfully separately.
Local DMG: `dist/DeviceBridge-0.1.2-build7-macOS-arm64-20260908.dmg`; SHA-256
`04297ffd484713c046393b1afd7ac253d10fcd81c9846f5d397d672afd4b6212`.
This is an ad-hoc signed local test artifact. Only Apple Development was found in the identity
inventory; Developer ID/notarization and clean-Mac first use remain uncompleted external gates.
[Current release scope](release-closure-20260908.md).


Date: 2026-09-07

Command:

```sh
xcodebuild -project apps/macos/DeviceBridge.xcodeproj -scheme DeviceBridge \
  -configuration Debug -derivedDataPath .build/xcode-derived \
  CODE_SIGNING_ALLOWED=NO build
```

Result: passed.

The product bundle contains:

- `Contents/Resources/Helpers/android-helper.apk` (version code 2);
- `Contents/Resources/Helpers/ios-runner/DeviceBridgeRunner.xcodeproj` and its source files;
- `Contents/Resources/Helpers/manifest.json` (schema 1, Android v2, iOS protocol v1).

The packaging phase rejects a missing APK, missing runner project, or Android version mismatch. It
recomputes the packaged APK SHA-256 and writes it into the bundle's manifest. The recorded digest
matched an independent `shasum -a 256` of the bundled APK.

