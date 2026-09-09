#!/bin/bash
set -euo pipefail
# Controller checks use isolated fake business services; no real IPC endpoint or devices.
swift build --package-path packages/DeviceBridgeCore --disable-build-manifest-caching --product DeviceBridgeCoreChecks
bridge_bin=$(swift build --package-path packages/DeviceBridgeCore --show-bin-path)
python3 scripts/compile-core-check.py "$bridge_bin" \
  apps/macos/DeviceBridgeApp/ViewModels/DeviceInformationViewModel.swift \
  apps/macos/DeviceBridgeApp/ViewModels/AndroidShellViewModel.swift \
  apps/macos/DeviceBridgeApp/AgentAPI/AgentAPIController.swift \
  apps/macos/DeviceBridgeAppTests/AgentAPIWorkspaceChecks.swift \
  -o "$bridge_bin/AgentAPIWorkspaceChecks"
"$bridge_bin/AgentAPIWorkspaceChecks"
