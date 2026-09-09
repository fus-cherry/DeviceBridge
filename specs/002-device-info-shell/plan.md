# Implementation Plan: 设备信息与 Android Shell

**Branch**: `codex/device-info-shell` | **Date**: 2026-09-09 | **Spec**: [spec.md](spec.md)

**Input**: 原需求已获用户确认的 `specs/002-device-info-shell/spec.md`，以及用户追加的“暴露接口允许Agent进行调用”。

**Status**: 用户已确认继续，方案通过；任务清单和一致性检查完成，正在按独立切片实现。实际结果见[验证记录](validation.md)。

## Summary

在现有原生 macOS 工作区增加设备信息和 Android Shell 两个独立模块。复用现有设备会话、语言、受管 iOS runner 与本地开发工具，不新增 Flutter 项目依赖、后台命令或持久历史。

两个新模块同时提供本机Agent调用入口：配套CLI接收/返回JSON，通过用户私有的本地IPC调用运行中桌面应用。Agent与界面共享操作入口，不另建设备控制器；详见[Agent接口契约](contracts/agent-api.md)。首版覆盖当前已选设备，不自动选择设备或扩大到其他模块。

设备信息采用按需读取的分组报告：Android 使用固定只读查询，iPhone 基础信息使用 CoreDevice 结构化详情，屏幕及运行时参数使用受管 runner 的可选 `device.info` 能力。缺失字段保留明确原因；CoreDevice 查询时间不能冒充设备端更新时间。

Shell 使用仅连接本机 ADB server 的窄范围 smart-socket/Shell-v2 适配器。选择它是为了保留设备退出帧证据、两路输出与连接失败的区别；普通 `adb shell` 进程退出码无法完整表达这个区别。每次只执行一条原始命令，无包装脚本、自动重试、后台队列或持久终端。

## Technical Context

**Language/Version**: Swift 6.2+；既有 SwiftUI/AppKit 桌面应用，UIKit iOS runner。

**Primary Dependencies**: 现有 DeviceBridgeCore、DeviceBridgeProtocol、DeviceBridgeSecureChannel、Foundation/Network；本机 ADB 37+ 与 Xcode 26.6 构建基线。不引入第三方运行时包，不使用私有设备信息 API。

**Storage**: 会话内存中的报告和有界命令历史。CoreDevice 每次查询使用独占临时 JSON 文件，限额读取并在清理后移除；不持久保存设备详情或命令内容。

**Testing**: Swift Testing 单元/契约测试、受控本地假 ADB server、无窗口 ViewModel 检查、iOS simulator adapter 测试、构建检查及获准后进行的只读真机验收。

**Target Platform**: Apple Silicon/macOS 14+；Android 11+；iOS 17+。本轮设计只支持本机 loopback ADB server；远程 ADB server、直接设备 TCP/TLS 和终端模拟不在范围内。

**Project Type**: 现有 desktop-app 的两个功能模块与小范围设备协议扩展。

**Performance Goals**: 保持 SC-002–008：稳定连接下 10 次读取至少 9 次≤10 秒；一次读取总预算 20 秒；界面反馈≤200 ms；Shell 30 秒、正常清理≤2秒；四类竞态各10次无错配或重放。

**Constraints**: 输入16 KiB UTF-8；设备输出合计1 MiB；历史20条/2 MiB；所有外部边界均检查捕获会话和取消状态。数值范围、显示缓存与协议资源限额见[契约](contracts/android-shell.md)。性能指标是验收目标，尚无本功能实测结论。

**Scale/Scope**: 单个工作区、多台已授权设备、一次选中一个会话；界面和Agent合计一个正在执行或清理的 Shell。连接维护与其他模块仍使用现有所有者；Agent调用关联有界且不复制结果载荷。

## Constitution Check

依据[项目章程](../../.specify/memory/constitution.md)，以下是设计符合性检查，不代表实现或真机检查已通过。

