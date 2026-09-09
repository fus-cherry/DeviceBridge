#!/bin/bash
set -euo pipefail
swift build --package-path packages/DeviceBridgeCore --product DeviceBridgeCoreChecks
selection_bin=$(swift build --package-path packages/DeviceBridgeCore --show-bin-path)
python3 scripts/compile-core-check.py "$selection_bin" \
  apps/macos/DeviceBridgeApp/ViewModels/PhoneImagesViewModel.swift \
  apps/macos/DeviceBridgeApp/ViewModels/WorkspaceViewModel.swift \
  apps/macos/DeviceBridgeAppTests/DeviceSelectionChecks.swift \
  -o "$selection_bin/DeviceSelectionChecks"
"$selection_bin/DeviceSelectionChecks"
