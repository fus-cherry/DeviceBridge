"""Synthetic-only pure classifier tests. No credentials, tools, network or files."""
import contextlib
import importlib.util
import io
from pathlib import Path
import unittest

ROOT = Path(__file__).parent.parent
SPEC = importlib.util.spec_from_file_location("classifier", ROOT / "scripts/classify-apple-codesign-failure.py")
M = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(M)
CANARY = b"never-disclose-private-fixture-password-certificate-base64-canary"


class CodesignFailureClassifierTests(unittest.TestCase):
    def classify(self, stdout=b"", stderr=b""):
        capture = io.StringIO()
        with contextlib.redirect_stdout(capture), contextlib.redirect_stderr(capture):
            result = M.classify_failure(stdout, stderr)
        self.assertEqual(capture.getvalue(), "")
        self.assertIsInstance(result, tuple)
        self.assertTrue(set(result) <= M.ALLOWED)
        self.assertNotIn(CANARY.decode(), repr(result))
        return result

    def test_generic_internal_error_does_not_assert_password_or_acl_problem(self):
        self.assertEqual(self.classify(stderr=CANARY + b": errSecInternalComponent"),
                         ("security_framework_internal_component",))

    def test_chain_warning_plus_internal_error_preserves_both_observations(self):
        stderr = b'Warning: unable to build chain to self-signed root for signer "' + CANARY + b'"\nerrSecInternalComponent'
        self.assertEqual(self.classify(stderr=stderr), ("certificate_chain_building_warning", "security_framework_internal_component"))

    def test_each_whitelist_observation_without_raw_data(self):
        for name, patterns in M.OBSERVATIONS:
            for pattern in patterns:
                with self.subTest(name=name):
                    self.assertEqual(self.classify(stderr=CANARY + b" " + pattern.upper() + b" " + CANARY), (name,))

    def test_other_known_observations_can_coexist(self):
        self.assertEqual(self.classify(stderr=b"User interaction is not allowed. errSecItemNotFound"),
                         ("keychain_interaction_denied", "identity_or_key_not_found"))

    def test_timestamp_failure_does_not_remove_timestamp_requirement(self):
        self.assertEqual(self.classify(stderr=b"The timestamp service is not available. " + CANARY),
                         ("timestamp_service_unavailable",))
        source = (ROOT / "scripts/sign-apple-release.py").read_text()
        self.assertIn('"--options", "runtime", "--timestamp"', source)
        self.assertNotIn('"--timestamp=none"', source)

    def test_unknown_empty_binary_or_large_data_never_echoed(self):
        for raw in (b"", CANARY, b"\x00\xff" + CANARY, b"x" * (1024 * 1024 + 1)):
            self.assertEqual(self.classify(stderr=raw), ("unclassified_codesign_failure",))
        self.assertEqual(self.classify(stdout=None, stderr=None), ("unclassified_codesign_failure",))

    def test_function_is_not_a_tool_runner_or_file_writer(self):
        source = (ROOT / "scripts/classify-apple-codesign-failure.py").read_text()
        for forbidden in ("import subprocess", "import os", "import socket", "import urllib", "open(", "print(", "load_secrets(", "AppleSigner(", "sys.argv"):
            self.assertNotIn(forbidden, source)


if __name__ == "__main__":
    unittest.main()