| 原则/门禁 | 研究前 | 设计后及落实位置 |
| --- | --- | --- |
| 连接可信、USB优先 | 通过：不改变优先策略 | 通过：运行期间允许当前路由健康观察，恢复与迁移等待资源清理；命令不迁移 |
| 单一会话所有者 | 通过：沿用 DeviceSessionStore | 通过：只扩展现有 operation map 的 Shell 清理阶段，不增加第二份 lease map；见[数据模型](data-model.md) |
| 本地、显式、最小权限 | 通过：需求已限定 | 通过：只读信息、显式用户命令、无上传/持久历史/提权；本地 ADB server 不可用时不自行启动或重启 |
| 真实平台能力 | 通过：字段允许受限 | 通过：明确 CoreDevice 缓存、iOS字段来源、Shell-v2退出证据；无型号查表或模拟成功 |
| 独立可验收切片 | 通过：US1/US2可分别验收 | 通过：按下方切片顺序实施；先验证高风险边界，再接入界面 |
| 状态路径与失效检查 | 需本阶段具体化 | 通过：生产路径、状态与回收点已在本文件及数据模型指定 |
| 自动化、真机与内容隐私 | 要求已定义 | 验收设计通过；实际结果待实现阶段记录，不把设计通过标成已验收 |
| 新功能范围 | 后续规格可引入新能力 | FR-016 明确允许手动提交的既有 Shell 权限内操作；不扩展为无人值守管理或破坏性预置动作，无需修改章程 |
| Agent调用追加 | 用户明确要求 | FR-026–030：仅本机、显式请求、固定会话、复用权限/互斥/取消，不增加远程监听或定时任务 |

无章程例外。若未来实现不能满足绑定、退出证据、取消或数值真实性门禁，应停止该切片并修订方案，不能削弱规格后宣称通过。

## Project Structure

### Documentation (this feature)

```text
specs/002-device-info-shell/
├── spec.md
├── plan.md
├── research.md
├── data-model.md
├── quickstart.md
├── checklists/requirements.md
└── contracts/
    ├── device-information.md
    ├── android-shell.md
    ├── workspace-ui.md
    └── agent-api.md
```

`tasks.md` 由下一阶段 `speckit-tasks` 产生，本阶段不创建。

### Source Code (planned boundaries)

| 位置 | 计划职责 |
| --- | --- |
| `packages/DeviceBridgeCore/Sources/DeviceBridgeCore/Models/DeviceInformation.swift` | 报告、字段可用性、来源与采集时间；重新核对暂停前占位结构 |
| `.../Operations/DeviceInformationService.swift` | 一次信息读取的会话准入、总预算、取消与候选报告提交资格 |
| `.../Operations/AndroidDeviceInformationProvider.swift`、`IOSDeviceInformationProvider.swift` | 固定查询、字段解析与平台差异，不拥有设备选择状态 |
| `.../Commands/ADBServerConnection.swift`、`ADBShellV2Session.swift` | 本地 server epoch 观察、同一 socket 的精确路由绑定与 Shell-v2 帧；只实现所需服务 |
| `.../Operations/AndroidShellService.swift` | 一次原始命令、资源清理、终止原因与设备会话资格；不保存界面历史 |
| `.../Commands/HostCommandRunner.swift` | 保留接口，补齐信息查询依赖的总截止时间和双管道清理；先加反例测试，不改用户命令语义 |
| `.../Session/DeviceSessionStore.swift`、`.../Supervision/ConnectionMaintenance.swift`、`AndroidConnectionTransport.swift` | 在现有 owner 内区分 Shell active/draining、健康观察与排他恢复；保留旧文件传输规则 |
| `packages/DeviceBridgeProtocol/.../HelperProtocol.swift`、`DeviceRuntimeInformation.swift` | `device.info` 与固定类型结果 schema |
| `packages/DeviceBridgeSecureChannel/.../IOSRunnerIdentityHandshake.swift`、`IOSRunnerSessionServer.swift` | 可选能力协商、现有内容槽、严格请求/结果校验 |
| `packages/DeviceBridgeCore/.../Helpers/IOSRunnerChannel.swift`、`IOSRunnerDeviceInformationChannel.swift` | 受管 runner 的认证上下文与元数据请求；保留关闭语义 |
| `helpers/ios/DeviceBridgeRunnerUITests/DeviceInformationCommands.swift`、`RunnerSmokeTests.swift` | 只读 UIKit/Foundation 参数采样并注册 handler |
| `apps/macos/DeviceBridgeApp/ViewModels/DeviceInformationViewModel.swift`、`AndroidShellViewModel.swift` | 各模块的呈现状态、请求句柄；Shell 历史唯一 writer |
| `apps/macos/DeviceBridgeApp/Views/DeviceInformationView.swift`、`AndroidShellView.swift` | 分组参数与非交互式命令面板 |
| `WorkspaceViewModel.swift`、`WorkspaceView.swift` | 在会话提交后绑定、失效时先撤销；自适应模块入口与平台切换 |
| `apps/macos/DeviceBridgeApp/AgentAPI/`、配套CLI target | 本地IPC服务、版本化JSON、会话标识、调用关联与模块入口适配；CLI target在任务阶段按现有构建结构接入，不直接调用ADB |
| 对应测试目录、两个 Xcode project、`scripts/check-*.sh`、`Localization/zh-Hans.json` | 显式源文件接入、相关检查及双语文案；新检查后续接入现有 CI |

