# Contract: 本机Agent调用接口

覆盖FR-026–030、US5、SC-009。方案已获用户同意继续；接口等待按任务实现与验证，尚未开放。

## 入口与范围

首版提供随桌面应用配套分发的 `devicebridge-agent` CLI，使用JSON输入/输出，转发至运行中应用的本地Unix socket。适合Agent的命令调用工具使用；本轮不增加MCP server或HTTP远程服务。CLI不是第二个设备控制器，应用未运行返回 `app_unavailable`，不自行启动ADB、runner或新应用实例。

请求通过stdin传入，不把命令及设备标识放进进程参数；stdout只输出JSON，stderr只输出不含载荷的诊断。IPC由应用持有，用户私有目录权限0700、socket权限0600，并核对连接的本机用户身份；不开放网络监听。CLI与IPC采用同一版本化请求模型，协议版本不支持即拒绝。此接口面向同一用户授权运行的本机程序，不声称隔离同一用户下的恶意程序。

同一用户只有一个IPC owner：应用先持有私有目录内固定锁文件的进程生命周期独占锁，成功后才能处理崩溃残留socket和绑定endpoint。第二实例不得覆盖活跃owner；锁文件不在退出时删除，避免不同inode各自加锁。启动拒绝符号链接或属主不符的目录/endpoint；退出仅由持锁owner移除本次创建且身份仍匹配的endpoint，先关闭监听及连接再释放锁。不得按“路径已存在”直接unlink。

调用方显式请求即为操作入口，不要求再次模拟点击。仍然受当前设备授权、已就绪能力、既有权限和资源边界限制；接口不自动准备扩展或代替用户选择设备。

## v1逻辑方法

每个请求包含 `apiVersion: 1`、调用方生成的UUID `requestID`、`method` 和 `params`。所有改变设备操作状态的方法显式传 `sessionKey`；状态查询同样校验sessionKey归属。sessionKey包含应用本次实例、已提交设备会话及本次Agent binding激活的随机UUID。每次会话或ADB epoch失效撤销旧key，重新激活必须生成新UUID；即使Store generation没变，也不能让旧key再次有效。

| method | params | 结果与行为 |
| --- | --- | --- |
| `device.current` | 空对象 | 当前设备归属、sessionKey、平台和各能力可用状态/原因；无当前设备返回明确状态，不选择设备 |
| `device.info.read` | sessionKey | 创建一次信息读取，立即返回operationID及accepted；复用完整/部分/取消报告契约 |
| `android.shell.run` | sessionKey、command | 创建一次命令，立即返回operationID及accepted；原命令不改写，非Android/忙碌/无能力时拒绝 |
| `operation.get` | sessionKey、operationID | pending/running/cancelling/draining/terminal及可用结果；只查询，不刷新设备、不执行命令 |
| `operation.cancel` | sessionKey、operationID | 请求取消；已完成则返回既有终态，未清理结束不能响应为已取消完成；只作用于Agent来源的匹配操作 |

响应公共字段为apiVersion、requestID及互斥result/error。操作结果包含origin=`agent`、operationID、sessionKey、设备归属、时间和结构化终态。信息字段沿用[信息模型](../data-model.md)；Shell输出使用带编码标签的stdout/stderr原始bytes之Base64，避免无效UTF-8丢失及重复缓存全文；exitCode仅remoteExit时存在。

稳定错误码至少包含：`unsupported_version`、`invalid_request`、`app_unavailable`、`no_active_session`、`stale_session`、`unsupported_capability`、`busy`、`operation_not_found`、`result_unavailable`。返回错误码和简短说明，恢复动作不能包含自动执行的命令。调用被接受不等于设备操作成功，CLI自身成功返回也不能代替设备退出码。

单次请求JSON≤128KiB；command仍严格≤16KiB UTF-8。单次响应JSON≤2MiB，输出在编码前受既有1MiB总限额约束，信息报告单字段文本≤1KiB、总序列化≤64KiB；超限报告具体错误，不静默截断数字或伪造完整报告。IPC使用长度前缀及限额完整读取；CLI不在stdout混入状态日志。

全局最多4条已接纳连接，每连接一次只处理1个请求和1个响应；最多4份在途响应，不另设无界队列。请求帧读取及响应写出各5秒期限，超时关闭该客户端并释放缓冲；容量满时立即关闭/返回busy，不能先分配完整响应。设备操作本身按既有20/30秒运行，已accepted操作不会因查询连接读写超时被自动取消。编码完整输出不在MainActor上阻塞界面；只从业务owner取得不可变快照再执行有界编码。

## 同一个生产入口及生命周期

Agent CLI → 本地IPC版本/用户/长度验证 → MainActor上的Agent调用适配器核对sessionKey → **与界面相同的模块read/run/cancel方法** → 既有service与DeviceSessionStore → 原模块提交结果/历史 → operation.get从该owner读取结构化快照。

在UI和Agent都可调用的入口原子分配operationID并设置忙碌状态，随后执行Store准入；不能先返回accepted再允许第二个入口覆盖活动句柄。两个入口共用一个Shell占用；任何一端正在执行或清理时另一端返回busy。信息读取同样不相互覆盖，在已有读取时返回busy。

Agent适配器只保存必要的有界调用关联（requestID→operationID），不保存第二份命令/报告/输出，不另建Store或执行队列。信息ViewModel保留最近一次操作终态元数据（operationID、origin、状态/原因、时间、可选reportID），首次失败/取消也可查询；刷新失败不得关联上一份报告为本次结果。报告载荷仍只有原有一份；下一次信息操作替换这份元数据，旧查询可返回result_unavailable。Shell引用当前执行或现有历史；被替换/淘汰的结果返回result_unavailable，不延长载荷保留周期。UI显示“Agent调用”及执行状态，仍可取消。

同一requestID在当前会话内重复时返回原关联，参数不一致则invalid_request，不再次执行。关联表最多128项；本会话用尽后拒绝新的启动请求并说明上限，不通过淘汰已用requestID来允许重放；状态查询/取消仍可用。会话失效即清空表并撤销sessionKey；应用重启也生成新实例标识。该表只保存ID、方法和请求摘要用于一致性核对，不记录原始载荷或写入磁盘。UI来源操作不占用此表。

CLI断开不等于用户取消：已accepted的操作继续受原期限约束，调用方可用已知operationID或相同requestID查回关联；**不得换一个requestID自动重试命令**。若sessionKey已失效或应用已退出，返回未知/不可获取，不能恢复执行。Agent取消与界面取消均遵循原Store draining和当前会话终态规则。

## 调用说明与验收

实现时随CLI提供schema、错误码和stdin示例：获取当前会话 → 显式传sessionKey读取信息 → 查询operationID；Android只读 `printf 'hello\n'` → 查询两路输出/真实退出码 → 对未完成操作取消。示例使用返回的sessionKey，不能硬编码“第一台设备”或用空标识默认执行。

验证顺序见[Q6](../quickstart.md#q6--agent调用)：两平台信息、Android命令、界面并发、旧会话/应用重启、响应丢失/重复requestID、限额及Agent结果与界面一致性。上述CLI名称与协议为设计契约，只有后续实现及打包验收通过才能宣称可调用。
