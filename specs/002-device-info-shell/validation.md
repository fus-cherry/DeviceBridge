# Validation: 设备信息、Shell、Agent接口

日期：2026-09-09。分支：`codex/device-info-shell`。当前为分步实现，不代表完整功能或真机验收通过。

## Setup 与规格门禁

- 用户在Agent追加需求后回复“继续”，完成方案评审，进入tasks/analyze/implement。
- 47项任务，30项FR、9项SC均有对应任务；任务格式、路径及本地文档链接检查通过，规格质量清单16/16。没有extensions.yml，相关前后钩子不适用。
- 工作区原有README AI声明、DeviceModels两项枚举与DeviceInformation占位模型保留；无git add/commit/push/merge。既有.gitignore已覆盖Swift/Xcode、设备构建产物与本地凭据，不需改动。
- Xcode scheme已核对为macOS `DeviceBridge`、iOS `DeviceBridgeRunner`；两个项目均显式列源文件，新增文件由集成任务接入。
- Agent专项设计审查的4项反例已纳入契约/任务：epoch激活key、无报告终态、IPC全局资源、socket单owner。此处是设计改进，尚无实现测试结论。

## T002 基线

命令：`swift test --package-path packages/DeviceBridgeCore --no-parallel --filter 'HostCommandRunnerTests|DeviceSessionStoreTests|ConnectionMaintenanceTests|IOSRunnerChannelTests'`

结果：退出0，4 suites / 44 tests通过，测试执行2.637秒；编译有既有libtool无符号目标文件警告。未操作设备。

## 功能与真机状态

SC-001–009均尚未完成全量验收。后续每片在此追加准确测试命令、反例结果和设备核对，未验证项保持未验证。

## T005/T006 精确会话准入

新增两个测试覆盖：捕获设备A会话后切到B，以及同一设备重新选择导致generation变化；旧会话均须拒绝且不能产生operation。旧无expectedSession调用者仍可正常使用。

Red：新增测试首次编译失败，明确指出缺少expectedSession参数和staleSession错误；未将编译失败当成运行行为通过。实现后命令 `swift test --package-path packages/DeviceBridgeCore --no-parallel --filter 'DeviceSessionStoreTests|ConnectionMaintenanceTests'` 通过17 tests / 2 suites，测试运行0.002秒。反例在去掉原子expectedSession比较时会接纳新会话token；guard位于Store actor内，避免检查与准入间的await间隙。

## T003/T004 HostCommandRunner 有界收尾

受控旧实现反例：3 条新增测试失败、4 个断言问题，原有 8 条通过。修正后 11 条通过（0.902 秒），新增 3 条各用时 0.108 / 0.314 / 0.216 秒。总期限覆盖主进程退出后继承 FD，两个 read owner 使用非阻塞读取并在返回前 join；SIGTERM 后 200ms 仅升级终止本次 Process 对象持有的子进程。

Core 全量 `swift test --package-path packages/DeviceBridgeCore --no-parallel` 最终通过 391 tests / 57 suites（19.125 秒）。首次全量中既有 IOSRunnerPublicRecordReader fixture 时限在负载下失败，隔离 5/5 通过后全量重跑通过；没有删除安全网或清理缓存。

## T013–T016 iOS metadata 协议与通道

DeviceRuntimeInformation 新模型反例先编译失败，实现后 Protocol 7 tests 通过；SecureChannel 全包 83 tests 通过，新增 metadata 6 条覆盖内容槽/心跳/Stop/取消/严格结果。Core 通道与报告合计 29 tests / 2 suites 通过，包括取消清理暂停时先发送 logical-closing 失效、忙碌不失效、严格 metadata 成功结果。

`xcodebuild build-for-testing -project helpers/ios/DeviceBridgeRunner.xcodeproj -scheme DeviceBridgeRunner -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath artifacts/device-info-ios-build CODE_SIGNING_ALLOWED=NO` 退出0（arm64/x86_64）；第一次发现 uname tuple 独占访问编译问题，取 byteCount 后已修正。5 条 UIKit adapter XCTest 已编译但未执行，不据此勾选 T015 完整验证。未启动/安装模拟器或真机。日志 `/tmp/device-info-ios-build-final.log`。

## T017 信息呈现反例（进行中）

新无窗口检查首次 typecheck 明确失败：缺少 DeviceInformationViewModel。检查覆盖同步 UI/Agent 准入、保留旧时间、取消晚到成功拒绝、失败终态无旧 reportID、10 次会话切换及错误报告归属。尚待实现后执行。

## 信息模型与工作区接入

