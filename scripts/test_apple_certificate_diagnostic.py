"""Synthetic-only tests for controlled local certificate diagnosis; no Apple calls."""
import base64
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).parent.parent
SPEC = importlib.util.spec_from_file_location("diagnostic", ROOT / "scripts/diagnose-apple-certificate.py")
M = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(M)
CANARY = "never-disclose-private-fixture-canary"


def result(code=0, output=b"", error=b""):
    return subprocess.CompletedProcess([], code, output, error)


class FakeCommands:
    def __init__(self):
        self.calls = []
        self.openssl = result(output=b"MAC: sha256, Iteration 2048\nShrouded Keybag: fixture")
        self.imported = result(output=b"1 identity imported. " + CANARY.encode())
        self.probed = result(output=b"probe_matching_named_developer_id_private_key\n")
        self.deleted = result()
        self.raise_on = None
        self.directory = None

    def run(self, args, *, data=None):
        self.calls.append((args, data))
        if self.raise_on and self.raise_on in args:
            raise M.DiagnosticError(CANARY)
        if args[0] == "/usr/bin/openssl":
            encrypted = Path(args[args.index("-in") + 1])
            self.directory = encrypted.parent
            if stat.S_IMODE(encrypted.stat().st_mode) != 0o600 or stat.S_IMODE(encrypted.parent.stat().st_mode) != 0o700:
                raise AssertionError("Private temporary permissions incorrect")
            return self.openssl
        if "import" in args: return self.imported
        if "delete-keychain" in args: return self.deleted
        if args[0] == "/fixture/probe": return self.probed
        return result()


