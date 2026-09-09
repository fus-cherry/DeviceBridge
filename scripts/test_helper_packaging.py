"""Exercise the production helper bundler without building apps or using a device.

Regression: copying only helpers/ios leaves its local Swift packages unresolved.
The fixture retains real project/package sources and injects disposable build and
signing canaries to detect accidental inclusion, including on incremental runs.
"""

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
RESOURCES = Path("apps/macos/DeviceBridgeApp/Resources/Helpers")


class HelperPackagingTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="helper packaging ")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / "source"
        self.output = Path(self.temporary.name) / "output"
        self.resources = self.root / RESOURCES
        self.resources.mkdir(parents=True)
        for name in ("manifest.json", "package-helpers.sh"):
            shutil.copy2(ROOT / RESOURCES / name, self.resources / name)
        for relative in (
            "helpers/ios/DeviceBridgeHost",
            "helpers/ios/DeviceBridgeRunnerUITests",
            "helpers/ios/DeviceBridgeRunner.xcodeproj",
            "packages/DeviceBridgeSecureChannel",
            "packages/DeviceBridgeProtocol",
        ):
            shutil.copytree(
                ROOT / relative, self.root / relative,
                ignore=shutil.ignore_patterns(
                    ".build", "DerivedData", "build", "xcuserdata", ".swiftpm",
                    "*.p12", "*.pfx", "*.mobileprovision", "*.provisionprofile",
                    "*.key", "*.pem", "*.cer", "*.crt", "*.cert",
                ),
            )
        self.apk = self.root / "fixture.apk"
        self.apk.write_bytes(b"synthetic Android artifact for packaging only")
        version = json.loads((self.resources / "manifest.json").read_text())["android"]["versionCode"]
        self.metadata = self.root / "output-metadata.json"
        self.metadata.write_text(json.dumps({"elements": [{"versionCode": version}]}))
        self.bundled = self.output / "DeviceBridge.app/Contents/Resources/Helpers"

    def package(self, overrides=None, succeeds=True):
        result = subprocess.run(
            ["/bin/sh", str(self.resources / "package-helpers.sh")],
            env={**os.environ,
                 "SRCROOT": str(self.root / "apps/macos"),
                 "TARGET_BUILD_DIR": str(self.output),
                 "UNLOCALIZED_RESOURCES_FOLDER_PATH": "DeviceBridge.app/Contents/Resources",
                 "DEVICE_BRIDGE_ANDROID_HELPER_APK": str(self.apk),
                 "DEVICE_BRIDGE_ANDROID_HELPER_METADATA": str(self.metadata),
                 **(overrides or {})},
            capture_output=True, text=True, timeout=30,
        )
        if succeeds:
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, "unsafe destination must be rejected")

    def dump_package(self, path):
        # dump-package evaluates manifests only; it does not resolve/fetch remotes.
        result = subprocess.run(
            ["swift", "package", "--package-path", str(path), "dump-package"],
            capture_output=True, text=True, timeout=60,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def test_packaged_project_resolves_local_packages_after_source_is_moved(self):
        self.package()
        self.root.rename(self.root.with_name("unavailable original source"))
        manifest = json.loads((self.bundled / "manifest.json").read_text())
        self.assertEqual((self.bundled / manifest["android"]["artifact"]).read_bytes(),
                         b"synthetic Android artifact for packaging only")
        self.assertEqual(manifest["android"]["sha256"], hashlib.sha256(
            b"synthetic Android artifact for packaging only").hexdigest())
        runner = self.bundled / manifest["ios"]["directory"]
        project = runner / manifest["ios"]["project"]
        self.assertTrue((project / "project.pbxproj").is_file())
        parsed = subprocess.run(
            ["/usr/bin/plutil", "-convert", "json", "-o", "-", str(project / "project.pbxproj")],
            capture_output=True, text=True, check=True,
        )
        references = [item["relativePath"] for item in json.loads(parsed.stdout)["objects"].values()
                      if item.get("isa") == "XCLocalSwiftPackageReference"]
        self.assertTrue(references, "project must exercise its actual local package graph")
        pending = [(project.parent / relative).resolve() for relative in references]
        visited = set()
        while pending:
            package = pending.pop()
            self.assertTrue(package.is_relative_to(runner.resolve()),
                            "local package escapes the portable runner source tree")
            self.assertTrue((package / "Package.swift").is_file(),
                            f"missing packaged local dependency: {package.name}")
            if package in visited:
                continue
            visited.add(package)
            description = self.dump_package(package)
            for dependency in description["dependencies"]:
                for local in dependency.get("fileSystem", []):
                    pending.append(Path(local["path"]).resolve())
            for target in description["targets"]:
                directory = target.get("path") or (
                    ("Tests/" if target["type"] == "test" else "Sources/") + target["name"])
                self.assertTrue((package / directory).is_dir(),
                                f"packaged manifest target missing sources: {target['name']}")
        self.assertEqual({path.name for path in visited},
                         {"DeviceBridgeSecureChannel", "DeviceBridgeProtocol"})
        self.assertTrue((project / "xcshareddata/xcschemes/DeviceBridgeRunner.xcscheme").is_file())
        self.assertTrue((project / "project.xcworkspace/xcshareddata/swiftpm/Package.resolved").is_file())

    def test_packaging_rejects_a_destination_symlink_before_writing(self):
        protected = Path(self.temporary.name) / "unrelated"
        protected.mkdir()
        marker = protected / "keep.txt"
        marker.write_text("preserve")
        self.bundled.mkdir(parents=True)
        (self.bundled / "ios-runner").symlink_to(protected, target_is_directory=True)
        self.package(succeeds=False)
        self.assertEqual(list(protected.iterdir()), [marker])
        self.assertEqual(marker.read_text(), "preserve")

    def test_packaging_rejects_a_destination_within_source_inputs(self):
        self.package({"TARGET_BUILD_DIR": str(self.root),
                      "UNLOCALIZED_RESOURCES_FOLDER_PATH": "helpers/ios"}, succeeds=False)
        self.assertFalse((self.root / "helpers/ios/Helpers").exists())

    def test_packaging_rejects_source_overlap_hidden_by_dot_components(self):
        self.package({"TARGET_BUILD_DIR": str(self.root),
                      "UNLOCALIZED_RESOURCES_FOLDER_PATH": "./helpers/ios"}, succeeds=False)
        self.assertFalse((self.root / "helpers/ios/Helpers").exists())

    def test_packaging_excludes_build_user_and_signing_artifacts_on_repeat_runs(self):
        canaries = (
            ".build/debug/cache", "DerivedData/Build/output", "build/products",
            "xcuserdata/developer.xcuserdatad/UserInterfaceState.xcuserstate",
            ".swiftpm/configuration/local", "identity.p12", "identity.pfx",
            "identity.key", "identity.pem", "identity.cer", "identity.crt",
            "identity.cert", "embedded.mobileprovision", "local.provisionprofile",
            "Signed.app/executable", "Signed.ipa", "Archive.xcarchive/metadata",
            "result.xcresult/metadata", "run.xctestrun",
        )
        for base in ("helpers/ios", "helpers/ios/DeviceBridgeRunnerUITests",
                     "packages/DeviceBridgeSecureChannel/Sources",
                     "packages/DeviceBridgeProtocol/Tests"):
            for relative in canaries:
                path = self.root / base / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("disposable packaging canary")
        self.package()
        # Simulate a previously generated bundle containing artifacts/old layout.
        for relative in ("old-source.swift", "DerivedData/old-build", "identity.p12"):
            path = self.bundled / "ios-runner" / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("disposable stale bundle canary")
        self.package()
        for path in (self.bundled / "ios-runner").rglob("*"):
            if path.is_file():
                self.assertFalse(path.read_bytes().startswith(b"disposable"),
                                 f"excluded artifact survived packaging: {path.name}")


@unittest.skipUnless(os.environ.get("DEVICEBRIDGE_TEST_INCREMENTAL_SIGNING") == "1",
                     "opt in to local Debug signing builds with DEVICEBRIDGE_TEST_INCREMENTAL_SIGNING=1")
class IncrementalHelperSigningTests(unittest.TestCase):
    def test_changed_helper_resources_are_signed_on_consecutive_incremental_builds(self):
        # A missing script output dependency lets Xcode skip CodeSign after the
        # bundler changes resources. Exercise the real build graph and seal;
        # synthetic APKs stay in this isolated product directory, never installed.
        with tempfile.TemporaryDirectory(prefix="helper incremental signing ") as temporary:
            scratch = Path(temporary)
            products = scratch / "products"
            apk = scratch / "fixture.apk"
            metadata = scratch / "output-metadata.json"
            version = json.loads((ROOT / RESOURCES / "manifest.json").read_text())["android"]["versionCode"]
            metadata.write_text(json.dumps({"elements": [{"versionCode": version}]}))
            command = [
                "xcodebuild", "build", "-project", str(ROOT / "apps/macos/DeviceBridge.xcodeproj"),
                "-scheme", "DeviceBridge", "-configuration", "Debug",
                "-derivedDataPath", str(scratch / "derived"),
                "-clonedSourcePackagesDirPath", str(ROOT / ".build/xcode-derived/SourcePackages"),
                "-disableAutomaticPackageResolution", "-skipPackageUpdates",
                f"CONFIGURATION_BUILD_DIR={products}",
                f"DEVICE_BRIDGE_ANDROID_HELPER_APK={apk}",
                f"DEVICE_BRIDGE_ANDROID_HELPER_METADATA={metadata}",
            ]
            # Establish a signed baseline, then make two resource-only changes.
            for revision in (0, 1, 2):
                with self.subTest(revision=revision):
                    content = f"synthetic packaging-only revision {revision}".encode()
                    apk.write_bytes(content)
                    build = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, timeout=600)
                    self.assertEqual(build.returncode, 0, build.stdout[-8000:] + build.stderr[-2000:])
                    app = products / "DeviceBridge.app"
                    bundled = app / "Contents/Resources/Helpers"
                    self.assertEqual((bundled / "android-helper.apk").read_bytes(), content)
                    manifest = json.loads((bundled / "manifest.json").read_text())
                    self.assertEqual(manifest["android"]["sha256"], hashlib.sha256(content).hexdigest())
                    seal = subprocess.run(
                        ["/usr/bin/codesign", "--verify", "--strict", "--verbose=4", str(app)],
                        capture_output=True, text=True, timeout=30,
                    )
                    self.assertEqual(seal.returncode, 0, seal.stderr)
                    self.assertTrue(any(line.startswith("CodeSign ") and "/DeviceBridge.app " in line
                                        for line in build.stdout.splitlines()),
                                    "changed helper output must cause Xcode to run CodeSign")
                    print(f"revision {revision}: packaged bytes/hash, CodeSign and strict seal PASS", flush=True)


if __name__ == "__main__":
    unittest.main()
