# Quickstart: 实现后的验证指南

**状态：实现后的可重复验收指南。** 新检查入口已建立；已经执行的结果、真机障碍和未完成项见 [validation.md](validation.md)。本指南本身不是全部通过的声明。

## 前置条件与执行范围

在仓库根目录使用既有Swift 6.2+/Xcode 26.6及本机ADB 37+基线。自动化先使用进程fixture、假ADB server和fake provider，不需要真实设备。真机步骤在进入获准的实现/设备验收阶段后执行，至少一台已授权Android 11+及一台iOS 17+；记录工具版本、设备系统、USB/Wi-Fi路由及runner准备状态，报告中脱敏完整标识。

这份指南不含提交、推送、Release打包发布、安装、更改设备显示配置或重启实际ADB server的指令。需要路由/重启故障注入时先使用隔离假server，避免影响正在使用的设备；实际设备检查仅运行列出的只读命令。

## 自动化与构建入口

以下入口当前存在，后续功能测试应接入相应套件后再运行。三个包依赖和编译缓存有关系，按顺序执行；记录总数、失败数、退出码和覆盖的新场景，不能只记录“测试通过”。

```sh
cd /Users/fus/Documents/debug_utli
swift test --package-path packages/DeviceBridgeProtocol
swift test --package-path packages/DeviceBridgeSecureChannel --no-parallel
swift test --package-path packages/DeviceBridgeCore --no-parallel
bash scripts/check-device-selection.sh
bash scripts/check-workspace-inventory.sh
bash scripts/check-workspace-modules.sh
bash scripts/check-ios-runner-workspace.sh
```

新模块另运行 `bash scripts/check-device-information.sh`、`bash scripts/check-android-shell.sh`、`bash scripts/check-agent-api.sh`。源文件依赖及CI已同步；macOS与iOS runner的实际编译命令见tasks.md，编译结果见validation.md。未进行设备安装或发布签名。

## Q1 — 外部边界与session门禁

1. HostCommandRunner先跑既有测试，再加入两个会失败的受控fixture：主进程退出但子进程持有输出FD、进程忽略SIGTERM。验证deadline覆盖EOF等待、两路读取错误和清理；修正后保留正常输出/非零退出/取消行为。不能以杀掉非本次拥有的系统进程通过测试。
2. 假ADB server分块发送status、tport和frame，覆盖多帧合并/逐字节切分、stdout/stderr、exit0、exit7、exit255、无exit的EOF、错误exit长度、未知ID及超长声明。只前三类有真实退出码；缺帧与非零退出不可混淆。
3. 验证命令原始UTF-8仅出现在一次 `shell,v2,raw:` service中，CloseStdin帧正确；输出即使包含看似ADB错误的文字也按设备结果处理。注入CloseStdin写失败但读缓冲已有exit0/255，仍须得到实际退出码；无exit的EOF不能伪造退出。
4. 捕获epoch后使假server断开并复用transport ID/serial tuple；在选择socket后、helper验证前后及service提交期间分别注入。旧执行要失败，不能重连执行。Wi-Fi helper不匹配或缺少可信上下文必须不提交service。验证identity走同tuple的localabstract流，整个Shell路径不创建/删除forward；所有identity/feature临时连接均确认关闭。
5. 让Shell清理暂停，触发取消、inventory新USB优先route、维护恢复及第二次运行。Store撤销发布但保留draining；自动迁移/新Shell等待。允许的健康查询必须仍针对旧route，且不分配forward或调用完整旧probe。
6. 放行旧清理，再提交新会话命令；旧finish及迟到输出不能移除新记录或进入新历史。相同测试保留旧文件传输期间不probe的行为。

Q1失败时不能开放对应执行路径，不能通过降低退出真实性或固定route要求来通过。

## Q2 — 设备信息与数值真实性

fixtures覆盖[信息契约](contracts/device-information.md)每组字段：缺键、空字符串、负电量、有效负温度、溢出、小数整数化、NaN、容量关系不合法、原始/覆盖分辨率及dpi差异、部分查询超时和全局20秒期限。不可用字段必须有原因，不能填0。

CoreDevice fixture要有不同identifier/UDID、缓存结果、未知source time及可选字段缺失。确认exit0不会移除缓存说明，iOS基础查询不等待runner准备；扩展未就绪仍有基础报告。旧报告刷新失败保留旧时间；取消/切换后旧候选不能发布。

