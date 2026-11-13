"""Source contracts only; production channel and real workspace have separate runtime tests."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class HarmonyClipboardInterfaceTests(unittest.TestCase):
    def test_real_channel_is_prepared_only_inside_an_explicit_action(self):
        vm = (ROOT / 'apps/macos/DeviceBridgeApp/ViewModels/WorkspaceViewModel.swift').read_text()
        explicit = vm.split('private func clipboardServiceForExplicitAction(')[1].split('private func screenshotServiceForExplicitAction(')[0]
        self.assertIn('HarmonyClipboardChannel(hdcURL:', explicit)
        self.assertIn('channel.probeCapabilities()', explicit)
        self.assertIn('capabilities.canRead && capabilities.canWrite', explicit)
        self.assertIn('await store.snapshot().session == session', explicit)
        self.assertEqual(vm.count('HarmonyClipboardChannel(hdcURL:'), 1)
        self.assertNotIn('HarmonyOS clipboard access is not supported in this version.', vm)
        self.assertIn('only after an explicit read or write', vm)

    def test_uncertain_write_errors_are_not_lost_and_ui_uses_platform_limit(self):
        service = (ROOT / 'packages/DeviceBridgeCore/Sources/DeviceBridgeCore/Operations/ClipboardService.swift').read_text()
        self.assertEqual(service.count('catch let failure as HarmonyClipboardChannel.Failure'), 2)
        self.assertEqual(service.count('return .failure(failure.operationFailure)'), 2)
        view = (ROOT / 'apps/macos/DeviceBridgeApp/Views/ClipboardView.swift').read_text()
        self.assertIn('byteCount > model.clipboardMaximumWriteUTF8Bytes', view)
        self.assertIn('HarmonyOS write limit 2 KiB', view)
        self.assertIn('Writing replaces its current text.', view)

    def test_real_vm_harness_and_native_dialog_tests_are_wired_in_ci(self):
        script = (ROOT / 'scripts/check-workspace-inventory.sh').read_text()
        self.assertIn('apps/macos/DeviceBridgeAppTests/HarmonyClipboardWorkspaceChecks.swift', script)
        self.assertIn('"$bridge_bin/HarmonyClipboardWorkspaceChecks"', script)
        workflow = (ROOT / '.github/workflows/release.yml').read_text()
        self.assertIn('-only-testing:DeviceBridgeAppUITests/FileTransferDialogUITests', workflow)
        self.assertIn('Require native UI success before packaging', workflow)
        self.assertNotIn('continue-on-error: true', workflow)


if __name__ == '__main__':
    unittest.main()
