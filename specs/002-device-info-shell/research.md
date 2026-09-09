# Research: 设备信息与 Android Shell

**日期**：2026-09-09；**阶段**：SpecKit Phase 0，只读研究。生产代码和实际设备均未在本轮修改或操作。

本文件记录决策及反证；来源支持设计选择，不代表目标设备已通过验证。技术选择已明确，实际协议与设备资格验证留给[验收指南](quickstart.md)。

## R1 — 在现有工作区增加独立模块

**Decision**：保留 Workspace 的选择/绑定职责，新增两个专用 ViewModel 和 provider/service；不继续将模块状态堆入现有大类，也不重构旧模块。

**Rationale**：现有 `WorkspaceViewModel.select` 在探测、Store提交后分别准备功能；`publishInventory`、`select`、`stop` 和 `cancelDisconnectedContent` 已是失效入口。`RetainedModulePane` 已支持模块导航保留输入。新增模块应接入这些入口，包括仅 inventory 变化时的失效，不能只处理点击切换。

**Alternatives considered**：所有状态写入 Workspace 会继续扩大编排；另建独立设备会话 Store 会制造两个选择 owner。均不采用。

**Evidence**：[工作区](../../apps/macos/DeviceBridgeApp/ViewModels/WorkspaceViewModel.swift)、[现有模块容器](../../apps/macos/DeviceBridgeApp/Views/WorkspaceView.swift)、[DeviceSessionStore](../../packages/DeviceBridgeCore/Sources/DeviceBridgeCore/Session/DeviceSessionStore.swift)。

## R2 — 原生 Shell-v2 保留真实退出证据

**Decision**：Shell 使用原生本地 ADB smart-socket/Shell-v2，原始命令只作为 service 的字节载荷。不使用普通 CLI 退出码、stderr前缀判断或远端包装标记推断结果。

**Rationale**：AOSP当前客户端缺失 exit 帧时可返回255，远端 `exit 255` 也可返回255；建立连接失败与用户程序退出1亦可能相同。任意命令还可输出看似 ADB 故障的 stderr 文本。只有协议退出帧能区分这些结果。

**Alternatives considered**：普通 `adb shell -T -n -- <command>` 是语义对照基准，但丢失退出来源；`adb raw` 在源码存在却不在当前工具help和公开手册中列出，增加工具兼容风险；附加远端 marker 会改变脚本环境并产生输出/标记歧义。原生适配器增加有限协议代码，同时移除了Shell宿主进程及双管道生命周期。

