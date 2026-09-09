# Contract: 设备信息读取与 iOS device.info

覆盖 FR-001–008、FR-020–024；验收见[quickstart](../quickstart.md)。本文件描述实现后的接口契约；实测状态见[验证记录](../validation.md)。

## 应用侧读取边界

输入为选中的 `DeviceRecord`、完整 captured `ConnectionSession` 和取消上下文。每次读取独立，以20秒单调时钟总预算包含准入、命令启动、读取、解析及清理；单类查询使用剩余预算内较短期限。正常连接的10次样本至少9次≤10秒是性能门禁。

读取可来自界面或[Agent接口](agent-api.md)；二者使用相同入口与报告owner，读取中重复请求返回busy，不互相覆盖。Agent返回结构化字段与来源/限制，不能仅返回供人阅读的拼接文本。

每个外部await前后检查归属/取消。失效即停止后续查询并完成清理，不发布迟到候选。普通类别失败形成局部不可用；全无可用设备数据时返回整体失败。全局期限到达时取消当前外部操作，保留已经完成类别为明确“部分结果：达到读取时限”；用户取消不发布候选。若底层未及时清理，显示清理中并将20秒门禁记为失败，不能假装结束。

数据只流向[数据模型](../data-model.md)中的报告，不能在一般日志打印原始输出或完整标识。固定查询允许内部设备shell语法，但不拼接用户输入或把返回值当脚本。Android目标使用捕获的明确transport；连接失效后不回退到最新设备。

## 字段来源与验证

| 分组 | Android 计划来源与处理 | iPhone 计划来源与处理 |
| --- | --- | --- |
| 基础 | 精确allowlist的 `getprop`，包括制造商、品牌、市场型号、product/device、序列标识；连接标识另列 | CoreDevice已验证的name/marketingName/udid及productType（型号标识）；其他可选键先用真实JSON fixture验证。UIDevice.name不覆盖CoreDevice设备名称 |
| 系统 | release/sdk/security_patch/fingerprint/build属性、固定 `uname` 查询；无厂商键则不可用 | CoreDevice osVersionNumber及经真机JSON fixture验证的osBuildUpdate；runtime systemName/systemVersion；未知键不猜测 |
| 屏幕 | `wm size` 与 `wm density`；保留physical/override，effective=override存在时取override否则physical | UIScreen nativeBounds作为自然竖向物理px；逻辑points与方向单独标明；scale/nativeScale/maximumFramesPerSecond分列 |
| 硬件 | 实际ABI列表、CPU在线/可能核心范围及可选ro.soc.*；不以核数字符串长度推算 | ProcessInfo核心数；hw.machine只作型号标识。CoreDevice cpuType.name及supportedCPUTypes[].name按实际返回文本展示，不解释未知编号。未有可靠来源的SoC名保留不可用 |
| 内存 | `/proc/meminfo` 的MemTotal、MemAvailable，kB按1024bytes换算；缺失MemAvailable不自行用MemFree代替 | ProcessInfo.physicalMemory；当前系统可用RAM不可用，不能使用应用分配额度代替 |
| 存储 | 固定 `df -k /data` 对应数据卷；处理实际输出格式，blocks×1024须防溢出 | 同次普通volumeTotalCapacity/volumeAvailableCapacity；已用=总量−可用；不混用可回收容量API或市场容量 |
| 电池 | dumpsys battery的present/level/scale/status/供电/temperature/voltage已知字段；level÷scale；温度十分之一°C，电压mV | UIDevice batteryLevel/batteryState；未知level及unknown state不当成0；读取前后恢复batteryMonitoring；温压不支持 |
| 连接 | captured session、route及采样时间；不读最新route替换 | captured session与CoreDevice/runtime来源时间；缓存可能性明确 |

Android固定输出只提取所需字段，原始全文不持久保存。数量必须有限、非负且可精确转换；screen维度/scale、CPU数、总RAM必须>0；电量范围0…100%，scale>0；可用容量≤总容量；数值溢出、NaN/Infinity、非法小数或格式未知则该字段不可用。电池温度可以低于0°C，不能套用通用“所有负值非法”；仅拒绝无法解释的单位或协议外值。

CoreDevice 使用 `xcrun devicectl device info details --device <captured ID> --json-output <unique file> --timeout <remaining>`。文件名由工具创建；读取限额1MiB，解析后清理。核对结果identifier/稳定UDID与捕获归属，缺失或冲突不能提交。exit0及JSON存在均不能证明设备新鲜响应；若无source timestamp/明确fresh证据，一律标注“系统返回信息，可能缓存；本次查询于…”而非刚刚从设备测得。

## iOS 协议扩展

新增可选 action `device.info`，复用既有请求envelope、authenticated context、requestID/nonce、deadline及严格schema。请求payload为空对象，额外键拒绝。只有注册handler才协商此能力；新host遇到旧runner不支持时显示基础报告和扩展不可用原因。host和runner配套构建，不能承诺旧host接受新runner协商列表。

结果使用固定 `DeviceRuntimeInformation` DTO。每个下列字段都必须具有明确状态：数值/字符串或 `null`（不支持/无法采样）；未知键、错误类型、非有限数、整数小数化及溢出拒绝，null映射为平台限制或采样不可用，不转换为0。

| 字段 | 类型/语义 |
| --- | --- |
| systemName, systemVersion, modelIdentifier | String；系统与hw.machine来源 |
| processorCount, physicalMemoryBytes | 正整数，安全范围内的Int/UInt64 |
| screenWidthPixels, screenHeightPixels | 可空正整数；nativeBounds，naturalPortrait方向 |
| screenWidthPoints, screenHeightPoints | 可空有限正数；与screenCoordinateBasis一起解释 |
| screenCoordinateBasis | 可空枚举 `fixedPortrait` / `currentLandscape` / `currentPortrait`；优先固定坐标，不能未标方向直接填bounds |
| screenScale, screenNativeScale | 可空有限正数，分别来自对应属性 |
| maximumFramesPerSecond | 可空正整数，仅最大能力 |
| totalStorageBytes, availableStorageBytes | 可空非负整数；同时可用时available≤total |
| batteryLevel | 可空有限数0…1 |
| batteryState | `unknown/unplugged/charging/full` |

字段范围固定且长度有界：字符串每项≤1KiB UTF-8，序列化结果≤64KiB，受既有envelope更严格上限约束。查询时间由host记录；不以跨设备墙钟比较deadline或排序。屏幕、存储采样失败允许对应字段null，其余有效字段保留；不能激活应用来强行获得screen。

metadata与既有clipboard/screenshot共享内容槽，忙碌返回busy；identity/Stop/heartbeat保留原路径。取消、deadline、Stop和错误必须清理本次handler。已有共享channel关闭语义保持不变，按[数据模型](../data-model.md)发出精确bindingLost；未准入不失效。adapter不得读取剪切板、截屏或更改应用前台状态。
