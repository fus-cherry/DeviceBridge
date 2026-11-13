# 鸿蒙 HDC 安装与文件发送

本次在云端源码副本开发，未访问用户本地、未推送或发布。v3.1 补上用户文档发送：v3 的 `/data/local/tmp` 调试中转不能视为手机文件管理可见的交付。新增功能仍需 macOS 构建与鸿蒙真机验收，不能把夹具测试当作实际安装或手机可见性验证。

## APK 与 HAP 的区别

- **HDC 原生安装：本版只接受一个 `.hap`。** APK 不是 HarmonyOS NEXT 原生包，改扩展名不会转换应用。
- **发送 APK：只复制文件，不安装、不启动，也不自动交给兼容应用。** v3.1 默认选择明确 OS 用户的公共 Documents 目录，并显示手机侧查找步骤；调试目录 `/data/local/tmp` 继续可选，但不能当作手机“下载”目录。
- 华为对 HarmonyOS 5+ 的说明包含卓易通/出境易等第三方兼容路径，适用应用、共享 APK 能力和版本由对应产品决定。本版没有对接它们，不能承诺某 APK 可运行。
- `.hsp` 需要不同安装方式/限制，`.app` 的 HDC 支持依赖 API 22+，本版安装入口均不接受。它们仍可作为普通文件发送。

