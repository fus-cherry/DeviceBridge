# 002 — 设备信息与 Android Shell

当前阶段：**设备信息、Android Shell、会话历史和本机 Agent 接口已实现并接入工作区；自动化与编译通过，SpecKit 收敛检查已完成并追加3项剩余验收任务。本机界面时延与长内容验收已完成；Android原生与实际CLI真机链路已通过；正常窗口真机重演及iOS运行时验收仍未完成，不能标为全量通过。**

- [需求规格](spec.md)：详细字段、Android/iPhone 差异、命令面板、历史与验收。
- [规格质量检查](checklists/requirements.md)：16/16 自检通过，含澄清覆盖情况；不是实现完成标记。
- [技术方案](plan.md)：架构边界、生产路径、状态所有者与交付切片。
- [研究结论](research.md)：技术选择、反证与一手依据。
- [数据模型](data-model.md)：会话、报告、执行、清理及历史生命周期。
- 接口契约：[设备信息](contracts/device-information.md)、[Android Shell](contracts/android-shell.md)、[工作区界面](contracts/workspace-ui.md)。
- [Agent调用接口](contracts/agent-api.md)：本机JSON CLI、当前会话、读取/执行/查询/取消，与界面共享状态及限制。
- [验收指南](quickstart.md)：实现后的测试步骤及FR/SC追溯，执行结果及限制见验证记录。
- [任务清单](tasks.md)：依赖顺序及逐项进度；[验证记录](validation.md)：已经运行的检查与尚未验证项。

## SpecKit 阶段顺序

1. `speckit-specify`：完成；用户选择“命令面板”已写入规格。
2. `speckit-clarify`：完成本轮覆盖检查；无需重复询问已确认的 Shell 形态。
3. 需求评审：完成；用户于2026-09-09回复“同意，继续吧”。
4. `speckit-plan`：Phase 0/1设计文档完成；前后扩展钩子不适用（无extensions.yml）。
5. 方案评审：通过；`speckit-tasks`生成47项任务，`speckit-analyze`完成39项需求覆盖检查，无实现阻塞项。
6. `speckit-implement`：代码与接入完成；完整基线Core 502项、Protocol 7项、SecureChannel 83项及相关无窗口检查通过；随后iPhone字段修复的16项针对性测试和macOS重新构建通过。iPhone基础信息10/10采样及真实CLI调用通过；UIKit适配测试已实际执行5/5通过；Android恢复在线，修复型号/容量解析遗漏后12项针对性测试、10/10真机读取、7项原生Shell和实际CLI读取/执行/取消通过；正常窗口真机重演与iOS运行时门禁仍未完成。
7. `speckit-converge`：完成30项FR、9项SC、27个验收场景及方案/章程核对；发现3项partial（HIGH 2、MEDIUM 1），在Phase 9追加T048–T050。当前45/50项完成，5项保留未完成；新增项追踪旧任务的剩余验收，不代表5个独立功能缺口。

流程中的需求与方案评审门禁来自项目已有 [SpecKit workflow](../../.specify/workflows/speckit/workflow.yml)，本轮遵循用户“先设计、逐步实现”的要求。

## 本阶段验证

- 规格与设计文档齐全，本地Markdown链接已检查；追加后包含FR-001–030、SC-001–009及5个用户故事，已生成tasks.md。
- 原方案只读独立反证审查发现4项设计问题，修订并复核后没有新增设计阻塞项；具体反例和处理见[研究结论](research.md)。该审查不覆盖之后追加的Agent接口，也不代表真机或代码测试通过。
- 文档阶段`git diff --check`通过；现已进入实现，代码与测试进度以validation.md为准。原有未提交改动仍按下方记录保留。

## 工作区现状

- Git 分支为 `codex/device-info-shell`；SpecKit 活跃目录已设为本目录，旧 `001-device-debug-bridge` 保持不变。
- README 的“本项目由 AI 自主生成”声明仍保留，尚未提交。
- 暂停前模型占位已按批准的 SpecKit 方案实现；两个平台 provider、原生 ADB Shell-v2、信息与 Shell ViewModel/View、Agent IPC/CLI 和相关测试均已接入。旧占位状态只属于前期记录，不再代表当前实现。
- 此前 `docs/superpowers/` 下的两份初稿已标记停用，由本目录规格取代；没有据此继续编码。
- 本轮工作按 SpecKit 切片和文件所有权推进；高风险连接/取消/IPC经过独立反证和新读者复核。没有提交、推送、真实设备安装或发布本功能；用户另行授权的模拟器测试应用安装/执行已完成。