在Android信息模块显式读取并核对，只读CLI基准（把环境变量设为当次确认的serial，命令使用引号）：

```sh
adb -s "$DEVICE_INFO_ANDROID_SERIAL" shell getprop ro.product.model
adb -s "$DEVICE_INFO_ANDROID_SERIAL" shell getprop ro.build.version.release
adb -s "$DEVICE_INFO_ANDROID_SERIAL" shell wm size
adb -s "$DEVICE_INFO_ANDROID_SERIAL" shell wm density
adb -s "$DEVICE_INFO_ANDROID_SERIAL" shell cat /proc/meminfo
adb -s "$DEVICE_INFO_ANDROID_SERIAL" shell df -k /data
adb -s "$DEVICE_INFO_ANDROID_SERIAL" shell dumpsys battery
```

其余字段按实现allowlist逐项比对，不自动收集完整属性库。不为覆盖测试修改真机分辨率或密度，用fixture覆盖override。对电池/RAM/可用存储记录两次采样时间，动态值用同一量纲和可解释变化比较，不要求不同时间字节值完全相同。

iPhone用同一设备CoreDevice JSON及独立UIKit/Foundation采样核对屏幕、内存、容量、电量；记录原生px、逻辑pt、坐标方向及缩放，并检查后台状态。没有可靠公开来源的字段验证其限制说明。采样不能触发截图、读取剪切板或切换前台。

## Q3 — iOS可选能力与取消

协议测试涵盖空payload、额外键、结果类型/范围、null、能力缺失、busy、错误归属、超时及重放。新host+旧runner可显示基础信息；新runner必须与host配套构建。

在已准入metadata请求上取消/超时，暂停endpoint/TLS物理清理，确认channel进入closing时Workspace就撤销对应runner能力；无需等metadata结果或heartbeat才改变界面。失效通知不等待反向关闭，避免互等。使用旧session/旧launchID失效事件验证新runner不受影响；busy/unsupported不关闭通道。用户取消后不发布部分候选，但必须完成bindingLost通知。Stop/heartbeat及既有clipboard/screenshot槽回归保持通过。

## Q4 — Shell完整流程

在当前已授权Android的面板中逐条显式运行以下只读输入，检查命令内容、目标、输出、耗时与退出码：

| 输入 | 预期 |
| --- | --- |
| `printf 'hello\n'` | stdout为hello及换行，stderr空，exit0 |
| `printf 'out\n'; printf 'err\n' >&2; exit 7` | 两路分别保留，exit7 |
| `exit 255` | exit255，不能呈现为ADB断连 |
| `true` | 两路无输出，exit0 |
| 两行：`printf 'a\nb\n'` 与 `printf 'abc' \| wc -c`（输入时管道前不加转义） | 保留换行/管道语义，输出a、b及计数3，exit0 |
| `read value; printf 'eof\n'` | stdin已关闭，不等待用户输入，输出eof |
| `sleep 10` 后点击取消 | 200ms内取消反馈；正常清理≤2秒，无退出码，清理前不能再运行 |

不在真实设备执行写入命令、破坏性用例或长期后台任务。无限输出、30秒deadline、断流、无效UTF-8、service提交不确定性与配额边界优先用fake server覆盖，避免用生产设备制造负载。

## Q5 — 历史、资源与UI

- 输入恰好16KiB/多1字节、全空白、NUL；输出恰好1MiB/多1字节、单路/两路、无效UTF-8及跨块多字节字符。验证发送前拒绝或不完整输出状态，内存持有量按原始字节检查。
- 历史20/21条及总载荷恰好2MiB/越界；FIFO正确、有淘汰反馈，显示缓存≤256KiB UTF-8。清空已完成历史后让当前命令完成，只新增这一条；选择/填入历史不执行。同会话cancelled清理完成后可保存取消记录及部分输出，不能被迟到exit改成功；会话失效则旧取消记录也不得加入新历史。
- 切换设备、断连重建、epoch失效及退出清空草稿/历史/报告；持久文件及一般日志不包含这些载荷。显式复制取准确的一份报告或结果。
- 简体中文和英文各验一次读取/刷新/取消、复制、运行、查看历史/填入/清空。Enter不执行，⌘Return遵循运行校验。长值与输出可选中复制，键盘可达主要操作。
- 按[界面契约](contracts/workspace-ui.md)记录最窄实际尺寸及常规宽窗口；Android有两模块，iPhone无可执行Shell，既有默认模块与设备切换回归通过。