T007/T008 原始报告4 tests及Shell历史4 tests，使用SwiftPM真实静态Core产物与原测试文件链接Swift Testing runner运行，8 tests / 2 suites通过（0.021秒）。覆盖非法数字、超长字段、报告64KiB、重复fieldID、来源时间、完整复制及分组语义。

T011/T012 CoreDevice/provider原13 tests以同样方式真实运行通过，含identity/scope/缺失键/文件权限/符号链接/期限/取消/清理失败/runtime未就绪。完整SwiftPM target当时被其他新测试的缺实现RED阻塞，未将typecheck冒充执行。日志 `/tmp/ios-device-information-focused-tests.log`。

`scripts/check-device-information.sh` 退出0：同步UI/Agent互斥、未读取/部分报告、刷新保留旧时间、取消清理、失败metadata不关联旧reportID、10次切换竞态及外来report拒绝。`scripts/check-ios-runner-workspace.sh` 退出0：新增metadata真实生产集成fixture + 全部原检查，验证CoreDevice名称、runtime合并、未自动读取、bindingLost在metadata continuation仍挂起时撤销截图/剪贴板、取消后不替换旧报告。初次缺少新observeCurrentRoute fixture实现及HelperAction拼写，已按实际API修正并复跑通过。

macOS `xcodebuild build -project apps/macos/DeviceBridge.xcodeproj -scheme DeviceBridge -configuration Debug -derivedDataPath artifacts/device-info-macos-build CODE_SIGNING_ALLOWED=NO` 退出0。只是编译，不是实际设备或界面交互验收。此时Android production固定连接尚待接入，因此T018/T019未标完成。

## T023/T024 单map与维护

3个真实旧行为反例先RED：第二条Shell被接纳、Shell运行时inventory自动换route、旧token删除复用UUID的新session操作。实现后旧反例GREEN；另发现draining期间重复disconnect递增generation，新增RED后修正。

使用完整Core静态产物链接原Store/Maintenance/AndroidTransport/MemoryMonitor四份测试文件，46 tests / 4 suites通过（2.731秒）。其中Store/Maintenance两文件30 tests，新增13项；实际AndroidConnectionTransport携带trusted helper context仍只发get-state，不创建forward。日志 `/tmp/devicebridge-store-maintenance-full-green.log`。

## Shell呈现与历史（T026/T032/T033）

`scripts/check-android-shell.sh` 最终退出0：输入不自动执行、UI/Agent单入口、原始命令保留、取消期间互斥、清空历史后未来完成可入库、10次切换与清理竞态。首轮暴露同session重新激活时draining旧操作仍被currentOperation呈现；新增phase隔离后复跑通过。

原始4个history tests通过：20/21 FIFO、2MiB、1MiB无效UTF8派生显示受256KiB限额、跨页合法多字节完整拼接、exit255与未知区分。显示页只派生两路各32KiB原始切片，原始Data为唯一长期载荷。窗口交互/真设备Shell尚待Q4/Q5后续核对。

## 集成自动化与独立审查（2026-09-09）

- 完整 Core：`swift test --package-path packages/DeviceBridgeCore --no-parallel`，498 tests / 67 suites，通过，运行24.720秒。Protocol 7 tests / 2 suites，通过；SecureChannel 83 tests / 10 suites，通过，运行14.040秒。该轮在最后 IPC 压力修订之前，后续单独记录修订后的复验。
- 原生 ADB 固定连接及帧21项测试通过。独立假server反例先暴露握手期间close后迟到epoch重新生效、1MiB后的首个越界字节等待整帧导致误报timeout，两者已修正并用当前真实源码复验。并发begin共享同一observer/epoch。
- 真实 App binding 的同会话取消反例：旧实现把Task取消误判binding失效，丢弃cancelled终态；取消检查从身份谓词移除后复验通过。取消仍由Service/VM明确仲裁，不因身份谓词放开而允许提交。
- Workspace 独立新读者检查暴露准备期间observer回调丢失：最后isCurrent返回true之后、MainActor发布ready之前失效。改为preparing/ready单一owner，在await前登记、回调与发布按同一ID核对。受控交错中旧规则ready=true，新规则ready=false；此夹具抽取了Workspace所有权交接规则，不冒充整应用实测。
- `check-device-information.sh`、`check-android-shell.sh`均退出0；新增切换到另一设备、断连、同会话取消、同设备重建四种场景各10次（每模型40次），无旧报告/输出发布、取消后成功或自动重放。原有刷新时间、失败metadata、UI/Agent互斥与历史检查保留。
- `check-device-selection.sh`、`check-workspace-inventory.sh`、`check-ios-runner-workspace.sh`、`check-workspace-modules.sh`、`check-image-view-model.sh`退出0。前者仍使用既有fixture，没有向设备发送命令；信息与Shell模块源文件均接入真实编译依赖。
- `check-ios-images-workspace.sh`编译通过，但其执行入口要求指定真机和图片内容opt-in，退出2并明确拒绝。本轮不读取相册，因此未提供该opt-in，不能标作真机图片回归通过。
- `check-agent-api.sh`退出0：真实Controller/VM成功信息报告、operationID/session身份、ISO8601日期、四种原始tag、失败终态、旧key、实例/epoch重建、128项关联、FIFO失效、重复请求不重放和UI互斥。stdout含0xff/NUL且exit255，base64回解逐字节相同。
- Agent集成使用唯一临时目录上的真实Unix IPC Server→Client→Controller→VM，覆盖五个方法及cancel cancelling→cancelled。未绑定默认endpoint；不会自动启动应用或选择设备。
- 独立Agent响应检查验证1MiB结果在脱离MainActor编码时撤销key；旧实现会返回旧success，新增编码后key复核后返回staleSession。
- `python3 -m unittest scripts/test_release_bundle.py scripts/test_helper_packaging.py`：20 tests，19通过，1个明确opt-in签名检查跳过。CLI精确bundle路径、可执行位、arm64及symlink逃逸等打包契约验证通过；未制作实际Release。

