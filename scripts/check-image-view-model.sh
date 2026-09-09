#!/bin/bash
set -euo pipefail
# Run from the repository root. This compiles production UI state without launching an app.
swift build --package-path packages/DeviceBridgeCore --product DeviceBridgeCoreChecks
bridge_bin=$(swift build --package-path packages/DeviceBridgeCore --show-bin-path)
python3 scripts/compile-core-check.py "$bridge_bin" \
  apps/macos/DeviceBridgeApp/ViewModels/PhoneImagesViewModel.swift \
  apps/macos/DeviceBridgeAppTests/PhoneImagesModelChecks.swift \
  -o "$bridge_bin/PhoneImagesModelChecks"
"$bridge_bin/PhoneImagesModelChecks"
