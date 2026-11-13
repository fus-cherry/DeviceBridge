"""Format-only workflow contract and synthetic no-disclosure checks; no Secrets."""
import ast
from pathlib import Path
import os
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).parent.parent
WORKFLOW = ROOT / ".github/workflows/apple-format-check.yml"
SOURCE_SHA = "44f515fcad46d806c16e6fccff9ce82e8503a4f0"
NAMES = (
    "APPLE_CERTIFICATE_P12_BASE64", "APPLE_CERTIFICATE_PASSWORD", "APPLE_ID",
    "APPLE_TEAM_ID", "APPLE_APP_SPECIFIC_PASSWORD",
)
CANARY = "never-print-private-fixture-canary"


def embedded_script():
    content = WORKFLOW.read_text()
    return textwrap.dedent(content.split("python3 -I -B - <<'PY'\n", 1)[1].rsplit("          PY", 1)[0])


class AppleFormatCheckTests(unittest.TestCase):
    def run_check(self, updates=None, missing=(), signer_override=None):
        environment = {"PATH": os.environ["PATH"],
                       "APPLE_CERTIFICATE_P12_BASE64": CANARY + "-not-even-valid-base64",
                       "APPLE_CERTIFICATE_PASSWORD": CANARY,
                       "APPLE_ID": "synthetic-canary@example.invalid",
                       "APPLE_TEAM_ID": "ABCDE12345", "APPLE_APP_SPECIFIC_PASSWORD": CANARY}
        environment.update(updates or {})
        for name in missing:
            environment.pop(name)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            target = root / "approved-source/scripts/sign-apple-release.py"
            target.parent.mkdir(parents=True)
            if signer_override is None:
                shutil.copyfile(ROOT / "scripts/sign-apple-release.py", target)
            else:
                target.write_text(signer_override)
            result = subprocess.run([sys.executable, "-I", "-B", "-"], input=embedded_script(),
                                    text=True, capture_output=True, cwd=root, env=environment, timeout=10)
            self.assertNotIn(CANARY, result.stdout + result.stderr)
            self.assertEqual(result.stderr, "")
            self.assertFalse(list(root.rglob("*.p12")))
            self.assertFalse(list(root.rglob("*.keychain*")))
            self.assertFalse(list(root.rglob("__pycache__")))
            return result

    def test_format_pass_does_not_decode_certificate_authenticate_or_sign(self):
        result = self.run_check()
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "format passed; no Apple authentication/signing attempted\n")

    def test_line_break_rejection_names_secret_without_value(self):
        result = self.run_check({"APPLE_APP_SPECIFIC_PASSWORD": CANARY + "\n"})
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, "APPLE_APP_SPECIFIC_PASSWORD contains an invalid line break or NUL\n")

    def test_missing_fields_and_invalid_team_are_controlled(self):
        result = self.run_check(missing=("APPLE_CERTIFICATE_PASSWORD", "APPLE_ID"))
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, "Missing GitHub Secrets: APPLE_CERTIFICATE_PASSWORD, APPLE_ID\n")
        result = self.run_check({"APPLE_TEAM_ID": CANARY})
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, "APPLE_TEAM_ID must be the 10-character developer Team ID\n")

    def test_unexpected_import_or_validation_failure_never_echoed(self):
        for source in (f"raise RuntimeError({CANARY!r})\n", f"class SigningError(Exception): pass\ndef load_secrets(env): raise RuntimeError({CANARY!r})\n"):
            result = self.run_check(signer_override=source)
            self.assertEqual(result.returncode, 1)
            self.assertEqual(result.stdout, "format check failed unexpectedly; no secret values logged\n")

    def test_unknown_signing_error_never_echoed(self):
        source = f"class SigningError(Exception): pass\ndef load_secrets(env): raise SigningError({CANARY!r})\n"
        result = self.run_check(signer_override=source)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, "format validation failed; no secret values logged\n")

    def test_repo_actor_ref_event_attempt_and_source_are_pinned(self):
        content = WORKFLOW.read_text()
        for guard in ("github.repository == 'fus-cherry/DeviceBridge'", "github.actor == 'fus-cherry'",
                      "github.ref == 'refs/heads/cloud/0.1.8-apple-format-check'",
                      "github.event_name == 'push'", "github.run_attempt == 1"):
            self.assertIn(guard, content)
        self.assertEqual(content.count(SOURCE_SHA), 2)
        self.assertIn("persist-credentials: false", content)
        self.assertIn("permissions:\n  contents: read", content)
        self.assertNotIn("actions: write", content)
        self.assertNotIn("workflow_dispatch:", content)
        self.assertNotIn("cloud/0.1.8-candidate", content)

    def test_only_validation_step_has_secrets_and_no_artifact_or_external_tool(self):
        content = WORKFLOW.read_text()
        ordinary, validation = content.split("- name: Validate in-memory format only", 1)
        self.assertNotIn("secrets.APPLE", ordinary)
        self.assertEqual(validation.count("secrets.APPLE"), 5)
        for name in NAMES:
            self.assertIn("${{ secrets." + name + " }}", validation)
        for forbidden in ("upload-artifact", "download-artifact", "notarytool", "codesign", "security ",
                          "openssl", "curl ", "wget ", "xcodebuild", "AppleSigner(", "decode_certificate("):
            self.assertNotIn(forbidden, content)
        tree = ast.parse(embedded_script())
        calls = [node for node in ast.walk(tree) if isinstance(node, ast.Call)]
        module_calls = [node.func.attr for node in calls if isinstance(node.func, ast.Attribute)
                        and isinstance(node.func.value, ast.Name) and node.func.value.id == "module"]
        self.assertEqual(module_calls, ["load_secrets"])
        self.assertIn("values.clear()", validation)
        self.assertIn("environment.clear()", validation)
        self.assertIn("os.environ.pop(name, None)", validation)


if __name__ == "__main__":
    unittest.main()