`...` 表示同列已给出的包源码根目录，实际任务清单必须展开成完整仓库相对路径。不拆分或重写旧工作区中的无关功能。

## Production path and authoritative owners

### 设备信息

用户读取 → DeviceInformationViewModel 同步进入读取态并捕获 revision → DeviceInformationService 在 Store 对精确会话准入 → Android 固定只读查询，或 iOS CoreDevice 基础查询后尝试已就绪的可选 runtime → 每次外部 await 后检查 token、revision/取消和剩余预算 → 验证字段并生成候选报告 → Store 原子完成操作并返回发布资格 → 同一 ViewModel 提交报告。

报告在 ViewModel 中只有一个呈现 owner；provider 不持久存放“当前报告”。基础查询不会等待 iOS 签名/构建：扩展未就绪就形成部分报告，下次由用户刷新。失败后如保留旧报告，仍使用旧查询时间并显示“上次结果”。

### Android Shell

用户运行 → 输入/平台/就绪检查 → Store 为捕获会话创建一次 operation → 捕获 server epoch 与路由 tuple → 同一 socket 选择 serial 并核对返回 transport ID，Wi-Fi经第二条同tuple的localabstract连接核验现有helper身份（不创建forward）→ 再检查当前会话 → 提交原始 Shell service一次 → 并行读取输出/exit及发送CloseStdin → 终止原因仲裁 → 关闭本次全部连接并等待读写结束 → Store 完成操作并判定当前会话终态呈现资格 → ViewModel 核对 executionID/revision并加入当前会话历史。

只有有效远端 exit 帧能提供退出码。已接收输出与之后的连接中断同时存在时，输出标不完整，退出码缺省。CloseStdin写失败不能抢先覆盖已缓冲的退出帧，读循环继续到有效exit、EOF或期限。取消一旦被接受，就不能由迟到的 exit 帧改成成功；已提交终态之后的取消不产生第二条终态。同会话取消清理后的cancelled记录可呈现，但不能恢复成功发布资格。

### 连接维护与清理

DeviceSessionStore 继续唯一持有 operation map。只有 Shell 记录在失效后转 `draining`，等待清理确认；其他操作保留现有失效行为。发布资格失效与资源已释放是两个不同事实，不能通过清空 map 代替关闭连接。

有 Shell 时，维护只执行当前路由的有界 `get-state` 级健康观察，并明确这不是新的 helper 身份认证；不在这一分支分配 forward、发现新路由或迁移。排他恢复、USB优先迁移和下一条 Shell 都检查完整 map（包含 draining）。`replaceInventory` 直接更新preferredTransport的自动迁移入口也必须遵守此门禁，不能仅修改维护tick。旧非 Shell 操作继续阻止 probe，避免改变已验证文件传输语义。

### iOS 扩展关闭的呈现

保留 IOSRunnerChannel 当前取消/超时关闭共享通道的语义，不增加单请求 cancel/tombstone 协议。通道逻辑进入closing时发出携带捕获的session、runner launch identity和 `bindingLost` 原因的事件；Workspace先核对当前owner，再调用现有 `invalidateIOSRunner`，撤销相关能力。事件必须先于等待TLS/endpoint物理清理，不能等metadata结果返回才通知。该通知即使发生在取消路径也要处理，不能被 `Task.isCancelled` 过滤掉；pending请求仍等待自己的清理结果。

