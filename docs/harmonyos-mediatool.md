# 鸿蒙图片与视频：mediatool 接入

本次仅在 Linux 云端源码副本开发。没有操作用户本地、真实 HDC 或鸿蒙设备，没有推送或发布。以下是实现协议与验证边界，不是设备兼容性承诺。

## 能做什么

- 选择已授权的鸿蒙设备，在“图片”或“视频”页明确点击加载。连接本身不列举图库。
- 运行时检查 shell 身份及设备 `mediatool` 的列表能力，读取当前用户的 `/storage/media/local/files/Photo` 列表。这个是官方媒体别名，不把用户 ID 猜成 `100`。
- 按图片/视频类型显示有限数量的元数据，随后显式选择预览，或勾选后下载。鸿蒙没有后台缩略图下载。
- 对所选单个资源调用 `mediatool recv` 创建设备临时副本，再有界读取并验证传输。原格式不转码，视频播放取决于 macOS 编码支持。

## 与之前说明的差别

“HDC 完全无法读图库，必须开发设备端应用”的说法不准确。华为的 [mediatool 文档](https://developer.huawei.com/consumer/en/doc/harmonyos-guides/mediatool/) 和 [设备文件访问文档](https://developer.huawei.com/consumer/en/doc/harmonyos-guides/ide-device-file-explorer/) 明确给出媒体导出流程。

文档的 V14 版本已有按名称 `query` 及按 URI `recv`；当前文档有 `ls -l` 列表与按媒体路径导出，但没有明确标注这两个功能的最早 API 版本。因此不根据系统版本字符串直接判定支持。只有 query/recv 的旧设备，本版暂不提供手输名称查找回退，会提示自动列举能力不可用。

API 21 是另一条 `/mnt/data/<uid>/media_fuse/Photo` 直接访问通道的版本说明，**不是本版 mediatool ls 的最低版本声明**。本版未实现 media_fuse 回退，也不改权限、切换帐号、提权或安装媒体伴随应用。

## 用户应知道的限制

1. **隐藏相册不支持。** 仅接受普通调试 shell（UID 2000）；拒绝 root，以免绕过平台的隐藏资产过滤。
2. **云端资源不保证可用。** 普通列表不读取内容，但选中导出时系统可能尝试取得云端原件，消耗流量与设备存储。本版没有受支持的“禁止云下载”开关，不能保证导出只读本地内容。失败时可先在手机图库下载原件，再重试。
3. **设备临时副本。** 导出需要 `/data/local/tmp` 的空间，会尝试清理本次副本；取消、断线或设备状态改变可能留下临时副本。列表阶段无此写操作，图库源文件不会被修改或删除。
4. **文件名与格式。** `ls -l` 可能给出系统内部 IMG/VID 文件名，不保证与图库显示名相同。解析严格限定官方长列表格式，支持普通中文与名称内空格；暂不支持引号、反斜杠、shell 特殊符号、首尾空格或控制字符名称，遇到这些名称/异常行会明确拒绝该列表，不猜测文件路径。不能把行格式当作 NUL 分隔文件协议；恶意名称恰好伪装成另一条合法长列表行的情况无法仅靠文本格式完美识别。
5. **大视频。** 单视频上限 512 MiB，单图片 20 MiB；这是 DeviceBridge 的安全边界，不是华为宣称的最大值。分块传输避免整部视频缓存在内存里，但 HDC 启动开销与设备复制耗时仍可能触发超时。设备端需要一份临时副本空间，Mac 也需要预览与最终导出的空间。
6. **完整性含义。** SHA-256 验证的是 mediatool 生成的设备导出副本与 Mac 收到的副本。列表时间只有分钟精度，不能证明原件在同一分钟内绝未发生同长度修改，也不承诺能抵御主动恶意设备在系统调用间替换文件的竞态。

## 安全与错误处理

媒体范围固定，shell 操作数逐项转义。命令绑定同一设备 transport 和会话，每步检查取消与会话有效性；连接变化后不寻找另一台设备完成旧任务。

不调用 `mediatool recv all`、媒体 delete、导入、root 或权限修改。设备暂存使用本次独占创建的随机目录和固定文件名，已有路径不会被借用。清理仅限该次暂存，不递归删除图库或任意用户路径。

mediatool 返回 0 不足以证明成功：实现检查明确成功目标、实际文件类型/长度/摘要。异常输出、权限拒绝、旧工具、传输损坏或超限会失败，不伪装成空图库或成功导出。

## 真机验收待办

在另行获准的 macOS 和已授权测试设备上运行完整构建及测试后，检查：

- 支持 ls 的当前设备、只有 query/recv 的旧设备、没有 mediatool、未授权与锁屏状态。
- 普通 shell/拒绝 root；隐藏资产不出现；空相册与错误输出可区分。
- 图片/视频切换、重复加载、分页和仅勾选不导出；选中才建立临时副本。
- 中文、空格、引号、控制字符、重名、特殊日期与大图库的明确安全拒绝。
- 512 MiB 边界、大视频取消/断线、设备空间不足、云端资产的真实行为与流量提示。
- 导出副本清理、残留提示、Mac 原文件未覆盖、设备切换后旧请求不再发布。

Linux 夹具不能验证真实图库权限、HDC 输出行为、系统云下载、macOS 播放器或手机暂存清理。自动化结果见[本次验证记录](validation/hdc-mediatool-20261112.md)。

## 实现依据

- [Huawei mediatool](https://developer.huawei.com/consumer/en/doc/harmonyos-guides/mediatool/)
- [Huawei Device File Browser](https://developer.huawei.com/consumer/en/doc/harmonyos-guides/ide-device-file-explorer/)
- [OpenHarmony ls 实现](https://github.com/openharmony/multimedia_media_library/blob/master/tools/medialibrary_tool/src/command/ls_command.cpp)
- [OpenHarmony recv 实现](https://github.com/openharmony/multimedia_media_library/blob/master/tools/medialibrary_tool/src/command/recv_command_v10.cpp)
- [OpenHarmony 参数与目标路径解析](https://github.com/openharmony/multimedia_media_library/blob/master/tools/medialibrary_tool/src/command_line.cpp)

OpenHarmony 源码用于解释风险与设计测试，不据此宣称某零售鸿蒙构建与其完全一致。
