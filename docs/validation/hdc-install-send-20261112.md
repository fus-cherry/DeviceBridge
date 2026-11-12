# HDC 安装与文件发送：云端验证记录

日期：2026-11-12。基线：`a7c14c32541848ad097825b237f630529a68cc0b`（v2）。本次只修改 Linux 云端项目副本，未访问用户本地、未连接设备、未推送或发布。

## 自测循环

按要求采用“实现 → 执行真实测试 → 修复 → 复测”的自主循环。

1. 初版安装与既有读取回归：70 项 Swift 测试通过。
2. 扩大到发送与真实 shell 夹具，并加入官方不同版本输出：85 项测试中发现同一个参数化测试的两个失败案例。安装成功解析只接受独立 `msg:` 行，拒绝了当前 HDC 及 OpenHarmony 4/5 的带路径/queuesize 成功行。
3. 修复为提取安装结果行最后的 `msg:` 字段，保留明确失败优先与非成功输出拒绝：85 项全部通过。
4. 代码复查发现“本地源文件在初次哈希后变化”以及“会话失效但任务未取消”两条发送边界。增加经过摘要与会话校验的发送接口，在远程写入前拒绝源文件变化，暂存/发送/提交前重新验证会话，并新增服务层回归：89 项通过。
5. 加入安装重复调用锁定和命令运行中取消的回归：最终 **91 项 Swift 测试连续两轮通过**。参数化测试每项还包含多个输入案例，未重复计数。

失败日志和修复后日志全部保留；未删除失败断言或把失败改成跳过。

## 已通过

- Swift 6.2 Linux 隔离 SwiftPM：最终两轮均 91 项、12 个 suite。
- 覆盖 HDC 原生 HAP/不支持包类型、覆盖确认、设备目标参数、临时安全副本、文件大小/类型、安装成功与失败输出、超时/取消、会话切换及重复调用。
- 覆盖 HDC 文件发送、读路径回归、共享文档只读、符号链接逃逸、源文件变化、摘要不符、目的冲突、取消/不确定提交、暂存清理及会话失效。
- Linux 真实 POSIX shell 夹具执行生产 shell 脚本，覆盖特殊文件名、拒绝目录/符号链接、默认不覆盖、显式替换、摘要错误与清理。这仍不是 HDC 或鸿蒙 shell 实测。
- 保留 Android/iPhone 文件、Android 视频、工具查找及文件完整性回归。
- 29 项可在本云端执行的 Python 检查通过，其中 7 项是新增 UI 源码连接检查，**不是运行时 UI 测试**。
- 10 个改动/新增 Swift 文件的编译器前端语法解析通过；中文 JSON 与 664 个键的占位符校验通过；`git diff --check` 通过。

复测命令：

```sh
python3 scripts/check-cloud-swift.py --swift /path/to/swift-6.2/usr/bin/swift \
  --work-dir /tmp/devicebridge-cloud-check
python3 scripts/check-cloud-swift.py --swift /path/to/swift-6.2/usr/bin/swift \
  --work-dir /tmp/devicebridge-cloud-check

PYTHONPATH=scripts python3 -m unittest -v \
  test_compile_core_check test_release_bundle test_harmony_package_interface \
  test_helper_packaging.HelperPackagingTests.test_packaging_rejects_a_destination_symlink_before_writing \
  test_helper_packaging.HelperPackagingTests.test_packaging_rejects_a_destination_within_source_inputs \
  test_helper_packaging.HelperPackagingTests.test_packaging_rejects_source_overlap_hidden_by_dot_components
```

## 没有通过或没有执行的部分

- 完整 Python discover 实际运行了 32 项：29 项通过、2 项 helper 打包测试因为 `/usr/bin/plutil` 不存在而失败、1 项签名测试按既有 opt-in 条件跳过；此外 VM 重定向 suite 在 setup 阶段编译完整 Core 时失败，因为 Linux 没有 Apple `Security` 模块。初次未设置 Swift PATH 的失败也保留，设置正确路径后重跑仍是平台依赖阻碍。
- 完整 macOS Core 构建、SwiftUI/AppKit 类型检查和运行时 UI 测试未通过验证。没有 Xcode/macOS 环境，不生成或冒充可运行 DMG。
- HDC 真进程、Huawei 设备、有效签名 HAP 实际安装/更新、零售系统文件权限、设备端 toybox 选项和实际 APK 兼容产品均未测试。
- 本次没有重跑 v2 的额外 HostCommandRunner Linux 诊断；其 3 项 Foundation 时序失败仍按 v2 记录保留，不记入本次 91 项成功。

隔离 harness 只复制明确列出的生产源码/测试，在副本中进行 CryptoKit→官方 Swift Crypto、Darwin→Glibc 和 autoreleasepool 兼容适配。未修改产品 macOS 平台依赖，未用 Python 重写实现替代 Swift 测试。

## 使用与剩余验收

使用方式、原生 APK 限制、安装覆盖语义、权限和安全边界见[HDC 安装与发送](../harmonyos-hdc-install-send.md)。后续应在获准的 macOS/Xcode 环境运行完整 Core 与 UI 检查并构建，然后用获准测试机验收。取消/超时不代表设备已回滚，重复操作前先检查设备。
