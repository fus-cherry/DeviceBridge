#!/bin/bash
set -euo pipefail
# In-process execution/history checks: no window or actual device commands.
swift build --package-path packages/DeviceBridgeCore --disable-build-manifest-caching --product DeviceBridgeCoreChecks
bridge_bin=$(swift build --package-path packages/DeviceBridgeCore --show-bin-path)
python3 scripts/compile-core-check.py "$bridge_bin" \
  apps/macos/DeviceBridgeApp/ViewModels/AndroidShellViewModel.swift \
  apps/macos/DeviceBridgeAppTests/AndroidShellModelChecks.swift \
  -o "$bridge_bin/AndroidShellModelChecks"
"$bridge_bin/AndroidShellModelChecks"
