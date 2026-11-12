# v3.1 用户文档交付验证

日期：2026-11-12。基线：`1411e118a6ecf5ae044f9488029161fc64e55b7a`（v3）。只在云端修改、复测，未操作用户本地或设备，未推送。

## 复查结论与修复

v3 的 `/data/local/tmp` 只完成调试文件传输，不能当作手机文件管理可见的交付。当前华为官方 Device File Browser 文档确认普通连接设备的公共 Documents/Downloads 可上传；这与模拟器单独文档不同。

v3.1 新增明确 OS 用户的 Documents 范围：默认选择这一范围，但用户 ID 初始为空，不猜测 `100` 或误用 shell UID。发送每次生成 `DeviceBridge-<UUID>/<原文件名>`，成功后显示实际完整路径和手机文件管理查找步骤。权限错误不回退到调试目录。

复查官方 HMDFS 实现发现公共文件系统没有 hardlink 操作。因此公共文档不照搬 v3 调试目录的 `ln -T`，改为原子创建专属新文件夹后移动已校验文件。已有文件夹即使为空也不会删除；不支持替换公共文档；失败清理仅删除明确属于本次操作的空目录。

附带收紧接收路径：HDC file recv 接收至生成的本地 ASCII 临时路径，再由 Foundation 写入用户选择位置；拒绝包含引号/控制字符的远程路径。它们仍可浏览/发送，但不能把尚未验证的 HDC 参数重解析当作安全接收支持。没有新增远程接收暂存或改权限行为。

官方依据：
- [当前设备文件文档：Public Directories](https://developer.huawei.com/consumer/en/doc/harmonyos-guides/ide-device-file-explorer/)
- [V14 用户文档可见性说明](https://developer.huawei.com/consumer/cn/doc/best-practices-V14/bpta-local-file-and-data-debugging-V14/)
- [HMDFS inode 实现](https://github.com/openharmony/kernel_linux_5.10/blob/master/fs/hmdfs/inode_local.c)
- [HDC 默认接收模式](https://github.com/openharmony/developtools_hdc/blob/master/src/common/file.cpp)
- [HarmonyOS 5+ 浏览器下载 APK](https://consumer.huawei.com/cn/support/content/zh-cn16010239/)

## 执行结果

- 首轮新增用户文档范围后：101 项 Swift 测试通过。
- 最终 **106 项 Swift 测试、12 个 suite 连续两轮通过**；参数化输入不重复计数。
- 31 项 Python 重点检查通过，其中 9 项为 UI 源码连接检查。6 个改动 Swift 文件语法解析通过；681 个中文键的 JSON/占位符校验通过，`git diff --check` 通过。
- 上述通过结果、初轮结果和 v3 历史失败记录一并随交付保存，没有用子集通过替代全量构建或真机验收。
- Swift 子集使用 `scripts/check-cloud-swift.py`，没有修改产品 macOS 依赖。真实 POSIX shell 夹具模拟本地目录，不等于真实 HMDFS/HDC。
- 重点回归包括用户 100/101、非法/空/注入 ID、路径逃逸、无调试回退、特殊文件名、已存在空文件夹、移动失败、文件系统不同、取消、摘要、失效会话，以及安装和 Android/iPhone 既有行为。
- 界面检查仍是源码连接检查与语法解析，不是 SwiftUI 运行时测试。

复测：

```sh
python3 scripts/check-cloud-swift.py --swift /path/to/swift --work-dir /tmp/devicebridge-cloud-check
python3 scripts/test_harmony_package_interface.py
```

完整 macOS 构建/运行时 UI、有效签名 HAP、真实 Huawei HDC、零售系统 HMDFS 行为、Documents 权限/手机可见性和 APK 实际兼容性仍未验证。v3 已记录的完整 Python 平台依赖失败及 v2 HostCommandRunner Linux 时序限制没有被本次子集结果覆盖。

## 必须继续的真机验收

在获准测试机上核对当前 OS 用户 ID，然后发送一个无敏感内容的 TXT 和测试 APK。检查正确用户的“文件管理 → 我的手机 → 文档”是否出现实际 `DeviceBridge-…` 文件夹，文件内容是否一致，能否通过设备的受支持应用打开/分享。拒绝权限、空间不足、断连、取消、错误用户和重复文件夹都不能伪报成功或改送调试目录。

Documents 路径和上传方法有官方依据，DeviceBridge 的完整设备端体验仍需以上验收。若目标系统拒绝该路径，不执行提权、chmod/chown、切换帐号或文件系统回退；用户授权的 DocumentViewPicker 配套应用是独立后续方案，本版未实现。