官方参考：[Huawei HDC](https://developer.huawei.com/consumer/en/doc/harmonyos-guides/hdc/)、[HarmonyOS 5+ 应用安装说明](https://consumer.huawei.com/cn/support/content/zh-cn16061787/)、[OpenHarmony HDC 文档](https://github.com/openharmony/docs/blob/master/en/application-dev/dfx/hdc.md)。

## 安装 HAP

1. 准备可信 DevEco Studio / SDK 的 HDC，在手机开启开发者调试，并在手机上授权当前电脑。
2. 在 DeviceBridge 选择可操作的鸿蒙设备，打开“文件传输”，点击“安装 HAP…”。
3. 选择可读的、已正确签名且适配该设备的 HAP（单文件大于 0、最大 512 MiB），核对确认框中的包名和设备，再确认“安装或更新”。
4. 成功仅在 HDC 返回明确的 bundle 安装成功信息时显示。签名、存储、版本或设备授权失败会保留失败状态，不会自动卸载已有应用。

执行形式是 `hdc -t <已选择设备> install -r <安全临时副本.hap>`。**即使省略 `-r`，bundle manager 也可能默认覆盖同包应用。** 因而界面明确确认“安装或更新”，核心服务在没有覆盖确认时拒绝调用 HDC，不提供虚假的“不覆盖”开关。安装可能更新现有应用或触发其数据迁移；安装成功不代表应用已启动或兼容性测试通过。

原始文件名可以包含中文、空格和引号。执行前会在权限为 0700 的临时目录复制为受控 ASCII 文件名，防止 HDC 内部重新解析命令参数造成路径混淆；结束后删除该本地临时副本。不上传包到任何服务。

官方行为依据：[BM 安装与签名限制](https://developer.huawei.com/consumer/en/doc/harmonyos-guides/bm-tool/)、[BM 默认 REPLACE_EXISTING](https://github.com/openharmony/bundlemanager_bundle_tool/blob/master/frameworks/src/bundle_command.cpp)、[HDC 安装结果输出](https://github.com/openharmony/developtools_hdc/blob/master/src/host/host_app.cpp)。

## 发送到手机用户文档（v3.1）

1. 选择鸿蒙设备后默认显示“鸿蒙用户文档”。**明确填写目标设备的 OS 用户 ID**，这不是华为帐号 ID。主用户常为 `100`，但应用不预填、不猜测当前帐号；请按该设备确认。没有确认 ID 时不会发送。
2. 点击“发送文件…”，选择本地文件，不需要先手填相对路径。每次自动生成一个新的 `DeviceBridge-<UUID>` 文件夹，保留原文件名。
3. 发送位置为 `/storage/media/<OS用户ID>/local/files/Docs/Documents/DeviceBridge-<UUID>/<文件名>`。选 APK 时确认框会显示完整目标位置并再次说明只复制。
4. 成功后复制界面显示的实际路径，并在目标用户的手机“文件管理 → 我的手机 → 文档”下查找同名 `DeviceBridge-…` 文件夹，然后打开或分享文件。不同系统界面可能略有差异，目标设备可见性和兼容应用能否打开仍须真机确认。
5. 接收/浏览用户文档时，相对路径仍相对于该用户的 Documents 根目录。发送每次创建新文件夹，不使用浏览器当前子目录、不覆盖已有文档。接收含引号或控制字符的远程路径暂不支持，会在调用 HDC 前明确失败；本地保存路径则通过安全临时别名处理。

当前华为 [Device File Browser 文档](https://developer.huawei.com/consumer/en/doc/harmonyos-guides/ide-device-file-explorer/) 明确将 `/storage/media/100/local/files/Docs` 下的 Desktop、Documents、Downloads 列为可上传/下载的公共目录；这不是只适用于模拟器的说明。较早的 [V14 文件调试实践](https://developer.huawei.com/consumer/cn/doc/best-practices-V14/bpta-local-file-and-data-debugging-V14/) 也说明用户文档上传后可在设备“我的文档”查看。这里选择最小的 Documents 范围，而不开放整个公共目录。

**不会绕过权限：** 根目录不存在、不可读写、规范路径不符合范围、摘要校验失败或安全提交不支持时，操作失败。不会改权限、提权、切换用户、猜另一个用户 ID，也不会悄悄改送到 `/data/local/tmp`。

### 目录可读写，不等于系统允许创建暂存目录

零售设备可能在 Documents 存在、规范路径和 `test -d/-r/-w/-x` 均通过后，仍由系统策略拒绝创建私有传输目录。已观察到 HDC 将 `mkdir: … Permission denied` 放入标准输出，主机退出码仍为 0、标准错误为空。退出码 0 或可写权限检查都不能单独证明目录已创建。

本版仍须收到精确的 `DBSEND_READY` 标记才会调用 `hdc file send`。标记缺失且明确报告 mkdir 权限拒绝时，会说明公共文档的私有传输目录创建被系统拒绝，文件尚未发送。其他未确认的准备结果不猜测根因，也不清理未经确认属于本次操作的目录。Documents 根、完整换行哨兵、规范路径检查、防覆盖和私有暂存策略不变。

需要调试用途时，用户可明确另选“鸿蒙调试文件”重试；这只是临时调试范围，不保证手机文件管理器可见。应用不会自动切换目标、创建公共 Documents 根或修改权限。

### 调试目录和旧共享别名

- “鸿蒙调试文件”仍发送/接收到 `/data/local/tmp`，适合 HDC/开发调试。它不是用户下载目录，文件管理器或兼容应用未必能看到。
- 原 `/storage/Users/currentUser/Docs` 共享文档别名继续只读，保留兼容用途；用户侧文件交付应选择新的明确用户文档范围。
- 调试目录发送需填写相对路径，已有文件时界面拒绝覆盖。核心 API 仅在明确允许时支持普通调试文件替换。

### 传输安全与 HMDFS 兼容

- 拒绝绝对路径、`..`、空组件、NUL、跨平台范围、非法目标和非规范 OS 用户 ID。所有远程路径按 shell 规则逐项转义；HDC file send 的路径采用生成的 ASCII 名称。
- 本地文件先固定为副本，并与服务开始时的摘要比较。源文件变化时在远程写入前失败。暂存/发送/提交前重新核对会话，不能发布旧设备结果。
- 公共文档的暂存位于所选 Documents 根目录内，上传后验证大小与 SHA-256。提交先以 `mkdir` 独占创建新的 `DeviceBridge-<UUID>` 文件夹，然后移动已校验文件。若文件夹已存在，哪怕是空目录也失败，不删除或覆盖它。
- 公共文档**不依赖硬链接**。OpenHarmony HMDFS 的官方 inode 操作没有 `.link`；v3 的调试目录 `ln -T` 不可直接照搬到公共文档。只在确认本次创建且移动明确失败时尝试 `rmdir` 空文件夹；提交应答不确定时保留目标，提示先检查再重试。
- 调试目录仍通过 `ln -T` 原子拒绝覆盖；明确替换使用 `mv -fT`。两种范围都检查同一文件系统，避免跨文件系统移动退化为复制。
- 依赖 shell 的 `readlink`、`stat`、`sha256sum`、`mv -T`，调试目录还需 `ln -T`。不支持时失败，不采用不安全回退。
- 不使用 HDC `-m` 同步源权限，不执行 chmod/chown。HDC 默认请求以 0644 创建接收文件，但 HMDFS 和零售系统可能调整实际权限；本测试不能证明手机应用已经获得可读性。
- 清理仅尝试删除本次暂存文件和空目录，不递归删除、不删除用户目标。创建应答中断可能留下空暂存目录。设备断开可能保留暂存内容。
- 不声称能抵御恶意设备或其他进程主动在多个 shell 系统调用之间交换路径/目录的所有竞态。不绕过应用沙箱、账户或相册授权。

实现依据：[HMDFS inode 操作](https://github.com/openharmony/kernel_linux_5.10/blob/master/fs/hmdfs/inode_local.c)、[HDC 默认文件模式](https://github.com/openharmony/developtools_hdc/blob/master/src/common/file.cpp)、[OpenHarmony mv](https://github.com/openharmony/third_party_toybox/blob/master/toys/posix/cp.c)。

### 如果手机端仍无法找到或打开

先核对 OS 用户 ID、界面实际路径和手机当前用户，不要把“SHA-256 已校验”理解成“文件管理器可见已验证”。权限或文件系统不支持时，本版没有自动导入到手机应用的替代通道。

华为官方另有 [HarmonyOS 5+ 浏览器 APK 下载流程](https://consumer.huawei.com/cn/support/content/zh-cn16010239/)：从可信的应用开发者下载页选择“仍要下载”，完成后“打开”可交给卓易通，兼容性以该产品为准。可按需在手机上自行使用这一流程；本版不上传用户 APK 到网站或第三方服务，不创建下载服务器，也不自动执行第三方安装。

## 取消与连接变化

安装/发送可以取消。取消只停止等待/传输，不保证撤销设备已经完成的安装或最终文件提交。超时、取消或提交应答中断时，应先检查设备状态，避免盲目重复安装。界面会等当前命令退出后再解锁同一会话的文件操作；旧请求不会覆盖新请求反馈。

`AppMod finish` 和 HDC 退出码 0 都不能单独证明成功。安装解析兼容当前以及 OpenHarmony 4/5 带 `queuesize` 的输出，仅接受最后的明确 `msg:install bundle successfully.` 信息；任何明确失败信息优先判为失败。传输另以实际远端摘要验证。

## 复测与验收

v3.1 云端自动化结果与限制见[用户文档验证记录](validation/hdc-user-documents-20261112.md)；v3 安装/发送基线见 [HDC 验证记录](validation/hdc-install-send-20261112.md)。在获准的 macOS/Xcode 环境，应先运行完整 Core 测试、构建应用，再用获准的鸿蒙测试机检查：

- 一个有正确签名的 HAP 首次安装及同包更新；拒绝确认后没有安装命令。
- APK 安装被拒绝；用户文档发送后在正确 OS 用户的手机文件管理中找到生成文件夹与原文件名，尝试打开或分享；不把第三方兼容产品当作原生能力。
- 用户 100/101、空/错误 ID、公共 Documents 权限被拒、HMDFS 不支持硬链接、已有同名传输文件夹不得覆盖、调试目录没有被当成下载目录。
- 签名不匹配、未授权/锁屏、离线、空间不足、超时及断连。
- 连续点击、取消后再操作、文件选择与确认期间切换设备、运行中切换/重连设备。
- 中文/空格/引号/换行文件名；现有文件/目录/符号链接不被覆盖；摘要不匹配不提交。
- 普通文件下载、图片/视频浏览以及 Android/iPhone 既有行为没有回归。

真实 HDC、签名包、设备权限和 macOS UI 均不由 Linux 夹具覆盖。
