"""Source wiring guards only. Behavioral coverage lives in Swift and macOS UI tests."""
from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[1]
VIEW = (ROOT / 'apps/macos/DeviceBridgeApp/Views/WorkspaceView.swift').read_text()

class DeviceSidebarChecks(unittest.TestCase):
    def test_partition_retains_both_groups(self):
        self.assertIn('filter { connectionPresentation($0).canAttemptConnection }', VIEW)
        self.assertIn('filter { !connectionPresentation($0).canAttemptConnection }', VIEW)
        self.assertIn('ForEach(attention) { device in deviceRow(device) }', VIEW)
        self.assertIn('Detected devices', VIEW)
    def test_whole_header_is_button_not_chevron_only(self):
        self.assertIn('Button { isExpanded.toggle() }', VIEW)
        self.assertIn('.contentShape(Rectangle())', VIEW)
        self.assertIn('identifier)-toggle', VIEW)
        self.assertIn('FullRowDisclosureStyle', VIEW)
    def test_fixed_columns_and_readable_names(self):
        self.assertIn('HStack(alignment: .top, spacing: 10)', VIEW)
        self.assertIn('.frame(width: 32, height: 36', VIEW)
        self.assertIn('.frame(width: 16, height: 20)', VIEW)
        self.assertIn('truncationMode(.middle)', VIEW)
    def test_active_status_and_guides_are_wired(self):
        self.assertIn('DevicePlatformGuide(platform: platform)', VIEW)
        self.assertIn('model.capabilitySummary(for: selectedModule).detail', VIEW)
        self.assertIn('device-auto-refresh-status', VIEW)
        self.assertIn('.onChange(of: model.connectionHealth)', VIEW)
        self.assertNotIn('language.text(status)', VIEW)

if __name__ == '__main__': unittest.main()
