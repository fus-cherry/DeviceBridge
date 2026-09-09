#!/usr/bin/env python3
"""Validate release identity and the managed helpers before sealing a DMG."""
import hashlib
import json
from pathlib import Path
import plistlib
import sys

REQUIRED_RUNNER_FILES = (
    "helpers/ios/DeviceBridgeRunner.xcodeproj/project.pbxproj",
    "helpers/ios/DeviceBridgeHost/DeviceBridgeHostApp.swift",
    "packages/DeviceBridgeProtocol/Package.swift",
    "packages/DeviceBridgeSecureChannel/Package.swift",
)


def verify(app: Path, version: str, build: str) -> dict:
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if (info.get("CFBundleShortVersionString"), info.get("CFBundleVersion")) != (version, build):
        raise ValueError("bundle version does not match release version/build")
    if info.get("CFBundleIdentifier") != "dev.debugutility.DeviceBridge":
        raise ValueError("unexpected bundle identifier")
    if info.get("LSMinimumSystemVersion") != "14.0":
        raise ValueError("unexpected minimum macOS version")
    helpers = app / "Contents/Resources/Helpers"
    manifest = json.loads((helpers / "manifest.json").read_text())
    actual_hash = hashlib.sha256((helpers / "android-helper.apk").read_bytes()).hexdigest()
    if actual_hash != manifest["android"]["sha256"]:
        raise ValueError("embedded Android APK SHA-256 mismatch")
    runner = helpers / "ios-runner"
    for relative in REQUIRED_RUNNER_FILES:
        if not (runner / relative).is_file():
            raise ValueError(f"missing iOS runner source: {relative}")
    for path in helpers.rglob("*"):
        if path.is_symlink() and not path.resolve().is_relative_to(helpers.resolve()):
            raise ValueError(f"escaping helper symlink: {path.relative_to(helpers)}")
        mode = path.stat().st_mode
        if path.is_file() and mode & 0o444 != 0o444:
            raise ValueError(f"helper resource is not readable by all users: {path.relative_to(helpers)}")
        if path.is_dir() and mode & 0o555 != 0o555:
            raise ValueError(f"helper directory is not traversable by all users: {path.relative_to(helpers)}")
        if path.suffix.lower() in {".p12", ".pfx", ".p8", ".key", ".pem", ".jks", ".keystore", ".mobileprovision", ".provisionprofile"}:
            raise ValueError(f"private signing material in helper bundle: {path.relative_to(helpers)}")
    return {"version": version, "build": build, "android_sha256": actual_hash,
            "android_version_code": manifest["android"]["versionCode"]}


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit("Usage: verify-release.py APP VERSION BUILD")
    print(json.dumps(verify(Path(sys.argv[1]), sys.argv[2], sys.argv[3]), indent=2))
