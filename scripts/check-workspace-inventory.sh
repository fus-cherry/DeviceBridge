#!/bin/bash
set -euo pipefail
# Compile the real workspace model without launching an app or touching a device.
inventory_build=${DEVICEBRIDGE_INVENTORY_BUILD:-/tmp/devicebridge-inventory-build}
swift build --package-path packages/DeviceBridgeCore --scratch-path "$inventory_build" --product DeviceBridgeCoreChecks
bridge_bin=$(swift build --package-path packages/DeviceBridgeCore --scratch-path "$inventory_build" --show-bin-path)
python3 scripts/compile-core-check.py "$bridge_bin" \
  apps/macos/DeviceBridgeApp/ViewModels/PhoneImagesViewModel.swift \
  apps/macos/DeviceBridgeApp/ViewModels/WorkspaceViewModel.swift \
  apps/macos/DeviceBridgeAppTests/WorkspaceInventoryChecks.swift \
  -o "$bridge_bin/WorkspaceInventoryChecks"
"$bridge_bin/WorkspaceInventoryChecks"
