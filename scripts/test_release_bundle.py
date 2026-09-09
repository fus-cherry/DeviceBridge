"""Check release packaging rejects incomplete or unsafe inputs before publishing."""
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import struct
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("release_bundle", Path(__file__).with_name("verify-release.py"))
release_bundle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release_bundle)


class ReleaseBundleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.app = Path(self.temp.name) / "DeviceBridge.app"
        self.helpers = self.app / "Contents/Resources/Helpers"
        self.helpers.mkdir(parents=True)
        self.agent = self.app / "Contents/MacOS/devicebridge-agent"
        self.agent.parent.mkdir(parents=True)
        self.agent.write_bytes(struct.pack("<II", 0xFEEDFACF, 0x0100000C))
        self.agent.chmod(0o755)
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "dev.debugutility.DeviceBridge",
            "CFBundleShortVersionString": "0.1.2", "CFBundleVersion": "10",
            "LSMinimumSystemVersion": "14.0",
        }))
        self.apk = self.helpers / "android-helper.apk"
        self.apk.write_bytes(b"fixture APK; signature checked separately by apksigner")
        (self.helpers / "manifest.json").write_text(json.dumps({"android": {
            "versionCode": 3, "sha256": hashlib.sha256(self.apk.read_bytes()).hexdigest(),
        }}))
        for file in release_bundle.REQUIRED_RUNNER_FILES:
            target = self.helpers / "ios-runner" / file
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text("fixture source")

    def verify(self):
        return release_bundle.verify(self.app, "0.1.2", "10")

    def test_complete_bundle(self):
        self.verify()

    def test_missing_agent_cli_is_rejected(self):
        self.agent.unlink()
        with self.assertRaisesRegex(ValueError, "devicebridge-agent"):
            self.verify()

    def test_agent_cli_in_resources_does_not_satisfy_bundle_contract(self):
        self.agent.replace(self.helpers / "devicebridge-agent")
        with self.assertRaisesRegex(ValueError, "devicebridge-agent"):
            self.verify()

    def test_non_executable_agent_cli_is_rejected(self):
        self.agent.chmod(0o644)
        with self.assertRaisesRegex(ValueError, "executable"):
            self.verify()

    def test_non_mach_o_agent_cli_is_rejected(self):
        self.agent.write_bytes(b"#!/bin/sh\n")
        with self.assertRaisesRegex(ValueError, "Mach-O"):
            self.verify()

    def test_wrong_agent_architecture_is_rejected(self):
        self.agent.write_bytes(struct.pack("<II", 0xFEEDFACF, 0x01000007))
        with self.assertRaisesRegex(ValueError, "arm64"):
            self.verify()

    def test_escaping_agent_symlink_is_rejected(self):
        outside = Path(self.temp.name) / "outside-agent"
        outside.write_bytes(struct.pack("<II", 0xFEEDFACF, 0x0100000C))
        outside.chmod(0o755)
        self.agent.unlink()
        self.agent.symlink_to(outside)
        with self.assertRaisesRegex(ValueError, "symlink"):
            self.verify()

    def test_changed_embedded_apk_is_rejected(self):
        self.apk.write_bytes(b"changed APK")
        with self.assertRaisesRegex(ValueError, "SHA-256"):
            self.verify()

    def test_missing_local_runner_package_is_rejected(self):
        (self.helpers / "ios-runner/packages/DeviceBridgeProtocol/Package.swift").unlink()
        with self.assertRaisesRegex(ValueError, "missing"):
            self.verify()

    def test_wrong_release_version_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "version"):
            release_bundle.verify(self.app, "0.2.0", "10")

    def test_packaged_private_key_is_rejected(self):
        (self.helpers / "ios-runner/private.p12").write_bytes(b"private canary")
        with self.assertRaisesRegex(ValueError, "private"):
            self.verify()

    def test_owner_only_apk_is_rejected(self):
        self.apk.chmod(0o600)
        with self.assertRaisesRegex(ValueError, "readable"):
            self.verify()

    def test_owner_only_source_directory_is_rejected(self):
        (self.helpers / "ios-runner/packages").chmod(0o700)
        with self.assertRaisesRegex(ValueError, "traversable"):
            self.verify()

    def test_escaping_symlink_is_rejected(self):
        (self.helpers / "ios-runner/escape").symlink_to(self.app.parent)
        with self.assertRaisesRegex(ValueError, "symlink"):
            self.verify()


if __name__ == "__main__":
    unittest.main()