**Evidence**：本机只运行 `adb version/help`，确认版本37.0.1；未运行设备命令。[ADB手册](https://android.googlesource.com/platform/packages/modules/adb/+/refs/heads/main/docs/user/adb.1.md)、[客户端协议消费](https://android.googlesource.com/platform/packages/modules/adb/+/refs/heads/main/client/commandline.cpp)、[Shell协议类型](https://android.googlesource.com/platform/system/core/+/refs/heads/android10-gsi/adb/shell_protocol.h)、[帧实现](https://android.googlesource.com/platform/packages/modules/adb/+/1641648f2186930ee28107686e75591cd47c1cee/shell_service_protocol.cpp)。

## R3 — 固定路由、server epoch 与身份依据

**Decision**：捕获 `adbSerial + transportID + generation`，在执行socket上使用 `host:tport:serial:<serial>` 并核对返回的实际ID，再在同一socket提交命令；先检查该route的 `shell_v2` 能力。会话范围持有本地 server 观察连接，丢失时撤销该epoch、清空Shell历史并通知Workspace。所有准入检查串行于当前epoch失效处理，不自动重新建立执行连接。

Wi-Fi serial 可能只是IP:port，因此还须使用已有可信helper context验证设备身份：先固定执行socket，再通过第二条同epoch/tport tuple绑定的socket访问既有helper的 `localabstract:<socketName>`，复用HelperWireCodec/HelperFrameCodec发送identity并核对上下文，关闭验证socket后重查epoch/会话，最后通过原执行socket提交。执行socket必须一直保持；重启导致其丢失即终止本次准入。没有可信依据的Wi-Fi route明确显示Shell未就绪，不能把endpoint当物理身份。USB同样拒绝重复、缺失或改变的serial/ID。

设计反证发现现有 `verifyIdentity` 会创建forward且吞掉删除失败，跨epoch还可能用旧端口数字删除新资源。因此Shell只复用身份协议与校验，不直接复用该forward方法；新增localabstract流复用已有smart-socket边界，不创建持久端口映射。旧维护实现不纳入本次重构。[ADB服务文档](https://android.googlesource.com/platform/packages/modules/adb/+/refs/heads/main/docs/dev/services.md)说明该设备socket服务；[TCPHelperChannel](../../packages/DeviceBridgeCore/Sources/DeviceBridgeCore/Helpers/TCPHelperChannel.swift)提供现有帧格式依据。

**Rationale**：transport ID在server重启后可重用；按ID选择和另开连接查询serial有竞态。`host:get-serialno`结束该查询连接，不能声称查询后沿同socket执行。`tport`返回选中ID且保留连接，绑定更完整的tuple。

**Alternatives considered**：只用 `-t`、按名称选择、在中途改用最新route、验证后重新打开执行socket均不满足归属边界。新建ADB密钥/TLS身份或直接连接设备扩大权限，不采用。

**Evidence**：[tport服务实现](https://android.googlesource.com/platform/system/core/+/df3f38f6c9546cf3553a38d8d5dc7497c8c540f0%5E2..df3f38f6c9546cf3553a38d8d5dc7497c8c540f0/)、[官方服务文档](https://android.googlesource.com/platform/packages/modules/adb/+/refs/heads/main/docs/dev/services.md)、[transport ID分配](https://android.googlesource.com/platform/packages/modules/adb/+/f4ba8d73079b99532069dbe888a58167b8723d6c/transport.cpp)、[本地ADB parser](../../packages/DeviceBridgeCore/Sources/DeviceBridgeCore/Discovery/ADBDeviceParser.swift)、[现有helper验证](../../packages/DeviceBridgeCore/Sources/DeviceBridgeCore/Supervision/AndroidConnectionTransport.swift)。

**Qualification gate**：来源只证明机制存在；fake server须覆盖epoch事件、同tuple复用、选中后断连，实际37+工具须验证支持与Wi-Fi身份顺序。未通过不开放相应Shell路径。observer只能报告已观察到的断连，不宣称能在零时间内感知所有物理变化；归属还必须依赖固定socket及身份验证，不能仅靠observer布尔值。

## R4 — 一个operation map区分失效与清理

**Decision**：现有 Store map的记录增加phase，只有Shell失效后保留为draining；发布IDs为active记录的派生集合。finish/清理确认才移除记录。新增当前route健康观察准入，排他恢复仍等待完整map为空。

**Rationale**：现有 `invalidateOperations()` 清空map，但外部资源可能仍在关闭；若把它当清理结束，会提前运行下一条或迁移route。原有维护tick又会在任何operation期间全部跳过，30秒Shell不能宣称维护仍持续。

**Alternatives considered**：第二份ShellLease表会重复同一执行的生命周期；所有操作改成通用状态机扩大回归范围。只针对Shell保留draining，旧文件传输等维持原行为。

**Evidence**：[Store](../../packages/DeviceBridgeCore/Sources/DeviceBridgeCore/Session/DeviceSessionStore.swift)、[维护入口](../../packages/DeviceBridgeCore/Sources/DeviceBridgeCore/Supervision/ConnectionMaintenance.swift)、[维护回归](../../packages/DeviceBridgeCore/Tests/DeviceBridgeCoreTests/ConnectionMaintenanceTests.swift)。有helper的现有probe可能临时创建forward并查询身份，因此健康并行分支不能直接调用整个旧probe；采用弱语义只读get-state，并保留身份核验独立性。

## R5 — 固定查询的信息源和真实单位

**Decision**：Android按字段allowlist读取属性及固定只读命令，避免收集完整属性库。屏幕使用 `wm size/density` 原始与覆盖值；CPU使用系统实际报告的架构/核心范围；RAM使用 `/proc/meminfo`；存储用 `/data` 所在文件系统；电池读level/scale及已提供值。可选数据缺失不推导宣传规格。

**Rationale**：显示dpi不是面板PPI，data volume不是标称闪存，battery unknown不是0%。`ro.soc.*` 等厂商键不是所有Android版本都提供。每个类别独立解析、保留查询时间/来源和错误。

**Alternatives considered**：型号数据库、截图推算分辨率、完整 `getprop`/`dumpsys` 报告自动留存均不符合按需与准确边界。可使用固定批量查询降低启动开销，但不得拼接设备返回值形成新命令。

**Qualification gate**：参数与输出键需在实现首片读取授权设备的只读样本并对比官方/系统基准；未验证键作为可选，未知字段不伪造。详见[信息契约](contracts/device-information.md)。

## R6 — CoreDevice基础与runner扩展独立

**Decision**：基础走专用JSON详情文件，核对identifier/稳定UDID，区分查询完成时间与未知的设备源更新时间；runtime只在已有认证runner可用时尝试，不等签名构建，不激活应用。

**Rationale**：Apple安装的 `devicectl device info details --help` 明确“连接取数失败时返回best available information”，exit0不是新鲜度证明。现有parser有name/marketingName/osVersionNumber/udid的使用证据；productType/serialNumber/osBuildUpdate等额外键在本轮无实际JSON证据，必须先验证可选映射。

**Alternatives considered**：只用CoreDevice不能承诺屏幕与运行时参数；用runner覆盖设备名称不正确，iOS16+ `UIDevice.name` 默认可能是泛称；私有MobileDevice查询和机型查表不采用。

**Evidence**：[现有CoreDevice解析](../../packages/DeviceBridgeCore/Sources/DeviceBridgeCore/Discovery/CoreDeviceParser.swift)、本机help只读结果、[UIDevice.name](https://developer.apple.com/documentation/uikit/uidevice/name)。

## R7 — iOS公开运行时字段和版本边界

**Decision**：新增可选 `device.info`，复用现有内容槽、deadline、nonce/requestID校验及Stop/heartbeat通道。物理pixels来自nativeBounds；逻辑points使用有明确方向的同屏幕坐标；scale/nativeScale分列；最大刷新率按maximumFramesPerSecond标注。RAM/核心数用ProcessInfo，数据卷用同次普通volumeTotalCapacity/volumeAvailableCapacity；battery监测状态在读取后恢复。

**Rationale**：`hw.machine`是型号标识而非CPU架构；`os_proc_available_memory`是应用分配额度而非系统可用RAM。未公开的芯片市场名、当前可用RAM、电池温度/电压等明确不可用。UIKit没有合适screen时不为查询而切换前台。

新host容忍旧runner缺少可选action；旧host的allowlist可能拒绝新action，因此不承诺双向兼容，host/runner必须配套打包。

**Evidence**：[nativeBounds](https://developer.apple.com/documentation/uikit/uiscreen/nativebounds)、[UIScreen](https://developer.apple.com/documentation/uikit/uiscreen)、[physicalMemory](https://developer.apple.com/documentation/foundation/processinfo/physicalmemory)、[batteryLevel](https://developer.apple.com/documentation/uikit/uidevice/batterylevel)、[volume容量](https://developer.apple.com/documentation/foundation/urlresourcevalues/volumeavailablecapacity)、[应用额度定义](https://developer.apple.com/documentation/os/os_proc_available_memory)、[现有握手](../../packages/DeviceBridgeSecureChannel/Sources/DeviceBridgeSecureChannel/IOSRunnerIdentityHandshake.swift)。

磁盘空间API属于Apple required-reason API。本次面向本机开发签名runner；若未来改变分发范围，应另行核对实际使用及跨设备展示限制，不能在计划中随意声称某个隐私理由代码适用。当前不增加公证、商店分发或证书流程。

## R8 — 保留共享iOS通道取消语义并诚实更新UI

**Decision**：通道逻辑进入closing时，由捕获session+runner identity的窄失效事件通知Workspace；先撤销扩展、剪切板及截图就绪状态，物理清理及pending请求结果随后完成。事件不得等metadata返回结果，因为现有shutdown会先await TLS/endpoint清理。busy/未协商能力不触发这一失效。

**Rationale**：当前 `IOSRunnerChannel.perform` 的取消处理关闭共享channel。只取消信息UI会导致其他能力仍显示ready，直到10秒heartbeat才发现；迟到失效通知又不能清掉新runner。

**Alternatives considered**：单请求cancel/drain/tombstone协议或第二条metadata通道都会增加并发状态与资源owner，本轮不采用。不能通过过滤取消任务中的清理回调掩盖问题。

**Evidence**：[channel](../../packages/DeviceBridgeCore/Sources/DeviceBridgeCore/Helpers/IOSRunnerChannel.swift)、[server](../../packages/DeviceBridgeSecureChannel/Sources/DeviceBridgeSecureChannel/IOSRunnerSessionServer.swift)、[Workspace失效](../../apps/macos/DeviceBridgeApp/ViewModels/WorkspaceViewModel.swift)。

## R9 — 信息查询确实需要有界宿主执行

**Decision**：Shell走socket；CoreDevice等固定信息命令仍用HostCommandRunning接口，但先用反例测试保护，再修正其截止时间覆盖与两路资源清理。

**Rationale**：当前超时竞争在进程退出后结束，随后无限等待stdout/stderr EOF；子进程继承FD可使其永远不返回。仅SIGTERM亦无法终止忽略该信号的进程。此依赖会违反SC-002，因此不能只给provider传一个timeout就宣称总预算成立。

**Alternatives considered**：新增第二个通用进程runner会复制同类生命周期；假设可信工具永不挂起不能满足契约。保留现有API和正常输出语义，仅补齐截止时间、单次完成及owned-child清理，先跑旧覆盖再实施。

**Evidence**：[HostCommandRunner](../../packages/DeviceBridgeCore/Sources/DeviceBridgeCore/Commands/HostCommandRunner.swift)、[现有测试](../../packages/DeviceBridgeCore/Tests/DeviceBridgeCoreTests/HostCommandRunnerTests.swift)。这是一项待实现验证的局部正确性修正，不是本轮已修复的问题。

## R10 — 历史和显示容量的明确口径

**Decision**：历史唯一保存命令UTF-8和原始两路Data，按合计字节执行20条/2MiB FIFO；不永久缓存完整解码String。只为当前可见输出生成合计≤256KiB UTF-8的显示前缀，超出可分页查看/显式复制完整结果，标签指出显示省略。

**Rationale**：1MiB无效UTF-8解码成replacement字符后可膨胀到约3MiB，不能按raw Data限额却无界缓存派生文本。2MiB是历史内容预算，不是整个应用RSS。协议缓冲和可见文本有独立小上限，不能藏在历史指标中。

**Alternatives considered**：同时长期保存Data与全量String增加所有权和内存。清空按钮仅清空已完成记录；当前运行项尚不在历史，之后完成是新记录，避免增加history epoch及让旧记录复活。

## 设计反证审查修订

只读独立审查发现并修订四个可达反例：旧forward清理可能删除重启server的新映射；等待metadata结果才通知会延迟撤销共享能力；CloseStdin写失败可能覆盖已缓冲的真实exit；取消撤销token后无法保存本会话cancelled终态。对应修订分别为无forward的localabstract身份流、closing时逻辑失效事件、保留读循环取得退出证据、独立于成功发布的当前会话终态资格。具体反例列入[Q1/Q3/Q5](quickstart.md)，尚待实现测试证明。

## R11 — Agent调用复用桌面应用的业务入口

**Decision**：按用户追加需求，为两个新模块提供配套JSON CLI，经本地用户私有IPC进入运行中的桌面应用；以opaque sessionKey明确归属，使用相同模块操作和结果owner。只新增有界调用ID关联，不持有第二份命令或设备状态。[接口契约](contracts/agent-api.md)定义方法、输入/输出、重复请求和断开行为。

**Rationale**：直接由CLI启动独立provider会绕过桌面当前设备、Shell互斥和失效检查；UI自动化又无法提供稳定结构化结果。薄CLI与IPC边界让Agent明确发起操作，同时保留当前生产路径。CLI从stdin读JSON，使完整命令不进入参数列表；默认只处理当前应用会话，不开放远程地址。

**Alternatives considered**：MCP适配层可以后续按明确需求增加，但首版不引入另一套工具协议/依赖；HTTP远程服务扩大范围；只暴露包内Swift方法无法让外部Agent直接使用。这里是本项目的设计取舍，不是对其他协议能力的否定。

**Validation gate**：Q6必须验证Agent/界面竞争、当前会话标识与应用重启、响应丢失/重复请求、容量及结果一致性。Agent专项只读反证审查补齐四点：epoch重新激活生成新binding UUID；信息失败/取消保留最近终态元数据；IPC最多4条连接及每帧读写5秒期限；进程生命周期独占锁确保socket单owner。详细规则已纳入接口和任务，尚待实现验证。

## 实现依赖修正 — Android 信息查询固定连接

实现前反证表明，仅对 `adb -t` 固定数字 ID 并在调用前后校验 Store，无法排除本机 ADB server 重启后 ID 复用。Android 固定信息查询因此复用 R2/R3 原生执行 socket 与 epoch/身份边界；provider 只接收已绑定 command executor，不提供 CLI fallback。T020–022 提前成为 Android 信息真机验证的前置，Shell UI/draining/history 的范围保持原计划。此修正由可达的归属反例驱动。