## Q6 — Agent调用

实现CLI及IPC后，从单独进程使用stdin JSON调用，按[Agent契约](contracts/agent-api.md)验证：

1. `device.current`返回当前设备及sessionKey；无应用/无设备时明确失败，不自动启动或选择。只接受同一用户的本地IPC，未知版本/非法JSON/超长报文拒绝。
2. `device.info.read`在Android/iPhone上返回operationID，经`operation.get`获得与界面相同的字段值、来源、部分可用状态；重读中第二次请求busy，报告替换后旧引用不可获取。
3. `android.shell.run`显式运行 `printf 'hello\n'`，获取真实两路输出、退出码和设备归属；在iPhone上拒绝。界面标注Agent来源，界面仍可取消。
4. UI先运行再Agent提交、Agent先运行再UI提交各验证一次；只能有一个执行/清理占用。取消支持立即反馈及清理中，完成后结构化终态与界面一致。
5. 固定旧sessionKey后切换设备、重建连接、ADB epoch失效或重启应用；旧调用均拒绝，不绑定新设备，不恢复执行。
6. 丢弃accepted响应，再提交同requestID同参数，返回原operationID且只执行一次；同ID不同参数拒绝。CLI断开后以已知ID查询，不自动换ID重试；应用已退出或结果淘汰时返回不可获取。
7. 调用关联128项边界、请求128KiB/响应2MiB边界、原命令/输出上限及Base64回解后原始bytes一致；关联耗尽不淘汰已用ID后重新执行，查询/取消仍可用。
8. stdout仅JSON、日志无命令/输出/完整设备标识；示例、schema和打包CLI实际可用。开发CLI需先运行 `swift build --package-path packages/DeviceBridgeCore --product devicebridge-agent`，Release由打包脚本纳入。
9. Store generation不变但ADB epoch重建时必须生成新sessionKey，旧key/旧requestID不能重新执行；首次信息读取失败/取消可查询准确终态，刷新失败不能返回旧报告冒充本次结果。
10. 4条客户端连接均停止读响应，额外连接不得积累新编码缓冲；请求读取/响应写出5秒后释放占用，已accepted设备操作仍受自身期限约束。并发启动第二应用实例不能unlink活跃socket，旧实例退出不能移除新endpoint；崩溃后仅持锁新owner可处理残留。

## 验收记录与追溯

实现阶段在本功能目录增加真实验收记录，逐项记录运行命令/场景、日期、环境、结果及剩余限制。未跑标记“未验证”，不标“通过”。设备敏感内容留本地临时证据并按用途清理，提交记录仅包含脱敏摘要。

| 需求 | 对应设计与验证 |
| --- | --- |
| FR-001–008 | 信息/界面契约，Q2、Q5 |
| FR-009–017 | Shell契约与Store模型，Q1、Q4、Q5 |
| FR-018–019 | 历史模型与界面契约，Q5 |
| FR-020–022 | 会话/iOS失效模型，Q1–Q3 |
| FR-023–025 | UI、日志与配额边界，Q2、Q4、Q5 |
| FR-026–030 | Agent接口、共享owner及本机会话标识，Q6 |
| SC-001 | Android+iPhone每个字段有核对值或具体限制，Q2 |
| SC-002 | 设备准备完成后各10次读取，至少9次≤10秒；20秒期限fixture；记录首次准备另计 |
| SC-003 | 时间戳/界面采样证据：读取/运行/取消反馈≤200ms，持续输入及模块切换无>1秒阻塞 |
| SC-004 | Q4五类只读命令均有真实输出及退出证据 |
| SC-005 | 切换/断连/取消/重建四类竞态各10次，错配/取消后成功/自动重放均0；Q1、Q3、Q5 |
| SC-006 | 正常连接取消清理≤2秒，超出明确记录性能未达标且继续禁止新命令 |
| SC-007 | 四类边界全部通过，Q5；历史配额不等于RSS |
| SC-008 | 双语、键盘、窄窗口、既有模块及设备切换回归，Q5与既有脚本 |
| SC-009 | Agent无需界面自动化完成读取/执行/查询/取消；并发、重启和响应丢失无错配或重放，Q6 |
