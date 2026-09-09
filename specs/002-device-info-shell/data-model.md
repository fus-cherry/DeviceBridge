# Data model: 设备信息与 Android Shell

本文件定义实现必须保持的语义；类型名可在任务拆分时对齐现有代码，不是已经存在的 API。

## 归属与唯一 writer

| 概念 | 字段/关系 | 唯一 writer 与生命周期 |
| --- | --- | --- |
| 当前设备会话 | 既有 `ConnectionSession` 的 identity、transportID、generation、state | DeviceSessionStore；Workspace 提交选择并绑定模块，provider 不自行选设备 |
| 操作记录 | operationID、kind、完整 SessionToken、phase=`active/draining(reason)` | Store 的原有 operation map；只有 Shell 失效后保留 draining，reason区分用户取消与会话失效等 |
| 本地 ADB epoch | 本地server观察连接的单调代次、有效/失效 | ADBServerConnection 的会话范围 owner；断开后本代次永久失效，执行不重连 |
| 一次 Shell 目标 | 捕获的 SessionToken、epoch、adbSerial、实际 transport ID、可信身份依据 | 执行准入时形成不可变值；不可被最新 inventory 替换 |
| 信息候选报告 | reportID、session、queryStartedAt/queryFinishedAt、sections | 单次 provider/service 返回不可变值；尚不等于已发布报告 |
| 已发布报告 | 候选报告加当前/上次结果呈现关系 | DeviceInformationViewModel；只有 Store 完成资格和本地 revision 同时有效才提交 |
| Shell 执行 | executionID、目标、原始命令、时间、输出、终止原因、清理阶段 | AndroidShellService 的一次执行 owner；ViewModel 仅呈现事件/结果 |
| 会话历史 | 当前session key、有序终态记录、保留字节数 | AndroidShellViewModel；切换/重建/epoch失效/退出清空，无持久副本 |
| Agent会话标识 | 应用本次实例 + 当前已提交设备会话 + 每次激活的新随机binding UUID | Agent适配器；应用重启或会话/epoch失效即撤销，即使Store generation没变也不可重新发出旧key |
| Agent调用关联 | requestID、method、请求摘要、operationID；≤128项/会话 | Agent适配器；不持有第二份输出/报告，详见[接口契约](contracts/agent-api.md) |

## 信息报告

`DeviceInformationReport` 具有稳定的分组及字段 ID。字段内容为互斥枚举：`available(value, unit, source)` 或 `unavailable(reason, recovery)`，避免 value/reason 两个可选值形成矛盾状态。

- value 使用字符串、整数、有限小数、布尔或有序字符串列表；数值和单位分开。容量原始值为 bytes，显示换算注明 GiB/MiB；像素 px、逻辑尺寸 pt、显示密度 dpi、频率 Hz、电压 mV、温度 °C。
- source 包含来源类别、query time、可选 source time、freshness（live sample、系统可能缓存、未知）。报告完成时间不能覆盖旧字段或替代设备源时间。
- reason 为可本地化的封闭类别：平台未提供、设备未返回、权限不足、扩展未就绪、能力不支持、忙碌、查询超时、格式无效、连接失效。恢复动作使用既有刷新/扩展准备入口，不携带任意执行脚本。
- 字段验证及平台映射见[设备信息契约](contracts/device-information.md)。同一报告可以部分可用；取消或归属失效不可借“部分可用”绕过发布检查。
- 报告归属包含当前设备完整标识供详情与显式复制使用，一般诊断日志只保留既有脱敏上下文。

信息呈现状态：未读取 → 读取中 → 完整/部分/失败/取消。刷新期间旧报告可保留，但显示“上次结果”及旧时间；提交新报告才替换。设备会话改变立即清空旧报告与请求句柄。切换模块不改变设备会话，也不自动读取。

界面与Agent入口共享上述状态，各操作带origin=`ui/agent`。共同入口先设置忙碌状态及operationID，再进行Store准入；Agent不能绕过ViewModel另起执行。信息ViewModel保留最近一次操作终态元数据（operationID、origin、状态/原因、开始/完成时间、可选reportID）供查询，包括失败/取消无报告的情况。旧报告可继续显示，但刷新失败的元数据reportID必须为空，不能冒充本次成功；下一次操作替换元数据，旧查询不可获取。报告载荷仍只有原有一份，不另存报告历史。

## Shell 输出及终态

原始命令保留输入原文；验证空白只用于拒绝，不能 trim 后改变实际命令。输出为 stdout/stderr 两路原始 Data，分别保持各路字节顺序；不承诺重建两路交错顺序。

终态是以下互斥结果之一：

