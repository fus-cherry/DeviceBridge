# Tasks: 设备信息、Android Shell 与 Agent 调用

**Input**: [spec.md](spec.md)、[plan.md](plan.md)、[data-model.md](data-model.md)、[contracts](contracts/agent-api.md)、[quickstart.md](quickstart.md)。

**Authorization**: 用户在追加Agent接口后回复“继续”，进入任务拆分、一致性检查及逐片实现。初始阶段没有提交、推送、安装或发布授权。用户后续回复“允许执行”，仅追加当前OPPO的一次定向ADB重连及本机模拟器5项UIKit测试所需的安装/启动授权；随后用户另行回复“允许”，追加5037服务重启授权并已完成；5038保持不变，不包含真实iPhone安装或发布。不得照搬旧停用草稿或恢复旧代理任务。

**Tests**: 规格SC-001–009及章程明确要求契约、竞态、平台和回归验证。先写可失败的关键反例，后实现；每片通过对应检查再标记完成。真实设备未验证项保持未完成。

所有路径均相对仓库根目录 `/Users/fus/Documents/debug_utli`。`[P]`仅表示不同文件、前置满足后可并行；相同文件保持一个write owner。构建/设备/共享项目文件由主代理串行协调。

## Phase 1: Setup

- [x] T001 核对当前分支、保留README及暂停前模型占位，检查忽略规则与源文件接入方式，将基线记录到 `specs/002-device-info-shell/validation.md`；涉及 `.gitignore`、`apps/macos/DeviceBridge.xcodeproj/project.pbxproj`、`helpers/ios/DeviceBridgeRunner.xcodeproj/project.pbxproj`。
- [x] T002 运行现有HostCommandRunner/DeviceSessionStore/ConnectionMaintenance及iOS通道相关基线测试，在 `specs/002-device-info-shell/validation.md` 记录实际命令、结果与预存失败，保留 `packages/DeviceBridgeCore/Tests/DeviceBridgeCoreTests/HostCommandRunnerTests.swift` 等现有安全网。

## Phase 2: Foundational — 有界查询与原子会话准入

所有故事共享基础；固定 ADB socket/epoch 边界（T020–022）同时服务 Android 信息查询与 Shell，提前实现。Shell draining、交互与历史仍在 US2/US3，iOS 信息不等待它们。

- [x] T003 [P] 在 `packages/DeviceBridgeCore/Tests/DeviceBridgeCoreTests/HostCommandRunnerTests.swift` 增加主进程退出后继承输出FD、忽略SIGTERM、取消及双流清理的受控反例；先记录旧实现失败，fixture自身有退出边界。
- [x] T004 在 `packages/DeviceBridgeCore/Sources/DeviceBridgeCore/Commands/HostCommandRunner.swift` 局部修正总截止时间、双管道收尾及owned-child终止升级，保持HostCommandRunning接口和普通输出语义；通过T003及旧测试。
- [x] T005 [P] 在 `packages/DeviceBridgeCore/Tests/DeviceBridgeCoreTests/DeviceSessionStoreTests.swift` 保护新操作expectedSession原子准入、旧token提交拒绝及旧调用者兼容。
- [x] T006 在 `packages/DeviceBridgeCore/Sources/DeviceBridgeCore/Session/DeviceSessionStore.swift` 新增精确会话准入，保留原调用入口行为；在 `packages/DeviceBridgeCore/Sources/DeviceBridgeCore/Models/DeviceModels.swift` 核对deviceInformation/androidShell操作类型。

**Checkpoint**: 查询期限可结束，旧会话不能被新操作接口重新接纳；基础测试通过后进入US1。

## Phase 3: US1 — 两平台设备信息 (P1 / MVP)

**独立验收**：从工作区读取Android/iPhone分组参数，刷新/取消/复制；缺失有原因，基础iOS信息不等待runner准备。FR-001–008、022–024，SC-001–003/008。

