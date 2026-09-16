import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import sys

sys.dont_write_bytecode = True


class CompileCoreCheckTests(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location(
            "compile_core_check", Path(__file__).with_name("compile-core-check.py")
        )
        self.helper = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.helper)
        self.temporary = tempfile.TemporaryDirectory(prefix="core check metadata ")
        self.addCleanup(self.temporary.cleanup)
        self.build = Path(self.temporary.name)

    def metadata(self, commands):
        (self.build / "description.json").write_text(json.dumps({"swiftCommands": commands}))
        (self.build / "libDeviceBridgeCoreChecks.a").touch()

    def test_swiftpm_archive_and_exact_clang_arguments_reach_compiler(self):
        imports = str(self.build / "Modules")
        clang = [
            "-Xcc", "-fmodule-map-file=/dependency with spaces/module.modulemap",
            "-Xcc", "-I", "-Xcc", "/dependency with spaces/include",
            "-Xcc", "-isysroot", "-Xcc", "/SDK with spaces",
        ]
        self.metadata({
            "unrelated": {"moduleName": "Other", "importPath": "/wrong", "otherArguments": []},
            "core": {"moduleName": "DeviceBridgeCore", "importPath": imports,
                     "otherArguments": ["-target", "arm64-apple-macosx14.0", *clang, "-DDEBUG"]},
        })
        source_arguments = ["/source with spaces/Check.swift", "-o", "/output with spaces/Check"]
        self.assertEqual(
            self.helper.compiler_command(self.build, source_arguments),
            ["swiftc", "-parse-as-library", "-swift-version", "6", "-I", imports,
             *clang, str(self.build / "libDeviceBridgeCoreChecks.a"), *source_arguments],
        )

    def test_missing_or_ambiguous_core_metadata_is_rejected(self):
        self.metadata({})
        with self.assertRaisesRegex(ValueError, "one DeviceBridgeCore"):
            self.helper.compiler_command(self.build, ["Check.swift"])
        entry = {"moduleName": "DeviceBridgeCore", "importPath": "/Modules", "otherArguments": []}
        (self.build / "description.json").write_text(json.dumps({"swiftCommands": {"a": entry, "b": entry}}))
        with self.assertRaisesRegex(ValueError, "one DeviceBridgeCore"):
            self.helper.compiler_command(self.build, ["Check.swift"])

    def test_incomplete_clang_pair_is_rejected(self):
        self.metadata({"core": {"moduleName": "DeviceBridgeCore", "importPath": "/Modules",
                               "otherArguments": ["-Xcc"]}})
        with self.assertRaisesRegex(ValueError, "-Xcc"):
            self.helper.compiler_command(self.build, ["Check.swift"])

    def test_missing_static_archive_is_rejected(self):
        self.metadata({"core": {"moduleName": "DeviceBridgeCore", "importPath": "/Modules",
                               "otherArguments": []}})
        (self.build / "libDeviceBridgeCoreChecks.a").unlink()
        with self.assertRaisesRegex(ValueError, "DeviceBridgeCoreChecks"):
            self.helper.compiler_command(self.build, ["Check.swift"])

    def test_swiftpm_products_directory_uses_product_modules_without_stale_metadata(self):
        products = self.build / "out" / "Products" / "Debug"
        metadata = self.build / "arm64-apple-macosx" / "debug"
        products.mkdir(parents=True)
        metadata.mkdir(parents=True)
        (products / "DeviceBridgeCore.swiftmodule").mkdir()
        (metadata / "description.json").write_text(json.dumps({"swiftCommands": {
            "core": {"moduleName": "DeviceBridgeCore", "importPath": "/stale/modules",
                     "otherArguments": ["-sdk", "/stale/sdk"]},
        }}))
        (products / "libDeviceBridgeCoreChecks.a").touch()

        self.assertEqual(
            self.helper.compiler_command(products, ["Check.swift"]),
            ["swiftc", "-parse-as-library", "-swift-version", "6", "-I", str(products),
             str(products / "libDeviceBridgeCoreChecks.a"), "Check.swift"],
        )


if __name__ == "__main__":
    unittest.main()
