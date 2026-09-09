#!/bin/bash
set -euo pipefail
# Explicit physical metadata-only opt-in. The executable refuses another owned Runner session.
swift build --package-path packages/DeviceBridgeCore --product DeviceBridgeCoreChecks
preparation_bin=$(swift build --package-path packages/DeviceBridgeCore --show-bin-path)
python3 scripts/compile-core-check.py "$preparation_bin" \
  apps/macos/DeviceBridgeAppTests/IOSPreparationTimingCheck.swift \
  -o "$preparation_bin/IOSPreparationTimingCheck"
"$preparation_bin/IOSPreparationTimingCheck"