- [x] T007 [P] [US1] 在 `packages/DeviceBridgeCore/Tests/DeviceBridgeCoreTests/DeviceInformationTests.swift` 写分组字段、数值/单位、可用性互斥、来源时间、完整复制及报告限额测试。
- [x] T008 [US1] 将暂停前占位替换为计划中的报告/字段/来源/会话模型，实现于 `packages/DeviceBridgeCore/Sources/DeviceBridgeCore/Models/DeviceInformation.swift`；补充有明确单位和限制原因的共享显示/序列化映射。
- [x] T009 [P] [US1] 在 `packages/DeviceBridgeCore/Tests/DeviceBridgeCoreTests/AndroidDeviceInformationTests.swift` 编写Android固定查询fixture：physical/override/dpi、未知电量/负温度、内存与卷容量、可选键、局部失败和全局期限。
- [x] T010 [US1] 在 `packages/DeviceBridgeCore/Sources/DeviceBridgeCore/Operations/AndroidDeviceInformationProvider.swift` 实现固定allowlist查询/有界解析，在 `packages/DeviceBridgeCore/Sources/DeviceBridgeCore/Operations/DeviceInformationService.swift` 实现捕获会话、剩余预算、候选与原子提交资格。
- [x] T011 [P] [US1] 在 `packages/DeviceBridgeCore/Tests/DeviceBridgeCoreTests/IOSDeviceInformationTests.swift` 保护CoreDevice JSON归属、缓存标签、可选键缺失、独占临时文件及runner未就绪时部分报告。
- [x] T012 [US1] 在 `packages/DeviceBridgeCore/Sources/DeviceBridgeCore/Operations/IOSDeviceInformationProvider.swift` 实现基础JSON查询及可选runtime合并；仅以已验证键展示值，不用UIDevice.name覆盖CoreDevice名称。
- [x] T013 [P] [US1] 在 `packages/DeviceBridgeProtocol/Tests/DeviceBridgeProtocolTests/DeviceRuntimeInformationTests.swift` 与 `packages/DeviceBridgeSecureChannel/Tests/DeviceBridgeSecureChannelTests/IOSRunnerDeviceInformationTests.swift` 定义device.info空请求、严格结果、null/数值、可选协商和内容槽反例。
- [x] T014 [US1] 在 `packages/DeviceBridgeProtocol/Sources/DeviceBridgeProtocol/DeviceRuntimeInformation.swift`、`packages/DeviceBridgeProtocol/Sources/DeviceBridgeProtocol/HelperProtocol.swift` 及 `packages/DeviceBridgeSecureChannel/Sources/DeviceBridgeSecureChannel/IOSRunnerIdentityHandshake.swift` 实现固定DTO和可选action协商，维持配套host/runner版本行为。
- [x] T015 [US1] 在 `packages/DeviceBridgeSecureChannel/Sources/DeviceBridgeSecureChannel/IOSRunnerSessionServer.swift` 接入可取消metadata内容槽handler；在 `helpers/ios/DeviceBridgeRunnerUITests/DeviceInformationCommands.swift`、`helpers/ios/DeviceBridgeRunnerUITests/RunnerSmokeTests.swift` 采集公开UIKit/Foundation字段并注册；同步 `helpers/ios/DeviceBridgeRunner.xcodeproj/project.pbxproj`。
- [x] T016 [US1] 在 `packages/DeviceBridgeCore/Sources/DeviceBridgeCore/Helpers/IOSRunnerChannel.swift` 与 `packages/DeviceBridgeCore/Sources/DeviceBridgeCore/Helpers/IOSRunnerDeviceInformationChannel.swift` 实现认证metadata入口及logical-closing bindingLost事件；在 `packages/DeviceBridgeCore/Tests/DeviceBridgeCoreTests/IOSRunnerChannelTests.swift` 验证清理暂停时先撤销、旧launchID不能影响新绑定、busy不失效。
- [x] T017 [US1] 在 `apps/macos/DeviceBridgeAppTests/DeviceInformationModelChecks.swift` 先写未读取/部分/刷新保留旧时间/取消/会话切换/迟到结果/读取互斥的无窗口检查，接入 `scripts/check-device-information.sh`。
- [x] T018 [US1] 实现 `apps/macos/DeviceBridgeApp/ViewModels/DeviceInformationViewModel.swift`、`apps/macos/DeviceBridgeApp/Views/DeviceInformationView.swift`，在 `apps/macos/DeviceBridgeApp/ViewModels/WorkspaceViewModel.swift` 和 `apps/macos/DeviceBridgeApp/Views/WorkspaceView.swift` 接入读取/刷新/取消/复制及当前runner失效，更新 `apps/macos/DeviceBridge.xcodeproj/project.pbxproj` 和 `packages/DeviceBridgeCore/Sources/DeviceBridgeCore/Localization/zh-Hans.json`。
- [ ] T019 [US1] 执行Q2/Q3及信息模型检查，编译macOS应用和iOS runner，按Q2完成两平台只读参数核对与10次时长采样，在 `specs/002-device-info-shell/validation.md` 逐项记录SC-001/002结果，未验证不得标通过。