## 实际窗口检查（fixture，非真机证据）

通过新Debug应用的 `--fixture-devices --ui-testing` 模式，在独立语言偏好域操作：显式读取后出现部分报告；Android Shell输入及回车只增加文字/换行；⌘Return产生单条结果；填入历史未新增执行，清空历史移除结果；切换iPhone自动回到信息模块且无Shell卡片。1100×720窗口截图可读。中文检查发现Completed、Device、Platform等漏译，已补齐；固定状态值采用按fieldID白名单翻译，设备原文不翻译。

工具的坐标拖动窗口两次返回noWindowsAvailable，未据此声称800×600验收通过；AX读取、按钮与文本输入仍成功。UI反馈200ms和长字段/窄窗口尚待独立测量，fixture快速结果不代表真实耗时。

窗口复验补充：普通build与多份历史app共用bundleID，坐标API无法唯一定位。改用仅测试产物的独立bundleID后，同一当前源码窗口成功调整到 **800×600**。英文信息页读取/刷新/复制按钮可见；中文信息标题/字段/状态均正确。中文Shell超16KiB显示拒绝原因且按钮禁用；恢复多行输入后⌘Return执行一次，结果显示“已完成”、fixture耗时、完整已执行命令、分离的两路输出；上下滚动可到达核心操作。控件独立accessibilityIdentifier不再被容器覆盖。截图为fixture数据，不是Android真实输出。此前坐标失败不再阻断窄窗口验证。严格200ms反馈采样仍未验证。

规格核对发现的本地呈现缺口均已补齐：输入校验原因、完整命令与耗时、notStarted的已有failure、取消/清空语义、Android当前旋转未查询说明，以及不同失败原因的刷新/访问限制建议。这些修改不新增执行路径。

## IPC 压力恢复与最终包检查

- 在隔离子进程同时设置软/硬RLIMIT_NOFILE=64，保持触发客户端连接，直接捕获当前源码的accept errno 24（EMFILE）；释放压力后旧代码请求仍超时。只设置软限额的早期夹具在本机可临时超过限制，未将其假通过当成证明。
- 修复将EMFILE/ENFILE作为暂时资源不足，以可取消100ms间隔重试；其他接收循环终止先关闭client/listener，再按自身inode清理endpoint并释放锁，避免自等待。移除重试分支的临时副本再次RED，当前14项IPC测试GREEN，独立审查复核通过。
- 测试使用Swift Testing原生子进程隔离，父进程限额未改变。早期手工重启测试二进制在xctest宿主下出现.closed，已替换；没有通过弱化断言规避失败。
- 最新完整Core为 **500 tests / 67 suites，全部通过，23.360秒**；`check-agent-api.sh`在该版本上再次通过真实临时IPC→Controller→ViewModel链路。
- 最新macOS Debug build和iOS Simulator `build-for-testing`均退出0。iOS的5项UIKit adapter测试仅编译，未安装/启动模拟器或真机执行。Debug项目补齐DEBUG编译条件，使已构建开发CLI的绝对路径可在调用说明中显示；Release只显示已打包可执行文件。

## 实际设备门禁：本轮未通过

