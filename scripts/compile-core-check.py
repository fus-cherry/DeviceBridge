#!/usr/bin/env python3
"""Compile a headless check against SwiftPM's complete Core static product.

Call after `swift build --product DeviceBridgeCoreChecks`. SwiftPM owns the
transitive archive; its Core compile metadata supplies dependency Clang imports.
This helper only compiles. Each caller retains control of its check/probe run.
"""

import json
from pathlib import Path
import subprocess
import sys


def description_path(build: Path) -> Path:
    direct = build / "description.json"
    if direct.is_file():
        return direct

    # SwiftPM 6.3 may return `.build/out/Products/<configuration>` from
    # `--show-bin-path` while retaining compile metadata in the target-triple
    # directory. Walk only the supplied build tree's ancestors and require a
    # unique sibling metadata file; never guess across another scratch tree.
    for root in build.parents:
        matches = sorted(root.glob("*/debug/description.json"))
        matches += sorted(root.glob("*/release/description.json"))
        if matches:
            if len(matches) != 1:
                raise ValueError("Expected exactly one SwiftPM description.json in the build tree")
            return matches[0]
        if root.name == ".build":
            break
    raise ValueError("SwiftPM description.json was not found in the build tree")


def compiler_command(build: Path, source_arguments: list[str]) -> list[str]:
    archive = build / "libDeviceBridgeCoreChecks.a"
    if not archive.is_file():
        raise ValueError("Build the DeviceBridgeCoreChecks static product before compiling a check")

    # Current SwiftPM/XCBuild places every transitive Swift module beside the
    # complete static product. Import that self-contained product directory
    # directly instead of consuming an old llbuild description with stale SDK
    # and module-map paths.
    if (build / "DeviceBridgeCore.swiftmodule").exists():
        return ["swiftc", "-parse-as-library", "-swift-version", "6", "-I", str(build),
                str(archive), *source_arguments]

    # Compatibility with older SwiftPM layouts where transitive Clang module
    # imports were available only through description.json.
    description = json.loads(description_path(build).read_text())
    matches = [command for command in description["swiftCommands"].values()
               if command.get("moduleName") == "DeviceBridgeCore"]
    if len(matches) != 1:
        raise ValueError("Expected exactly one DeviceBridgeCore compile command")
    core = matches[0]
    clang_arguments = []
    arguments = core["otherArguments"]
    for index, argument in enumerate(arguments):
        if argument == "-Xcc":
            if index + 1 == len(arguments):
                raise ValueError("Incomplete -Xcc pair in DeviceBridgeCore metadata")
            clang_arguments.extend(arguments[index:index + 2])
    return ["swiftc", "-parse-as-library", "-swift-version", "6", "-I", core["importPath"],
            *clang_arguments, str(archive), *source_arguments]


def main() -> int:
    if len(sys.argv) < 3:
        print("Usage: compile-core-check.py BUILD_DIRECTORY SOURCE... -o EXECUTABLE", file=sys.stderr)
        return 2
    try:
        command = compiler_command(Path(sys.argv[1]), sys.argv[2:])
        return subprocess.run(command, check=False).returncode
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"Cannot compile Core check: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
