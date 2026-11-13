"""Apple pipeline contracts run without real credentials or Apple services."""
import base64
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("apple_signing", Path(__file__).with_name("sign-apple-release.py"))
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
TEAM = "ABC1234567"
IDENTITY = "A" * 40
COMMIT = "b" * 40
VALUES = {
    "APPLE_CERTIFICATE_P12_BASE64": base64.b64encode(b"fake-test-p12-not-a-real-certificate" * 2).decode(),
    "APPLE_CERTIFICATE_PASSWORD": "certificate-canary",
    "APPLE_ID": "fixture@example.test",
    "APPLE_TEAM_ID": TEAM,
    "APPLE_APP_SPECIFIC_PASSWORD": "notary-canary",
}


class FakeCommands:
    def __init__(self, app, *, fail_phase=None, reject_notary=False, wrong_team=False):
        self.app = app
        self.calls = []
        self.fail_phase = fail_phase
        self.reject_notary = reject_notary
        self.wrong_team = wrong_team

    def run(self, args, *, phase, **kwargs):
        self.calls.append((args, phase))
        if phase == self.fail_phase:
            raise MODULE.SigningError("simulated command failed")
        if phase == "Validate Developer ID identity":
            team = "XYZ1234567" if self.wrong_team else TEAM
            return f'1) {IDENTITY} "Developer ID Application: Fixture ({team})"\n1 valid identities found\n'
        if phase == "Mount verified input DMG":
            mount = Path(args[args.index("-mountpoint") + 1])
            shutil.copytree(self.app, mount / "DeviceBridge.app")
        if phase == "Copy verified app":
            shutil.copytree(args[1], args[2])
        if phase == "Inspect Developer ID signature":
            return f"Authority=Developer ID Application: Fixture ({TEAM})\nTeamIdentifier={TEAM}\nflags=0x10000(runtime)\n"
        if phase == "Prepare app notarization submission":
            Path(args[-1]).write_bytes(b"zip")
        if phase == "Package signed DMG":
            Path(args[-1]).write_bytes(b"signed DMG fixture")
        if phase in ("Apple notarization upload", "Wait for Apple notarization"):
            return json.dumps({"id": "12345678-abcd-1234-abcd-123456789abc", "status": "Invalid" if self.reject_notary else "Accepted"})
        return ""


class AppleSigningTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.input = self.root / "input"
        self.input.mkdir()
        self.app = self.root / "fixture/DeviceBridge.app"
        contents = self.app / "Contents"
        (contents / "MacOS").mkdir(parents=True)
        for name in ("DeviceBridge", "devicebridge-agent"):
            target = contents / "MacOS" / name
            target.write_bytes(struct.pack("<II", 0xFEEDFACF, 0x0100000C))
            target.chmod(0o755)
        (contents / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "dev.debugutility.DeviceBridge", "CFBundleShortVersionString": "0.1.8",
            "CFBundleVersion": "132", "LSMinimumSystemVersion": "14.0",
        }))
        helpers = contents / "Resources/Helpers"
        helpers.mkdir(parents=True)
        apk = helpers / "android-helper.apk"
        apk.write_bytes(b"fixture APK")
        (helpers / "manifest.json").write_text(json.dumps({"android": {"sha256": MODULE.sha256(apk), "versionCode": 132}}))
        verifier_spec = importlib.util.spec_from_file_location("fixture_verifier", Path(__file__).with_name("verify-release.py"))
        verifier = importlib.util.module_from_spec(verifier_spec)
        verifier_spec.loader.exec_module(verifier)
        for name in verifier.REQUIRED_RUNNER_FILES:
            target = helpers / "ios-runner" / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text("fixture source")
        self.dmg = self.input / "DeviceBridge-0.1.8-build132-macOS-arm64.dmg"
        self.dmg.write_bytes(b"ad hoc input DMG")
        (self.input / "build-info.json").write_text(json.dumps({
            "version": "0.1.8", "build": "132", "commit": COMMIT,
            "architecture": "arm64", "macos_signing": "ad-hoc", "apple_notarized": False,
        }))
        (self.input / "release-notes.md").write_text("unsigned fixture notes")
        self.refresh_manifest()

    def refresh_manifest(self):
        (self.input / "SHA256SUMS.txt").write_text("".join(
            f"{MODULE.sha256(p)}  {p.name}\n" for p in (self.dmg, self.input / "build-info.json", self.input / "release-notes.md")))

    def invoke(self, commands, output=None):
        signer = MODULE.AppleSigner(commands)
        with patch.object(MODULE.sys, "platform", "darwin"), patch.dict(os.environ, {"RUNNER_TEMP": str(self.root)}):
            signer.run(self.input, output or self.root / "output", "0.1.8", "132", COMMIT, VALUES)
        return signer

    def test_complete_signing_requires_app_and_dmg_accepted_stapled_and_assessed(self):
        commands = FakeCommands(self.app)
        signer = self.invoke(commands)
        phases = [phase for _, phase in commands.calls]
        self.assertEqual(phases.count("Apple notarization upload"), 2)
        for name in ("Staple app notarization ticket", "Validate app notarization ticket", "Gatekeeper app assessment",
                     "Staple DMG notarization ticket", "Validate DMG notarization ticket", "Gatekeeper DMG assessment",
                     "Delete temporary keychain"):
            self.assertIn(name, phases)
        self.assertEqual(signer.summary["status"], "accepted")
        self.assertTrue(signer.summary["apple_notarized"])
        self.assertEqual(len(signer.summary["submissions"]), 2)
        info = json.loads((self.root / "output/build-info.json").read_text())
        self.assertTrue(info["apple_notarized"])
        self.assertEqual(info["macos_signing"], "Developer ID Application")
        self.assertEqual(list(self.root.glob("devicebridge-apple-*")), [])
        self.assertFalse(any("list-keychains" in args or "default-keychain" in args for args, _ in commands.calls))
        all_output = "".join(p.read_text() for p in (self.root / "output").iterdir() if p.suffix != ".dmg")
        for name, value in VALUES.items():
            if name != "APPLE_TEAM_ID":
                self.assertNotIn(value, all_output)

    def test_missing_secrets_report_names_only(self):
        with self.assertRaisesRegex(MODULE.SigningError, "APPLE_CERTIFICATE_PASSWORD"):
            MODULE.load_secrets({"APPLE_ID": "private-value"})

    def test_wrapped_certificate_base64_is_accepted(self):
        value = VALUES["APPLE_CERTIFICATE_P12_BASE64"]
        self.assertEqual(MODULE.decode_certificate("\n".join(value[i:i+20] for i in range(0, len(value), 20))), base64.b64decode(value))

    def test_invalid_certificate_and_account_inputs_rejected(self):
        for value in ("%%%", base64.b64encode(b"tiny").decode()):
            with self.assertRaises(MODULE.SigningError):
                MODULE.decode_certificate(value)
        for key, value in (("APPLE_TEAM_ID", "bad"), ("APPLE_ID", "invalid"), ("APPLE_CERTIFICATE_PASSWORD", "bad\nvalue")):
            values = dict(VALUES, **{key: value})
            with self.assertRaises(MODULE.SigningError):
                MODULE.load_secrets(values)

    def test_artifact_wrong_commit_or_checksum_rejected_before_key_import(self):
        with self.assertRaises(MODULE.SigningError):
            MODULE.verify_input(self.input, "0.1.8", "132", "a" * 40)
        self.dmg.write_bytes(b"changed")
        commands = FakeCommands(self.app)
        with self.assertRaises(MODULE.SigningError):
            self.invoke(commands)
        self.assertEqual(commands.calls, [])

    def test_manifest_rejects_traversal_duplicate_missing_and_symlink(self):
        manifest = self.input / "SHA256SUMS.txt"
        good = manifest.read_text()
        for bad in (good + good.splitlines()[0] + "\n", good.replace(self.dmg.name, "../outside.dmg"), ""):
            manifest.write_text(bad)
            with self.assertRaises(MODULE.SigningError):
                MODULE.verify_input(self.input, "0.1.8", "132", COMMIT)
        manifest.unlink()
        outside = self.root / "external-manifest"
        outside.write_text(good)
        manifest.symlink_to(outside)
        with self.assertRaises(MODULE.SigningError):
            MODULE.verify_input(self.input, "0.1.8", "132", COMMIT)

    def test_development_or_wrong_team_or_multiple_identities_rejected(self):
        for text in (f'1) {IDENTITY} "Apple Development: Fixture ({TEAM})"',
                     f'1) {IDENTITY} "Developer ID Application: Fixture (XYZ1234567)"',
                     '\n'.join([f'1) {IDENTITY} "Developer ID Application: Fixture ({TEAM})"'] * 2)):
            with self.assertRaises(MODULE.SigningError):
                MODULE.find_identity(text, TEAM)

    def test_wrong_team_and_import_failure_clean_up(self):
        for commands in (FakeCommands(self.app, wrong_team=True), FakeCommands(self.app, fail_phase="Import Developer ID certificate")):
            with self.assertRaises(MODULE.SigningError):
                self.invoke(commands)
            self.assertIn("Delete temporary keychain", [p for _, p in commands.calls])
            self.assertEqual(list(self.root.glob("devicebridge-apple-*")), [])
            shutil.rmtree(self.root / "output")

    def test_notary_rejection_withholds_success_metadata_and_cleans_up(self):
        commands = FakeCommands(self.app, reject_notary=True)
        with self.assertRaisesRegex(MODULE.SigningError, "Accepted"):
            self.invoke(commands)
        self.assertFalse((self.root / "output/build-info.json").exists())
        self.assertNotIn("Staple app notarization ticket", [p for _, p in commands.calls])
        self.assertIn("Delete temporary keychain", [p for _, p in commands.calls])

    def test_notary_wait_timeout_preserves_submission_id(self):
        commands = FakeCommands(self.app, fail_phase="Wait for Apple notarization")
        signer = MODULE.AppleSigner(commands)
        with patch.object(MODULE.sys, "platform", "darwin"), patch.dict(os.environ, {"RUNNER_TEMP": str(self.root)}):
            with self.assertRaises(MODULE.SigningError):
                signer.run(self.input, self.root / "output", "0.1.8", "132", COMMIT, VALUES)
        self.assertEqual(signer.summary["submission_state"], "submitted-pending")
        self.assertEqual(signer.summary["submissions"][0]["id"], "12345678-abcd-1234-abcd-123456789abc")
        self.assertNotIn("Staple app notarization ticket", [p for _, p in commands.calls])
        self.assertEqual([p for _, p in commands.calls].count("Apple notarization upload"), 1)

    def test_stapler_or_gatekeeper_failure_never_reports_accepted(self):
        for phase in ("Validate app notarization ticket", "Gatekeeper app assessment", "Validate DMG notarization ticket", "Gatekeeper DMG assessment"):
            commands = FakeCommands(self.app, fail_phase=phase)
            with self.assertRaises(MODULE.SigningError):
                self.invoke(commands)
            self.assertFalse((self.root / "output/build-info.json").exists())
            shutil.rmtree(self.root / "output")

    def test_no_overwrite_existing_output(self):
        output = self.root / "existing"
        output.mkdir()
        with self.assertRaises(MODULE.SigningError):
            self.invoke(FakeCommands(self.app), output=output)

    def test_unexpected_native_binary_and_escaping_symlink_rejected(self):
        extra = self.app / "Contents/MacOS/unreviewed"
        extra.write_bytes(struct.pack("<II", 0xFEEDFACF, 0x0100000C))
        with self.assertRaises(MODULE.SigningError):
            MODULE.native_files(self.app)
        extra.unlink()
        extra.symlink_to(self.root)
        with self.assertRaises(MODULE.SigningError):
            MODULE.native_files(self.app)

    def test_commands_do_not_echo_tool_output_or_inherit_apple_secrets(self):
        failure = subprocess.CompletedProcess([], 3, stdout="certificate-canary", stderr="notary-canary")
        with patch.dict(os.environ, VALUES), patch.object(MODULE.subprocess, "run", return_value=failure) as run:
            with self.assertRaises(MODULE.SigningError) as raised:
                MODULE.Commands().run(["fake-tool"], phase="Import identity")
            self.assertNotIn("canary", str(raised.exception))
            self.assertTrue(set(VALUES).isdisjoint(run.call_args.kwargs["env"]))

    def test_workflow_limits_secret_scope_and_never_uploads_private_temp(self):
        workflow = (Path(__file__).parent.parent / ".github/workflows/release.yml").read_text()
        job = workflow.split("\n  apple-sign:", 1)[1].split("\n  publish:", 1)[0]
        build = workflow.split("\n  build:", 1)[1].split("\n  apple-sign:", 1)[0]
        self.assertIn("needs: build", job)
        self.assertIn("refs/heads/cloud/0.1.8-candidate", job)
        self.assertIn("github.actor == 'fus-cherry'", job)
        for name in MODULE.SECRET_NAMES:
            self.assertNotIn(name, build)
        signed_upload = job.split("- name: Upload accepted signed and notarized DMG only", 1)[1]
        self.assertNotIn("if:", signed_upload)  # implicit success-only
        self.assertIn("path: ${{ runner.temp }}/apple-signed/", signed_upload)
        self.assertNotIn("devicebridge-apple", job)


if __name__ == "__main__":
    unittest.main()
