#!/usr/bin/env python3
"""Validate release identity and the managed helpers before sealing a DMG."""
import hashlib
import json
from pathlib import Path
import plistlib
import stat
import struct
import sys

REQUIRED_RUNNER_FILES = (
    "helpers/ios/DeviceBridgeRunner.xcodeproj/project.pbxproj",
    "helpers/ios/DeviceBridgeHost/DeviceBridgeHostApp.swift",
    "packages/DeviceBridgeProtocol/Package.swift",
    "packages/DeviceBridgeSecureChannel/Package.swift",
)

AGENT_RELATIVE_PATH = Path("Contents/MacOS/devicebridge-agent")
CPU_ARCHITECTURES = {
    7: "x86",
    0x01000007: "x86_64",
    12: "arm",
    0x0100000C: "arm64",
}


def macho_architectures(executable: Path) -> set[str]:
    data = executable.read_bytes()
    if len(data) < 8:
        raise ValueError("devicebridge-agent is not a Mach-O executable")

    magic = data[:4]
    thin_endian = {
        b"\xce\xfa\xed\xfe": "<",
        b"\xcf\xfa\xed\xfe": "<",
        b"\xfe\xed\xfa\xce": ">",
        b"\xfe\xed\xfa\xcf": ">",
    }.get(magic)
    if thin_endian:
        cpu_type = struct.unpack(f"{thin_endian}I", data[4:8])[0]
        return {CPU_ARCHITECTURES.get(cpu_type, f"cpu-{cpu_type:#x}")}

    fat_format = {
        b"\xca\xfe\xba\xbe": (">", 20),
        b"\xbe\xba\xfe\xca": ("<", 20),
        b"\xca\xfe\xba\xbf": (">", 32),
        b"\xbf\xba\xfe\xca": ("<", 32),
    }.get(magic)
    if not fat_format:
        raise ValueError("devicebridge-agent is not a Mach-O executable")

    endian, entry_size = fat_format
    architecture_count = struct.unpack(f"{endian}I", data[4:8])[0]
    if not 1 <= architecture_count <= 32 or len(data) < 8 + architecture_count * entry_size:
        raise ValueError("devicebridge-agent has an invalid Mach-O architecture table")
    return {
        CPU_ARCHITECTURES.get(
            struct.unpack(f"{endian}I", data[8 + index * entry_size:12 + index * entry_size])[0],
            "unknown",
        )
        for index in range(architecture_count)
    }


def verify_agent_cli(app: Path) -> list[str]:
    executable = app / AGENT_RELATIVE_PATH
    try:
        resolved = executable.resolve(strict=True)
    except FileNotFoundError as error:
        raise ValueError(f"missing bundled CLI: {AGENT_RELATIVE_PATH}") from error
    if not resolved.is_relative_to(app.resolve()):
        raise ValueError(f"escaping devicebridge-agent symlink: {AGENT_RELATIVE_PATH}")
    if not executable.is_file():
        raise ValueError(f"bundled CLI is not a file: {AGENT_RELATIVE_PATH}")
    if executable.stat().st_mode & (stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH) != 0o111:
        raise ValueError("bundled devicebridge-agent is not executable by all users")
    architectures = macho_architectures(executable)
    if architectures != {"arm64"}:
        found = ", ".join(sorted(architectures))
        raise ValueError(f"unexpected devicebridge-agent architecture: expected arm64, found {found}")
    return sorted(architectures)


def verify(app: Path, version: str, build: str) -> dict:
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if (info.get("CFBundleShortVersionString"), info.get("CFBundleVersion")) != (version, build):
        raise ValueError("bundle version does not match release version/build")
    if info.get("CFBundleIdentifier") != "dev.debugutility.DeviceBridge":
        raise ValueError("unexpected bundle identifier")
    if info.get("LSMinimumSystemVersion") != "14.0":
        raise ValueError("unexpected minimum macOS version")
    agent_architectures = verify_agent_cli(app)
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
    return {"version": version, "build": build, "agent_architectures": agent_architectures,
            "android_sha256": actual_hash,
            "android_version_code": manifest["android"]["versionCode"]}


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit("Usage: verify-release.py APP VERSION BUILD")
    print(json.dumps(verify(Path(sys.argv[1]), sys.argv[2], sys.argv[3]), indent=2))
