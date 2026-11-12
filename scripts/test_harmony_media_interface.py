#!/usr/bin/env python3
"""Source wiring checks only; not a macOS build or device/UI runtime test."""
import json
from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / 'apps/macos/DeviceBridgeApp'
VM = (APP / 'ViewModels/PhoneImagesViewModel.swift').read_text()
VIEW = (APP / 'Views/PhoneImagesView.swift').read_text()
WORKSPACE = (APP / 'ViewModels/WorkspaceViewModel.swift').read_text()
MODELS = (ROOT / 'packages/DeviceBridgeCore/Sources/DeviceBridgeCore/Models/PhoneImages.swift').read_text()
ZH = json.loads((ROOT / 'packages/DeviceBridgeCore/Sources/DeviceBridgeCore/Localization/zh-Hans.json').read_text())

class HarmonyMediaInterfaceChecks(unittest.TestCase):
    def test_connection_only_constructs_provider(self):
        preparation = WORKSPACE.split('private func prepareFileTransfer')[1].split('func harmonyDestinationPath')[0]
        self.assertIn('provider: HarmonyMediaProvider(hdcURL: hdcURL, runner: runner)', preparation)
        self.assertIn('sources: [.harmonyMediaLibrary]', preparation)
        self.assertNotIn('.load(', preparation)
        self.assertNotIn('.preview(', preparation)

    def test_no_automatic_harmony_thumbnails(self):
        self.assertIn('thumbnailsEnabled = !isHarmonyMedia', VM)
        self.assertIn('guard !stopped, !isHarmonyMedia, thumbnailsEnabled', VM)
        self.assertIn('case .iosUSBCameraImport, .harmonyMediaLibrary: nil', MODELS)
        self.assertIn('source == .iosUSBCameraImport || source == .harmonyMediaLibrary', MODELS)

    def test_core_thumbnail_refuses_device_side_export(self):
        service = (ROOT / 'packages/DeviceBridgeCore/Sources/DeviceBridgeCore/Operations/ImageLibraryService.swift').read_text()
        thumbnail = service.split('public func thumbnail(itemID: UUID)')[1].split('public func preview')[0]
        self.assertIn('guard catalog?.source != .harmonyMediaLibrary', thumbnail)
        self.assertIn('throw PhoneImageError.unsupported', thumbnail)
        self.assertLess(thumbnail.index('guard catalog?.source'), thumbnail.index('readImage('))

    def test_provider_failures_are_localized_and_old_absolute_claim_removed(self):
        import re
        provider = (ROOT / 'packages/DeviceBridgeCore/Sources/DeviceBridgeCore/Operations/HarmonyMediaProvider.swift').read_text()
        for key in re.findall(r'safeMessage: "([^"\n]+)"', provider):
            self.assertIn(key, ZH)
        file_provider = (ROOT / 'packages/DeviceBridgeCore/Sources/DeviceBridgeCore/Operations/HarmonyFileProvider.swift').read_text()
        old = 'Private app data and the system photo library require app-level authorization.'
        self.assertNotIn(old, file_provider)
        self.assertFalse(any(old in key for key in ZH))

    def test_selection_download_and_reset_remain_guarded(self):
        self.assertIn('await previous?.value', VM)
        self.assertIn('revision == expectedRevision', VM)
        self.assertIn('itemIDs == selectedDownloadIDs', VM)
        self.assertIn('selectedDownloadIDs.removeAll()', VM)
        self.assertIn('case let failure as OperationFailure: failure.safeMessage', VM)

    def test_discloses_temporary_copy_and_cloud_limits(self):
        self.assertIn('disconnection may leave temporary copies', VIEW)
        self.assertIn('using network data and device storage', VIEW)
        self.assertIn('cloud-only media is not guaranteed to work', VIEW)
        self.assertIn('SHA-256 verifies the exported temporary copy', VIEW)
        self.assertIn('Download export copy…', ZH)
        self.assertIn('Device export copy saved · SHA-256 verified', ZH)
        self.assertNotIn('HDC file access does not grant media-library access.',
                         (APP / 'Views/FileTransferView.swift').read_text())

if __name__ == '__main__':
    unittest.main()