在已有ADB server上，仅发现一台已授权USB Android（型号PLD110，transport 5）。只读独立harness使用当前App binding、Store、固定native executor及provider，无helper安装、forward或server重启。日志只保留脱敏状态和长度。

- epoch握手5.8ms；10次信息读取全部无设备数据，分别约20.99–21.33秒后失败，**0/10**形成报告。故SC-001/002没有通过。
- 六类只读Shell（普通输出、两路exit7、exit255、true、多行管道、read EOF）全部在约10.37–10.63秒后timeout，没有输出或确认退出码，不能声称SC-004通过。
- 本地取消返回0.0ms、连接清理0.2ms，结果cancelled且没有退出码；但没有证明远端sleep已开始，不能代替“正常稳定设备连接”下的SC-006验收。
- 独立系统CLI `adb -t 5 shell true` 与 `adb -t 5 shell -T -n true` 均5秒超时；`get-state`约19.7ms返回device、`features`约13.2ms包含shell_v2。现有证据说明列表/能力查询成功不能代替Shell可用性，具体根因尚未定位；没有修改或重启ADB/设备来绕过。
- 原生期限出现约5%超时宽限，已另立本地计时反例核对，结果在下方续记。真实ADB无有效数据的结论与计时问题分开记录。
- CoreDevice列表只有配对记录：三台tunnel unavailable、一台disconnected，没有可用iPhone链路。iOS逐字段核对和10次采样未执行；不会把缓存列表或fixture作为真机报告。

脱敏物理记录：`/tmp/device-info-android-physical.log`。本地App源码和文档可以审查，真机门禁未通过前不发布本功能。


## 最终验证与 SpecKit 收敛（2026-09-09）

- 最终顺序验证进程退出0：Core **502 tests / 67 suites，26.664秒全部通过**；macOS Debug `xcodebuild` 显示 BUILD SUCCEEDED；`scripts/check-agent-api.sh` 再次通过实际隔离IPC路由、载荷保真、会话key、重复请求不重放、UI互斥、取消清理、淘汰及128项上限。该结果取代上方500项的中间快照；其余Protocol 7项和SecureChannel 83项的既有完整通过结果仍有效。
- 日志分别为 `/tmp/device-info-core-final.log`、`/tmp/device-info-macos-final.log`、`/tmp/device-info-agent-final.log`；日志是本机临时证据，不作为仓库可移植产物。
- 新增的两个Core回归测试：`heldSocketDeadlineIsPromptAndClean` 保持socket无响应并三次测量1秒截止时间，旧默认容差的中位超限26.41ms使测试失败；显式零容差后通过，同时检查连接终止。独立计时探针观察到默认容差约5%的调度宽限，零容差减少该宽限；这不保证操作系统实时调度，也不证明真机读取成功。`initialTimeoutKeepsItsCause` 保护初始查询超时仍显示timedOut，旧实现错误映射noDeviceData；没有返回任何数据的普通失败仍保持原有语义。
- 收敛覆盖30项FR、9项SC、27个用户故事验收场景、16个计划源码边界、6个交付切片、5项章程原则及6个质量门禁。发现missing 0、partial 3、contradicts 0、unrequested 0；严重度HIGH 2、MEDIUM 1。该计数表示本轮检查发现的问题，不把缺少物理证据解释为已满足全部要求。
- `speckit-converge`只向tasks末尾追加Phase 9的T048–T050，未修改规格、方案或代码。收敛结束后，普通进度记录将T047标完成并同步本README/validation。当前42/50项完成；T015/T019/T028/T042/T044以及新T048–T050未完成，新任务聚合追踪前五项的剩余证据。

| 成功标准 | 最终状态 | 证据与剩余内容 |
| --- | --- | --- |
| SC-001 | 未通过真机门禁 | Android未形成报告；无可用iPhone；字段fixture通过不能代替逐字段基准核对。 |
| SC-002 | 未通过真机门禁 | Android10次读取0次成功；iPhone未采样。本地截止时间回归已通过，修复后真机性能尚未复验。 |
| SC-003 | 未验证 | 实际窗口流程可操作，严格200ms反馈与1秒响应目标尚未采样。 |
| SC-004 | 未通过真机门禁 | 五类协议fixture通过；真实Shell均超时，无实际输出/exit证据。 |
| SC-005 | 自动化通过 | 信息和Shell各自四类受控竞态、各10次，无错配、取消后成功或自动重放。 |
| SC-006 | 部分 | 受控清理与保持busy通过；真机取消不能证明远端命令已开始，仍需正常执行链路采样。 |
| SC-007 | 自动化通过 | 输入、输出、20条历史和2MiB总量边界及可辨认反馈通过；不等同RSS上限。 |
| SC-008 | 部分 | 双语、键盘、800×600实际窗口和相关无设备检查通过；长名称/字段、Agent来源实际窗口与需设备opt-in的图片回归仍未全部验收。 |
| SC-009 | 部分 | 真实隔离Unix IPC→Controller→VM五方法和错误/竞态保真通过；Android/iPhone实际读取与命令链路未完成。 |