## Phase 4: US2 — Android Shell (P1)

**独立验收**：Android面板运行只读输入，真实两路输出及0/7/255退出；取消、清理、并发限制正确，iPhone无执行入口。FR-009–017/020–021/025，SC-003–007。

- [x] T020 [P] [US2] 在 `packages/DeviceBridgeCore/Tests/DeviceBridgeCoreTests/ADBShellV2Tests.swift` 和 `packages/DeviceBridgeCore/Tests/DeviceBridgeCoreTests/ADBServerConnectionTests.swift` 编写隔离假server及帧/tuple/epoch/localabstract身份反例，包括即时exit与CloseStdin写失败竞争；不重启实际ADB server。
- [x] T021 [US2] 在 `packages/DeviceBridgeCore/Sources/DeviceBridgeCore/Commands/ADBServerConnection.swift` 实现本机socket、严格smart-socket、同socket tport/ID校验、epoch观察及无forward的helper identity流；任一路失效不重连执行。
- [x] T022 [US2] 在 `packages/DeviceBridgeCore/Sources/DeviceBridgeCore/Commands/ADBShellV2Session.swift` 实现原始命令service、CloseStdin、两路有界Data、真实exit、错误/期限/取消仲裁和所有临时socket清理；通过T020。
- [x] T023 [P] [US2] 在 `packages/DeviceBridgeCore/Tests/DeviceBridgeCoreTests/DeviceSessionStoreTests.swift` 和 `packages/DeviceBridgeCore/Tests/DeviceBridgeCoreTests/ConnectionMaintenanceTests.swift` 保护Shell active/draining、取消终态资格、inventory自动路由变更、当前route健康观察及旧非Shell禁止probe行为。
- [x] T024 [US2] 在 `packages/DeviceBridgeCore/Sources/DeviceBridgeCore/Session/DeviceSessionStore.swift`、`packages/DeviceBridgeCore/Sources/DeviceBridgeCore/Supervision/ConnectionMaintenance.swift`、`packages/DeviceBridgeCore/Sources/DeviceBridgeCore/Supervision/AndroidConnectionTransport.swift` 实现单operation map清理阶段、所有自动迁移入口门禁及只读健康分支；不直接复用含forward的旧probe。
- [x] T025 [US2] 在 `packages/DeviceBridgeCore/Sources/DeviceBridgeCore/Models/AndroidShellExecution.swift`、`packages/DeviceBridgeCore/Sources/DeviceBridgeCore/Operations/AndroidShellService.swift` 实现一次执行owner、原始输入验证、固定会话、单终态及清理确认；新增 `packages/DeviceBridgeCore/Tests/DeviceBridgeCoreTests/AndroidShellServiceTests.swift` 验证拒绝/未知/取消先后。
- [x] T026 [US2] 在 `apps/macos/DeviceBridgeAppTests/AndroidShellModelChecks.swift` 保护Enter不执行、运行互斥、取消中禁止运行、origin/operationID、窗口保留及设备切换清空；接入 `scripts/check-android-shell.sh`。
- [x] T027 [US2] 实现 `apps/macos/DeviceBridgeApp/ViewModels/AndroidShellViewModel.swift`、`apps/macos/DeviceBridgeApp/Views/AndroidShellView.swift`，接入 `apps/macos/DeviceBridgeApp/ViewModels/WorkspaceViewModel.swift`、`apps/macos/DeviceBridgeApp/Views/WorkspaceView.swift` 的Android专属模块及所有失效入口，更新 `apps/macos/DeviceBridge.xcodeproj/project.pbxproj` 和 `packages/DeviceBridgeCore/Sources/DeviceBridgeCore/Localization/zh-Hans.json`。
- [ ] T028 [US2] 完成Q1/Q4协议及授权Android只读场景，记录真实退出证据、限额及取消耗时到 `specs/002-device-info-shell/validation.md`；未通过tuple/退出/清理门禁的路径不开放执行。

