# 开发与测试

[返回 README](../README.md) · [GitHub 自动构建与发布](releasing.md) · [完整验收指南](../specs/001-device-debug-bridge/quickstart.md)

以下命令均从仓库根目录执行。使用 Release 的团队成员无需编译 Android helper；这些步骤面向源码开发与维护者。

## 工具链与目录

- Apple Silicon Mac；应用部署目标为 macOS 14，实际编译主机还需满足所选 Xcode 的系统要求。
- 支持 Swift 6.2+ 的 Xcode，并选为当前开发工具目录。仓库 Swift packages 使用 `swift-tools-version: 6.2`；旧文档中的 Xcode 15.4 不能编译当前源码。
- JDK 17、Gradle 8.11.1、Android SDK Platform 35。仓库未附带 Gradle wrapper 二进制，需要可用的 `gradle` 命令。
- Android 真机检查需 ADB 37+；iOS 真机检查需对应版本的 Xcode、设备信任、开发者模式及现有本地签名配置。

| 路径 | 内容 |
| --- | --- |
| `apps/macos` | SwiftUI 桌面应用与 UI 测试 |
| `packages/DeviceBridgeCore` | 设备发现、会话、操作与连接维护 |
| `packages/DeviceBridgeProtocol` / `DeviceBridgeSecureChannel` | 共享协议与安全通道 |
| `helpers/android` | 由桌面应用管理的 Android helper |
| `helpers/ios` | 在使用者 Mac 上构建并签名的 iOS runner |
| `scripts` | 专项验证与打包工具 |
| `specs/001-device-debug-bridge` | 规格、计划、任务、契约和历史验证证据 |

检查工具版本，不自动更改系统配置：

```sh
swift --version
xcodebuild -version
xcrun devicectl --version
java -version
gradle --version
adb version
```

## 本地构建

先构建 Android APK，再构建 Mac 应用：

```sh
gradle -p helpers/android testDebugUnitTest assembleDebug

xcodebuild build -project apps/macos/DeviceBridge.xcodeproj \
  -scheme DeviceBridge -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/xcode-derived
```

产物位于 `.build/xcode-derived/Build/Products/Debug/DeviceBridge.app`。`Package Managed Helpers` 构建阶段会嵌入 APK、iOS runner 项目及其依赖源码，并生成带版本及 Android SHA-256 的 manifest，存入 `DeviceBridge.app/Contents/Resources/Helpers`。缺少 APK 或版本不匹配会终止打包。

iOS 开发签名使用当前 Mac 已有的身份和描述文件。不要把个人 Team ID 写入共享源码；不要未经授权启用 provisioning updates、注册设备或创建证书。应用设置中的 Team ID 不等于 Mac Developer ID 分发证书。

## 自动检查

核心测试不需要真实设备或桌面输入：

```sh
swift test --package-path packages/DeviceBridgeCore --no-parallel
```

当前共享主机的完整 Core 回归使用显式串行执行，避免多个时序夹具并发时的短截止时间竞争。具体历史结果见[启动反馈与复用验证](../specs/001-device-debug-bridge/validation/startup-feedback-and-reuse-20260909.md)。

Android 单元测试包含在上述 `testDebugUnitTest` 中。专项无界面检查与自愿启用的真机命令见 [Quickstart](../specs/001-device-debug-bridge/quickstart.md) 和[后台真机验证](../specs/001-device-debug-bridge/validation/physical-background.md)。普通测试跳过真实设备案例不构成该项验收通过。

### 桌面 UI 测试的授权边界

macOS XCTest 会生成真实输入，可能抢占焦点、键盘和鼠标。仅在真正隔离的画中画会话中，或用户明确同意前台测试时执行。普通预览窗口不构成输入隔离；用户正在工作时应优先运行后台核心检查。若当前任务限制为 Computer Use 操作，不得用 XCTest 替代。

以下命令只使用夹具设备，跳过单独命名的真实设备测试：

```sh
xcodebuild test -project apps/macos/DeviceBridge.xcodeproj \
  -scheme DeviceBridge -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/xcode-ui-derived \
  -only-testing:DeviceBridgeAppUITests \
  -skip-testing:DeviceBridgeAppUITests/DeviceWorkspaceUITests/testLiveInventoryCanSwitchBetweenTwoCommandReadyDevices
```

只有明确授权真实设备交互及 helper 准备时，才另行运行 live-device 测试。UI 测试保持正常本地签名，不要添加 `CODE_SIGNING_ALLOWED=NO`。

XCTest 可能请求开发者 UI 自动化权限。若在首个测试前停滞，检查实际系统提示及请求方；超时本身不能证明缺少某项权限。不要重置隐私设置或一次开启全部权限。`testmanagerd` 的输入法启用提示不是 DeviceBridge 剪切板授权，不应自动同意。

