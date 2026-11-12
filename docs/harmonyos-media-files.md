# 鸿蒙读取、视频与文件浏览

本次新增代码尚未完成 macOS 编译和真机验收。下面区分实现范围与仍需验证的能力，不代表所有设备均可使用。

## 鸿蒙：HDC 读取与调试操作

适用于开启开发者调试并已授权当前电脑的 HarmonyOS / HarmonyOS NEXT 设备。桌面端通过 DevEco Studio 提供的 HDC 使用明确的 `-t <connect-key>`，不会将鸿蒙当作 Android/ADB 设备处理。

- 发现：`hdc list targets -v`，选择设备后执行只读 shell 就绪检查。
- 基础信息：公开的厂商、型号、产品、系统构建参数。未返回的字段明确显示不可用，不用 API 等级猜测系统营销版本。
- 文件：只读浏览和接收 `/data/local/tmp` 与 `/storage/Users/currentUser/Docs` 下调试 shell 可以读取的文件。共享文档在零售系统上也可能被拒绝。
- 普通文件路径：相对路径校验、规范路径范围检查、跳过目录符号链接、NUL 分隔目录结果。浏览可保留特殊名称；HDC 普通文件接收遇引号/控制字符会安全拒绝，详见安装与发送说明。媒体列表的行格式另有限制。
- HDC 目标身份标为 provisional，不声称 USB 与 TCP connect-key 是已验证的同一物理设备。
- 新增显式确认后的 HAP 安装/更新与明确 OS 用户的公共 Documents/调试目录文件发送，详见[HDC 安装与发送](harmonyos-hdc-install-send.md)。旧 currentUser 共享别名继续只读；不启用调试、提权或绕过用户授权，不提供鸿蒙剪切板、截图和内存监测。

工具查找：已有系统目录、`PATH`、`HDC_HOME`（hdc 可执行文件所在目录）、`DEVECO_SDK_HOME` / `OHOS_SDK_HOME` 下的 toolchains 目录，以及 `/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains`。配置变化后重新启动应用并刷新。

**更正系统相册说明：** HDC 文件权限不等于 PhotoAccessHelper / 文件选择器授权，但“必须另做设备端应用才能读取图库”的说法过于绝对。华为提供 `mediatool` 的列举/导出通道；API 21 起另有 `media_fuse` 直接文件通道。本版新增前者的运行时能力检测、图片/视频列表与显式选中导出，见 [mediatool 接入说明](harmonyos-mediatool.md)。这不表示所有 HarmonyOS 版本、隐藏相册或云端资产都能使用。仅有旧版 query/recv 而没有 ls 能力的设备，本版自动列表明确不可用，不把失败显示为空图库。

普通调试目录仍不是相册；`mediatool recv` 会在设备调试目录创建临时副本，再传到 Mac。程序不修改或删除图库原件，但不能把整个导出过程称作“设备纯只读”。需要设备临时空间，系统是否会下载云端原件取决于设备实现，本版无法保证离线或只读本地资源。未完成真机验收。

官方参考：
- https://developer.huawei.com/consumer/en/doc/harmonyos-guides/mediatool/
- https://developer.huawei.com/consumer/en/doc/harmonyos-guides/ide-device-file-explorer/

## Android / iPhone 视频

文件页分为“图片”“视频”“文件传输”。图片流程保留默认行为；切换类型会取消旧请求并清空旧目录和预览。

- Android：DCIM、Pictures、Download、Movies 范围内按扩展名列出视频，原文件按需读取。
- iPhone：使用现有 ImageCaptureCore USB 相机导入通道，只列出该通道可见的本地媒体。不新增设备应用；不支持无线或仅云端保存的视频。
- 最大单视频 512 MiB。Android 每次最多读取 4 MiB，并校验前后元数据、SHA-256 与本地字节；iPhone 使用已有下载通道、长度边界与本地完整性校验。
- 列表使用视频占位图，不为一页视频自动下载全部原文件。选择一个视频才下载并交给 macOS 播放器。
- 播放取决于 macOS 编码支持。原文件仍可下载到本地并用其他播放器打开；导出不等待视频解码。切换页面或失去连接可操作状态时暂停播放。
- 图片保持 20 MiB / 1 亿像素限制，目录扫描继续有数量与输出大小上限。

## 文件读取改进

1. 选择平台允许的文件范围。Android 应用数据需要 debuggable 包名；iOS 容器需要正确 Bundle ID / 应用组 / 临时域标识。
2. 点击“加载文件夹”，点击目录进入，或点击文件自动填写相对路径；“上一级”只返回范围内的父目录。
3. 点击“接收文件…”选择保存位置。保留手输相对路径功能，但去掉误导性的默认 `fixture.txt` 和虚构临时域标识。

