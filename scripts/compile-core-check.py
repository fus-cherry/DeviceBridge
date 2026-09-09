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


def compiler_command(build: Path, source_arguments: list[str]) -> list[str]:
    description = json.loads((build / "description.json").read_text())
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
    archive = build / "libDeviceBridgeCoreChecks.a"
    if not archive.is_file():
        raise ValueError("Build the DeviceBridgeCoreChecks static product before compiling a check")
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
