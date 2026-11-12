# HDC mediatool 云端验证记录

日期：2026-11-12。交付轮次 v4，基线 v3.1 `165f6ecf450813ef46e3d0fef9d5c5f94fdd2124`。全部开发和测试在 Linux 云端副本完成，未访问用户本地、未连接真实设备、未推送或发布。

## 实现与证据

- 新增 `HarmonyMediaProvider`，运行时检查普通 shell UID 2000、mediatool 帮助中 ls/recv 能力，并执行有界长列表读取。不凭营销版本或 API 数字猜测能力。
- 当前用户官方媒体别名；256 目录、深度 8、10,000 条、总 4 MiB 元数据、60 秒扫描期限。单次列表输出另限 512 KiB。超限明确失败，不返回貌似完整的部分列表。
- 列表不读取图片/视频内容；UI 和核心服务均阻止鸿蒙自动缩略图。显式选择或批量勾选后点击下载才导出所选项目。
- 临时导出仅在随机独占 0700 调试目录的 `payload.bin`；校验实际目标行、普通文件、规范路径、长度和 SHA-256。带扩展名防止 mediatool 将目标当作目录。
- 4 MiB 原始字节分块，经 Base64 文本传输以避开终端二进制变换；单条输出上限 6 MiB，读取期限 600 秒，每块 60 秒。图片 20 MiB、视频 512 MiB 的产品限制没有扩大。
- 仅清理本次普通副本及空目录，不删除图库原件、递归目录或已有目标。命令前后检查捕获的设备会话；清理期间取消/失效亦撤销自己的 Mac partial，不发布成功。
- 对特殊名称保守拒绝，普通中文及中间空格支持。元数据只能用于有限的变化检测，不能证明同分钟同长度修改或抵御主动恶意设备竞态。

官方协议与限制见[接入说明](../harmonyos-mediatool.md)。OpenHarmony 源码与零售设备不保证逐版本一致；真实设备仍需验收。

## 自测、修复、复测

未找到名为 loop 的可用项目技能，使用实际运行测试、定位修复、补回归、再完整复测的循环；没有把“审查通过”当作运行测试。

1. 初次隔离 Swift 检查执行 121 项，120 通过，真实 POSIX 多块传输夹具报 `integrityMismatch`。
2. 定位：旧校验按 Swift Character 检查字符串 `...=\r\n`，CRLF 被视为一个 Character，真实 Base64 的单独 LF 反而被拒绝；无折行的假输出未暴露此问题。
3. 改成 ASCII 字节校验与去除 CR/LF，并补 LF/CRLF 折行测试。真实多块二进制夹具通过，不放宽摘要或长度校验。
4. 审查同时修复合法 `failed.png`、`not found.jpg` 等名称被错误诊断为命令失败，以及清理期间取消/失效后仍可能返回成功的问题；新增针对性回归。
5. 最终冻结代码后，**124 项 Swift 测试 / 14 套件连续两轮通过**，测试执行分别 2.425 秒、2.653 秒（不含构建）。

最终测试包含：支持/不支持/空列表区分、root/未授权拒绝、目标注入、异常元数据、遍历边界、普通中文空格、诊断关键词文件名、隐藏/越界/超限拒绝、所选单项导出、多块视频、伪成功、路径偏离、摘要和分块损坏、源变化、取消、会话失效、清理期间取消、逐命令会话检查。真实 shell 夹具运行生成的暂存、stat、sha256、dd/base64、清理脚本，只有 mediatool 和身份探测被模拟。**没有运行实际 HDC。**

## 最终检查结果

| 检查 | 结果 |
| --- | --- |
| 隔离 Swift 6.2 核心回归 | 124 项，连续两轮通过 |
| Python 重点检查 | 34 项通过，含 6 项媒体 UI 源接线检查 |
| Swift 语法解析 | 10 个修改/新增文件通过，不等于 macOS 类型检查 |
| 中文资源 | 694 个键，JSON 与占位符校验通过 |
| git diff --check | 通过 |
| 完整 Core swift test | 已尝试，Linux 缺 Apple `Security` 模块，构建失败 |
| 完整 Python discover | 已尝试：运行 40 项，37 通过、2 失败、1 跳过；另 VM 套件初始化报错 |
| macOS 运行时模型检查 / SwiftUI 构建 / 真机 | 未执行，不能记为通过 |

完整 Python 的两项失败均为 helper 打包依赖 `/usr/bin/plutil` 不存在；VM 套件初始化同样被 Apple Security 构建依赖阻挡，签名检查按既有条件跳过。这些没有被改成通过或删除。旧 HostCommandRunner 的 3 个 Linux Foundation 时间诊断失败在历史 v2 记录中保留，本轮未重跑该可选扩大诊断。

`PhoneImagesModelChecks.swift` 新增了鸿蒙页面激活、重复加载、勾选不读取、核心 thumbnail 拒绝、显式单选/批量、取消及重置案例；本环境只能解析语法，不能运行依赖 macOS 的该模型检查。

## 复现命令

```sh
python3 scripts/check-cloud-swift.py --swift /path/to/swift-6.2 --work-dir /tmp/devicebridge-cloud-check
python3 -m unittest scripts/test_compile_core_check.py scripts/test_release_bundle.py scripts/test_harmony_package_interface.py scripts/test_harmony_media_interface.py -v
```

隔离脚本只对临时副本做已记录的平台兼容调整：CryptoKit → 官方 Swift Crypto、Darwin → Glibc、同步 autoreleasepool 替身，并提取纯数据/请求校验类型。生产平台依赖不因此改变。

另行获准的 macOS 环境仍须运行完整 Core 测试、`scripts/check-image-view-model.sh`、完整 Python 套件和 Xcode 应用构建，随后按接入说明验收真实 HDC、图库权限、云端原件、隐藏资产、视频、特殊名称与暂存清理。此交付不含已构建的 Mac 应用，不提供真机成功承诺。
