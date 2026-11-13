# DeviceBridge

> **AI 生成声明：本项目由 AI 自主生成。**

面向 Flutter 开发者的原生 macOS 设备调试工具。在一个窗口中连接 Android 与 iPhone，处理剪切板、截图、图片、视频、文件和 Flutter 内存数据，并实验性接入鸿蒙 HDC 设备信息、剪贴板、文件与 HAP 安装；被调试的 Flutter 项目无需添加依赖或修改代码。

[下载 Release](https://github.com/fus-cherry/DeviceBridge/releases) · [开发与测试](docs/development.md) · [自动构建与发布](docs/releasing.md) · [验收指南](specs/001-device-debug-bridge/quickstart.md)

## 可以做什么

| 功能 | 当前范围 |
| --- | --- |
| 设备连接 | 自动发现设备、优先 USB；Android 支持已配对的无线调试与连接维护。iOS 主要验证路径为 USB。 |
| 剪切板 | 读取、写入当前文本，最多 1 MiB UTF-8；支持完整编辑、复制全部及保存 TXT，不读取历史记录。 |
| 截图 | 捕获设备屏幕、预览、复制和保存 PNG；iOS 需先准备并签名设备端 runner。 |
| 图片 | 按需加载每页最多 24 张缩略图，预览并下载原图；Android 限 DCIM、Pictures、Download，iPhone 限 USB 相机导入可访问内容。 |
| 视频 | Android 共享媒体目录、iPhone USB 导入可见的本地视频；按需下载与播放，单个最大 512 MiB。编码播放支持取决于 macOS。新增路径尚未真机验收。 |
| 文件传输 | 新增目录浏览和文件选择。Android 下载目录及可调试应用数据；iOS 由 CoreDevice 允许的临时目录、应用/应用组容器和只读崩溃日志。受保护路径不可任意访问。 |
| 鸿蒙（实验性） | HDC 设备发现、基础信息、目录浏览与下载、明确 OS 用户的文档发送、调试目录文件发送、HAP 安装/更新。APK 只能发送，不能通过 HDC 原生安装。新增 mediatool 能力检测、图片/视频列表及选中导出，候选加入显式 HDC 剪贴板读写。HarmonyOS 7 已验证列表元数据及部分 CLI 能力；公共文档 mkdir 被该测试设备策略拒绝，调试目录不等于手机文件管理可见。媒体原件、HAP 安装及新候选 App 的完整真机验收仍有未测项。 |
| Flutter 内存 | 发现目标应用的 VM Service，监测 Dart heap/external 数据；Android 另有系统内存信息。Dart 指标不等同于 iOS 应用总内存。 |
| 界面语言 | 跟随系统、简体中文、English；右上角即时切换并保存选择，不改变设备内容或当前会话。 |

新增鸿蒙、视频和文件浏览代码的范围与未验证项见[接入说明](docs/harmonyos-media-files.md)；HAP 安装、APK 发送和使用限制见[HDC 安装与发送](docs/harmonyos-hdc-install-send.md)。媒体库的新能力及限制见 [mediatool 接入](docs/harmonyos-mediatool.md)。限定系统的实测范围与未通过项见 [HarmonyOS 7 验证记录](docs/validation/harmonyos7-20261113.md)。当前分支不是已发布版本，不能把部分命令验证当作全部 App 功能通过。

## 下载与安装

1. 登录有权访问本私人仓库的 GitHub 账号，打开 [Releases](https://github.com/fus-cherry/DeviceBridge/releases)，下载对应版本的 `macOS-arm64.dmg` 文件。
2. 打开 DMG，将 `DeviceBridge.app` 拖入“应用程序”，然后从“应用程序”启动。
3. 当前自动构建采用 **ad-hoc 签名，未经过 Apple 公证**，面向可信团队内部使用。如果 macOS 阻止打开，在确认下载来源后，通过“系统设置 → 隐私与安全性”对这一个应用选择“仍要打开”。组织的安全策略可能不允许此类应用。
4. 按下方要求准备设备工具，连接并选择设备。应用会显示检查、准备、失败原因与重试入口。

每次发布的具体文件、校验和及构建结果以 Release 页面为准。手动触发构建的下载位置和维护者操作见[发布文档](docs/releasing.md)。

## 使用前准备

| 使用场景 | 要求 |
| --- | --- |
| Mac 应用 | Apple Silicon，macOS 14 或更新；当前不提供 Intel 构建。 |
| Android | Android 11+，Android SDK Platform-Tools / ADB 37+；开启 USB 调试并确认设备授权。无线连接需先完成无线调试配对。 |
| iPhone | iOS 17+；安装并选用支持 **Swift 6.2+** 的 Xcode，且支持所连接的 iOS 版本；完成设备信任与开发者模式设置。Xcode 自身可能要求比 macOS 14 更新的系统。 |
| iOS 剪切板与截图 | 当前私有构建内置所有者的 iOS 开发团队，不再显示团队输入框，也不使用旧保存值。本机须已有该团队可用的 Apple Development 签名身份和设备描述文件；应用不会自动创建证书。 |

Android helper APK 已内置，应用按需安装或更新，无需使用者自行编译。剪切板及无线保活需要可见的受管 helper，并可能要求前台操作或通知权限。iOS runner 源码同样内置，但必须在使用者自己的 Mac 上完成开发签名与构建。当前所有者构建的 iOS runner 团队固定为 `5F6294RLX4`；这不是 Mac App 的 Developer ID 分发证书，不能替代本机证书、私钥或描述文件。

设备信任、调试授权、配对、剪切板隐私提示和文件/网络权限按实际操作处理。当前实现通过设备工具截图，不要求 Mac 屏幕录制，也不要求全局辅助功能或完全磁盘访问。连接设备或后台发现不会自动读取剪切板、截图或图片内容；图片需要点击“加载图片”。

## 鸿蒙 HDC 工具管理

0.1.8 候选新增“设置 → HDC 管理”：识别新旧 DevEco SDK 路径、手动选择或导入解压后的官方工具链、检查架构和依赖、保存并恢复选择。下载源支持自定义 HTTPS 地址和同版本/架构的有限样本测速排序；官方下载可能需要在浏览器登录。此版本不会自动解压或执行任意来源的软件包，不修改系统 PATH。具体边界和验证说明见 [HDC 工具管理](docs/hdc-tool-manager.md)。

## iPhone 首次准备为何较慢

首次使用需要本机编译、校验签名、安装并启动 runner。界面会显示准备阶段、已用时间与取消/恢复操作；构建完成的工作目录可跨应用重启复用，后续仍会运行增量构建及签名校验。

2026-09-09 的三个独立进程实测：首次编译 **33.650 秒**，复用后 **2.359 / 1.689 秒**。这仅测量 `build-for-testing`，**不含设备安装、通道启动或整体就绪时间**；更换安装路径、团队、设备或构建输入仍可能触发冷构建。详见[启动反馈与缓存验证](specs/001-device-debug-bridge/validation/startup-feedback-and-reuse-20260909.md)。

## 已知限制

- 当前是内部试用工具。已有指定真机的 USB 剪切板、截图、图片与文件传输记录，但不能据此保证所有设备、系统和权限组合都可用；全新 Mac 首次运行仍需验证。
- iPhone 无线图片访问不可用；其他 iOS 无线路径、断连/锁屏/拒绝权限等异常条件，以及 Flutter VM 长期稳定性仍需分别验收。USB 成功不代表 Wi-Fi 已通过。
- Android 无线连接会受厂商电池策略和网络变化影响；长时间保活与大文件传输仍需在目标设备上验证。
- iOS runner 会话最长运行一小时，结束后需重新选择设备。持久编译缓存目前没有自动容量上限；中断或失败的工作目录不会自动回收。
- 自动构建通过代表产物与自动检查通过，不代表真机验收完成，也不代表 Developer ID 签名或 Apple 公证通过。

## 文档导航

- [Agent API 与 CLI](docs/agent-api.md)：本机 JSON 调用、五个方法、会话与重试规则、输出结构及限额。
- [开发与测试](docs/development.md)：工具链、源码构建、测试边界及手动 Developer ID / 公证流程。
- [自动构建与发布](docs/releasing.md)：GitHub Actions、签名配置、版本标签与产物下载。
- [Quickstart / 验收指南](specs/001-device-debug-bridge/quickstart.md)：可执行检查和物理设备验证条件。
- [需求规格](specs/001-device-debug-bridge/spec.md) · [实现计划](specs/001-device-debug-bridge/plan.md) · [任务与未完成项](specs/001-device-debug-bridge/tasks.md)。
- [验证记录](specs/001-device-debug-bridge/validation/)：按日期保留历史结果和限制；当前启动行为见 [Build 9](specs/001-device-debug-bridge/validation/startup-feedback-and-reuse-20260909.md)，非 VM 真机证据见 [iOS 验收记录](specs/001-device-debug-bridge/validation/ios-nonvm-acceptance.md)。