实现修复包括：
- `adb shell` 的远程参数转义；`exec-out` 使用 ADB 自身的参数转义，避免二次引号。
- Android 应用文件按 1 MiB 分块读取，并抑制 dd 的统计输出，避免将文本混入二进制数据或一次缓存数百 MiB。
- iOS 列表失败/未知 JSON 不再被当作“文件不存在”，防止误覆盖；接收经应用临时目录完成。
- 文件浏览与传输绑定所选会话，文件选择对话框关闭后再次核对设备选择，避免 A 设备请求误发到 B 设备。
- 传输期间新出现的目标文件不会在未获覆盖许可时被替换；已提交文件不会因为随后设备切换而被删除。

权限拒绝、设备断开、目录不支持、超时仍可能发生，界面报告失败，不把失败当作空目录。

## v2 历史验证状态（2026-11-12，第二轮自主检查）

后续 HDC 安装与发送的最新验证见[第三轮记录](validation/hdc-install-send-20261112.md)。以下保留 v2 基线结果。

开发和测试均在 Linux 云端副本完成，未访问用户本地电脑、未操作真实设备、未推送或发布。

第二轮通过真实测试继续修复了：
- 无读取权限但可进入的 Android 目录被误报为空目录。
- 手输相对读取路径中的符号链接范围问题；仍不能保证抵御恶意设备主动改名的竞态。
- 含换行等特殊文件名的 sha256sum 转义前缀。
- iOS JSON 元数据文件没有读取大小上限、重复条目/不合法长度值和递归借用其他字段大小的问题。
- 读取命令结束后的取消检查，以及大文件哈希循环内的取消响应。
- 远程相对路径统一按已验证的 POSIX 组件解析。Linux Foundation 的 NSString 单组件路径异常在此避免，但没有据此声称 macOS 存在同样崩溃。

### 已执行的检查

- 官方 Swift 6.2 Linux 编译器对本次修改的 Swift 文件执行语法解析。
- 隔离 SwiftPM 核心测试：57 项，覆盖鸿蒙读取、Android 视频分块读取、Android/iOS 文件、目录浏览、完整性和工具查找。最终连续两轮均通过，日志随交付保存。
- 额外扩大到既有 HostCommandRunner 的诊断运行：69 项中 66 项通过，3 项有关继承管道与超时清理的时间断言失败。串行复测仍失败，未放松断言或改掉测试。
- 这 3 项对应的生产代码和测试与开发基线一致；独立 Linux Foundation Process 复现也在后台子进程结束约 2 秒后才回调，而测试要求小于 1 秒。这是当前 Linux 诊断限制，不作为 macOS 成功或失败的证据。
- 22 项仓库 Python 检查通过；实际 POSIX 二进制读取/特殊路径检查、JSON 占位符校验和 `git diff --check` 通过。

### 核心测试的边界

`scripts/check-cloud-swift.py` 在独立临时目录复制明确选定的生产源码和测试，不修改产品的平台依赖。仅在测试副本中将 CryptoKit 替换为官方 Swift Crypto 3.15.1、Darwin 替换为 Glibc、autoreleasepool 替换为同步闭包，并提取原有纯数据/校验声明。使用的是生产提供器、会话、文件传输逻辑与真实 Swift 测试，不是 Python 重写的行为模拟。

**这不是完整 macOS 应用构建：** 未覆盖 SwiftUI/AppKit、ImageCaptureCore、ImageIO、真实 AVPlayer 播放、Apple 安全通道或真实 ADB/HDC/devicectl 集成。上述部分及所有真机验收仍未执行。

可在具备可信 Swift 6.2 工具链的 Linux 云端重复运行：

```sh
python3 scripts/check-cloud-swift.py --swift /path/to/swift --work-dir /tmp/devicebridge-cloud-check
# 可选扩大诊断；当前 Linux 的 3 项 Foundation 时间断言已知失败，脚本会返回失败。
python3 scripts/check-cloud-swift.py --swift /path/to/swift --work-dir /tmp/devicebridge-cloud-check --include-host-runner
```

完整 Python 套件仍有环境阻碍：两项 helper 打包测试需要 macOS `/usr/bin/plutil`；VM 重定向测试需要完整 macOS Core 构建；签名测试按原设置跳过。没有将这些项目记为通过。

在获准的 macOS 开发或 CI 环境仍需执行：

```sh
swift test --package-path packages/DeviceBridgeCore --no-parallel
bash scripts/check-image-view-model.sh
bash scripts/check-workspace-inventory.sh
bash scripts/check-device-selection.sh
python3 -m unittest discover -s scripts -p 'test_*.py' -v
```

随后按 `docs/development.md` 构建 macOS 应用（需要 Android helper APK 与合适 Xcode），并验收：设备切换/断连、HDC 拒绝授权、文件夹空/拒绝访问、含中文/空格/引号/换行路径、下载取消、视频大小边界、无法播放的编码、视频播放中切换模块、覆盖文件竞态。真机验证需另行授权，不能以模拟数据测试代替。