Codex Computer Use 的辅助功能权限属于代理桌面操作能力，不是团队成员运行 DeviceBridge 的前提。当前应用不要求 Mac 屏幕录制、全局辅助功能或完全磁盘访问；设备信任、调试/配对、helper 通知、相关文件/网络提示按实际操作分别处理。全新 Mac 的完整权限验收仍未完成。

## Android helper 的稳定签名

`assembleDebug` 使用开发者的 debug key。团队分发使用同一把受保护的稳定密钥，以便后续 APK 原位更新。GitHub CI 的配置见[发布文档](releasing.md)；不要提交 keystore 或密码。

手动分发时，在受保护的 shell 环境中设置全部四个变量：

```sh
export DEVICE_BRIDGE_HELPER_KEYSTORE='/secure/path/devicebridge-helper.jks'
export DEVICE_BRIDGE_HELPER_STORE_PASSWORD='stored-outside-the-repository'
export DEVICE_BRIDGE_HELPER_KEY_ALIAS='devicebridge-helper'
export DEVICE_BRIDGE_HELPER_KEY_PASSWORD='stored-outside-the-repository'

gradle -p helpers/android testDebugUnitTest assembleRelease

export DEVICE_BRIDGE_ANDROID_HELPER_APK="$PWD/helpers/android/app/build/outputs/apk/release/app-release.apk"
export DEVICE_BRIDGE_ANDROID_HELPER_METADATA="$PWD/helpers/android/app/build/outputs/apk/release/output-metadata.json"
```

示例密码为占位符，实际值应从密钥管理系统注入。使用 Android 签名工具可接受的 JKS。若设备已有另一把密钥签名的 `dev.debugutility.helper`，需要先确认可移除旧 helper，再卸载并安装团队版本。

## 手动 Developer ID 归档

本节是可选的正式分发流程；默认 GitHub 内部分发包采用 ad-hoc 签名，不运行此公证流程。

在本机安装 `Developer ID Application` 证书，并为目标设置自己的开发团队。Release 配置开启 Hardened Runtime，关闭 App Sandbox 以访问本地开发工具，不注入 `get-task-allow`，不申请 runtime exceptions。

先完成上节签名 APK 构建并保留导出变量。可以使用 Xcode 的 Product → Archive，在 Organizer 中选择 Distribute App → Developer ID / Direct Distribution，再上传公证；或使用：

```sh
xcodebuild archive -project apps/macos/DeviceBridge.xcodeproj \
  -scheme DeviceBridge -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$PWD/.build/archives/DeviceBridge.xcarchive" \
  DEVELOPMENT_TEAM='YOUR_TEAM_ID' CODE_SIGN_STYLE=Automatic

xcodebuild -exportArchive \
  -archivePath "$PWD/.build/archives/DeviceBridge.xcarchive" \
  -exportPath "$PWD/.build/export" \
  -exportOptionsPlist apps/macos/ExportOptions-DeveloperID.plist

codesign --verify --deep --strict --verbose=2 .build/export/DeviceBridge.app
codesign -d --entitlements :- .build/export/DeviceBridge.app
```

## 手动公证与分发

通过交互方式把公证凭据存入 Keychain；不要把 app-specific password 写入仓库或 shell 历史：

```sh
xcrun notarytool store-credentials 'DeviceBridge-notary' \
  --apple-id 'APPLE_ID' --team-id 'YOUR_TEAM_ID'

ditto -c -k --keepParent \
  .build/export/DeviceBridge.app .build/export/DeviceBridge-submit.zip

xcrun notarytool submit .build/export/DeviceBridge-submit.zip \
  --keychain-profile 'DeviceBridge-notary' --wait

xcrun stapler staple .build/export/DeviceBridge.app
xcrun stapler validate .build/export/DeviceBridge.app
spctl --assess --type execute --verbose=4 .build/export/DeviceBridge.app

ditto -c -k --keepParent \
  .build/export/DeviceBridge.app .build/export/DeviceBridge-notarized.zip
```

提交后检查公证状态与日志，确认接受后再 staple 和生成最终压缩包。ZIP 可以提交公证，但不能直接 staple，所以先为 app 附加票据，再创建分发 ZIP。签名、公证和真机功能验收是分别需要验证的结果。

官方参考：[macOS 软件公证](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)、[自定义公证流程](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)、[Hardened Runtime](https://developer.apple.com/documentation/xcode/configuring-the-hardened-runtime)、[Android 应用签名](https://developer.android.com/studio/publish/app-signing)。
