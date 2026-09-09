# 自动构建与发布

[返回首页](../README.md) · [开发指南](development.md)

仓库：[fus-cherry/DeviceBridge](https://github.com/fus-cherry/DeviceBridge)

## 触发方式

| 操作 | 结果 |
| --- | --- |
| 推送到 `main` | 测试、构建 DMG，保存为 Actions artifact，保留 14 天 |
| Actions → Build and Release → Run workflow | 构建所选分支或标签；只有版本标签会发布 Release |
| 推送 `vMAJOR.MINOR.PATCH` 标签 | 构建成功后，将 DMG 与校验文件发布到 GitHub Releases 的内部测试预发布版本 |

分支构建读取根目录 [`VERSION`](../VERSION)。标签构建以标签版本为准；构建号为 `100 + GITHUB_RUN_NUMBER`，写入 App 的 `CFBundleVersion`。发布前应将 `VERSION` 更新到相同版本。

```sh
# 在已检查、已提交的版本上执行；版本标签应当唯一。
git push origin main
git tag -a v0.1.2 -m 'DeviceBridge 0.1.2'
git push origin v0.1.2
```

以后发布时递增版本，不移动已发布标签。

## 流水线做什么

入口是 [release.yml](../.github/workflows/release.yml)。构建使用 GitHub 托管的 Apple Silicon `macos-26` runner、Xcode 26.6、Java 17、Gradle 8.11.1、Android SDK 35；产物部署目标仍为 macOS 14+，不是要求使用者安装 macOS 26。

1. 校验版本与 runner 架构。
2. 运行三个 Swift package 的测试、Python 打包检查及两个无界面工作区检查。
3. 用固定 CI 签名构建 Android helper，并验证 APK 签名。
4. [build-release.sh](../scripts/build-release.sh) 构建 Release App，校验 App 版本、arm64 架构、代码签名、内嵌 APK 哈希及 iOS runner 源码依赖，生成并校验 DMG。
5. 上传 DMG、`SHA256SUMS.txt`、`build-info.json` 和发布说明。版本标签构建在独立发布任务中先创建草稿、上传全部附件，再公开为仓库成员可见的预发布版本。

工作流默认只读仓库，仅发布任务拥有 `contents: write`。第三方 Actions 固定到提交 SHA。构建不会运行桌面 XCTest，也不会接触真实手机；自动检查不代表真机全功能验收完成。

Runner 和工具链资料：[GitHub 托管 runner](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)、[macOS 26 ARM64 镜像](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md)。更新工具链时应同时更新工作流与此文档，并重新构建验证。

## 签名与安装边界

### macOS

默认包为 **ad-hoc 签名的内部测试版本，未经 Apple 公证**，不需要将个人 Apple 证书上传到 GitHub。首次打开可能被 Gatekeeper 拦截；按首页的安装说明，在系统设置 → 隐私与安全性中允许打开。

需要 Developer ID 签名和 Apple 公证时，按[开发指南](development.md#手动-developer-id-归档)准备正式分发。当前自动流水线不声称支持自动公证。

iOS runner 源码内嵌在 App 中，使用者在自己的 Mac 上选择签名团队后构建；CI 不分发可直接安装到任意 iPhone 的预签名 runner。

### Android

在仓库 Settings → Secrets and variables → Actions 中配置以下 **Repository secrets**：

| Secret | 内容 |
| --- | --- |
| `ANDROID_KEYSTORE_BASE64` | 专用于此项目的 JKS 文件的 Base64 字符串，别名为 `devicebridge-ci` |
| `ANDROID_KEYSTORE_PASSWORD` | JKS 密码与该别名的私钥密码，两者相同 |

两项必须同时存在。缺少任何一项就停止构建，不临时生成不同密钥、不退回每次变化的 debug 签名。秘密仅在签名步骤注入；临时 JKS 在该步骤退出时清理，不进入源码、缓存或构建附件。

妥善保存这份固定签名。GitHub Secrets 不能读回明文，不能作为唯一备份。更新 helper 时必须复用相同密钥；若改了签名，Android 无法直接覆盖旧 helper，需用户手动卸载后再安装。既有本地测试包使用的签名与 CI 签名可能不同，首次迁移也可能遇到此情况。

## 下载与校验

从 [Releases](https://github.com/fus-cherry/DeviceBridge/releases) 下载同一版本的附件。私人仓库需要登录并有仓库访问权限。

```sh
# 在附件所在目录执行；同时验证 DMG、构建信息和发布说明。
shasum -a 256 -c SHA256SUMS.txt
```

`build-info.json` 记录源码提交、版本号、构建号、架构、工具链及内嵌 APK 哈希。安装前退出旧 App，将新 App 拖到 `/Applications`，从固定路径启动。

## 失败与重试

- 测试或打包失败：查看失败步骤日志，修复后重新推送；没有成功的构建就不会运行发布任务。
- GitHub 托管 runner 因账户额度或账单限制拒绝运行：先处理 GitHub 账户提示，再重新运行工作流。
- 签名失败：核对两项 Secrets、别名及密码，不通过更换临时密钥规避。
- 已有相同标签的 Release：工作流拒绝覆盖。发布完成后要修正内容，请发布新版本。
- 附件上传中断：可能留下未发布草稿。核对草稿来源后，由维护者删除该草稿再重跑失败任务；不会自动删除草稿、覆盖附件或移动标签。

本地也可复现打包：按开发指南生成已签名的 Android helper，设置 `ANDROID_HOME`、`DEVICE_BRIDGE_ANDROID_HELPER_APK`、`DEVICE_BRIDGE_ANDROID_HELPER_METADATA`，执行 `bash scripts/build-release.sh 0.1.2 10`。需要 Git checkout、Xcode 26.6、Python 3.9+ 和 Android build-tools 35.0.0。脚本保留构建目录与输出，已有同版本同构建号的输出会拒绝覆盖。