未准入的 busy/unsupported 不撤销其他能力。基础报告与设备会话可以继续存在；用户取消的信息请求不发布其迟到结果，新 runner 不受旧失效通知影响。

## Delivery slices and gates

### Agent调用生产路径

本机CLI → 本地IPC验证 → Agent适配器核对应用实例/sessionKey → 同一模块ViewModel的显式read/run/cancel入口 → 既有service/Store → 原owner提交结果。Agent查询读取同一owner快照；关联表只存ID/请求摘要。UI与Agent竞争在共同入口及Store准入处被序列化，不能各自启动一条Shell。应用重启、设备会话失效时撤销sessionKey；响应丢失不自动重放。该追加设计的单独验收见Q6，前一轮独立评审不代表已审查本追加接口。

| 顺序 | 可验收结果 | 必须先证明的门禁 |
| --- | --- | --- |
| A. 共享基础 | 有界查询生命周期、原子expectedSession准入 | 继承FD/忽略SIGTERM反例；捕获旧会话不能在新设备准入；Shell专用边界在D切片开始时验证 |
| B. Android信息 | 从工作区读取、刷新、复制真实分组报告 | 覆盖分辨率/dpi、未知电量、容量单位、部分失败与20秒预算 |
| C. iPhone信息 | 基础查询独立可用，扩展参数按能力补充 | JSON归属/缓存标签、无前台切换、取消撤销共享能力、旧runner兼容与配套打包 |
| D. Android命令面板 | Shell-v2固定绑定、单map清理阶段、显式执行/结果/取消/会话历史 | 0/255退出对断流；server epoch/tuple复用；维护不中途迁移；只运行一次、stdin关闭、限额、历史失效与键盘操作 |
| E. Agent接口 | 从JSON入口读取两平台信息、执行/查询/取消Android命令 | 共享入口互斥、固定sessionKey、重复请求不重放、应用重启与响应丢失、结构化输出与界面一致 |
| F. 综合验收 | 四类竞态、双语UI、两平台只读真机及回归 | SC-001–009可追溯证据，不以构建成功代替实际验收 |

任务拆分应将每个切片写成有验收结果的纵向任务，不能先完成所有底层代码后才接界面。A 只包含后续切片必需的外部/会话基础，不变成通用进程或连接框架。

## Review focus and remaining qualification

首个独立评审需从“运行”入口找到 Store 准入、固定 route、结果证据、取消仲裁、清理确认与历史提交；从 iOS“读取”入口找到基础/扩展分界、共享通道关闭及当前 runner 失效检查。无法直接找到时应简化路径，而不是增加 facade。

剩余的是实现与实测证据：本地 ADB 协议兼容性、server 重启竞态、后台 runner 的屏幕参数、具体 CoreDevice 可选键、2秒清理与10秒读取目标。方案已选定处理规则与失败行为；这些验收未通过前不能开放相应执行能力或声称功能完成，详见[quickstart](quickstart.md)。

## Complexity Tracking

无章程违例，不引入通用调度器、第二份 lease 表或额外 iOS 通道。必要复杂度对应真实新语义：一个 Shell-v2 结果边界、一个仅 Shell 使用的 draining phase、一个可选 iOS metadata action。既有 HostCommandRunner 的局部修正只因信息查询的20秒边界存在可达反例而纳入，保留公共接口及旧测试。

Agent追加一个本地IPC边界及有界ID关联表，承担调用协议与响应重取；业务状态、报告和命令历史仍由原模块持有。CLI不复刻平台provider或维护生命周期。

### 实现依赖补充

Android 信息查询的固定命令必须经过 T020–022 原生同连接路由边界，避免 ADB server 重启后数字 transport ID 复用。信息 provider 以已绑定 executor 注入，无 CLI fallback；只提前共享连接基础，不要求信息页面等待 Shell UI/历史。证据见 research 实现依赖修正。
