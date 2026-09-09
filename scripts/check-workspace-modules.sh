#!/bin/bash
set -euo pipefail
# In-process layout checks: no window, XCTest, desktop input or devices.
swift build --package-path packages/DeviceBridgeCore --product DeviceBridgeCoreChecks
bridge_bin=$(swift build --package-path packages/DeviceBridgeCore --show-bin-path)
python3 scripts/compile-core-check.py "$bridge_bin" \
  apps/macos/DeviceBridgeApp/ViewModels/*.swift \
  apps/macos/DeviceBridgeApp/Views/*.swift \
  apps/macos/DeviceBridgeAppTests/WorkspaceModuleChecks.swift \
  -o "$bridge_bin/WorkspaceModuleChecks"
"$bridge_bin/WorkspaceModuleChecks"