剩余任务集中于T048 Android、T049 iOS、T050界面实测。无需重新拆分已完成代码；具备相应设备条件及执行授权后，继续`speckit-implement`完成验收，按证据定位修复，再运行收敛检查。未提交、推送、安装、制作或发布本功能Release。


## 继续处理剩余项（2026-09-09，17:20 后）

用户要求继续处理剩余问题。本轮沿T048–T050推进；设备重连及安装/启动测试仍单独请求授权，不能将未回复当作同意。

### Android：服务握手故障定位

- 当前授权USB Android为PLD110，ADB37.0.1/build15733141，transport5。主机版本/功能/列表/状态查询约0.06–1.82ms返回；独立`get-state`约9ms，不能据此认定远端Shell可用。
- 用独立smart socket选中transport5，约0.06ms收到OKAY；发送`shell,v2,raw:true`后3001ms仍未收到服务状态。legacy Shell及exec只读探针也在服务ACK前超时。因此不能将故障归因于应用的Shell-v2帧解码，也不能凭此断言具体是USB还是adbd。
- 挂起请求期间对现有服务器做1秒只读采样：主线程等待fdevent，USB读取线程等待ReadPipe，没有采到主机忙循环。证据 `/tmp/device-info-adb-pending-sample.txt`；未停止任何既有进程、重启服务器或修改设备。
- 在隔离临时本地假服务器捕获实际ADB客户端请求，`-t 5 reconnect`发送`host:version`及`host-transport-id:5:reconnect`。官方处理路径选择单一transport再kick，与全局server重启不同：[AOSP adb.cpp](https://android.googlesource.com/platform/packages/modules/adb/+/refs/heads/main/adb.cpp#1535)。真实重连尚未执行；已请求仅重连当前OPPO的授权。T048仍未完成。

### iPhone：补齐有真实来源的字段

当前iPhone12（iOS18.3.1）已可通过CoreDevice访问，配对且localNetwork隧道connected。此前“无可用iPhone”的记录为上一轮状态，本轮基础读取已恢复；未将已安装runner的版本元数据当作当前运行或已认证的证明。

实际JSON提供的`osBuildUpdate`、`productType`、`cpuType.name`及`supportedCPUTypes[].name`原先没有映射。按真实结构脱敏成fixture后，新增回归测试先出现41处预期断言失败，证明字段遗漏；现在映射为系统构建号、型号标识、CPU架构和支持架构列表。未知CPU名字保留原文，不从型号推算；`internalStorageCapacity`不充作数据卷容量，也没有增加额外序列号采集。

- 缺键/null标记notReturned，错误类型/不完整CPU列表/超限标记invalidData；没有扩展runtime时保留CoreDevice型号标识，认证runtime返回后用其live值替换；CoreDevice来源仍为possiblyCached，sourceTime保持nil。
- 最终`swift test --package-path packages/DeviceBridgeCore --filter IOSDeviceInformationTests`：**16/16通过，2.098秒**。日志 `/tmp/device-info-ios-optional-final.log`；RED `/tmp/device-info-ios-optional-red.log`。只改provider字段解析与针对性测试，未改会话/取消的编排路径。
- 当前源码的macOS Debug应用重新构建退出0、BUILD SUCCEEDED；日志 `/tmp/device-info-macos-resume.log`。当前物理iOS unsigned build-for-testing也成功；日志 `/tmp/device-info-ios-physical-build.log`。构建不代表设备测试已运行。

### iPhone：最终基础读取与真实CLI验收

最终采样时间2026-09-09 09:33:02–09:33:08 UTC；日志 `/tmp/device-info-ios-final-live.log`，临时harness `/tmp/device-info-ios-live.swift`。

- 10/10返回部分报告，耗时秒：2.317、0.426、0.354、0.312、0.489、0.312、0.322、0.442、0.393、0.331；最小0.312、中位约0.373、最大2.317、平均0.570。所有10次均低于10秒；这是iPhone基础报告门禁，不是Android或runtime准备后的完整报告证据。
- 每份报告14个字段可用、38个有明确不可用原因。9个CoreDevice字段与独立同设备JSON逐项相符：设备名/UDID仅本机比较，其他为iPhone12、iOS、18.3.1、22D72、iPhone13,2、arm64e以及`arm64e, arm64, unknown-12-13`；另5个连接字段与捕获的会话、路由和采集时间相符。未把可能缓存的数据标成实时采集。
- 16个运行时字段明确runtimeNotReady，22个当前平台未支持字段保留unsupported，没有用0补齐。没有活跃的UITests runner；已安装bundle版本不足以证明当前源码、capability或认证链路。
- 使用真实当前`devicebridge-agent`子进程，经默认Unix IPC→Controller→ViewModel→Service/Store→真实CoreDevice provider验证读取/查询、结构化报告归属、重复请求去重和invalidate后的staleSession；成功exit0、错误exit1。默认endpoint事先检查无活动owner，完全使用既有AgentIPCServer锁及正常stop释放；没有启动正常应用，旧目录/lock保留，结束后socket不存在且lsof无owner。
- 日志中一条沿用旧隔离harness的“no app default endpoint”文案不准确，末尾已明确纠正；最终运行确实使用默认endpoint和真实CLI。不能将早期Client直连当成实际CLI调用。

5项UIKit adapter测试仍仅编译；精确的Simulator `test-without-building`调用已经准备，限定`DeviceInformationCommandsTests`，不运行RunnerSmokeTests。已请求启动本机iPhone17Pro模拟器并安装/运行这两个测试app的授权，尚未执行。真实iPhone运行时扩展参数及设备侧失效验收也未完成；T015/T049保持未完成。


### macOS 窗口剩余验收：T044/T050完成

使用当前生产WorkspaceView、信息/Shell View及ViewModel的隔离临时fixture应用，替换测试数据与可控挂起服务，在800×600窗口通过CUA实际输入。没有修改仓库界面代码，也没有启动正常应用、默认IPC或真实设备命令。证据目录 `/tmp/devicebridge-ui-qualification`，临时入口 `src/QualificationMain.swift`，完整分阶段记录 `timing.log`。测试进程已退出，主代理按进程可执行路径复核为0个。

计时从真实NSEvent的单调时间戳起，包含事件排队和反馈状态的布局/绘制及缓存位图生成；主代理独立核对了统计与“Reading… / Running… / Cancelling…”目标像素。缓存位图缺少部分WindowServer合成层，故计时明确表示**目标反馈像素就绪**，不声称测到物理屏幕扫描输出；完整外观另用正常CUA窗口截图核对。

| 动作 | 有原始事件的样本数 | 最大事件→目标像素就绪 |
| --- | --- | --- |
| 信息读取 | 4 | 83.892ms |
| 信息取消 | 3 | 90.928ms |
| Shell运行 | 2 | 71.698ms |
| Shell取消 | 1 | 62.300ms |

以上有效样本均低于200ms；小样本不表示任意负载下的性能保证。另有读取4次、信息取消4次及Shell取消1次AX调用没有可靠原始事件，仅保留handler→像素时间，不能混入总输入延迟统计；其中Shell取消193.103ms。

先前默认RunLoop模式计时器及同步OCR阶段出现约3.024秒间隔，保留为未归因的探针受干扰记录，既不认定应用卡顿，也不删掉后当作通过。区分测试使用`.common`模式5ms计时器，并在持续输入/模块切换段明确关闭位图/OCR：81个实际keyDown对应81字符，事件→输入处理最大87.490ms；10次模块切换（各5次）经AX确认，事件→处理最大10.754ms。该段完整日志没有任何>200ms的GAP记录；此前common-mode但仍含采样负载的累计最大间隙738.735ms另记，未混入该段。草稿保留且历史为空，无隐式执行。

正常窗口截图另确认：217字符设备名可换行；750-byte指纹尾部`END-FINGERPRINT`在中英文均可到达；Agent来源中英文可见，未覆盖草稿；522,010-byte stdout能从第一页切换到第二页，HTML/ANSI内容按普通文本呈现，完整复制提示可见。结合上一轮双语、键盘、16KiB输入拒绝及最小窗口证据，T044/T050完成。没有重验需要真实图片内容opt-in的旧图片回归，因此不把SC-008的所有既有真机路径一并标通过。

### 本轮结束状态

- T044/T050补齐；当前**44/50任务完成**，未完成为T015/T019/T028/T042/T048/T049。新收敛任务聚合追踪旧任务，六个未勾选项不表示六个独立代码缺陷。
- 已修复iPhone四项有实际来源的字段遗漏；iPhone基础10次读取、实际CLI与针对性16项测试、macOS重建通过。SC-003本机窗口测量完成；SC-001/002/009的iPhone基础部分得到真机证据，整体仍受Android与iOS runtime限制。
- Android仍卡在远端服务ACK前；一次仅针对当前OPPO的reconnect授权尚未收到，未执行。5项UIKit测试的模拟器启动/安装/运行授权尚未收到，未执行；真实iPhone runtime仍未验收。没有因等待授权而继续发起相同设备超时批次。
- 未提交、推送、安装、发布，也未重启ADB server。下一步先处理已提出的两项授权，再按实际恢复结果推进剩余设备门禁。


## 用户授权后的执行结果（2026-09-09 17:53–17:54）

用户回复“允许执行”，明确授权此前提出的两项动作：仅重连当前OPPO的ADB传输，以及在本机模拟器安装/运行5项UIKit测试。授权不扩大为全局ADB server重启或真实iPhone安装。

### Android 定向重连

- 执行前重新核对同一授权OPPO的USB route及transport5，执行`adb -H 127.0.0.1 -P 5037 -t 5 reconnect`退出0，返回reconnecting。未请求kill-server，未停止其他进程。
- server日志记录旧transport重置及USB handle重新打开；新transport6持续为offline，没有恢复设备握手。后续只读状态复核仍offline，因此没有继续提交Shell命令或重复跑20秒超时批次。定向重连未解决故障；仍不能确定是USB链路还是设备adbd。
- 已请求用户重新插拔该手机USB并保持解锁，必要时确认手机上的USB调试授权，等待实际恢复后继续验收。
- 当前源码只读harness已重新编译为`/tmp/devicebridge-physical-readonly/bin/physical-readonly-harness-resume`（退出0），链接当前Core archive及当前App AndroidDeviceCommandBinding；尚未在offline设备上运行。此前旧快照harness的测量不会作为新版本通过证据。

### UIKit 适配测试实际执行

执行已准备的`xcodebuild test-without-building`，仅选择`DeviceBridgeRunnerUITests/DeviceInformationCommandsTests`；目标为iPhone17Pro、iOS26.5 arm64模拟器。

- **5/5通过，0失败、0跳过**；xcodebuild退出0，TEST EXECUTE SUCCEEDED。xcresult summary独立确认totalTestCount=5、passedTests=5、failedTests=0、skippedTests=0。
- 覆盖已开启电量监测保持原状、取消请求不采样、过期/非法请求不采样、px/pt固定竖屏语义、未知电量为null且恢复监测开关。测试套件约0.666秒，Xcode整次操作约39.147秒。
- 模拟器起始Shutdown，测试期间Booted，结束状态独立复核为Shutdown。显式收尾shutdown返回alreadyShutdown，未将此退出码误报为测试失败，也未停掉其他模拟器。
- 证据：`/tmp/device-info-ios-adapter-execution.log`、`/tmp/device-info-ios-adapter-summary.json`、`/tmp/device-info-ios-adapter-execution.xcresult`。没有执行RunnerSmokeTests或真实iPhone安装/启动。

T015现在完成。当前**45/50任务完成**；T019/T028/T042/T048/T049保持未完成。iPhone基础信息和CLI已有上一节的真机通过证据，UIKit adapter现在实际通过；真实iPhone已认证runtime字段/设备侧失效仍未验收。Android仍待USB调试连接恢复。未提交、推送或发布。


### 再次检查 Android（用户回复“再试试”，2026-09-09 17:58）

USB事件日志确认17:57:42断开、17:57:46重新打开；同一OPPO的transport由6变7。首次查询及随后15秒内6次直接smart-socket只读查询均为offline，设备握手没有恢复；5038上的另一ADB服务未列出该OPPO。没有向offline设备提交Shell，也没有再次重连或重启服务器。

下一步候选为只重启127.0.0.1:5037的ADB服务（当前PID60993），保留5038的独立服务（PID48658），再核对同一设备并运行最小只读命令。此前授权只覆盖单设备reconnect，不包括server重启；该动作尚未执行，需另行确认。任务状态仍45/50。


### 5037 服务重启后的复核（用户回复“允许”，2026-09-09 18:02–18:05）

用户明确授权重启5037上的ADB服务后复测。旧服务已退出；期间MobAI自带ADB 36.0.0自动占用5037，使用LIBUSB后端，设备曾短暂不在列表。macOS的IOUSB完整属性仍能识别同一台OPPO，不能将ADB列表为空解释为USB物理断开。

启动命令携带显式回环地址时被ADB判为remote host，启动退出255；随后用SDK ADB的`-P 5037 start-server`紧接kill-server执行，启动退出0。最终server-status确认5037运行SDK ADB 37.0.1、NATIVE后端及原有密钥路径。连续6次只读查询仍为offline；因此未运行设备信息或Shell验收批次。5038独立服务未停止、未重启。

结论：已完成授权的5037服务重启并恢复原SDK服务，但Android调试握手仍未恢复。当前证据不足以判定手机adbd、USB接口或主机侧的具体根因。下一步需要在手机侧重新开启USB调试、保持解锁并处理实际出现的授权提示，再复核；没有撤销调试授权或重置密钥。任务仍45/50，Android真机及真实iPhone runtime剩余验收不标通过。未提交、推送、发布或安装真实设备应用。


## OPPO 恢复在线后的真机复验（2026-09-09 18:08–18:17）

用户再次回复“你再试试”。同一USB OPPO已为device（transport3）；没有再次重连或重启server。独立SDK CLI `true`退出0，stdout/stderr/exit7基准精确通过，分别约57ms/113ms。恢复发生在手机侧操作请求之后，不能据此认定此前故障的唯一根因。

### 真实返回值暴露的两处字段遗漏

第一轮当前源码10次信息读取成功（1.292–1.712秒），但型号及三项存储容量显示notReturned。独立CLI确认：marketname为空而model为PLD110；`df -k /data`返回挂载点`/data/user/0`。旧实现分别在空字符串处停止fallback、只接受挂载点完全等于/data，因此遗漏实际存在的值。

新增两个回归测试，旧实现12项中2项失败、共4个断言失败；修复仅在marketname为空时回退model，并接受/data/下的挂载点，仍拒绝/database等无关路径。原有数值合法性和溢出检查保留。修复后AndroidDeviceInformationTests **12/12通过**；macOS Debug重新构建BUILD SUCCEEDED。没有改动状态机或查询allowlist。

### 修复后的真实provider、原生Shell与CLI

重新构建Core静态产物，并以当前App AndroidDeviceCommandBinding及当前两个ViewModel/AgentAPIController编译临时harness；捕获同一USB route，直接访问真实手机。它不是正常应用窗口，也没有自动准备helper。

- 信息读取 **10/10通过**，全部低于10秒；最小1187.6ms、中位1680.65ms、最大1714.5ms。52字段中45项可用，剩余字段保留具体限制。型号PLD110、总容量239493771264 bytes已恢复。
- 独立SDK CLI执行22条固定只读基准，不读取完整属性库或私有序列号。制造商/品牌/型号/product/device、系统版本/API/补丁/build/fingerprint、SoC/架构/ABI、内核、1080×2400及480dpi、8核、总RAM和总容量逐项核对；无覆盖值的显示与基准一致。动态值分别留采样：可用RAM2798022656→2802454528 bytes；存储已用40381624320→40381665280 bytes、可用198977929216→198977888256 bytes；电量80%、29.9°C、4192mV、放电及Battery来源一致。动态值差异没有被当作解析错误。
- 原生Shell六项只读输入精确匹配stdout/stderr与真实0/7/255退出；多行管道及stdin EOF通过。第七项sleep10取消无退出码，调用反馈约0.0ms、清理0.2ms；truncated=true表示取消结果不完整，并非正常完成。
- 真实`devicebridge-agent`独立子进程以stdin/stdout JSON经默认Unix IPC→Controller→ViewModel→Service/Store→真实provider/原生ADB执行。信息结构化报告、设备/route归属、重复请求原operationID通过；Shell真实0/7/255及Base64双流精确通过；活动时第二次提交返回busy，取消后为cancelled且无exitCode，CLI取消到取得终态约37.6ms。server正常stop释放本轮endpoint，保留既有目录及锁文件。

证据：`/tmp/devicebridge-physical-readonly/recovered-final.log`、`recovered-baseline.json`；回归红/绿日志`/tmp/devicebridge-android-recovery-red.log`、`/tmp/devicebridge-android-recovery-green.log`；macOS构建`/tmp/devicebridge-android-recovery-macos.log`。上述物理测试不依赖前期失败快照。

### 剩余范围

Android连接阻塞已解除；当前原生、业务模型与实际CLI真机链路通过。先前实际窗口验证使用fixture，本轮未在正常工作区窗口逐项重演真实手机的Q4及UI/Agent互斥操作，因此不将该证据替换为完整窗口验收。T028/T048保留此剩余项；T019/T042/T049还涉及未验证的真实iPhone已认证runtime。当前仍45/50，未完成项不表示此前Android超时仍在发生。没有提交、推送、发布或真实设备安装。
