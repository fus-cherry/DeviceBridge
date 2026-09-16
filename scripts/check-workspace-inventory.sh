#!/bin/bash
set -euo pipefail
# Compile the real workspace model without launching an app or touching a device.
inventory_build=${DEVICEBRIDGE_INVENTORY_BUILD:-/tmp/devicebridge-inventory-build}
swift build --package-path packages/DeviceBridgeCore --scratch-path "$inventory_build" --product DeviceBridgeCoreChecks
bridge_bin=$(swift build --package-path packages/DeviceBridgeCore --scratch-path "$inventory_build" --show-bin-path)
workspace_sources=(
  apps/macos/DeviceBridgeApp/ViewModels/PhoneImagesViewModel.swift \
  apps/macos/DeviceBridgeApp/ViewModels/DeviceInformationViewModel.swift \
  apps/macos/DeviceBridgeApp/ViewModels/AndroidShellViewModel.swift \
  apps/macos/DeviceBridgeApp/ViewModels/AndroidDeviceCommandBinding.swift \
  apps/macos/DeviceBridgeApp/AgentAPI/AgentAPIController.swift \
  apps/macos/DeviceBridgeApp/ViewModels/WorkspaceViewModel.swift
)
python3 scripts/compile-core-check.py "$bridge_bin" "${workspace_sources[@]}" \
  apps/macos/DeviceBridgeAppTests/WorkspaceInventoryChecks.swift \
  -o "$bridge_bin/WorkspaceInventoryChecks"
"$bridge_bin/WorkspaceInventoryChecks"
python3 scripts/compile-core-check.py "$bridge_bin" "${workspace_sources[@]}" \
  scripts/verify-workspace-ios-memory.swift \
  -o "$bridge_bin/IOSMemoryAdmissionChecks"
"$bridge_bin/IOSMemoryAdmissionChecks"
