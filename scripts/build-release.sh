#!/bin/bash
# Build the same ad-hoc signed internal distribution locally and on GitHub.
set -euo pipefail
release_version=${1:-}
release_build=${2:-}
if [[ ! "$release_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || [[ ! "$release_build" =~ ^[1-9][0-9]*$ ]]; then
    echo "Usage: $0 MAJOR.MINOR.PATCH POSITIVE_BUILD_NUMBER" >&2
    exit 2
fi
release_root=$(cd "$(dirname "$0")/.." && pwd -P)
cd "$release_root"
: "${DEVICE_BRIDGE_ANDROID_HELPER_APK:?Set the signed Android APK path}"
: "${DEVICE_BRIDGE_ANDROID_HELPER_METADATA:?Set Android output-metadata.json path}"
: "${ANDROID_HOME:?Set Android SDK path}"
release_apksigner="$ANDROID_HOME/build-tools/35.0.0/apksigner"
"$release_apksigner" verify --verbose "$DEVICE_BRIDGE_ANDROID_HELPER_APK"
release_output="$release_root/dist/ci/$release_version-build$release_build"
# Never mix artifacts from separate attempts or overwrite an existing package.
if [[ -e "$release_output" ]]; then
    echo "Release output already exists: $release_output (choose a new build number)" >&2
    exit 1
fi
mkdir -p "$release_output" "$release_root/.build"
release_work=$(mktemp -d "$release_root/.build/release-$release_version-$release_build.XXXXXX")
release_app="$release_work/derived/Build/Products/Release/DeviceBridge.app"
release_agent_build="$release_work/agent-build"
xcodebuild build -project apps/macos/DeviceBridge.xcodeproj \
    -scheme DeviceBridge -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath "$release_work/derived" \
    -onlyUsePackageVersionsFromResolvedFile \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- \
    DEVELOPMENT_TEAM= CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    MARKETING_VERSION="$release_version" CURRENT_PROJECT_VERSION="$release_build"
swift build --package-path packages/DeviceBridgeCore \
    --scratch-path "$release_agent_build" --configuration release \
    --triple arm64-apple-macosx14.0 --only-use-versions-from-resolved-file \
    --product devicebridge-agent
release_agent_bin=$(swift build --package-path packages/DeviceBridgeCore \
    --scratch-path "$release_agent_build" --configuration release \
    --triple arm64-apple-macosx14.0 --show-bin-path)
release_agent="$release_agent_bin/devicebridge-agent"
if [[ ! -f "$release_agent" || ! -x "$release_agent" ]]; then
    echo "Release devicebridge-agent was not produced: $release_agent" >&2
    exit 1
fi
install -m 0755 "$release_agent" "$release_app/Contents/MacOS/devicebridge-agent"
codesign --force --sign - "$release_app/Contents/MacOS/devicebridge-agent"
codesign --force --sign - --preserve-metadata=entitlements,requirements,flags,runtime "$release_app"
python3 scripts/verify-release.py "$release_app" "$release_version" "$release_build" > "$release_output/build-info.json"
codesign --verify --deep --strict --verbose=2 "$release_app"
[[ "$(lipo -archs "$release_app/Contents/MacOS/DeviceBridge")" == arm64 ]]
release_stage="$release_work/stage"
mkdir "$release_stage"
ditto "$release_app" "$release_stage/DeviceBridge.app"
ln -s /Applications "$release_stage/Applications"
cat > "$release_stage/安装说明.txt" <<'TXT'
DeviceBridge 内部测试版 · Apple Silicon · macOS 14+

退出旧版本后，将 DeviceBridge.app 拖到 Applications，再从应用程序打开。
此包使用 ad-hoc 签名，未经 Apple 公证。首次打开如被拦截，请在系统设置 → 隐私与安全性中选择“仍要打开”。
Android 需要 ADB；iOS 辅助功能需要支持 Swift 6.2 的 Xcode、开发者模式和本机签名团队。
首次准备 iOS 通道需要编译；后续相同设备与配置可复用构建缓存。
Android helper 使用固定 CI 签名；从其他签名版本迁移时，可能需要手动卸载旧 helper 一次。
TXT
codesign --verify --deep --strict --verbose=2 "$release_stage/DeviceBridge.app"
release_name="DeviceBridge-$release_version-build$release_build-macOS-arm64.dmg"
hdiutil create -volname "DeviceBridge $release_version" -srcfolder "$release_stage" \
    -format UDZO -ov "$release_output/$release_name"
hdiutil verify "$release_output/$release_name"
python3 - "$release_output" "$release_version" "$release_build" <<'PY'
import json, pathlib, subprocess, sys
output, version, build = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
info = json.loads((output / 'build-info.json').read_text())
info.update(commit=subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
            macos_signing='ad-hoc', apple_notarized=False, architecture='arm64',
            xcode=subprocess.check_output(['xcodebuild', '-version'], text=True).strip())
(output / 'build-info.json').write_text(json.dumps(info, indent=2) + '\n')
(output / 'release-notes.md').write_text(
    f'# DeviceBridge {version} · Build {build}\n\n'
    'macOS 14+ / Apple Silicon 内部测试包。下载 DMG，将 App 拖到 Applications。\n\n'
    '**macOS 使用 ad-hoc 签名，未经 Apple 公证。** 首次打开若被系统拦截，请在“系统设置 → 隐私与安全性”中允许打开。\n\n'
    '包含固定 CI 签名的 Android helper 与在使用者 Mac 上构建、签名的 iOS runner 源码。'
    'iOS 需要支持 Swift 6.2 的 Xcode、本机签名团队和设备开发者模式。'
    '从其他 Android helper 签名切换时，可能需要手动卸载旧 helper 一次。\n\n'
    f'源码提交：`{info["commit"]}`。校验和见 `SHA256SUMS.txt`，构建信息见 `build-info.json`。\n'
    '自动测试与包校验不替代真机全功能验收。\n')
PY
(cd "$release_output" && shasum -a 256 "$release_name" build-info.json release-notes.md > SHA256SUMS.txt)
echo "Release artifacts: $release_output"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "directory=$release_output" >> "$GITHUB_OUTPUT"
fi
