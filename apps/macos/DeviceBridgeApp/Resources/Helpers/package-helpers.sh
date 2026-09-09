#!/bin/sh

set -eu

if [ -z "${TARGET_BUILD_DIR:-}" ] || [ -z "${UNLOCALIZED_RESOURCES_FOLDER_PATH:-}" ] || [ -z "${SRCROOT:-}" ]; then
    echo "error: helper packaging requires the Xcode build environment" >&2
    exit 1
fi

source_root=$(cd "${SRCROOT}/../.." && pwd -P)
/bin/mkdir -p "${TARGET_BUILD_DIR}"
build_root=$(cd "${TARGET_BUILD_DIR}" && pwd -P)
case "${UNLOCALIZED_RESOURCES_FOLDER_PATH}" in
    /*|.|./*|*/./*|*/.|..|../*|*/../*|*/..|*//*|*/)
        echo "error: helper resources require a normalized path inside TARGET_BUILD_DIR" >&2
        exit 1
        ;;
esac
resource_root="${build_root}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
destination="${resource_root}/Helpers"
case "${destination}/" in
    "${source_root}/helpers/"*|"${source_root}/packages/"*)
        echo "error: helper output overlaps source inputs" >&2
        exit 1
        ;;
esac
case "${source_root}/" in
    "${destination}/"*)
        echo "error: helper output contains the source tree" >&2
        exit 1
        ;;
esac
# rsync owns only this generated subtree. Reject symlinked output ancestors
# before any bundle writes so incremental cleanup cannot reach another tree.
output_ancestor="${destination}/ios-runner"
while [ "${output_ancestor}" != "${build_root}" ]; do
    if [ -L "${output_ancestor}" ]; then
        echo "error: helper output must not traverse a symbolic link" >&2
        exit 1
    fi
    output_ancestor=$(/usr/bin/dirname "${output_ancestor}")
done

manifest_source="${SRCROOT}/DeviceBridgeApp/Resources/Helpers/manifest.json"
android_output="${SRCROOT}/../../helpers/android/app/build/outputs/apk/debug"
android_apk="${DEVICE_BRIDGE_ANDROID_HELPER_APK:-${android_output}/app-debug.apk}"
android_metadata="${DEVICE_BRIDGE_ANDROID_HELPER_METADATA:-$(/usr/bin/dirname "${android_apk}")/output-metadata.json}"
ios_runner="${source_root}/helpers/ios"

for required in "${manifest_source}" "${android_apk}" "${android_metadata}" \
    "${ios_runner}/DeviceBridgeRunner.xcodeproj/project.pbxproj" \
    "${source_root}/packages/DeviceBridgeSecureChannel/Package.swift" \
    "${source_root}/packages/DeviceBridgeProtocol/Package.swift"; do
    if [ ! -e "${required}" ]; then
        echo "error: missing managed helper input: ${required}" >&2
        echo "error: build the Android helper with assembleDebug before building DeviceBridge" >&2
        exit 1
    fi
done

expected_android_version=$(/usr/bin/plutil -extract android.versionCode raw "${manifest_source}")
built_android_version=$(/usr/bin/plutil -extract elements.0.versionCode raw "${android_metadata}")
if [ "${built_android_version}" != "${expected_android_version}" ]; then
    echo "error: Android helper version ${built_android_version} does not match manifest version ${expected_android_version}" >&2
    exit 1
fi

/bin/mkdir -p "${destination}"
/bin/cp "${android_apk}" "${destination}/android-helper.apk"
# Preserve the project's ../../packages references and the packages' sibling
# references inside one relocatable source tree. Only declared source inputs
# are included; incremental builds also remove old generated/cached artifacts.
/usr/bin/rsync -a --delete --delete-excluded --prune-empty-dirs --safe-links \
    --exclude='.build/' --exclude='DerivedData/' --exclude='build/' \
    --exclude='xcuserdata/' --exclude='.swiftpm/' --exclude='.git/' \
    --exclude='.DS_Store' --exclude='*.p12' --exclude='*.pfx' \
    --exclude='*.mobileprovision' --exclude='*.provisionprofile' \
    --exclude='*.key' --exclude='*.pem' --exclude='*.cer' --exclude='*.crt' --exclude='*.cert' \
    --exclude='*.app' --exclude='*.ipa' --exclude='*.xcarchive' \
    --exclude='*.xcresult' --exclude='*.xctestrun' \
    --include='/helpers/' --include='/helpers/ios/' \
    --include='/helpers/ios/DeviceBridgeHost/***' \
    --include='/helpers/ios/DeviceBridgeRunnerUITests/***' \
    --include='/helpers/ios/DeviceBridgeRunner.xcodeproj/***' \
    --include='/packages/' \
    --include='/packages/DeviceBridgeSecureChannel/' \
    --include='/packages/DeviceBridgeProtocol/' \
    --include='/packages/*/Package.swift' --include='/packages/*/Package.resolved' \
    --include='/packages/*/Sources/***' --include='/packages/*/Tests/***' \
    --exclude='*' "${source_root}/" "${destination}/ios-runner/"
/bin/cp "${manifest_source}" "${destination}/manifest.json"

android_sha=$(/usr/bin/shasum -a 256 "${destination}/android-helper.apk" | /usr/bin/awk '{print $1}')
/usr/bin/plutil -replace android.sha256 -string "${android_sha}" "${destination}/manifest.json"

echo "Packaged managed helpers: Android v${built_android_version}, iOS protocol v1"
