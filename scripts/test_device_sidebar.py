"""Source wiring guards only, not a SwiftUI build or visual test."""
from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[1]
VIEW = (ROOT / 'apps/macos/DeviceBridgeApp/Views/WorkspaceView.swift').read_text()

class DeviceSidebarChecks(unittest.TestCase):
    def test_partition_retains_both_groups(self):
        self.assertIn('filter { connectionPresentation($0).canAttemptConnection }', VIEW)
        self.assertIn('filter { !connectionPresentation($0).canAttemptConnection }', VIEW)
        self.assertIn('ForEach(unavailable) { device in deviceRow(device) }', VIEW)
    def test_failures_are_visible_and_retry_is_unchanged(self):
        self.assertIn('failure = problem.safeMessage', VIEW)
        self.assertIn('showsUnavailableDevices = true', VIEW)
        self.assertIn('.onChange(of: model.connectionHealth)', VIEW)
        self.assertIn('Button { model.select(device.identity) }', VIEW)
    def test_active_status_and_guides_are_wired(self):
        self.assertIn('device.identity == model.selectedDeviceIdentity ? healthLabel', VIEW)
        self.assertIn('DevicePlatformGuide(platform: platform)', VIEW)
        self.assertIn('model.capabilitySummary(for: selectedModule).detail', VIEW)
        self.assertNotIn('language.text(status)', VIEW)

if __name__ == '__main__': unittest.main()