| 结果 | 退出码 | 呈现 |
| --- | --- | --- |
| remoteExit(code: UInt8) | 必有，范围0…255 | 实际退出；code非零保留全部已接收输出，stderr内容不决定成败 |
| cancelled | 无 | 用户取消；输出若有则注明不完整 |
| timedOut | 无 | 30秒执行期限到达；输出不完整 |
| outputLimitExceeded | 无 | 超过输出配额；只保留配额内前缀 |
| connectionLost / resultUnknown | 无 | 未收到有效退出证据；命令可能已经产生副作用 |
| protocolFailure | 无 | 无法信任后续帧；保留已验证输出并注明不完整 |
| notStarted(reason) | 无 | 准入失败、busy、能力不可用或service提交前失败；不声称设备执行过 |

执行 owner 串行仲裁取消、退出帧、期限与错误。接受取消早于终态提交时取消获胜；终态已提交后取消无效。不能用系统时间戳比较跨任务先后。CloseStdin写失败仅记录为待决传输错误，读循环继续在剩余期限内读取；有效exit优先于该写错误，EOF无exit才失去退出证据，显式取消/总期限仍按原规则仲裁。终止原因决定后，仍有 `draining` 资源阶段；只有关闭全部本次连接并确认读写任务结束才发出 cleaned terminal result。超过2秒清理目标保持“取消中/清理中”，禁止下一条。

## Store 准入与清理

新操作的准入必须在 Store actor 内原子校验 captured expectedSession，不能先检查旧snapshot再调用会接纳新session的旧接口。保留旧调用者接口行为；新路径传入完整期望会话。

1. 没有排他probe/recovery且期望会话active，才接纳新操作。
2. Shell 准入还要求不存在任何 active/draining Shell，不自动排队。与现有内容能力冲突时返回busy，不强制取消其他动作；具体内容槽继续由现有 owner 仲裁。
3. cancel/invalidate 立即撤销 token 的发布资格。Shell 记录转draining，其他类型保持原有移除行为；draining不出现在派生的activeOperationIDs中。
4. 信息finish保留普通发布资格。Shell的finish匹配完整token及operationID，原子返回终态呈现资格并移除记录：同一当前会话中的cancelled/timeout等清理结果仍可呈现；取消过的token绝不能提交remoteExit成功。session/epoch失效只允许确认资源清理，禁止向后续会话提交历史。旧finish不能移除新执行；清理失败或未结束不能伪装为finish。
5. finish 的返回只证明 Store 资格；回到 MainActor 后还必须检查 revision/executionID及当前epoch，才能提交报告或历史。取消中的即时反馈是呈现状态，不能当作已完成历史。

Store 的 map 是资源占用的依据；不得用activeOperationIDs为空推断可以迁移。有 Shell 时，维护可做当前route健康观察，不能复用含helper forward的排他probe。**所有自动route写入入口，包括 `replaceInventory` 的preferredTransport变更及维护恢复，都必须等待Shell清理**；新候选仍可显示，自动迁移延后。用户显式切换可提交新选择并取消旧操作，但旧draining仍阻止新的Shell及自动恢复，直至旧资源清理。

## 历史预算与呈现缓存

- 已完成记录的原始命令UTF-8字节 + stdout.count + stderr.count 总和≤2 MiB，记录数≤20；新增前FIFO淘汰到两个条件同时成立。正在执行的输出另计≤1 MiB，命令≤16 KiB。
- 当前会话终态才入历史；设备切换及断连重建后的旧终态即使完成清理也不入新历史。输入草稿同样在会话变化时清空，避免误提交到另一设备。
- 清空只删除已经完成的记录及其派生显示缓存。执行中的命令随后完成属于一条新记录，清空动作不取消执行，也不需要第二个history epoch。
- 全量Data是唯一保存副本；可见输出的解码文本合计≤256 KiB UTF-8，按页或前缀生成。无效UTF-8使用替换字符并标注，分页不能在合法多字节字符中间制造额外损坏。显式完整复制可短暂生成完整字符串，完成后不作为历史缓存保存。
- 2 MiB是历史载荷上限，包含命令及输出，非进程RSS承诺；记录元数据、当前执行、协议缓冲及可见文本分别有上述或[Shell契约](contracts/android-shell.md)的边界。

## iOS bindingLost

共享runner通道逻辑进入closing时，向Workspace发送带原session及runner launch identity的结构化失效事件，先于等待TLS/endpoint清理或恢复metadata continuation。Workspace按当前绑定核对后撤销扩展能力；事件不是报告数据提交，因此不能被“任务已取消”短路。事件不反向等待同一次channel关闭，避免重入清理互等；物理清理与pending结果仍由channel owner完成。旧runner事件不得撤销新runner。busy/unsupported在准入之前返回，不发送bindingLost。
