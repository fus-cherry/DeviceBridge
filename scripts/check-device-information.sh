#!/bin/bash
set -euo pipefail
# In-process state checks: no window, device or installation.
swift build --package-path packages/DeviceBridgeCore --disable-build-manifest-caching --product DeviceBridgeCoreChecks
bridge_bin=$(swift build --package-path packages/DeviceBridgeCore --show-bin-path)
python3 scripts/compile-core-check.py "$bridge_bin" \
  apps/macos/DeviceBridgeApp/ViewModels/DeviceInformationViewModel.swift \
  apps/macos/DeviceBridgeAppTests/DeviceInformationModelChecks.swift \
  -o "$bridge_bin/DeviceInformationModelChecks"
"$bridge_bin/DeviceInformationModelChecks"
