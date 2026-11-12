#!/usr/bin/env python3
"""Run isolated Swift 6.2 Linux regression checks; NOT a macOS app build.

Requires a trusted Swift 6.2 toolchain, Python 3, git, C/C++ toolchain and network
access to Apple's official swift-crypto/swift-asn1 repositories. No system edits.

Copies selected production sources/tests into a separate SwiftPM package. Only
these compatibility changes are made to COPIES: CryptoKit -> official Swift
Crypto 3.15.1; Darwin -> Glibc; autoreleasepool -> synchronous closure passthrough.
Discovery declarations and image request validity checks are extracted verbatim,
excluding the Darwin-only image export method and unrelated framework code. No device connection is made; providers use fakes and
shell fixtures. Excludes UI, ImageIO/ImageCaptureCore, SecureChannel and real
ADB/HDC/devicectl integration. Neither success nor failure proves a macOS build.
Default: focused file/media/HDC tests. --include-host-runner adds 12 unchanged runner tests;
three timing cases fail on Linux Foundation (delayed Process termination callbacks).
The diagnostic failures are not waived or weakened.

Example: python3 scripts/check-cloud-swift.py --swift /path/to/swift \
  --work-dir /tmp/devicebridge-cloud-check
"""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--swift', default=os.environ.get('SWIFT_BIN', 'swift'))
parser.add_argument('--work-dir', type=Path)
parser.add_argument('--jobs', default='2')
parser.add_argument('--include-host-runner', action='store_true', help='Include unchanged host-runner diagnostics; three deadline tests fail on Linux Foundation due to delayed Process termination callbacks.')
args = parser.parse_args()
repo = Path(__file__).resolve().parents[1]
core = repo / 'packages/DeviceBridgeCore'
work = args.work_dir.resolve() if args.work_dir else Path(tempfile.mkdtemp(prefix='devicebridge-cloud-'))
# A dedicated generated package only; never clean an existing arbitrary folder.
marker = work / '.devicebridge-cloud-check'
if work.exists() and any(work.iterdir()) and not marker.exists():
    raise SystemExit('Refusing nonempty work directory without harness marker; use a new directory.')
work.mkdir(parents=True, exist_ok=True)
marker.touch()
source = work / 'Sources/DeviceBridgeCore'
tests = work / 'Tests/DeviceBridgeCoreTests'
for directory in (source, tests):
    if directory.exists(): shutil.rmtree(directory)
    directory.mkdir(parents=True)
files = '''Models/DeviceModels Models/WorkspaceModule Models/DeviceConnectionPresentation Models/DeviceCapabilitySummary Models/PhoneImages Models/DeviceInformation
Models/AndroidShellExecution Models/AndroidShellHistory Session/DeviceSessionStore
Discovery/HDCDeviceParser Discovery/ADBDeviceParser Operations/DeviceFileBrowsing
Operations/AndroidFileProvider Operations/HarmonyFileProvider Operations/IOSFileProvider
Operations/HarmonyDeviceInformationProvider Operations/HarmonyPackageInstallService Operations/HarmonyMediaProvider Supervision/DeviceCommandProbe
Commands/ToolchainPreflight Operations/AndroidImageProvider Operations/FileTransferService
Commands/HostCommandRunner Localization/InterfaceLanguage'''.split()
def adapted(text):
    return text.replace('import CryptoKit', 'import Crypto').replace('import Darwin', 'import Glibc').replace('Darwin.', 'Glibc.')
for name in files:
    path = core / 'Sources/DeviceBridgeCore' / (name + '.swift')
    (source / path.name).write_text(adapted(path.read_text()))
f = (core / 'Sources/DeviceBridgeCore/Discovery/DeviceDiscoveryServices.swift').read_text()
(source / 'DiscoveryTypes.swift').write_text('import Foundation\n' + f[f.index('public enum DeviceDiscoveryError'):f.index('public struct AndroidDeviceDiscoveryService')])
f = (core / 'Sources/DeviceBridgeCore/Operations/ImageLibraryService.swift').read_text()
(source / 'ImageRequestValidity.swift').write_text('import Foundation\n' + f[f.index('final class ImageRequestValidity'):f.index('    func commit(staged:')] + '}\n')
(source / 'AutoreleasepoolShim.swift').write_text('func autoreleasepool<T>(invoking body: () throws -> T) rethrows -> T { try body() }\n')
shutil.copyfile(core / 'Sources/DeviceBridgeCore/Localization/zh-Hans.json', source / 'zh-Hans.json')
test_names = '''DeviceConnectionPresentation DeviceCapabilitySummary WorkspaceModule HarmonyRead DeviceFileBrowsing AndroidFileProvider IOSFileProvider
PhoneImageModels ToolchainPreflight AndroidImageProvider FileTransferService HarmonyPackageInstall HarmonyFileSend HarmonyTransferSession HarmonyMediaProvider'''.split()
if args.include_host_runner: test_names.append('HostCommandRunner')
for name in test_names:
    path = core / 'Tests/DeviceBridgeCoreTests' / (name + 'Tests.swift')
    (tests / path.name).write_text(adapted(path.read_text()))
(work / 'Package.swift').write_text('''// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "PortableChecks", dependencies: [
    .package(url: "https://github.com/apple/swift-crypto.git", exact: "3.15.1")
], targets: [
    .target(name: "DeviceBridgeCore", dependencies: [.product(name: "Crypto", package: "swift-crypto")], resources: [.process("zh-Hans.json")]),
    .testTarget(name: "DeviceBridgeCoreTests", dependencies: ["DeviceBridgeCore"])
])
''')
cache = work / 'cache'
cache.mkdir(exist_ok=True)
env = dict(os.environ, HOME=str(cache), XDG_CACHE_HOME=str(cache),
           CLANG_MODULE_CACHE_PATH=str(cache / 'clang'), SWIFTPM_MODULECACHE_OVERRIDE=str(cache / 'modules'))
print(f'Isolated portable checks in {work}; not a full macOS build.', flush=True)
subprocess.run([args.swift, '--version'], check=True, env=env)
subprocess.run([args.swift, 'test', '--no-parallel', '--package-path', str(work), '--cache-path', str(cache), '-j', args.jobs], check=True, env=env)
