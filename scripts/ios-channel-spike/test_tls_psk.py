"""Actual local system-TLS handshake, not cryptographic mocks or phone actions."""
import os
import subprocess
import unittest


@unittest.skipUnless(os.environ.get('DEVICEBRIDGE_TLS_PROBE'), 'Opt-in rejected TLS-PSK feasibility diagnostic')
class TLSPSKTests(unittest.TestCase):
    def test_matching_in_memory_keys_complete_tls13_before_identity(self):
        result = subprocess.run([os.environ['DEVICEBRIDGE_TLS_PROBE']], capture_output=True,
                                text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('TLS13_IDENTITY_EXCHANGE', result.stdout)

    def test_wrong_key_cannot_complete_identity_exchange(self):
        result = subprocess.run([os.environ['DEVICEBRIDGE_TLS_PROBE'], '--wrong-key'],
                                capture_output=True, text=True, timeout=15)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('TLS13_IDENTITY_EXCHANGE', result.stdout)


if __name__ == '__main__':
    unittest.main()
