#!/bin/bash
set -euo pipefail

: "${DEVICEBRIDGE_LIVE_ANDROID_TRANSPORT:?Set the designated ADB transport ID}"
: "${DEVICEBRIDGE_LIVE_ADB_PATH:?Set the absolute ADB path}"
: "${DEVICE_BRIDGE_ANDROID_HELPER_APK:?Set the built helper APK path}"

swift build --package-path packages/DeviceBridgeCore --product DeviceBridgeCoreChecks
live_bin=$(swift build --package-path packages/DeviceBridgeCore --show-bin-path)
mkdir -p "$live_bin/Helpers"
cp apps/macos/DeviceBridgeApp/Resources/Helpers/manifest.json "$live_bin/Helpers/manifest.json"
cp "$DEVICE_BRIDGE_ANDROID_HELPER_APK" "$live_bin/Helpers/android-helper.apk"
python3 scripts/compile-core-check.py "$live_bin" \
  apps/macos/DeviceBridgeApp/ViewModels/PhoneImagesViewModel.swift \
  apps/macos/DeviceBridgeApp/ViewModels/DeviceInformationViewModel.swift \
  apps/macos/DeviceBridgeApp/ViewModels/AndroidShellViewModel.swift \
  apps/macos/DeviceBridgeApp/ViewModels/AndroidDeviceCommandBinding.swift \
  apps/macos/DeviceBridgeApp/AgentAPI/AgentAPIController.swift \
  apps/macos/DeviceBridgeApp/ViewModels/WorkspaceViewModel.swift \
  apps/macos/DeviceBridgeAppTests/AndroidCapabilityPhysicalCheck.swift \
  -o "$live_bin/AndroidCapabilityPhysicalCheck"
"$live_bin/AndroidCapabilityPhysicalCheck"
