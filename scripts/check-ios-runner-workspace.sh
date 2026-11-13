#!/bin/bash
set -euo pipefail
# Real model/services, synthetic external device boundaries; no UI or physical device commands.
swift build --package-path packages/DeviceBridgeCore --product DeviceBridgeCoreChecks
bridge_bin=$(swift build --package-path packages/DeviceBridgeCore --show-bin-path)
workspace_sources=(
  apps/macos/DeviceBridgeApp/ViewModels/PhoneImagesViewModel.swift \
  apps/macos/DeviceBridgeApp/ViewModels/DeviceInformationViewModel.swift \
  apps/macos/DeviceBridgeApp/ViewModels/AndroidShellViewModel.swift \
  apps/macos/DeviceBridgeApp/ViewModels/AndroidDeviceCommandBinding.swift \
  apps/macos/DeviceBridgeApp/AgentAPI/AgentAPIController.swift \
  apps/macos/DeviceBridgeApp/ViewModels/WorkspaceViewModel.swift
)
python3 scripts/compile-core-check.py "$bridge_bin" "${workspace_sources[@]}" \
  apps/macos/DeviceBridgeAppTests/IOSRunnerOwnerSigningChecks.swift \
  -o "$bridge_bin/IOSRunnerOwnerSigningChecks"
"$bridge_bin/IOSRunnerOwnerSigningChecks"
python3 scripts/compile-core-check.py "$bridge_bin" "${workspace_sources[@]}" \
  apps/macos/DeviceBridgeAppTests/IOSRunnerWorkspaceChecks.swift \
  -o "$bridge_bin/IOSRunnerWorkspaceChecks"
"$bridge_bin/IOSRunnerWorkspaceChecks"
