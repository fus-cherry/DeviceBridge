#!/bin/bash
set -euo pipefail
swift build --package-path packages/DeviceBridgeCore --product DeviceBridgeCoreChecks
bridge_bin=$(swift build --package-path packages/DeviceBridgeCore --show-bin-path)
python3 scripts/compile-core-check.py "$bridge_bin" scripts/probe-ios-photo-identity.swift \
  -o "$bridge_bin/PhotoIdentityCheck"
"$bridge_bin/PhotoIdentityCheck"
