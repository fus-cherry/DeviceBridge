#!/usr/bin/env python3
"""Source-level UI wiring guards, NOT a macOS SwiftUI build or runtime UI test."""
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
VIEW = (ROOT / 'apps/macos/DeviceBridgeApp/Views/FileTransferView.swift').read_text()
MODEL = (ROOT / 'apps/macos/DeviceBridgeApp/ViewModels/WorkspaceViewModel.swift').read_text()
ZH = json.loads((ROOT / 'packages/DeviceBridgeCore/Sources/DeviceBridgeCore/Localization/zh-Hans.json').read_text())


class HarmonyPackageInterfaceSourceChecks(unittest.TestCase):
    def test_install_requires_confirmation_and_rechecks_selection(self):
        body = VIEW.split('private func chooseHarmonyPackage()')[1].split('private var directoryBrowser')[0]
        self.assertEqual(body.count('canUseHarmonyPackageSelection(revision: revision)'), 2)
        self.assertIn('url.pathExtension.lowercased() == "hap"', body)
        self.assertLess(body.index('dialogs.confirm(alert, for: window)'), body.index('model.installHarmonyPackage'))
        self.assertNotIn('runModal()', VIEW)
        lifecycle = VIEW.split('private final class FileTransferDialogs:')[1]
        self.assertIn('alert.beginSheetModal(for: window)', lifecycle)
        self.assertIn('guard response == .alertFirstButtonReturn, window.isVisible else { return }', lifecycle)
        self.assertIn('self.revision == request', lifecycle)
        self.assertIn('replaceExisting: true', body)
        self.assertIn('arguments: [url.lastPathComponent, deviceName]', body)

    def test_apk_send_is_copy_only(self):
        body = VIEW.split('private func chooseFileToSend()')[1].split('private func chooseReceiveDestination()')[0]
        self.assertIn('url.pathExtension.lowercased() == "apk"', body)
        self.assertIn('Copy APK only?', body)
        self.assertNotIn('installHarmonyPackage', body)
        self.assertEqual(body.count('canUseFileSelection(revision: revision)'), 2)

    def test_debug_scope_writable_documents_read_only(self):
        self.assertIn('scope = .harmonyUserDocuments', VIEW)
        line = next(line for line in VIEW.splitlines() if 'var isReadOnly:' in line)
        self.assertIn('.harmonyDocuments', line)
        self.assertNotIn('.harmonyDebugFiles', line)

    def test_cancel_drains_and_stale_outcomes_cannot_publish(self):
        body = MODEL.split('func cancelHarmonyPackageInstall()')[1].split('private func resetHarmonyPackageInstall()')[0]
        self.assertIn('harmonyPackageTask?.cancel()', body)
        self.assertNotIn('isInstallingHarmonyPackage = false', body)
        self.assertIn('self.harmonyPackageRevision == request', MODEL)
        self.assertIn('self.fileTransferRevision == request', MODEL)
        self.assertIn('busy: isTransferringFile || isInstallingHarmonyPackage', MODEL)
        self.assertEqual(MODEL.count('        resetHarmonyPackageInstall()'), 3)

    def test_cancelled_harmony_send_discloses_uncertain_commit(self):
        body = MODEL.split('    func sendFile(')[1].split('    func receiveFile(')[0]
        self.assertIn('let isHarmonySend = selectedDevice?.identity.platform == .harmonyOS', body)
        key = 'Transfer interrupted. The device may already contain the file; inspect it before retrying.'
        self.assertIn(key, body)
        self.assertIn(key, ZH)

    def test_public_documents_use_explicit_user_and_generated_destination(self):
        self.assertIn('@State private var identifier = ""', VIEW)
        self.assertNotIn('identifier = "100"', VIEW)
        self.assertIn('return [.harmonyUserDocuments, .harmonyDocuments, .harmonyDebugFiles]', VIEW)
        self.assertIn('scope == .harmonyUserDocuments || !relativePath.isEmpty', VIEW)
        self.assertIn('DeviceFileLocation.harmonyUserDocument(userID: selectedIdentifier, fileName: url.lastPathComponent)', VIEW)
        self.assertIn('Phone OS user ID (for example, 100)', ZH)

    def test_success_path_is_selectable_and_bound_to_artifact_device(self):
        self.assertIn('Text(path).font(.caption.monospaced()).textSelection(.enabled)', VIEW)
        self.assertIn('artifact.sourceDevice == selectedDevice?.identity', MODEL)
        self.assertIn('artifact.direction == .hostToDevice', MODEL)
        self.assertIn('/storage/media/\\(userID)/local/files/Docs/Documents/\\(location.relativePath)', MODEL)
        self.assertIn('Copy APK to user documents: {0}', VIEW)
        self.assertIn('Copy APK to debug folder: {0}', VIEW)
        for name, end in [('sendFile', 'receiveFile'), ('receiveFile', 'cancelFileTransfer'),
                          ('cancelFileTransfer', 'canInstallHarmonyPackage')]:
            body = MODEL.split('func ' + name + '(')[1].split(end)[0]
            self.assertIn('latestTransferArtifact = nil', body)
        self.assertIn('private func cancelDisconnectedContent() {\n        latestTransferArtifact = nil', MODEL)
        self.assertIn('private func applyFileTransferOutcome(_ outcome: FileTransferOutcome) {\n        latestTransferArtifact = nil', MODEL)

    def test_native_installer_is_not_faked(self):
        preparation = MODEL.split('private func prepareFileTransfer')[1].split('private func applyFileTransferOutcome')[0]
        self.assertIn('device.identity.platform == .harmonyOS, !arguments.contains("--fixture-devices")', preparation)
        self.assertIn('installer: HDCPackageInstaller', preparation)

    def test_critical_feedback_is_localized(self):
        for key in ('Install HAP…', 'Install or update HAP?', 'HAP installed',
                    'Copy APK only?', 'Cancelling installation…', 'Cancelling transfer…',
                    'HarmonyOS debug files',
                    'Installation cancelled. Check the device before retrying; installation may have completed.'):
            self.assertIn(key, ZH)
            self.assertNotEqual(key, ZH[key])


if __name__ == '__main__':
    unittest.main()
