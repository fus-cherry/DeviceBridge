#!/usr/bin/env python3
"""Source layout guards only, not SwiftUI compilation or visual acceptance."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
VIEWS = ROOT / 'apps/macos/DeviceBridgeApp/Views'
FILES = (VIEWS / 'FileTransferView.swift').read_text()
MEDIA = (VIEWS / 'PhoneImagesView.swift').read_text()

class HarmonyLayoutChecks(unittest.TestCase):
    def test_file_tasks_have_distinct_sections(self):
        body = FILES.split('private var transferBody: some View')[1].split('private var harmonyPackageControls')[0]
        self.assertLess(body.index('harmony-browse-section'), body.index('directoryBrowser'))
        self.assertLess(body.index('directoryBrowser'), body.index('harmony-transfer-section'))
        self.assertLess(body.index('harmony-transfer-section'), body.index('files-send'))
        self.assertLess(body.index('files-feedback'), body.index('harmonyPackageControls'))
        self.assertIn('harmony-install-section', FILES)

    def test_apk_warning_not_hidden_in_compatibility_help(self):
        install = FILES.split('private var harmonyPackageControls')[1].split('private func chooseHarmonyPackage')[0]
        self.assertLess(install.index('HDC installs HarmonyOS HAP packages'), install.index('DisclosureGroup'))
        self.assertIn('Sending an APK copies a file only; HDC cannot install it as a native HarmonyOS app.', FILES)
        self.assertIn('Alternative: open the app developer', install.split('DisclosureGroup')[1])

    def test_cloud_and_cleanup_warning_visible_before_disclosure(self):
        warning = MEDIA.split('DisclosureGroup(language.text("Media access details and limits"))')[0]
        self.assertIn('using network data and device storage', warning)
        self.assertIn('Disconnection may leave temporary copies', warning)
        self.assertIn('cloud-only media is not guaranteed to work', warning)
        self.assertIn('harmony-media-export-warning', warning)

    def test_limits_and_integrity_explanation_retained(self):
        for text in ['Images: up to 20 MiB; videos: up to 512 MiB.',
                     'Hidden media is unsupported.', 'Older devices without mediatool listing',
                     'SHA-256 verifies the exported temporary copy, not the system-library original.',
                     'System-library originals are never deleted or changed.']:
            self.assertIn(text, MEDIA)
        self.assertIn('Existing files are skipped.', MEDIA)

if __name__ == '__main__':
    unittest.main()