## Phase 5: US4 — 断连、切换和迟到结果 (P1)

**独立验收**：通过可控延迟切换/断连/取消/重建各10次，无旧结果错配、取消后成功或命令重放。FR-006/008/014–015/020–022，SC-005/006/008。

- [x] T029 [P] [US4] 在 `apps/macos/DeviceBridgeAppTests/DeviceInformationModelChecks.swift` 与 `apps/macos/DeviceBridgeAppTests/AndroidShellModelChecks.swift` 扩展四类竞态各10次、清理暂停、旧finish、新runner绑定及双入口竞争的受控场景。
- [x] T030 [US4] 在 `apps/macos/DeviceBridgeApp/ViewModels/WorkspaceViewModel.swift`、`packages/DeviceBridgeCore/Sources/DeviceBridgeCore/Session/DeviceSessionStore.swift` 修补T029暴露的具体失效入口，保留既有模块行为；通过 `scripts/check-device-selection.sh`、`scripts/check-workspace-inventory.sh` 和 `scripts/check-ios-runner-workspace.sh`。
- [x] T031 [US4] 在 `specs/002-device-info-shell/validation.md` 记录Q1/Q3竞态计数、清理≤2秒目标与超时仍busy的证据，核对一般诊断日志不含载荷或完整标识。

## Phase 6: US3 — 会话历史与有界输出 (P2)

US3在US5前执行，是Agent结果查询复用现有历史的直接依赖，不因P2标签跳过此依赖。

**独立验收**：查看/填入/清空不执行，20条/2MiB FIFO、显示缓存及会话清空成立。FR-018–019/024–025，SC-007。

- [x] T032 [P] [US3] 在 `packages/DeviceBridgeCore/Tests/DeviceBridgeCoreTests/AndroidShellHistoryTests.swift` 及 `apps/macos/DeviceBridgeAppTests/AndroidShellModelChecks.swift` 写20/21条、2MiB、无效UTF-8/跨块字符、清空后当前执行完成及旧会话迟到测试。
- [x] T033 [US3] 在 `packages/DeviceBridgeCore/Sources/DeviceBridgeCore/Models/AndroidShellHistory.swift` 实现纯有界历史值/分页转换，在 `apps/macos/DeviceBridgeApp/ViewModels/AndroidShellViewModel.swift` 保持唯一writer与raw Data唯一载荷，显示解码缓存≤256KiB UTF-8。
- [x] T034 [US3] 在 `apps/macos/DeviceBridgeApp/Views/AndroidShellView.swift` 接入查看/填入/清空、FIFO提示、分页/完整复制及独立Shell说明；更新 `packages/DeviceBridgeCore/Sources/DeviceBridgeCore/Localization/zh-Hans.json`，通过Q5边界并记录 `specs/002-device-info-shell/validation.md`。

## Phase 7: US5 — 本机Agent接口 (P1，依赖US1/2/3/4)

**独立验收**：CLI JSON完成设备上下文、两平台信息、Android执行/查询/取消；与UI互斥、响应丢失不重放、旧sessionKey失效。FR-026–030及FR-002/011/016/024追加条款，SC-009。

