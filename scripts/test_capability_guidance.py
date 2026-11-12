#!/usr/bin/env python3
"""Source wiring checks only; not macOS compilation, UI or device validation."""
from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[1]
VM = (ROOT / 'apps/macos/DeviceBridgeApp/ViewModels/WorkspaceViewModel.swift').read_text()
CORE = (ROOT / 'packages/DeviceBridgeCore/Sources/DeviceBridgeCore/Models/DeviceCapabilitySummary.swift').read_text()

class CapabilityGuidanceWiringTests(unittest.TestCase):
    def test_display_mapping_cannot_start_device_work(self):
        summary = VM.split('    func capabilitySummary(for module:')[1].split('    var clipboardAction:')[0]
        for invocation in ('.read(', '.load(', '.run(', '.install(', '.select(', 'Task {'):
            self.assertNotIn(invocation, summary)
        self.assertIn('connectionIssue: connectionActionBlock', summary)
        self.assertIn('authorization: device.authorization', summary)

    def test_missing_tool_has_observed_evidence(self):
        summary = VM.split('    func capabilitySummary(for module:')[1].split('    var clipboardAction:')[0]
        for tool in ('adbURL != nil', 'xcrunURL != nil', 'hdcURL != nil'):
            self.assertIn(tool, summary)
        self.assertNotIn('reason.contains(', summary)
        self.assertNotIn('safeMessage.contains(', summary)
        self.assertIn('case let .actionRequired(reason): return .init(state: .actionRequired, detail: reason)', summary)

    def test_files_do_not_claim_all_permissions_ready(self):
        summary = VM.split('        case .files:\n')[1].split('        return .resolve')[0]
        self.assertIn('.availableOnDemand', summary)
        self.assertIn('does not guarantee access', summary)

if __name__ == '__main__':
    unittest.main()
