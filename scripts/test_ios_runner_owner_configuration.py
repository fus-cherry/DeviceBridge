"""App-only owner signing must cover both helper paths without changing generic Core."""
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]


class IOSRunnerOwnerConfigurationTests(unittest.TestCase):
    def test_both_real_app_paths_use_the_shared_owner_factory_not_old_defaults(self):
        source = (ROOT / "apps/macos/DeviceBridgeApp/ViewModels/WorkspaceViewModel.swift").read_text()
        owner = source.split("enum IOSRunnerOwnerConfiguration {", 1)[1].split("\nenum CapabilityReadiness", 1)[0]
        self.assertIn('developmentTeamIdentifier = "5F6294RLX4"', owner)
        self.assertIn("signingTeamID: developmentTeamIdentifier", owner)
        for start, end, launcher in (
            ("private func prepareIOSRunner(", "private func prepareIOSClipboardHost(", "IOSRunnerLauncher"),
            ("private func prepareIOSClipboardHost(", "private func observeIOSClipboardPreparation(", "IOSClipboardHostLauncher"),
        ):
            path = source.split(start, 1)[1].split(end, 1)[0]
            self.assertIn("IOSRunnerOwnerConfiguration.manager(", path)
            self.assertIn("launcher: " + launcher + "(", path)
            self.assertNotIn("UserDefaults", path)
            self.assertNotIn("IOSRunnerManager(", path)
            self.assertNotIn("Team ID in Settings", path)
        self.assertNotIn('UserDefaults.standard.string(forKey: "iosSigningTeamID")', source)

    def test_core_remains_team_generic_and_native_harness_runs_owner_regression(self):
        core = ROOT / "packages/DeviceBridgeCore/Sources/DeviceBridgeCore/Helpers"
        for name in ("IOSRunnerManager.swift", "IOSRunnerSourceConfiguration.swift", "IOSRunnerBuildWorkspace.swift"):
            self.assertNotIn("5F6294RLX4", (core / name).read_text())
        script = (ROOT / "scripts/check-ios-runner-workspace.sh").read_text()
        self.assertIn("apps/macos/DeviceBridgeAppTests/IOSRunnerOwnerSigningChecks.swift", script)
        self.assertIn('"$bridge_bin/IOSRunnerOwnerSigningChecks"', script)


if __name__ == "__main__":
    unittest.main()