class CertificateDiagnosticTests(unittest.TestCase):
    def setUp(self):
        self.environment = {"APPLE_CERTIFICATE_P12_BASE64": base64.b64encode(b"synthetic encrypted archive fixture" * 4).decode(),
                            "APPLE_CERTIFICATE_PASSWORD": CANARY, "APPLE_TEAM_ID": "ABCDE12345"}
        self.commands = FakeCommands()

    def diagnose(self, probe=Path("/fixture/probe")):
        with tempfile.TemporaryDirectory() as root, patch.dict(os.environ, self.environment, clear=False):
            environment = dict(self.environment)
            captured = io.StringIO()
            with contextlib.redirect_stdout(captured), contextlib.redirect_stderr(captured):
                report = M.diagnose(environment, probe, self.commands, root)
            self.assertEqual(captured.getvalue(), "")
            self.assertEqual(list(Path(root).iterdir()), [])
            self.assertEqual(environment, {})
            self.assertTrue(all(name not in os.environ for name in M.NAMES))
            self.assertNotIn(CANARY, json.dumps(report))
            self.assertEqual(report["apple_authentication_or_signing"], "not_attempted")
            return report

    def test_local_pair_pass_uses_no_export_and_cleans_temporary_chain(self):
        report = self.diagnose()
        self.assertEqual(report["openssl"], "parsed_mac_verified")
        self.assertEqual(report["security_import"], "imported")
        self.assertEqual(report["local_identity"], "probe_matching_named_developer_id_private_key")
        self.assertEqual(report["cleanup"], "complete")
        args, data = self.commands.calls[0]
        self.assertEqual(data, CANARY.encode() + b"\n")
        self.assertNotIn(CANARY, args)
        self.assertIn("-noout", args)
        self.assertEqual(self.commands.calls[-1][0][1], "delete-keychain")
        for args, _ in self.commands.calls:
            self.assertTrue(args[0] in ("/usr/bin/openssl", "/usr/bin/security", "/fixture/probe"))
            self.assertTrue(all(flag not in args for flag in ("-nodes", "-noenc", "find-identity", "export", "notarytool", "codesign", "default-keychain", "list-keychains", "set-key-partition-list", "-A")))

    def test_optional_probe_cannot_block_parser_and_import_diagnosis(self):
        report = self.diagnose(probe=None)
        self.assertEqual(report["openssl"], "parsed_mac_verified")
        self.assertEqual(report["security_import"], "imported")
        self.assertEqual(report["local_identity"], "probe_not_available")
        self.assertEqual(report["cleanup"], "complete")

    def test_mac_failure_never_called_password_definitely_wrong_or_imported(self):
        self.commands.openssl = result(1, error=b"Mac verify error: invalid password? " + CANARY.encode())
        report = self.diagnose()
        self.assertEqual(report["openssl"], "password_or_archive_integrity_failure")
        self.assertEqual(report["security_import"], "not_run")
        self.assertEqual(len(self.commands.calls), 1)

    def test_missing_mac_malformed_and_unknown_parse_fail_closed(self):
        for parsed, category in ((result(error=b"Warning: MAC is absent!"), "parsed_without_mac_integrity_proof"),
                                 (result(1, error=b"ASN1 wrong tag " + CANARY.encode()), "malformed_or_non_pkcs12_archive"),
                                 (result(1, error=CANARY.encode()), "parser_failure_unclassified")):
            self.commands = FakeCommands()
            self.commands.openssl = parsed
            report = self.diagnose()
            self.assertEqual(report["openssl"], category)
            self.assertEqual(report["security_import"], "not_run")

    def test_unsupported_parser_can_still_diagnose_apple_local_import_without_conversion(self):
        self.commands.openssl = result(1, error=b"digital envelope routines: unsupported")
        report = self.diagnose()
        self.assertEqual(report["openssl"], "parser_unsupported_algorithm")
        self.assertEqual(report["security_import"], "imported")
        self.assertEqual(report["local_identity"], "probe_matching_named_developer_id_private_key")

    def test_import_failure_only_categorized_and_always_cleans(self):
        for error, category in ((b"MAC verification failed during PKCS12 import", "mac_verification_failed"),
                                (b"Unknown format in import", "unknown_or_unsupported_format"),
                                (b"User interaction is not allowed", "interaction_denied"),
                                (CANARY.encode(), "import_failure_unclassified")):
            self.commands = FakeCommands()
            self.commands.imported = result(1, error=error + CANARY.encode())
            report = self.diagnose()
            self.assertEqual(report["security_import"], category)
            self.assertEqual(report["local_identity"], "not_run")
            self.assertEqual(report["cleanup"], "complete")

    def test_probe_errors_or_wrong_team_cannot_become_local_pass(self):
        for output, category in ((b"probe_no_identity\n", "probe_no_identity"),
                                 (b"probe_no_matching_named_developer_id_private_key\n", "probe_no_matching_named_developer_id_private_key"),
                                 (CANARY.encode(), "probe_failure_unclassified")):
            self.commands = FakeCommands()
            self.commands.probed = result(output=output, error=CANARY.encode())
            report = self.diagnose()
            self.assertEqual(report["local_identity"], category)

    def test_unknown_exception_and_cleanup_failure_are_controlled(self):
        self.commands.raise_on = "import"
        report = self.diagnose()
        self.assertEqual(report["error"], "unexpected_local_diagnostic_failure")
        self.assertEqual(report["cleanup"], "complete")
        self.commands = FakeCommands()
        self.commands.deleted = result(1, error=CANARY.encode())
        report = self.diagnose()
        self.assertEqual(report["cleanup"], "temporary_keychain_cleanup_failed")

    def test_invalid_inputs_never_write_or_call_tool(self):
        for key, value in (("APPLE_CERTIFICATE_P12_BASE64", "not base64"), ("APPLE_CERTIFICATE_PASSWORD", "bad\n"),
                           ("APPLE_TEAM_ID", CANARY), ("APPLE_CERTIFICATE_P12_BASE64", "QQ==")):
            previous = self.environment[key]
            self.environment[key] = value
            self.commands = FakeCommands()
            self.diagnose()
            self.assertEqual(self.commands.calls, [])
            self.environment[key] = previous

    def test_tool_children_receive_no_apple_or_other_credential_environment(self):
        environment = dict(self.environment, APPLE_ID=CANARY, APPLE_APP_SPECIFIC_PASSWORD=CANARY, GH_TOKEN=CANARY)
        with patch.dict(os.environ, environment), patch.object(M.subprocess, "run", return_value=result()) as run:
            M.Commands().run(["/usr/bin/openssl"], data=b"synthetic")
        self.assertTrue(set(run.call_args.kwargs["env"]) <= {"PATH", "HOME", "TMPDIR"})
        self.assertTrue(run.call_args.kwargs["capture_output"])

    def test_workflow_limits_secrets_and_native_probe_never_evaluates_trust_or_exports(self):
        workflow = (ROOT / ".github/workflows/apple-certificate-diagnostic.yml").read_text()
        before, secret_step = workflow.split("- name: Diagnose temporary local certificate", 1)
        self.assertNotIn("secrets.APPLE", before)
        self.assertEqual(secret_step.count("secrets.APPLE"), 3)
        for name in M.NAMES: self.assertIn("${{ secrets." + name + " }}", secret_step)
        for forbidden in ("secrets.APPLE_ID", "secrets.APPLE_APP_SPECIFIC_PASSWORD", "upload-artifact", "curl ", "wget ", "brew ", "pip install", "actions: write", "workflow_dispatch:"):
            self.assertNotIn(forbidden, workflow)
        for guard in ("github.repository == 'fus-cherry/DeviceBridge'", "github.actor == 'fus-cherry'",
                      "github.ref == 'refs/heads/cloud/0.1.8-apple-certificate-diagnostic'", "github.event_name == 'push'", "github.run_attempt == 1", "persist-credentials: false"):
            self.assertIn(guard, workflow)
        swift = (ROOT / "scripts/apple-local-identity-probe.swift").read_text()
        for allowed in ("SecItemCopyMatching", "SecIdentityCopyPrivateKey", "SecIdentityCopyCertificate", "kSecMatchSearchList", "kSecUseAuthenticationUIFail"):
            self.assertIn(allowed, swift)
        for forbidden in ("SecTrust", "SecKeyCopyExternalRepresentation", "SecKeyCreateSignature", "URLSession", "print(summary", "print(args"):
            self.assertNotIn(forbidden, swift)

if __name__ == "__main__":
    unittest.main()