- [x] T035 [P] [US5] 在 `packages/DeviceBridgeCore/Tests/DeviceBridgeCoreTests/AgentAPITests.swift` 写v1严格schema、UUID/未知版本、stdin请求/响应限额、Base64输出原始bytes、状态/错误映射及无敏感日志测试。
- [x] T036 [US5] 在 `packages/DeviceBridgeCore/Sources/DeviceBridgeCore/AgentAPI/AgentAPIProtocol.swift` 实现五个方法的请求/响应及长度边界；状态引用现有信息/Shell模型，不复制设备控制逻辑。
- [x] T037 [P] [US5] 在 `packages/DeviceBridgeCore/Tests/DeviceBridgeCoreTests/AgentIPCTests.swift` 写私有目录/socket权限、peer用户、分块报文、4连接/响应及5秒读写限额、客户端断开、生命周期锁/第二实例/崩溃残留/旧owner退出的隔离本地IPC测试。
- [x] T038 [US5] 在 `packages/DeviceBridgeCore/Sources/DeviceBridgeCore/AgentAPI/AgentIPC.swift` 实现同用户Unix IPC，在 `packages/DeviceBridgeCore/Sources/DeviceBridgeAgentCLI/main.swift` 实现stdin/stdout JSON CLI；在 `packages/DeviceBridgeCore/Package.swift` 注册 `devicebridge-agent` executable，应用不可用不自动启动。
- [x] T039 [US5] 在 `apps/macos/DeviceBridgeAppTests/AgentAPIWorkspaceChecks.swift` 写sessionKey实例/epoch重新激活隔离、requestID重用/参数冲突/128项耗尽、accepted响应丢失、信息失败/取消终态、UI并发、结果淘汰与取消的无窗口检查；接入 `scripts/check-agent-api.sh`。
- [x] T040 [US5] 在 `apps/macos/DeviceBridgeApp/AgentAPI/AgentAPIController.swift` 实现MainActor适配器/有界ID关联；接入 `apps/macos/DeviceBridgeApp/ViewModels/WorkspaceViewModel.swift`、`apps/macos/DeviceBridgeApp/App/DeviceBridgeApp.swift` 的实例/session生命周期，复用两个ViewModel共同入口并在失效时撤销sessionKey。
- [x] T041 [US5] 更新 `apps/macos/DeviceBridge.xcodeproj/project.pbxproj`、`scripts/build-release.sh`、`scripts/verify-release.py` 和 `scripts/test_release_bundle.py`，将CLI作为配套本地可执行文件正确打包及校验；本任务不创建Release、签名部署或发布。
- [ ] T042 [US5] 在 `docs/agent-api.md` 提供真实CLI路径、v1输入/输出schema及只读调用示例，并从 `README.md` 链接；在 `apps/macos/DeviceBridgeApp/Views/WorkspaceView.swift` 提供调用说明入口，完成Q6并将结果写入 `specs/002-device-info-shell/validation.md`。

## Phase 8: Polish & 跨功能验收

- [x] T043 补齐所有新增文件的实际Xcode/无窗口脚本编译依赖，在 `scripts/check-workspace-modules.sh`、`scripts/check-device-selection.sh`、`scripts/check-workspace-inventory.sh`、`scripts/check-ios-runner-workspace.sh` 和 `.github/workflows/release.yml` 接入必要新检查，避免脚本漏编译新模块。
- [x] T044 完成简体中文/英文、键盘、800×600或既有更大最小窗口、长设备名/字段/输出及Agent来源界面验收；对应 `apps/macos/DeviceBridgeAppTests/WorkspaceModuleChecks.swift` 与 `specs/002-device-info-shell/validation.md`，保留截图/交互证据的脱敏摘要。
- [x] T045 运行相关包测试、无窗口新旧检查、macOS及iOS runner编译与CLI打包测试；将准确命令、次数、失败及限制记入 `specs/002-device-info-shell/validation.md`，不得用编译成功替代真机验收。
- [x] T046 对实际高风险diff做一次独立反证/新读者评审，沿生产入口核对owner、提交、失效、取消清理及终态；修正具体发现后在 `specs/002-device-info-shell/validation.md` 记录范围与证据。
- [x] T047 使用 `speckit-converge` 对照30项FR、9项SC和任务完成状态，将已验证及未验证项反映到 `specs/002-device-info-shell/README.md`、`specs/002-device-info-shell/validation.md`；保持未完成任务未勾选，不提交/推送/发布。

## 依赖与并行

主链：T001–006 → US1（Android 原生查询依赖 T020–022）→ US2 → US4 → US3 → US5 → 跨功能验收。MVP是US1完整纵向切片；共享 ADB 连接边界提前，Shell 界面与历史不作为其能力依赖。本次完整范围仍须完成全部5个故事。

基础中T003→T004与T005→T006是不同文件的两条独立依赖链，可以并行编辑；共享Swift编译/测试时段仍串行交接。

- US1：T007/T009/T011/T013可以先分别写独立测试；模型T008完成后Android provider与iOS协议/adapter可由不同owner推进。T017–018统一接入，Xcode项目文件只由主代理写。
- US2：T020和T023在基础完成后可独立写反例；T021–022协议与T024 Store/维护分属不同文件，T025依赖两边完成；T026–028随后形成界面切片。
- US4：两个模块测试文件可分别处理；Workspace/Store修正单owner串行，不与其他阶段同时写。
- US3：模型层历史测试与UI已有场景分析可并行；同一AndroidShellViewModel保持单owner。
- US5：T035/T037可分别写协议与IPC测试；T039在共同模块入口稳定后启动；T040之后由同一owner接App生命周期和T041打包，避免项目文件冲突。
- 测试运行使用同一Swift缓存时串行；真实设备及桌面UI由主代理协调，不与其他代理并发操作。

## 验证命令基线

工作目录为仓库根目录；新脚本只在对应任务已创建后执行。

```sh
swift test --package-path packages/DeviceBridgeProtocol
swift test --package-path packages/DeviceBridgeSecureChannel --no-parallel
swift test --package-path packages/DeviceBridgeCore --no-parallel
xcodebuild build -project apps/macos/DeviceBridge.xcodeproj -scheme DeviceBridge -configuration Debug -derivedDataPath artifacts/device-info-macos-build CODE_SIGNING_ALLOWED=NO
xcodebuild build-for-testing -project helpers/ios/DeviceBridgeRunner.xcodeproj -scheme DeviceBridgeRunner -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath artifacts/device-info-ios-build CODE_SIGNING_ALLOWED=NO
swift build --package-path packages/DeviceBridgeCore --product devicebridge-agent
```

## 需求覆盖索引

| 需求 | 任务 |
| --- | --- |
| FR-001–008 | T007–019、T029–031 |
| FR-009–017 | T020–028、T029–031 |
| FR-018–019 | T032–034、T029–031 |
| FR-020–022 | T005–006、T012–019、T023–031 |
| FR-023–025 | T007–019、T020–028、T032–034、T044–045 |
| FR-026–030 | T035–042 |
| SC-001–002 | T003–004、T009–019 |
| SC-003–006 | T016–019、T020–031、T044–045 |
| SC-007 | T020–028、T032–034 |
| SC-008 | T018–019、T030、T043–045 |
| SC-009 | T035–042 |

任务总数47：Setup/基础6，US1 13，US2 9，US4 3，US3 3，US5 8，跨功能5。完成标记只代表该任务描述的完整证据齐全，不把设计检查或某一子步骤通过当成整个任务完成。


## Phase 9: Convergence

- [ ] T048 完成 Android 真机信息、Shell 与 Agent 验收：先定位 `adb shell` 与原生执行器均超时的原因，在可用且明确授权的设备上复验 Q2/Q4/Q6，逐字段比对、各10次读取、五类只读命令及正常执行后的取消清理；将实测与独立基准记录到 `specs/002-device-info-shell/validation.md`，按结果完成 T019/T028/T042。追溯 FR-003/006/011/014/027–030、SC-001/002/004/006/009、US1/US2/US5 与 plan: 真机门禁（partial，HIGH）。当前恢复后10/10报告、独立CLI比对、7项原生Shell及实际Agent CLI已通过；正常工作区窗口的真实手机Q4/UI互斥重演仍待完成。此前0/10超时只属历史证据；需要重启、安装或其他超出本轮授权的动作时另行取得授权。
- [ ] T049 执行 iOS runtime adapter 的5项测试，并在可用且明确授权的 iPhone 上完成 Q2/Q3/Q6：核对基础与运行时字段、未就绪/失效行为、10次读取及 Agent 结构化结果，将证据写入 `specs/002-device-info-shell/validation.md`，按结果完成 T015/T019/T042。追溯 FR-004–008/027–030、SC-001/002/009、US1/US5 与 plan: iOS runtime / 真机门禁（partial，HIGH）。UIKit模拟器测试已获授权并实际5/5通过，基础信息10/10及实际CLI已通过；真实iPhone runtime仍未验证，尚无真实iPhone安装/启动测试授权。
- [x] T050 补齐长设备名、长字段、长输出及 Agent 来源的实际窗口检查，并测量读取/运行/取消反馈≤200ms、持续输入和模块切换无>1秒无响应；保留脱敏采样方法及结果到 `specs/002-device-info-shell/validation.md`，完成 T044。追溯 FR-022/024/028、SC-003/008、US1/US2/US5 与 plan: 工作区界面验收（partial，MEDIUM）。复用已完成的双语、键盘和800×600检查，仅补未验证项。
